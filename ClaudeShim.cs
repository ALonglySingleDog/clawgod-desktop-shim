using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

// ClaudeShim.exe
//
// Lets Claude Desktop (MSIX build) run the Claude Code CLI that the ClawGod
// installer produced, i.e. ~/.local/bin/claude.cmd.
//
// Claude Desktop never looks at PATH: it resolves a CLI binary from
//   %LOCALAPPDATA%\Claude-3p\claude-code\<version>\<sha256-prefix>\claude.exe
// and requires a sibling ".verified" file holding the manifest checksum. When
// it cannot find one it downloads the CLI from downloads.claude.ai, which is
// what fails on a machine that cannot reach that host.
//
// This shim reproduces what claude.cmd does (spawn Bun against the patched
// ~/.clawgod/cli.cjs with CLAUDE_CODE_EXECPATH pointing at the original
// binary) and forwards stdio and the exit code unchanged.
//
// stdio is pumped by hand rather than inherited: .NET's Process only passes
// bInheritHandles=TRUE to CreateProcess when at least one standard handle is
// redirected, so a child started without redirection silently gets a fresh,
// empty stdout. Redirecting all three and copying the bytes ourselves is the
// only way to get byte-exact, streaming stdio in both directions.
//
// The child is placed in a job object with KILL_ON_JOB_CLOSE, so killing the
// shim also kills the CLI. Without that the CLI would keep the stdout pipe
// open and the host would wait forever for an EOF that never arrives.

public static class ClaudeShim
{
    private const int JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
    private const int JobObjectExtendedLimitInformation = 9;

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInfo
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    private static string UserHome
    {
        get { return Environment.GetFolderPath(Environment.SpecialFolder.UserProfile); }
    }

    private static bool Debug
    {
        get { return Environment.GetEnvironmentVariable("CLAUDE_SHIM_DEBUG") == "1"; }
    }

    public static int Main(string[] args)
    {
        return RunClaude(UserHome, args);
    }

    // The explicit home keeps runtime discovery testable without touching the
    // user's installed ClawGod files. Production always uses UserHome.
    internal static int RunClaude(string userHome, string[] args)
    {
        // Desktop reads diagnostics as UTF-8. Process also creates an
        // auto-flushing stdin StreamWriter from Console.InputEncoding; its
        // encoding must have no BOM or it writes extra bytes before our pump.
        // The pumps themselves still read and write raw, undecoded bytes.
        Console.InputEncoding = new UTF8Encoding(false);
        Console.OutputEncoding = new UTF8Encoding(false);

        string target = FindClaudeCmd(userHome);
        if (target == null)
        {
            Console.Error.WriteLine("[claude-shim] claude.cmd not found. Check CLAUDE_SHIM_TARGET or " +
                Path.Combine(userHome, ".local", "bin", "claude.cmd"));
            return 127;
        }

        string targetDir = Path.GetDirectoryName(target);
        string origExe = Path.Combine(targetDir, "claude.orig.exe");
        string cli = Path.Combine(userHome, ".clawgod", "cli.cjs");
        string importExe = Path.Combine(userHome, ".clawgod", "clawgod-import.exe");

        // claude.cmd routes the "import" subcommand to its own tool.
        if (args.Length > 0 && args[0] == "import")
        {
            if (!File.Exists(importExe))
            {
                Console.Error.WriteLine("[claude-shim] import tool not installed. Reinstall clawgod to get it.");
                return 127;
            }
            List<string> rest = new List<string>();
            for (int i = 1; i < args.Length; i++) rest.Add(args[i]);
            return Run(importExe, rest, null);
        }

        if (!File.Exists(cli))
        {
            Console.Error.WriteLine("[claude-shim] cli.cjs not found: " + cli + ". Reinstall clawgod.");
            return 127;
        }
        if (!File.Exists(origExe))
        {
            Console.Error.WriteLine("[claude-shim] original CLI not found: " + origExe + ". Reinstall clawgod.");
            return 127;
        }

        string bun = FindBun(target, userHome);
        if (bun == null)
        {
            Console.Error.WriteLine("[claude-shim] Bun not found. Check the bun.exe path in " + target +
                " or set CLAUDE_SHIM_BUN to its full path. cmd.exe fallback is disabled " +
                "because it cannot forward Desktop's long arguments.");
            return 127;
        }

        // Same work claude.cmd does, without cmd.exe's 8191-character limit
        // or its interpretation of quotes, percent expansions and metacharacters.
        List<string> full = new List<string>();
        full.Add(cli);
        foreach (string a in args) full.Add(a);
        Dictionary<string, string> env = new Dictionary<string, string>();
        env["CLAUDE_CODE_EXECPATH"] = origExe;
        return Run(bun, full, env);
    }

    private static string FindClaudeCmd(string userHome)
    {
        string fromEnv = Environment.GetEnvironmentVariable("CLAUDE_SHIM_TARGET");
        if (!string.IsNullOrEmpty(fromEnv))
            return File.Exists(fromEnv) ? Path.GetFullPath(fromEnv) : null;

        string nextTo = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "claude.cmd");
        if (File.Exists(nextTo)) return nextTo;

        string inLocalBin = Path.Combine(userHome, ".local", "bin", "claude.cmd");
        if (File.Exists(inLocalBin)) return inLocalBin;

        return null;
    }

    private static string FindBun(string target, string userHome)
    {
        string fromEnv = Environment.GetEnvironmentVariable("CLAUDE_SHIM_BUN");
        if (!string.IsNullOrEmpty(fromEnv))
            return GetExistingBun(fromEnv, target, userHome);

        // Prefer the runtime chosen by the installed launcher. ClawGod may
        // install Bun via npm rather than into ~/.bun/bin. Read the executable
        // path as data; never execute the batch file or its shell expressions.
        try
        {
            Match match = Regex.Match(File.ReadAllText(target),
                @"(?im)^\s*""(?<bun>[^""\r\n]*[\\/]bun\.exe)""\s+""[^""\r\n]*cli\.cjs""");
            if (match.Success)
            {
                string found = GetExistingBun(match.Groups["bun"].Value, target, userHome);
                if (found != null) return found;
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }

        List<string> candidates = new List<string>();
        string bunInstall = Environment.GetEnvironmentVariable("BUN_INSTALL");
        if (!string.IsNullOrEmpty(bunInstall)) candidates.Add(bunInstall + @"\bin\bun.exe");
        candidates.Add(Path.Combine(userHome, ".bun", "bin", "bun.exe"));
        candidates.Add(Path.Combine(userHome, "AppData", "Roaming", "npm", "node_modules", "bun", "bin", "bun.exe"));
        candidates.Add(@"%APPDATA%\npm\node_modules\bun\bin\bun.exe");

        string path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (string entry in path.Split(';'))
        {
            string dir = entry.Trim().Trim('"');
            if (dir.Length == 0) continue;
            candidates.Add(dir + @"\bun.exe");
            // npm's PATH entry contains bun.cmd; bypass that wrapper too.
            candidates.Add(dir + @"\node_modules\bun\bin\bun.exe");
        }

        foreach (string candidate in candidates)
        {
            string found = GetExistingBun(candidate, target, userHome);
            if (found != null) return found;
        }
        return null;
    }

    private static string GetExistingBun(string candidate, string target, string userHome)
    {
        try
        {
            string targetDir = Path.GetDirectoryName(Path.GetFullPath(target));
            candidate = candidate.Trim().Trim('"');
            candidate = Regex.Replace(candidate, @"%USERPROFILE%",
                delegate(Match m) { return userHome; }, RegexOptions.IgnoreCase);
            candidate = Regex.Replace(candidate, @"%~dp0",
                delegate(Match m) { return targetDir + Path.DirectorySeparatorChar; }, RegexOptions.IgnoreCase);
            candidate = Environment.ExpandEnvironmentVariables(candidate);
            if (!Path.IsPathRooted(candidate)) candidate = Path.Combine(targetDir, candidate);
            candidate = Path.GetFullPath(candidate);
            return File.Exists(candidate) ? candidate : null;
        }
        catch (ArgumentException) { return null; }
        catch (NotSupportedException) { return null; }
        catch (IOException) { return null; }
    }

    private static int Run(string fileName, List<string> args, Dictionary<string, string> env)
    {
        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = fileName;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;

        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < args.Count; i++)
        {
            if (i > 0) sb.Append(' ');
            sb.Append(QuoteForWindows(args[i]));
        }
        psi.Arguments = sb.ToString();

        if (env != null)
        {
            foreach (KeyValuePair<string, string> kv in env)
            {
                psi.EnvironmentVariables[kv.Key] = kv.Value;
            }
        }

        return Spawn(psi, fileName);
    }

    private static int Spawn(ProcessStartInfo psi, string label)
    {
        psi.RedirectStandardInput = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;

        if (Debug)
        {
            Console.Error.WriteLine("[claude-shim] exec: " + psi.FileName + " " + psi.Arguments);
        }

        Process child = new Process();
        child.StartInfo = psi;

        IntPtr job = IntPtr.Zero;
        try
        {
            child.Start();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("[claude-shim] failed to start " + label + ": " + ex.Message);
            return 127;
        }

        job = AssignToKillOnCloseJob(child.Id);

        // stdout / stderr: copy the child's bytes to our own handles, unmodified.
        Thread outThread = new Thread(delegate()
        {
            Pump(child.StandardOutput.BaseStream, Console.OpenStandardOutput());
        });
        outThread.IsBackground = true;
        outThread.Start();

        Thread errThread = new Thread(delegate()
        {
            Pump(child.StandardError.BaseStream, Console.OpenStandardError());
        });
        errThread.IsBackground = true;
        errThread.Start();

        // stdin: forward whatever the host writes until our stdin ends, then
        // close the child's stdin so it sees EOF (and not a pipe that stays open).
        Thread inThread = new Thread(delegate()
        {
            try
            {
                Stream src = Console.OpenStandardInput();
                byte[] buf = new byte[8192];
                while (true)
                {
                    int n = src.Read(buf, 0, buf.Length);
                    if (n <= 0) break;
                    child.StandardInput.BaseStream.Write(buf, 0, n);
                    child.StandardInput.BaseStream.Flush();
                }
            }
            catch (Exception)
            {
                // The child closed stdin, or our own stdin ended. Either is fine.
            }
            finally
            {
                try { child.StandardInput.BaseStream.Close(); } catch (Exception) { }
            }
        });
        inThread.IsBackground = true;
        inThread.Start();

        child.WaitForExit();

        try { child.StandardInput.BaseStream.Close(); } catch (Exception) { }

        // Give the pumps a moment to drain whatever is still buffered.
        outThread.Join(2000);
        errThread.Join(2000);

        if (job != IntPtr.Zero) CloseHandle(job);

        return child.ExitCode;
    }

    private static void Pump(Stream from, Stream to)
    {
        try
        {
            byte[] buf = new byte[8192];
            while (true)
            {
                int n = from.Read(buf, 0, buf.Length);
                if (n <= 0) break;
                to.Write(buf, 0, n);
                to.Flush();
            }
        }
        catch (Exception)
        {
            // One of the pipes closed; nothing left to copy.
        }
    }

    // Standard CreateProcess argument quoting.
    private static string QuoteForWindows(string s)
    {
        if (s.Length > 0 && s.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) return s;

        StringBuilder sb = new StringBuilder();
        sb.Append('"');
        int backslashes = 0;
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            if (c == '\\')
            {
                backslashes++;
                continue;
            }
            if (c == '"')
            {
                sb.Append('\\', backslashes * 2 + 1);
                sb.Append('"');
                backslashes = 0;
                continue;
            }
            if (backslashes > 0)
            {
                sb.Append('\\', backslashes);
                backslashes = 0;
            }
            sb.Append(c);
        }
        if (backslashes > 0) sb.Append('\\', backslashes * 2);
        sb.Append('"');
        return sb.ToString();
    }

    private static IntPtr AssignToKillOnCloseJob(int pid)
    {
        try
        {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) return IntPtr.Zero;

            JobObjectExtendedLimitInfo info = new JobObjectExtendedLimitInfo();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

            int size = Marshal.SizeOf(typeof(JobObjectExtendedLimitInfo));
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(info, buffer, false);
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (uint)size))
                {
                    CloseHandle(job);
                    return IntPtr.Zero;
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }

            Process proc = Process.GetProcessById(pid);
            IntPtr handle = proc.Handle;
            if (!AssignProcessToJobObject(job, handle))
            {
                CloseHandle(job);
                return IntPtr.Zero;
            }
            return job;
        }
        catch (Exception)
        {
            return IntPtr.Zero;
        }
    }
}

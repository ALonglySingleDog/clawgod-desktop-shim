<#
.SYNOPSIS
    Keeps Claude Desktop pointed at the ClawGod-patched Claude Code CLI.

.DESCRIPTION
    Claude Desktop (MSIX) never looks at PATH. It resolves its Claude Code CLI
    from

        %LOCALAPPDATA%\Claude-3p\claude-code\<version>\<sha256-prefix>\claude.exe

    and only accepts that directory when a sibling ".verified" file contains
    the checksum pinned in the app's manifest. Otherwise it downloads the CLI
    from downloads.claude.ai.

    This script reads the pinned version and win32-x64 checksum straight out of
    the installed app.asar and (re)installs claude.exe (the shim that runs
    ~/.local/bin/claude.cmd) plus the .verified marker for that version.

    Run it after every Claude Desktop update, or from a scheduled task.

.PARAMETER Uninstall
    Remove the deployed shim from the Desktop cache and the
    CLAUDE_CODE_LOCAL_BINARY variable.

.PARAMETER LinuxCli
    Path to a linux-x64 "claude" binary (from the npm package
    @anthropic-ai/claude-code-linux-x64). When given, it is also installed
    into the workspace VM's CLI slot. The VM still needs its disk images,
    which come from downloads.claude.ai and are not shipped here.

.PARAMETER FetchLinuxCli
    Download @anthropic-ai/claude-code-linux-x64@<pinned version> from the npm
    registry and install it into the workspace VM's CLI slot. Needs npm and
    network access to the registry.

.PARAMETER ProxyUrl
    Proxy for the Cowork workspace VM's downloads, e.g. "http://127.0.0.1:7890".
    Written into the active configLibrary entry as "egressProxyUrl". Use this
    when the VM download host cannot be reached directly.

.PARAMETER ClearProxy
    Remove a previously written "egressProxyUrl".

.EXAMPLE
    .\redeploy.ps1
    .\redeploy.ps1 -FetchLinuxCli
    .\redeploy.ps1 -LinuxCli .\package\claude
    .\redeploy.ps1 -ProxyUrl http://127.0.0.1:7890
    .\redeploy.ps1 -ClearProxy
    .\redeploy.ps1 -Uninstall
#>
param(
    [switch]$Uninstall,
    [string]$LinuxCli,
    [switch]$FetchLinuxCli,
    [string]$ProxyUrl,
    [switch]$ClearProxy
)

$ErrorActionPreference = 'Stop'

$ShimSource     = Join-Path $PSScriptRoot 'ClaudeShim.exe'
$ShimInstalled  = Join-Path $env:USERPROFILE '.local\bin\claude-shim.exe'
$UserDataSuffix = 'Claude-3p'          # the "3p" (third-party) desktop build
$StorageRoot    = Join-Path $env:LOCALAPPDATA "$UserDataSuffix\claude-code"

function Write-Ok($m)   { Write-Host "  [ok]   $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Write-Info($m) { Write-Host "  $m" -ForegroundColor DarkGray }

# --- find the installed Desktop package -------------------------------

function Get-AppAsarPath {
    $roots = @(
        (Join-Path $env:ProgramFiles 'WindowsApps'),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'WindowsApps' }),
        (Join-Path $env:LOCALAPPDATA 'AnthropicClaude')
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $hits = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'AnthropicPBC.Claude_*' -or $_.Name -like 'app-*' }
        foreach ($hit in $hits) {
            $candidates = @(
                (Join-Path $hit.FullName 'app\resources\app.asar'),
                (Join-Path $hit.FullName 'resources\app.asar')
            )
            foreach ($c in $candidates) {
                if (Test-Path -LiteralPath $c) { return $c }
            }
        }
    }
    return $null
}

function Get-PinnedCli($asarPath) {
    $bytes = [System.IO.File]::ReadAllBytes($asarPath)
    # Latin1 maps bytes 1:1 to chars, so offsets stay meaningful and the UTF-8
    # manifest inside the archive stays searchable.
    $text = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
    $opts = [System.Text.RegularExpressions.RegexOptions]::Singleline

    $m = [regex]::Match($text,
        '\{"version":"(?<ver>\d+\.\d+\.\d+)","manifest":\{.*?"win32-x64":\{"binary":"claude\.exe\.zst","checksum":"(?<win>[0-9a-f]{64})"',
        $opts)
    if (-not $m.Success) { return $null }

    $lin = [regex]::Match($text,
        '\{"version":"(?<ver>\d+\.\d+\.\d+)","manifest":\{.*?"linux-x64":\{"binary":"claude\.zst","checksum":"(?<linux>[0-9a-f]{64})"',
        $opts)

    return [pscustomobject]@{
        Version      = $m.Groups['ver'].Value
        WinChecksum  = $m.Groups['win'].Value
        LinuxChecksum = $(if ($lin.Success) { $lin.Groups['linux'].Value } else { $null })
    }
}

# --- uninstall ---------------------------------------------------------

if ($Uninstall) {
    Write-Host ''
    Write-Host '  Claude Desktop -> ClawGod shim, uninstall' -ForegroundColor White

    if (Test-Path -LiteralPath $StorageRoot) {
        Get-ChildItem -LiteralPath $StorageRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $exe = Join-Path $_.FullName 'claude.exe'
                $ver = Join-Path $_.FullName '.verified'
                if ((Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $ver)) {
                    $size = (Get-Item -LiteralPath $exe).Length
                    if ($size -lt 1MB) {           # only ever delete our tiny shim
                        Remove-Item -LiteralPath $exe, $ver -Force -ErrorAction SilentlyContinue
                        Write-Ok "removed $($_.FullName)"
                    }
                }
            }
        }
    }

    [Environment]::SetEnvironmentVariable('CLAUDE_CODE_LOCAL_BINARY', $null, 'User')
    Write-Ok 'cleared CLAUDE_CODE_LOCAL_BINARY'

    if (Test-Path -LiteralPath $ShimInstalled) {
        Remove-Item -LiteralPath $ShimInstalled -Force
        Write-Ok "removed $ShimInstalled"
    }

    Write-Info 'Restart Claude Desktop to finish.'
    return
}

# --- install -----------------------------------------------------------

Write-Host ''
Write-Host '  Claude Desktop -> ClawGod shim' -ForegroundColor White

& (Join-Path $PSScriptRoot 'build.ps1')

if (-not (Test-Path -LiteralPath $ShimSource)) {
    throw "ClaudeShim.exe not found next to this script ($ShimSource)"
}

# Validate BEFORE replacing any deployed binary or setting the user override.
# Native stderr is left alone and the exit code is checked explicitly: piping
# `2>&1 | Select-Object -First 1` used to label a startup error as a version.
$versionOutput = @(& $ShimSource --version)
if ($LASTEXITCODE -ne 0) {
    throw "Shim could not report its version (exit $LASTEXITCODE). Deployment stopped."
}
$version = ($versionOutput -join [Environment]::NewLine).Trim()
if (-not $version) { throw 'Shim produced no version output. Deployment stopped.' }
Write-Ok "shim reports: $version"

$asar = Get-AppAsarPath
if ($asar -eq $null) {
    throw 'Could not find the installed Claude Desktop (app.asar).'
}
Write-Info "Claude Desktop: $asar"

$pin = Get-PinnedCli $asar
if ($pin -eq $null) {
    throw 'Could not read the pinned Claude Code version/checksum out of app.asar.'
}
Write-Info "pinned CLI: $($pin.Version)  checksum: $($pin.WinChecksum.Substring(0,12))..."

$dir = Join-Path $StorageRoot (Join-Path $pin.Version $pin.WinChecksum.Substring(0,12))
New-Item -ItemType Directory -Path $dir -Force | Out-Null

$target = Join-Path $dir 'claude.exe'

# Claude Desktop may still be running and holding claude.exe open. Windows
# refuses to overwrite a file that is in use, so check first and tell the user
# to close the app rather than failing halfway through the deployment.
if (Test-Path -LiteralPath $target) {
    try {
        $probe = [System.IO.File]::Open($target, 'Open', 'ReadWrite', 'None')
        $probe.Close()
    } catch {
        Write-Host ''
        Write-Host '  Claude Desktop is still running and is holding' -ForegroundColor Yellow
        Write-Host '  claude.exe open, so it cannot be replaced.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Close Claude Desktop (all windows + the tray icon), then run this' -ForegroundColor Yellow
        Write-Host '  script again.' -ForegroundColor Yellow
        Write-Host ''
        throw 'Claude Desktop is running; close it and re-run.'
    }
}

Copy-Item -LiteralPath $ShimSource -Destination $target -Force
Write-Ok "installed $target"

# The marker has to hold the full manifest checksum; that is the only thing
# Desktop compares. It does not re-hash the file for a host install on Windows.
[System.IO.File]::WriteAllText((Join-Path $dir '.verified'), $pin.WinChecksum)
Write-Ok "wrote $dir\.verified"

# Keep a canonical copy outside the versioned directory too.
$binDir = Split-Path -Parent $ShimInstalled
if (-not (Test-Path -LiteralPath $binDir)) {
    New-Item -ItemType Directory -Path $binDir -Force | Out-Null
}
Copy-Item -LiteralPath $ShimSource -Destination $ShimInstalled -Force
Write-Ok "installed $ShimInstalled"

[Environment]::SetEnvironmentVariable('CLAUDE_CODE_LOCAL_BINARY', $ShimInstalled, 'User')
Write-Ok "CLAUDE_CODE_LOCAL_BINARY = $ShimInstalled"

# --- fetch the linux-x64 CLI from npm ----------------------------------

function Get-LinuxCliFromNpm {
    param([string]$Version)

    $pkg = '@anthropic-ai/claude-code-linux-x64'
    $npm = (Get-Command npm -ErrorAction SilentlyContinue)
    if ($npm -eq $null) {
        throw 'npm was not found on PATH; install Node.js, or pass -LinuxCli <path> instead.'
    }

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-linux-cli-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $ok = $false
    try {
        Write-Info "downloading $pkg@$Version from the npm registry ..."
        Push-Location $work
        try {
            & npm pack "$pkg@$Version" --silent 2>&1 | Out-Null
        } finally {
            Pop-Location
        }

        $tgz = Get-ChildItem -LiteralPath $work -Filter '*.tgz' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($tgz -eq $null) {
            throw "npm pack produced no tarball for $pkg@$Version"
        }

        $extract = Join-Path $work 'extracted'
        New-Item -ItemType Directory -Path $extract -Force | Out-Null

        # Extract from inside the work directory with a relative name: GNU tar
        # reads a leading "C:" as a remote host and refuses to connect.
        Push-Location $work
        try {
            & tar -xzf $tgz.Name -C 'extracted'
        } finally {
            Pop-Location
        }
        if ($LASTEXITCODE -ne 0) { throw 'failed to extract the npm tarball' }

        $bin = Join-Path $extract 'package\claude'
        if (-not (Test-Path -LiteralPath $bin)) {
            $bin = Join-Path $extract 'package/claude'
        }
        if (-not (Test-Path -LiteralPath $bin)) {
            $found = Get-ChildItem -LiteralPath $extract -Recurse -Filter 'claude' -File -ErrorAction SilentlyContinue |
                        Select-Object -First 1
            if ($found -ne $null) { $bin = $found.FullName }
        }
        if (-not (Test-Path -LiteralPath $bin)) {
            throw 'the npm tarball did not contain package/claude'
        }

        # Confirm it really is an ELF binary before it goes anywhere.
        $head = [System.IO.File]::ReadAllBytes($bin)[0..3]
        if (-not ($head[0] -eq 0x7F -and $head[1] -eq 0x45 -and $head[2] -eq 0x4C -and $head[3] -eq 0x46)) {
            throw 'the downloaded file is not an ELF binary'
        }

        $ok = $true
        return $bin
    } finally {
        # Only clean up on failure: on success the caller still needs the file.
        if (-not $ok) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- proxy for the workspace VM's downloads ----------------------------

function Set-EgressProxy {
    param([string]$Url, [switch]$Clear)

    $libDir = Join-Path $env:LOCALAPPDATA "$UserDataSuffix\configLibrary"
    $metaPath = Join-Path $libDir '_meta.json'
    if (-not (Test-Path -LiteralPath $metaPath)) {
        Write-Warn2 "no configLibrary at $libDir; skipping proxy configuration"
        return
    }

    $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
    $id = $meta.appliedId
    if (-not $id) {
        Write-Warn2 'configLibrary has no appliedId; skipping proxy configuration'
        return
    }

    $entryPath = Join-Path $libDir "$id.json"
    if (-not (Test-Path -LiteralPath $entryPath)) {
        Write-Warn2 "active configLibrary entry $id.json not found; skipping proxy configuration"
        return
    }

    # Read/modify/write as raw text: the entry holds a sealed value that must
    # not be round-tripped through ConvertTo-Json (it would be re-encoded).
    $raw = Get-Content -LiteralPath $entryPath -Raw

    if ($Clear) {
        $updated = [regex]::Replace($raw, ',\s*"egressProxyUrl"\s*:\s*"[^"]*"', '')
        $updated = [regex]::Replace($updated, '"egressProxyUrl"\s*:\s*"[^"]*"\s*,\s*', '')
        if ($updated -ne $raw) {
            [System.IO.File]::WriteAllText($entryPath, $updated)
            Write-Ok 'cleared egressProxyUrl'
        } else {
            Write-Info 'egressProxyUrl was not set'
        }
        return
    }

    if (-not $Url) { return }

    $escaped = $Url.Replace('\', '\\').Replace('"', '\"')
    if ($raw -match '"egressProxyUrl"\s*:') {
        $updated = [regex]::Replace($raw, '"egressProxyUrl"\s*:\s*"[^"]*"', '"egressProxyUrl":"' + $escaped + '"')
    } else {
        $updated = [regex]::Replace($raw, '^\s*\{', '{ "egressProxyUrl":"' + $escaped + '",', 1)
    }
    [System.IO.File]::WriteAllText($entryPath, $updated)
    Write-Ok "egressProxyUrl = $Url  (in configLibrary $id.json)"
}

# --- workspace VM CLI (optional) --------------------------------------
#
# Cowork's bash tool runs in a Linux VM. Its CLI slot is
#   %LOCALAPPDATA%\Claude-3p\claude-code-vm\<version>\claude  (+ .verified)
# and, like the host slot, is normally filled by a download from
# downloads.claude.ai. If a linux-x64 binary is supplied, install it so the
# VM stops trying to fetch the CLI. The VM disk images (rootfs.vhdx, vmlinuz,
# initrd) are separate and still have to come from that host.

$vmDir = Join-Path $env:LOCALAPPDATA "$UserDataSuffix\claude-code-vm\$($pin.Version)"

if ($FetchLinuxCli) {
    $LinuxCli = Get-LinuxCliFromNpm -Version $pin.Version
}

if ($LinuxCli) {
    if (-not (Test-Path -LiteralPath $LinuxCli)) {
        throw "Linux CLI not found: $LinuxCli"
    }
    $head = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $LinuxCli))[0..3]
    if (-not ($head[0] -eq 0x7F -and $head[1] -eq 0x45 -and $head[2] -eq 0x4C -and $head[3] -eq 0x46)) {
        throw "$LinuxCli is not an ELF binary"
    }
    if ($pin.LinuxChecksum -eq $null) {
        throw 'Could not read the linux-x64 checksum out of app.asar.'
    }

    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
    Copy-Item -LiteralPath $LinuxCli -Destination (Join-Path $vmDir 'claude') -Force
    [System.IO.File]::WriteAllText((Join-Path $vmDir '.verified'), $pin.LinuxChecksum)
    Write-Ok "installed $vmDir\claude (workspace VM CLI)"

    # The npm copy lives in a temp directory; drop it once it is in place.
    $tempRoot = [System.IO.Path]::GetTempPath()
    if ($LinuxCli.StartsWith($tempRoot)) {
        $tempDir = Split-Path -Parent (Split-Path -Parent $LinuxCli)
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} elseif (Test-Path -LiteralPath (Join-Path $vmDir 'claude')) {
    Write-Info "workspace VM CLI already present in $vmDir"
} else {
    Write-Warn2 'workspace VM CLI not installed (-LinuxCli <path to package\claude>)'
}

# --- proxy for the workspace VM's downloads ----------------------------

if ($ClearProxy) {
    Set-EgressProxy -Clear
} elseif ($ProxyUrl) {
    Set-EgressProxy -Url $ProxyUrl
}

# Verify the deployed copy too, without swallowing a nonzero exit code.
$deployedVersion = @(& $target --version)
if ($LASTEXITCODE -ne 0) {
    throw "Deployed shim could not report its version (exit $LASTEXITCODE)."
}
if (-not ($deployedVersion -join '').Trim()) { throw 'Deployed shim produced no version output.' }
Write-Ok "deployed shim reports: $($deployedVersion -join ' ')"

Write-Host ''
Write-Info 'Restart Claude Desktop so it re-resolves the CLI.'

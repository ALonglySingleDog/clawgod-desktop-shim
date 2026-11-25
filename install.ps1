<#
.SYNOPSIS
    One-shot setup: point Claude Desktop at the ClawGod-patched Claude Code CLI.

.DESCRIPTION
    Checks the prerequisites, compiles the shim if needed, then runs redeploy.ps1
    with everything that can be done without extra input.

    Run this on a fresh machine (or after a Claude Desktop update).

    What it sets up:
      * a shim that makes Claude Desktop run ~/.local/bin/claude.cmd
      * the shim + .verified marker in Claude Desktop's own CLI cache
      * the CLAUDE_CODE_LOCAL_BINARY environment variable (secondary path)
      * the linux-x64 CLI inside the Cowork workspace VM's slot (from npm)

    What it cannot set up:
      * the Cowork workspace VM's disk images (rootfs.vhdx, vmlinuz, initrd).
        They come from downloads.claude.ai and are ~1.4 GB. If that host is
        unreachable, cowork's bash tool stays unavailable; file tools still
        work. Use -ProxyUrl if you have a proxy.

.PARAMETER ProxyUrl
    Proxy for the Cowork workspace VM's downloads, e.g. "http://127.0.0.1:7890".

.PARAMETER SkipLinuxCli
    Do not download the linux-x64 CLI for the workspace VM (needs npm).

.PARAMETER CloseDesktop
    Close a running Claude Desktop automatically instead of asking the user to
    do it. Without this the script stops and tells you to close the app, because
    Windows will not let it replace claude.exe while it is in use.

.PARAMETER Uninstall
    Remove everything this setup installed.

.EXAMPLE
    .\install.ps1
    .\install.ps1 -CloseDesktop
    .\install.ps1 -ProxyUrl http://127.0.0.1:7890
    .\install.ps1 -Uninstall
#>
param(
    [string]$ProxyUrl,
    [switch]$SkipLinuxCli,
    [switch]$CloseDesktop,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

function Ok($m)   { Write-Host "  [ok]   $m" -ForegroundColor Green }
function Warn2($m){ Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Info($m) { Write-Host "  $m" -ForegroundColor DarkGray }
function Step($m) { Write-Host "`n  $m" -ForegroundColor Cyan }

Write-Host ''
Write-Host '  Claude Desktop -> ClawGod Claude Code' -ForegroundColor White
Write-Host '  ======================================' -ForegroundColor DarkGray

# --- uninstall ---------------------------------------------------------

if ($Uninstall) {
    Step 'Uninstalling'
    & (Join-Path $here 'redeploy.ps1') -Uninstall
    exit $LASTEXITCODE
}

# --- prerequisites -----------------------------------------------------

Step 'Checking prerequisites'

# 1. ClawGod's CLI
$clawgodCmd = Join-Path $env:USERPROFILE '.local\bin\claude.cmd'
if (Test-Path -LiteralPath $clawgodCmd) {
    Ok "ClawGod CLI: $clawgodCmd"
    $v = @(& $clawgodCmd --version)
    if ($LASTEXITCODE -ne 0) { throw "ClawGod CLI could not start (exit $LASTEXITCODE). Reinstall clawgod first." }
    if (-not ($v -join '').Trim()) { throw 'ClawGod CLI produced no version output.' }
    Ok "  reports: $($v -join ' ')"
} else {
    throw "ClawGod CLI not found at $clawgodCmd. Install clawgod first, then re-run this script."
}

# 2. Claude Desktop (MSIX)
$asar = $null
foreach ($root in @((Join-Path $env:ProgramFiles 'WindowsApps'), (Join-Path $env:LOCALAPPDATA 'AnthropicClaude'))) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'AnthropicPBC.Claude_*' -or $_.Name -like 'app-*' } |
        ForEach-Object {
            foreach ($c in @((Join-Path $_.FullName 'app\resources\app.asar'), (Join-Path $_.FullName 'resources\app.asar'))) {
                if ($asar -eq $null -and (Test-Path -LiteralPath $c)) { $asar = $c }
            }
        }
}
if ($asar -eq $null) {
    throw 'Claude Desktop was not found. Install it from the Microsoft Store first, then re-run this script.'
}
Ok "Claude Desktop: $asar"

# 3. npm (only needed for the workspace VM's CLI)
$haveNpm = $null -ne (Get-Command npm -ErrorAction SilentlyContinue)
if ($haveNpm) { Ok 'npm found' } else { Warn2 'npm not found on PATH (Node.js) — the workspace VM CLI will be skipped' }

# --- close Claude Desktop if needed ------------------------------------

Step 'Checking that Claude Desktop is not running'

$running = Get-Process -Name 'claude' -ErrorAction SilentlyContinue
if ($running) {
    if (-not $CloseDesktop) {
        Write-Host ''
        Write-Host '  Claude Desktop is running.' -ForegroundColor Yellow
        Write-Host '  Its claude.exe cannot be replaced while it is in use.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Close Claude Desktop (all windows + the tray icon) and run this' -ForegroundColor Yellow
        Write-Host '  script again, or re-run it with -CloseDesktop to have this' -ForegroundColor Yellow
        Write-Host '  script close it for you.' -ForegroundColor Yellow
        Write-Host ''
        throw 'Claude Desktop is running; close it (or pass -CloseDesktop) and re-run.'
    }

    Info 'closing Claude Desktop ...'
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    # It may come back on its own (a tray/launcher watchdog).
    $again = Get-Process -Name 'claude' -ErrorAction SilentlyContinue
    if ($again) {
        $again | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
    Ok 'Claude Desktop closed'
} else {
    Ok 'Claude Desktop is not running'
}

# --- compile the shim --------------------------------------------------

Step 'Preparing the shim'

& (Join-Path $here 'build.ps1')

# --- deploy ------------------------------------------------------------

Step 'Deploying'

# Invoke in-process so deployment keeps the current execution policy and
# exceptions propagate directly instead of going through another shell.
$deployArgs = @{}
if ($haveNpm -and -not $SkipLinuxCli) { $deployArgs['FetchLinuxCli'] = $true }
if ($ProxyUrl) { $deployArgs['ProxyUrl'] = $ProxyUrl }

& (Join-Path $here 'redeploy.ps1') @deployArgs
if ($LASTEXITCODE -ne 0) { throw "redeploy.ps1 failed (exit $LASTEXITCODE)" }

# --- closing summary ---------------------------------------------------

Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
Write-Host ''
Info 'Code tab (local sessions): runs your ClawGod-patched claude.cmd.'
Info 'Cowork/workspace bash: needs the VM images from downloads.claude.ai.'
if (-not $ProxyUrl) {
    Info '  If that host is unreachable, run:  .\redeploy.ps1 -ProxyUrl http://127.0.0.1:<port>'
}
Info 'Restart Claude Desktop, then check %LOCALAPPDATA%\Claude-3p\logs\main.log'
Info 'for "executable: ...\claude-code\<version>\...\claude.exe".'
Info 'Run this script again after every Claude Desktop update.'
Write-Host ''

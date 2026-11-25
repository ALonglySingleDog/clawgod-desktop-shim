<#
.SYNOPSIS
    Build ClaudeShim.exe when it is missing or older than ClaudeShim.cs.
.PARAMETER Force
    Rebuild even when the existing executable is up to date.
#>
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'ClaudeShim.cs'
$output = Join-Path $PSScriptRoot 'ClaudeShim.exe'

if (-not (Test-Path -LiteralPath $source)) {
    if (Test-Path -LiteralPath $output) {
        Write-Host "  [ok]   using prebuilt shim: $output" -ForegroundColor Green
        return
    }
    throw "Neither ClaudeShim.cs nor ClaudeShim.exe is present in $PSScriptRoot."
}

if (-not $Force -and (Test-Path -LiteralPath $output) -and
    (Get-Item -LiteralPath $output).LastWriteTimeUtc -ge (Get-Item -LiteralPath $source).LastWriteTimeUtc) {
    Write-Host "  [ok]   shim is up to date: $output" -ForegroundColor Green
    return
}

$csc = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($null -eq $csc) {
    throw 'No C# compiler found (csc.exe). Install .NET Framework 4.x or supply a current ClaudeShim.exe.'
}

# Do not replace a working executable until compilation has succeeded.
$tempOutput = Join-Path $PSScriptRoot ("ClaudeShim-build-" + [guid]::NewGuid().ToString('N') + '.exe')
try {
    Write-Host "  compiling shim with $csc" -ForegroundColor DarkGray
    & $csc -nologo -target:exe -platform:x64 -optimize+ "-out:$tempOutput" $source
    if ($LASTEXITCODE -ne 0) { throw "Shim compilation failed (exit $LASTEXITCODE)." }
    Copy-Item -LiteralPath $tempOutput -Destination $output -Force
    Write-Host "  [ok]   built $output" -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $tempOutput) {
        Remove-Item -LiteralPath $tempOutput -Force
    }
}

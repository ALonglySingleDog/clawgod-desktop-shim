<#
.SYNOPSIS
    Compile and run isolated shim regression tests with .NET Framework 4.x.
    Also check script syntax and the automatic stale-binary rebuild path.
#>
$ErrorActionPreference = 'Stop'

foreach ($script in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1') {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { throw "PowerShell syntax errors in $($script.Name): $($errors -join '; ')" }
}
Write-Host '[pass] PowerShell script syntax'

$csc = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw 'Tests require the .NET Framework C# compiler (csc.exe).' }

$work = Join-Path ([IO.Path]::GetTempPath()) ('claude-shim-test-build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $testExe = Join-Path $work 'ShimTests.exe'
    & $csc -nologo -target:exe -platform:x64 -optimize+ -codepage:65001 -main:ShimTests "-out:$testExe" `
        (Join-Path $PSScriptRoot 'ClaudeShim.cs') (Join-Path $PSScriptRoot 'tests\ShimTests.cs')
    if ($LASTEXITCODE -ne 0) { throw "Test compilation failed (exit $LASTEXITCODE)." }
    & $testExe
    if ($LASTEXITCODE -ne 0) { throw "Shim regression tests failed (exit $LASTEXITCODE)." }

    # Exercise build.ps1 on copies, not the project's/deployed executable.
    $sandbox = Join-Path $work 'build sandbox'
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ClaudeShim.cs'), (Join-Path $PSScriptRoot 'build.ps1') -Destination $sandbox
    $build = Join-Path $sandbox 'build.ps1'
    $output = Join-Path $sandbox 'ClaudeShim.exe'
    $source = Join-Path $sandbox 'ClaudeShim.cs'
    & $build
    if (-not (Test-Path -LiteralPath $output)) { throw 'Build did not create a missing executable.' }
    Write-Host '[pass] build creates a missing executable'

    (Get-Item -LiteralPath $output).LastWriteTimeUtc = (Get-Item -LiteralPath $source).LastWriteTimeUtc.AddMinutes(-1)
    & $build
    if ((Get-Item -LiteralPath $output).LastWriteTimeUtc -lt (Get-Item -LiteralPath $source).LastWriteTimeUtc) {
        throw 'Build reused a stale executable.'
    }
    Write-Host '[pass] build replaces a stale executable'

    $stamp = (Get-Item -LiteralPath $output).LastWriteTimeUtc
    & $build
    if ((Get-Item -LiteralPath $output).LastWriteTimeUtc -ne $stamp) { throw 'Build unnecessarily replaced a current executable.' }
    Write-Host '[pass] build preserves an up-to-date executable'

    $hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
    [IO.File]::WriteAllText($source, 'intentionally invalid C# fixture')
    (Get-Item -LiteralPath $output).LastWriteTimeUtc = (Get-Item -LiteralPath $source).LastWriteTimeUtc.AddMinutes(-1)
    $failed = $false
    try { & $build > $null } catch { $failed = $true }
    if (-not $failed) { throw 'Build did not report a compiler failure.' }
    if ((Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash -ne $hash) { throw 'Compiler failure damaged the previous executable.' }
    Write-Host '[pass] compiler failure preserves the previous executable'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}
Write-Host 'All regression tests passed.' -ForegroundColor Green
exit 0

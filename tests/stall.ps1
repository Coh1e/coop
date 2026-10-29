# Red when: a write command that produces no output for several seconds stops reporting that it is still
# working, or that report leaks into a --json run or a quiet run.
param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test data must stay within the project test directory'
}
$archive = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives/ripgrep-15.2.0-x86_64-pc-windows-msvc.zip'))
if (-not (Test-Path -LiteralPath $archive)) { throw "Missing test archive: $archive" }
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower()
$url = 'file:///' + ($archive -replace '\\', '/')
$root = Join-Path $TestRoot 'stall'
if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
New-Item -ItemType Directory -Path "$root/buckets/probe/bucket" -Force | Out-Null
@"
{
  "version": "1.0",
  "url": "$url",
  "hash": "$hash",
  "extract_dir": "ripgrep-15.2.0-x86_64-pc-windows-msvc",
  "bin": "rg.exe"
}
"@ | Set-Content "$root/buckets/probe/bucket/slow.json" -Encoding utf8 -NoNewline
$previousStall = $env:COOP_TEST_STALL_MS
try {
    $env:COOP_TEST_STALL_MS = '6500'

    # Text mode reports the silence instead of looking frozen.
    $out = & $CoopExe --root $root install probe/slow 2>&1
    if ($LASTEXITCODE -cne 0) { throw "the install failed: $($out -join ' | ')" }
    if (($out -join "`n") -cnotmatch 'coop: still working, \d+s without progress') {
        throw "a silent write command printed no stall report: $($out -join ' | ')"
    }
    & $CoopExe --root $root uninstall slow 2>&1 | Out-Null

    # A --json run stays machine-readable: the report must not appear.
    $out = & $CoopExe --root $root install probe/slow --json 2>&1
    if ($LASTEXITCODE -cne 0) { throw 'the json install failed' }
    if (($out -join "`n") -cmatch 'still working') { throw 'a --json run printed the stall report' }
    & $CoopExe --root $root uninstall slow -q 2>&1 | Out-Null

    # A quiet run suppresses progress, including this report.
    $out = & $CoopExe --root $root install probe/slow -q 2>&1
    if ($LASTEXITCODE -cne 0) { throw 'the quiet install failed' }
    if (($out -join "`n") -cmatch 'still working') { throw 'a quiet run printed the stall report' }
} finally {
    if ($null -eq $previousStall) { Remove-Item Env:\COOP_TEST_STALL_MS -ErrorAction SilentlyContinue }
    else { $env:COOP_TEST_STALL_MS = $previousStall }
}
Write-Output 'PASS: a silent write command reports that it is still working'

# Pre-release gate. Run this before tagging: it builds every target the way CI does, runs the full
# suite, and checks that the binary reports the version being released.
#
# A local `ninja coop` is not enough. v0.2.2 was tagged while the release build failed, because the
# release record had pulled a JSON header into app.hpp and only the `coop` target was ever built
# locally. This script exists so that mistake has to be made twice.
param(
    [Parameter(Mandatory)][string]$Version,
    [switch]$SkipTests,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version '$Version' is not <major>.<minor>.<patch>" }

Push-Location $projectRoot
try {
    $cmake = Get-Content -LiteralPath (Join-Path $projectRoot 'CMakeLists.txt') -Raw -Encoding utf8
    if ($cmake -notmatch 'project\(coop VERSION ([0-9]+\.[0-9]+\.[0-9]+)') { throw 'project version is missing from CMakeLists.txt' }
    if ($Matches[1] -ne $Version) { throw "CMakeLists.txt says $($Matches[1]); the release is $Version" }

    $dirty = @(git status --porcelain)
    if ($dirty.Count) { throw "the working tree is not clean:`n$($dirty -join "`n")" }

    if ((git tag --list "v$Version") -and -not $Force) {
        throw "tag v$Version already exists; pass -Force to re-verify a tagged release"
    }

    # The child scripts write progress to stderr; merging it keeps Windows PowerShell from turning a
    # compiler warning into a terminating error. Only a non-zero exit code fails the gate.
    $hygiene = & (Join-Path $PSScriptRoot 'check-source-hygiene.ps1') 2>&1
    if ($LASTEXITCODE -ne 0) {
        $hygiene | Select-Object -Last 10 | Write-Output
        throw 'source hygiene failed'
    }

    $action = if ($SkipTests) { 'build' } else { 'all' }
    $build = & (Join-Path $PSScriptRoot 'build.ps1') -Action $action 2>&1
    if ($LASTEXITCODE -ne 0) {
        $build | Select-Object -Last 30 | Write-Output
        throw 'build or test run failed'
    }

    $reported = (& (Join-Path $projectRoot '.local/build/coop.exe') --version | Out-String).Trim()
    if ($reported -ne "coop $Version") { throw "the binary reports '$reported', not 'coop $Version'" }

    Write-Output "release check passed: coop $Version builds with every target and passes every test"
} finally {
    Pop-Location
}

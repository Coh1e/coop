# Red when: a forced reinstall stops being resumable after an injected failure at the version publish,
# or the fault file starts working without the engineering token.
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
$root = Join-Path $TestRoot 'force-recovery'
if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
New-Item -ItemType Directory -Path "$root/buckets/probe/bucket" -Force | Out-Null
@"
{
  "version": "1.0",
  "url": "$url",
  "hash": "$hash",
  "extract_dir": "ripgrep-15.2.0-x86_64-pc-windows-msvc",
  "bin": [ [ "rg.exe", "rgforced" ] ]
}
"@ | Set-Content "$root/buckets/probe/bucket/vers.json" -Encoding utf8 -NoNewline
& $CoopExe --root $root install probe/vers | Out-Null
if ($LASTEXITCODE -cne 0) { throw 'the fixture package did not install' }

# A fault file only has an effect when the engineering token is present in the environment.
'{ "fail": ["after-version-publish"] }' | Set-Content "$root/.coop/test-faults.json" -Encoding utf8
$ungated = & $CoopExe --root $root update probe/vers -f 2>&1
if ($LASTEXITCODE -cne 0) { throw "a fault file worked without the token: $($ungated -join ' | ')" }

$previousToken = $env:COOP_ALLOW_TEST_FAULTS
try {
    $env:COOP_ALLOW_TEST_FAULTS = '1'
    $failed = & $CoopExe --root $root update probe/vers -f 2>&1
    if ($LASTEXITCODE -ceq 0) { throw 'the injected failure did not fail the command' }
    if (($failed -join "`n") -cnotmatch 'Injected test fault') { throw "the failure was not the injected one: $($failed -join ' | ')" }

    # The replaced version directory is restored, so the package keeps working without a repair step.
    $listed = @(& $CoopExe --root $root list)
    if (($listed -join "`n") -cnotmatch 'vers\s+1\.0') { throw "the package is gone after the failure: $($listed -join ' | ')" }
    if (-not (Test-Path "$root/apps/vers/1.0")) { throw 'the version directory was not restored' }
    if (-not (Test-Path "$root/apps/vers/current")) { throw 'the current link was not restored' }
    if (-not (Test-Path "$root/shims/rgforced.exe")) { throw 'the command entry was not restored' }
    $recover = @(& $CoopExe --root $root recover)
    if ($LASTEXITCODE -cne 0 -or ($recover -join "`n") -cnotmatch 'No pending transactions') {
        throw "recover reported a pending transaction: $($recover -join ' | ')"
    }

    # With the fault file gone the same forced reinstall completes.
    Remove-Item -LiteralPath "$root/.coop/test-faults.json" -Force
    $healed = & $CoopExe --root $root update probe/vers -f 2>&1
    if ($LASTEXITCODE -cne 0) { throw "the forced reinstall did not recover: $($healed -join ' | ')" }
} finally {
    if ($null -eq $previousToken) { Remove-Item Env:\COOP_ALLOW_TEST_FAULTS -ErrorAction SilentlyContinue }
    else { $env:COOP_ALLOW_TEST_FAULTS = $previousToken }
}
Write-Output 'PASS: a failed forced reinstall restores the version and leaves no pending transaction'

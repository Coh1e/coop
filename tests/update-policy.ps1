# Red when: status, preview or real update misclassifies eligibility, or a protected update changes installed files.
param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null
function Manifest([string]$version,[string]$payload) {
    $source = Join-Path (Split-Path $CoopExe) "fixture-$payload.exe"
    @{version=$version;url=([Uri][IO.Path]::GetFullPath($source)).AbsoluteUri+'#/fixture.exe';hash=(Get-FileHash $source -Algorithm SHA256).Hash.ToLower();bin='fixture.exe'} | ConvertTo-Json | Set-Content "$root/buckets/test/bucket/fixture.json" -Encoding utf8
}
Manifest '2' '1'
$null = & $CoopExe --root $root install test/fixture --json
if ($LASTEXITCODE -ne 0) { throw 'Fixture install failed' }
Manifest '2' '2'
$before = (Get-FileHash "$root/apps/fixture/current/scoop-manifest.json").Hash
$result = Invoke-CoopNative $CoopExe --root $root update fixture --json
if ($LASTEXITCODE -ne 0 -or (Get-FileHash "$root/apps/fixture/current/scoop-manifest.json").Hash -ne $before -or (& "$root/shims/fixture.exe") -ne 'fixture 1') { throw 'Same-version manifest change must not reinstall without force' }
function ExpectDecision([string]$state,[bool]$blocked) {
    $status = & $CoopExe --root $root status -l --json=2 | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $status.apps[0].data.update_state -ne $state) { throw "Status decision differs: $state" }
    foreach ($force in @($false,$true)) {
        if ($force -and -not $blocked) { continue }
        $arguments = @('--root',$root,'update','fixture','--dry-run','--json')
        if ($force) { $arguments += '--force' }
        $preview = Invoke-CoopNativeRaw -Exe $CoopExe -Arguments $arguments
        $plan = $preview.out | ConvertFrom-Json
        $expectedCode = if ($blocked) { 1 } else { 0 }
        if ($plan.update_decision.state -ne $state -or $plan.update_decision.blocked -ne $blocked -or $preview.code -ne $expectedCode) { throw "Preview decision differs: $state" }
    }
}
ExpectDecision 'manifest-changed' $false
$result = & $CoopExe --root $root update fixture --force --json
if ($LASTEXITCODE -ne 0 -or (& "$root/shims/fixture.exe") -ne 'fixture 2') { throw 'Force did not reinstall same version' }
ExpectDecision 'current' $false
$before = (Get-FileHash "$root/apps/fixture/current/scoop-manifest.json").Hash
$candidate = Get-Content "$root/buckets/test/bucket/fixture.json" -Raw | ConvertFrom-Json
$candidate | Add-Member -NotePropertyName persist -NotePropertyValue 'changed-data'
$candidate | ConvertTo-Json | Set-Content "$root/buckets/test/bucket/fixture.json" -Encoding utf8
ExpectDecision 'manifest-changed' $false
$result = Invoke-CoopNativeRaw -Exe $CoopExe -Arguments @('--root',$root,'update','fixture','--json')
if ($result.code -ne 0 -or (Get-FileHash "$root/apps/fixture/current/scoop-manifest.json").Hash -ne $before -or (Test-Path "$root/persist/fixture")) { throw 'No-op must not require or perform a persistence migration' }
foreach ($target in @('1','nightly')) {
    Manifest $target '1'
    $state = if ($target -eq '1') { 'downgrade-blocked' } else { 'version-incomparable' }
    ExpectDecision $state $true
    foreach ($force in @($false,$true)) {
        $arguments = @('--root',$root,'update','fixture','--json')
        if ($force) { $arguments += '--force' }
        $result = Invoke-CoopNative $CoopExe @arguments
        if ($LASTEXITCODE -ne 1 -or (Get-FileHash "$root/apps/fixture/current/scoop-manifest.json").Hash -ne $before -or (& "$root/shims/fixture.exe") -ne 'fixture 2') { throw 'Protected update modified installation' }
    }
}
Manifest '3' '1'
ExpectDecision 'update-available' $false
$null = & $CoopExe --root $root hold fixture
if ($LASTEXITCODE -ne 0) { throw 'Hold failed' }
ExpectDecision 'held-package' $true
$result = Invoke-CoopNative $CoopExe --root $root update fixture --force --json
if ($LASTEXITCODE -ne 1 -or (& "$root/shims/fixture.exe") -ne 'fixture 2') { throw 'Force bypassed hold' }
$null = & $CoopExe --root $root unhold fixture
$null = & $CoopExe --root $root update fixture --json
if ($LASTEXITCODE -ne 0 -or (& "$root/shims/fixture.exe") -ne 'fixture 1') { throw 'Higher version did not update actual files' }
# install remains an explicit install operation, including selecting another locally available version.
Manifest '1' '2'
$null = & $CoopExe --root $root install test/fixture --json
if ($LASTEXITCODE -ne 0 -or (& "$root/shims/fixture.exe") -ne 'fixture 2') { throw 'Update policy unexpectedly changed install semantics' }
Write-Output 'PASS update policy'

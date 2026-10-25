param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$fixture1 = Join-Path (Split-Path $CoopExe) 'fixture-1.exe'
$fixture2 = Join-Path (Split-Path $CoopExe) 'fixture-2.exe'
foreach ($path in @($fixture1,$fixture2)) { if (-not (Test-Path -LiteralPath $path)) { throw "Missing fixed test input: $path" } }
function New-TestRoot {
    $root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path "$root/buckets/test/bucket","$root/buckets/main/bucket","$root/buckets/other/bucket" -Force | Out-Null
    return $root
}
function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
function Write-Manifest([string]$root,[string]$bucket,[string]$name,[string]$version,[string]$source,[string]$bin,[object]$depends) {
    $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLower()
    $manifest = @{version=$version;url=(File-Uri $source)+'#/'+$bin;hash=$hash;bin=$bin}
    if ($null -ne $depends) { $manifest.depends = $depends }
    [IO.File]::WriteAllText("$root/buckets/$bucket/bucket/$name.json",($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
function Assert-Exit([string]$message) { if ($LASTEXITCODE -ne 0) { throw $message } }
function Read-Json([object]$output) { return (($output -join "`n") | ConvertFrom-Json) }
function Assert-Runs([string]$path,[string]$expected) {
    if (-not (Test-Path -LiteralPath $path)) { throw "missing program $path" }
    $output = ((& $path) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or $output -ne $expected) { throw "program $path printed '$output' (wanted '$expected')" }
}
$root = New-TestRoot

# Real Main/wget declares depends: cacert. The dependency order is planned before any product state exists.
Write-Manifest $root 'main' 'cacert' '1' $fixture1 'cacert.exe' $null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'corpus/main/wget.json') -Destination "$root/buckets/main/bucket/wget.json"
$preview = & $CoopExe --root $root install main/wget --dry-run --json
Assert-Exit 'real Main/wget dependency preview failed'
$wget = Read-Json $preview
if ('cacert' -notin @($wget.package.dependencies)) { throw 'real Manifest dependency was not disclosed' }
$order = @($wget.dependency_order)
if ($order.Count -ne 2 -or $order[0].package -ne 'cacert' -or $order[0].status -ne 'planned' -or
    $order[1].package -ne 'wget' -or $order[1].status -ne 'planned') { throw 'real dependency order is wrong' }
if (@($wget.diagnostics | Where-Object code -eq 'dependency-missing').Count) { throw 'available cacert dependency was reported missing' }
if ((Test-Path "$root/apps") -or (Test-Path "$root/shims") -or (Test-Path "$root/.coop")) { throw 'dependency preview changed product state' }
$wgetInstall = & $CoopExe --root $root install main/wget --json 2>&1
if ($LASTEXITCODE -eq 0 -or (Test-Path "$root/apps/cacert") -or (Test-Path "$root/apps/wget")) { throw 'unsupported real package installed its dependency before refusing the root' }

Write-Manifest $root 'test' 'base' '1' $fixture1 'base.exe' $null
Write-Manifest $root 'test' 'leaf' '1' $fixture2 'leaf.exe' 'base'
Write-Manifest $root 'test' 'leaf2' '1' $fixture2 'leaf2.exe' 'base'
Write-Manifest $root 'test' 'ind' '1' $fixture1 'ind.exe' $null
Write-Manifest $root 'test' 'missing' '1' $fixture1 'missing.exe' 'ghost'
Write-Manifest $root 'test' 'cyclea' '1' $fixture1 'cyclea.exe' 'cycleb'
Write-Manifest $root 'test' 'cycleb' '1' $fixture2 'cycleb.exe' 'cyclea'
Write-Manifest $root 'test' 'versiondep' '1' $fixture1 'versiondep.exe' 'base@1'
Write-Manifest $root 'test' 'dup' '1' $fixture1 'dup.exe' $null
Write-Manifest $root 'other' 'dup' '1' $fixture1 'dup.exe' $null
Write-Manifest $root 'test' 'amb' '1' $fixture1 'amb.exe' 'dup'
$scriptHash = (Get-FileHash -LiteralPath $fixture1 -Algorithm SHA256).Hash.ToLower()
$scriptManifest = @{version='1';url=(File-Uri $fixture1)+'#/scriptdep.exe';hash=$scriptHash;bin='scriptdep.exe';post_install='Write-Output dependency-script'} | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText("$root/buckets/test/bucket/scriptdep.json",$scriptManifest,[Text.UTF8Encoding]::new($false))
Write-Manifest $root 'test' 'needsscript' '1' $fixture1 'needsscript.exe' 'scriptdep'

# A dependency is installed first in its own transaction, then the requested package is published.
$preview = & $CoopExe --root $root install leaf --dry-run --json
Assert-Exit 'dependency install preview failed'
$leafPreview = Read-Json $preview
if (-not $leafPreview.execution_available) { throw 'preview did not consider planned dependencies executable' }
$order = @($leafPreview.dependency_order)
if ($order.Count -ne 2 -or $order[0].package -ne 'base' -or $order[1].package -ne 'leaf') { throw 'preview dependency order is wrong' }
if ('base' -notin @($leafPreview.planned_dependencies) -or 'leaf' -notin @($leafPreview.planned_dependencies)) { throw 'preview omitted planned packages' }
if ((Test-Path "$root/apps") -or (Test-Path "$root/shims") -or (Test-Path "$root/.coop")) { throw 'dependency preview changed product state' }
$install = & $CoopExe --root $root install leaf --json
Assert-Exit "dependency install failed: $($install -join "`n")"
$result = Read-Json $install
$packages = @($result.packages)
if ($result.status -ne 'success' -or $packages.Count -ne 2) { throw 'dependency install result is incomplete' }
if ($packages[0].package -ne 'base' -or $packages[0].status -ne 'success' -or $packages[0].requested -ne $false) { throw 'dependency was not installed first' }
if ($packages[1].package -ne 'leaf' -or $packages[1].status -ne 'success' -or $packages[1].requested -ne $true) { throw 'requested package result is wrong' }
if ($result.transaction_scope -notlike 'per-package*') { throw 'dependency install claimed a global transaction' }
Assert-Runs "$root/shims/base.exe" 'fixture 1'
Assert-Runs "$root/shims/leaf.exe" 'fixture 2'
$leafRecord = Get-Content -LiteralPath "$root/.coop/packages/leaf.json" -Raw | ConvertFrom-Json
if ('base' -notin @($leafRecord.dependencies)) { throw 'management record omitted the declared dependency' }

# An already installed dependency is skipped, not reinstalled, and the dependent still installs.
$skip = & $CoopExe --root $root install leaf2 --json
Assert-Exit 'install with an already installed dependency failed'
$skipResult = Read-Json $skip
$skipPackages = @($skipResult.packages)
if ($skipPackages.Count -ne 2 -or $skipPackages[0].package -ne 'base' -or $skipPackages[0].status -ne 'skipped' -or
    $skipPackages[0].reason -ne 'already-installed' -or $skipPackages[1].status -ne 'success') { throw 'installed dependency was not reported as skipped' }
Assert-Runs "$root/shims/base.exe" 'fixture 1'
Assert-Runs "$root/shims/leaf2.exe" 'fixture 2'

# A batch reports every requested package; a later failure does not roll back an earlier success.
$batch = & $CoopExe --root $root install ind leaf --json
if ($LASTEXITCODE -eq 0) { throw 'batch with an already installed request unexpectedly succeeded' }
$batchResult = Read-Json $batch
$batchItems = @($batchResult)
if ($batchItems.Count -ne 2 -or $batchItems[0].package -ne 'ind' -or $batchItems[0].status -ne 'success' -or
    $batchItems[1].package -ne 'leaf' -or $batchItems[1].status -ne 'failed' -or
    $batchItems[1].reason -notmatch 'already exists') { throw 'batch did not report per-package success and failure' }
if ($batchItems[0].transaction_scope -notlike 'per-package*' -or $batchItems[1].transaction_scope -notlike 'per-package*') { throw 'batch claimed a global transaction' }
Assert-Runs "$root/shims/ind.exe" 'fixture 1'
Assert-Runs "$root/shims/leaf.exe" 'fixture 2'

# Missing, circular and ambiguous dependencies are explicit failures before any product state changes.
$missing = & $CoopExe --root $root install missing --dry-run --json
if ($LASTEXITCODE -eq 0 -or ($missing -join "`n") -notmatch 'dependency-missing' -or ($missing -join "`n") -notmatch 'ghost') { throw 'missing dependency was not reported' }
if (Test-Path "$root/apps/missing") { throw 'missing dependency preview wrote product state' }
$missingInstall = & $CoopExe --root $root install missing --json 2>&1
if ($LASTEXITCODE -eq 0 -or (Test-Path "$root/apps/missing") -or (Test-Path "$root/shims/missing.exe")) { throw 'missing dependency install was not refused' }
$cycle = & $CoopExe --root $root install cyclea --dry-run --json
if ($LASTEXITCODE -eq 0 -or ($cycle -join "`n") -notmatch 'dependency-cycle' -or ($cycle -join "`n") -notmatch 'Circular dependency') { throw 'circular dependency was not reported' }
if (Test-Path "$root/apps/cyclea") { throw 'circular dependency preview wrote product state' }
$cycleInstall = & $CoopExe --root $root install cyclea --json 2>&1
if ($LASTEXITCODE -eq 0 -or (Test-Path "$root/apps/cyclea")) { throw 'circular dependency install was not refused' }
$ambiguous = & $CoopExe --root $root install amb --dry-run --json
if ($LASTEXITCODE -eq 0 -or ($ambiguous -join "`n") -notmatch 'dependency-ambiguous' -or
    ($ambiguous -join "`n") -notmatch 'other' -or ($ambiguous -join "`n") -notmatch 'test') { throw 'ambiguous dependency was not reported with its buckets' }
$versioned = & $CoopExe --root $root install versiondep --dry-run --json
if ($LASTEXITCODE -eq 0 -or ($versioned -join "`n") -notmatch 'dependency-version') { throw 'version-constrained dependency was not refused explicitly' }
$unsupported = & $CoopExe --root $root install needsscript --dry-run --json
if ($LASTEXITCODE -eq 0 -or ($unsupported -join "`n") -notmatch 'dependency-unsupported' -or ($unsupported -join "`n") -notmatch 'script') { throw 'unsupported dependency was not refused with a capability diagnostic' }
if (Test-Path "$root/apps/needsscript") { throw 'unsupported dependency preview wrote product state' }
Write-Manifest $root 'other' 'base' '1' $fixture1 'base.exe' $null
Write-Manifest $root 'test' 'conflict' '1' $fixture1 'conflict.exe' 'other/base'
$sourceConflict = & $CoopExe --root $root install conflict --dry-run --json
if ($LASTEXITCODE -eq 0 -or ($sourceConflict -join "`n") -notmatch 'dependency-bucket-conflict' -or ($sourceConflict -join "`n") -notmatch 'other') { throw 'installed dependency from a conflicting source was not reported' }

# Update preview checks the new Manifest against actually installed dependencies.
Rename-Item -LiteralPath "$root/apps/base" -NewName 'base-hidden'
$update = & $CoopExe --root $root update leaf --dry-run --json
if ($LASTEXITCODE -eq 0 -or ($update -join "`n") -notmatch 'dependency-missing' -or ($update -join "`n") -notmatch 'base') { throw 'update did not detect a missing declared dependency' }
Rename-Item -LiteralPath "$root/apps/base-hidden" -NewName 'base'
$update = & $CoopExe --root $root update leaf --dry-run --json
Assert-Exit 'update preview failed after restoring the dependency'
$updatePlan = Read-Json $update
if (@($updatePlan.dependency_order | Where-Object { $_.package -eq 'base' -and $_.status -eq 'satisfied' }).Count -ne 1) { throw 'update preview omitted the satisfied dependency' }

# Known dependents, including unadopted installations, block uninstall; unreadable evidence is not treated as no dependency.
New-Item -ItemType Directory -Path "$root/apps/legacy/current" -Force | Out-Null
Copy-Item -LiteralPath "$root/buckets/test/bucket/leaf.json" -Destination "$root/apps/legacy/current/scoop-manifest.json"
'{"bucket":"test","architecture":"64bit"}' | Set-Content -LiteralPath "$root/apps/legacy/current/scoop-install.json" -Encoding utf8
New-Item -ItemType Directory -Path "$root/apps/mystery/current" -Force | Out-Null
'{' | Set-Content -LiteralPath "$root/apps/mystery/current/scoop-manifest.json" -Encoding utf8
'{"bucket":"test","architecture":"64bit"}' | Set-Content -LiteralPath "$root/apps/mystery/current/scoop-install.json" -Encoding utf8
$blocked = & $CoopExe --root $root uninstall base --dry-run --json
if ($LASTEXITCODE -eq 0) { throw 'blocked uninstall preview unexpectedly succeeded' }
$blockedPlan = Read-Json $blocked
foreach ($dependent in @('leaf','leaf2','legacy')) { if ($dependent -notin @($blockedPlan.blocking_dependents)) { throw "uninstall did not list dependent $dependent" } }
if ('user/mystery' -notin @($blockedPlan.unverified_dependents)) { throw 'unreadable dependency evidence was treated as no dependency' }
if ('blocked-by-dependents' -notin @($blockedPlan.diagnostics.code) -or 'dependency-evidence-incomplete' -notin @($blockedPlan.diagnostics.code)) { throw 'uninstall protection diagnostics are incomplete' }
$blockedInstall = & $CoopExe --root $root uninstall base --json 2>&1
if ($LASTEXITCODE -eq 0) { throw 'blocked uninstall was executed' }
Assert-Runs "$root/shims/base.exe" 'fixture 1'
Assert-Runs "$root/shims/leaf.exe" 'fixture 2'
Remove-Item -LiteralPath "$root/apps/mystery" -Recurse -Force
Remove-Item -LiteralPath "$root/apps/legacy" -Recurse -Force

# Uninstalling dependents is a per-package batch; the shared dependency is retained, never autoremoved.
$remove = & $CoopExe --root $root uninstall leaf leaf2 --json
Assert-Exit "dependent batch uninstall failed: $($remove -join "`n")"
$removeResult = @(Read-Json $remove)
if ($removeResult.Count -ne 2 -or $removeResult[0].status -ne 'success' -or $removeResult[1].status -ne 'success') { throw 'dependent batch uninstall did not report both packages' }
if (Test-Path "$root/shims/leaf.exe") { throw 'batch uninstall left a dependent entry' }
Assert-Runs "$root/shims/base.exe" 'fixture 1'
$baseRecord = Get-Content -LiteralPath "$root/.coop/packages/base.json" -Raw | ConvertFrom-Json
if ($baseRecord.status -ne 'ready') { throw 'retained dependency lost its management record' }
$list = @(Read-Json (& $CoopExe --root $root list --json))
if (@($list | Where-Object { $_.name -eq 'base' -and $_.management -eq 'managed' }).Count -ne 1) { throw 'retained dependency disappeared from list' }
$removeBase = & $CoopExe --root $root uninstall base --json
Assert-Exit 'dependency uninstall failed after dependents were removed'
if (Test-Path "$root/shims/base.exe") { throw 'dependency entry remained after explicit uninstall' }

# A batch uninstall continues after one package fails and reports an accurate overall result.
$partial = & $CoopExe --root $root uninstall ghostpkg ind --json
if ($LASTEXITCODE -eq 0) { throw 'batch uninstall with a missing package unexpectedly succeeded' }
$partialResult = @(Read-Json $partial)
if ($partialResult.Count -ne 2 -or $partialResult[0].package -ne 'ghostpkg' -or $partialResult[0].status -ne 'failed' -or
    $partialResult[1].package -ne 'ind' -or $partialResult[1].status -ne 'success') { throw "batch uninstall did not report per-package failure and success (exit $LASTEXITCODE): $($partial -join "`n")" }
if (Test-Path "$root/shims/ind.exe") { throw 'successful batch entry was not removed' }

@{coop=$CoopExe;root=$root;fixed_wget_manifest=(Join-Path $PSScriptRoot 'corpus/main/wget.json')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $TestRoot 'dependencies-evidence.json') -Encoding utf8
Write-Output "PASS dependency install order, batch outcomes and reverse dependency protection: $TestRoot"
exit 0

param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$fixture1 = Join-Path (Split-Path $CoopExe) 'fixture-1.exe'
$fixture2 = Join-Path (Split-Path $CoopExe) 'fixture-2.exe'
foreach ($path in @($fixture1,$fixture2)) { if (-not (Test-Path -LiteralPath $path)) { throw "Missing fixed test input: $path" } }
# The five real Main/Extras packages whose declared dependency lives in the official Versions
# bucket. The fixture reproduces their exact dependency identities (bucket-qualified, unqualified
# and version-looking package names) with local artifacts so the cross-bucket resolver can be
# exercised without network access or the real shared root.
$versionsPackages = @('main/buck','main/glslviewer','main/terraform-provider-ibm','extras/node-compiler','extras/rabbitmqadmin')
function New-TestRoot([string[]]$Buckets) {
    $root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
    $paths = @($Buckets | ForEach-Object { "$root/buckets/$_/bucket" })
    New-Item -ItemType Directory -Path $paths -Force | Out-Null
    return $root
}
function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
function Write-Manifest([string]$root,[string]$bucket,[string]$name,[string]$version,[string]$source,[string]$bin,[object]$depends) {
    $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLower()
    $manifest = @{version=$version;url=(File-Uri $source)+'#/'+$bin;hash=$hash;bin=$bin}
    if ($null -ne $depends) { $manifest.depends = $depends }
    [IO.File]::WriteAllText("$root/buckets/$bucket/bucket/$name.json",($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
function Read-Json([object]$output) { return (($output -join "`n") | ConvertFrom-Json) }
function CoopPlan([string]$root,[string]$id) {
    $text = & $CoopExe --root $root --arch 64bit install $id --dry-run --json 2>$null
    $exit = $LASTEXITCODE
    return [pscustomobject]@{ exit=$exit; plan=(Read-Json $text); text=($text -join "`n") }
}
function Assert-VersionsDependency([object]$plan,[string]$id,[string]$dependency,[string]$bucket,[string]$version) {
    $order = @($plan.dependency_order)
    $requested = $order[-1]
    if ($requested.package -ne ($id -split '/')[1] -or $requested.requested -ne $true) { throw "$id preview did not place the requested package last in dependency_order" }
    $matches = @($order | Where-Object { $_.package -eq $dependency })
    if ($matches.Count -ne 1) { throw "$id preview has $($matches.Count) '$dependency' entries in dependency_order; expected exactly one" }
    $entry = $matches[0]
    if ($entry.bucket -ne $bucket -or $entry.version -ne $version -or $entry.status -ne 'planned' -or $entry.installed -ne $false) {
        throw "$id preview resolved '$dependency' as bucket=$($entry.bucket) version=$($entry.version) status=$($entry.status); expected $bucket@$version planned"
    }
    if (@($entry.ir_operations).Count -eq 0) { throw "$id preview did not plan the operations of '$dependency'" }
    $dependencyIndex = [array]::IndexOf(@($order | ForEach-Object package),$dependency)
    if ($dependencyIndex -ge $order.Count - 1) { throw "$dependency is not planned before the requested package $id" }
    if (@($plan.diagnostics | Where-Object { $_.code -eq 'dependency-missing' }).Count) { throw "$id reported an available versions dependency as missing" }
    return $entry
}

$root = New-TestRoot @('main','extras','versions')
# The official Versions manifests for these packages are plain archives with a command entry; the
# fixture keeps that shape and only replaces the artifact with a local program.
Write-Manifest $root 'versions' 'python27' '2.7.18' $fixture1 'python.exe' $null
Write-Manifest $root 'versions' 'ffmpeg-shared-4.4.1' '4.4.1' $fixture2 'ffmpeg.exe' $null
Write-Manifest $root 'versions' 'terraform011' '0.11.15' $fixture1 'terraform.exe' $null
Write-Manifest $root 'main' 'buck' '2021.01.12.01' $fixture2 'buck.exe' 'versions/python27'
Write-Manifest $root 'main' 'glslviewer' '3.5.2' $fixture1 'glslviewer.exe' 'versions/ffmpeg-shared-4.4.1'
Write-Manifest $root 'main' 'terraform-provider-ibm' '2.8.0' $fixture2 'terraform-provider-ibm.exe' 'versions/terraform011'
Write-Manifest $root 'extras' 'squashfs-tools' '43' $fixture1 'mksquashfs.exe' $null
Write-Manifest $root 'extras' 'node-compiler' '1.5.0' $fixture2 'nodec.exe' @('versions/python27','extras/squashfs-tools')
Write-Manifest $root 'extras' 'rabbitmqadmin' '3.8.9' $fixture1 'rabbitmqadmin.ps1' 'python27'

# Every real package form is planned through the versions bucket: the bucket-qualified names of
# buck/glslviewer/terraform-provider-ibm/node-compiler and the unqualified 'python27' that
# rabbitmqadmin relies on (resolved uniquely from the versions bucket, as Scoop does).
$expected = @{
    'main/buck' = @('python27','versions','2.7.18')
    'main/glslviewer' = @('ffmpeg-shared-4.4.1','versions','4.4.1')
    'main/terraform-provider-ibm' = @('terraform011','versions','0.11.15')
    'extras/node-compiler' = @('python27','versions','2.7.18')
    'extras/rabbitmqadmin' = @('python27','versions','2.7.18')
}
foreach ($id in $versionsPackages) {
    $preview = CoopPlan $root $id
    if ($preview.exit -ne 0) { throw "$id preview failed: $($preview.text)" }
    if (-not $preview.plan.execution_available) { throw "$id preview was not executable with the versions bucket registered" }
    $spec = $expected[$id]
    $entry = Assert-VersionsDependency $preview.plan $id $spec[0] $spec[1] $spec[2]
    if ($entry.request -ne ("{0}/{1}" -f $spec[1],$spec[0])) { throw "$id reported request '$($entry.request)' instead of the resolved $($spec[1])/$($spec[0])" }
    if ((Test-Path "$root/apps") -or (Test-Path "$root/shims") -or (Test-Path "$root/.coop")) { throw "$id dependency preview changed product state" }
}
$nodeOrder = @((CoopPlan $root 'extras/node-compiler').plan.dependency_order | ForEach-Object package)
if (($nodeOrder -join ',') -ne 'python27,squashfs-tools,node-compiler') { throw "transitive cross-bucket order is wrong: $($nodeOrder -join ',')" }

# An installed versions dependency is reused instead of downloaded and installed again, and it
# keeps the position it must have: before the requested package.
$installDependency = & $CoopExe --root $root install versions/python27 --json
if ($LASTEXITCODE -ne 0) { throw "installing the versions dependency failed: $($installDependency -join "`n")" }
$recordPath = "$root/.coop/packages/python27.json"
$recordBefore = (Get-FileHash -LiteralPath $recordPath -Algorithm SHA256).Hash
$reusePreview = CoopPlan $root 'main/buck'
if ($reusePreview.exit -ne 0) { throw "reuse preview failed: $($reusePreview.text)" }
$reuse = @($reusePreview.plan.dependency_order)
$reused = $reuse[0]
if ($reused.package -ne 'python27' -or $reused.installed -ne $true -or $reused.status -ne 'satisfied' -or
    $reused.installed_bucket -ne 'versions' -or $reused.installed_version -ne '2.7.18' -or
    @($reused.ir_operations).Count -ne 0) { throw 'installed versions dependency was not reused with its source and version' }
if ('python27' -in @($reusePreview.plan.planned_dependencies)) { throw 'reuse preview still planned to install the satisfied dependency' }
if ($reuse[1].package -ne 'buck' -or $reuse[1].status -ne 'planned' -or @($reuse[1].ir_operations).Count -eq 0) { throw 'reuse preview lost the requested package plan' }
$reuseInstall = & $CoopExe --root $root install main/buck --json
if ($LASTEXITCODE -ne 0) { throw "install with a reused versions dependency failed: $($reuseInstall -join "`n")" }
$reuseResult = Read-Json $reuseInstall
$reusePackages = @($reuseResult.packages)
if ($reusePackages.Count -ne 2 -or $reusePackages[0].package -ne 'python27' -or $reusePackages[0].status -ne 'skipped' -or
    $reusePackages[0].reason -ne 'already-installed' -or $reusePackages[1].status -ne 'success') {
    throw 'the satisfied versions dependency was not reported as skipped/already-installed'
}
if ((Get-FileHash -LiteralPath $recordPath -Algorithm SHA256).Hash -ne $recordBefore) { throw 'the reused versions dependency record was rewritten' }
foreach ($program in @(@('python.exe','fixture 1'),@('buck.exe','fixture 2'))) {
    $path = "$root/shims/$($program[0])"
    $output = ((& $path) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or $output -ne $program[1]) { throw "$($program[0]) printed '$output' after the dependency install" }
}

# A dependency installed from another bucket keeps conflicting with the explicit versions source.
$conflictRoot = New-TestRoot @('main','versions')
Write-Manifest $conflictRoot 'versions' 'python27' '2.7.18' $fixture1 'python.exe' $null
Write-Manifest $conflictRoot 'main' 'python27' '2.7.18' $fixture2 'python.exe' $null
Write-Manifest $conflictRoot 'main' 'needsversions' '1' $fixture1 'needsversions.exe' 'versions/python27'
$mainInstall = & $CoopExe --root $conflictRoot install main/python27 --json
if ($LASTEXITCODE -ne 0) { throw "installing the same package from main failed: $($mainInstall -join "`n")" }
$conflict = CoopPlan $conflictRoot 'main/needsversions'
if ($conflict.exit -eq 0) { throw 'preview accepted an installed dependency from a different bucket than versions' }
if ($conflict.plan.execution_available -ne $false -or @($conflict.plan.diagnostics | Where-Object code -eq 'dependency-bucket-conflict').Count -eq 0) {
    throw 'cross-bucket installed conflict was not reported as dependency-bucket-conflict'
}

# Without the versions bucket the same manifests report the missing source. Repeated identical
# declarations are reported once, and each distinct missing source keeps its own diagnostic.
$absentRoot = New-TestRoot @('main','extras')
Write-Manifest $absentRoot 'main' 'buck' '2021.01.12.01' $fixture2 'buck.exe' 'versions/python27'
Write-Manifest $absentRoot 'extras' 'squashfs-tools' '43' $fixture1 'mksquashfs.exe' $null
Write-Manifest $absentRoot 'extras' 'node-compiler' '1.5.0' $fixture2 'nodec.exe' @('versions/python27','extras/squashfs-tools')
Write-Manifest $absentRoot 'extras' 'repeatedmissing' '1' $fixture1 'repeatedmissing.exe' @('versions/absent-tool','versions/absent-tool')
$absent = CoopPlan $absentRoot 'main/buck'
if ($absent.exit -eq 0 -or $absent.plan.execution_available -ne $false) { throw 'preview without the versions bucket unexpectedly succeeded' }
$absentDiagnostics = @($absent.plan.diagnostics | Where-Object code -eq 'dependency-missing')
if ($absentDiagnostics.Count -ne 1 -or $absentDiagnostics[0].message -notmatch 'versions/python27') {
    throw "missing versions dependency was reported $($absentDiagnostics.Count) times instead of once with its source"
}
$repeated = CoopPlan $absentRoot 'extras/repeatedmissing'
$repeatedDiagnostics = @($repeated.plan.diagnostics | Where-Object code -eq 'dependency-missing')
if ($repeated.exit -eq 0 -or $repeatedDiagnostics.Count -ne 1) {
    throw "a dependency declared twice was reported $($repeatedDiagnostics.Count) times instead of one deduplicated diagnostic"
}
if ($repeatedDiagnostics[0].message -notmatch 'versions/absent-tool') { throw 'deduplicated diagnostic lost the declared source identity' }
$absentNode = CoopPlan $absentRoot 'extras/node-compiler'
$absentCodes = @($absentNode.plan.diagnostics | Where-Object code -eq 'dependency-missing')
if ($absentNode.exit -eq 0 -or $absentCodes.Count -ne 1 -or $absentCodes[0].message -notmatch 'versions/python27' -or
    $absentCodes[0].message -match 'squashfs-tools') { throw 'only the unavailable versions source should be reported missing' }

Write-Output "PASS versions bucket dependency source: $($versionsPackages -join ', ')"

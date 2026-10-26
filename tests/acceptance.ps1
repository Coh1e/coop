param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$buildDirectory = Split-Path $CoopExe
$guard = Join-Path $buildDirectory 'process_guard.exe'
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$shimSource = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-fixtures/scoop-shim-kiennq.exe'))
$jq17 = Join-Path $archives 'jq-1.7.1-windows-amd64.exe'
$jq18 = Join-Path $archives 'jq-1.8.2-windows-amd64.exe'
$nodeArchive = Join-Path $archives 'node-v26.12.1-win-x64.7z'
$ripgrepArchive = Join-Path $archives 'ripgrep-15.2.0-x86_64-pc-windows-msvc.zip'
foreach ($required in @($guard,$shimSource,$jq17,$jq18,$nodeArchive,$ripgrepArchive)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing fixed acceptance input: $required; run scripts/fetch-deps.ps1" }
}
if ((Get-FileHash -LiteralPath $shimSource -Algorithm SHA256).Hash.ToLower() -ne '140e3801d8adeda639a21b14e62b93a4c7d26b7a758421f43c82be59753be49b') {
    throw 'Unverified original Scoop test shim'
}

function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
function Write-JsonFile([string]$path,[object]$value) {
    [IO.File]::WriteAllText($path,($value | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}
function Read-JsonFile([string]$path) { return [IO.File]::ReadAllText($path) | ConvertFrom-Json }
function Convert-JsonOutput([string]$text,[string]$label) {
    if (-not $text.Trim()) { throw "$label returned no JSON output" }
    try { return $text | ConvertFrom-Json } catch { throw "$label returned invalid JSON: $_`n$text" }
}
function Invoke-Coop([string[]]$arguments) {
    $errorFile = Join-Path $TestRoot ('coop-stderr-'+[guid]::NewGuid().ToString('N')+'.log')
    $output = & $CoopExe @arguments 2> $errorFile
    $exit = $LASTEXITCODE
    $errorText = if (Test-Path -LiteralPath $errorFile) { Get-Content -LiteralPath $errorFile -Raw } else { '' }
    Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    return @{exit=$exit; text=($output -join "`n"); error=$errorText}
}
function Invoke-Guarded([string]$label,[string[]]$arguments,[int]$timeoutMilliseconds = 180000,[bool]$allowChildren = $false) {
    $errorFile = Join-Path $TestRoot ('guard-'+$label+'-'+[guid]::NewGuid().ToString('N')+'.log')
    $previousTimeout = $env:COOP_PROCESS_GUARD_TIMEOUT_MS
    $previousAllowChildren = $env:COOP_PROCESS_GUARD_ALLOW_CHILDREN
    $env:COOP_PROCESS_GUARD_TIMEOUT_MS = [string]$timeoutMilliseconds
    if ($allowChildren) { $env:COOP_PROCESS_GUARD_ALLOW_CHILDREN = '1' }
    $guardArguments = @($CoopExe)+$arguments
    try { $output = & $guard @guardArguments 2> $errorFile; $exit = $LASTEXITCODE }
    finally {
        if ($null -eq $previousTimeout) { Remove-Item Env:COOP_PROCESS_GUARD_TIMEOUT_MS -ErrorAction SilentlyContinue }
        else { $env:COOP_PROCESS_GUARD_TIMEOUT_MS = $previousTimeout }
        if ($null -eq $previousAllowChildren) { Remove-Item Env:COOP_PROCESS_GUARD_ALLOW_CHILDREN -ErrorAction SilentlyContinue }
        else { $env:COOP_PROCESS_GUARD_ALLOW_CHILDREN = $previousAllowChildren }
    }
    $guardText = if (Test-Path -LiteralPath $errorFile) { Get-Content -LiteralPath $errorFile -Raw } else { '' }
    Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    $workloads = @($guardText -split "`r?`n" | Where-Object { $_ -match '^Workload process: (.+)$' } |
        ForEach-Object { $Matches[1].Trim() })
    return @{exit=$exit; text=($output -join "`n"); error=$guardText; workloads=$workloads}
}
function Assert-Exit([int]$exit,[int]$expected,[string]$message,[string]$text = '') {
    if ($exit -ne $expected) { throw "$message (exit $exit, expected $expected): $text" }
}
function Assert-Equal($expected,$actual,[string]$message) {
    if ($expected -ne $actual) { throw "$message (expected '$expected', actual '$actual')" }
}
function Assert-NoProcess([hashtable]$result,[string[]]$forbidden,[string]$message) {
    foreach ($process in $result.workloads) {
        foreach ($name in $forbidden) {
            if ([IO.Path]::GetFileName($process) -ieq $name) { throw "$message launched ${name}: $($result.workloads -join ', ')" }
        }
    }
}
function Assert-SingleWorkload([hashtable]$result,[string]$message) {
    if ($result.workloads.Count -ne 1 -or
        [IO.Path]::GetFullPath($result.workloads[0]) -ine [IO.Path]::GetFullPath($CoopExe)) {
        throw "$message launched an unexpected process: $($result.workloads -join ', ')"
    }
}
function Get-TreeEvidence([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-ChildItem -LiteralPath $path -Recurse -Force -File | Sort-Object FullName |
        ForEach-Object { $_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
}
function Get-StateEvidence([string]$root) {
    $items = @()
    foreach ($path in @("$root/apps","$root/shims","$root/persist","$root/.coop/packages","$root/.coop/backups","$root/.coop/transactions")) {
        $items += Get-TreeEvidence $path
    }
    return $items
}
function Assert-NoManagementWrite([string]$root,[string]$message) {
    foreach ($path in @("$root/.coop/packages","$root/.coop/backups","$root/.coop/transactions")) {
        if (Test-Path -LiteralPath $path) { throw "$message created $path" }
    }
}
function Assert-Unchanged([string[]]$before,[string[]]$after,[string]$message) {
    if (@(Compare-Object $before $after).Count) { throw $message }
}
function New-Shim([string]$root,[string]$name,[string]$target) {
    New-Item -ItemType Directory -Path "$root/shims" -Force | Out-Null
    Copy-Item -LiteralPath $shimSource "$root/shims/$name.exe"
    [IO.File]::WriteAllText("$root/shims/$name.shim",'path = "'+[IO.Path]::GetFullPath($target)+'"'+"`r`n")
}
function New-JqManifest([string]$version,[string]$archive,[string]$hash) {
    return [ordered]@{
        version=$version
        description='Lightweight and flexible command-line JSON processor'
        homepage='https://jqlang.github.io/jq/'
        license='MIT'
        architecture=@{'64bit'=@{url=((File-Uri $archive)+'#/jq.exe');hash=$hash}}
        bin='jq.exe'
    }
}
function New-CorpusManifest([string]$id,[string]$archive) {
    $bucket,$name = $id.Split('/')
    $folder = if ($bucket -eq 'Main') { 'main' } else { 'extras' }
    $manifest = Read-JsonFile (Join-Path $PSScriptRoot "corpus/$folder/$name.json")
    $manifest.architecture.'64bit'.url = File-Uri $archive
    if ($name -eq 'jq') { $manifest.architecture.'64bit'.url = (File-Uri $archive)+'#/jq.exe' }
    return $manifest
}

# --- 1. Fixed corpus: every sample stays readable, plannable or explicitly rejected. ---
$corpusRoot = Join-Path $TestRoot ('corpus-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$corpusRoot/buckets/main/bucket","$corpusRoot/buckets/extras/bucket" -Force | Out-Null
Copy-Item -LiteralPath (Get-ChildItem -LiteralPath "$PSScriptRoot/corpus/main" -Filter *.json).FullName "$corpusRoot/buckets/main/bucket"
Copy-Item -LiteralPath (Get-ChildItem -LiteralPath "$PSScriptRoot/corpus/extras" -Filter *.json).FullName "$corpusRoot/buckets/extras/bucket"
$index = Read-JsonFile (Join-Path $PSScriptRoot 'corpus/index.json')
$expectedClasses = @{
    'Main/jq'='executable'; 'Main/ripgrep'='executable'; 'Main/neovim'='executable'; 'Main/cmake'='executable';
    'Main/nodejs'='executable'; 'Main/air'='executable'; 'Main/oh-my-posh'='executable';
    # Lifecycle script text no longer decides executability: every sample whose remaining
    # requirements are supported archives, scripts and entries is executable, and a script that
    # fails at run time is reported by the lifecycle, not predicted by a text whitelist.
    'Main/git'='executable'; 'Main/rclone'='executable'; 'Main/python'='executable';
    'Main/android-clt'='executable'; 'Main/azure-cli'='executable';
    'Extras/notepadplusplus'='executable'; 'Extras/vscode'='executable'; 'Extras/everything'='executable';
    'Extras/firefox'='executable'; 'Extras/aider-desk'='executable';
    # MSI artifacts are extracted from a read-only installer database view; the plan is executable
    # without msiexec, elevation or a reboot (see docs/installer-support.md).
    'Main/7zip'='executable';
    'Main/wget'='rejected'; 'Extras/adventuregamestudio'='rejected'
}
if ($index.samples.Count -ne 20 -or $expectedClasses.Count -ne 20) { throw 'The fixed corpus no longer contains exactly 20 audited samples' }
$corpusResults = @()
foreach ($sample in $index.samples) {
    $id = $sample.id
    $bucket,$name = $id.Split('/')
    $folder = if ($bucket -eq 'Main') { 'main' } else { 'extras' }
    $manifestPath = Join-Path "$corpusRoot/buckets/$folder/bucket" "$name.json"
    if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLower() -ne $sample.sha256) {
        throw "Corpus sample bytes changed: $id"
    }
    $infoResult = Invoke-Coop @('--root',$corpusRoot,'info',$id,'--json')
    Assert-Exit $infoResult.exit 0 "Corpus sample is not readable: $id" $infoResult.error
    $info = @(Convert-JsonOutput $infoResult.text "info $id")
    if ($info.Count -ne 1 -or $info[0].name -ne $name -or $info[0].version -ne $sample.version) {
        throw "Corpus sample query identity is wrong: $id"
    }
    $planResult = Invoke-Coop @('--root',$corpusRoot,'install',$id,'--arch','64bit','--dry-run','--json')
    $plan = Convert-JsonOutput $planResult.text "plan $id"
    if ($plan.package.name -ne $name -or $plan.package.version -ne $sample.version) { throw "Corpus plan identity is wrong: $id" }
    if ($plan.manifest_sha256 -ne $sample.sha256) { throw "Corpus plan is not bound to the fixed Manifest bytes: $id" }
    $class = if ($planResult.exit -eq 0 -and $plan.execution_available) { 'executable' }
        elseif ($planResult.exit -eq 0) { 'unsupported' }
        else { 'rejected' }
    if ($class -ne $expectedClasses[$id]) {
        throw "Corpus plan classification changed for ${id}: $class (expected $($expectedClasses[$id]))"
    }
    $codes = @($plan.diagnostics | ForEach-Object { $_.code })
    if ($class -eq 'unsupported' -and 'execution-blocked' -notin $codes) { throw "Unsupported sample lacks an explicit block: $id" }
    if ($class -eq 'rejected') {
        if (@($codes | Where-Object { $_ -in @('unsupported-hash','unsupported-capability','dependency-missing') }).Count -eq 0) {
            throw "Rejected sample lacks a concrete input diagnostic: $id"
        }
        if ($planResult.exit -eq 0) { throw "Rejected sample unexpectedly exited zero: $id" }
    }
    $corpusResults += [ordered]@{
        id=$id
        version=$sample.version
        manifest_sha256=$sample.sha256
        info_exit=$infoResult.exit
        plan_exit=$planResult.exit
        classification=$class
        execution_available=[bool]$plan.execution_available
        diagnostics=$codes
        script_phases=@($plan.package.scripts | ForEach-Object { $_.phase })
        script_host=$plan.package.script_support.host
        archives=@($plan.artifacts | ForEach-Object { $_.archive })
        lifecycle='not-run'
    }
}
if ((Test-Path "$corpusRoot/.coop") -or (Test-Path "$corpusRoot/apps") -or (Test-Path "$corpusRoot/shims")) {
    throw 'Corpus planning wrote installation state'
}
if (@(Get-ChildItem -LiteralPath $corpusRoot -Force | Where-Object { $_.Name -ne 'buckets' }).Count) {
    throw 'Corpus planning created files outside the copied bucket'
}

# --- 2. First acceptance path: preview, in-place adoption, local query, explicit bucket
# update, rejected update, successful update, batch partial failure and uninstall. ---
$root = Join-Path $TestRoot ('first-path-'+[guid]::NewGuid().ToString('N'))
$source = Join-Path $TestRoot ('source-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/apps/jq/1.7.1","$source/bucket" -Force | Out-Null
Copy-Item -LiteralPath $jq17 "$root/apps/jq/1.7.1/jq.exe"
$jq17Manifest = New-JqManifest '1.7.1' $jq17 '7451fbbf37feffb9bf262bd97c54f0da558c63f0748e64152dd87b0a07b6d6ab'
Write-JsonFile "$root/apps/jq/1.7.1/scoop-manifest.json" $jq17Manifest
Write-JsonFile "$root/apps/jq/1.7.1/scoop-install.json" ([ordered]@{bucket='main';architecture='64bit'})
New-Item -ItemType Junction -Path "$root/apps/jq/current" -Target "$root/apps/jq/1.7.1" | Out-Null
New-Shim $root 'jq' "$root/apps/jq/1.7.1/jq.exe"
$original = @(Get-ChildItem -LiteralPath "$root/apps/jq/1.7.1" -Recurse -File | ForEach-Object { $_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash }) +
    @(Get-ChildItem -LiteralPath "$root/shims" -File | ForEach-Object { $_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash })
if (((& "$root/shims/jq.exe" --version) -join "`n") -notmatch '^jq-1\.7\.1') { throw 'Original Scoop entry does not run the real jq 1.7.1 program' }
Write-JsonFile "$source/bucket/jq.json" $jq17Manifest

$add = Invoke-Guarded 'bucket-add' @('--root',$root,'bucket','add','main',$source,'--json')
Assert-Exit $add.exit 0 'Local bucket registration failed' $add.error
Assert-SingleWorkload $add 'Local bucket registration'
$sourceRecord = Convert-JsonOutput $add.text 'bucket add'
if ($sourceRecord.kind -ne 'local' -or -not (Test-Path -LiteralPath $sourceRecord.path)) { throw 'Registered bucket source is not the project-local directory' }
$info = Invoke-Guarded 'info-before' @('--root',$root,'info','main/jq','--json')
Assert-Exit $info.exit 0 'Local query before adoption failed' $info.error
Assert-SingleWorkload $info 'Local query'
if ((@(Convert-JsonOutput $info.text 'info before') | Select-Object -First 1).version -ne '1.7.1') { throw 'Registered bucket did not expose the installed version' }

$previewState = Get-StateEvidence $root
$adoptPreview = Invoke-Guarded 'adopt-preview' @('--root',$root,'adopt','jq','--dry-run','--json')
Assert-Exit $adoptPreview.exit 0 'Adoption preview failed' $adoptPreview.error
Assert-SingleWorkload $adoptPreview 'Adoption preview'
$adoptPlan = Convert-JsonOutput $adoptPreview.text 'adopt preview'
if ($adoptPlan.eligibility -ne 'eligible' -or -not $adoptPlan.execution_available) { throw "Real jq installation is not eligible for adoption: $($adoptPlan.eligibility)" }
if ($adoptPlan.lifecycle_checks.update -ne 'supported-path' -or $adoptPlan.lifecycle_checks.uninstall -ne 'supported-path') { throw 'Adoption preview did not assess future update/uninstall' }
if (@(Compare-Object $previewState (Get-StateEvidence $root)).Count) { throw 'Adoption preview changed installed state' }
Assert-NoManagementWrite $root 'Adoption preview'

$adopt = Invoke-Guarded 'adopt' @('--root',$root,'adopt','jq','--json')
Assert-Exit $adopt.exit 0 'In-place adoption failed' $adopt.error
Assert-SingleWorkload $adopt 'In-place adoption'
$adopted = Convert-JsonOutput $adopt.text 'adopt'
if ($adopted.status -ne 'adopted' -or $adopted.version -ne '1.7.1' -or -not (Test-Path -LiteralPath "$($adopted.backup)/evidence.json")) {
    throw 'Adoption result is incomplete'
}
$afterAdopt = @(Get-ChildItem -LiteralPath "$root/apps/jq/1.7.1" -Recurse -File | ForEach-Object { $_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash }) +
    @(Get-ChildItem -LiteralPath "$root/shims" -File | ForEach-Object { $_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash })
Assert-Unchanged $original $afterAdopt 'Adoption altered the original program, Manifest, install record or command entry'
if (((& "$root/shims/jq.exe" --version) -join "`n") -notmatch '^jq-1\.7\.1') { throw 'Adoption broke the original command entry' }

$list = Invoke-Guarded 'list-after-adopt' @('--root',$root,'list','--json')
Assert-Exit $list.exit 0 'Local list after adoption failed' $list.error
Assert-SingleWorkload $list 'Local list'
$listed = @(Convert-JsonOutput $list.text 'list after adopt')
if ($listed.Count -ne 1 -or $listed[0].management -ne 'managed' -or $listed[0].version -ne '1.7.1' -or $listed[0].origin -ne 'scoop') {
    throw 'Local query did not report the adopted package as managed'
}

# The source bucket is the only thing that changes: an explicit update must publish jq
# 1.8.2 and ripgrep 15.2.0 while the installed jq stays at 1.7.1 until update runs.
Write-JsonFile "$source/bucket/jq.json" (New-CorpusManifest 'Main/jq' $jq18)
Write-JsonFile "$source/bucket/ripgrep.json" (New-CorpusManifest 'Main/ripgrep' $ripgrepArchive)
Start-Sleep -Milliseconds 100
$bucketUpdate = Invoke-Guarded 'bucket-update' @('--root',$root,'bucket','update','main','--json')
Assert-Exit $bucketUpdate.exit 0 'Explicit bucket update failed' $bucketUpdate.error
Assert-SingleWorkload $bucketUpdate 'Explicit bucket update'
$jqInfo = @(Convert-JsonOutput (Invoke-Coop @('--root',$root,'info','main/jq','--json')).text 'info after bucket update')
if ($jqInfo[0].version -ne '1.8.2') { throw 'Explicit bucket update did not expose jq 1.8.2' }
if ((@(Convert-JsonOutput (Invoke-Coop @('--root',$root,'info','main/ripgrep','--json')).text 'ripgrep info'))[0].version -ne '15.2.0') {
    throw 'Explicit bucket update did not expose ripgrep 15.2.0'
}

$updatePreviewState = Get-StateEvidence $root
$updatePreview = Invoke-Guarded 'update-preview' @('--root',$root,'update','jq','--dry-run','--json')
Assert-Exit $updatePreview.exit 0 'Update preview failed' $updatePreview.error
Assert-SingleWorkload $updatePreview 'Update preview'
$updatePlan = Convert-JsonOutput $updatePreview.text 'update preview'
if ($updatePlan.previous_package.version -ne '1.7.1' -or $updatePlan.package.version -ne '1.8.2' -or -not $updatePlan.execution_available) {
    throw 'Update preview did not target the new version from the adopted installation'
}
if (@(Compare-Object $updatePreviewState (Get-StateEvidence $root)).Count) { throw 'Update preview changed installed state' }
if (((& "$root/shims/jq.exe" --version) -join "`n") -notmatch '^jq-1\.7\.1') { throw 'Update preview changed the current entry' }

# A rejected update leaves the adopted current version runnable and records a failure.
$corrupt = New-CorpusManifest 'Main/jq' $jq18
$corrupt.architecture.'64bit'.hash = '0'*64
Write-JsonFile "$source/bucket/jq.json" $corrupt
Start-Sleep -Milliseconds 100
Assert-Exit (Invoke-Coop @('--root',$root,'bucket','update','main','--json')).exit 0 'Bucket update before rejected package update failed'
$rejected = Invoke-Guarded 'update-rejected' @('--root',$root,'update','jq','--json')
if ($rejected.exit -eq 0) { throw 'Update with a mismatched SHA256 unexpectedly succeeded' }
Assert-SingleWorkload $rejected 'Rejected update'
if (((& "$root/shims/jq.exe" --version) -join "`n") -notmatch '^jq-1\.7\.1') { throw 'Rejected update replaced the current entry' }
if (Test-Path -LiteralPath "$root/apps/jq/1.8.2") { throw 'Rejected update published a new version directory' }
$failedList = @(Convert-JsonOutput (Invoke-Coop @('--root',$root,'list','--json')).text 'list after rejected update')
if ($failedList[0].version -ne '1.7.1' -or $failedList[0].last_operation -ne 'failed' -or $failedList[0].status -ne 'ready') {
    throw 'Rejected update was reported as a successful installed state'
}

Write-JsonFile "$source/bucket/jq.json" (New-CorpusManifest 'Main/jq' $jq18)
Start-Sleep -Milliseconds 100
Assert-Exit (Invoke-Coop @('--root',$root,'bucket','update','main','--json')).exit 0 'Bucket update after repairing the Manifest failed'
$updated = Invoke-Guarded 'update' @('--root',$root,'update','jq','--json')
Assert-Exit $updated.exit 0 'Update of the adopted package failed' $updated.error
Assert-SingleWorkload $updated 'Adopted update'
$updateResult = Convert-JsonOutput $updated.text 'update'
if ($updateResult.status -ne 'success' -or $updateResult.version -ne '1.8.2' -or '1.7.1' -notin @($updateResult.retained_versions)) {
    throw 'Update result did not retain the previous version'
}
if (((& "$root/shims/jq.exe" --version) -join "`n") -notmatch '^jq-1\.8\.2') { throw 'Updated command entry does not run jq 1.8.2' }
if (((& "$root/apps/jq/1.7.1/jq.exe" --version) -join "`n") -notmatch '^jq-1\.7\.1') { throw 'Retained old version no longer runs jq 1.7.1' }

# Batch install: a later failure does not roll back an earlier success.
$batch = Invoke-Guarded 'batch-partial' @('--root',$root,'install','main/ripgrep','ghostpkg','--json')
if ($batch.exit -eq 0) { throw 'Batch install with a missing package unexpectedly succeeded' }
Assert-SingleWorkload $batch 'Batch install'
$batchItems = @(Convert-JsonOutput $batch.text 'batch install')
if ($batchItems.Count -ne 2 -or $batchItems[0].package -notmatch '(^|/)ripgrep$' -or $batchItems[0].status -ne 'success' -or
    $batchItems[1].package -ne 'ghostpkg' -or $batchItems[1].status -ne 'failed') {
    throw 'Batch install did not report per-package success and failure'
}
if ($batchItems[0].transaction_scope -notlike 'per-package*' -or $batchItems[1].transaction_scope -notlike 'per-package*') {
    throw 'Batch install claimed one global transaction'
}
if (((& "$root/shims/rg.exe" --version) -join "`n") -notmatch '^ripgrep 15\.2\.0') { throw 'Successful batch item is not runnable' }
Assert-Exit (Invoke-Guarded 'batch-cleanup' @('--root',$root,'uninstall','ripgrep','--json')).exit 0 'Cleanup of the successful batch item failed'

$uninstall = Invoke-Guarded 'uninstall' @('--root',$root,'uninstall','jq','--json')
Assert-Exit $uninstall.exit 0 'Uninstall of the adopted package failed' $uninstall.error
Assert-SingleWorkload $uninstall 'Adopted uninstall'
$uninstallResult = Convert-JsonOutput $uninstall.text 'uninstall'
if ($uninstallResult.status -ne 'success' -or '1.7.1' -notin @($uninstallResult.retained_versions)) {
    throw 'Uninstall did not report the retained old version'
}
if ((Test-Path "$root/shims/jq.exe") -or (Test-Path "$root/apps/jq/current") -or (Test-Path "$root/.coop/packages/jq.json")) {
    throw 'Uninstall left current or management state behind'
}
if (-not (Test-Path "$root/apps/jq/1.7.1/jq.exe")) { throw 'Uninstall deleted the separately retained old version' }

# --- 3. Real data retention: exact Main/nodejs Manifest, real 7z and post_install. ---
$nodeRoot = Join-Path $TestRoot ('data-'+[guid]::NewGuid().ToString('N'))
$nodeSource = Join-Path $TestRoot ('node-source-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$nodeRoot/buckets/main/bucket" -Force | Out-Null
Write-JsonFile "$nodeRoot/buckets/main/bucket/nodejs.json" (New-CorpusManifest 'Main/nodejs' $nodeArchive)
$nodePreview = Invoke-Coop @('--root',$nodeRoot,'install','main/nodejs','--dry-run','--json')
Assert-Exit $nodePreview.exit 0 'Real nodejs preview failed' $nodePreview.error
$nodePlan = Convert-JsonOutput $nodePreview.text 'node preview'
if (-not $nodePlan.execution_available -or $nodePlan.artifacts[0].archive -ne '7z' -or $nodePlan.package.persistence.Count -ne 2) {
    throw 'Real nodejs preview did not expose native 7z extraction and declared persistence'
}
if ((Test-Path "$nodeRoot/apps/nodejs/current") -or (Test-Path "$nodeRoot/apps/nodejs/26.12.1")) { throw 'node preview published a program' }
$nodeInstall = Invoke-Guarded 'node-install' @('--root',$nodeRoot,'install','main/nodejs','--json') 240000 $true
Assert-Exit $nodeInstall.exit 0 'Real nodejs install failed' $nodeInstall.error
Assert-NoProcess $nodeInstall @('7z.exe','7za.exe','7zr.exe','git.exe','msiexec.exe') 'Real nodejs install'
$nodeResult = Convert-JsonOutput $nodeInstall.text 'node install'
if ($nodeResult.status -ne 'success' -or $nodeResult.scripts.Count -ne 1 -or $nodeResult.scripts[0].phase -ne 'post_install' -or
    $nodeResult.scripts[0].exit_code -ne 0 -or @($nodeResult.persistence).Count -ne 2) {
    throw 'Real nodejs install did not run the declared post_install or persistence'
}
if (((& "$nodeRoot/apps/nodejs/current/node.exe" --version) -join "`n") -notmatch '^v26\.12\.1$') {
    throw 'Installed real node.exe did not run the expected version'
}
$persistRoot = [IO.Path]::GetFullPath("$nodeRoot/persist/nodejs")
$npmrc = [IO.File]::ReadAllText("$nodeRoot/apps/nodejs/current/node_modules/npm/npmrc")
if ($npmrc -notmatch [regex]::Escape("prefix=$persistRoot\bin") -or $npmrc -notmatch [regex]::Escape("cache=$persistRoot\cache")) {
    throw 'Real nodejs post_install did not write the persist paths'
}
New-Item -ItemType Directory -Path "$persistRoot/cache" -Force | Out-Null
[IO.File]::WriteAllText("$persistRoot/cache/acceptance-marker.txt",'must survive normal uninstall')
$purgePreview = Invoke-Coop @('--root',$nodeRoot,'uninstall','nodejs','--purge','--dry-run','--json')
Assert-Exit $purgePreview.exit 0 'Purge preview failed' $purgePreview.error
$purgePlan = Convert-JsonOutput $purgePreview.text 'purge preview'
if (-not $purgePlan.purge.requested -or @($purgePlan.purge.scope).Count -ne 2 -or
    @($purgePlan.purge.scope | Where-Object { $_.store -notlike "$persistRoot*" }).Count) {
    throw 'Purge preview did not list only the declared persist stores'
}
if (-not (Test-Path "$persistRoot/cache/acceptance-marker.txt")) { throw 'Purge preview deleted persistent data' }
$nodeUninstall = Invoke-Coop @('--root',$nodeRoot,'uninstall','nodejs','--json')
Assert-Exit $nodeUninstall.exit 0 'Real nodejs uninstall failed' $nodeUninstall.error
$nodeRemoved = Convert-JsonOutput $nodeUninstall.text 'node uninstall'
if ($nodeRemoved.status -ne 'success' -or -not $nodeRemoved.data_retained) { throw 'Real nodejs uninstall did not report retained data' }
if (-not (Test-Path "$persistRoot/cache/acceptance-marker.txt") -or -not (Test-Path "$persistRoot/bin")) {
    throw 'Normal uninstall discarded declared persistent data'
}
if ((Test-Path "$nodeRoot/apps/nodejs/current") -or (Test-Path "$nodeRoot/.coop/packages/nodejs.json")) {
    throw 'Normal uninstall left the current program or management record behind'
}

$verifiedLifecycle = @{
    'Main/jq'='verified: in-place adoption 1.7.1, update 1.8.2, uninstall in this acceptance test'
    'Main/ripgrep'='verified: batch install 15.2.0, run entry, uninstall in this acceptance test'
    'Main/nodejs'='verified: install 26.12.1 with real post_install, normal uninstall retaining persist in this acceptance test'
}
foreach ($item in $corpusResults) {
    if ($verifiedLifecycle.ContainsKey($item.id)) { $item.lifecycle = $verifiedLifecycle[$item.id] }
}

$evidence = [ordered]@{
    schema=1
    generated_by='tests/acceptance.ps1'
    coop_version=((& $CoopExe --version) -join ' ').Trim()
    coop_sha256=(Get-FileHash -LiteralPath $CoopExe -Algorithm SHA256).Hash.ToLower()
    os=[Environment]::OSVersion.VersionString
    windows_architecture=$env:PROCESSOR_ARCHITECTURE
    powershell=$PSVersionTable.PSVersion.ToString()
    corpus_revisions=$index.revisions
    corpus_summary=[ordered]@{
        total=$corpusResults.Count
        executable=@($corpusResults | Where-Object classification -eq 'executable').Count
        unsupported=@($corpusResults | Where-Object classification -eq 'unsupported').Count
        rejected=@($corpusResults | Where-Object classification -eq 'rejected').Count
        lifecycle_verified=@($corpusResults | Where-Object { $_.lifecycle -ne 'not-run' }).Count
    }
    corpus=$corpusResults
    first_path=[ordered]@{
        package='jq'
        adopted_version='1.7.1'
        updated_version='1.8.2'
        adoption_eligibility=$adoptPlan.eligibility
        update_preview_exit=$updatePreview.exit
        rejected_update_exit=$rejected.exit
        rejected_update_state_version=$failedList[0].version
        successful_update_exit=$updated.exit
        batch_exit=$batch.exit
        batch_items=@($batchItems | ForEach-Object { [ordered]@{package=$_.package;status=$_.status;scope=$_.transaction_scope} })
        uninstall_exit=$uninstall.exit
        retained_versions=@($uninstallResult.retained_versions)
    }
    data_retention=[ordered]@{
        package='nodejs'
        version='26.12.1'
        install_exit=$nodeInstall.exit
        post_install_exit=$nodeResult.scripts[0].exit_code
        purge_preview_exit=$purgePreview.exit
        purge_scope=@($purgePlan.purge.scope | ForEach-Object { $_.store })
        uninstall_exit=$nodeUninstall.exit
        marker_retained=(Test-Path "$persistRoot/cache/acceptance-marker.txt")
    }
    process_observations=[ordered]@{
        local_query_workloads=$info.workloads.Count
        bucket_update_workloads=$bucketUpdate.workloads.Count
        node_install_workloads=@($nodeInstall.workloads | ForEach-Object { [IO.Path]::GetFileName($_) })
        node_install_guard=($nodeInstall.error -split "`r?`n" | Where-Object { $_ -match 'Observed workload processes' } | Select-Object -Last 1)
    }
}
Write-JsonFile (Join-Path $TestRoot 'acceptance-evidence.json') $evidence
Write-Output ('PASS fixed corpus 20 samples ('+$evidence.corpus_summary.executable+' executable / '+
    $evidence.corpus_summary.unsupported+' unsupported / '+$evidence.corpus_summary.rejected+
    ' rejected), real jq in-place adoption/query/bucket update/preview/rejection/batch/update/uninstall, real nodejs 7z persist retention: '+
    $TestRoot)
exit 0

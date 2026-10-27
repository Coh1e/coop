param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$EvidenceDir,
    [string]$ScoopRoot = 'C:\Users\Neo\scoop',
    [string]$VersionsRevision = ''
)
$ErrorActionPreference = 'Stop'
# Bounded real-shared-root check for cross-bucket dependency sources (R28 / #49).
#
# The only registration this test may add is the official Versions bucket at the fixed revision in
# tests/coverage/dependency-sources.json. If the selected root already registers it, the test uses
# that registration unchanged and removes nothing. The original buckets, registry records and local
# worktree changes are recorded before the run and compared afterwards; only the packages and
# registration this run added are removed again.
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\') + '\'
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
if (-not (($EvidenceDir.TrimEnd('\') + '\').StartsWith($projectRoot,[StringComparison]::OrdinalIgnoreCase))) {
    throw "EvidenceDir must stay inside the project directory: $EvidenceDir"
}
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$ScoopRoot = [IO.Path]::GetFullPath($ScoopRoot).TrimEnd('\')
$ledgerPath = Join-Path $PSScriptRoot 'coverage/dependency-sources.json'
$ledger = Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json
$versionsSource = @($ledger.buckets | Where-Object { $_.name -eq 'versions' }) | Select-Object -First 1
if (-not $versionsSource) { throw 'The dependency source ledger does not define the official versions bucket' }
if (-not $VersionsRevision) { $VersionsRevision = [string]$versionsSource.revision }
$VersionsRevision = $VersionsRevision.ToLower()
if ($VersionsRevision -notmatch '^[0-9a-f]{40}$') { throw "Invalid Versions revision: $VersionsRevision" }
$versionsUrl = [string]$versionsSource.url
$scoop = (Get-Command scoop.ps1 -ErrorAction Stop).Source
$commands = [System.Collections.Generic.List[object]]::new()
$installedByTest = [System.Collections.Generic.List[string]]::new()
$addedRegistration = $false
function Run([string]$name,[string]$exe,[string[]]$arguments) {
    $log = Join-Path $EvidenceDir (($name -replace '[\\/:*?"<>|]','-')+'.log')
    $output = & $exe @arguments *>&1 | Out-String
    $exit = $LASTEXITCODE
    Set-Content -LiteralPath $log -Value $output -Encoding utf8
    $commands.Add([pscustomobject]@{name=$name;exe=$exe;arguments=$arguments;exit=$exit;log=[IO.Path]::GetFileName($log)})
    return [pscustomobject]@{exit=$exit;output=$output;log=$log}
}
function Coop([string]$name,[string[]]$arguments) { return Run $name $CoopExe (@('--root',$ScoopRoot)+$arguments) }
function Scoop([string]$name,[string[]]$arguments) { return Run $name $scoop $arguments }
function Assert-True([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
function Read-Json([object]$output) { return (($output -join "`n") | ConvertFrom-Json) }
function HashOf([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function Get-BucketState([string]$Label) {
    $directory = Join-Path $ScoopRoot 'buckets'
    $names = @(Get-ChildItem -LiteralPath $directory -Directory -Force | Select-Object -ExpandProperty Name | Sort-Object)
    $records = @()
    $registryPath = Join-Path $ScoopRoot '.coop/buckets.json'
    if (Test-Path -LiteralPath $registryPath) {
        $records = @((Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json) | ForEach-Object {
            [ordered]@{ name = $_.name; url = $_.url; revision = $_.revision; path = $_.path; adopted = $_.adopted }
        } | Sort-Object { $_.name })
    }
    $worktrees = @($names | ForEach-Object {
        $path = Join-Path $directory $_
        if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) { return }
        $status = (& git -C $path status --porcelain 2>&1 | Out-String).Trim()
        $head = (& git -C $path rev-parse HEAD 2>&1 | Out-String).Trim()
        [ordered]@{ name = $_; head = $head; local_changes_sha256 = (([Text.Encoding]::UTF8.GetBytes($status) | ForEach-Object { $_.ToString('x2') }) -join '') }
    })
    $scoopBuckets = (Scoop ($Label+'-scoop-bucket-list') @('bucket','list')).output
    return [ordered]@{ directory_names = $names; registry = $records; worktrees = $worktrees; scoop_bucket_list = $scoopBuckets.Trim() }
}
function Get-InstalledState([string]$Label) {
    $items = (Coop ($Label+'-list') @('list','--json')).output | ConvertFrom-Json
    return @($items | ForEach-Object { [ordered]@{ name = $_.name; version = $_.version; status = $_.status } } | Sort-Object { $_.name })
}
function Assert-DependencyReuse([object]$plan,[string]$dependency,[string]$version) {
    $order = @($plan.dependency_order)
    Assert-True ($order.Count -ge 2) "preview did not report a dependency order for $dependency"
    $entry = $order[0]
    Assert-True ($entry.package -eq $dependency -and $entry.bucket -eq 'versions') "the versions dependency was not planned first: $($entry.package)/$($entry.bucket)"
    Assert-True ($entry.installed -eq $true -and $entry.status -eq 'satisfied') 'the installed versions dependency was not reused'
    Assert-True ($entry.installed_version -eq $version) "the reused dependency version is $($entry.installed_version), expected $version"
    Assert-True (@($entry.ir_operations).Count -eq 0) 'a satisfied versions dependency unexpectedly has installation operations'
    for ($index = 1; $index -lt $order.Count; $index++) {
        Assert-True ($order[$index].package -ne $dependency) 'the versions dependency appears again after its first position'
    }
    return $entry
}
$appDataTerraform = Join-Path $env:APPDATA 'terraform.d'
$appDataTerraformExisted = Test-Path -LiteralPath $appDataTerraform
$appDataEntriesBefore = if ($appDataTerraformExisted) { @(Get-ChildItem -LiteralPath $appDataTerraform -Recurse -Force | ForEach-Object FullName | Sort-Object) } else { @() }
$registryPath = Join-Path $ScoopRoot '.coop/buckets.json'
$registryRawBefore = if (Test-Path -LiteralPath $registryPath) { [IO.File]::ReadAllText($registryPath) } else { $null }
# Undo only what this run added: the packages it installed, the bucket registration and clone it
# created, and the AppData tree that the dependency's own installer and program created. The
# routine is idempotent so the failure path can call it too.
function Restore-TestState {
    $restored = [ordered]@{
        removed_packages = @(); registration_removed = $false; worktree_removed = $false
        registry_restored = $false; appdata_removed = @(); appdata_restored = $false
    }
    foreach ($name in @($installedByTest)) {
        if (-not (Test-Path "$ScoopRoot/apps/$name/current")) { continue }
        $cleanup = Coop ($name+'-uninstall') @('uninstall',$name,'--json')
        if ($cleanup.exit -ne 0) { Write-Warning "Could not clean up test installation $name : $($cleanup.output)"; continue }
        $installedByTest.Remove($name) | Out-Null
        $restored.removed_packages += $name
    }
    if ($script:addedRegistration) {
        $remove = Coop 'bucket-remove-versions' @('bucket','remove','versions','--json')
        if ($remove.exit -ne 0) { throw "removing the test-added versions registration failed: $($remove.output)" }
        $restored.registration_removed = $true
        # `bucket remove` unregisters a bucket but deliberately keeps its shared worktree so a later
        # `bucket add` can re-register local commits. The clone this run created must also go,
        # otherwise Scoop (which scans buckets/<name> directories) still sees a bucket that was not
        # registered before the run. Only the clone created here is removed.
        $worktree = Join-Path $ScoopRoot 'buckets/versions'
        if (Test-Path -LiteralPath $worktree) {
            $origin = (& git -C $worktree remote get-url origin 2>&1 | Out-String).Trim()
            $worktreeHead = (& git -C $worktree rev-parse HEAD 2>&1 | Out-String).Trim()
            if ($origin -ne $versionsUrl -or $worktreeHead -ne $VersionsRevision) { throw "refusing to delete $worktree (origin=$origin head=$worktreeHead)" }
            $deleted = cmd /c ('rmdir /s /q "' + $worktree + '" 2>&1')
            if (Test-Path -LiteralPath $worktree) { throw "cannot remove the test-added worktree $worktree : $deleted" }
            $restored.worktree_removed = $true
        }
        # Coop keeps a `kind: removed` tombstone in .coop/buckets.json. Restore the exact
        # registration file captured before the run after proving no other record changed.
        if ($null -eq $registryRawBefore) { throw 'the selected root had no bucket registry before the run' }
        $originalRecords = @($registryRawBefore | ConvertFrom-Json)
        if (@($originalRecords | Where-Object { $_.name -eq 'versions' }).Count -ne 0) { throw 'the original registry already registered versions' }
        $nowRecords = @((Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json) | Where-Object { $_.kind -ne 'removed' })
        $describe = { param($records) @($records | ForEach-Object { "$($_.name)|$($_.url)|$($_.revision)|$($_.path)|$($_.adopted)" }) }
        if (((& $describe $originalRecords) -join ';') -ne ((& $describe $nowRecords) -join ';')) { throw 'another bucket registration changed during the run; refusing to restore the registry file' }
        [IO.File]::WriteAllText($registryPath,$registryRawBefore,[Text.UTF8Encoding]::new($false))
        $restored.registry_restored = $true
        $script:addedRegistration = $false
    }
    if (-not $appDataTerraformExisted -and (Test-Path -LiteralPath $appDataTerraform)) {
        $restored.appdata_removed = @(Get-ChildItem -LiteralPath $appDataTerraform -Recurse -Force | ForEach-Object FullName | Sort-Object)
        Remove-Item -LiteralPath $appDataTerraform -Recurse -Force
        $restored.appdata_restored = -not (Test-Path -LiteralPath $appDataTerraform)
    }
    return $restored
}
try {
    Assert-True (Test-Path -LiteralPath (Join-Path $ScoopRoot 'apps')) "selected root is not a Scoop installation: $ScoopRoot"
    if (Test-Path -LiteralPath "$ScoopRoot/apps/terraform011") { throw 'terraform011 is already installed in the selected root; refusing to change it' }
    if (Test-Path -LiteralPath "$ScoopRoot/apps/terraform-provider-ibm") { throw 'terraform-provider-ibm is already installed in the selected root; refusing to change it' }
    $inventoryBefore = Get-InstalledState 'coop' 
    $bucketStateBefore = Get-BucketState 'before'
    $scoopVersionOutput = (Scoop 'scoop-version' @('--version')).output
    $scoopVersion = (@(($scoopVersionOutput -split "`r?`n") | Where-Object { $_ -match '^v\d' })[0]).Trim()
    if ([string]::IsNullOrWhiteSpace($scoopVersion)) { $scoopVersion = $scoopVersionOutput.Trim() }
    $versionsRegisteredBefore = @($bucketStateBefore.directory_names) -contains 'versions'
    $versionsHeadBefore = $null
    if ($versionsRegisteredBefore) {
        $versionsHeadBefore = (& git -C (Join-Path $ScoopRoot 'buckets/versions') rev-parse HEAD 2>&1 | Out-String).Trim()
        Write-Output "versions is already registered at $versionsHeadBefore; using the existing registration unchanged"
    } else {
        $add = Coop 'bucket-add-versions' @('bucket','add','versions',$versionsUrl,'--revision',$VersionsRevision,'--json')
        Assert-True ($add.exit -eq 0) "registering the pinned versions bucket failed: $($add.output)"
        $addedRegistration = $true
    }
    $versionsHead = (& git -C (Join-Path $ScoopRoot 'buckets/versions') rev-parse HEAD 2>&1 | Out-String).Trim()
    if ($versionsRegisteredBefore) {
        Assert-True ($versionsHead -eq $versionsHeadBefore) 'the pre-existing versions registration moved during the test'
    } else {
        Assert-True ($versionsHead -eq $VersionsRevision) "registered versions bucket is at $versionsHead, expected $VersionsRevision"
    }
    $scoopSeesVersions = (Scoop 'scoop-bucket-list-versions' @('bucket','list')).output
    Assert-True (($scoopSeesVersions -split "`r?`n" | Where-Object { $_ -match '^versions\b' }).Count -eq 1) 'Scoop does not see the versions bucket registration'

    # The real Main packages that declare versions/* dependencies must plan through the shared root
    # and the real Versions manifests. Main/terraform-provider-ibm is the sample carried through the
    # real install/uninstall cycle below.
    $plans = [ordered]@{}
    foreach ($package in @('buck','glslviewer','terraform-provider-ibm')) {
        $preview = Coop ($package+'-preview') @('install',$package,'--dry-run','--json')
        Assert-True ($preview.exit -eq 0) "real $package preview failed: $($preview.output)"
        $plan = Read-Json $preview.output
        Assert-True ($plan.execution_available -eq $true) "real $package preview was not executable"
        $versionsEntries = @($plan.dependency_order | Where-Object { $_.bucket -eq 'versions' })
        Assert-True ($versionsEntries.Count -eq 1) "real $package preview has $($versionsEntries.Count) versions dependencies, expected 1"
        Assert-True ($versionsEntries[0].installed -eq $false) "the versions dependency of $package was unexpectedly already installed"
        Assert-True ($versionsEntries[0].version -and $versionsEntries[0].request -match '^versions/') "the versions dependency of $package was not resolved with its version and source"
        $index = [array]::IndexOf(@($plan.dependency_order | ForEach-Object package),$versionsEntries[0].package)
        Assert-True ($index -lt @($plan.dependency_order).Count - 1) "$package does not plan its versions dependency before itself"
        Assert-True (@($plan.diagnostics | Where-Object { $_.code -eq 'dependency-missing' }).Count -eq 0) "real $package still reports dependency-missing"
        $plans[$package] = $plan
    }
    Assert-True ($plans['terraform-provider-ibm'].dependency_order[0].request -eq 'versions/terraform011') 'terraform-provider-ibm did not request versions/terraform011'
    Assert-True (-not (Test-Path -LiteralPath "$ScoopRoot/apps/terraform011")) 'a dependency preview installed terraform011'

    # Install the versions dependency from the real shared root, then prove its program runs.
    $dependencyInstall = Coop 'terraform011-install' @('install','versions/terraform011','--json')
    Assert-True ($dependencyInstall.exit -eq 0) "real versions dependency install failed: $($dependencyInstall.output)"
    $installedByTest.Add('terraform011')
    Assert-True (Test-Path -LiteralPath "$ScoopRoot/apps/terraform011/current") 'the installed versions dependency has no current directory'
    $terraformRun = Run 'terraform-run' "$ScoopRoot/shims/terraform.exe" @('--version')
    Assert-True ($terraformRun.exit -eq 0 -and $terraformRun.output -match 'Terraform v0\.11\.15') "installed terraform011 did not run: $($terraformRun.output)"

    # The same dependent now reuses the installed cross-bucket dependency: no second download and no
    # installation operation for it, and it stays first in the plan.
    $reusePreview = Coop 'terraform-provider-ibm-reuse-preview' @('install','terraform-provider-ibm','--dry-run','--json')
    Assert-True ($reusePreview.exit -eq 0) "reuse preview failed: $($reusePreview.output)"
    $reusePlan = Read-Json $reusePreview.output
    Assert-True ($reusePlan.execution_available -eq $true) 'reuse preview was not executable'
    $reused = Assert-DependencyReuse $reusePlan 'terraform011' '0.11.15'
    Assert-True ('terraform011' -notin @($reusePlan.planned_dependencies)) 'the satisfied versions dependency was still planned for installation'

    # Execute the displayed plan: the dependency is skipped as already installed and the requested
    # package is installed afterwards in its own transaction.
    $providerInstall = Coop 'terraform-provider-ibm-install' @('install','terraform-provider-ibm','--json')
    Assert-True ($providerInstall.exit -eq 0) "real dependent install failed: $($providerInstall.output)"
    $installedByTest.Add('terraform-provider-ibm')
    $providerResult = Read-Json $providerInstall.output
    $providerPackages = @($providerResult.packages)
    Assert-True ($providerPackages.Count -eq 2) 'real dependent install did not report both packages'
    Assert-True ($providerPackages[0].package -eq 'terraform011' -and $providerPackages[0].status -eq 'skipped' -and $providerPackages[0].reason -eq 'already-installed') 'the reused versions dependency was not reported as skipped/already-installed'
    Assert-True ($providerPackages[1].package -eq 'terraform-provider-ibm' -and $providerPackages[1].status -eq 'success' -and $providerPackages[1].requested -eq $true) 'the requested dependent was not installed after its dependency'
    $providerJournal = Get-Content -LiteralPath $providerPackages[1].journal -Raw | ConvertFrom-Json
    $planned = @($reusePlan.ir_operations | ForEach-Object operation)
    $observed = @($providerJournal.observed_steps)
    Assert-True (($planned -join ',') -eq ($observed -join ',')) "the real dependent did not execute its displayed plan: planned=$($planned -join ',') observed=$($observed -join ',')"
    $providerRecord = Get-Content -LiteralPath "$ScoopRoot/.coop/packages/terraform-provider-ibm.json" -Raw | ConvertFrom-Json
    Assert-True ('versions/terraform011' -in @($providerRecord.dependencies)) 'the Coop record did not preserve the declared cross-bucket dependency'
    $providerProgram = Get-ChildItem -LiteralPath "$ScoopRoot/apps/terraform-provider-ibm/current" -Filter '*.exe' -File | Select-Object -First 1
    Assert-True ($null -ne $providerProgram) 'the installed dependent has no program'
    $providerRun = Run 'terraform-provider-ibm-run' $providerProgram.FullName @('-version')
    Assert-True ($providerRun.output -match 'plugin') "the installed dependent did not identify itself as a Terraform plugin: $($providerRun.output)"
    $terraformRunAfter = Run 'terraform-run-after-dependent' "$ScoopRoot/shims/terraform.exe" @('--version')
    Assert-True ($terraformRunAfter.exit -eq 0) 'the dependency stopped running after the dependent was installed'

    # Removing the dependent does not cascade into the cross-bucket dependency.
    $providerRemove = Coop 'terraform-provider-ibm-uninstall' @('uninstall','terraform-provider-ibm','--json')
    Assert-True ($providerRemove.exit -eq 0) "real dependent uninstall failed: $($providerRemove.output)"
    $installedByTest.Remove('terraform-provider-ibm') | Out-Null
    Assert-True (-not (Test-Path -LiteralPath "$ScoopRoot/apps/terraform-provider-ibm/current")) 'the dependent uninstall left its current directory'
    Assert-True (Test-Path -LiteralPath "$ScoopRoot/apps/terraform011/current") 'removing the dependent cascaded into the versions dependency'
    $terraformRunAfterRemove = Run 'terraform-run-after-dependent-removal' "$ScoopRoot/shims/terraform.exe" @('--version')
    Assert-True ($terraformRunAfterRemove.exit -eq 0) 'the versions dependency stopped running after the dependent was removed'

    # Explicitly remove the test-installed dependency and the registration this run added. The
    # original buckets, registry records and local worktree changes must be unchanged afterwards.
    $restore = Restore-TestState
    Assert-True (($restore.removed_packages -join ',') -eq 'terraform011') "unexpected packages removed during restoration: $($restore.removed_packages -join ',')"
    Assert-True ((Test-Path -LiteralPath "$ScoopRoot/apps/terraform011/current") -eq $false) 'the dependency uninstall left its current directory'
    Assert-True (-not (Test-Path -LiteralPath "$ScoopRoot/shims/terraform.exe")) 'the dependency uninstall left its command entry'
    if (-not $versionsRegisteredBefore) {
        Assert-True ($restore.registration_removed -and $restore.worktree_removed -and $restore.registry_restored) 'the test-added versions registration and clone were not fully removed'
    }
    Assert-True ($restore.appdata_restored -eq (-not $appDataTerraformExisted)) 'the AppData\terraform.d tree was not restored to its original presence'
    $appDataRestored = if ($appDataTerraformExisted) { 'AppData\terraform.d existed before the run and was left untouched' }
        elseif ($restore.appdata_restored) { 'removed the AppData\terraform.d tree that the dependency installer and the terraform program created during this run' }
        else { 'the dependency installer and program did not create AppData\terraform.d' }
    $appDataRemoved = @($restore.appdata_removed)
    $bucketStateAfter = Get-BucketState 'after'
    $inventoryAfter = Get-InstalledState 'coop-after'
    Assert-True (($bucketStateBefore.directory_names -join '|') -eq ($bucketStateAfter.directory_names -join '|')) "bucket directories changed: $($bucketStateBefore.directory_names -join ',') -> $($bucketStateAfter.directory_names -join ',')"
    $beforeRecords = @($bucketStateBefore.registry | ForEach-Object { "$($_.name)|$($_.url)|$($_.revision)|$($_.path)|$($_.adopted)" })
    $afterRecords = @($bucketStateAfter.registry | ForEach-Object { "$($_.name)|$($_.url)|$($_.revision)|$($_.path)|$($_.adopted)" })
    Assert-True (($beforeRecords -join ';') -eq ($afterRecords -join ';')) 'the original bucket registration records changed'
    $beforeWorktrees = @($bucketStateBefore.worktrees | ForEach-Object { "$($_.name)|$($_.head)|$($_.local_changes_sha256)" })
    $afterWorktrees = @($bucketStateAfter.worktrees | ForEach-Object { "$($_.name)|$($_.head)|$($_.local_changes_sha256)" })
    Assert-True (($beforeWorktrees -join ';') -eq ($afterWorktrees -join ';')) 'the original bucket worktrees or their local changes changed'
    $beforeInventory = @($inventoryBefore | ForEach-Object { "$($_.name)@$($_.version)|$($_.status)" })
    $afterInventory = @($inventoryAfter | ForEach-Object { "$($_.name)@$($_.version)|$($_.status)" })
    Assert-True (($beforeInventory -join ';') -eq ($afterInventory -join ';')) 'the shared installation inventory changed outside the test'
    Assert-True (($bucketStateBefore.scoop_bucket_list.Trim()) -eq ($bucketStateAfter.scoop_bucket_list.Trim())) 'Scoop bucket list did not return to its original content'
    $evidence = [ordered]@{
        ticket = '#49 R28 cross-bucket dependency sources'
        coop_exe = $CoopExe
        coop_sha256 = (HashOf $CoopExe)
        coop_version = (& $CoopExe --version | Out-String).Trim()
        scoop_version = $scoopVersion
        scoop_root = $ScoopRoot
        scoop_bucket_list_before = $bucketStateBefore.scoop_bucket_list
        scoop_bucket_list_after = $bucketStateAfter.scoop_bucket_list
        versions_ledger = $ledgerPath
        versions_url = $versionsUrl
        versions_revision = $VersionsRevision
        versions_registered_before = $versionsRegisteredBefore
        versions_registration_added_by_test = (-not $versionsRegisteredBefore)
        versions_head = $versionsHead
        scoop_sees_versions_while_registered = ($scoopSeesVersions.Trim())
        bucket_state_before = $bucketStateBefore
        bucket_state_after = $bucketStateAfter
        installed_before = $inventoryBefore
        installed_after = $inventoryAfter
        plans = $plans
        reuse_preview = [ordered]@{ execution_available = $reusePlan.execution_available; dependency_order = @($reusePlan.dependency_order); planned_dependencies = @($reusePlan.planned_dependencies) }
        install_packages = $providerPackages
        plan_matches_journal = [ordered]@{ planned = $planned; observed = $observed }
        terraform_version = $terraformRun.output.Trim()
        terraform_version_after_dependent_install = $terraformRunAfter.output.Trim()
        terraform_version_after_dependent_removal = $terraformRunAfterRemove.output.Trim()
        provider_program = $providerProgram.FullName
        provider_run = [ordered]@{ exit = $providerRun.exit; output = $providerRun.output.Trim() }
        appdata_restore = $appDataRestored
        appdata_removed = $appDataRemoved
        restoration = $restore
        appdata_before = [ordered]@{ existed = $appDataTerraformExisted; entries = $appDataEntriesBefore }
        commands = $commands
    }
    $evidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $EvidenceDir 'real-scoop-versions-evidence.json') -Encoding utf8
    Write-Output "PASS cross-bucket dependency source on the shared root: $ScoopRoot (versions pinned at $VersionsRevision)"
    exit 0
} finally {
    if ($installedByTest.Count -or $addedRegistration -or (-not $appDataTerraformExisted -and (Test-Path -LiteralPath $appDataTerraform))) {
        try { [void](Restore-TestState) } catch { Write-Warning "Could not fully restore the shared root: $_" }
    }
}

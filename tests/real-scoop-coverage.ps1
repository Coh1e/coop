param(
    [Parameter(Mandatory)][string]$CoopExe,
    [string]$ScoopRoot = (Join-Path $env:USERPROFILE 'scoop'),
    [Parameter(Mandatory)][string]$EvidenceDir,
    [string]$InventoryRoot = (Join-Path $PSScriptRoot '../.local/coverage/root'),
    [string]$MainRevision = '',
    [string]$ExtrasRevision = '',
    [switch]$ResetInventory,
    [string]$VerifiedFacts = '',
    [string]$VerifiedLifecycle = '',
    [int]$ThrottleLimit = 8,
    [switch]$SkipRealRootSnapshot,
    [string]$VersionsRevision = '',
    [switch]$SkipDependencySources
)
# Full-denominator Main/Extras compatibility inventory (R20 / #41).
#
# The denominator is every Manifest in the official Main and Extras buckets at pinned
# revisions. Main always uses the revision that is actually checked out in the human's
# shared Scoop bucket; the Coop registry record is reported next to it because a Scoop
# bucket update moves the worktree without updating Coop's cached record. Extras has to
# be cloned into a project-local inventory root because the shared root does not register
# it (or clones it at the recorded revision when it does).
#
# Every Manifest is read with `coop info --json` and planned with
# `coop install --json --dry-run`. A successful read or an executable plan is never
# reported as a runtime verification: the only runtime-verified packages are the ones in
# a supplied cohort facts file whose installed Manifest still has the same SHA256 as the
# denominator Manifest and whose recorded program run succeeded.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$ProgressPreference = 'SilentlyContinue'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\') + '\'
foreach ($location in @($CoopExe,$ScoopRoot,$EvidenceDir,$InventoryRoot)) {
    if (-not $location) { throw 'A required path is empty' }
}
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$ScoopRoot = [IO.Path]::GetFullPath($ScoopRoot).TrimEnd('\')
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
$InventoryRoot = [IO.Path]::GetFullPath($InventoryRoot).TrimEnd('\')
function Assert-ProjectLocal([string]$Path,[string]$Label) {
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($projectRoot,[StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay inside the project directory: $Path"
    }
}
Assert-ProjectLocal $EvidenceDir 'EvidenceDir'
Assert-ProjectLocal $InventoryRoot 'InventoryRoot'
if (-not (Test-Path -LiteralPath $CoopExe)) { throw "Coop executable not found: $CoopExe" }
if (-not (Test-Path -LiteralPath $ScoopRoot)) { throw "Shared Scoop root not found: $ScoopRoot" }
if ($InventoryRoot.TrimEnd('\') + '\' -like ($ScoopRoot.TrimEnd('\') + '\*')) {
    throw 'The inventory root must not live inside the shared Scoop root'
}
$mainUrl = 'https://github.com/ScoopInstaller/Main'
$extrasUrl = 'https://github.com/ScoopInstaller/Extras'
if ($ExtrasRevision) { $ExtrasRevision = $ExtrasRevision.ToLower() }
# Cross-bucket dependency sources are official buckets that are not part of the Main/Extras
# denominator but are required for declared dependencies such as versions/python27. Their fixed
# URL and 40-hex revision live in tests/coverage/dependency-sources.json so every measurement and
# real-root check uses the same input.
$dependencySourceLedgerPath = Join-Path $PSScriptRoot 'coverage/dependency-sources.json'
$dependencySources = @()
$dependencySourceProblems = [System.Collections.Generic.List[string]]::new()
if (Test-Path -LiteralPath $dependencySourceLedgerPath) {
    $dependencyLedger = Get-Content -LiteralPath $dependencySourceLedgerPath -Raw | ConvertFrom-Json
    if ($dependencyLedger.schema -ne 1) { $dependencySourceProblems.Add('dependency source ledger schema must be 1') }
    foreach ($source in @($dependencyLedger.buckets)) {
        if ([string]$source.name -notmatch '^[A-Za-z0-9._-]+$') { $dependencySourceProblems.Add("invalid dependency source name: $($source.name)"); continue }
        if ([string]$source.url -notmatch '^https://') { $dependencySourceProblems.Add("dependency source $($source.name) needs an https url") }
        if ([string]$source.revision -notmatch '^[0-9a-f]{40}$') { $dependencySourceProblems.Add("dependency source $($source.name) needs a 40-hex revision") }
        if ([string]$source.role -ne 'dependency-source') { $dependencySourceProblems.Add("dependency source $($source.name) must declare role=dependency-source") }
        if ($source.denominator -ne $false) { $dependencySourceProblems.Add("dependency source $($source.name) must not be part of the denominator") }
        $dependencySources += $source
    }
    if (-not $dependencySources.Count) { $dependencySourceProblems.Add('dependency source ledger lists no buckets') }
} else {
    $dependencySourceProblems.Add("missing dependency source ledger: $dependencySourceLedgerPath")
}
if ($dependencySourceProblems.Count) { throw ('Dependency source ledger is unusable: ' + ($dependencySourceProblems -join '; ')) }
$versionsSource = @($dependencySources | Where-Object { $_.name -eq 'versions' }) | Select-Object -First 1
if (-not $versionsSource) { throw 'The dependency source ledger does not define the official versions bucket' }
$versionsUrl = [string]$versionsSource.url
if (-not $VersionsRevision) { $VersionsRevision = [string]$versionsSource.revision }
$VersionsRevision = $VersionsRevision.ToLower()
if ($VersionsRevision -notmatch '^[0-9a-f]{40}$') { throw "Invalid Versions revision: $VersionsRevision" }
$script:CommandLines = [System.Collections.Generic.List[string]]::new()

. (Join-Path $PSScriptRoot 'coverage-manifest-features.ps1')
function Get-ProjectPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (($full.TrimEnd('\') + '\').StartsWith($projectRoot,[StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($projectRoot.Length).Replace('\','/')
    }
    return $full
}
function Get-WorktreeRevision([string]$Worktree) {
    $git = Join-Path $Worktree '.git'
    if (Test-Path -LiteralPath $git -PathType Leaf) {
        $pointer = (Get-Content -LiteralPath $git -Raw).Trim()
        if ($pointer -notmatch '^gitdir:\s*(.+)$') { throw "Unreadable Git pointer: $git" }
        $git = [IO.Path]::GetFullPath((Join-Path $Worktree $Matches[1].Trim()))
    }
    if (-not (Test-Path -LiteralPath $git -PathType Container)) { return $null }
    $head = (Get-Content -LiteralPath (Join-Path $git 'HEAD') -Raw).Trim()
    if ($head -match '^ref:\s*(.+)$') {
        $reference = $Matches[1].Trim()
        $loose = Join-Path $git ($reference -replace '/','\')
        if (Test-Path -LiteralPath $loose -PathType Leaf) {
            return [ordered]@{ revision = (Get-Content -LiteralPath $loose -Raw).Trim(); reference = $reference; detached = $false }
        }
        $packed = Join-Path $git 'packed-refs'
        if (Test-Path -LiteralPath $packed -PathType Leaf) {
            foreach ($line in Get-Content -LiteralPath $packed) {
                if ($line -match '^([0-9a-fA-F]{40})\s+(.+)$' -and $Matches[2] -eq $reference) {
                    return [ordered]@{ revision = $Matches[1].ToLower(); reference = $reference; detached = $false }
                }
            }
        }
        throw "Cannot resolve $reference in $Worktree"
    }
    if ($head -match '^[0-9a-fA-F]{40}$') {
        return [ordered]@{ revision = $head.ToLower(); reference = $null; detached = $true }
    }
    throw "Unreadable HEAD in $Worktree"
}
function Get-BucketRecords([string]$Root) {
    $registry = Join-Path $Root '.coop/buckets.json'
    if (-not (Test-Path -LiteralPath $registry)) { return @() }
    return @((Get-Content -LiteralPath $registry -Raw | ConvertFrom-Json))
}
function Invoke-Coop([string[]]$Arguments,[string]$Label) {
    $output = Invoke-CoopNative $CoopExe  @Arguments
    $code = $LASTEXITCODE
    $script:CommandLines.Add(('{0} :: coop {1} :: exit={2}' -f $Label,($Arguments -join ' '),$code))
    return [pscustomobject]@{ exit = $code; text = ($output -join "`n") }
}
function Get-DiagnosticMechanism([object]$Diagnostic) {
    if ($Diagnostic.category -eq 'verification') { return $null }
    $key = $Diagnostic.category + '/' + $Diagnostic.code
    switch ($key) {
        'adapter/unsupported-capability' {
            if ($Diagnostic.message -match '^Not yet supported:\s*(.+)$') { return 'capability:'+$Matches[1].Trim().ToLower() }
            return 'capability:unknown'
        }
        'adapter/unsupported-command-host' { return 'command-entry-host' }
        'adapter/manifest-shape' { return 'manifest-shape' }
        'ir/dependency-missing' { return 'dependency-missing' }
        'capability/dependency-unsupported' { return 'dependency-unsupported' }
        'ir/missing-artifact' { return 'architecture-artifact' }
        'capability/execution-blocked' {
            # A missing external command host is an environment prerequisite, not an unsupported
            # entry mechanism. Keep it visible instead of folding it into an unclassified gap.
            if ($Diagnostic.message -match '^Python interpreter not found') { return 'external-host:python' }
            if ($Diagnostic.message -match '^bash not found') { return 'external-host:bash' }
            return $null
        }
        default { return 'other:'+$key }
    }
}
function Get-GapMechanism([object]$Record) {
    if ($Record.plan.reason -eq 'already-installed-inventory-helper') { return @() }
    if ($Record.plan.execution_available) { return @() }
    $mechanisms = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if (-not $Record.read.ok) { [void]$mechanisms.Add('read-failure') }
    if ($Record.plan.reason -eq 'plan-unavailable') { [void]$mechanisms.Add('plan-unavailable') }
    foreach ($diagnostic in @($Record.plan.diagnostics)) {
        $mechanism = Get-DiagnosticMechanism $diagnostic
        if ($mechanism) { [void]$mechanisms.Add($mechanism) }
    }
    if ($mechanisms.Count -eq 0) { [void]$mechanisms.Add('unclassified') }
    return @($mechanisms | Sort-Object)
}

New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$runDir = Join-Path $EvidenceDir ('coverage-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$sampleDir = Join-Path $runDir 'samples'
$baseline = [ordered]@{
    schema = 1
    generated_at = [DateTime]::UtcNow.ToString('o')
    tool = 'tests/real-scoop-coverage.ps1'
    platform = [ordered]@{
        os = [System.Environment]::OSVersion.VersionString
        architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        powershell = $PSVersionTable.PSVersion.ToString()
    }
    coop = [ordered]@{ version = (& $CoopExe --version); sha256 = (Get-Sha256 $CoopExe) }
}
$projectHead = Get-WorktreeRevision ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')))
if ($projectHead) { $baseline.project_head = [ordered]@{ revision = $projectHead.revision; reference = $projectHead.reference } }
$scoopVersion = ''
try {
    $scoopVersionText = (& scoop --version 2>&1 6>&1 | Out-String)
    $scoopVersion = (@($scoopVersionText -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -First 2) -join ' '
} catch { $scoopVersion = 'unavailable' }
$baseline.scoop = [ordered]@{ root = $ScoopRoot; version = $scoopVersion }
Write-Output ("coverage inventory: coop {0}, shared root {1}" -f $baseline.coop.version,$ScoopRoot)

# Shared-root snapshot: the inventory only reads the shared root. Any change is a failure.
function Get-RootSnapshot([string]$Path) {
    @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($Path.Length) + ':' + $_.Length + ':' + $_.LastWriteTimeUtc.Ticks
    })
}
$snapshotBefore = @()
if (-not $SkipRealRootSnapshot) {
    Write-Output 'snapshotting the shared Scoop root before the inventory'
    $snapshotBefore = Get-RootSnapshot $ScoopRoot
    $snapshotBefore | Set-Content -LiteralPath (Join-Path $runDir 'shared-root-before.txt') -Encoding utf8
}

# Resolve the actual shared Main worktree revision, not Coop's cached refresh record.
$sharedMain = Join-Path $ScoopRoot 'buckets/main'
if (-not (Test-Path -LiteralPath (Join-Path $sharedMain '.git'))) { throw "Shared Main bucket is not a Git worktree: $sharedMain" }
$sharedMainHead = Get-WorktreeRevision $sharedMain
$sharedRecords = @(Get-BucketRecords $ScoopRoot)
$sharedMainRecord = @($sharedRecords | Where-Object { $_.name -eq 'main' }) | Select-Object -First 1
$mainRevision = if ($MainRevision) { $MainRevision.ToLower() } else { $sharedMainHead.revision }
if ($mainRevision -notmatch '^[0-9a-f]{40}$') { throw "Invalid Main revision: $mainRevision" }
if ($mainRevision -ne $sharedMainHead.revision) {
    throw "Requested Main revision $mainRevision is not the revision checked out in $sharedMain ($($sharedMainHead.revision))"
}
$baseline.shared_root = [ordered]@{
    main_worktree = $sharedMain
    main_worktree_revision = $sharedMainHead.revision
    main_branch_reference = $sharedMainHead.reference
    main_registered_revision = if ($sharedMainRecord) { $sharedMainRecord.revision } else { $null }
    main_registry_matches_worktree = [bool]($sharedMainRecord -and $sharedMainRecord.revision -eq $sharedMainHead.revision)
    main_registry_synced_at = if ($sharedMainRecord) { $sharedMainRecord.synced_at } else { $null }
}

if ($ResetInventory -and (Test-Path -LiteralPath $InventoryRoot)) {
    Assert-ProjectLocal $InventoryRoot 'InventoryRoot'
    # Remove only the helper junctions we created; never let a recursive delete follow
    # a junction into the shared Scoop installation.
    foreach ($helper in @('innounp','7zip')) {
        $link = Join-Path $InventoryRoot ('apps/'+$helper+'/current')
        if (-not (Test-Path -LiteralPath $link)) { continue }
        $item = Get-Item -LiteralPath $link -Force
        if ($item.LinkType -eq 'Junction') {
            $target = [IO.Path]::GetFullPath($item.Target)
            if (-not ($target.TrimEnd('\') + '\').StartsWith($ScoopRoot.TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to delete unexpected junction $link -> $target"
            }
            cmd /c ('rmdir "' + $link + '"') | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Cannot remove helper junction $link" }
        }
    }
    Write-Output "resetting the project-local inventory root $InventoryRoot"
    Remove-Item -LiteralPath $InventoryRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $InventoryRoot -Force | Out-Null
function Get-InventoryBucket([string]$Name) { Join-Path $InventoryRoot ('buckets/'+$Name) }
function Add-InventoryBucket([string]$Name,[string]$Url,[string]$Revision) {
    $arguments = @('--root',$InventoryRoot,'bucket','add',$Name,$Url)
    if ($Revision) { $arguments += @('--revision',$Revision) }
    $arguments += '--json'
    $result = Invoke-Coop $arguments "add-$Name"
    if ($result.exit -ne 0) { throw "bucket add $Name failed: $($result.text)" }
}
function Assert-InventoryRevision([string]$Name,[string]$Expected) {
    $head = Get-WorktreeRevision (Get-InventoryBucket $Name)
    if (-not $head -or $head.revision -ne $Expected) {
        throw "Inventory bucket $Name is at $($head.revision), expected $Expected; rerun with -ResetInventory to rebuild the project-local clone"
    }
    return $head
}
if (-not (Test-Path -LiteralPath (Join-Path (Get-InventoryBucket 'main') '.git'))) {
    Add-InventoryBucket 'main' $mainUrl $mainRevision
} else {
    $head = Get-WorktreeRevision (Get-InventoryBucket 'main')
    if ($head.revision -ne $mainRevision) {
        throw "Inventory Main is at $($head.revision), the shared worktree is at $mainRevision; rerun with -ResetInventory"
    }
}
$inventoryMainHead = Assert-InventoryRevision 'main' $mainRevision

if (-not (Test-Path -LiteralPath (Join-Path (Get-InventoryBucket 'extras') '.git'))) {
    Add-InventoryBucket 'extras' $extrasUrl $ExtrasRevision
} else {
    $head = Get-WorktreeRevision (Get-InventoryBucket 'extras')
    if ($ExtrasRevision -and $head.revision -ne $ExtrasRevision.ToLower()) {
        throw "Inventory Extras is at $($head.revision), requested $($ExtrasRevision.ToLower()); rerun with -ResetInventory"
    }
}
$inventoryExtrasHead = Get-WorktreeRevision (Get-InventoryBucket 'extras')
$extrasRevision = $inventoryExtrasHead.revision
$versionsHead = $null
$bundledDependencySources = @()
if (-not $SkipDependencySources) {
    foreach ($source in $dependencySources) {
        $name = [string]$source.name
        $revision = [string]$source.revision
        if (-not (Test-Path -LiteralPath (Join-Path (Get-InventoryBucket $name) '.git'))) {
            Add-InventoryBucket $name ([string]$source.url) $revision
        } else {
            $existing = Get-WorktreeRevision (Get-InventoryBucket $name)
            if ($existing.revision -ne $revision) {
                throw "Inventory $name is at $($existing.revision), the pinned dependency source revision is $revision; rerun with -ResetInventory"
            }
        }
        $head = Assert-InventoryRevision $name $revision
        if ($name -eq 'versions') { $versionsHead = $head }
        $bundledDependencySources += [ordered]@{
            name = $name; url = [string]$source.url; role = 'dependency-source'; denominator = $false
            revision = $head.revision; branch = if ($head.reference) { $head.reference -replace '^refs/heads/','' } else { $null }
            path = (Get-ProjectPath (Get-InventoryBucket $name))
            manifests = @(Get-ChildItem -LiteralPath (Join-Path (Get-InventoryBucket $name) 'bucket') -Filter '*.json' -File).Count
        }
    }
}
$inventoryRecords = @(Get-BucketRecords $InventoryRoot)
function Get-InventoryRecord([string]$Name) { @($inventoryRecords | Where-Object { $_.name -eq $Name }) | Select-Object -First 1 }
$mainRecord = Get-InventoryRecord 'main'
$extrasRecord = Get-InventoryRecord 'extras'
$baseline.buckets = @(
    [ordered]@{
        name = 'main'; url = $mainUrl; source = 'shared-scoop-worktree'; path = (Get-ProjectPath (Get-InventoryBucket 'main'))
        branch = if ($inventoryMainHead.reference) { $inventoryMainHead.reference -replace '^refs/heads/','' } else { $null }
        revision = $mainRevision; files_count = if ($mainRecord) { $mainRecord.files_count } else { $null }
        denominator = $true
    },
    [ordered]@{
        name = 'extras'; url = $extrasUrl; source = 'official-git-clone-fetched-for-this-inventory'; path = (Get-ProjectPath (Get-InventoryBucket 'extras'))
        branch = if ($inventoryExtrasHead.reference) { $inventoryExtrasHead.reference -replace '^refs/heads/','' } else { $null }
        revision = $extrasRevision; files_count = if ($extrasRecord) { $extrasRecord.files_count } else { $null }
        denominator = $true
    }
) + @($bundledDependencySources | ForEach-Object { [ordered]@{
    name = $_.name; url = $_.url; source = 'official-git-clone-fetched-for-this-inventory'; path = $_.path
    branch = $_.branch; revision = $_.revision; files_count = $_.manifests; role = $_.role; denominator = $_.denominator
} })
$baseline.scope = [ordered]@{
    architecture = '64bit'
    denominator = 'every *.json manifest in buckets/<name>/bucket for the Main and Extras buckets only'
    denominator_buckets = @('main','extras')
    dependency_source_buckets = @($bundledDependencySources | ForEach-Object { $_.name })
    dependency_source_ledger = (Get-ProjectPath $dependencySourceLedgerPath)
    mechanism_scan = 'manifest root plus every architecture section; checkver/autoupdate excluded'
    runtime_verification = 'only packages present in the supplied cohort facts with an identical manifest SHA256 and a successful program run'
}

# Prove that the inventory Main denominator is the actual shared worktree content.
Write-Output 'verifying the inventory Main manifests against the shared worktree'
function Compare-ManifestTrees([string]$Left,[string]$Right) {
    $leftNames = @(Get-ChildItem -LiteralPath $Left -Filter '*.json' -File | Select-Object -ExpandProperty Name | Sort-Object)
    $rightNames = @(Get-ChildItem -LiteralPath $Right -Filter '*.json' -File | Select-Object -ExpandProperty Name | Sort-Object)
    $missing = @($leftNames | Where-Object { $rightNames -notcontains $_ })
    $extra = @($rightNames | Where-Object { $leftNames -notcontains $_ })
    $mismatched = @()
    foreach ($name in @($leftNames | Where-Object { $rightNames -contains $_ })) {
        if ((Get-Sha256 (Join-Path $Left $name)) -ne (Get-Sha256 (Join-Path $Right $name))) { $mismatched += $name }
    }
    return [ordered]@{
        shared_manifests = $leftNames.Count; inventory_manifests = $rightNames.Count
        missing_in_inventory = $missing; extra_in_inventory = $extra; mismatched_content = $mismatched
        identical = ($missing.Count -eq 0 -and $extra.Count -eq 0 -and $mismatched.Count -eq 0)
    }
}
$mainVerification = Compare-ManifestTrees (Join-Path $sharedMain 'bucket') (Join-Path (Get-InventoryBucket 'main') 'bucket')
$mainVerification | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runDir 'shared-main-manifest-verification.json') -Encoding utf8
if (-not $mainVerification.identical) {
    throw ("The inventory Main clone does not match the shared worktree manifests: missing={0} extra={1} mismatched={2}. " +
        'The shared bucket has local modifications; commit or revert them or pass a matching project-local clone before measuring.') -f `
        $mainVerification.missing_in_inventory.Count,$mainVerification.extra_in_inventory.Count,$mainVerification.mismatched_content.Count
}

# Helper packages that a mechanism needs are read-only junctions to the shared installs,
# so the inventory measures the actual machine capability instead of an empty helper root.
$helperTargets = [ordered]@{}
foreach ($helper in @('innounp','7zip')) {
    $target = Join-Path $ScoopRoot ('apps/'+$helper+'/current')
    $link = Join-Path $InventoryRoot ('apps/'+$helper+'/current')
    if (-not (Test-Path -LiteralPath $target)) { continue }
    New-Item -ItemType Directory -Path (Split-Path $link) -Force | Out-Null
    if (-not (Test-Path -LiteralPath $link)) {
        $created = cmd /c ('mklink /J "' + $link + '" "' + $target + '" 2>&1')
        if ($LASTEXITCODE -ne 0) { throw "Cannot create helper junction $link -> $target : $created" }
    }
    $helperTargets[$helper] = $target
}
$baseline.external_helper_links = $helperTargets

$verified = @{}
if ($VerifiedFacts) {
    $factsPath = [IO.Path]::GetFullPath($VerifiedFacts)
    if (-not (Test-Path -LiteralPath $factsPath)) { throw "Verified cohort facts not found: $factsPath" }
    $facts = @(Get-Content -LiteralPath $factsPath -Raw | ConvertFrom-Json)
    $steps = @{}
    $lifecycleVerifications = @{}
    if ($VerifiedLifecycle) {
        $lifecyclePath = [IO.Path]::GetFullPath($VerifiedLifecycle)
        if (-not (Test-Path -LiteralPath $lifecyclePath)) { throw "Verified cohort lifecycle not found: $lifecyclePath" }
        foreach ($entry in @(Get-Content -LiteralPath $lifecyclePath -Raw | ConvertFrom-Json)) {
            if (-not $steps.ContainsKey($entry.package)) { $steps[$entry.package] = [System.Collections.Generic.List[string]]::new() }
            if (-not $lifecycleVerifications.ContainsKey($entry.package)) { $lifecycleVerifications[$entry.package] = [System.Collections.Generic.List[object]]::new() }
            foreach ($step in @($entry.steps)) {
                if ($null -eq $step) { continue }
                [string]$stepName = $step.step
                if (-not $steps[$entry.package].Contains($stepName)) { $steps[$entry.package].Add($stepName) }
                foreach ($key in @('verification','coop_verify','scoop_verify')) {
                    $verification = $step.$key
                    if (-not $verification) { continue }
                    $lifecycleVerifications[$entry.package].Add([ordered]@{
                        step = $stepName; label = [string]$verification.label
                        coop_version = [string]$verification.coop_version
                        scoop_version = [string]$verification.scoop_version
                        run_exit = $verification.run_exit
                        current_target = [string]$verification.current_target
                        log_dir = [string]$verification.log_dir
                    })
                }
            }
        }
    }
    foreach ($fact in $facts) {
        $id = ([string]$fact.bucket) + '/' + ([string]$fact.package)
        $verified[$id] = [ordered]@{
            bucket = [string]$fact.bucket; package = [string]$fact.package
            facts_version = [string]$fact.manifest_version
            facts_run_exit = if ($fact.run) { $fact.run.exit } else { $null }
            facts_run_log = if ($fact.run) { [string]$fact.run.log } else { $null }
            installed_manifest_sha256 = Get-Sha256 ([string]$fact.manifest_path)
            lifecycle_steps = if ($steps.ContainsKey([string]$fact.package)) { @($steps[[string]$fact.package]) } else { @() }
            lifecycle_verifications = if ($lifecycleVerifications.ContainsKey([string]$fact.package)) { @($lifecycleVerifications[[string]$fact.package]) } else { @() }
            source_facts = Get-ProjectPath $factsPath
            source_lifecycle = if ($VerifiedLifecycle) { Get-ProjectPath $lifecyclePath } else { $null }
        }
    }
    $baseline.verified_source = [ordered]@{ facts = (Get-ProjectPath $factsPath); lifecycle = if ($VerifiedLifecycle) { Get-ProjectPath $lifecyclePath } else { $null }; packages = $facts.Count }
} else {
    $baseline.verified_source = $null
}

$manifestEntries = @()
foreach ($bucket in @('main','extras')) {
    $directory = Join-Path (Get-InventoryBucket $bucket) 'bucket'
    $files = @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File | Sort-Object Name)
    if (-not $files.Count) { throw "No manifests found in $directory" }
    $manifestEntries += @($files | ForEach-Object { [pscustomobject]@{ bucket = $bucket; name = $_.BaseName; path = $_.FullName } })
}
$denominator = [ordered]@{
    main = @($manifestEntries | Where-Object { $_.bucket -eq 'main' }).Count
    extras = @($manifestEntries | Where-Object { $_.bucket -eq 'extras' }).Count
    total = $manifestEntries.Count
}
$baseline.denominator = $denominator
Write-Output ("denominator: Main={0} Extras={1} total={2} (Main revision {3}, Extras revision {4})" -f $denominator.main,$denominator.extras,$denominator.total,$mainRevision,$extrasRevision)
if ($sharedMainRecord -and -not $baseline.shared_root.main_registry_matches_worktree) {
    Write-Warning ("Coop's cached Main revision {0} differs from the actual shared worktree HEAD {1}; the inventory uses the worktree HEAD" -f $sharedMainRecord.revision,$sharedMainHead.revision)
}

$FeatureHelperPath = Join-Path $PSScriptRoot 'coverage-manifest-features.ps1'
$sw = [Diagnostics.Stopwatch]::StartNew()
$allRecords = [System.Collections.Generic.List[object]]::new()
foreach ($bucket in @('main','extras')) {
    $entries = @($manifestEntries | Where-Object { $_.bucket -eq $bucket })
    $ids = @($entries | ForEach-Object { $_.bucket + '/' + $_.name })
    Write-Output ("reading and planning {0} {1} manifests with {2} parallel workers" -f $entries.Count,$bucket,$ThrottleLimit)
    $results = $ids | ForEach-Object -Parallel {
        . $using:FeatureHelperPath
        $exe = $using:CoopExe
        $root = $using:InventoryRoot
        $id = $_
        $parts = $id -split '/',2
        $manifestPath = Join-Path $root ('buckets/'+$parts[0]+'/bucket/'+$parts[1]+'.json')
        try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable }
        catch { $manifest = $null }
        $infoText = $null; $infoExit = $null; $info = $null
        try {
            $infoText = & $exe --root $root --arch 64bit info $id --json 2>$null
            $infoExit = $LASTEXITCODE
            $info = $infoText | ConvertFrom-Json
        } catch { $info = $null }
        $planText = $null; $planExit = $null; $plan = $null
        try {
            $planText = & $exe --root $root --arch 64bit install $id --dry-run --json 2>$null
            $planExit = $LASTEXITCODE
            $plan = $planText | ConvertFrom-Json
        } catch { $plan = $null }
        $featureList = @()
        if ($manifest) { $featureList = @(Read-ManifestFeatures $manifest) }
        $readDiagnostics = @()
        if ($info) {
            foreach ($diagnostic in @($info[0].validation.diagnostics)) {
                if ($diagnostic) { $readDiagnostics += [ordered]@{ layer = [string]$diagnostic.layer; code = [string]$diagnostic.code } }
            }
        }
        $planDiagnostics = @()
        if ($plan) {
            foreach ($diagnostic in @($plan.diagnostics)) {
                if ($diagnostic) { $planDiagnostics += [ordered]@{ category = [string]$diagnostic.category; code = [string]$diagnostic.code; message = [string]$diagnostic.message } }
            }
        }
        $capabilities = @()
        if ($plan) {
            foreach ($capability in @($plan.capabilities)) { $capabilities += [ordered]@{ id = [string]$capability.id; supported = [bool]$capability.supported } }
        }
        $tools = @()
        if ($plan) {
            foreach ($tool in @($plan.external_tools)) { $tools += [ordered]@{ name = [string]$tool.name; available = [bool]$tool.available; enabled = [bool]$tool.enabled } }
        }
        $artifacts = @()
        if ($plan) {
            foreach ($artifact in @($plan.artifacts)) { $artifacts += [ordered]@{ archive = [string]$artifact.archive; algorithm = [string]$artifact.algorithm; renamed = [bool]$artifact.renamed } }
        }
        $operations = @(); $dependencies = @(); $launchers = @()
        if ($plan) {
            foreach ($operation in @($plan.ir_operations)) { $operations += [string]$operation.operation }
            foreach ($dependency in @($plan.dependency_order)) { if ($dependency -and $dependency.package) { $dependencies += [string]$dependency.package } }
            foreach ($command in @($plan.package.commands)) { if ($command) { $launchers += [string]$command.launcher } }
        }
        $reason = if (-not $plan) { 'plan-unavailable' }
                  elseif ($plan.execution_available) { 'executable' }
                  elseif (@($planDiagnostics | Where-Object { $_.category -eq 'capability' -and $_.code -eq 'execution-blocked' -and $_.message -match 'Package already exists' }).Count) { 'already-installed-inventory-helper' }
                  elseif (@($planDiagnostics | Where-Object { $_.category -ne 'verification' }).Count) { 'mechanism-or-dependency-gap' }
                  else { 'unspecified' }
        # Declared dependency identities and the order the plan resolved them into, so a
        # cross-bucket finding can be replayed without re-parsing the Manifest or the plan text.
        $declaredDependencies = @()
        if ($manifest -and $manifest.depends) { $declaredDependencies = @($manifest.depends) }
        $dependencyDetails = @()
        if ($plan) {
            foreach ($dependency in @($plan.dependency_order)) {
                if (-not $dependency -or -not $dependency.package) { continue }
                $dependencyDetails += [ordered]@{
                    package = [string]$dependency.package; request = [string]$dependency.request
                    bucket = [string]$dependency.bucket; version = [string]$dependency.version
                    installed = [bool]$dependency.installed; status = [string]$dependency.status
                }
            }
        }
        [ordered]@{
            id = $id; bucket = $parts[0]; name = $parts[1]
            manifest_path = $manifestPath
            manifest_sha256 = (Get-Sha256 $manifestPath)
            version = if ($info) { $info[0].version } else { $null }
            features = $featureList
            read = [ordered]@{ exit = $infoExit; ok = [bool]$info; diagnostics = $readDiagnostics }
            plan = [ordered]@{
                exit = $planExit; built = [bool]$plan; execution_available = [bool]($plan -and $plan.execution_available)
                reason = $reason; diagnostics = $planDiagnostics; capabilities = $capabilities
                external_tools = $tools; artifacts = $artifacts; operations = $operations
                dependencies = $dependencies; declared_dependencies = $declaredDependencies
                dependency_details = $dependencyDetails; command_launchers = $launchers
            }
        }
    } -ThrottleLimit $ThrottleLimit
    foreach ($result in @($results | Sort-Object { $_.id })) { $allRecords.Add($result) }
    $script:CommandLines.Add(('bucket {0} :: {1} manifests read and planned :: elapsed={2}s' -f $bucket,$entries.Count,[math]::Round($sw.Elapsed.TotalSeconds,1)))
    Write-Output ("finished {0} in {1:N1}s" -f $bucket,$sw.Elapsed.TotalSeconds)
}
$sw.Stop()
$baseline.elapsed_seconds = [math]::Round($sw.Elapsed.TotalSeconds,1)

# Attach runtime verification status and classify gaps.
foreach ($record in $allRecords) {
    $record['verified'] = [ordered]@{ status = 'not-run' }
    $record['gap_mechanisms'] = @()
    if ($verified.ContainsKey($record.id)) {
        $fact = $verified[$record.id]
        $currentVersion = $record.version
        $lifecycleMatch = $null
        $matchingVerifications = @()
        foreach ($verification in @($fact.lifecycle_verifications)) {
            if ($verification.run_exit -ne 0) { continue }
            if (($verification.coop_version -eq $currentVersion) -or ($verification.scoop_version -eq $currentVersion)) {
                $matchingVerifications += $verification
            }
        }
        if ($matchingVerifications.Count) {
            $lifecycleMatch = $matchingVerifications | Where-Object { $_.step -match 'real-update' } | Select-Object -First 1
            if (-not $lifecycleMatch) { $lifecycleMatch = $matchingVerifications[0] }
        }
        $factsMatch = $fact.facts_run_exit -eq 0 -and $fact.facts_version -and $fact.facts_version -eq $currentVersion
        if ($fact.installed_manifest_sha256 -eq $record.manifest_sha256 -and ($lifecycleMatch -or $factsMatch)) {
            $fact.status = 'real-cohort'
            $fact.verified_version = $currentVersion
            $fact.current_manifest_sha256 = $record.manifest_sha256
            $fact.current_version = $currentVersion
            if ($lifecycleMatch) {
                $fact.run_exit = $lifecycleMatch.run_exit
                $fact.run_source = 'lifecycle:' + $lifecycleMatch.step + '/' + $lifecycleMatch.label
                $fact.run_log = $lifecycleMatch.log_dir
            } else {
                $fact.run_exit = $fact.facts_run_exit
                $fact.run_source = 'facts-all.json'
                $fact.run_log = $fact.facts_run_log
            }
            $fact.evidence = @($fact.source_facts,$fact.source_lifecycle) | Where-Object { $_ }
        } elseif ($fact.installed_manifest_sha256 -eq $record.manifest_sha256) {
            $fact.status = 'cohort-run-not-bound'
            $fact.current_manifest_sha256 = $record.manifest_sha256
            $fact.current_version = $currentVersion
            $fact.note = 'no cohort run covers the installed manifest version; not counted as verified for this revision'
        } else {
            $fact.status = 'cohort-manifest-mismatch'
            $fact.current_manifest_sha256 = $record.manifest_sha256
            $fact.current_version = $currentVersion
            $fact.note = 'the recorded installed manifest differs from this denominator manifest, so it is not counted as verified for this revision'
        }
        $record.verified = $fact
    }
    $record['gap_mechanisms'] = @(Get-GapMechanism $record)
}

# Cross-bucket dependency sources: when the pinned dependency-source buckets are registered, every
# declared versions/* dependency must resolve into the plan, before the requesting package, instead
# of turning into a missing-source gap. A regression fails the measurement instead of silently
# dropping back to the environment precondition recorded before this ticket.
$declaredVersionsRecords = @($allRecords | Where-Object {
    @($_.plan.declared_dependencies | Where-Object { [string]$_ -match '^versions/' }).Count -gt 0
})
$crossBucketRecords = @($allRecords | Where-Object {
    @($_.plan.dependency_details | Where-Object { $_.bucket -eq 'versions' }).Count -gt 0
})
if (-not $SkipDependencySources) {
    foreach ($record in $declaredVersionsRecords) {
        if (-not $record.plan.execution_available) {
            throw "$($record.id) declares a versions/* dependency but its plan is not executable with the pinned versions bucket registered"
        }
        $details = @($record.plan.dependency_details)
        $versionsDetails = @($details | Where-Object { $_.bucket -eq 'versions' })
        if (-not $versionsDetails.Count) {
            throw "$($record.id) declares a versions/* dependency but the plan has no versions bucket dependency"
        }
        if (@($record.plan.diagnostics | Where-Object { $_.code -eq 'dependency-missing' }).Count) {
            throw "$($record.id) still reports dependency-missing with the pinned versions bucket registered"
        }
        $requestedIndex = $details.Count - 1
        if ($requestedIndex -lt 0 -or $details[$requestedIndex].package -ne $record.name) {
            throw "$($record.id) does not list the requested package last in dependency_order"
        }
        foreach ($versionsDetail in $versionsDetails) {
            if (-not $versionsDetail.version) { throw "$($record.id) resolved $($versionsDetail.package) from versions without a version" }
            $versionsIndex = [array]::IndexOf(@($details | ForEach-Object package),$versionsDetail.package)
            if ($versionsIndex -lt 0 -or $versionsIndex -ge $requestedIndex) { throw "$($record.id) does not plan $($versionsDetail.package) before the requested package" }
        }
    }
    if (-not $declaredVersionsRecords.Count) {
        throw 'No Main/Extras package declared a versions/* dependency in this measurement; the cross-bucket finding cannot be replayed'
    }
}
$crossBucketReport = @($crossBucketRecords | Sort-Object { $_.id } | ForEach-Object {
    [ordered]@{
        id = $_.id; version = $_.version; manifest_sha256 = $_.manifest_sha256
        declared_dependencies = @($_.plan.declared_dependencies)
        execution_available = $_.plan.execution_available
        dependency_order = @($_.plan.dependency_details)
        diagnostic_codes = @($_.plan.diagnostics | Where-Object { $_.category -ne 'verification' } | ForEach-Object { $_.category + '/' + $_.code } | Sort-Object -Unique)
    }
})

$planStatusCounts = [ordered]@{ executable = 0; 'mechanism-or-dependency-gap' = 0; 'already-installed-inventory-helper' = 0; unspecified = 0; 'plan-unavailable' = 0 }
foreach ($record in $allRecords) { $planStatusCounts[$record.plan.reason]++ }
$readFailures = @($allRecords | Where-Object { -not $_.read.ok })
$executable = @($allRecords | Where-Object { $_.plan.execution_available })
$blocked = @($allRecords | Where-Object { -not $_.plan.execution_available -and $_.plan.reason -ne 'already-installed-inventory-helper' })
$envInstalled = @($allRecords | Where-Object { $_.plan.reason -eq 'already-installed-inventory-helper' })
$verifiedRecords = @($allRecords | Where-Object { $_.verified.status -eq 'real-cohort' })
$historicalRecords = @($allRecords | Where-Object { $_.verified.status -eq 'historical-cohort' })
# Every package that is not verified at this denominator revision is reported as not run, including
# a cohort fact that no longer binds to the current manifest (cohort-run-not-bound /
# cohort-manifest-mismatch). Otherwise a failed binding would silently leave the total unclosed.
$notRunRecords = @($allRecords | Where-Object { $_.verified.status -ne 'real-cohort' -and $_.verified.status -ne 'historical-cohort' })
foreach ($record in $allRecords) {
    if ($record.verified.status -eq 'real-cohort') {
        if ($record.manifest_sha256 -ne $verified[$record.id].installed_manifest_sha256) { throw "Internal verification binding failed for $($record.id)" }
        if ($record.verified.verified_version -ne $record.version) { throw "Verified version is not the denominator manifest version for $($record.id)" }
        if ($record.verified.run_exit -ne 0) { throw "Verified run did not succeed for $($record.id)" }
        if (-not $record.verified.run_source) { throw "Verified run source is missing for $($record.id)" }
    }
}
if (($planStatusCounts.Values | Measure-Object -Sum).Sum -ne $allRecords.Count) { throw 'Plan status accounting does not cover every manifest' }
if (($readFailures.Count + @($allRecords | Where-Object { $_.read.ok }).Count) -ne $allRecords.Count) { throw 'Read status accounting does not cover every manifest' }
if (($verifiedRecords.Count + $historicalRecords.Count + $notRunRecords.Count) -ne $allRecords.Count) { throw 'Verification status accounting does not cover every manifest' }
if ($verifiedRecords.Count -gt $verified.Count) { throw 'Verified accounting exceeds the supplied cohort facts' }

$featureStats = [ordered]@{}
foreach ($record in $allRecords) {
    foreach ($feature in $record.features) {
        if (-not $featureStats.Contains($feature)) {
            $featureStats[$feature] = [ordered]@{ mechanism = $feature; manifests = 0; read_ok = 0; executable = 0; blocked = 0; environment_installed = 0; verified = 0; gap_ids = @(); verified_ids = @() }
        }
        $entry = $featureStats[$feature]
        $entry.manifests++
        if ($record.read.ok) { $entry.read_ok++ }
        if ($record.plan.execution_available) { $entry.executable++ }
        if ($record.plan.reason -eq 'already-installed-inventory-helper') { $entry.environment_installed++ }
        elseif (-not $record.plan.execution_available) { $entry.blocked++; $entry.gap_ids += $record.id }
        if ($record.verified.status -eq 'real-cohort') { $entry.verified++; $entry.verified_ids += $record.id }
    }
}
$mechanisms = @($featureStats.Values | Sort-Object mechanism)

$diagnosticStats = [ordered]@{}
foreach ($record in $allRecords) {
    foreach ($diagnostic in $record.plan.diagnostics) {
        $key = $diagnostic.category + '/' + $diagnostic.code
        if (-not $diagnosticStats.Contains($key)) {
            $diagnosticStats[$key] = [ordered]@{ key = $key; category = $diagnostic.category; code = $diagnostic.code; count = 0; message = $diagnostic.message; ids = @() }
        }
        $diagnosticStats[$key].count++
        $diagnosticStats[$key].ids += $record.id
    }
}
$gapStats = [ordered]@{}
foreach ($record in $allRecords) {
    foreach ($mechanism in $record.gap_mechanisms) {
        if (-not $gapStats.Contains($mechanism)) {
            $gapStats[$mechanism] = [ordered]@{ mechanism = $mechanism; count = 0; ids = @(); codes = @(); messages = @() }
        }
        $gapStats[$mechanism].count++
        $gapStats[$mechanism].ids += $record.id
        foreach ($diagnostic in $record.plan.diagnostics) {
            if ((Get-DiagnosticMechanism $diagnostic) -ne $mechanism) { continue }
            $key = $diagnostic.category + '/' + $diagnostic.code
            if ($gapStats[$mechanism].codes -notcontains $key) { $gapStats[$mechanism].codes += $key }
            if ($diagnostic.message -and $gapStats[$mechanism].messages -notcontains $diagnostic.message) { $gapStats[$mechanism].messages += $diagnostic.message }
        }
    }
}
$gapList = @($gapStats.Values | Sort-Object mechanism)
$capabilityStats = [ordered]@{}
foreach ($record in $allRecords) {
    foreach ($capability in $record.plan.capabilities) {
        if (-not $capabilityStats.Contains($capability.id)) { $capabilityStats[$capability.id] = [ordered]@{ id = $capability.id; manifests = 0; supported = 0; unsupported = 0; unsupported_ids = @() } }
        $capabilityStats[$capability.id].manifests++
        if ($capability.supported) { $capabilityStats[$capability.id].supported++ }
        else { $capabilityStats[$capability.id].unsupported++; $capabilityStats[$capability.id].unsupported_ids += $record.id }
    }
}
$toolStats = [ordered]@{}
foreach ($record in $allRecords) {
    foreach ($tool in $record.plan.external_tools) {
        if (-not $toolStats.Contains($tool.name)) { $toolStats[$tool.name] = [ordered]@{ name = $tool.name; manifests = 0; available = 0; unavailable = 0; unavailable_ids = @() } }
        $toolStats[$tool.name].manifests++
        if ($tool.available) { $toolStats[$tool.name].available++ }
        else { $toolStats[$tool.name].unavailable++; $toolStats[$tool.name].unavailable_ids += $record.id }
    }
}
$formatStats = [ordered]@{}
foreach ($record in $allRecords) {
    $seenFormats = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($artifact in $record.plan.artifacts) {
        if (-not $formatStats.Contains($artifact.archive)) { $formatStats[$artifact.archive] = [ordered]@{ format = $artifact.archive; artifacts = 0; manifests = 0; verified_manifests = 0; ids = @() } }
        $formatStats[$artifact.archive].artifacts++
        if ($formatStats[$artifact.archive].ids -notcontains $record.id) { $formatStats[$artifact.archive].ids += $record.id }
        if ($seenFormats.Add($artifact.archive)) {
            $formatStats[$artifact.archive].manifests++
            if ($record.verified.status -eq 'real-cohort') { $formatStats[$artifact.archive].verified_manifests++ }
        }
    }
}
$algorithmStats = [ordered]@{}
foreach ($record in $allRecords) {
    foreach ($artifact in $record.plan.artifacts) {
        if (-not $algorithmStats.Contains($artifact.algorithm)) { $algorithmStats[$artifact.algorithm] = [ordered]@{ algorithm = $artifact.algorithm; artifacts = 0; manifests = 0; ids = @() } }
        $algorithmStats[$artifact.algorithm].artifacts++
        if ($algorithmStats[$artifact.algorithm].ids -notcontains $record.id) { $algorithmStats[$artifact.algorithm].ids += $record.id; $algorithmStats[$artifact.algorithm].manifests++ }
    }
}

$samples = @((@($blocked | ForEach-Object { $_.id }) + @($verifiedRecords | ForEach-Object { $_.id })) | Sort-Object -Unique)
foreach ($id in $samples) {
    $parts = $id -split '/',2
    $destination = Join-Path $sampleDir ($parts[0]+'/'+$parts[1])
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $infoResult = Invoke-Coop @('--root',$InventoryRoot,'--arch','64bit','info',$id,'--json') ('sample-info-'+$parts[1])
    $infoResult.text | Set-Content -LiteralPath (Join-Path $destination 'info.json') -Encoding utf8
    $planResult = Invoke-Coop @('--root',$InventoryRoot,'--arch','64bit','install',$id,'--dry-run','--json') ('sample-plan-'+$parts[1])
    $planResult.text | Set-Content -LiteralPath (Join-Path $destination 'plan.json') -Encoding utf8
    $script:CommandLines.Add(('sample {0} :: info exit={1} plan exit={2}' -f $id,$infoResult.exit,$planResult.exit))
}

$summary = [ordered]@{
    schema = 1
    generated_at = $baseline.generated_at
    project_head = $baseline.project_head
    coop = $baseline.coop
    platform = $baseline.platform
    buckets = $baseline.buckets
    scope = $baseline.scope
    denominator = $denominator
    totals = [ordered]@{
        manifests = $allRecords.Count
        read_ok = @($allRecords | Where-Object { $_.read.ok }).Count
        read_failed = $readFailures.Count
        plan_built = @($allRecords | Where-Object { $_.plan.built }).Count
        plan_executable = $executable.Count
        plan_blocked = $blocked.Count
        environment_installed_helper = $envInstalled.Count
        plan_unavailable = $planStatusCounts['plan-unavailable']
        verified_real_cohort = $verifiedRecords.Count
        verified_historical_cohort = $historicalRecords.Count
        not_run = $notRunRecords.Count
    }
    plan_status = $planStatusCounts
    mechanisms = $mechanisms
    gaps = $gapList
    diagnostics = @($diagnosticStats.Values | Sort-Object key)
    capabilities = @($capabilityStats.Values | Sort-Object id)
    external_tools = @($toolStats.Values | Sort-Object name)
    artifact_formats = @($formatStats.Values | Sort-Object format)
    hash_algorithms = @($algorithmStats.Values | Sort-Object algorithm)
    verified = @($verifiedRecords | ForEach-Object { $_.verified } | Sort-Object package)
    verified_source = $baseline.verified_source
    cross_bucket_dependencies = $crossBucketReport
    manifest_verification = $mainVerification
    shared_root = $baseline.shared_root
    external_helper_links = $helperTargets
}
foreach ($record in $allRecords) {
    $script:CommandLines.Add(('measure {0} :: coop --root {1} --arch 64bit info {0} --json :: exit={2}' -f $record.id,$InventoryRoot,$record.read.exit))
    $script:CommandLines.Add(('measure {0} :: coop --root {1} --arch 64bit install {0} --dry-run --json :: exit={2}' -f $record.id,$InventoryRoot,$record.plan.exit))
}
$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $runDir 'summary.json') -Encoding utf8
$allRecords | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $runDir 'manifests.json') -Encoding utf8
$crossBucketReport | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $runDir 'cross-bucket-dependencies.json') -Encoding utf8
$script:CommandLines | Set-Content -LiteralPath (Join-Path $runDir 'commands.log') -Encoding utf8
$baseline | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDir 'run-baseline.json') -Encoding utf8

# Compact, commit-ready projection of the same measurement.
$baselineProjection = [ordered]@{
    schema = 1
    generated_at = $baseline.generated_at
    project_head = $baseline.project_head
    coop = $baseline.coop
    platform = $baseline.platform
    scope = $baseline.scope
    buckets = $baseline.buckets
    denominator = $denominator
    totals = $summary.totals
    mechanisms = $mechanisms
    gaps = $gapList
    artifacts = @($summary.artifact_formats | ForEach-Object { [ordered]@{ format = $_.format; artifacts = $_.artifacts; manifests = $_.manifests; verified_manifests = $_.verified_manifests } })
    hash_algorithms = @($summary.hash_algorithms | ForEach-Object { [ordered]@{ algorithm = $_.algorithm; artifacts = $_.artifacts; manifests = $_.manifests } })
    verified_source = $baseline.verified_source
    verified = @($summary.verified)
    cross_bucket_dependencies = $summary.cross_bucket_dependencies
    shared_root = $baseline.shared_root
    manifest_verification = $mainVerification
    external_helper_links = $helperTargets
}
$baselineProjection | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runDir 'baseline.json') -Encoding utf8

if (-not $SkipRealRootSnapshot) {
    $snapshotAfter = Get-RootSnapshot $ScoopRoot
    $snapshotAfter | Set-Content -LiteralPath (Join-Path $runDir 'shared-root-after.txt') -Encoding utf8
    $changes = @(Compare-Object $snapshotBefore $snapshotAfter)
    $changes | ForEach-Object { $_.InputObject } | Set-Content -LiteralPath (Join-Path $runDir 'shared-root-changes.txt') -Encoding utf8
    if ($changes.Count) { throw "The inventory changed $($changes.Count) files under the shared Scoop root" }
    Write-Output 'shared root unchanged (recursive path/length/mtime snapshot)'
}

Write-Output ''
Write-Output ('Denominator: Main {0} + Extras {1} = {2} manifests' -f $denominator.main,$denominator.extras,$denominator.total)
Write-Output ('Read: {0} ok, {1} failed; plan: {2} executable, {3} blocked, {4} helper-installed in the inventory root, {5} unavailable' -f `
    $summary.totals.read_ok,$summary.totals.read_failed,$summary.totals.plan_executable,$summary.totals.plan_blocked,
    $summary.totals.environment_installed_helper,$summary.totals.plan_unavailable)
Write-Output ('Runtime verified at this denominator revision: {0} (historical cohort: {1}, not run: {2}, reported total: {3})' -f `
    $summary.totals.verified_real_cohort,$summary.totals.verified_historical_cohort,$summary.totals.not_run,($summary.totals.verified_real_cohort+$summary.totals.verified_historical_cohort+$summary.totals.not_run))
foreach ($gap in $gapList) {
    Write-Output ('Gap {0}: {1} package(s); {2}' -f $gap.mechanism,$gap.count,($gap.codes -join ', '))
}
foreach ($record in $crossBucketReport) {
    Write-Output ('Cross-bucket dependency {0}: {1}' -f $record.id,(@($record.dependency_order | Where-Object { $_.bucket -eq 'versions' } | ForEach-Object { $_.request + '@' + $_.version }) -join ', '))
}
Write-Output ("Evidence: {0}" -f $runDir)

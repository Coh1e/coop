param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$EvidenceDir,
    [string]$ScoopRoot = 'C:\Users\Neo\scoop'
)
$ErrorActionPreference = 'Stop'
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$ScoopRoot = [IO.Path]::GetFullPath($ScoopRoot)
$scoop = (Get-Command scoop.ps1 -ErrorAction Stop).Source
$commands = [System.Collections.Generic.List[object]]::new()
$installedByTest = [System.Collections.Generic.List[string]]::new()
function Run([string]$name,[string]$exe,[string[]]$arguments) {
    $log = Join-Path $EvidenceDir (($name -replace '[\\/:*?"<>|]','-')+'.log')
    $output = & $exe @arguments 2>&1 | Out-String
    $exit = $LASTEXITCODE
    Set-Content -LiteralPath $log -Value $output -Encoding utf8
    $commands.Add([pscustomobject]@{name=$name;exe=$exe;arguments=$arguments;exit=$exit;log=$log})
    return [pscustomobject]@{exit=$exit;output=$output;log=$log}
}
function Coop([string]$name,[string[]]$arguments) { return Run $name $CoopExe (@('--root',$ScoopRoot)+$arguments) }
function Scoop([string]$name,[string[]]$arguments) { return Run $name $scoop $arguments }
function Assert-True([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
function Read-Json([object]$output) { return (($output -join "`n") | ConvertFrom-Json) }
function HashOf([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function InstalledEntry([string]$name) {
    $items = (Coop ($name+'-list') @('list','--json')).output | ConvertFrom-Json
    $entry = @($items | Where-Object { $_.name -eq $name -and ($_.status -eq 'installed' -or $_.status -eq 'ready') })
    if ($entry.Count -eq 0) { return $null }
    if ($entry.Count -ne 1) { throw "Duplicate installed entries for $name" }
    return $entry[0]
}
function Assert-PlanMatchesJournal($plan,$journal,[string]$name) {
    $planned = @($plan.ir_operations | ForEach-Object operation)
    $observed = @($journal.observed_steps)
    Assert-True (($planned -join ',') -eq ($observed -join ',')) "execution did not follow the displayed plan for $name`: planned=$($planned -join ',') observed=$($observed -join ',')"
    return [pscustomobject]@{planned=$planned;observed=$observed}
}
$temporaryBucket = $null
try {
    $inventoryBefore = (Coop 'coop-list-before' @('list','--json')).output | ConvertFrom-Json
    $gitBefore = @($inventoryBefore | Where-Object { $_.name -eq 'git' })
    Assert-True ($gitBefore.Count -eq 1) 'The selected real Scoop root does not contain exactly one git installation'
    if (Test-Path "$ScoopRoot/apps/git-tfs/current") { throw 'git-tfs is already installed; refusing to change the selected real root' }
    $scoopVersion = (Scoop 'scoop-version' @('--version')).output.Trim()
    $gitBucketHead = (& git -C "$ScoopRoot/buckets/main" rev-parse HEAD 2>&1 | Out-String).Trim()
    $gitRunBefore = Run 'git-before' "$ScoopRoot/shims/git.exe" @('--version')
    Assert-True ($gitRunBefore.exit -eq 0 -and $gitRunBefore.output -match '^git version') "The selected real git installation does not run: $($gitRunBefore.output)"

    # A real Main Manifest (git-tfs) declares depends: git. Preview resolves it from the real
    # installed git and produces the dependency's own IR sequence without writing product state.
    $preview = Coop 'git-tfs-preview' @('install','git-tfs','--dry-run','--json')
    Assert-True ($preview.exit -eq 0) "real dependency preview failed: $($preview.output)"
    $plan = Read-Json $preview.output
    Assert-True ($plan.execution_available -eq $true) 'real dependency preview was not executable'
    $dependencyOrder = @($plan.dependency_order)
    Assert-True ($dependencyOrder.Count -eq 2) "real dependency order has $($dependencyOrder.Count) entries, expected 2"
    $gitPlan = $dependencyOrder[0]
    $rootPlan = $dependencyOrder[1]
    Assert-True ($gitPlan.package -eq 'git' -and $gitPlan.installed -eq $true -and $gitPlan.status -eq 'satisfied') 'preview did not reuse the real installed git dependency'
    Assert-True ($gitPlan.installed_version -eq $gitBefore[0].version) 'preview reused a different git version than the shared installation fact'
    Assert-True (@($gitPlan.ir_operations).Count -eq 0) 'a satisfied dependency unexpectedly has installation operations'
    Assert-True ($rootPlan.package -eq 'git-tfs' -and $rootPlan.status -eq 'planned' -and @($rootPlan.ir_operations).Count -gt 0) 'preview omitted the requested package operation sequence'
    Assert-True (-not (Test-Path "$ScoopRoot/apps/git-tfs")) 'dependency preview wrote a product installation'
    Assert-True (-not (Test-Path "$ScoopRoot/.coop/packages/git-tfs.json")) 'dependency preview wrote a Coop record'

    # Execute the same plan: the installed dependency is skipped and the requested package is
    # installed in its own transaction. The journal proves the displayed root operations ran.
    $install = Coop 'git-tfs-install' @('install','git-tfs','--json')
    Assert-True ($install.exit -eq 0) "real dependency install failed: $($install.output)"
    $installedByTest.Add('git-tfs')
    $result = Read-Json $install.output
    $packages = @($result.packages)
    Assert-True ($packages.Count -eq 2) 'real dependency install did not report both packages'
    Assert-True ($packages[0].package -eq 'git' -and $packages[0].status -eq 'skipped' -and $packages[0].reason -eq 'already-installed') 'real installed dependency was not reused as skipped'
    Assert-True ($packages[1].package -eq 'git-tfs' -and $packages[1].status -eq 'success' -and $packages[1].requested -eq $true) 'requested real package was not installed after its dependency'
    $journal = Get-Content -LiteralPath $packages[1].journal -Raw | ConvertFrom-Json
    $planMatch = Assert-PlanMatchesJournal $plan $journal 'git-tfs'
    $record = Get-Content -LiteralPath "$ScoopRoot/.coop/packages/git-tfs.json" -Raw | ConvertFrom-Json
    Assert-True ('git' -in @($record.dependencies)) 'the Coop record did not preserve the declared real dependency'
    $gitTfsRun = Run 'git-tfs-run' "$ScoopRoot/shims/git-tfs.exe" @('--version')
    Assert-True ($gitTfsRun.exit -eq 0 -and $gitTfsRun.output.Trim().Length -gt 0) "installed git-tfs did not run: $($gitTfsRun.output)"

    # Reverse protection includes the real installed package's declared dependents. The Coop-
    # installed git-tfs blocks git removal in both preview and execution.
    $blockedPreview = Coop 'git-uninstall-preview' @('uninstall','git','--dry-run','--json')
    Assert-True ($blockedPreview.exit -ne 0) 'blocked reverse-dependency preview unexpectedly succeeded'
    Assert-True (($blockedPreview.output -join "`n") -match 'blocking_dependents' -and ($blockedPreview.output -join "`n") -match 'git-tfs') 'reverse-dependency preview did not list git-tfs'
    Assert-True (Test-Path "$ScoopRoot/apps/git/current") 'blocked uninstall preview changed git'
    $blocked = Coop 'git-uninstall' @('uninstall','git','--json')
    Assert-True ($blocked.exit -ne 0) 'blocked reverse-dependency uninstall unexpectedly succeeded'
    Assert-True (($blocked.output -join "`n") -match 'git-tfs') 'blocked uninstall did not explain the dependent'
    $gitRunBlocked = Run 'git-after-blocked-uninstall' "$ScoopRoot/shims/git.exe" @('--version')
    Assert-True ($gitRunBlocked.exit -eq 0) 'git stopped working after a refused uninstall'

    # Removing the dependent does not cascade to git. git remains installed and runnable until an
    # explicit uninstall is requested.
    $remove = Coop 'git-tfs-uninstall' @('uninstall','git-tfs','--json')
    Assert-True ($remove.exit -eq 0) "real dependent uninstall failed: $($remove.output)"
    $installedByTest.Remove('git-tfs') | Out-Null
    Assert-True (-not (Test-Path "$ScoopRoot/apps/git-tfs/current")) 'dependent uninstall left git-tfs current'
    Assert-True (Test-Path "$ScoopRoot/apps/git/current") 'removing the dependent cascaded into removing git'
    $gitRunAfter = Run 'git-after-dependent-removal' "$ScoopRoot/shims/git.exe" @('--version')
    Assert-True ($gitRunAfter.exit -eq 0) 'git stopped working after the dependent was removed'
    $gitEntry = InstalledEntry 'git'
    Assert-True ($null -ne $gitEntry) 'git disappeared from the shared installation list'

    # A real missing dependency is diagnosed before any write. Main/terraform-provider-ibm
    # declares versions/terraform011, which is not present in the selected buckets.
    $missing = Coop 'terraform-provider-ibm-missing-preview' @('install','terraform-provider-ibm','--dry-run','--json')
    Assert-True ($missing.exit -ne 0) 'preview with a missing real dependency unexpectedly succeeded'
    Assert-True (($missing.output -join "`n") -match 'dependency-missing' -and ($missing.output -join "`n") -match 'versions/terraform011') 'missing real dependency was not diagnosed with its source identity'
    Assert-True (-not (Test-Path "$ScoopRoot/apps/terraform-provider-ibm")) 'missing dependency preview wrote a product installation'

    $inventoryAfter = (Coop 'coop-list-after' @('list','--json')).output | ConvertFrom-Json
    $beforeNames = @($inventoryBefore | ForEach-Object { "$($_.name)@$($_.version)" } | Sort-Object)
    $afterNames = @($inventoryAfter | ForEach-Object { "$($_.name)@$($_.version)" } | Sort-Object)
    Assert-True (($beforeNames -join '|') -eq ($afterNames -join '|')) 'the shared installation inventory changed outside the test'
    $evidence = [pscustomobject]@{
        coop_exe = $CoopExe
        coop_sha256 = (HashOf $CoopExe)
        coop_version = (& $CoopExe --version | Out-String).Trim()
        scoop_version = $scoopVersion
        main_bucket_revision = $gitBucketHead
        scoop_root = $ScoopRoot
        inventory_before = $inventoryBefore
        inventory_after = $inventoryAfter
        git_before = $gitBefore[0]
        preview = [pscustomobject]@{dependency_order=$dependencyOrder;execution_available=$plan.execution_available}
        install_packages = $packages
        root_plan_match = $planMatch
        git_tfs_program = $gitTfsRun.output.Trim()
        blocked_uninstall = $blockedPreview.output
        git_version_before = $gitRunBefore.output.Trim()
        git_version_after = $gitRunAfter.output.Trim()
        missing_dependency = $missing.output
        commands = $commands
    }
    $evidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $EvidenceDir 'real-scoop-dependencies-evidence.json') -Encoding utf8
    Write-Output "PASS real dependency reuse and reverse-dependency protection: $ScoopRoot"
    exit 0
} finally {
    if ($null -ne $temporaryBucket -and (Test-Path -LiteralPath $temporaryBucket)) {
        Remove-Item -LiteralPath $temporaryBucket -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($name in @($installedByTest)) {
        if (Test-Path "$ScoopRoot/apps/$name/current") {
            $cleanup = Coop ($name+'-cleanup') @('uninstall',$name,'--json')
            if ($cleanup.exit -ne 0) { Write-Warning "Could not clean up test installation $name : $($cleanup.output)" }
        }
    }
}

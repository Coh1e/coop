param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$projectTests = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($projectTests,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$source = Join-Path $TestRoot 'source'
$root = Join-Path $TestRoot ('root-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$source/bucket",$root -Force | Out-Null
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$source/bucket/jq.json" -Force
& $CoopExe --root $root bucket add local $source
if ($LASTEXITCODE -ne 0) { throw 'local bucket add failed' }
$items = (& $CoopExe --root $root search jq --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $items[0].bucket -ne 'local') { throw 'registered local bucket not queryable' }
& $CoopExe --root $root bucket remove local
if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$source/bucket/jq.json")) { throw 'local bucket removal changed source' }
Write-Output 'PASS local bucket registration, query, safe removal'

# Git is only a fixture authoring tool; its configuration and hooks are isolated.
$git = (Get-Command git.exe -ErrorAction Stop).Source
$empty = Join-Path $TestRoot 'empty-git-config'
[IO.File]::WriteAllText($empty,'')
$templates = Join-Path $TestRoot 'empty-templates'
New-Item -ItemType Directory -Path $templates -Force | Out-Null
function Invoke-FixtureGit([string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($git)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = $empty
    $start.EnvironmentVariables['GIT_CONFIG_SYSTEM'] = $empty
    $start.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
    $start.EnvironmentVariables['XDG_CONFIG_HOME'] = $templates
    Add-ProcessArgument $start ('-c')
    Add-ProcessArgument $start ('core.hooksPath='+$templates)
    foreach ($argument in $Arguments) { Add-ProcessArgument $start ($argument) }
    $process = [Diagnostics.Process]::Start($start)
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $output = $outputTask.GetAwaiter().GetResult()
    $errorText = $errorTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) { throw "Fixture git failed: $errorText" }
    return $output.Trim()
}
$repository = Join-Path $TestRoot ('repository-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$repository/bucket" -Force | Out-Null
Invoke-FixtureGit @('init','-b','trunk',('--template='+$templates),$repository) | Out-Null
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$repository/bucket/jq.json"
Invoke-FixtureGit @('-C',$repository,'add','bucket') | Out-Null
Invoke-FixtureGit @('-C',$repository,'-c','user.name=CoopTest','-c','user.email=coop@example.invalid','commit','-m','initial') | Out-Null
$url = ([uri]($repository.Replace('\','/')+'/')).AbsoluteUri
$firstText = & $CoopExe --root $root bucket add git $url --branch trunk --json
if ($LASTEXITCODE -ne 0) { throw 'Git library clone failed' }
$first = ($firstText -join "`n") | ConvertFrom-Json
$sharedGit = Join-Path $root 'buckets/git'
if ($first.branch -ne 'trunk' -or $first.revision -ne (Invoke-FixtureGit @('-C',$repository,'rev-parse','HEAD'))) { throw 'branch/revision lost' }
if ($first.path -ne $sharedGit -or -not (Test-Path -LiteralPath "$sharedGit/.git")) { throw 'Git bucket was not cloned into the shared bucket directory' }
if ($first.first_refresh -ne $true -or $first.refresh_kind -ne 'first' -or $first.changed -ne $true -or $first.files_count -le 0) { throw 'first refresh evidence is incomplete' }
if (Test-Path -LiteralPath "$root/.coop/snapshots") { throw 'Git bucket used a private snapshot instead of the shared working tree' }
if ((Invoke-FixtureGit @('-C',$sharedGit,'rev-parse','HEAD')) -ne $first.revision) { throw 'shared working tree revision differs from the published record' }
$gitIndexPath = Join-Path $root '.coop/cache/index/git.json'
$firstIndexHash = (Get-FileHash -LiteralPath $gitIndexPath).Hash
$same = (& $CoopExe --root $root bucket update git --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $same.changed -ne $false -or $same.path -ne $first.path -or $same.refresh_kind -ne 'unchanged' -or $same.first_refresh -ne $false) { throw 'unchanged bucket unnecessarily republished' }
if ((Get-FileHash -LiteralPath $gitIndexPath).Hash -ne $firstIndexHash) { throw 'no-change refresh rebuilt the search index' }
$trackingDirectory = Join-Path $root 'buckets/tracked'
New-Item -ItemType Directory -Path (Split-Path $trackingDirectory) -Force | Out-Null
Invoke-FixtureGit @('clone','--origin','upstream','--branch','trunk',$url,$trackingDirectory) | Out-Null
Invoke-FixtureGit @('-C',$trackingDirectory,'branch','-m','local-name') | Out-Null
Invoke-FixtureGit @('-C',$trackingDirectory,'remote','add','origin','https://127.0.0.1:9/incorrect.git') | Out-Null
$tracked = (& $CoopExe --root $root bucket update tracked --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $tracked.url -ne $url -or $tracked.branch -ne 'trunk' -or $tracked.remote -ne 'upstream' -or $tracked.path -ne $trackingDirectory) { throw 'actual tracking remote/branch was not preserved' }
if (-not (Test-Path -LiteralPath "$trackingDirectory/.git")) { throw 'original Scoop Git metadata was removed' }
if ((Invoke-FixtureGit @('-C',$trackingDirectory,'rev-parse','--abbrev-ref','HEAD')) -ne 'local-name') { throw 'existing local branch name was not preserved' }
if ((Invoke-FixtureGit @('-C',$trackingDirectory,'rev-parse','HEAD')) -ne $tracked.revision) { throw 'adopted shared bucket revision was not published' }
if ($tracked.adopted -ne $true) { throw 'in-place adoption was not recorded' }
$trackedAgain = (& $CoopExe --root $root bucket update tracked --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $trackedAgain.changed -ne $false -or $trackedAgain.adopted -ne $true) { throw 'adoption provenance was lost on a later refresh' }
Copy-Item "$PSScriptRoot/corpus/main/ripgrep.json" "$repository/bucket/ripgrep.json"
Invoke-FixtureGit @('-C',$repository,'add','bucket') | Out-Null
Invoke-FixtureGit @('-C',$repository,'-c','user.name=CoopTest','-c','user.email=coop@example.invalid','commit','-m','add ripgrep') | Out-Null
$changed = (& $CoopExe --root $root bucket update git --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $changed.changed -ne $true -or $changed.path -ne $first.path -or $changed.refresh_kind -ne 'changed') { throw 'new revision was not published in place' }
if ($changed.previous_revision -ne $first.revision -or $changed.changed_files -le 0) { throw 'changed refresh evidence is incomplete' }
if ((Invoke-FixtureGit @('-C',$sharedGit,'rev-parse','HEAD')) -ne $changed.revision) { throw 'shared working tree did not advance to the new revision' }
if ((Get-FileHash -LiteralPath $gitIndexPath).Hash -eq $firstIndexHash) { throw 'changed refresh did not rebuild the search index' }
$items = (& $CoopExe --root $root search ripgrep --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $items.Count -ne 1) { throw 'new manifest not visible' }
Invoke-FixtureGit @('-C',$repository,'rm','bucket/jq.json') | Out-Null
Invoke-FixtureGit @('-C',$repository,'-c','user.name=CoopTest','-c','user.email=coop@example.invalid','commit','-m','delete jq') | Out-Null
$deleted = (& $CoopExe --root $root bucket update git --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'delete refresh failed' }
$items = @(Get-JsonItems (& $CoopExe --root $root search git/jq --json))
if ($LASTEXITCODE -ne 0 -or $items.Count -ne 0) { throw 'removed manifest remained visible' }
if (Test-Path -LiteralPath "$sharedGit/bucket/jq.json") { throw 'removed manifest remained in the shared working tree' }

$initialRevision = $first.revision
$pinnedText = & $CoopExe --root $root bucket add pinned $url --branch trunk --revision $initialRevision --json
if ($LASTEXITCODE -ne 0) { throw 'fixed revision add failed' }
$pinned = ($pinnedText -join "`n") | ConvertFrom-Json
if ($pinned.revision -ne $initialRevision) { throw 'fixed revision ignored' }
if ($pinned.path -ne (Join-Path $root 'buckets/pinned') -or -not (Test-Path -LiteralPath (Join-Path $pinned.path '.git'))) { throw 'fixed revision bucket is not a shared working tree' }
$pinnedAgain = (& $CoopExe --root $root bucket update pinned --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $pinnedAgain.revision -ne $initialRevision -or $pinnedAgain.changed -or $pinnedAgain.refresh_kind -ne 'unchanged') { throw 'fixed revision unexpectedly advanced' }

[IO.File]::WriteAllText((Join-Path $repository 'link-payload'),'../../outside')
$linkOid = Invoke-FixtureGit @('-C',$repository,'hash-object','-w','link-payload')
Invoke-FixtureGit @('-C',$repository,'update-index','--add','--cacheinfo',('120000,'+$linkOid+',unsafe-link')) | Out-Null
Invoke-FixtureGit @('-C',$repository,'-c','user.name=CoopTest','-c','user.email=coop@example.invalid','commit','-m','unsupported tree link') | Out-Null
Invoke-CoopNativeToFile $CoopExe "$root/unsupported-tree-error.txt" --root $root bucket update git --json | Out-Null
if ($LASTEXITCODE -eq 0) { throw 'unsafe tree was silently accepted' }
$afterFailed = (& $CoopExe --root $root bucket list --json) | ConvertFrom-Json
if (($afterFailed | Where-Object name -eq git).path -ne $deleted.path -or ($afterFailed | Where-Object name -eq git).revision -ne $deleted.revision) { throw 'failed refresh changed the published pointer' }
if ((Invoke-FixtureGit @('-C',$sharedGit,'rev-parse','HEAD')) -ne $deleted.revision) { throw 'failed refresh changed the shared working tree revision' }
if (-not (Test-Path -LiteralPath "$sharedGit/bucket/ripgrep.json")) { throw 'failed refresh removed usable shared bucket files' }
$items = (& $CoopExe --root $root search ripgrep --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $items.Count -ne 1) { throw 'failed refresh broke prior query state' }

Invoke-FixtureGit @('-C',$repository,'update-index','--force-remove','unsafe-link') | Out-Null
New-Item -ItemType Directory -Path "$repository/auxiliary" -Force | Out-Null
foreach ($number in 1..1200) { [IO.File]::WriteAllText((Join-Path $repository ('auxiliary/{0:d4}.txt' -f $number)),('fixture-'+$number)) }
Invoke-FixtureGit @('-C',$repository,'add','auxiliary') | Out-Null
Invoke-FixtureGit @('-C',$repository,'-c','user.name=CoopTest','-c','user.email=coop@example.invalid','commit','-m','interruption fixture') | Out-Null
$registryPath = Join-Path $root '.coop/buckets.json'
$journals = Join-Path $root '.coop/bucket-refresh'
$interrupted = $false
$updater = $null
for ($attempt = 1; $attempt -le 4 -and -not $interrupted; $attempt++) {
    # Give each attempt a fresh source commit so a completed attempt can be retried instead of
    # becoming a no-op. The kill is accepted only while the published registry is still old.
    [IO.File]::WriteAllText((Join-Path $repository ("interrupt-$attempt.txt")),("attempt $attempt"))
    Invoke-FixtureGit @('-C',$repository,'add',("interrupt-$attempt.txt")) | Out-Null
    Invoke-FixtureGit @('-C',$repository,'-c','user.name=CoopTest','-c','user.email=coop@example.invalid','commit','-m',("interruption trigger $attempt")) | Out-Null
    $beforeCrash = (Get-FileHash -LiteralPath $registryPath).Hash
    $existingJournals = @(Get-ChildItem -LiteralPath $journals -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $start = [Diagnostics.ProcessStartInfo]::new($CoopExe)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('--root',$root,'bucket','update','git','--json')) { Add-ProcessArgument $start ($argument) }
    $updater = [Diagnostics.Process]::Start($start)
    $updaterOutput = $updater.StandardOutput.ReadToEndAsync()
    $updaterError = $updater.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    $sawJournal = $false
    while (-not $updater.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        $newJournal = @(Get-ChildItem -LiteralPath $journals -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin $existingJournals })
        if ($newJournal.Count) {
            $sawJournal = $true
            if ((Get-FileHash -LiteralPath $registryPath).Hash -eq $beforeCrash) {
                $updater.Kill()
                $interrupted = $true
                break
            }
        }
        Start-Sleep -Milliseconds 2
    }
    if (-not $updater.HasExited) { $updater.Kill() }
    $updater.WaitForExit()
    $updaterOutput.GetAwaiter().GetResult() | Out-Null
    $updaterError.GetAwaiter().GetResult() | Out-Null
    if (-not $interrupted -and -not $sawJournal) { Start-Sleep -Milliseconds 50 }
}
if (-not $interrupted) { throw 'Failed to observe an actual in-progress refresh interruption' }
if ((Get-FileHash -LiteralPath $registryPath).Hash -ne $beforeCrash) { throw 'Interruption changed published registry' }
if (-not (Test-Path -LiteralPath (Join-Path $journals 'git.json'))) { throw 'Interrupted refresh did not leave its journal' }
$pending = @(Get-JsonItems (& $CoopExe --root $root bucket list --json)) | Where-Object name -eq git
if ($LASTEXITCODE -ne 0 -or $pending.refresh_pending -ne $true -or -not (Test-Path -LiteralPath $pending.refresh_journal)) { throw 'Interruption journal was not surfaced by bucket list' }
$items = (& $CoopExe --root $root search ripgrep --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $items.Count -ne 1) { throw 'Interruption broke previous query' }
$deleted = (& $CoopExe --root $root bucket update git --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $deleted.changed) { throw 'Retry after interruption did not recover' }
if (-not (Test-Path -LiteralPath "$sharedGit/.git") -or (Invoke-FixtureGit @('-C',$sharedGit,'rev-parse','HEAD')) -ne $deleted.revision) { throw 'Retry after interruption did not leave a usable shared bucket' }
if (Test-Path -LiteralPath (Join-Path $journals 'git.json')) { throw 'Completed refresh left an in-progress journal' }
$settled = @(Get-JsonItems (& $CoopExe --root $root bucket list --json)) | Where-Object name -eq git
if ($LASTEXITCODE -ne 0 -or $settled.refresh_pending) { throw 'Completed refresh still reports a pending journal' }
Write-Output ('PASS actual updater process interruption, exit='+$updater.ExitCode+'; journal observed and diagnosed; old record and query retained; retry completed')

# The product removes its lock file after a finished command, so a concurrent-writer fixture must
# create the file it is about to hold.
New-Item -ItemType Directory -Path (Join-Path $root '.coop') -Force | Out-Null
New-Item -ItemType File -Path (Join-Path $root '.coop/write.lock') -Force | Out-Null
$heldLock = [IO.File]::Open((Join-Path $root '.coop/write.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    Invoke-CoopNativeToFile $CoopExe "$root/busy-error.txt" --root $root bucket update git --json | Out-Null
    if ($LASTEXITCODE -eq 0) { throw 'Concurrent write lock was ignored' }
    $items = (& $CoopExe --root $root search ripgrep --json) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $items.Count -ne 1) { throw 'Read query was blocked by write lock' }
} finally { $heldLock.Dispose() }

[IO.File]::WriteAllText((Join-Path $repository 'commit-proof.txt'),'new revision')
Invoke-FixtureGit @('-C',$repository,'add','commit-proof.txt') | Out-Null
Invoke-FixtureGit @('-C',$repository,'-c','user.name=CoopTest','-c','user.email=coop@example.invalid','commit','-m','state commit fixture') | Out-Null
$beforeCommitFailure = (Get-FileHash -LiteralPath $registryPath).Hash
$heldRegistry = [IO.File]::Open($registryPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try {
    Invoke-CoopNativeToFile $CoopExe "$root/commit-error.txt" --root $root bucket update git --json | Out-Null
    if ($LASTEXITCODE -eq 0) { throw 'Commit sharing violation was ignored' }
    if ((Get-FileHash -LiteralPath $registryPath).Hash -ne $beforeCommitFailure) { throw 'Failed registry commit changed state' }
} finally { $heldRegistry.Dispose() }
$deleted = (& $CoopExe --root $root bucket update git --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $deleted.changed) { throw 'Retry after commit failure did not publish' }
Write-Output 'PASS concurrent writer exclusion, readable stable state, failed atomic commit and retry'

$modifiedManifest = Join-Path $deleted.path 'bucket/ripgrep.json'
[IO.File]::AppendAllText($modifiedManifest,' ')
Invoke-CoopNativeToFile $CoopExe "$root/local-change-error.txt" --root $root bucket update git --json | Out-Null
if ($LASTEXITCODE -eq 0) { throw 'current local modification was discarded' }
if (-not (Get-Content -LiteralPath $modifiedManifest -Raw).EndsWith(' ')) { throw 'local modification was not preserved' }
if ((Invoke-FixtureGit @('-C',$sharedGit,'rev-parse','HEAD')) -ne $deleted.revision) { throw 'local-change refusal moved the shared working tree revision' }
if (-not (Test-Path -LiteralPath "$sharedGit/bucket/ripgrep.json")) { throw 'local-change refusal removed usable shared bucket files' }
if (@(Get-JsonItems (& $CoopExe --root $root search ripgrep --json)).Count -ne 1) { throw 'local-change refusal broke local query' }
Write-Output 'PASS Git library clone into shared bucket, non-default branch, in-place incremental refresh, local-change protection'

# A clean local commit is not a worktree modification, but it is still local history. The refresh
# must stop before checkout instead of discarding it.
$localCommitText = & $CoopExe --root $root bucket add localcommit $url --branch trunk --json
if ($LASTEXITCODE -ne 0) { throw 'local-commit fixture bucket add failed' }
$localCommitRecord = ($localCommitText -join "`n") | ConvertFrom-Json
$localCommitPath = $localCommitRecord.path
[IO.File]::WriteAllText((Join-Path $localCommitPath 'bucket/custom.json'),'{"version":"1.0.0","url":"https://invalid.example/custom.exe","hash":"'+('0'*64)+'"}')
Invoke-FixtureGit @('-C',$localCommitPath,'add','bucket/custom.json') | Out-Null
Invoke-FixtureGit @('-C',$localCommitPath,'-c','user.name=CoopTest','-c','user.email=coop@example.invalid','commit','-m','local custom commit') | Out-Null
$localCommitHead = Invoke-FixtureGit @('-C',$localCommitPath,'rev-parse','HEAD')
Invoke-CoopNativeToFile $CoopExe "$root/local-commit-error.txt" --root $root bucket update localcommit --json | Out-Null
if ($LASTEXITCODE -eq 0) { throw 'a clean local commit was silently discarded' }
if ((Invoke-FixtureGit @('-C',$localCommitPath,'rev-parse','HEAD')) -ne $localCommitHead) { throw 'refused refresh moved the local commit' }
if (-not (Test-Path -LiteralPath (Join-Path $localCommitPath 'bucket/custom.json'))) { throw 'refused refresh deleted the local custom manifest' }
$localCommitAfter = @(Get-JsonItems (& $CoopExe --root $root bucket list --json)) | Where-Object name -eq localcommit
if ($localCommitAfter.revision -ne $localCommitRecord.revision) { throw 'refused refresh changed the published local-commit record' }
& $CoopExe --root $root bucket remove localcommit | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'remove of the local-commit bucket failed' }
$localReaddText = & $CoopExe --root $root bucket add localcommit $url --branch trunk --json
if ($LASTEXITCODE -ne 0) { throw 're-registration of the local-commit bucket failed' }
$localReadd = ($localReaddText -join "`n") | ConvertFrom-Json
if ($localReadd.registered -ne $true -or $localReadd.adopted -ne $true -or $localReadd.revision -ne $localCommitHead) { throw 're-registration did not adopt the current local commit' }
if ((Invoke-FixtureGit @('-C',$localCommitPath,'rev-parse','HEAD')) -ne $localCommitHead -or -not (Test-Path -LiteralPath (Join-Path $localCommitPath 'bucket/custom.json'))) { throw 're-registration moved or deleted the local commit' }
Invoke-CoopNativeToFile $CoopExe "$root/local-commit-readd-error.txt" --root $root bucket update localcommit --json | Out-Null
if ($LASTEXITCODE -eq 0) { throw 're-registered local commit was silently discarded by update' }
if ((Invoke-FixtureGit @('-C',$localCommitPath,'rev-parse','HEAD')) -ne $localCommitHead) { throw 'update after re-registration moved the local commit' }
Write-Output 'PASS clean local commit is preserved; non-fast-forward refresh is refused before and after re-registration'

# Removing only unregisters. Re-adding must adopt the existing shared worktree instead of leaving
# the name in a dead end; updating a removed name must fail honestly.
$readdText = & $CoopExe --root $root bucket add readd $url --branch trunk --json
if ($LASTEXITCODE -ne 0) { throw 're-registration fixture add failed' }
$readd = ($readdText -join "`n") | ConvertFrom-Json
& $CoopExe --root $root bucket remove readd | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'remove before re-registration failed' }
Invoke-CoopNativeToFile $CoopExe "$root/removed-update-error.txt" --root $root bucket update readd --json | Out-Null
if ($LASTEXITCODE -eq 0) { throw 'updating a removed bucket silently succeeded' }
if ((Get-Content -LiteralPath "$root/removed-update-error.txt" -Raw) -notmatch 'removed') { throw 'removed-bucket update did not explain the state' }
$readdAgainText = & $CoopExe --root $root bucket add readd $url --branch trunk --json
if ($LASTEXITCODE -ne 0) { throw ('re-registration of the existing shared bucket failed: '+($readdAgainText -join "`n")) }
$readdAgain = ($readdAgainText -join "`n") | ConvertFrom-Json
if ($readdAgain.path -ne $readd.path -or -not (Test-Path -LiteralPath (Join-Path $readdAgain.path '.git')) -or $readdAgain.adopted -ne $true) { throw 're-registration did not adopt the existing shared worktree' }
$readdSame = (& $CoopExe --root $root bucket update readd --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $readdSame.changed -ne $false -or $readdSame.adopted -ne $true -or $readdSame.revision -ne $readdAgain.revision) { throw 're-registered bucket is not stable or lost adoption provenance' }
Write-Output 'PASS removed bucket re-adopts its shared worktree; removed update fails honestly'

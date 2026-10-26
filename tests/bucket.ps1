param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
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
    $start.Environment['GIT_CONFIG_GLOBAL'] = $empty
    $start.Environment['GIT_CONFIG_SYSTEM'] = $empty
    $start.Environment['GIT_CONFIG_NOSYSTEM'] = '1'
    $start.Environment['XDG_CONFIG_HOME'] = $templates
    $start.ArgumentList.Add('-c')
    $start.ArgumentList.Add('core.hooksPath='+$templates)
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
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
$gitIndexPath = Join-Path $root '.coop/index/git.json'
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
$items = @((& $CoopExe --root $root search git/jq --json) | ConvertFrom-Json)
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
& $CoopExe --root $root bucket update git --json 2> "$root/unsupported-tree-error.txt" | Out-Null
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
$beforeCrash = (Get-FileHash -LiteralPath $registryPath).Hash
$journals = Join-Path $root '.coop/bucket-refresh'
$existingJournals = @(Get-ChildItem -LiteralPath $journals -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
$start = [Diagnostics.ProcessStartInfo]::new($CoopExe)
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
foreach ($argument in @('--root',$root,'bucket','update','git','--json')) { $start.ArgumentList.Add($argument) }
$updater = [Diagnostics.Process]::Start($start)
$updaterOutput = $updater.StandardOutput.ReadToEndAsync()
$updaterError = $updater.StandardError.ReadToEndAsync()
$deadline = [DateTime]::UtcNow.AddSeconds(30)
$interrupted = $false
while (-not $updater.HasExited -and [DateTime]::UtcNow -lt $deadline) {
    $newJournal = @(Get-ChildItem -LiteralPath $journals -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin $existingJournals })
    if ($newJournal.Count) { $updater.Kill($true); $interrupted = $true; break }
    Start-Sleep -Milliseconds 2
}
if (-not $updater.HasExited) { $updater.Kill($true) }
$updater.WaitForExit()
$updaterOutput.GetAwaiter().GetResult() | Out-Null
$updaterError.GetAwaiter().GetResult() | Out-Null
if (-not $interrupted) { throw 'Failed to observe an actual in-progress refresh interruption' }
if ((Get-FileHash -LiteralPath $registryPath).Hash -ne $beforeCrash) { throw 'Interruption changed published registry' }
$items = (& $CoopExe --root $root search ripgrep --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $items.Count -ne 1) { throw 'Interruption broke previous query' }
$deleted = (& $CoopExe --root $root bucket update git --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $deleted.changed) { throw 'Retry after interruption did not recover' }
if (-not (Test-Path -LiteralPath "$sharedGit/.git") -or (Invoke-FixtureGit @('-C',$sharedGit,'rev-parse','HEAD')) -ne $deleted.revision) { throw 'Retry after interruption did not leave a usable shared bucket' }
if (Test-Path -LiteralPath (Join-Path $journals 'git.json')) { throw 'Completed refresh left an in-progress journal' }
Write-Output ('PASS actual updater process interruption, exit='+$updater.ExitCode+'; journal observed; old record and query retained; retry completed')

$heldLock = [IO.File]::Open((Join-Path $root '.coop/write.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    & $CoopExe --root $root bucket update git --json 2> "$root/busy-error.txt" | Out-Null
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
    & $CoopExe --root $root bucket update git --json 2> "$root/commit-error.txt" | Out-Null
    if ($LASTEXITCODE -eq 0) { throw 'Commit sharing violation was ignored' }
    if ((Get-FileHash -LiteralPath $registryPath).Hash -ne $beforeCommitFailure) { throw 'Failed registry commit changed state' }
} finally { $heldRegistry.Dispose() }
$deleted = (& $CoopExe --root $root bucket update git --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $deleted.changed) { throw 'Retry after commit failure did not publish' }
Write-Output 'PASS concurrent writer exclusion, readable stable state, failed atomic commit and retry'

$modifiedManifest = Join-Path $deleted.path 'bucket/ripgrep.json'
[IO.File]::AppendAllText($modifiedManifest,' ')
& $CoopExe --root $root bucket update git --json 2> "$root/local-change-error.txt" | Out-Null
if ($LASTEXITCODE -eq 0) { throw 'current local modification was discarded' }
if (-not (Get-Content -LiteralPath $modifiedManifest -Raw).EndsWith(' ')) { throw 'local modification was not preserved' }
if ((Invoke-FixtureGit @('-C',$sharedGit,'rev-parse','HEAD')) -ne $deleted.revision) { throw 'local-change refusal moved the shared working tree revision' }
if (-not (Test-Path -LiteralPath "$sharedGit/bucket/ripgrep.json")) { throw 'local-change refusal removed usable shared bucket files' }
if (((& $CoopExe --root $root search ripgrep --json) | ConvertFrom-Json).Count -ne 1) { throw 'local-change refusal broke local query' }
Write-Output 'PASS Git library clone into shared bucket, non-default branch, in-place incremental refresh, local-change protection'

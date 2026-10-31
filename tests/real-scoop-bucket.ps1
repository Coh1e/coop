param(
    [Parameter(Mandatory)][string]$CoopExe,
    [string]$ScoopRoot = (Join-Path $env:USERPROFILE 'scoop'),
    [string]$Bucket = 'main',
    [Parameter(Mandatory)][string]$EvidenceDir)
# Bounded product operation against the human-selected real Scoop root: refresh one existing
# shared bucket with Coop's embedded Git library, then prove that the same working tree remains
# usable and that a second refresh is a no-change operation. No software is installed, updated,
# uninstalled or scripted here.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$ScoopRoot = [IO.Path]::GetFullPath($ScoopRoot)
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
$allowed = [IO.Path]::GetFullPath((Join-Path $projectRoot '.local')).TrimEnd('\') + '\'
if (-not ($EvidenceDir.TrimEnd('\') + '\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence must stay inside the project .local directory' }
if (-not (Test-Path -LiteralPath $ScoopRoot)) { throw "Real Scoop root not found: $ScoopRoot" }
$shared = Join-Path $ScoopRoot "buckets/$Bucket"
if (-not (Test-Path -LiteralPath (Join-Path $shared '.git'))) { throw "Shared bucket is not a Git working tree: $shared" }
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$guard = Join-Path (Split-Path $CoopExe) 'process_guard.exe'
function Invoke-Git([string[]]$Arguments) {
    $output = & git -C $shared @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("git -C $shared $($Arguments -join ' ') failed: "+($output -join "`n")) }
    return ($output -join "`n").Trim()
}
function Get-Hash([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}
# Scoop's --version also prints bucket update hints on this release; read the installed
# changelog instead so the evidence field contains the actual release.
function Get-ScoopVersion {
    $changelog = Join-Path $ScoopRoot 'apps/scoop/current/CHANGELOG.md'
    if (Test-Path -LiteralPath $changelog) { return (Get-Content -LiteralPath $changelog -TotalCount 1).Trim() }
    return 'unknown'
}
function Invoke-Guarded([string]$Label) {
    $start = [Diagnostics.ProcessStartInfo]::new($guard)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['COOP_PROCESS_GUARD_TIMEOUT_MS'] = '600000'
    foreach ($argument in @($CoopExe,'--root',$ScoopRoot,'bucket','update',$Bucket,'--json')) { Add-ProcessArgument $start ($argument) }
    $process = [Diagnostics.Process]::Start($start)
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(600000)) { $process.Kill(); throw "Guarded $Label refresh timed out" }
    $elapsedMs = [math]::Round($stopwatch.Elapsed.TotalMilliseconds,1)
    $text = $stdout.GetAwaiter().GetResult()
    $guardText = $stderr.GetAwaiter().GetResult()
    $text | Set-Content -LiteralPath (Join-Path $EvidenceDir "$Label-output.json") -Encoding utf8
    $guardText | Set-Content -LiteralPath (Join-Path $EvidenceDir "$Label-guard.txt") -Encoding utf8
    if ($process.ExitCode -ne 0) { throw ("Guarded $Label refresh failed with exit $($process.ExitCode): "+$text+' '+$guardText) }
    if ($guardText -notmatch 'Observed workload processes: 1') { throw "Coop $Label refresh started an unexpected helper process: $guardText" }
    $record = $text | ConvertFrom-Json
    Add-Member -InputObject $record -NotePropertyName elapsed_ms -NotePropertyValue $elapsedMs
    return $record
}
$branchBefore = Invoke-Git @('rev-parse','--abbrev-ref','HEAD')
$remoteBefore = Invoke-Git @('config','--get',("branch.$branchBefore.remote"))
$urlBefore = Invoke-Git @('config','--get',("remote.$remoteBefore.url"))
$revisionBefore = Invoke-Git @('rev-parse','HEAD')
$statusBefore = Invoke-Git @('status','--porcelain=v1')
$trackedBefore = @(& git -C $shared ls-files 2>$null)
if ($statusBefore) { throw 'The real shared bucket has local modifications; refusing to run a destructive refresh test against it' }
$sampleManifest = @(& git -C $shared ls-files 'bucket/*.json' 2>$null | Select-Object -First 1)
$sampleName = if ($sampleManifest.Count) { [IO.Path]::GetFileNameWithoutExtension($sampleManifest[0]) } else { $null }
$sampleBefore = if ($sampleManifest.Count) { Get-Hash (Join-Path $shared $sampleManifest[0]) } else { $null }
$listBeforePath = Join-Path $EvidenceDir 'bucket-list-before.json'
(& $CoopExe --root $ScoopRoot bucket list --json) | Set-Content -LiteralPath $listBeforePath -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'Reading the bucket registry before refresh failed' }

$first = Invoke-Guarded 'first-refresh'
$branchAfterFirst = Invoke-Git @('rev-parse','--abbrev-ref','HEAD')
$revisionAfterFirst = Invoke-Git @('rev-parse','HEAD')
$statusAfterFirst = Invoke-Git @('status','--porcelain=v1')
$urlAfterFirst = Invoke-Git @('config','--get',("remote.$remoteBefore.url"))
if ($first.path -ne $shared -or -not (Test-Path -LiteralPath (Join-Path $shared '.git'))) { throw 'Coop did not refresh the shared bucket working tree' }
if ($first.branch -ne $branchBefore -or $branchAfterFirst -ne $branchBefore) { throw 'Shared bucket branch was not preserved' }
if ($first.revision -ne $revisionAfterFirst) { throw 'Published revision does not match the shared working tree HEAD' }
if ($urlAfterFirst -ne $urlBefore -or $first.url -ne $urlBefore) { throw 'Shared bucket source URL changed' }
if ($statusAfterFirst) { throw "Refresh left local changes in the real shared bucket: $statusAfterFirst" }
if ($first.refresh_kind -notin @('first','changed','unchanged')) { throw 'First refresh did not report its kind' }
if ($first.changed -ne ($revisionAfterFirst -ne $revisionBefore)) { throw 'Changed flag does not match the actual shared revision' }
$indexPath = Join-Path $ScoopRoot ".coop/cache/index/$Bucket.json"
$indexAfterFirst = Get-Hash $indexPath
if (-not $indexAfterFirst) { throw 'Refresh did not create the search index' }
$sampleAfterFirst = if ($sampleManifest.Count) { Get-Hash (Join-Path $shared $sampleManifest[0]) } else { $null }
if (-not $sampleName) { throw 'The shared bucket has no manifest to query' }
$query = Invoke-CoopNative $CoopExe  --root $ScoopRoot info "$Bucket/$sampleName" --json
$query | Set-Content -LiteralPath (Join-Path $EvidenceDir 'info-after-refresh.json') -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw ('Local query after shared bucket refresh failed: '+($query -join "`n")) }

$second = Invoke-Guarded 'second-refresh'
$branchAfterSecond = Invoke-Git @('rev-parse','--abbrev-ref','HEAD')
$revisionAfterSecond = Invoke-Git @('rev-parse','HEAD')
$statusAfterSecond = Invoke-Git @('status','--porcelain=v1')
$indexAfterSecond = Get-Hash $indexPath
if ($second.changed -ne $false -or $second.refresh_kind -ne 'unchanged') { throw 'Second refresh was not a no-change operation' }
if ($second.revision -ne $revisionAfterFirst -or $revisionAfterSecond -ne $revisionAfterFirst) { throw 'No-change refresh moved the shared revision' }
if ($second.path -ne $shared -or $branchAfterSecond -ne $branchBefore) { throw 'No-change refresh changed the shared path or branch' }
if ($indexAfterSecond -ne $indexAfterFirst) { throw 'No-change refresh rebuilt the search index' }
if ($statusAfterSecond) { throw "No-change refresh left local changes in the real shared bucket: $statusAfterSecond" }

$evidence = [ordered]@{
    generated_at = [DateTime]::UtcNow.ToString('o')
    scope = 'one existing shared bucket, no software install/update/uninstall/script'
    scoop_root = $ScoopRoot
    bucket = $Bucket
    shared_path = $shared
    coop = (& $CoopExe --version)
    scoop_version = (Get-ScoopVersion)
    git_used_for_verification = (@(git --version) -join ' ')
    branch = $branchBefore
    remote = $remoteBefore
    source_url = $urlBefore
    revision_before = $revisionBefore
    revision_after_first = $revisionAfterFirst
    revision_after_second = $revisionAfterSecond
    local_modifications_before = $statusBefore
    local_modifications_after_first = $statusAfterFirst
    local_modifications_after_second = $statusAfterSecond
    tracked_files_before = $trackedBefore.Count
    sample_manifest = if ($sampleManifest.Count) { $sampleManifest[0] } else { $null }
    sample_manifest_sha256_before = $sampleBefore
    sample_manifest_sha256_after_first = $sampleAfterFirst
    first_refresh = $first
    no_change_refresh = $second
    search_index_sha256_after_first = $indexAfterFirst
    search_index_sha256_after_second = $indexAfterSecond
    no_git_helper_process = $true
    coop_state_directory = (Join-Path $ScoopRoot '.coop')
    registry_before = (Get-Content -LiteralPath $listBeforePath -Raw | ConvertFrom-Json)
}
$evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceDir 'real-scoop-bucket-evidence.json') -Encoding utf8
Write-Output ("PASS real shared bucket {0}: {1} -> {2} ({3}); no-change refresh {4}; branch {5}; no local modifications; no helper process" -f `
    $Bucket,$revisionBefore,$revisionAfterFirst,$first.refresh_kind,$second.refresh_kind,$branchBefore)

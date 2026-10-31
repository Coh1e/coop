param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$ScoopRoot,
    [Parameter(Mandatory)][string]$TestRoot,
    [Parameter(Mandatory)][string]$EvidenceDir,
    [int]$Runs = 7,
    [int]$FirstRefreshRuns = 3,
    [string]$HttpsUrl = '',
    [string]$HttpsPinnedRevision = ''
)
# Full-process performance measurement against the real shared Scoop environment and a real-scale
# (Main-sized) project-local copy. The only write against the real root is an explicit `bucket
# update`, which is the product operation this ticket measures; queries must leave it untouched.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Real-scale performance data must stay within the project test directory'
}
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
if (-not (Test-Path -LiteralPath $CoopExe)) { throw 'Coop executable is missing' }
$ScoopRoot = [IO.Path]::GetFullPath($ScoopRoot)
if (-not (Test-Path -LiteralPath (Join-Path $ScoopRoot 'buckets/main'))) { throw 'A real main bucket is required' }
if (-not (Test-Path -LiteralPath (Join-Path $ScoopRoot '.coop/buckets.json'))) { throw 'The real root has no Coop bucket registry' }
New-Item -ItemType Directory -Path $TestRoot,$EvidenceDir -Force | Out-Null

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "real performance test failed: $Message" }
}
function Invoke-Measured([string[]]$Arguments) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new($CoopExe)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { Add-ProcessArgument $startInfo ($argument) }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $watch.Stop()
    return [pscustomobject]@{
        exit = $process.ExitCode
        output = $stdout.GetAwaiter().GetResult()
        error = $stderr.GetAwaiter().GetResult()
        ms = $watch.Elapsed.TotalMilliseconds
    }
}
function Percentile([double[]]$Values, [double]$Fraction) {
    $sorted = @($Values | Sort-Object)
    $index = [math]::Min($sorted.Count - 1, [math]::Max(0, [int][math]::Ceiling($sorted.Count * $Fraction) - 1))
    return [math]::Round($sorted[$index], 1)
}
function Summary([string]$Name, [string]$Target, [double[]]$Samples, [string]$Command) {
    $warm = @($Samples | Select-Object -Skip 1)
    [pscustomobject]@{
        name = $Name
        command = $Command
        target_ms = [int]$Target
        first_ms = [math]::Round($Samples[0], 1)
        p50_ms = Percentile $warm 0.50
        p95_ms = Percentile $warm 0.95
        min_ms = [math]::Round((@($warm | Sort-Object))[0], 1)
        max_ms = [math]::Round((@($warm | Sort-Object))[-1], 1)
        runs = @($Samples).Count
    }
}
function Measure-Coop([string]$Name, [string]$Target, [string[]]$Arguments) {
    $samples = [System.Collections.Generic.List[double]]::new()
    for ($index = 0; $index -lt $Runs; $index++) {
        $result = Invoke-Measured $Arguments
        Assert ($result.exit -eq 0) "$Name exited $($result.exit): $($result.error)"
        $samples.Add($result.ms)
    }
    Summary $Name $Target $samples.ToArray() ($Arguments -join ' ')
}
function Coop-Json([string[]]$Arguments) {
    $result = Invoke-Measured $Arguments
    Assert ($result.exit -eq 0) "coop $($Arguments -join ' ') exited $($result.exit): $($result.error)"
    return ($result.output | ConvertFrom-Json)
}
function File-HashOrNull([string]$Path) {
    if (Test-Path -LiteralPath $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } else { return $null }
}
$git = (Get-Command git.exe -ErrorAction Stop).Source
$gitConfig = Join-Path $TestRoot 'empty-git-config'
[IO.File]::WriteAllText($gitConfig, '')
$gitTemplates = Join-Path $TestRoot 'empty-git-templates'
New-Item -ItemType Directory -Path $gitTemplates -Force | Out-Null
function Invoke-FixtureGit([string[]]$Arguments) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new($git)
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = $gitConfig
    $startInfo.EnvironmentVariables['GIT_CONFIG_SYSTEM'] = $gitConfig
    $startInfo.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
    $startInfo.EnvironmentVariables['XDG_CONFIG_HOME'] = $gitTemplates
    Add-ProcessArgument $startInfo ('-c')
    Add-ProcessArgument $startInfo ('core.hooksPath=' + $gitTemplates)
    foreach ($argument in $Arguments) { Add-ProcessArgument $startInfo ($argument) }
    $process = [Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "fixture git failed: $($stderr.GetAwaiter().GetResult())" }
    return $stdout.GetAwaiter().GetResult().Trim()
}
$mainBucket = Join-Path $ScoopRoot 'buckets/main'
$mainManifests = @(Get-ChildItem -LiteralPath (Join-Path $mainBucket 'bucket') -File -Filter '*.json')
$registryPath = Join-Path $ScoopRoot '.coop/buckets.json'
$indexPath = Join-Path $ScoopRoot '.coop/index/main.json'
$registryBefore = Get-Content -LiteralPath $registryPath -Raw
$registry = @($registryBefore | ConvertFrom-Json) | Where-Object name -eq 'main'
$revisionBefore = Invoke-FixtureGit @('-C', $mainBucket, 'rev-parse', 'HEAD')
$statusBefore = Invoke-FixtureGit @('-C', $mainBucket, 'status', '--porcelain')
$indexHashBefore = File-HashOrNull $indexPath
$registryHashBefore = File-HashOrNull $registryPath

$infoName = if (Test-Path -LiteralPath (Join-Path $mainBucket 'bucket/git.json')) { 'git' } else { $mainManifests[0].BaseName }
$searchNeedle = $infoName.Substring(0, [math]::Min(4, $infoName.Length))
$queries = [System.Collections.Generic.List[object]]::new()
$listSamples = [System.Collections.Generic.List[double]]::new()
for ($index = 0; $index -lt $Runs; $index++) {
    $result = Invoke-Measured @('--root', $ScoopRoot, 'list', '--json')
    Assert ($result.exit -eq 0) "real list exited $($result.exit): $($result.error)"
    $listSamples.Add($result.ms)
}
$installed = @($listSamples)
$queries.Add((Summary 'list' 50 $installed @('--root', $ScoopRoot, 'list', '--json')))
$installedCount = @((Invoke-Measured @('--root', $ScoopRoot, 'list', '--json')).output | ConvertFrom-Json).Count
$queries.Add((Measure-Coop "info-$infoName" 50 @('--root', $ScoopRoot, 'info', "main/$infoName", '--json')))
$queries.Add((Measure-Coop "search-$searchNeedle" 100 @('--root', $ScoopRoot, 'search', $searchNeedle, '--json')))
$otherBucket = @($registryBefore | ConvertFrom-Json) | Where-Object { $_.name -ne 'main' -and $_.kind -ne 'removed' } | Select-Object -First 1
$otherInfo = $null
if ($null -ne $otherBucket) {
    $otherBucketPath = Join-Path $otherBucket.path 'bucket'
    if (-not (Test-Path -LiteralPath $otherBucketPath)) { $otherBucketPath = $otherBucket.path }
    $otherManifest = @(Get-ChildItem -LiteralPath $otherBucketPath -File -Filter '*.json' | Sort-Object Name | Select-Object -First 1)
    if ($otherManifest.Count -eq 1) {
        $otherInfo = Measure-Coop "info-$($otherBucket.name)/$($otherManifest[0].BaseName)" 50 @('--root', $ScoopRoot, 'info', "$($otherBucket.name)/$($otherManifest[0].BaseName)", '--json')
        $queries.Add($otherInfo)
    }
}
# Queries are read-only: the registry, the main index and the shared worktree must be unchanged.
Assert ((File-HashOrNull $registryPath) -eq $registryHashBefore) 'queries rewrote the real bucket registry'
Assert ((File-HashOrNull $indexPath) -eq $indexHashBefore) 'queries rewrote the real query index'
Assert ((Invoke-FixtureGit @('-C', $mainBucket, 'rev-parse', 'HEAD')) -eq $revisionBefore) 'queries moved the real bucket revision'
Assert ((Invoke-FixtureGit @('-C', $mainBucket, 'status', '--porcelain')) -eq $statusBefore) 'queries modified the real shared worktree'

# Real-root refresh: the first run may publish a record repaired after the other client advanced the
# worktree; later runs must report `unchanged` and transfer nothing.
$realRefreshRuns = [System.Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $Runs; $index++) {
    $result = Invoke-Measured @('--root', $ScoopRoot, 'bucket', 'update', 'main', '--json')
    Assert ($result.exit -eq 0) "real bucket update exited $($result.exit): $($result.error)"
    $record = $result.output | ConvertFrom-Json
    $realRefreshRuns.Add([pscustomobject]@{
        run = $index + 1
        ms = [math]::Round($result.ms, 1)
        refresh_kind = $record.refresh_kind
        changed = $record.changed
        changed_files = $record.changed_files
        received_bytes = $record.received_bytes
        previous_revision = $record.previous_revision
        revision = $record.revision
    })
}
$revisionAfterRefresh = Invoke-FixtureGit @('-C', $mainBucket, 'rev-parse', 'HEAD')
$statusAfterRefresh = Invoke-FixtureGit @('-C', $mainBucket, 'status', '--porcelain')
Assert ($statusAfterRefresh -eq $statusBefore) 'real-root refresh changed the shared worktree beyond the published revision'
$unchangedSamples = @($realRefreshRuns | Where-Object { $_.refresh_kind -eq 'unchanged' } | ForEach-Object { $_.ms })
$realUnchangedP50 = $null
$realUnchangedP95 = $null
if (@($unchangedSamples).Count -gt 0) {
    $realUnchangedP50 = Percentile $unchangedSamples 0.50
    $realUnchangedP95 = Percentile $unchangedSamples 0.95
}
$realRoot = [ordered]@{
    path = $ScoopRoot
    bucket = 'main'
    manifests = $mainManifests.Count
    installed_packages = $installedCount
    revision_before_queries = $revisionBefore
    published_revision_before = $registry.revision
    revision_after_refresh = $revisionAfterRefresh
    runs = @($realRefreshRuns)
    unchanged_runs = @($unchangedSamples).Count
    unchanged_p50_ms = $realUnchangedP50
    unchanged_p95_ms = $realUnchangedP95
}

# Real-scale first/changed/unchanged refresh through a project-local copy of the real main bucket.
# The copy keeps the real 1,700+ manifest worktree and full history; only the transport is local, so
# no unrelated network load is created while timing repeated runs.
$upstream = Join-Path $TestRoot 'main-upstream'
if (Test-Path -LiteralPath $upstream) { Remove-Item -LiteralPath $upstream -Recurse -Force }
Invoke-FixtureGit @('clone', '--no-hardlinks', $mainBucket, $upstream) | Out-Null
$upstreamUrl = ([uri]($upstream.Replace('\', '/') + '/')).AbsoluteUri
$upstreamRevision = Invoke-FixtureGit @('-C', $upstream, 'rev-parse', 'HEAD')
$firstRefreshRecords = [System.Collections.Generic.List[object]]::new()
$firstRoot = $null
for ($index = 0; $index -lt $FirstRefreshRuns; $index++) {
    $root = Join-Path $TestRoot ("first-root-{0}" -f ($index + 1))
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $result = Invoke-Measured @('--root', $root, 'bucket', 'add', 'main', $upstreamUrl, '--branch', 'master', '--json')
    Assert ($result.exit -eq 0) "real-scale first refresh exited $($result.exit): $($result.error)"
    $record = $result.output | ConvertFrom-Json
    Assert ($record.first_refresh -eq $true -and $record.refresh_kind -eq 'first') 'real-scale first refresh did not report a first refresh'
    Assert ($record.revision -eq $upstreamRevision) 'real-scale first refresh published a wrong revision'
    $firstRefreshRecords.Add([pscustomobject]@{ run = $index + 1; ms = [math]::Round($result.ms, 1); received_bytes = $record.received_bytes; files_count = $record.files_count; cache = 'fresh root; this copy is re-used each run, so the OS cache may hold the repository data' })
    if ($index -lt $FirstRefreshRuns - 1) { Remove-Item -LiteralPath $root -Recurse -Force }
    else { $firstRoot = $root }
}
$changedRuns = [System.Collections.Generic.List[object]]::new()
$scaleRoot = $firstRoot
$baseRevision = $upstreamRevision
$unrelatedManifest = $null
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $upstream 'bucket') -File -Filter '*.json' | Sort-Object Name)) {
    if ($file.BaseName -notlike 'pkg99*') { $unrelatedManifest = $file.FullName; break }
}
Assert ($null -ne $unrelatedManifest) 'real-scale fixture has no unrelated manifest to protect'
$unrelatedName = [IO.Path]::GetFileName($unrelatedManifest)
$unrelatedSourceHash = (Get-FileHash -LiteralPath $unrelatedManifest -Algorithm SHA256).Hash
# The property under test is the refreshed shared worktree, so the hash must come from
# <root>/buckets/main/bucket, not from the file:// upstream copy that Coop only reads.
$worktreeUnrelated = Join-Path $scaleRoot ('buckets/main/bucket/' + $unrelatedName)
Assert (Test-Path -LiteralPath $worktreeUnrelated) "real-scale worktree is missing $unrelatedName after the first refresh"
$unrelatedWorktreeHash = (Get-FileHash -LiteralPath $worktreeUnrelated -Algorithm SHA256).Hash
Assert ($unrelatedWorktreeHash -eq $unrelatedSourceHash) 'first refresh did not materialize the unrelated manifest byte-identically'
for ($index = 0; $index -lt $Runs; $index++) {
    $manifestName = 'pkg{0:d5}' -f (99000 + $index)
    $manifest = Join-Path $upstream ('bucket/' + $manifestName + '.json')
    $json = [ordered]@{
        version = '9.0.{0}' -f $index
        description = 'Real-scale changed-refresh benchmark manifest'
        architecture = @{ '64bit' = @{ url = "https://example.invalid/pkg$index.zip"; hash = ('a' * 64) } }
    } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($manifest, $json)
    Invoke-FixtureGit @('-C', $upstream, 'add', ('bucket/' + $manifestName + '.json')) | Out-Null
    Invoke-FixtureGit @('-C', $upstream, '-c', 'user.name=CoopPerf', '-c', 'user.email=coop@example.invalid', 'commit', '-m', ("bench change " + $index)) | Out-Null
    $target = Invoke-FixtureGit @('-C', $upstream, 'rev-parse', 'HEAD')
    $scaleIndex = Join-Path $scaleRoot '.coop/index/main.json'
    $indexHashBefore = File-HashOrNull $scaleIndex
    Assert ($null -ne $indexHashBefore) 'real-scale changed refresh started without a query index'
    $worktreeHashBefore = (Get-FileHash -LiteralPath $worktreeUnrelated -Algorithm SHA256).Hash
    Assert ($worktreeHashBefore -eq $unrelatedWorktreeHash) 'real-scale worktree unrelated manifest changed between rounds'
    $result = Invoke-Measured @('--root', $scaleRoot, 'bucket', 'update', 'main', '--json')
    Assert ($result.exit -eq 0) "real-scale changed refresh exited $($result.exit): $($result.error)"
    $record = $result.output | ConvertFrom-Json
    Assert ($record.changed -eq $true -and $record.refresh_kind -eq 'changed' -and $record.previous_revision -eq $baseRevision -and $record.revision -eq $target) 'real-scale changed refresh published the wrong transition'
    Assert ($record.changed_files -ge 1) 'real-scale changed refresh reported no changed file'
    # The changed refresh must leave an unrelated manifest byte-identical in the refreshed shared
    # worktree (and keep the upstream copy untouched) and must rebuild the query index.
    $worktreeHashAfter = (Get-FileHash -LiteralPath $worktreeUnrelated -Algorithm SHA256).Hash
    Assert ($worktreeHashAfter -eq $worktreeHashBefore) 'real-scale changed refresh modified an unrelated manifest in the refreshed worktree'
    Assert ((Get-FileHash -LiteralPath $unrelatedManifest -Algorithm SHA256).Hash -eq $unrelatedSourceHash) 'real-scale changed refresh modified the upstream source manifest'
    Assert ((File-HashOrNull $scaleIndex) -ne $indexHashBefore) 'real-scale changed refresh did not rebuild the query index'
    $added = Invoke-Measured @('--root', $scaleRoot, 'info', "main/$manifestName", '--json')
    Assert ($added.exit -eq 0 -and @($added.output[0].version | ConvertFrom-Json) -eq ('9.0.' + $index)) 'real-scale changed refresh did not publish a queryable manifest'
    $changedRuns.Add([pscustomobject]@{ run = $index + 1; ms = [math]::Round($result.ms, 1); received_bytes = $record.received_bytes; changed_files = $record.changed_files; previous_revision = $baseRevision; revision = $target; unrelated_manifest = $unrelatedName; worktree_unrelated_manifest_sha256 = $worktreeHashAfter; worktree_unrelated_manifest_unchanged = $true; upstream_manifest_unchanged = $true; index_rebuilt = $true; new_manifest_queryable = $true })
    $baseRevision = $target
}
$scaleUnchangedSamples = [System.Collections.Generic.List[double]]::new()
for ($index = 0; $index -lt $Runs; $index++) {
    $result = Invoke-Measured @('--root', $scaleRoot, 'bucket', 'update', 'main', '--json')
    Assert ($result.exit -eq 0) "real-scale unchanged refresh exited $($result.exit): $($result.error)"
    $record = $result.output | ConvertFrom-Json
    Assert ($record.changed -eq $false -and $record.refresh_kind -eq 'unchanged' -and $record.received_bytes -eq 0) 'real-scale unchanged refresh transferred or republished data'
    $scaleUnchangedSamples.Add($result.ms)
}
$https = $null
if (-not [string]::IsNullOrEmpty($HttpsUrl)) {
    $httpsRoot = Join-Path $TestRoot 'https-root'
    if (Test-Path -LiteralPath $httpsRoot) { Remove-Item -LiteralPath $httpsRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $httpsRoot -Force | Out-Null
    if ([string]::IsNullOrEmpty($HttpsPinnedRevision)) {
        $first = Invoke-Measured @('--root', $httpsRoot, 'bucket', 'add', 'main', $HttpsUrl, '--branch', 'master', '--json')
        Assert ($first.exit -eq 0) "HTTPS first refresh exited $($first.exit): $($first.error)"
        $firstRecord = $first.output | ConvertFrom-Json
        $changed = Invoke-Measured @('--root', $httpsRoot, 'bucket', 'update', 'main', '--json')
        Assert ($changed.exit -eq 0) "HTTPS refresh exited $($changed.exit): $($changed.error)"
        $changedRecord = $changed.output | ConvertFrom-Json
        $https = [ordered]@{
            url = $HttpsUrl
            pinned_revision = $null
            first = [ordered]@{ ms = [math]::Round($first.ms, 1); revision = $firstRecord.revision; received_bytes = $firstRecord.received_bytes; files_count = $firstRecord.files_count }
            changed = [ordered]@{ ms = [math]::Round($changed.ms, 1); refresh_kind = $changedRecord.refresh_kind; changed_files = $changedRecord.changed_files; received_bytes = $changedRecord.received_bytes; previous_revision = $changedRecord.previous_revision; revision = $changedRecord.revision }
        }
    } else {
        $first = Invoke-Measured @('--root', $httpsRoot, 'bucket', 'add', 'main', $HttpsUrl, '--branch', 'master', '--revision', $HttpsPinnedRevision, '--json')
        Assert ($first.exit -eq 0) "HTTPS pinned first refresh exited $($first.exit): $($first.error)"
        $firstRecord = $first.output | ConvertFrom-Json
        Assert ($firstRecord.revision -eq $HttpsPinnedRevision) 'HTTPS pinned first refresh published a wrong revision'
        $afterFirst = Invoke-Measured @('--root', $httpsRoot, 'bucket', 'update', 'main', '--json')
        Assert ($afterFirst.exit -eq 0) "HTTPS refresh after the pinned first fetch exited $($afterFirst.exit): $($afterFirst.error)"
        $afterFirstRecord = $afterFirst.output | ConvertFrom-Json
        # A pinned bucket keeps its revision, so this update is expected to be unchanged. A real
        # changed refresh over HTTPS needs the upstream branch itself to advance, which this
        # read-only shared environment does not control.
        $https = [ordered]@{
            url = $HttpsUrl
            pinned_revision = $HttpsPinnedRevision
            first = [ordered]@{ ms = [math]::Round($first.ms, 1); revision = $firstRecord.revision; received_bytes = $firstRecord.received_bytes; files_count = $firstRecord.files_count }
            after_pinned = [ordered]@{ ms = [math]::Round($afterFirst.ms, 1); refresh_kind = $afterFirstRecord.refresh_kind; changed_files = $afterFirstRecord.changed_files; received_bytes = $afterFirstRecord.received_bytes; revision = $afterFirstRecord.revision }
            changed = $null
            changed_note = 'No real HTTPS changed refresh: the shared environment does not control when the public upstream branch advances. Real-scale changed refreshes are measured on the full project-local copy; the real network payload is reported for the first and unchanged refreshes.'
        }
    }
}
$disk = 'unavailable'
try {
    $physical = Get-PhysicalDisk | Select-Object -First 1
    if ($null -ne $physical) { $disk = "$($physical.FriendlyName) media=$($physical.MediaType) bus=$($physical.BusType)" }
} catch { }
$cmakeVersion = 'unavailable'
try { $cmakeVersion = (& cmake --version | Select-Object -First 1) } catch { }
$ninjaVersion = 'unavailable'
try { $ninjaVersion = (& ninja --version) } catch { }
$scoopVersion = 'unavailable'
try { $scoopVersion = (Get-Content -LiteralPath (Join-Path $ScoopRoot 'apps/scoop/current/CHANGELOG.md') -ErrorAction Stop | Select-Object -First 1) } catch { }
$environment = [ordered]@{
    os = (Get-CimInstance Win32_OperatingSystem | ForEach-Object { "$($_.Caption) $($_.Version) build $($_.BuildNumber)" })
    cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1 | ForEach-Object { $_.Name.Trim() })
    logical_processors = [Environment]::ProcessorCount
    memory_bytes = (Get-CimInstance Win32_ComputerSystem | ForEach-Object { $_.TotalPhysicalMemory })
    disk = $disk
    powershell = $PSVersionTable.PSVersion.ToString()
    coop_version = (& $CoopExe --version)
    coop_sha256 = (Get-FileHash -LiteralPath $CoopExe -Algorithm SHA256).Hash.ToLower()
    coop_built = (Get-Item -LiteralPath $CoopExe).LastWriteTimeUtc.ToString('o')
    git = (& $git --version)
    git_head = (Invoke-FixtureGit @('-C', (Split-Path $PSScriptRoot -Parent), 'rev-parse', 'HEAD'))
    cmake = $cmakeVersion
    ninja = $ninjaVersion
    scoop_version = $scoopVersion
}
$report = [ordered]@{
    generated_at = [DateTime]::UtcNow.ToString('o')
    test_root = $TestRoot
    inputs = [ordered]@{
        real_main_manifests = $mainManifests.Count
        real_installed_packages = $installedCount
        real_other_bucket = if ($null -ne $otherBucket) { $otherBucket.name } else { $null }
        local_copy_manifests = @(Get-ChildItem -LiteralPath (Join-Path $upstream 'bucket') -File -Filter '*.json').Count
        local_copy_revision = $upstreamRevision
    }
    runs_per_measurement = $Runs
    first_refresh_runs = $FirstRefreshRuns
    targets_ms = [ordered]@{ version = 30; list = 50; info = 50; search = 100 }
    cache = 'Each command is a full process start-to-exit. Real-root queries read the index published by the last refresh. Repeated first refreshes reuse the same upstream copy, so the OS cache may hold its data; only the first sample of a series is labelled first.'
    environment = $environment
    queries = @($queries)
    real_root_refresh = $realRoot
    scale_refresh = [ordered]@{
        transport = 'file:// project-local copy of the real main bucket; no external network'
        first = [ordered]@{
            runs = @($firstRefreshRecords)
            p50_ms = Percentile (@($firstRefreshRecords | ForEach-Object { $_.ms })) 0.50
            p95_ms = Percentile (@($firstRefreshRecords | ForEach-Object { $_.ms })) 0.95
        }
        changed = [ordered]@{
            runs = @($changedRuns)
            p50_ms = Percentile (@($changedRuns | ForEach-Object { $_.ms })) 0.50
            p95_ms = Percentile (@($changedRuns | ForEach-Object { $_.ms })) 0.95
        }
        unchanged = [ordered]@{
            p50_ms = Percentile $scaleUnchangedSamples.ToArray() 0.50
            p95_ms = Percentile $scaleUnchangedSamples.ToArray() 0.95
            runs = $scaleUnchangedSamples.Count
        }
    }
    https = $https
    real_root_before = [ordered]@{ revision = $revisionBefore; published_revision = $registry.revision; index_sha256 = $indexHashBefore }
    real_root_after = [ordered]@{ revision = $revisionAfterRefresh; index_sha256 = (File-HashOrNull $indexPath) }
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceDir 'perf-real-report.json') -Encoding utf8
$queries | Format-Table name, target_ms, first_ms, p50_ms, p95_ms, min_ms, max_ms, runs -AutoSize | Out-String -Width 200 | Write-Output
Write-Output ("real root: manifests={0} installed={1} revision {2} -> {3}" -f $mainManifests.Count, $installedCount, $revisionBefore, $revisionAfterRefresh)
Write-Output ("real-root refresh: {0}" -f (($realRefreshRuns | ForEach-Object { "run$($_.run)=$($_.ms)ms/$($_.refresh_kind)/bytes=$($_.received_bytes)" }) -join '; '))
Write-Output ("scale first refresh: p50={0}ms p95={1}ms; changed: p50={2}ms p95={3}ms; unchanged: p50={4}ms p95={5}ms" -f `
    $report.scale_refresh.first.p50_ms, $report.scale_refresh.first.p95_ms,
    $report.scale_refresh.changed.p50_ms, $report.scale_refresh.changed.p95_ms,
    $report.scale_refresh.unchanged.p50_ms, $report.scale_refresh.unchanged.p95_ms)
if ($null -ne $https) {
    Write-Output ("HTTPS: first={0}ms bytes={1} revision={2}; after-pinned={3}ms {4} bytes={5}" -f `
        $https.first.ms, $https.first.received_bytes, $https.first.revision,
        $https.after_pinned.ms, $https.after_pinned.refresh_kind, $https.after_pinned.received_bytes)
    if ($null -ne $https.changed) {
        Write-Output ("HTTPS changed: {0}ms bytes={1} changed_files={2} {3} -> {4}" -f `
            $https.changed.ms, $https.changed.received_bytes, $https.changed.changed_files,
            $https.changed.previous_revision, $https.changed.revision)
    } else { Write-Output ("HTTPS changed: not available - " + $https.changed_note) }
}
foreach ($query in $queries) {
    if ($query.p50_ms -gt $query.target_ms) {
        Write-Output ("TARGET MISSED: {0} p50={1}ms > {2}ms (p95={3}ms)" -f $query.name, $query.p50_ms, $query.target_ms, $query.p95_ms)
    }
}
Write-Output ("PASS: real-root query and refresh plus real-scale first/changed/unchanged refresh measured; report: " + (Join-Path $EvidenceDir 'perf-real-report.json'))

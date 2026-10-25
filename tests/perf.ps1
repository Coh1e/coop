param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$TestRoot,
    [int]$Runs = 7
)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Performance test data must stay within the project test directory'
}
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
if (-not (Test-Path -LiteralPath $CoopExe)) { throw 'Coop executable is missing' }
Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "performance test failed: $Message" }
}
# Full process start-to-exit measurement: no resident helper process and no in-process timing.
function Invoke-Measured([string[]]$Arguments) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new($CoopExe)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
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
function Measure-Coop([string]$Name, [string]$Target, [string[]]$Arguments) {
    $samples = [System.Collections.Generic.List[double]]::new()
    $first = $null
    $last = $null
    for ($index = 0; $index -lt $Runs; $index++) {
        $result = Invoke-Measured $Arguments
        Assert ($result.exit -eq 0) "$Name exited $($result.exit): $($result.error)"
        if ($null -eq $first) { $first = $result }
        $last = $result
        $samples.Add($result.ms)
    }
    $warm = @($samples | Select-Object -Skip 1 | Sort-Object)
    $targetMs = [int]$Target
    [pscustomobject]@{
        name = $Name
        command = ($Arguments -join ' ')
        target_ms = $targetMs
        first_ms = [math]::Round($first.ms, 1)
        p50_ms = [math]::Round($warm[[int][math]::Floor($warm.Count / 2)], 1)
        p90_ms = [math]::Round($warm[[math]::Min($warm.Count - 1, [int][math]::Floor($warm.Count * 0.9))], 1)
        min_ms = [math]::Round($warm[0], 1)
        max_ms = [math]::Round($warm[-1], 1)
        target_met = $warm[[int][math]::Floor($warm.Count / 2)] -le $targetMs
        output_bytes = $last.output.Length
    }
}
function New-ManifestFile([string]$Path, [string]$Name, [string]$Version) {
    $manifest = [ordered]@{
        version = $Version
        description = "Package $Name benchmark fixture with a representative description used for local search matching."
        homepage = "https://example.invalid/$Name"
        license = 'MIT'
        architecture = @{ '64bit' = @{ url = "https://example.invalid/$Name-$Version.zip"; hash = ('a' * 64) } }
        bin = @("$Name.exe")
    }
    [IO.File]::WriteAllText($Path, ($manifest | ConvertTo-Json -Depth 6))
}
function New-BucketSource([string]$Directory, [int]$Count) {
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    for ($number = 1; $number -le $Count; $number++) {
        $name = 'pkg{0:d5}' -f $number
        New-ManifestFile (Join-Path $Directory ($name + '.json')) $name ('1.' + ($number % 20) + '.0')
    }
}
function New-InstallRoot([string]$Root, [int]$Count) {
    for ($number = 1; $number -le $Count; $number++) {
        $name = 'install{0:d3}' -f $number
        $app = Join-Path $Root "apps/$name"
        $current = Join-Path $app '2.0.0'
        New-Item -ItemType Directory -Path $current -Force | Out-Null
        New-ManifestFile (Join-Path $current 'scoop-manifest.json') $name '2.0.0'
        [IO.File]::WriteAllText((Join-Path $current 'scoop-install.json'), '{"bucket":"main","architecture":"64bit"}')
        for ($file = 0; $file -lt 3; $file++) {
            [IO.File]::WriteAllText((Join-Path $current ('payload' + $file + '.txt')), ('fixture payload ' + $file))
        }
        if ($number % 4 -eq 0) {
            foreach ($oldVersion in '1.0.0', '0.9.0') {
                $old = Join-Path $app $oldVersion
                New-Item -ItemType Directory -Path $old -Force | Out-Null
                New-ManifestFile (Join-Path $old 'scoop-manifest.json') $name $oldVersion
                [IO.File]::WriteAllText((Join-Path $old 'scoop-install.json'), '{"bucket":"main","architecture":"64bit"}')
                for ($file = 0; $file -lt 3; $file++) {
                    [IO.File]::WriteAllText((Join-Path $old ('payload' + $file + '.txt')), ('old payload ' + $file))
                }
            }
        }
        New-Item -ItemType Junction -Path (Join-Path $app 'current') -Target $current | Out-Null
    }
}

# Bucket scale fixtures: 200 / 1,500 / 3,000 manifests approximate a curated bucket, Main and
# Main+Extras sized inputs. The same files are read through an unmanaged directory (scan) and
# a registered local bucket (index hit), so both paths see identical data.
$sizes = 200, 1500, 3000
$sources = @{}
foreach ($size in $sizes) {
    $source = Join-Path $TestRoot "source-$size"
    New-BucketSource (Join-Path $source 'bucket') $size
    $sources[$size] = $source
}
New-ManifestFile (Join-Path $sources[200] 'bucket/broken.json') 'broken' '1.0.0'
[IO.File]::WriteAllText((Join-Path $sources[200] 'bucket/broken.json'), 'not json')

$scanRoots = @{}
$indexRoots = @{}
foreach ($size in $sizes) {
    $scanRoot = Join-Path $TestRoot "scan-$size"
    New-Item -ItemType Directory -Path "$scanRoot/buckets" -Force | Out-Null
    New-Item -ItemType Junction -Path "$scanRoot/buckets/main" -Target $sources[$size] | Out-Null
    $scanRoots[$size] = $scanRoot
    $indexRoot = Join-Path $TestRoot "index-$size"
    New-Item -ItemType Directory -Path $indexRoot -Force | Out-Null
    $registered = Invoke-Measured @('--root', $indexRoot, 'bucket', 'add', 'main', $sources[$size], '--json')
    Assert ($registered.exit -eq 0) "local bucket add failed for $size manifests: $($registered.error)"
    $indexRoots[$size] = $indexRoot
}
New-InstallRoot (Join-Path $TestRoot 'installed-25') 25
New-InstallRoot (Join-Path $TestRoot 'installed-100') 100

# A process-start floor separates Coop's own work from Windows process creation cost.
$floorSamples = [System.Collections.Generic.List[double]]::new()
for ($index = 0; $index -lt $Runs; $index++) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/cmd.exe'))
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.ArgumentList.Add('/d')
    $startInfo.ArgumentList.Add('/c')
    $startInfo.ArgumentList.Add('exit 0')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($startInfo)
    $process.WaitForExit()
    $watch.Stop()
    Assert ($process.ExitCode -eq 0) 'process start floor probe failed'
    $floorSamples.Add($watch.Elapsed.TotalMilliseconds)
}
$floor = @($floorSamples | Sort-Object)

$measurements = [System.Collections.Generic.List[object]]::new()
$measurements.Add((Measure-Coop 'version' 30 @('--version')))
foreach ($size in $sizes) {
    $measurements.Add((Measure-Coop "info-scan-$size" 50 @('--root', $scanRoots[$size], 'info', 'main/pkg00042', '--json')))
    $measurements.Add((Measure-Coop "search-scan-$size" 100 @('--root', $scanRoots[$size], 'search', 'pkg00042', '--json')))
    $measurements.Add((Measure-Coop "info-index-$size" 50 @('--root', $indexRoots[$size], 'info', 'main/pkg00042', '--json')))
    $measurements.Add((Measure-Coop "search-index-$size" 100 @('--root', $indexRoots[$size], 'search', 'pkg00042', '--json')))
}
$measurements.Add((Measure-Coop 'search-no-match-index-3000' 100 @('--root', $indexRoots[3000], 'search', 'absent-package-query', '--json')))
foreach ($count in 25, 100) {
    $measurements.Add((Measure-Coop "list-$count" 50 @('--root', (Join-Path $TestRoot "installed-$count"), 'list', '--json')))
}

# Local query contract: indexed and scanned paths must return the same facts, diagnostics for
# malformed manifests must survive indexing, and a query must not modify bucket source files.
$info = Invoke-Measured @('--root', $indexRoots[1500], 'info', 'main/pkg00777', '--json')
Assert ($info.exit -eq 0) "indexed info failed: $($info.error)"
Assert (@($info.output | ConvertFrom-Json)[0].version -eq '1.17.0') 'indexed info returned a wrong version'
$search = Invoke-Measured @('--root', $indexRoots[1500], 'search', 'pkg00777', '--json')
$searchItems = @($search.output | ConvertFrom-Json)
Assert ($search.exit -eq 0 -and $searchItems.Count -eq 1 -and $searchItems[0].name -eq 'pkg00777') 'indexed search returned wrong results'
$scanned = @((Invoke-Measured @('--root', $scanRoots[1500], 'search', 'pkg00777', '--json')).output | ConvertFrom-Json)
$facts = { param($item) [pscustomobject]@{ name=$item.name; version=$item.version; bucket=$item.bucket; description=$item.description } }
Assert (((& $facts $scanned[0]) | ConvertTo-Json -Compress) -eq ((& $facts $searchItems[0]) | ConvertTo-Json -Compress)) 'scan and index results differ'
$broken = @((Invoke-Measured @('--root', $indexRoots[200], 'search', 'broken', '--json')).output | ConvertFrom-Json)
Assert ($broken.Count -eq 1 -and @($broken[0].diagnostics).Count -eq 1) 'indexed search hid a malformed manifest diagnostic'
$sourceSnapshot = @(Get-ChildItem -LiteralPath $sources[1500] -Recurse -File | ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash })
$queryRegistry = Join-Path $indexRoots[1500] '.coop/buckets.json'
$queryRegistryHash = (Get-FileHash -LiteralPath $queryRegistry).Hash
$noMatch = Invoke-Measured @('--root', $indexRoots[1500], 'search', 'absent-package-query', '--json')
Assert (@($noMatch.output | ConvertFrom-Json).Count -eq 0) 'search no-match returned a package'
$sourceAfter = @(Get-ChildItem -LiteralPath $sources[1500] -Recurse -File | ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash })
Assert (@(Compare-Object $sourceSnapshot $sourceAfter).Count -eq 0) 'query modified bucket source files'
Assert ((Get-FileHash -LiteralPath $queryRegistry).Hash -eq $queryRegistryHash) 'query rewrote the bucket registry'

# Index hit: rewriting an entry without touching the source must be served. This proves the
# query read the index rather than rescanning the manifests.
$indexPath = Join-Path $indexRoots[1500] '.coop/index/main.json'
Assert (Test-Path -LiteralPath $indexPath) 'bucket synchronization did not write a search index'
$index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
$entry = @($index.entries | Where-Object name -eq 'pkg00777')[0]
$entry.version = '9.9.9-index-hit'
$index | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $indexPath -Encoding utf8
$hit = Invoke-Measured @('--root', $indexRoots[1500], 'info', 'main/pkg00777', '--json')
Assert (@($hit.output | ConvertFrom-Json)[0].version -eq '9.9.9-index-hit') 'validated index entry was not used'
# A changed local manifest invalidates the fingerprint; the query falls back to the files.
$changedManifest = Join-Path $sources[1500] 'bucket/pkg00777.json'
$manifestText = Get-Content -LiteralPath $changedManifest -Raw
[IO.File]::WriteAllText($changedManifest, ($manifestText -replace '"version":\s*"1\.17\.0"', '"version": "2.17.0"'))
$fallback = Invoke-Measured @('--root', $indexRoots[1500], 'info', 'main/pkg00777', '--json')
Assert (@($fallback.output | ConvertFrom-Json)[0].version -eq '2.17.0') 'stale local index did not fall back to source files'
$rebuilt = Invoke-Measured @('--root', $indexRoots[1500], 'bucket', 'update', 'main', '--json')
Assert ($rebuilt.exit -eq 0) "local bucket update failed: $($rebuilt.error)"
$rebuiltIndex = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
Assert ((@($rebuiltIndex.entries | Where-Object name -eq 'pkg00777')[0]).version -eq '2.17.0') 'explicit update did not rebuild the local index'
# Corruption is never fatal: the query scans the published files instead.
[IO.File]::WriteAllText($indexPath, 'not json')
$corrupt = Invoke-Measured @('--root', $indexRoots[1500], 'info', 'main/pkg00777', '--json')
Assert ($corrupt.exit -eq 0 -and @($corrupt.output | ConvertFrom-Json)[0].version -eq '2.17.0') 'corrupt index did not fall back to files'
$repaired = Invoke-Measured @('--root', $indexRoots[1500], 'bucket', 'update', 'main', '--json')
Assert ($repaired.exit -eq 0) 'index repair update failed'

# List contract: package counts and old-version evidence remain visible after optimization.
$listed25 = @((Invoke-Measured @('--root', (Join-Path $TestRoot 'installed-25'), 'list', '--json')).output | ConvertFrom-Json)
$listed100 = @((Invoke-Measured @('--root', (Join-Path $TestRoot 'installed-100'), 'list', '--json')).output | ConvertFrom-Json)
Assert ($listed25.Count -eq 25 -and $listed100.Count -eq 100) 'list hid installed packages'
$withOld = @($listed100 | Where-Object { @($_.old_versions).Count -gt 0 })
Assert ($withOld.Count -eq 25) 'list omitted old-version evidence'
Assert (@($withOld | Where-Object { @($_.old_versions | Where-Object version -eq '1.0.0').Count -eq 1 }).Count -eq 25) 'list omitted a retained old version'

# Git refresh: a local file:// repository exercises the same libgit2 path while keeping the
# default suite offline. Network payload is reported from libgit2 transfer progress.
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
    $startInfo.Environment['GIT_CONFIG_GLOBAL'] = $gitConfig
    $startInfo.Environment['GIT_CONFIG_SYSTEM'] = $gitConfig
    $startInfo.Environment['GIT_CONFIG_NOSYSTEM'] = '1'
    $startInfo.Environment['XDG_CONFIG_HOME'] = $gitTemplates
    $startInfo.ArgumentList.Add('-c')
    $startInfo.ArgumentList.Add('core.hooksPath=' + $gitTemplates)
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "fixture git failed: $($stderr.GetAwaiter().GetResult())" }
    return $stdout.GetAwaiter().GetResult().Trim()
}
$repository = Join-Path $TestRoot 'refresh-repository'
New-Item -ItemType Directory -Path "$repository/bucket" -Force | Out-Null
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $sources[1500] 'bucket') -File) {
    Copy-Item -LiteralPath $file.FullName -Destination "$repository/bucket/$($file.Name)"
}
Invoke-FixtureGit @('init', '-b', 'trunk', ('--template=' + $gitTemplates), $repository) | Out-Null
Invoke-FixtureGit @('-C', $repository, 'add', 'bucket') | Out-Null
Invoke-FixtureGit @('-C', $repository, '-c', 'user.name=CoopPerf', '-c', 'user.email=coop@example.invalid', 'commit', '-m', 'initial') | Out-Null
$repositoryUrl = ([uri]($repository.Replace('\', '/') + '/')).AbsoluteUri
$gitRoot = Join-Path $TestRoot 'refresh-root'
New-Item -ItemType Directory -Path $gitRoot -Force | Out-Null
$refreshFirst = Invoke-Measured @('--root', $gitRoot, 'bucket', 'add', 'main', $repositoryUrl, '--branch', 'trunk', '--json')
Assert ($refreshFirst.exit -eq 0) "git bucket add failed: $($refreshFirst.error)"
$firstRecord = $refreshFirst.output | ConvertFrom-Json
Assert ($firstRecord.changed -eq $true -and $firstRecord.revision -eq (Invoke-FixtureGit @('-C', $repository, 'rev-parse', 'HEAD'))) 'git first fetch published the wrong revision'
Assert (Test-Path -LiteralPath (Join-Path $gitRoot '.coop/index/main.json')) 'git synchronization did not write a search index'
$snapshotDirectory = Join-Path $gitRoot '.coop/snapshots'
$gitRegistry = Join-Path $gitRoot '.coop/buckets.json'
$snapshotsBefore = @(Get-ChildItem -LiteralPath $snapshotDirectory -Directory).Count
$gitIndexHashBefore = (Get-FileHash -LiteralPath (Join-Path $gitRoot '.coop/index/main.json')).Hash
$registryHashBefore = (Get-FileHash -LiteralPath $gitRegistry).Hash
$registryBefore = @(Get-Content -LiteralPath $gitRegistry -Raw | ConvertFrom-Json)[0]
$refreshSame = Invoke-Measured @('--root', $gitRoot, 'bucket', 'update', 'main', '--json')
Assert ($refreshSame.exit -eq 0) "git no-change refresh failed: $($refreshSame.error)"
$sameRecord = $refreshSame.output | ConvertFrom-Json
$registryAfter = @(Get-Content -LiteralPath $gitRegistry -Raw | ConvertFrom-Json)[0]
Assert ($sameRecord.changed -eq $false -and $sameRecord.path -eq $firstRecord.path) 'unchanged revision was republished'
Assert (@(Get-ChildItem -LiteralPath $snapshotDirectory -Directory).Count -eq $snapshotsBefore) 'no-change refresh created a snapshot'
Assert ((Get-FileHash -LiteralPath (Join-Path $gitRoot '.coop/index/main.json')).Hash -eq $gitIndexHashBefore) 'no-change refresh rebuilt the search index'
Assert ($registryAfter.revision -eq $registryBefore.revision -and $registryAfter.path -eq $registryBefore.path -and
    (($registryAfter.files | ConvertTo-Json -Compress) -eq ($registryBefore.files | ConvertTo-Json -Compress))) 'no-change refresh changed the published snapshot record'
$registryMetadataRewritten = (Get-FileHash -LiteralPath $gitRegistry).Hash -ne $registryHashBefore
$snapshotFilesBefore = Get-ChildItem -LiteralPath $firstRecord.path -Recurse -File | Measure-Object -Property Length -Sum
New-ManifestFile (Join-Path $repository 'bucket/pkg09999.json') 'pkg09999' '3.0.0'
Invoke-FixtureGit @('-C', $repository, 'add', 'bucket/pkg09999.json') | Out-Null
Invoke-FixtureGit @('-C', $repository, '-c', 'user.name=CoopPerf', '-c', 'user.email=coop@example.invalid', 'commit', '-m', 'add pkg09999') | Out-Null
$refreshChanged = Invoke-Measured @('--root', $gitRoot, 'bucket', 'update', 'main', '--json')
Assert ($refreshChanged.exit -eq 0) "git changed refresh failed: $($refreshChanged.error)"
$changedRecord = $refreshChanged.output | ConvertFrom-Json
Assert ($changedRecord.changed -eq $true -and $changedRecord.path -ne $firstRecord.path) 'new revision was not published'
Assert (@(Get-ChildItem -LiteralPath $snapshotDirectory -Directory).Count -eq $snapshotsBefore + 1) 'changed refresh did not publish one new snapshot'
Assert ((Get-FileHash -LiteralPath (Join-Path $gitRoot '.coop/index/main.json')).Hash -ne $gitIndexHashBefore) 'changed refresh did not rebuild the search index'
$newPackage = Invoke-Measured @('--root', $gitRoot, 'info', 'main/pkg09999', '--json')
Assert ($newPackage.exit -eq 0 -and @($newPackage.output | ConvertFrom-Json)[0].version -eq '3.0.0') 'new revision is not queryable'
$measurements.Add((Measure-Coop 'info-git-index-1500' 50 @('--root', $gitRoot, 'info', 'main/pkg00042', '--json')))
$measurements.Add((Measure-Coop 'search-git-index-1500' 100 @('--root', $gitRoot, 'search', 'pkg00042', '--json')))
# A repeat first fetch in a fresh root separates repository cache warm-up from Coop's own work.
$warmRoot = Join-Path $TestRoot 'refresh-root-warm'
New-Item -ItemType Directory -Path $warmRoot -Force | Out-Null
$refreshFirstWarm = Invoke-Measured @('--root', $warmRoot, 'bucket', 'add', 'main', $repositoryUrl, '--branch', 'trunk', '--json')
Assert ($refreshFirstWarm.exit -eq 0) "warm git bucket add failed: $($refreshFirstWarm.error)"
$warmRecord = $refreshFirstWarm.output | ConvertFrom-Json
Assert ($warmRecord.changed -eq $true -and $warmRecord.revision -eq $changedRecord.revision) 'warm first fetch published a wrong revision'
$oldSnapshot = Get-ChildItem -LiteralPath $firstRecord.path -Recurse -File | Measure-Object -Property Length -Sum
Assert ($oldSnapshot.Count -eq $snapshotFilesBefore.Count -and $oldSnapshot.Sum -eq $snapshotFilesBefore.Sum) 'old snapshot was modified by the refresh'

$disk = 'unavailable'
try {
    $physical = Get-PhysicalDisk | Select-Object -First 1
    if ($null -ne $physical) { $disk = "$($physical.FriendlyName) media=$($physical.MediaType) bus=$($physical.BusType)" }
} catch { }
$cmakeVersion = 'unavailable'
try { $cmakeVersion = (& cmake --version | Select-Object -First 1) } catch { }
$ninjaVersion = 'unavailable'
try { $ninjaVersion = (& ninja --version) } catch { }
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
}
$refresh = [ordered]@{
    transport = 'file:// (offline libgit2 fixture; no external network)'
    first = [ordered]@{ ms = [math]::Round($refreshFirst.ms, 1); received_bytes = $firstRecord.received_bytes; changed = $firstRecord.changed; revision = $firstRecord.revision; cache = 'first fetch after fixture creation (repository data not yet read by Coop)' }
    first_warm = [ordered]@{ ms = [math]::Round($refreshFirstWarm.ms, 1); received_bytes = $warmRecord.received_bytes; changed = $warmRecord.changed; revision = $warmRecord.revision; cache = 'repeat first fetch in a fresh root after the fixture is in the OS cache' }
    no_change = [ordered]@{ ms = [math]::Round($refreshSame.ms, 1); received_bytes = $sameRecord.received_bytes; changed = $sameRecord.changed; snapshots_created = 0; index_rebuilt = $false; snapshot_path = $sameRecord.path; snapshot_files_unchanged = $true; registry_metadata_rewritten = $registryMetadataRewritten }
    changed = [ordered]@{ ms = [math]::Round($refreshChanged.ms, 1); received_bytes = $changedRecord.received_bytes; changed = $changedRecord.changed; snapshots_created = 1; index_rebuilt = $true; snapshot_files_unchanged = $true; old_snapshot_retained = $true }
}
$report = [ordered]@{
    generated_at = [DateTime]::UtcNow.ToString('o')
    test_root = $TestRoot
    bucket_sizes = @($sizes)
    installed_counts = @(25, 100)
    runs_per_measurement = $Runs
    process_start_floor_ms = [ordered]@{ p50 = [math]::Round($floor[[int][math]::Floor($floor.Count / 2)], 1); min = [math]::Round($floor[0], 1); max = [math]::Round($floor[-1], 1) }
    environment = $environment
    targets_ms = [ordered]@{ version = 30; list = 50; info = 50; search = 100 }
    measurements = @($measurements)
    refresh = $refresh
    cold_cache = 'The first invocation after fixture creation is reported as first_ms. Dropping the Windows standby list requires administrator intervention outside this task, so a true cold-cache run is not claimed.'
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $TestRoot 'perf-report.json') -Encoding utf8
$measurements | Format-Table name, target_ms, first_ms, p50_ms, p90_ms, min_ms, max_ms, target_met -AutoSize | Out-String -Width 200 | Write-Output
Write-Output ("process start floor: p50={0}ms; index report: {1}" -f $report.process_start_floor_ms.p50, (Join-Path $TestRoot 'perf-report.json'))
foreach ($measurement in $measurements) {
    if (-not $measurement.target_met) {
        Write-Output ("TARGET MISSED: {0} p50={1}ms > {2}ms" -f $measurement.name, $measurement.p50_ms, $measurement.target_ms)
    }
}
Write-Output ("refresh: first={0}ms bytes={1}; first-warm={2}ms bytes={3}; no-change={4}ms bytes={5} changed={6}; changed={7}ms bytes={8} changed={9}" -f `
    $refresh.first.ms, $refresh.first.received_bytes, $refresh.first_warm.ms, $refresh.first_warm.received_bytes,
    $refresh.no_change.ms, $refresh.no_change.received_bytes, $refresh.no_change.changed,
    $refresh.changed.ms, $refresh.changed.received_bytes, $refresh.changed.changed)
Write-Output 'PASS: measured version/list/info/search, index hit/fallback/rebuild, unchanged Git refresh without rebuild, changed Git refresh'


# Red when: local status v2 omits healthy facts, claims remote freshness, loses diagnostics,
# mutates state, contacts a remote, emits multiple JSON documents, or changes legacy status JSON.
param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test root' }
$session = Join-Path $TestRoot ([Guid]::NewGuid().ToString('N'))
$root = Join-Path $session 'root'
$state = Join-Path $session 'state'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$savedState = $env:COOP_STATE_DIR
$savedApi = $env:COOP_GITHUB_API
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$remote = 'http://127.0.0.1:' + $port
$env:COOP_STATE_DIR = $state
$env:COOP_GITHUB_API = $remote
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Snapshot([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '<absent>' }
    $lines = foreach ($item in Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object FullName) {
        $name = $item.FullName.Substring($Path.Length)
        if ($item.PSIsContainer) { 'D ' + $name } else { 'F ' + $name + ' ' + (Get-FileHash -LiteralPath $item.FullName).Hash + ' ' + $item.LastWriteTimeUtc.Ticks }
    }
    return $lines -join "`n"
}
function Read-V2([int]$ExpectedCode = 0,[string]$GlobalRoot = '') {
    $before = Snapshot $root
    $beforeState = Snapshot $state
    $arguments = @('--root',$root,'status','-l','--json=2')
    $beforeGlobal = if ($GlobalRoot) { Snapshot $GlobalRoot } else { '' }
    if ($GlobalRoot) { $arguments += @('--global-root',$GlobalRoot) }
    $result = Invoke-CoopNativeRaw -Exe $CoopExe -Arguments $arguments
    Check ($result.code -eq $ExpectedCode) "v2 exited $($result.code): $($result.err) $($result.out)"
    Check ([string]::IsNullOrWhiteSpace($result.err)) "v2 mixed diagnostics into stderr: $($result.err)"
    $report = $result.out | ConvertFrom-Json
    Check ($report.schema_version -eq 2 -and $report.command -eq 'status' -and $report.scope -eq 'local') 'Missing v2 identity/scope'
    Check ($null -ne $report.clients -and $null -ne $report.buckets -and $null -ne $report.apps -and $null -ne $report.stages) 'Missing result groups'
    Check ((Snapshot $root) -ceq $before -and (Snapshot $state) -ceq $beforeState) 'Local status v2 changed shared or private state'
    if ($GlobalRoot) { Check ((Snapshot $GlobalRoot) -ceq $beforeGlobal) 'Read-only global scope was changed' }
    Check (-not $listener.Pending()) 'Local status v2 contacted a remote'
    return $report
}
function Install-Fact([string]$Name,[string]$Version) {
    $directory = "$root/apps/$Name/current"
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    ('{"version":"' + $Version + '"}') | Set-Content "$directory/scoop-manifest.json" -Encoding ascii
    '{"bucket":"main","architecture":"64bit"}' | Set-Content "$directory/scoop-install.json" -Encoding ascii
}
function Write-GitIndex([string]$Revision,[string[]]$Names) {
    $bucketPath = [IO.Path]::GetFullPath("$root/buckets/main")
    $directory = [IO.Path]::GetFullPath("$root/buckets/main/bucket")
    ConvertTo-Json -Depth 8 -InputObject @(@{name='main';path=$bucketPath;kind='git';revision=$Revision;url=$remote}) |
        Set-Content "$state/buckets.json" -Encoding utf8
    $entries = @($Names | ForEach-Object { @{name=$_;version='1';description='';homepage='';bin=@();diagnostics=@()} })
    New-Item -ItemType Directory -Force -Path "$state/cache/index" | Out-Null
    ConvertTo-Json -Depth 8 -InputObject @{version=2;bucket='main';kind='git';path=$directory;revision=$Revision;entries=$entries} |
        Set-Content "$state/cache/index/main.json" -Encoding utf8
}
try {
    $empty = Read-V2
    Check (@($empty.apps).Count -eq 0 -and @($empty.buckets).Count -eq 0 -and $empty.summary.complete) 'Empty root is not a complete local report'
    $coop = @($empty.clients | Where-Object name -eq 'coop')
    $scoop = @($empty.clients | Where-Object name -eq 'scoop')
    Check ($coop.Count -eq 1 -and $coop[0].state -eq 'not_checked' -and $coop[0].reason -eq 'local-only') 'Coop remote check claimed freshness'
    Check ($scoop.Count -eq 1 -and $scoop[0].state -eq 'not_applicable' -and -not $scoop[0].data.installed) 'Missing Scoop not represented'
    New-Item -ItemType Directory -Force -Path "$root/buckets/main/bucket" | Out-Null
    '{"version":"1","post_install":"throw ''hooks must not run''"}' | Set-Content "$root/buckets/main/bucket/demo.json" -Encoding ascii
    & git init -q -b main "$root/buckets/main"
    & git -C "$root/buckets/main" add .
    & git -C "$root/buckets/main" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m initial
    if ($LASTEXITCODE -ne 0) { throw 'Git fixture failed' }
    & git -C "$root/buckets/main" remote add origin $remote
    $head = & git -C "$root/buckets/main" rev-parse HEAD
    Install-Fact demo 1
    Copy-Item "$root/buckets/main/bucket/demo.json" "$root/apps/demo/current/scoop-manifest.json" -Force
    $oldBefore = Invoke-CoopNativeRaw -Exe $CoopExe -Arguments @('--root',$root,'status','--json')
    Check ($oldBefore.code -eq 0 -and $oldBefore.out.Trim() -ceq '[]') 'Legacy baseline changed'
    New-Item -ItemType Directory -Force -Path "$root/.coop" | Out-Null
    'legacy' | Set-Content "$root/.coop/sentinel" -Encoding ascii
    $healthy = Read-V2
    $demo = @($healthy.apps | Where-Object name -eq 'demo')
    $bucket = @($healthy.buckets | Where-Object name -eq 'main')
    Check ($demo.Count -eq 1 -and $demo[0].state -eq 'ok' -and $demo[0].data.installed_version -eq '1') 'Healthy software omitted'
    Check ($bucket.Count -eq 1 -and $bucket[0].state -eq 'not_checked' -and $bucket[0].data.revision -eq $head) 'Bucket local facts or remote scope wrong'
    Check ($healthy.summary.state -eq 'ok' -and $healthy.summary.complete) 'Healthy local result incorrect'
    $headPath = "$root/buckets/main/.git/HEAD"
    $headBytes = [IO.File]::ReadAllBytes($headPath)
    [IO.File]::Delete($headPath)
    $missingHead = Read-V2 1
    Check (@($missingHead.buckets | Where-Object state -eq 'failed').Count -eq 1) 'Missing Git HEAD treated as an empty repository'
    $unreadableDemo = @($missingHead.apps | Where-Object name -eq 'demo')[0]
    Check ($unreadableDemo.state -eq 'failed' -and -not $unreadableDemo.data.manifest_removed) 'Unreadable source falsely reported as a removed manifest'
    [IO.File]::WriteAllBytes($headPath,$headBytes)
    '{"version":"2","depends":"missing"}' | Set-Content "$root/buckets/main/bucket/demo.json" -Encoding ascii
    $attention = Read-V2
    $demo = @($attention.apps | Where-Object name -eq 'demo')[0]
    Check ($demo.state -eq 'attention' -and $demo.data.manifest_version -eq '2' -and @($demo.data.missing_dependencies) -contains 'missing') 'Local software issues lost'
    Check ($attention.summary.state -eq 'attention' -and $attention.summary.complete) 'Reported issue confused with failed check'
    '{"version":"1"}' | Set-Content "$root/buckets/main/bucket/demo.json" -Encoding ascii
    New-Item -ItemType Directory -Force -Path "$root/apps/scoop/current" | Out-Null
    $installedScoop = Read-V2
    $scoop = @($installedScoop.clients | Where-Object name -eq 'scoop')[0]
    Check ($scoop.state -eq 'not_checked' -and $scoop.data.installed) 'Installed Scoop was not reported as unchecked'
    Install-Fact broken 1
    '{broken' | Set-Content "$root/apps/broken/current/scoop-manifest.json" -Encoding ascii
    $damaged = Read-V2 1
    $broken = @($damaged.apps | Where-Object name -eq 'broken')[0]
    Check ($broken.state -eq 'failed' -and @($broken.diagnostics).Count -gt 0 -and -not $damaged.summary.complete) 'Corrupt installed facts hidden'
    Check (@($damaged.apps | Where-Object name -eq 'demo').Count -eq 1) 'One failed fact hid healthy software'
    '{"version":"1"}' | Set-Content "$root/apps/broken/current/scoop-manifest.json" -Encoding ascii
    '{bad' | Set-Content "$root/buckets/main/bucket/broken.json" -Encoding ascii
    $badManifest = Read-V2 1
    Check (@($badManifest.buckets | Where-Object state -eq 'failed').Count -eq 1) 'Corrupt bucket manifest not diagnosed'
    '{"version":"1"}' | Set-Content "$root/buckets/main/bucket/broken.json" -Encoding ascii
    New-Item -ItemType Directory -Force -Path $state | Out-Null
    '{bad' | Set-Content "$state/buckets.json" -Encoding ascii
    $badRegistry = Read-V2 1
    Check (@($badRegistry.diagnostics).Count -gt 0 -and @($badRegistry.buckets).Count -eq 1) 'Bad registry hid shared buckets or lacked a diagnostic'
    [IO.File]::Delete("$state/buckets.json")
    Copy-Item "$root/buckets/main/bucket/demo.json" "$root/apps/demo/current/scoop-manifest.json" -Force
    $legacy = Invoke-CoopNativeRaw -Exe $CoopExe -Arguments @('--root',$root,'status','--json')
    Check ($legacy.code -eq 0 -and $legacy.out.Trim() -ceq '[]') 'Legacy JSON shape/content changed'
    '{bad' | Set-Content "$root/apps/demo/current/scoop-install.json" -Encoding ascii
    '{"version":"2"}' | Set-Content "$root/buckets/main/bucket/demo.json" -Encoding ascii
    $badInstall = Read-V2 1
    $demo = @($badInstall.apps | Where-Object name -eq 'demo')[0]
    Check ($demo.state -eq 'failed' -and $demo.data.installed_version -eq '1') 'Bad install record hid a readable installed version'
    '{"bucket":"main","architecture":"64bit"}' | Set-Content "$root/apps/demo/current/scoop-install.json" -Encoding ascii
    $missing = Join-Path $session 'missing-bucket'
    ConvertTo-Json -InputObject @(@{name='gone';path=$missing;kind='local'}) | Set-Content "$state/buckets.json" -Encoding ascii
    $missingBucket = Read-V2 1
    Check (@($missingBucket.buckets | Where-Object { $_.name -eq 'gone' -and $_.state -eq 'failed' }).Count -eq 1) 'Missing registered bucket hidden'
    [IO.File]::Delete("$state/buckets.json")
    'bad git metadata' | Set-Content "$root/apps/scoop/current/.git" -Encoding ascii
    $badScoop = Read-V2 1
    Check (@($badScoop.clients | Where-Object { $_.name -eq 'scoop' -and $_.state -eq 'failed' }).Count -eq 1) 'Corrupt Scoop metadata hidden'
    [IO.File]::Delete("$root/apps/scoop/current/.git")
    Install-Fact coop 0.3.3
    $rootCoop = Read-V2
    Check (@($rootCoop.apps | Where-Object name -eq 'coop').Count -eq 0 -and
        @($rootCoop.clients | Where-Object { $_.name -eq 'coop' -and $_.data.installed }).Count -eq 1) 'Coop client treated as ordinary software'
    $globalRoot = Join-Path $session 'global'
    New-Item -ItemType Directory -Force -Path "$globalRoot/apps/demo/current" | Out-Null
    '{"version":"3"}' | Set-Content "$globalRoot/apps/demo/current/scoop-manifest.json" -Encoding ascii
    '{"bucket":"main","architecture":"64bit"}' | Set-Content "$globalRoot/apps/demo/current/scoop-install.json" -Encoding ascii
    $globalReport = Read-V2 0 $globalRoot
    Check (@($globalReport.apps | Where-Object { $_.name -eq 'demo' -and $_.scope -eq 'global' -and $_.data.read_only }).Count -eq 1) 'Global facts omitted or not marked read-only'
    ConvertTo-Json -InputObject @(@{name='main';path="$root/buckets/main";kind='removed'}) | Set-Content "$state/buckets.json" -Encoding ascii
    $removed = Read-V2
    Check (@($removed.buckets).Count -eq 0) 'Removed bucket was silently reactivated'
    [IO.File]::Delete("$state/buckets.json")
    $invalid = Invoke-CoopNativeRaw -Exe $CoopExe -Arguments @('--root',$root,'status','-l','--json=3')
    Check ($invalid.code -eq 2) 'Unsupported JSON version was accepted'
    foreach ($case in @(
        @{args=@('update','--json=2');code=1},
        @{args=@('status','-l','--json','--json=2');code=2},
        @{args=@('status','-l','--json=2','--json');code=2}
    )) {
        $before = Snapshot $root
        $beforeState = Snapshot $state
        $result = Invoke-CoopNativeRaw -Exe $CoopExe -Arguments (@('--root',$root) + $case.args)
        Check ($result.code -eq $case.code -and [string]::IsNullOrWhiteSpace($result.out)) 'Unsupported/conflicting format silently degraded'
        Check ((Snapshot $root) -ceq $before -and (Snapshot $state) -ceq $beforeState -and -not $listener.Pending()) 'Rejected v2 request had side effects'
    }
    $alias = Invoke-CoopNativeRaw -Exe $CoopExe -Arguments @('--root',$root,'status','--local','--json=2')
    Check ($alias.code -eq 0 -and ($alias.out | ConvertFrom-Json).scope -eq 'local') 'Local long switch lost v2 support'
    # Simulate a valid Coop index, followed by a Scoop-side commit while private metadata stays old.
    & git -C "$root/buckets/main" add .
    & git -C "$root/buckets/main" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m cached-baseline
    if ($LASTEXITCODE -ne 0) { throw 'Cannot commit cache baseline' }
    $cachedHead = & git -C "$root/buckets/main" rev-parse HEAD
    Write-GitIndex $cachedHead @('demo','broken')
    '{"version":"1"}' | Set-Content "$root/buckets/main/bucket/fresh.json" -Encoding ascii
    & git -C "$root/buckets/main" add .
    & git -C "$root/buckets/main" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m scoop-side-update
    if ($LASTEXITCODE -ne 0) { throw 'Cannot simulate Scoop-side update' }
    $actualHead = & git -C "$root/buckets/main" rev-parse HEAD
    Install-Fact fresh 1
    $advanced = Read-V2
    $fresh = @($advanced.apps | Where-Object name -eq 'fresh')[0]
    Check ($fresh.state -eq 'ok' -and -not $fresh.data.manifest_removed) 'Old registered Git index hid a Scoop-side manifest'
    Check (@($advanced.buckets | Where-Object name -eq 'main')[0].data.revision -eq $actualHead) 'Cached revision replaced actual HEAD'
    Write-GitIndex $actualHead @('demo','broken','fresh')
    '{bad' | Set-Content "$root/buckets/main/bucket/dirty.json" -Encoding ascii
    $dirty = Read-V2 1
    Check (@($dirty.buckets | Where-Object state -eq 'failed').Count -eq 1) 'Same-HEAD cache hid a corrupt worktree manifest'
    [IO.File]::Delete("$root/buckets/main/bucket/dirty.json")
    Write-Output 'PASS local status v2 facts, diagnostics, legacy JSON compatibility and no remote/state effects'
} finally {
    $listener.Stop()
    $env:COOP_STATE_DIR = $savedState
    $env:COOP_GITHUB_API = $savedApi
}

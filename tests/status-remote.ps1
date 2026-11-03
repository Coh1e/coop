# Red when: bare status omits Coop/Scoop update checks, local mode contacts a remote,
# failed checks claim success, or a check changes Scoop's working tree or refs.
param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test data must stay within the project test directory' }
$TestRoot = Join-Path $TestRoot ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path "$TestRoot/api/repos/Coh1e/coop/releases", "$TestRoot/root" | Out-Null
$savedApi = $env:COOP_GITHUB_API
$env:COOP_GITHUB_API = 'file:///' + ((Join-Path $TestRoot 'api') -replace '\\','/')
$release = "$TestRoot/api/repos/Coh1e/coop/releases/latest"
function Check-Status([string[]]$Options, [string]$Pattern, [string]$Absent = '', [int]$ExpectedCode = 0) {
    $lines = @(& $CoopExe --root "$TestRoot/root" status @Options)
    if ($LASTEXITCODE -ne $ExpectedCode) { throw "status exited $LASTEXITCODE, expected $ExpectedCode" }
    $text = $lines -join "`n"
    if ($text -notmatch $Pattern -or ($Absent -and $text -match $Absent)) { throw "Unexpected status: $text; expected $Pattern; absent $Absent" }
}
try {
    '{"tag_name":"v999.0.0"}' | Set-Content $release -Encoding ascii
    Check-Status @() 'Coop update available:.*999\.0\.0' 'Everything is ok|Scoop is'
    $version = ((& $CoopExe --version) -replace '^coop ','').Trim()
    ('{"tag_name":"v' + $version + '"}') | Set-Content $release -Encoding ascii
    Check-Status @() 'Coop is up to date\.' 'Scoop is'
    '{"tag_name":"v0.0.0"}' | Set-Content $release -Encoding ascii
    Check-Status @() 'Coop is up to date\.' 'Coop update available'
    '{}' | Set-Content $release -Encoding ascii
    Check-Status @() 'WARN  Could not check Coop updates' 'Everything is ok|Coop is up to date' 1
    '{"tag_name":"v999.0.0-preview"}' | Set-Content $release -Encoding ascii
    Check-Status @() 'versions cannot be compared' 'Everything is ok|Could not check Coop updates' 1
    [IO.File]::Delete($release)
    Check-Status @() 'WARN  Could not check Coop updates' 'Everything is ok|Coop is up to date' 1
    Check-Status @('-l') '^Everything is ok!$'
    Check-Status @('--local') '^Everything is ok!$'
    Check-Status @('--json') '^\[\]$'
    ('{"tag_name":"v' + $version + '"}') | Set-Content $release -Encoding ascii
    $source = "$TestRoot/source"
    if (-not (Test-Path "$source/.git")) {
        & git init -q -b main $source
        & git -C $source -c user.name=fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m initial
    }
    New-Item -ItemType Directory -Force -Path "$TestRoot/root/apps/scoop" | Out-Null
    $current = "$TestRoot/root/apps/scoop/current"
    if (-not (Test-Path "$current/.git")) { & git clone -q $source $current }
    if ($LASTEXITCODE -ne 0) { throw 'Git fixture setup failed' }
    & git -C $current remote set-url origin $source
    & git -C $current checkout -q main
    & git -C $current fetch -q origin
    & git -C $current reset -q --hard origin/main
    Check-Status @() 'Scoop is up to date\.'
    $head = & git -C $current rev-parse HEAD
    $tracking = & git -C $current rev-parse refs/remotes/origin/main
    & git -C $current -c user.name=fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m local-ahead
    Check-Status @() 'Scoop is up to date\.'
    & git -C $current reset -q --hard $head
    'keep' | Set-Content "$current/user-file" -Encoding ascii
    & git -C $source -c user.name=fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m newer
    Check-Status @() 'Scoop out of date\.' 'Everything is ok'
    if ((& git -C $current rev-parse HEAD) -ne $head -or
        (& git -C $current rev-parse refs/remotes/origin/main) -ne $tracking -or
        (Get-Content "$current/user-file") -ne 'keep') { throw 'Status changed Scoop state' }
    & git -C $current remote set-url origin "$TestRoot/missing-remote"
    Check-Status @() 'WARN  Could not check Scoop updates' 'Everything is ok|Scoop is up to date' 1
    Check-Status @('-l') '^Everything is ok!$'
    & git -C $current remote set-url origin $source
    & git -C $current checkout -q --detach
    Check-Status @() 'WARN  Could not check Scoop updates' 'Everything is ok|Scoop is up to date' 1
    & git -C $current checkout -q main
    # A failed client check must not hide the local package status table.
    New-Item -ItemType Directory -Force -Path "$TestRoot/root/buckets/main/bucket", "$TestRoot/root/apps/demo/1" | Out-Null
    '{"version":"2"}' | Set-Content "$TestRoot/root/buckets/main/bucket/demo.json" -Encoding ascii
    '{"version":"1"}' | Set-Content "$TestRoot/root/apps/demo/1/scoop-manifest.json" -Encoding ascii
    '{"bucket":"main","architecture":"64bit"}' | Set-Content "$TestRoot/root/apps/demo/1/scoop-install.json" -Encoding ascii
    New-Item -ItemType Junction -Path "$TestRoot/root/apps/demo/current" -Target "$TestRoot/root/apps/demo/1" | Out-Null
    & git -C $current remote set-url origin "$TestRoot/missing-remote"
    Check-Status @() '(?s)Could not check Scoop updates.*demo\s+1\s+2' 'Everything is ok' 1
    # Publish a newer Manifest upstream without updating the shared checkout.
    $bucket = "$TestRoot/root/buckets/main"
    $remoteBucket = "$TestRoot/bucket-remote"
    function Invoke-FixtureGit {
        & git @args
        if ($LASTEXITCODE -ne 0) { throw "Git fixture command failed: $args" }
    }
    Invoke-FixtureGit init -q -b main $bucket
    Invoke-FixtureGit -C $bucket add bucket/demo.json
    Invoke-FixtureGit -C $bucket -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm v2
    Invoke-FixtureGit clone -q $bucket $remoteBucket
    Invoke-FixtureGit -C $bucket remote add origin $remoteBucket
    Invoke-FixtureGit -C $bucket fetch -q origin
    Invoke-FixtureGit -C $bucket branch --set-upstream-to=origin/main main | Out-Null
    Invoke-FixtureGit -C $current remote set-url origin $source
    Invoke-FixtureGit -C $current pull -q --ff-only
    $legacyBefore = (& $CoopExe --root "$TestRoot/root" status --json) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0 -or ($legacyBefore | ConvertFrom-Json).latest_version -ne '2') {
        throw 'Legacy baseline must report local Manifest version 2'
    }
    '{"version":"3"}' | Set-Content "$remoteBucket/bucket/demo.json" -Encoding ascii
    Invoke-FixtureGit -C $remoteBucket add bucket/demo.json
    Invoke-FixtureGit -C $remoteBucket -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm v3

    function SharedSnapshot([string]$Path = "$TestRoot/root") {
        if (-not (Test-Path -LiteralPath $Path)) { return '<absent>' }
        $directories = Get-ChildItem -LiteralPath $Path -Force -Recurse -Directory | Sort-Object FullName | ForEach-Object FullName
        $files = Get-ChildItem -LiteralPath $Path -Force -Recurse -File | Sort-Object FullName |
            ForEach-Object { "$($_.FullName):$($_.LastWriteTimeUtc.Ticks):$((Get-FileHash -LiteralPath $_.FullName).Hash)" }
        return (@($Path) + @($directories) + @($files)) -join [Environment]::NewLine
    }
    $before = SharedSnapshot
    $bare = (& $CoopExe --root "$TestRoot/root" status) -join [Environment]::NewLine
    $bareExit = $LASTEXITCODE
    if ((SharedSnapshot) -cne $before) { throw 'Bare status changed shared files or Git state' }
    $legacyAfter = (& $CoopExe --root "$TestRoot/root" status --json) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0 -or $legacyAfter -cne $legacyBefore) { throw 'Legacy JSON changed after upstream advanced' }
    if ((SharedSnapshot) -cne $before) { throw 'Legacy status changed shared files or Git state' }
    Write-Output 'PASS: shared files and Git state unchanged, legacy JSON unchanged'
    if ($bareExit -ne 0) { throw "Bare status exited $bareExit despite readable upstream" }
    if ($bare -notmatch '(?i)(stale|outdated|old|out.of.date)\s+(local\s+)?manifests?') {
        throw "Bare status did not warn that software results use stale manifests: $bare"
    }
    $v2 = (& $CoopExe --root "$TestRoot/root" status --json=2) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $v2.scope -ne 'remote' -or -not $v2.summary.complete) {
        throw 'Expected a complete remote report'
    }
    $reportedBucket = $v2.buckets | Where-Object name -eq 'main'
    $reportedApp = $v2.apps | Where-Object name -eq 'demo'
    if ($reportedBucket.state -ne 'attention' -or $reportedBucket.reason -ne 'stale-manifests' -or
        -not $reportedBucket.data.manifests_may_be_stale -or $reportedApp.data.manifest_version -ne '2' -or
        -not $bare.Contains($reportedBucket.data.message)) {
        throw 'Remote JSON v2 and text disagree on stale manifests'
    }
    if ((SharedSnapshot) -cne $before) { throw 'Remote JSON v2 changed shared files or Git state' }
    if (@($v2.clients | Where-Object state -eq 'ok').Count -ne 2) {
        throw 'Successful remote checks did not report both clients'
    }
    '{}' | Set-Content $release -Encoding ascii
    $failed = (& $CoopExe --root "$TestRoot/root" status --json=2) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 1 -or $failed.summary.complete -or
        ($failed.clients | Where-Object name -eq 'coop').state -ne 'failed' -or
        ($failed.clients | Where-Object name -eq 'scoop').state -ne 'ok' -or
        ($failed.buckets | Where-Object name -eq 'main').reason -ne 'stale-manifests' -or
        ($failed.apps | Where-Object name -eq 'demo').data.manifest_version -ne '2') {
        throw 'Client failure did not preserve the other client, bucket and software results'
    }
    $invalid = Invoke-CoopNativeRaw -Exe $CoopExe -Arguments @('--root',"$TestRoot/root",'status','--json=2','invalid')
    if ($invalid.code -ne 2) { throw 'Invalid remote status usage did not exit 2' }
    if ((SharedSnapshot) -cne $before) { throw 'Remote client checks changed shared files or Git state' }
    if (($v2.clients | Where-Object name -eq 'coop').data.source -ne 'official-release') {
        throw 'Standalone Coop did not select the official release source'
    }
    function Invoke-HttpStatusFixture([string]$Response, [string[]]$Options) {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
        $listener.Start()
        $process = $null
        $client = $null
        try {
            $start = [Diagnostics.ProcessStartInfo]::new($CoopExe)
            $start.UseShellExecute = $false
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $start.EnvironmentVariables['COOP_GITHUB_API'] = "http://127.0.0.1:$($listener.LocalEndpoint.Port)"
            $start.EnvironmentVariables['NO_PROXY'] = '127.0.0.1'
            foreach ($argument in (@('--root',"$TestRoot/root",'status') + $Options)) {
                Add-ProcessArgument $start $argument
            }
            if ($Response) { $connection = $listener.AcceptTcpClientAsync() }
            else { $listener.Stop() }
            $process = [Diagnostics.Process]::Start($start)
            $output = $process.StandardOutput.ReadToEndAsync()
            $errors = $process.StandardError.ReadToEndAsync()
            if ($Response) {
                if (-not $connection.Wait(10000)) { throw 'Status did not reach the local HTTP fixture' }
                $client = $connection.GetAwaiter().GetResult()
                $stream = $client.GetStream()
                $stream.ReadTimeout = 5000
                $reader = [IO.StreamReader]::new($stream)
                if ($reader.ReadLine() -notmatch '^GET /repos/Coh1e/coop/releases/latest HTTP/') {
                    throw 'Unexpected release request'
                }
                while ($reader.ReadLine()) {}
                $bytes = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $Response`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                $stream.Write($bytes,0,$bytes.Length)
                $client.Close()
            }
            if (-not $process.WaitForExit(15000)) { throw 'Status fixture timed out' }
            return @{code=$process.ExitCode;out=$output.GetAwaiter().GetResult();err=$errors.GetAwaiter().GetResult()}
        } finally {
            if ($client) { $client.Dispose() }
            $listener.Stop()
            if ($process) {
                if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
                $process.Dispose()
            }
        }
    }
    foreach ($response in @('429 Too Many Requests','503 Service Unavailable','')) {
        $case = if ($response) { $response } else { 'connection refused' }
        $text = Invoke-HttpStatusFixture $response @()
        if ($text.out -notmatch 'Could not check Coop updates' -or $text.out -notmatch 'Scoop is up to date' -or
            $text.out -notmatch 'stale manifests' -or $text.out -notmatch 'demo\s+1\s+2' -or $text.out -match 'Everything is ok') {
            throw "$case lost the warning or available text results: $($text.out) $($text.err)"
        }
        if ($text.code -ne 1) { throw "$case warned but bare status exited $($text.code), expected 1" }
        $json = Invoke-HttpStatusFixture $response @('--json=2')
        $report = $json.out | ConvertFrom-Json
        if ($json.code -ne 1 -or $report.summary.complete -or
            ($report.clients | Where-Object name -eq 'coop').state -ne 'failed' -or
            ($report.clients | Where-Object name -eq 'scoop').state -ne 'ok' -or
            ($report.buckets | Where-Object name -eq 'main').reason -ne 'stale-manifests' -or
            ($report.apps | Where-Object name -eq 'demo').data.manifest_version -ne '2') {
            throw "$case lost available JSON v2 results"
        }
        $legacyHttp = Invoke-HttpStatusFixture '' @('--json')
        if ($legacyHttp.code -ne 0 -or $legacyHttp.out.TrimEnd() -cne $legacyBefore.TrimEnd()) {
            throw "$case changed legacy JSON"
        }
        if ((SharedSnapshot) -cne $before) { throw "$case changed shared state" }
    }
    '{"tag_name":"v999.0.0-preview"}' | Set-Content $release -Encoding ascii
    Check-Status @() '(?s)versions cannot be compared.*Scoop is up to date.*stale manifests.*demo\s+1\s+2' 'Could not check Coop updates|Everything is ok' 1
    $unknown = (& $CoopExe --root "$TestRoot/root" status --json=2) | ConvertFrom-Json
    $client = $unknown.clients | Where-Object name -eq 'coop'
    if ($LASTEXITCODE -ne 1 -or $unknown.summary.complete -or $client.state -ne 'blocked' -or
        $client.reason -ne 'version-incomparable' -or
        ($unknown.clients | Where-Object name -eq 'scoop').state -ne 'ok' -or
        ($unknown.buckets | Where-Object name -eq 'main').reason -ne 'stale-manifests' -or
        ($unknown.apps | Where-Object name -eq 'demo').data.manifest_version -ne '2') {
        throw 'Incomparable release version was not distinguished from a request failure'
    }
    $legacyUnknown = (& $CoopExe --root "$TestRoot/root" status --json) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0 -or $legacyUnknown -cne $legacyBefore) { throw 'Incomparable release changed legacy JSON' }
    if ((SharedSnapshot) -cne $before) { throw 'Incomparable release check wrote shared state' }
    # An unreachable bucket must not hide the other bucket's stale result or its software.
    ('{"tag_name":"v' + $version + '"}') | Set-Content $release -Encoding ascii
    $unreachableBucket = "$TestRoot/root/buckets/unreachable"
    Invoke-FixtureGit clone -q $bucket $unreachableBucket
    Invoke-FixtureGit -C $unreachableBucket remote set-url origin "$TestRoot/missing-bucket-remote"
    $before = SharedSnapshot
    Check-Status @() '(?s)Bucket main.*stale manifests.*Could not check remote status for bucket unreachable.*demo\s+1\s+2' 'Everything is ok' 1
    $partial = Invoke-CoopNativeRaw -Exe $CoopExe -Arguments @('--root',"$TestRoot/root",'status','--json=2')
    $report = $partial.out | ConvertFrom-Json
    $failedBucket = $report.buckets | Where-Object name -eq 'unreachable'
    $availableBucket = $report.buckets | Where-Object name -eq 'main'
    $availableApp = $report.apps | Where-Object name -eq 'demo'
    if ($partial.code -ne 1 -or $report.summary.complete -or
        $failedBucket.state -ne 'failed' -or $failedBucket.reason -ne 'bucket-remote-check-failed' -or
        $availableBucket.state -ne 'attention' -or $availableBucket.reason -ne 'stale-manifests' -or
        $availableApp.data.bucket -ne 'main' -or $availableApp.data.manifest_version -ne '2') {
        throw "Bucket failure lost available remote results: $($partial.out) $($partial.err)"
    }
    if ((SharedSnapshot) -cne $before) { throw 'Partial bucket checks wrote shared state' }
    Invoke-FixtureGit -C $unreachableBucket remote set-url origin $bucket
    $coopApp = "$TestRoot/root/apps/coop/current"
    New-Item -ItemType Directory -Force -Path $coopApp | Out-Null
    '{"version":"1"}' | Set-Content "$coopApp/scoop-manifest.json" -Encoding ascii
    '{"bucket":"main","architecture":"64bit"}' | Set-Content "$coopApp/scoop-install.json" -Encoding ascii
    $before = SharedSnapshot
    $stale = (& $CoopExe --root "$TestRoot/root" status --json=2) | ConvertFrom-Json
    $client = $stale.clients | Where-Object name -eq 'coop'
    if ($LASTEXITCODE -ne 1 -or $client.data.source -ne 'bucket' -or $client.state -ne 'failed' -or
        $client.diagnostics[0].message -notmatch 'stale manifests') {
        throw 'Coop treated its stale installation source as current or fell back to the official release'
    }
    if ((SharedSnapshot) -cne $before) { throw 'Stale Coop source check wrote shared state' }

    '{"version":"4"}' | Set-Content "$remoteBucket/bucket/coop.json" -Encoding ascii
    Invoke-FixtureGit -C $remoteBucket add bucket/coop.json
    Invoke-FixtureGit -C $remoteBucket -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'Publish Coop'
    Invoke-FixtureGit -C $bucket pull -q --ff-only
    $before = SharedSnapshot
    $bucketStatus = (& $CoopExe --root "$TestRoot/root" status --json=2) | ConvertFrom-Json
    $client = $bucketStatus.clients | Where-Object name -eq 'coop'
    if ($LASTEXITCODE -ne 0 -or $client.reason -ne 'update-available' -or $client.data.source -ne 'bucket' -or
        $client.data.bucket -ne 'main' -or $client.data.source_version -ne '4') {
        throw 'Bucket-installed Coop did not use its installation source'
    }
    Check-Status @() 'Coop update available from bucket main: 1 -> 4'
    if ((SharedSnapshot) -cne $before) { throw 'Coop source checks wrote shared state' }
    ('{"tag_name":"v' + $version + '"}') | Set-Content $release -Encoding ascii
    $legacySource = "$TestRoot/legacy-source"
    New-Item -ItemType Directory -Path $legacySource | Out-Null
    '{"version":"2"}' | Set-Content "$legacySource/demo.json" -Encoding ascii
    $savedState = $env:COOP_STATE_DIR
    try {
        foreach ($mode in @('text','v2')) {
            $legacyRoot = "$TestRoot/legacy-$mode/root"
            $private = "$TestRoot/legacy-$mode/private"
            $env:COOP_STATE_DIR = $private
            New-Item -ItemType Directory -Force -Path "$legacyRoot/.coop/index","$legacyRoot/apps/demo/current" | Out-Null
            ConvertTo-Json -InputObject @(@{name='legacy';kind='local';path=$legacySource}) |
                Set-Content "$legacyRoot/.coop/buckets.json" -Encoding ascii
            '[]' | Set-Content "$legacyRoot/.coop/index/probe.json" -Encoding ascii
            '{"version":"1"}' | Set-Content "$legacyRoot/apps/demo/current/scoop-manifest.json" -Encoding ascii
            '{"bucket":"legacy","architecture":"64bit"}' | Set-Content "$legacyRoot/apps/demo/current/scoop-install.json" -Encoding ascii
            $rootBefore = SharedSnapshot $legacyRoot
            $privateBefore = SharedSnapshot $private
            $options = @('--root',$legacyRoot,'status')
            if ($mode -eq 'v2') { $options += '--json=2' }
            $result = Invoke-CoopNativeRaw -Exe $CoopExe -Arguments $options
            if ($result.code -ne 0) { throw "Legacy $mode status failed: $($result.err)" }
            if ($mode -eq 'v2') {
                $report = $result.out | ConvertFrom-Json
                if (($report.apps | Where-Object name -eq 'demo').data.manifest_version -ne '2') {
                    throw 'Remote v2 did not read the legacy bucket registry'
                }
            } elseif ($result.out -notmatch 'demo\s+1\s+2') {
                throw 'Bare status did not read the legacy bucket registry'
            }
            if ((SharedSnapshot $legacyRoot) -cne $rootBefore -or (SharedSnapshot $private) -cne $privateBefore) {
                throw "Legacy $mode status migrated or wrote state"
            }
        }
    } finally { $env:COOP_STATE_DIR = $savedState }
    $savedState = $env:COOP_STATE_DIR
    try {
        $env:COOP_STATE_DIR = "$TestRoot/damaged-private"
        New-Item -ItemType Directory -Path $env:COOP_STATE_DIR | Out-Null
        '{broken' | Set-Content "$env:COOP_STATE_DIR/buckets.json" -Encoding ascii
        $rootBefore = SharedSnapshot
        $privateBefore = SharedSnapshot $env:COOP_STATE_DIR
        $arguments = @('--root',"$TestRoot/root",'status')
        $damaged = Invoke-CoopNativeRaw -Exe $CoopExe -Arguments $arguments
        if ($damaged.code -ne 1 -or $damaged.out -notmatch 'bucket-registry-unreadable' -or
            $damaged.out -notmatch 'demo\s+1\s+3' -or $damaged.out -notmatch 'Scoop is up to date') {
            throw "Damaged registry lost available text results or diagnostics: $($damaged.out) $($damaged.err)"
        }
        $remote = Invoke-CoopNativeRaw -Exe $CoopExe -Arguments ($arguments + '--json=2')
        $report = $remote.out | ConvertFrom-Json
        if ($remote.code -ne 1 -or $report.summary.complete -or
            $report.diagnostics.code -notcontains 'bucket-registry-unreadable' -or
            ($report.buckets | Where-Object name -eq 'main').state -ne 'ok' -or
            ($report.apps | Where-Object name -eq 'demo').data.manifest_version -ne '3') {
            throw 'Damaged registry lost available remote JSON v2 results or diagnostics'
        }
        ConvertTo-Json -InputObject @(@{name='main';kind='git';path=$bucket;fixed_revision=42}) |
            Set-Content "$env:COOP_STATE_DIR/buckets.json" -Encoding ascii
        $privateBefore = SharedSnapshot $env:COOP_STATE_DIR
        $typed = Invoke-CoopNativeRaw -Exe $CoopExe -Arguments $arguments
        if ($typed.code -ne 1 -or $typed.out -notmatch 'bucket-registry-entry-invalid.*fixed_revision' -or
            $typed.out -notmatch 'demo\s+1\s+3' -or $typed.out -notmatch 'Scoop is up to date') {
            throw "Numeric fixed_revision lost text results: $($typed.out) $($typed.err)"
        }
        $typed = Invoke-CoopNativeRaw -Exe $CoopExe -Arguments ($arguments + '--json=2')
        $report = $typed.out | ConvertFrom-Json
        if ($typed.code -ne 1 -or $report.summary.complete -or
            $report.diagnostics.code -notcontains 'bucket-registry-entry-invalid' -or
            ($report.buckets | Where-Object name -eq 'unreachable').reason -ne 'stale-manifests' -or
            ($report.apps | Where-Object name -eq 'demo').data.manifest_version -ne '3') {
            throw 'Numeric fixed_revision lost remote JSON v2 results'
        }
        if ((SharedSnapshot) -cne $rootBefore -or (SharedSnapshot $env:COOP_STATE_DIR) -cne $privateBefore) {
            throw 'Damaged registry status wrote shared or private state'
        }
    } finally { $env:COOP_STATE_DIR = $savedState }
    Write-Output 'PASS: remote status checks, local mode, failure handling and read-only Scoop check'
} finally { $env:COOP_GITHUB_API = $savedApi }

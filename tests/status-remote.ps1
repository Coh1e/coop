# Red when: bare status omits Coop/Scoop update checks, local mode contacts a remote,
# failed checks claim success, or a check changes Scoop's working tree or refs.
param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test data must stay within the project test directory' }
$TestRoot = Join-Path $TestRoot ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path "$TestRoot/api/repos/Coh1e/coop/releases", "$TestRoot/root" | Out-Null
$savedApi = $env:COOP_GITHUB_API
$env:COOP_GITHUB_API = 'file:///' + ((Join-Path $TestRoot 'api') -replace '\\','/')
$release = "$TestRoot/api/repos/Coh1e/coop/releases/latest"
function Check-Status([string[]]$Options, [string]$Pattern, [string]$Absent = '') {
    $lines = @(& $CoopExe --root "$TestRoot/root" status @Options)
    if ($LASTEXITCODE -ne 0) { throw "status exited $LASTEXITCODE" }
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
    Check-Status @() 'WARN  Could not check Coop updates' 'Everything is ok|Coop is up to date'
    '{"tag_name":"v999.0.0-preview"}' | Set-Content $release -Encoding ascii
    Check-Status @() 'WARN  Could not check Coop updates' 'Everything is ok|Coop is up to date'
    [IO.File]::Delete($release)
    Check-Status @() 'WARN  Could not check Coop updates' 'Everything is ok|Coop is up to date'
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
    Check-Status @() 'WARN  Could not check Scoop updates' 'Everything is ok|Scoop is up to date'
    Check-Status @('-l') '^Everything is ok!$'
    & git -C $current remote set-url origin $source
    & git -C $current checkout -q --detach
    Check-Status @() 'WARN  Could not check Scoop updates' 'Everything is ok|Scoop is up to date'
    & git -C $current checkout -q main
    # A failed client check must not hide the local package status table.
    New-Item -ItemType Directory -Force -Path "$TestRoot/root/buckets/main/bucket", "$TestRoot/root/apps/demo/1" | Out-Null
    '{"version":"2"}' | Set-Content "$TestRoot/root/buckets/main/bucket/demo.json" -Encoding ascii
    '{"version":"1"}' | Set-Content "$TestRoot/root/apps/demo/1/scoop-manifest.json" -Encoding ascii
    '{"bucket":"main","architecture":"64bit"}' | Set-Content "$TestRoot/root/apps/demo/1/scoop-install.json" -Encoding ascii
    New-Item -ItemType Junction -Path "$TestRoot/root/apps/demo/current" -Target "$TestRoot/root/apps/demo/1" | Out-Null
    & git -C $current remote set-url origin "$TestRoot/missing-remote"
    Check-Status @() '(?s)Could not check Scoop updates.*demo\s+1\s+2' 'Everything is ok'
    Write-Output 'PASS: remote status checks, local mode, failure handling and read-only Scoop check'
} finally { $env:COOP_GITHUB_API = $savedApi }

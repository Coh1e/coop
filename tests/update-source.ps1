# Red when: named update uses stale manifests, misses a newly declared source, or preview writes shared state.
param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$fixture = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
$root = Join-Path $fixture 'root'
$env:COOP_STATE_DIR = Join-Path $fixture 'state'
function Check([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
function Run([string[]]$arguments,[int]$code = 0) {
    $result = Invoke-CoopNativeRaw -Exe $CoopExe -Arguments (@('--root',$root) + $arguments)
    Check ($result.code -eq $code) "Unexpected exit $($result.code): $($arguments -join ' ') $($result.out) $($result.err)"
    return $result
}
function Publish([string]$bucket,[string]$package,[string]$version,[string]$dependency = '') {
    $remote = Join-Path $fixture $bucket
    if (-not (Test-Path $remote)) {
        New-Item -ItemType Directory -Path "$remote/bucket" -Force | Out-Null
        & git init -q -b main $remote
        Check ($LASTEXITCODE -eq 0) 'Git init failed'
    }
    $file = Join-Path (Split-Path $CoopExe) "fixture-$version.exe"
    $manifest = @{version=$version;url=([Uri][IO.Path]::GetFullPath($file)).AbsoluteUri+"#/$package.exe";hash=(Get-FileHash $file).Hash.ToLower();bin="$package.exe"}
    if ($dependency) { $manifest.depends = $dependency }
    $manifest | ConvertTo-Json | Set-Content "$remote/bucket/$package.json" -Encoding utf8
    & git -C $remote add .
    Check ($LASTEXITCODE -eq 0) 'Git add failed'
    & git -C $remote -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm "Release $version"
    Check ($LASTEXITCODE -eq 0) 'Git commit failed'
    & git -C $remote rev-parse HEAD
}
function Snapshot {
    $files = foreach ($directory in @($root,$env:COOP_STATE_DIR)) {
        Get-ChildItem -LiteralPath $directory -Force -Recurse -File | Sort-Object FullName | ForEach-Object {
            $_.FullName + ':' + $_.LastWriteTimeUtc.Ticks + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash
        }
    }
    return $files -join "`n"
}
$null = Publish 'upstream' 'demo' '1'
$null = Publish 'dependent' 'helper' '1'
foreach ($bucket in @('upstream','dependent')) {
    $url = ([Uri][IO.Path]::GetFullPath((Join-Path $fixture $bucket))).AbsoluteUri
    $null = Run @('bucket','add',$bucket,$url,'--branch','main','--json')
}
$null = Run @('install','dependent/helper','--json')
$null = Run @('install','upstream/demo','--json')
$depRevision = Publish 'dependent' 'helper' '2'
$revision = Publish 'upstream' 'demo' '2' 'dependent/helper'
$before = Snapshot
$preview = Run @('update','demo','--dry-run','--json') 1
Check ($preview.out -match 'remote revision differs') 'Stale preview did not explain missing revision evidence'
Check ((Snapshot) -ceq $before) 'Preview changed shared worktree, Git references or Coop state'
$result = (Run @('update','demo','--json')).out | ConvertFrom-Json
Check ($result.version -eq '2' -and $result.status -eq 'success') 'Single update did not install the refreshed version'
Check (@($result.source_revisions).Count -eq 2) 'Update did not report both planned revisions'
Check ((& "$root/shims/demo.exe") -eq 'fixture 2') 'Refreshed payload was not published'
$before = Snapshot
$plan = (Run @('update','demo','--dry-run','--json')).out | ConvertFrom-Json
Check (@($plan.source_revisions | Where-Object { $_.bucket -eq 'upstream' -and $_.revision -eq $revision }).Count -eq 1) 'Target revision is missing'
Check (@($plan.source_revisions | Where-Object { $_.bucket -eq 'dependent' -and $_.revision -eq $depRevision }).Count -eq 1) 'New dependency source was not refreshed'
Check ((Snapshot) -ceq $before) 'Successful preview changed state'
$manifest = "$root/buckets/dependent/bucket/helper.json"
$original = [IO.File]::ReadAllBytes($manifest)
[IO.File]::AppendAllText($manifest,' ')
$before = Snapshot
$dirty = Run @('update','demo','--dry-run','--json') 1
Check ($dirty.out -match 'local bucket modifications') 'Dirty dependency source was not reported'
Check ((Snapshot) -ceq $before) 'Dirty-source preview changed state'
[IO.File]::WriteAllBytes($manifest,$original)
$missing = ([Uri][IO.Path]::GetFullPath((Join-Path $fixture 'missing'))).AbsoluteUri
& git -C "$root/buckets/dependent" remote set-url origin $missing
Check ($LASTEXITCODE -eq 0) 'Could not configure unavailable fixture source'
$failed = Run @('update','demo','--json') 1
Check ($failed.err -match 'Bucket dependent' -and $failed.out -notmatch 'up-to-date') 'Source failure was hidden as an up-to-date result'
Check ((& "$root/shims/demo.exe") -eq 'fixture 2') 'Failed source changed installed software'
$pinRevision = Publish 'pinned' 'pin' '1'
$pinUrl = ([Uri][IO.Path]::GetFullPath((Join-Path $fixture 'pinned'))).AbsoluteUri
$null = Run @('bucket','add','pinned',$pinUrl,'--branch','main','--revision',$pinRevision,'--json')
$null = Run @('install','pinned/pin','--json')
$null = Publish 'pinned' 'pin' '2'
$before = Snapshot
$pin = (Run @('update','pin','--dry-run','--json')).out | ConvertFrom-Json
Check ($pin.package.version -eq '1' -and $pin.source_revisions[0].revision -eq $pinRevision) 'Preview ignored the fixed revision'
Check ((Snapshot) -ceq $before) 'Fixed-revision preview changed state'
$pin = (Run @('update','pin','--json')).out | ConvertFrom-Json
Check ($pin.version -eq '1' -and $pin.status -eq 'up-to-date') 'Update moved a fixed revision'
Write-Output 'PASS named update source preparation and read-only preview'

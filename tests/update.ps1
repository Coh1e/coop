param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null
function Manifest([string]$version) {
    $source = Join-Path (Split-Path $CoopExe) "fixture-$version.exe"
    @{version=$version;url=([Uri][IO.Path]::GetFullPath($source)).AbsoluteUri+'#/fixture.exe';hash=(Get-FileHash $source -Algorithm SHA256).Hash.ToLower();bin='fixture.exe'} | ConvertTo-Json | Set-Content "$root/buckets/test/bucket/fixture.json" -Encoding utf8
}
Manifest '1'
$install = & $CoopExe --root $root install test/fixture --json
if ($LASTEXITCODE -ne 0 -or (& "$root/shims/fixture.exe") -ne 'fixture 1') { throw 'initial program version wrong' }
Manifest '2'
$goodManifest = [IO.File]::ReadAllText("$root/buckets/test/bucket/fixture.json")
$bad = $goodManifest | ConvertFrom-Json
$bad.hash = '0'*64
$bad | ConvertTo-Json | Set-Content "$root/buckets/test/bucket/fixture.json" -Encoding utf8
$failed = & $CoopExe --root $root update fixture --json 2>&1
if ($LASTEXITCODE -eq 0 -or (& "$root/shims/fixture.exe") -ne 'fixture 1') { throw 'prepare failure lost old program' }
[IO.File]::WriteAllText("$root/buckets/test/bucket/fixture.json",$goodManifest)
foreach ($lockedPath in @("$root/shims/fixture.exe","$root/.coop/packages/fixture.json")) {
    $lock = [IO.File]::Open($lockedPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $failed = & $CoopExe --root $root update fixture --json 2>&1
        if ($LASTEXITCODE -eq 0) { throw 'occupied publication target unexpectedly changed' }
    } finally { $lock.Dispose() }
    if ((& "$root/shims/fixture.exe") -ne 'fixture 1' -or (Test-Path "$root/apps/fixture/2")) { throw 'publication failure did not restore old version' }
    $diagnosis = & $CoopExe --root $root list --json | ConvertFrom-Json
    if ($diagnosis[0].version -ne '1' -or $diagnosis[0].status -ne 'ready') { throw 'fresh process misreported failed update' }
}
$guard = Join-Path (Split-Path $CoopExe) 'process_guard.exe'
$update = & $guard $CoopExe --root $root update fixture --json
if ($LASTEXITCODE -ne 0) { throw 'update failed' }
if ((& "$root/shims/fixture.exe") -ne 'fixture 2' -or (& "$root/apps/fixture/1/fixture.exe") -ne 'fixture 1') { throw 'version switch or old version retention failed' }
$items = & $CoopExe --root $root list --json | ConvertFrom-Json
if ($items[0].version -ne '2' -or $items[0].management -ne 'managed') { throw 'updated query wrong' }
Write-Output "PASS actual program update and old version retention: $root"
exit 0

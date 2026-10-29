# Red when: `info` stops reporting the bucket commit that last touched the manifest, `-v` stops adding
# the Manifest path, or `search` stops matching a binary name declared by the manifest.
param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test data must stay within the project test directory'
}
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) { throw 'git.exe is required to build the fixture repository' }
$root = Join-Path $TestRoot 'info-git'
if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
$repo = Join-Path $root 'source'
New-Item -ItemType Directory -Path "$repo/bucket" -Force | Out-Null
function Write-Manifest([string]$Name,[string]$Alias) {
    @"
{
  "version": "1.0",
  "url": "https://example.invalid/$Name.zip",
  "hash": "0000000000000000000000000000000000000000000000000000000000000000",
  "bin": [ [ "tool.exe", "$Alias" ] ]
}
"@ | Set-Content "$repo/bucket/$Name.json" -Encoding utf8
}
Write-Manifest 'first' 'firsttool'
& git -C $repo init -q
& git -C $repo -c user.email=fixture@example.invalid -c user.name=FixtureAuthor add -A
& git -C $repo -c user.email=fixture@example.invalid -c user.name=FixtureAuthor commit -qm 'add first' | Out-Null
Write-Manifest 'second' 'secondtool'
& git -C $repo -c user.email=fixture@example.invalid -c user.name=FixtureAuthor add -A
& git -C $repo -c user.email=fixture@example.invalid -c user.name=FixtureAuthor commit -qm 'add second' | Out-Null
New-Item -ItemType Directory -Path "$root/buckets" -Force | Out-Null
Copy-Item $repo "$root/buckets/test" -Recurse -Force

# The bucket is a Git working tree, so `info` reports the commit that last touched the manifest.
$lines = @(& $CoopExe --root $root info test/first)
if ($LASTEXITCODE -cne 0) { throw "info failed: $($lines -join ' | ')" }
$text = $lines -join "`n"
if ($text -cnotmatch 'Updated by : FixtureAuthor') { throw "info did not report the commit author: $text" }
if ($text -cnotmatch 'Updated at : \d{4}/\d{1,2}/\d{1,2} \d{1,2}:\d{2}:\d{2}') { throw "info did not report the commit time: $text" }

# -v adds the manifest path.
$lines = @(& $CoopExe --root $root info test/first -v)
if ($lines -join "`n" -cnotmatch 'Manifest\s+: .*first\.json') { throw "info -v did not report the manifest path: $($lines -join ' | ')" }

# A bucket without Git has no commit, so the two lines are absent rather than invented.
$plain = Join-Path $root 'plain'
New-Item -ItemType Directory -Path "$plain/buckets/local/bucket" -Force | Out-Null
Copy-Item "$repo/bucket/first.json" "$plain/buckets/local/bucket/first.json" -Force
$lines = @(& $CoopExe --root $plain info local/first)
if ($lines -join "`n" -cmatch 'Updated at') { throw 'a non-Git bucket reported a commit time' }

# search matches binary names, the way Scoop does.
$lines = @(& $CoopExe --root $root search secondtool)
if ($LASTEXITCODE -cne 0 -or ($lines -join "`n") -cnotmatch 'second') { throw "search by binary name found '$($lines -join ' | ')'" }
$lines = @(& $CoopExe --root $root search '^sec')
if (($lines -join "`n") -cnotmatch 'second') { throw 'search does not treat the query as a regular expression' }
Write-Output 'PASS: info reports the bucket commit, -v adds the manifest path, search matches binaries'

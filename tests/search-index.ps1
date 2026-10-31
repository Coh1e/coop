# Red when: the bucket index stops recording binary names (so `search` cannot match them), a stale index
# of an older format stops being ignored, or `bucket update` stops rewriting it.
param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test data must stay within the project test directory'
}
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) { throw 'git.exe is required to build the fixture repository' }
$root = Join-Path $TestRoot 'search-index'
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
"@ | Set-Content "$repo/bucket/$Name.json" -Encoding utf8 -NoNewline
}
function Commit-Fixture([string]$Message) {
    & git -C $repo -c user.email=fixture@example.invalid -c user.name=Fixture add -A | Out-Null
    & git -C $repo -c user.email=fixture@example.invalid -c user.name=Fixture commit -qm $Message | Out-Null
}
Write-Manifest 'alpha' 'alphatool'
Write-Manifest 'bravo' 'bravotool'
& git -C $repo init -q
Commit-Fixture 'first'
$installed = Join-Path $root 'install-root'
$url = 'file:///' + ($repo -replace '\\', '/')
Invoke-CoopNative $CoopExe  --root $installed bucket add probe $url | Out-Null
if ($LASTEXITCODE -cne 0) { throw 'the fixture bucket did not register' }

# The index records the binary names, which is what makes a binary search possible.
$index = Join-Path $installed '.coop/index/probe.json'
if (-not (Test-Path $index)) { throw 'the bucket index was not written' }
$stored = Get-Content $index -Raw | ConvertFrom-Json
if ($stored.version -cne 2) { throw "the index format is $($stored.version), not 2" }
$bins = @($stored.entries | ForEach-Object { $_.bin } | ForEach-Object { $_ })
if ('alphatool' -notin $bins) { throw "the index does not record binary names: $($bins -join ', ')" }

# A search matches the alias declared by the manifest.
$lines = @(& $CoopExe --root $installed search alphatool)
if ($LASTEXITCODE -cne 0 -or ($lines -join "`n") -cnotmatch 'alpha') { throw "search did not use the index: $($lines -join ' | ')" }

# An index from an older format is ignored, and the published manifests still answer the query.
Set-Content $index -Value '{ "version": 1, "bucket": "probe", "entries": [] }' -Encoding utf8
$lines = @(& $CoopExe --root $installed search alphatool)
if (($lines -join "`n") -cnotmatch 'alpha') { throw 'a stale index hid the published manifest' }

# `bucket update` rewrites it, and the new package shows up after the source changes.
Write-Manifest 'charlie' 'charlietool'
Commit-Fixture 'second'
Invoke-CoopNative $CoopExe  --root $installed bucket update probe | Out-Null
if ($LASTEXITCODE -cne 0) { throw 'bucket update failed' }
$stored = Get-Content $index -Raw | ConvertFrom-Json
if ($stored.version -cne 2) { throw "bucket update left the index at format $($stored.version)" }
$lines = @(& $CoopExe --root $installed search charlietool)
if (($lines -join "`n") -cnotmatch 'charlie') { throw "the refreshed index missed a new package: $($lines -join ' | ')" }
Write-Output 'PASS: the catalog index records binaries, tolerates a stale format and refreshes on demand'

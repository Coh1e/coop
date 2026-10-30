# Red when: a search that misses locally stops asking the known buckets, or starts asking them when a
# local match exists.
param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test data must stay within the project test directory'
}
$root = Join-Path $TestRoot 'search-remote'
if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
New-Item -ItemType Directory -Path "$root/buckets/probe/bucket", "$root/buckets/main/bucket", "$root/api" -Force | Out-Null
@'
{ "version": "1.0", "url": "https://example.invalid/a.zip", "hash": "0000000000000000000000000000000000000000000000000000000000000000", "bin": "alpha.exe" }
'@ | Set-Content "$root/buckets/probe/bucket/alpha.json" -Encoding utf8 -NoNewline
# The known buckets are queried only for the ones that are not installed locally; `extras` is one.
'{"tree":[{"path":"bucket/wiztree.json"},{"path":"bucket/other-tool.json"},{"path":"bucket/readme.md"}]}' |
    Set-Content "$root/api/extras.json" -Encoding utf8
'{"tree":[{"path":"bucket/wiztree.json"}]}' | Set-Content "$root/api/main.json" -Encoding utf8

$previousApi = $env:COOP_GITHUB_API
try {
    $env:COOP_GITHUB_API = 'file:///' + (($root -replace '\\','/') + '/api')

    # A local match prints the local table only.
    $local = (& $CoopExe --root $root search alpha) -join "`n"
    if ($local -cnotmatch 'alpha' -or $local -cmatch 'other known buckets') {
        throw "a local match consulted the remotes: $local"
    }

    # A miss asks the known buckets and prints the row Scoop prints.
    $remote = (& $CoopExe --root $root search wiztree) -join "`n"
    if ($remote -cnotmatch 'Results from other known buckets\.\.\.') { throw "no remote section: $remote" }
    if ($remote -cnotmatch "(?m)^wiztree\s+extras") { throw "the remote row is missing: $remote" }
    if ($remote -cmatch '(?m)^wiztree\s+main') { throw "an installed bucket was queried as well: $remote" }
    if ($remote -cmatch 'No matches found') { throw "a remote hit still warned: $remote" }

    # Nothing anywhere still warns.
    $none = (& $CoopExe --root $root search zzznomatch) -join "`n"
    if ($none -cnotmatch 'WARN  No matches found') { throw "the miss message changed: $none" }
} finally {
    if ($null -eq $previousApi) { Remove-Item Env:\COOP_GITHUB_API -ErrorAction SilentlyContinue }
    else { $env:COOP_GITHUB_API = $previousApi }
}
Write-Output 'PASS: a local miss falls back to the known buckets, a local hit does not'

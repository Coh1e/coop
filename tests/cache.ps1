# Red when: `download` writes install state, stops naming cached artifacts `<app>#<version>#<sha7><ext>`,
# `-f` stops re-downloading, a digest mismatch stops failing and leaves the file behind, `cache show`
# stops printing the Name/Version/Length table with its total, or `cache rm` stops requiring a target
# and reporting what it deleted.
param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test data must stay within the project test directory'
}
$archive = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives/ripgrep-15.2.0-x86_64-pc-windows-msvc.zip'))
if (-not (Test-Path -LiteralPath $archive)) { throw "Missing test archive: $archive" }
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower()
$url = 'file:///' + ($archive -replace '\\', '/')
$root = Join-Path $TestRoot 'cache'
if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
New-Item -ItemType Directory -Path "$root/buckets/probe/bucket" -Force | Out-Null
function Write-Manifest([string]$Hash) {
    @"
{
  "version": "1.0",
  "url": "$url",
  "hash": "$Hash",
  "extract_dir": "ripgrep-15.2.0-x86_64-pc-windows-msvc",
  "bin": "rg.exe"
}
"@ | Set-Content "$root/buckets/probe/bucket/probe.json" -Encoding utf8 -NoNewline
}
Write-Manifest $hash

# A cold download fills the cache and never installs anything.
$out = @(& $CoopExe --root $root download probe/probe)
if ($LASTEXITCODE -cne 0) { throw "download failed: $($out -join ' | ')" }
$cached = Get-ChildItem "$root/cache" -File
if (@($cached).Count -cne 1 -or $cached[0].Name -cnotmatch '^probe#1\.0#[0-9a-f]{7}\.zip$') {
    throw "cache holds '$(@($cached | ForEach-Object Name) -join ', ')'"
}
$installed = @(& $CoopExe --root $root list)
if (($installed -join "`n") -cnotmatch "There aren't any apps installed") { throw 'download created installation state' }

# The second run reports a cache hit; `-f` goes back to the network.
$out = @(& $CoopExe --root $root download probe/probe)
if (($out -join "`n") -cnotmatch 'Loading ripgrep-15\.2\.0-x86_64-pc-windows-msvc\.zip from cache') {
    throw "a cached download said '$($out -join ' | ')'"
}
$out = @(& $CoopExe --root $root download probe/probe -f)
if (($out -join "`n") -cnotmatch 'Downloading file://') { throw "forced download said '$($out -join ' | ')'" }

# cache show prints Scoop's table and total; cache rm requires a target.
$out = @(& $CoopExe --root $root cache show)
if ($out[0] -cnotmatch '^Name\s+Version\s+Length\s*$') { throw "cache show header is '$($out[0])'" }
if (($out -join "`n") -cnotmatch 'probe\s+1\.0\s+\d+') { throw "cache show rows are '$($out -join ' | ')'" }
if (($out -join "`n") -cnotmatch 'Total: 1 file, ') { throw "cache show total is '$($out -join ' | ')'" }
$out = @(& $CoopExe --root $root cache show nosuchapp)
if (($out -join "`n") -cnotmatch 'Total: 0 files, 0 B') { throw "cache show for an absent app said '$($out -join ' | ')'" }
Invoke-CoopNative $CoopExe  --root $root cache rm | Out-Null
if ($LASTEXITCODE -cne 1) { throw "cache rm without a target exited $LASTEXITCODE" }

# A wrong digest fails and leaves nothing behind in the cache.
Write-Manifest ('0' * 64)
$out = Invoke-CoopNative $CoopExe  --root $root download probe/probe -f
if ($LASTEXITCODE -cne 1 -or ($out -join "`n") -cnotmatch 'digest mismatch') { throw "a wrong digest said '$($out -join ' | ')'" }
if (@(Get-ChildItem "$root/cache" -File).Count -cne 0) { throw 'a failed verify left an extra cache file' }
Write-Manifest $hash
$out = @(& $CoopExe --root $root download probe/probe)
if ($LASTEXITCODE -cne 0) { throw "restoring the cache failed: $($out -join ' | ')" }

$out = @(& $CoopExe --root $root cache rm probe)
if ($LASTEXITCODE -cne 0) { throw "cache rm failed: $($out -join ' | ')" }
if (($out -join "`n") -cnotmatch 'Removing probe#1\.0#[0-9a-f]{7}\.zip\.\.\.') { throw "cache rm said '$($out -join ' | ')'" }
if (($out -join "`n") -cnotmatch 'Deleted: 1 file, ') { throw "cache rm summary is '$($out -join ' | ')'" }
if (@(Get-ChildItem "$root/cache" -File).Count -cne 0) { throw 'cache rm left a file behind' }
Write-Output 'PASS: download cold/hit/force, digest failure, cache show and cache rm'

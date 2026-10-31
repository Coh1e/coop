# Red when: `-s` stops downgrading a digest mismatch to a warning, `-k` stops bypassing the download
# cache, `-i` stops leaving declared dependencies out of the plan, or `-f` stops replacing the installed
# version in place.
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
$root = Join-Path $TestRoot 'switches'
if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
New-Item -ItemType Directory -Path "$root/buckets/probe/bucket" -Force | Out-Null
function Write-Manifest([string]$Name,[string]$Hash,[string]$Alias,[string]$Depends) {
    $dependsLine = if ($Depends) { "  `"depends`": `"$Depends`"," } else { '' }
    @"
{
  "version": "1.0",
  $dependsLine
  "url": "$url",
  "hash": "$Hash",
  "extract_dir": "ripgrep-15.2.0-x86_64-pc-windows-msvc",
  "bin": [ [ "rg.exe", "$Alias" ] ]
}
"@ | Set-Content "$root/buckets/probe/bucket/$Name.json" -Encoding utf8 -NoNewline
}
Write-Manifest 'plain' $hash 'rgplain' ''
Write-Manifest 'badtool' ('0' * 64) 'rgbad' ''
Write-Manifest 'dep' $hash 'rgdep' 'leaf'
Write-Manifest 'leaf' $hash 'rgleaf' ''
Write-Manifest 'vers' $hash 'rgvers' ''

# -s: a digest mismatch fails, and the switch turns the failure into a warning.
$refusal = Invoke-CoopNative $CoopExe  --root $root install probe/badtool
if ($LASTEXITCODE -cne 1 -or ($refusal -join "`n") -cnotmatch 'sha256 mismatch') { throw "a bad digest said '$($refusal -join ' | ')'" }
$out = Invoke-CoopNative $CoopExe  --root $root install probe/badtool -s
if ($LASTEXITCODE -cne 0) { throw "install -s failed: $($out -join ' | ')" }
if (($out -join "`n") -cnotmatch 'WARN  Hash check skipped') { throw "install -s said '$($out -join ' | ')'" }
& $CoopExe --root $root uninstall badtool | Out-Null

# -k: the second install hits the cache; the switch goes back to the network.
& $CoopExe --root $root install probe/plain | Out-Null
& $CoopExe --root $root uninstall plain | Out-Null
$cached = Invoke-CoopNative $CoopExe  --root $root install probe/plain
if (($cached -join "`n") -cnotmatch 'Loading .* from cache') { throw "a cached install said '$($cached -join ' | ')'" }
& $CoopExe --root $root uninstall plain | Out-Null
$fresh = Invoke-CoopNative $CoopExe  --root $root install probe/plain -k
if (($fresh -join "`n") -cnotmatch 'Downloading file://') { throw "install -k said '$($fresh -join ' | ')'" }
if (($fresh -join "`n") -cmatch 'from cache') { throw 'install -k still used the cache' }

# -i: a declared dependency is installed by default and left out with the switch.
& $CoopExe --root $root install probe/dep | Out-Null
$withDep = @(& $CoopExe --root $root list)
if (($withDep -join "`n") -cnotmatch 'leaf\s+1\.0') { throw "the declared dependency was not installed: $($withDep -join ' | ')" }
& $CoopExe --root $root uninstall dep | Out-Null
& $CoopExe --root $root uninstall leaf | Out-Null
& $CoopExe --root $root install probe/dep -i | Out-Null
$withoutDep = @(& $CoopExe --root $root list)
if (($withoutDep -join "`n") -cmatch 'leaf\s+1\.0') { throw 'install -i installed the declared dependency anyway' }
if (($withoutDep -join "`n") -cnotmatch 'dep\s+1\.0') { throw 'install -i did not install the package itself' }

# -f: an unchanged update is a no-op; forcing it is refused instead of silently reported as current.
& $CoopExe --root $root install probe/vers | Out-Null
$plainUpdate = Invoke-CoopNative $CoopExe  --root $root update probe/vers
if ($LASTEXITCODE -cne 0 -or ($plainUpdate -join "`n") -cnotmatch 'up-to-date') { throw "an unchanged update said '$($plainUpdate -join ' | ')'" }
# Forcing replaces the installed version in place: the old directory is moved into the transaction,
# then the same version is published again.
$forced = Invoke-CoopNative $CoopExe  --root $root update probe/vers -f
if ($LASTEXITCODE -cne 0) { throw "update -f failed: $($forced -join ' | ')" }
if (($forced -join "`n") -cnotmatch "Uninstalling 'vers' \(1\.0\)") { throw "update -f did not replace the version: $($forced -join ' | ')" }
if (($forced -join "`n") -cnotmatch "was installed successfully") { throw "update -f did not republish the package: $($forced -join ' | ')" }
$afterForce = @(& $CoopExe --root $root list)
if (($afterForce -join "`n") -cnotmatch 'vers\s+1\.0') { throw 'the package disappeared after a forced reinstall' }
$recovery = @(& $CoopExe --root $root recover)
if (($recovery -join "`n") -cnotmatch 'No pending transactions') { throw "a forced reinstall left a pending transaction: $($recovery -join ' | ')" }
Write-Output 'PASS: -s, -k, -i and -f behave end to end'

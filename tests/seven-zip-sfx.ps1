# Red when: a 7z self-extracting archive stops being routed to the 7-Zip helper. The fixture's
# LZMA stream uses lc=8, the property git-for-windows PortableGit uses; liblzma rejects lc+lp>4 with
# "Lzma library error: Invalid options", while 7-Zip reads lc 0-8, so dropping the route makes the
# install fail. Also red when the no-helper fallback stops trying the native reader and reporting
# its error instead of publishing silently.
param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test data must stay within the project test directory'
}
$msi = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives/7z2605-x64.msi'))
if (-not (Test-Path -LiteralPath $msi)) { throw "Missing test archive: $msi; run scripts/fetch-deps.ps1" }

$root = Join-Path $TestRoot 'seven-zip-sfx'
if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
New-Item -ItemType Directory -Path "$root/buckets/probe/bucket" -Force | Out-Null

# The helper is the 7-Zip package Coop installs into the root from the MSI, exactly like a shared root.
$msiUrl = 'file:///' + (($msi -replace '\\','/') -replace '^([A-Za-z]):','$1:')
@"
{
  "version": "26.05",
  "url": "$msiUrl",
  "hash": "$((Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash.ToLower())",
  "architecture": { "64bit": { "extract_dir": "Files\\7-Zip" } },
  "bin": [ "7z.exe" ]
}
"@ | Set-Content "$root/buckets/probe/bucket/7zip.json" -Encoding utf8 -NoNewline
Invoke-CoopNative $CoopExe  --root $root install probe/7zip | Out-Null
if ($LASTEXITCODE -cne 0) { throw 'the 7-Zip helper package did not install' }
$helper = Join-Path $root 'apps/7zip/current/7z.exe'
if (-not (Test-Path -LiteralPath $helper)) { throw 'the helper is missing after installation' }

# Build a 7z self-extracting archive with an LZMA stream libarchive cannot read: lc=8 is legal for
# 7-Zip (and is what git-for-windows uses for PortableGit) but liblzma rejects lc+lp>4. Without the
# helper route the native reader fails with "Lzma library error: Invalid options", so a plain small
# SFX would not prove the route.
$payload = Join-Path $root 'sfx-payload'
New-Item -ItemType Directory -Path $payload -Force | Out-Null
Set-Content (Join-Path $payload 'hello.txt') -Value 'sfx-ok' -Encoding utf8 -NoNewline
$sfx = Join-Path $root 'tool-sfx.exe'
Invoke-CoopNative $helper  a -sfx -t7z -m0=lzma -mlc=8 -md=1m $sfx (Join-Path $payload 'hello.txt') | Out-Null
if ($LASTEXITCODE -cne 0 -or -not (Test-Path -LiteralPath $sfx)) { throw 'the sfx fixture could not be built' }

$sfxUrl = 'file:///' + (($sfx -replace '\\','/') -replace '^([A-Za-z]):','$1:') + '#/tool.7z'
function Write-ToolManifest([string]$root) {
    @"
{
  "version": "1.0",
  "url": "$sfxUrl",
  "hash": "$((Get-FileHash -LiteralPath $sfx -Algorithm SHA256).Hash.ToLower())"
}
"@ | Set-Content "$root/buckets/probe/bucket/tool.json" -Encoding utf8 -NoNewline
}
Write-ToolManifest $root
$install = Invoke-CoopNative $CoopExe  --root $root install probe/tool
if ($LASTEXITCODE -cne 0) { throw "installing the 7z SFX failed: $($install -join ' | ')" }
$extracted = Join-Path $root 'apps/tool/current/hello.txt'
if (-not (Test-Path -LiteralPath $extracted)) { throw 'the SFX payload was not extracted' }
if ((Get-Content -LiteralPath $extracted -Raw) -cne 'sfx-ok') { throw 'the extracted content is wrong' }

# The success above must come from the helper, not from a native read that happens to work on this
# stream. The journal records the mechanism, the helper, the content signature offset and the exit code.
$journals = @(Get-ChildItem "$root/.coop/transactions" -Recurse -Filter journal.json -ErrorAction SilentlyContinue |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } |
    Where-Object { $_.package -eq 'tool' -and $_.action -eq 'install' })
if ($journals.Count -ne 1) { throw "expected one committed install journal for tool, found $($journals.Count)" }
$record = @($journals[0].seven_zip_sfx_extractions)
if ($record.Count -ne 1) { throw 'the install journal does not record the 7z SFX helper extraction' }
if ($record[0].exit_code -ne 0 -or $record[0].installer_executed -ne $false) { throw 'the 7z SFX helper record is inaccurate' }
if ($record[0].detection.signature -notmatch '7z signature' -or $record[0].detection.offset -le 0) { throw 'the journal does not record the content detection that selected the helper' }
if ($record[0].helper -ne $helper -or @($record[0].arguments) -notcontains 'x' -or @($record[0].arguments) -notcontains '-y') { throw 'the journal does not record the helper and Expand-7zipArchive arguments' }
if ($record[0].files -ne 1) { throw "the journal records $($record[0].files) extracted files, expected 1" }

# A root without the helper must fall back to the native reader. This is the same SFX, so the
# fallback has to fail with the native error and publish nothing; it must not claim success.
$bare = Join-Path $TestRoot 'seven-zip-sfx-no-helper'
if (Test-Path $bare) { Remove-Item -LiteralPath $bare -Recurse -Force }
New-Item -ItemType Directory -Path "$bare/buckets/probe/bucket" -Force | Out-Null
Write-ToolManifest $bare
$fallback = Invoke-CoopNative $CoopExe  --root $bare install probe/tool
if ($LASTEXITCODE -eq 0) { throw 'the SFX installed without a helper instead of falling back and failing' }
$fallbackText = $fallback -join "`n"
if ($fallbackText -notmatch 'Archive entry cannot be read' -or $fallbackText -notmatch 'Lzma library error: Invalid options') {
    throw "the no-helper fallback did not report the native reader error: $fallbackText"
}
if ((Test-Path -LiteralPath "$bare/apps/tool") -or (Test-Path -LiteralPath "$bare/.coop/packages/tool.json")) {
    throw 'the failed no-helper install published package state'
}

Write-Output 'PASS: a 7z SFX whose LZMA stream the native reader rejects is unpacked through the 7-Zip helper, and the no-helper fallback reports the native error'

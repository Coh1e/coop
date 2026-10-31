# Red when: a 7z self-extracting archive stops being routed to the 7-Zip helper and falls back to the
# native reader, which rejects this container.
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

# Build a small 7z self-extracting archive with that helper.
$payload = Join-Path $root 'sfx-payload'
New-Item -ItemType Directory -Path $payload -Force | Out-Null
Set-Content (Join-Path $payload 'hello.txt') -Value 'sfx-ok' -Encoding utf8 -NoNewline
$sfx = Join-Path $root 'tool-sfx.exe'
Invoke-CoopNative $helper  a -sfx -mx=1 $sfx (Join-Path $payload 'hello.txt') | Out-Null
if ($LASTEXITCODE -cne 0 -or -not (Test-Path -LiteralPath $sfx)) { throw 'the sfx fixture could not be built' }

$sfxUrl = 'file:///' + (($sfx -replace '\\','/') -replace '^([A-Za-z]):','$1:') + '#/tool.7z'
@"
{
  "version": "1.0",
  "url": "$sfxUrl",
  "hash": "$((Get-FileHash -LiteralPath $sfx -Algorithm SHA256).Hash.ToLower())"
}
"@ | Set-Content "$root/buckets/probe/bucket/tool.json" -Encoding utf8 -NoNewline
$install = Invoke-CoopNative $CoopExe  --root $root install probe/tool
if ($LASTEXITCODE -cne 0) { throw "installing the 7z SFX failed: $($install -join ' | ')" }
$extracted = Join-Path $root 'apps/tool/current/hello.txt'
if (-not (Test-Path -LiteralPath $extracted)) { throw 'the SFX payload was not extracted' }
if ((Get-Content -LiteralPath $extracted -Raw) -cne 'sfx-ok') { throw 'the extracted content is wrong' }
Write-Output 'PASS: a 7z self-extracting archive is unpacked through the 7-Zip helper'

# Red when: a bucket whose working tree only differs by CRLF line endings stops refreshing, or a real
# local edit starts being discarded instead of stopping the refresh.
param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test data must stay within the project test directory'
}
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) { throw 'git.exe is required to build the fixture repository' }
$root = Join-Path $TestRoot 'bucket-crlf'
if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
$repo = Join-Path $root 'source'
New-Item -ItemType Directory -Path "$repo/bucket" -Force | Out-Null
@'
{
  "version": "1.0",
  "url": "https://example.invalid/x.zip",
  "hash": "0000000000000000000000000000000000000000000000000000000000000000",
  "bin": "x.exe"
}
'@ | Set-Content "$repo/bucket/x.json" -Encoding utf8 -NoNewline
& git -C $repo init -q
& git -C $repo -c user.email=fixture@example.invalid -c user.name=Fixture add -A | Out-Null
& git -C $repo -c user.email=fixture@example.invalid -c user.name=Fixture commit -qm 'first' | Out-Null
$installed = Join-Path $root 'install-root'
Invoke-CoopNative $CoopExe  --root $installed bucket add probe ('file:///' + ($repo -replace '\\','/')) | Out-Null
if ($LASTEXITCODE -cne 0) { throw 'the fixture bucket did not register' }
$clone = Join-Path $installed 'buckets/probe'

# Get the clone to see a new upstream commit once, so a later refresh has something to do.
@'
{
  "version": "2.0",
  "url": "https://example.invalid/y.zip",
  "hash": "0000000000000000000000000000000000000000000000000000000000000000",
  "bin": "y.exe"
}
'@ | Set-Content "$repo/bucket/y.json" -Encoding utf8 -NoNewline
& git -C $repo -c user.email=fixture@example.invalid -c user.name=Fixture add -A | Out-Null
& git -C $repo -c user.email=fixture@example.invalid -c user.name=Fixture commit -qm 'second' | Out-Null

# `core.autocrlf=true` leaves CRLF in the working tree and LF in the index; Git calls that clean.
# The setting has to exist before the files are materialised, so the clone is reconfigured and
# checked out again.
& git -C $clone config core.autocrlf true
Remove-Item (Join-Path $clone 'bucket/*.json') -Force
& git -C $clone checkout -- . | Out-Null
$target = Join-Path $clone 'bucket/x.json'
$bytes = [IO.File]::ReadAllBytes($target)
if (@($bytes | Where-Object { $_ -eq 13 }).Count -eq 0) { throw 'the fixture did not materialise CRLF' }
if ((Invoke-CoopNative git -C $clone status --porcelain) -join '' -ne '') { throw 'the fixture is not clean for Git' }
$refresh = Invoke-CoopNative $CoopExe  --root $installed bucket update probe
if ($LASTEXITCODE -cne 0) { throw "a CRLF-only difference stopped the refresh: $($refresh -join ' | ')" }
$index = Join-Path $installed '.coop/cache/index/probe.json'
if (-not (Test-Path $index)) { throw 'the refresh did not rebuild the index' }
if ((Get-Content $index -Raw | ConvertFrom-Json).entries.Count -cne 2) { throw 'the refresh did not pick up the new package' }

# A real edit is still preserved: the refresh must stop and say which file.
Set-Content $target -Value '{ "version": "9.9" }' -Encoding utf8 -NoNewline
$blocked = Invoke-CoopNative $CoopExe  --root $installed bucket update probe
if ($LASTEXITCODE -ceq 0) { throw 'a local edit did not stop the refresh' }
if (($blocked -join "`n") -cnotmatch 'must be preserved.*bucket[/\\]x\.json') { throw "the refusal did not name the file: $($blocked -join ' | ')" }
if ((Get-Content $target -Raw) -cnotmatch '9\.9') { throw 'the local edit was overwritten' }
Write-Output 'PASS: a CRLF-only worktree refreshes, a real local edit stops the refresh'

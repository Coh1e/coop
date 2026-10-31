# Red when: publishing a replacement stops waiting for a short-lived file lock, so a forced reinstall
# fails while an antivirus-style handle is still open on the tree being replaced.
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
$root = Join-Path $TestRoot 'publish-lock'
if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
New-Item -ItemType Directory -Path "$root/buckets/probe/bucket" -Force | Out-Null
@"
{
  "version": "1.0",
  "url": "$url",
  "hash": "$hash",
  "extract_dir": "ripgrep-15.2.0-x86_64-pc-windows-msvc",
  "bin": [ [ "rg.exe", "rglock" ] ]
}
"@ | Set-Content "$root/buckets/probe/bucket/held.json" -Encoding utf8 -NoNewline
& $CoopExe --root $root install probe/held | Out-Null
if ($LASTEXITCODE -cne 0) { throw 'the fixture package did not install' }

# Hold a file inside the installed version for six seconds: longer than the old three-second window,
# shorter than the new one. An antivirus scanner looks exactly like this to the publisher.
$victim = Join-Path $root 'apps/held/1.0/rg.exe'
$holder = Start-Job -ScriptBlock {
    param($path)
    $stream = [IO.File]::Open($path,'Open','Read','Read')
    Start-Sleep -Seconds 6
    $stream.Dispose()
} -ArgumentList $victim
Start-Sleep -Milliseconds 700

$install = Invoke-CoopNative $CoopExe  --root $root update held -f
$code = $LASTEXITCODE
Wait-Job $holder -Timeout 30 | Out-Null
Remove-Job $holder -Force
if ($code -cne 0) { throw "a forced reinstall failed while a file was briefly held: $($install -join ' | ')" }
if (($install -join "`n") -cnotmatch 'was installed successfully') { throw "the reinstall did not report success: $($install -join ' | ')" }
if (-not (Test-Path -LiteralPath (Join-Path $root 'apps/held/current/rg.exe'))) { throw 'the replacement was not published' }
Write-Output 'PASS: publishing waits out a short-lived lock instead of failing'

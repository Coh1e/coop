# Red when: a preview in text mode starts printing the JSON plan again, a batch preview stops printing
# one line per package, or `--json` stops carrying the structured plan.
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
$root = Join-Path $TestRoot 'preview-text'
if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
New-Item -ItemType Directory -Path "$root/buckets/probe/bucket" -Force | Out-Null
foreach ($name in 'alpha','bravo') {
    @"
{
  "version": "1.0",
  "url": "$url",
  "hash": "$hash",
  "extract_dir": "ripgrep-15.2.0-x86_64-pc-windows-msvc",
  "bin": [ [ "rg.exe", "rg$name" ] ]
}
"@ | Set-Content "$root/buckets/probe/bucket/$name.json" -Encoding utf8 -NoNewline
}
foreach ($name in 'alpha','bravo') {
    & $CoopExe --root $root install "probe/$name" | Out-Null
    if ($LASTEXITCODE -cne 0) { throw "the fixture package $name did not install" }
}

# A single preview is one readable line plus its diagnostics, never the JSON plan.
$text = (Invoke-CoopNative $CoopExe  --root $root update probe/alpha --dry-run) -join "`n"
if ($LASTEXITCODE -cne 0) { throw "the preview failed: $text" }
if ($text -cmatch '\{') { throw "the text preview printed JSON: $text" }
if ($text -cnotmatch '(?m)^alpha: update 1\.0 \(installed 1\.0\)\s+executable') {
    throw "the preview line is missing: $text"
}

# A batch preview prints one line per package instead of staying silent.
$batch = (Invoke-CoopNative $CoopExe  --root $root update '*' --dry-run) -join "`n"
if ($LASTEXITCODE -cne 0) { throw "the batch preview failed: $batch" }
foreach ($name in 'alpha','bravo') {
    if ($batch -cnotmatch "(?m)^$name`: update 1\.0") { throw "the batch preview skipped ${name}: $batch" }
}
if ($batch -cmatch '\{') { throw "the batch preview printed JSON: $batch" }

# `--json` still carries the plan.
$plan = (& $CoopExe --root $root update probe/alpha --dry-run --json | Out-String | ConvertFrom-Json)
if ($plan.package.name -cne 'alpha' -or $plan.action -cne 'update') { throw 'the json preview lost the plan' }
Write-Output 'PASS: previews are human-readable in text mode and structured with --json'

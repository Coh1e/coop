param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test data must stay within the project test directory'
}
$TestRoot = Join-Path $TestRoot 'core'
New-Item -ItemType Directory -Path "$TestRoot/buckets/main/bucket", "$TestRoot/apps/jq/1.8.2" -Force | Out-Null
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$TestRoot/buckets/main/bucket/jq.json" -Force
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$TestRoot/apps/jq/1.8.2/scoop-manifest.json" -Force
'{"bucket":"main","architecture":"64bit"}' | Set-Content "$TestRoot/apps/jq/1.8.2/scoop-install.json" -Encoding utf8
if (-not (Test-Path "$TestRoot/apps/jq/current")) {
    New-Item -ItemType Junction -Path "$TestRoot/apps/jq/current" -Target "$TestRoot/apps/jq/1.8.2" | Out-Null
}
$text = & $CoopExe --root $TestRoot list --json
if ($LASTEXITCODE -ne 0) { throw 'list failed' }
$items = ($text -join "`n") | ConvertFrom-Json
if ($items.Count -ne 1 -or $items[0].name -ne 'jq' -or $items[0].version -ne '1.8.2' -or $items[0].management -ne 'unadopted') {
    throw "Unexpected installed package result: $text"
}
$text = & $CoopExe --root $TestRoot search jq --json
if ($LASTEXITCODE -ne 0) { throw 'search failed' }
$items = ($text -join "`n") | ConvertFrom-Json
if ($items.Count -ne 1 -or $items[0].name -ne 'jq' -or $items[0].bucket -ne 'main' -or $items[0].version -ne '1.8.2') {
    throw "Unexpected search result: $text"
}
$text = & $CoopExe --root $TestRoot info main/jq --json
if ($LASTEXITCODE -ne 0 -or (($text -join "`n") | ConvertFrom-Json)[0].version -ne '1.8.2') { throw 'qualified info failed' }

$edge = Join-Path (Split-Path $TestRoot) 'edge'
New-Item -ItemType Directory -Path "$edge/buckets/main/bucket", "$edge/buckets/other/bucket", "$edge/apps/legacy/current", "$edge/apps/broken/current" -Force | Out-Null
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$edge/buckets/main/bucket/jq.json" -Force
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$edge/buckets/other/bucket/jq.json" -Force
'not JSON' | Set-Content "$edge/buckets/main/bucket/broken.json" -Encoding utf8
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$edge/apps/legacy/current/manifest.json" -Force
if (Test-Path -LiteralPath "$edge/apps/legacy/current/scoop-manifest.json") {
    Remove-Item -LiteralPath "$edge/apps/legacy/current/scoop-manifest.json"
}
'{"bucket":"main","architecture":"64bit"}' | Set-Content "$edge/apps/legacy/current/install.json" -Encoding utf8
'{"version":"0.0.0"}' | Set-Content "$TestRoot/apps/jq/current/manifest.json" -Encoding utf8
$items = (& $CoopExe --root $TestRoot list --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $items[0].version -ne '1.8.2') { throw 'new record did not take precedence' }
$items = (& $CoopExe --root $edge list --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or ($items | Where-Object name -eq legacy).version -ne '1.8.2') { throw 'legacy fallback failed' }
if (-not ($items | Where-Object name -eq broken).diagnostics.Count) { throw 'invalid installation was hidden' }
'not JSON' | Set-Content "$edge/apps/legacy/current/scoop-manifest.json" -Encoding utf8
$items = (& $CoopExe --root $edge list --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not ($items | Where-Object name -eq legacy).diagnostics.Count) { throw 'invalid new record incorrectly fell back' }
$items = (& $CoopExe --root $edge search broken --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $items.Count -ne 1 -or -not $items[0].diagnostics.Count) { throw 'invalid manifest was hidden' }
& $CoopExe --root $edge info jq --json 2> "$edge/ambiguous-error.txt" | Out-Null
if ($LASTEXITCODE -eq 0) { throw 'ambiguous name was silently resolved' }
& $CoopExe --root $edge info missing --json 2> "$edge/missing-error.txt" | Out-Null
if ($LASTEXITCODE -eq 0) { throw 'missing info succeeded' }

$corpusRoot = Join-Path (Split-Path $TestRoot) 'corpus'
foreach ($bucket in 'main','extras') {
    New-Item -ItemType Directory -Path "$corpusRoot/buckets/$bucket/bucket" -Force | Out-Null
    Copy-Item "$PSScriptRoot/corpus/$bucket/*.json" "$corpusRoot/buckets/$bucket/bucket" -Force
}
$items = (& $CoopExe --root $corpusRoot search / --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $items.Count -ne 20 -or @($items | Where-Object { $_.diagnostics.Count }).Count) { throw 'real corpus query failed' }
$snapshot = @(Get-ChildItem -LiteralPath $corpusRoot -Recurse -File | ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash })
& $CoopExe --root $corpusRoot info main/git --json | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'scripted package disappeared from query' }
$after = @(Get-ChildItem -LiteralPath $corpusRoot -Recurse -File | ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash })
if (@(Compare-Object $snapshot $after).Count) { throw 'query modified source data' }
$system = Join-Path (Split-Path $TestRoot) 'system'
New-Item -ItemType Directory -Path "$system/apps/system-jq/current" -Force | Out-Null
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$system/apps/system-jq/current/scoop-manifest.json" -Force
'{"bucket":"main","architecture":"64bit"}' | Set-Content "$system/apps/system-jq/current/scoop-install.json" -Encoding utf8
$items = (& $CoopExe --root $TestRoot --global-root $system list --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or ($items | Where-Object name -eq system-jq).scope -ne 'global') { throw 'global read-only installation missing' }
Write-Output 'PASS: new/legacy state, invalid records, 20 real manifests, qualified lookup, no data changes'
$human = (& $CoopExe --root $TestRoot list) -join "`n"
if ($LASTEXITCODE -ne 0 -or $human -notmatch 'Source' -or $human -notmatch 'Synced' -or $human -notmatch 'main' -or $human -notmatch 'unknown') { throw 'default output omits provenance or sync status' }

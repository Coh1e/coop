# Red when: the default (non---json) output of `list`, `search` or `info` changes shape — the header
# lines, the column widths, the aligned info block, `list`'s query filter, or the empty-state warnings.
param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test data must stay within the project test directory'
}
$root = Join-Path $TestRoot 'text'
if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
New-Item -ItemType Directory -Path "$root/buckets/main/bucket", "$root/apps/jq/1.8.2" -Force | Out-Null
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$root/buckets/main/bucket/jq.json" -Force
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$root/apps/jq/1.8.2/scoop-manifest.json" -Force
'{"bucket":"main","architecture":"64bit"}' | Set-Content "$root/apps/jq/1.8.2/scoop-install.json" -Encoding utf8
New-Item -ItemType Junction -Path "$root/apps/jq/current" -Target "$root/apps/jq/1.8.2" | Out-Null

# list: `Installed apps:`, one blank line, then a table whose every line shares one width.
$lines = @(& $CoopExe --root $root list)
if ($LASTEXITCODE -ne 0) { throw 'list failed' }
if ($lines.Count -ne 5) { throw "list printed $($lines.Count) lines: $($lines -join ' | ')" }
if ($lines[0] -ne 'Installed apps:') { throw "list header is '$($lines[0])'" }
if ($lines[1] -ne '') { throw 'list header is not followed by a blank line' }
if ($lines[2] -notmatch '^Name\s+Version\s+Source\s+Updated\s+Info$') { throw "list columns are '$($lines[2])'" }
if ($lines[3] -notmatch '^----\s+-------\s+------\s+-------\s+----$') { throw "list rule is '$($lines[3])'" }
if ($lines[4] -notmatch '^jq\s+1\.8\.2\s+main\s+\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\s+$') {
    throw "list row is '$($lines[4])'"
}
foreach ($line in $lines) {
    if ($line -match 'Management|Synced|Last operation') { throw 'list still prints the internal provenance columns' }
}
foreach ($line in $lines[2..4]) {
    if ($line.Length -ne $lines[2].Length) { throw "list line '$line' breaks the shared column width" }
}

# list [query] filters installed apps; a query with no match keeps the header and prints no rows.
$lines = @(& $CoopExe --root $root list jq)
if ($LASTEXITCODE -ne 0 -or $lines[0] -ne "Installed apps matching 'jq':") { throw "list query header is '$($lines[0])'" }
if ($lines.Count -ne 5) { throw 'list query dropped or added rows' }
$lines = @(& $CoopExe --root $root list zzznomatch)
if ($LASTEXITCODE -ne 0 -or $lines[0] -ne "Installed apps matching 'zzznomatch':") { throw "list query header is '$($lines[0])'" }
if ($lines.Count -ne 4) { throw "a non-matching query printed $($lines.Count) lines" }

# info: the aligned key/value block Scoop prints, in its order.
$lines = @(& $CoopExe --root $root info main/jq)
if ($LASTEXITCODE -ne 0) { throw 'info failed' }
$expected = @(
    'Name        : jq'
    'Description : Lightweight and flexible command-line JSON processor'
    'Version     : 1.8.2'
    'Source      : main'
    'Website     : https://jqlang.github.io/jq'
    'License     : MIT'
    'Installed   : 1.8.2'
    'Binaries    : jq.exe'
    'Suggestions : jid'
)
if (($lines -join "`n") -ne ($expected -join "`n")) {
    throw "info block is:`n$($lines -join "`n")"
}

# search: header, blank line, then Name/Version/Source/Binaries; no match means the warning alone.
$lines = @(& $CoopExe --root $root search jq)
if ($LASTEXITCODE -ne 0) { throw 'search failed' }
if ($lines.Count -ne 5) { throw "search printed $($lines.Count) lines: $($lines -join ' | ')" }
if ($lines[0] -ne 'Results from local buckets...') { throw "search header is '$($lines[0])'" }
if ($lines[1] -ne '') { throw 'search header is not followed by a blank line' }
if ($lines[2] -notmatch '^Name\s+Version\s+Source\s+Binaries\s*$') { throw "search columns are '$($lines[2])'" }
if ($lines[3] -notmatch '^----\s+-------\s+------\s+--------\s*$') { throw "search rule is '$($lines[3])'" }
if ($lines[4] -notmatch '^jq\s+1\.8\.2\s+main\s+jq\.exe\s*$') { throw "search row is '$($lines[4])'" }
$lines = @(& $CoopExe --root $root search zzznomatch)
if ($LASTEXITCODE -ne 0 -or ($lines -join '|') -ne 'WARN  No matches found.') {
    throw "empty search is '$($lines -join ' | ')'"
}

# An empty root warns instead of printing an empty table.
$empty = Join-Path $TestRoot 'empty'
New-Item -ItemType Directory -Path $empty -Force | Out-Null
$lines = @(& $CoopExe --root $empty list)
if ($LASTEXITCODE -ne 0 -or ($lines -join '|') -ne "WARN  There aren't any apps installed.") {
    throw "empty list is '$($lines -join ' | ')'"
}
if (Test-Path (Join-Path $empty '.coop')) { throw 'a read-only query created Coop state' }
Write-Output 'PASS: Scoop-shaped list, list query, info block, search and empty states'

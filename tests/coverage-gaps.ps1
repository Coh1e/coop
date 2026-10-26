$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$baselinePath = Join-Path $PSScriptRoot 'coverage/baseline.json'
$ledgerPath = Join-Path $PSScriptRoot 'coverage/gaps.json'

# R21/#42 closes the inventory loop: every blocked package from the full Main/Extras inventory has
# one explicit disposition. The ledger is checked structurally here so a later inventory cannot drop
# a gap, shrink scope or reroute a mechanism without an obvious failure.
$expectedMapping = [ordered]@{
    'capability:psmodule' = @{ ticket = 'R25'; count = 28 }
    'dependency-unsupported' = @{ ticket = 'R25'; count = 2 }
    'command-entry-host' = @{ ticket = 'R26'; count = 11 }
    'manifest-shape' = @{ ticket = 'R27'; count = 6 }
    'dependency-missing' = @{ ticket = 'R28'; count = 5 }
    'architecture-artifact' = @{ boundary = 'arm64-only'; count = 3 }
}

$failures = [System.Collections.Generic.List[string]]::new()
function Fail([string]$message) { $script:failures.Add($message) }

if (-not (Test-Path -LiteralPath $ledgerPath)) {
    Write-Error "Missing gap closure ledger: $ledgerPath"
    exit 1
}
$baseline = Get-Content $baselinePath -Raw | ConvertFrom-Json -AsHashtable
$ledger = Get-Content $ledgerPath -Raw | ConvertFrom-Json -AsHashtable

# 1. Baseline accounting: 55 rows over 53 unique packages, six mechanisms.
$baselineRows = 0
$baselineIds = [System.Collections.Generic.HashSet[string]]::new()
$baselineMap = @{}
foreach ($gap in $baseline.gaps) {
    $baselineMap[$gap.mechanism] = $gap
    foreach ($id in $gap.ids) {
        $baselineRows++
        [void]$baselineIds.Add($id)
    }
}
if ($baselineRows -ne 55) { Fail "baseline gap rows changed: expected 55, found $baselineRows" }
if ($baselineIds.Count -ne 53) { Fail "baseline unique blocked packages changed: expected 53, found $($baselineIds.Count)" }
if ($baseline.totals.plan_blocked -ne $baselineIds.Count) { Fail "baseline totals.plan_blocked=$($baseline.totals.plan_blocked) does not match $($baselineIds.Count) unique blocked ids" }
if ($baseline.gaps.Count -ne $expectedMapping.Count) { Fail "baseline mechanisms changed: expected $($expectedMapping.Count), found $($baseline.gaps.Count)" }
foreach ($mechanism in $expectedMapping.Keys) {
    if (-not $baselineMap.ContainsKey($mechanism)) { Fail "baseline lost mechanism $mechanism" }
    elseif ($baselineMap[$mechanism].count -ne $expectedMapping[$mechanism].count) {
        Fail "baseline $mechanism count=$($baselineMap[$mechanism].count), expected $($expectedMapping[$mechanism].count)"
    }
}
if ($ledger.source.baseline -ne 'tests/coverage/baseline.json') { Fail 'ledger must name tests/coverage/baseline.json as its source' }
if ($ledger.source.blocked_rows -ne $baselineRows) { Fail "ledger source.blocked_rows=$($ledger.source.blocked_rows), expected $baselineRows" }
if ($ledger.source.blocked_unique -ne $baselineIds.Count) { Fail "ledger source.blocked_unique=$($ledger.source.blocked_unique), expected $($baselineIds.Count)" }
foreach ($key in 'denominator') {
    if (-not $ledger.source.ContainsKey($key)) { Fail "ledger source is missing $key" }
}
if ($ledger.source.denominator.total -ne $baseline.denominator.total) { Fail 'ledger denominator total does not match the baseline' }

# 2. Proposed tickets: complete, unique, acyclic and still open-ended for the orchestrator.
$tickets = @{}
foreach ($ticket in $ledger.tickets) {
    if ($tickets.ContainsKey($ticket.id)) { Fail "duplicate proposed ticket $($ticket.id)"; continue }
    $tickets[$ticket.id] = $ticket
    foreach ($field in 'id','title','scope','reason','verification') {
        if ([string]::IsNullOrWhiteSpace([string]$ticket[$field])) { Fail "$($ticket.id) is missing $field" }
    }
    if (@($ticket.acceptance).Count -lt 2) { Fail "$($ticket.id) needs at least two acceptance criteria" }
    foreach ($criterion in @($ticket.acceptance)) { if ([string]::IsNullOrWhiteSpace([string]$criterion)) { Fail "$($ticket.id) has an empty acceptance criterion" } }
    foreach ($reference in @($ticket.blocks) + @($ticket.depends_on)) {
        if ([string]$reference -notmatch '^(R2[5-9]|#4[2-5])$') { Fail "$($ticket.id) references an unexpected issue $reference" }
    }
    foreach ($dependency in @($ticket.depends_on)) {
        if ($dependency -match '^R' -and -not $tickets.ContainsKey($dependency)) { Fail "$($ticket.id) depends on undefined ticket $dependency" }
    }
    if (@($ticket.blocks) -notcontains '#42') { Fail "$($ticket.id) must block #42 (R21 stays open while the gap is unresolved)" }
    if (@($ticket.blocks) -notcontains '#45') { Fail "$($ticket.id) must block #45 (final acceptance needs the gap closed)" }
    if ($ticket.issue -ne $null) { Fail "$($ticket.id) must not claim a created issue number; the orchestrator creates it" }
}
if ($tickets.Count -ne 4) { Fail "expected exactly four proposed tickets, found $($tickets.Count)" }
$order = @{}
function Visit([string]$id) {
    if ($order[$id] -eq 1) { Fail "proposed ticket dependency cycle at $id"; return }
    if ($order[$id] -eq 2) { return }
    $order[$id] = 1
    foreach ($dependency in @($tickets[$id].depends_on)) { if ($dependency -match '^R' -and $tickets.ContainsKey($dependency)) { Visit $dependency } }
    $order[$id] = 2
}
foreach ($id in $tickets.Keys) { Visit $id }

# 3. Every baseline gap row has exactly one disposition row with the same codes and a real cause.
$entries = @{}
$entryRows = 0
foreach ($entry in $ledger.entries) {
    $entryRows++
    $key = "$($entry.id)|$($entry.mechanism)"
    if ($entries.ContainsKey($key)) { Fail "duplicate ledger entry $key"; continue }
    $entries[$key] = $entry
    if ([string]::IsNullOrWhiteSpace([string]$entry.cause) -or ([string]$entry.cause).Length -lt 20) { Fail "$key needs a substantive cause" }
    if (@($entry.codes).Count -eq 0) { Fail "$key has no diagnostic codes" }
    if (@($entry.resolution).Count -eq 0) { Fail "$key has no resolution" }
    $resolution = $entry.resolution
    switch ($resolution.kind) {
        'ticket' {
            if (-not $tickets.ContainsKey([string]$resolution.ticket)) { Fail "$key points at unknown ticket $($resolution.ticket)" }
        }
        'architecture-scope' {
            if ($entry.mechanism -ne 'architecture-artifact') { Fail "$key can only use architecture-scope for architecture-artifact" }
            $boundary = @($ledger.boundaries | Where-Object { $_.id -eq $resolution.boundary })
            if ($boundary.Count -ne 1) { Fail "$key references unknown boundary $($resolution.boundary)" }
            elseif ([string]::IsNullOrWhiteSpace([string]$boundary[0].reason) -or [string]::IsNullOrWhiteSpace([string]$boundary[0].evidence)) { Fail "boundary $($resolution.boundary) needs reason and evidence" }
        }
        default { Fail "$key has unsupported resolution kind '$($resolution.kind)'" }
    }
}
if ($entryRows -ne $baselineRows) { Fail "ledger has $entryRows entries, baseline has $baselineRows gap rows" }

foreach ($gap in $baseline.gaps) {
    $expected = $expectedMapping[$gap.mechanism]
    foreach ($id in $gap.ids) {
        $key = "$id|$($gap.mechanism)"
        if (-not $entries.ContainsKey($key)) { Fail "ledger is missing $key"; continue }
        $entry = $entries[$key]
        $expectedCodes = @($gap.codes | Sort-Object)
        $entryCodes = @($entry.codes | Sort-Object)
        if (($expectedCodes -join ',') -ne ($entryCodes -join ',')) { Fail "$key codes=$($entryCodes -join ','), baseline=$($expectedCodes -join ',')" }
        if ($expected.ContainsKey('ticket')) {
            if ($entry.resolution.kind -ne 'ticket' -or $entry.resolution.ticket -ne $expected.ticket) {
                Fail "$key must resolve through $($expected.ticket), found $($entry.resolution.kind)/$($entry.resolution.ticket)"
            }
        } elseif ($expected.ContainsKey('boundary')) {
            if ($entry.resolution.kind -ne 'architecture-scope' -or $entry.resolution.boundary -ne $expected.boundary) {
                Fail "$key must use the $($expected.boundary) boundary"
            }
        }
    }
}

# No package may be declared out of scope; architecture-only packages stay visible as unrun work.
foreach ($entry in $ledger.entries) {
    if ($entry.resolution.kind -eq 'architecture-scope' -and $entry.mechanism -ne 'architecture-artifact') { Fail "$($entry.id) uses architecture scope outside the arm64-only case" }
}
if (@($ledger.entries | Where-Object { $_.resolution.kind -eq 'architecture-scope' }).Count -ne 3) { Fail 'the three arm64-only packages must be the only architecture-scoped entries' }

if ($failures.Count) {
    $failures | ForEach-Object { Write-Output "FAIL $_" }
    exit 1
}
Write-Output ("PASS gap closure ledger: {0} entries over {1} unique blocked packages, {2} proposed tickets, {3} architecture boundary" -f $entryRows, $baselineIds.Count, $tickets.Count, @($ledger.boundaries).Count)
exit 0

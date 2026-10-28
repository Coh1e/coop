$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$baselinePath = Join-Path $PSScriptRoot 'coverage/baseline.json'
$ledgerPath = Join-Path $PSScriptRoot 'coverage/gaps.json'

# R21/#42 closes the inventory loop: every blocked package from the full Main/Extras inventory has
# one explicit disposition. The ledger is checked structurally here so a later inventory cannot drop
# a gap, shrink scope or reroute a mechanism without an obvious failure.
$expectedMapping = [ordered]@{
    'capability:psmodule' = @{ ticket = 'R25'; issue = 46; count = 28 }
    'dependency-unsupported' = @{ ticket = 'R25'; issue = 46; count = 2 }
    'command-entry-host' = @{ ticket = 'R26'; issue = 47; count = 11 }
    'manifest-shape' = @{ ticket = 'R27'; issue = 48; count = 6 }
    'dependency-missing' = @{ ticket = 'R28'; issue = 49; count = 5 }
    'architecture-artifact' = @{ boundary = 'arm64-only'; count = 3 }
}

$failures = [System.Collections.Generic.List[string]]::new()
$expectedIssue = @{ R25 = 46; R26 = 47; R27 = 48; R28 = 49 }
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

# 2. Child tickets: complete, unique, acyclic and bound to the created, now closed issues.
$tickets = @{}
foreach ($ticket in $ledger.tickets) {
    if ($tickets.ContainsKey($ticket.id)) { Fail "duplicate proposed ticket $($ticket.id)"; continue }
    $tickets[$ticket.id] = $ticket
    foreach ($field in 'id','title','scope','reason','verification','delivered') {
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
    if ($ticket.issue -ne $expectedIssue[$ticket.id]) { Fail "$($ticket.id) must bind to issue #$($expectedIssue[$ticket.id])" }
    if ($ticket.issue_state -ne 'closed') { Fail "$($ticket.id) must record the closed child issue" }
    if (@($ticket.closure_evidence).Count -eq 0) { Fail "$($ticket.id) has no closure evidence" }
}
if ($tickets.Count -ne 4) { Fail "expected exactly four child tickets, found $($tickets.Count)" }
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

# 4. Dependency-source ledger: the official buckets that make cross-bucket dependencies
# resolvable must stay outside the compatibility denominator and pinned to a full revision, and
# the packages it documents must be the same ones the gap ledger attributes to R28.
$dependencySourcePath = Join-Path $PSScriptRoot 'coverage/dependency-sources.json'
if (-not (Test-Path -LiteralPath $dependencySourcePath)) {
    Fail 'missing tests/coverage/dependency-sources.json'
} else {
    $dependencySources = Get-Content -LiteralPath $dependencySourcePath -Raw | ConvertFrom-Json
    if ($dependencySources.schema -ne 1) { Fail 'dependency source ledger schema must be 1' }
    $sourceNames = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($source in @($dependencySources.buckets)) {
        $name = [string]$source.name
        if (-not $sourceNames.Add($name)) { Fail "duplicate dependency source $name"; continue }
        if ($name -notmatch '^[A-Za-z0-9._-]+$') { Fail "invalid dependency source name: $name" }
        if ([string]$source.url -notmatch '^https://') { Fail "dependency source $name needs an https url" }
        if ([string]$source.revision -notmatch '^[0-9a-f]{40}$') { Fail "dependency source $name is not pinned to a 40-hex revision" }
        if ([string]$source.role -ne 'dependency-source') { Fail "dependency source $name must declare role=dependency-source" }
        if ($source.denominator -ne $false) { Fail "dependency source $name must stay outside the Main/Extras denominator" }
        if (@($source.consumers).Count -eq 0) { Fail "dependency source $name documents no consuming package" }
        foreach ($consumer in @($source.consumers)) {
            foreach ($field in 'package','declared','resolved') {
                if ([string]::IsNullOrWhiteSpace([string]$consumer.$field)) { Fail "dependency source $name has a consumer without $field" }
            }
        }
    }
    $versionsSources = @($dependencySources.buckets | Where-Object { $_.name -eq 'versions' })
    if ($versionsSources.Count -ne 1) { Fail 'the dependency source ledger must define the official versions bucket exactly once' }
    else {
        foreach ($entry in @($ledger.entries | Where-Object { $_.mechanism -eq 'dependency-missing' })) {
            $consumer = @($versionsSources[0].consumers | Where-Object { $_.package -eq $entry.id })
            if ($consumer.Count -ne 1) { Fail "dependency source ledger does not document $($entry.id)" }
            elseif ($consumer[0].declared -ne $entry.dependency) { Fail "$($entry.id) declares $($entry.dependency) but the dependency source ledger records $($consumer[0].declared)" }
        }
    }
    $inventoryScript = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'real-scoop-coverage.ps1') -Raw
    if ($inventoryScript -notmatch 'coverage/dependency-sources\.json') { Fail 'the inventory script must read the pinned dependency source ledger' }
}

# 5. Closure: the four child tickets are closed and a fresh measurement of the same 53 baseline
# packages classifies every row, leaving only the documented Python-host precondition and the
# human-approved ARM64 lifecycle exception.
if (-not $ledger.ContainsKey('closure')) {
    Fail 'ledger needs a closure block'
} else {
    $closure = $ledger.closure
    if ($closure.code_head -notmatch '^[0-9a-f]{40}$') { Fail 'closure.code_head must be a full commit' }
    if ($closure.coop_sha256 -notmatch '^[0-9a-f]{64}$') { Fail 'closure.coop_sha256 must be a SHA256' }
    if ([string]::IsNullOrWhiteSpace([string]$closure.verified_at)) { Fail 'closure.verified_at is empty' }
    foreach ($revision in @($closure.inventory.measured.main, $closure.inventory.measured.extras, $closure.inventory.measured.versions)) {
        if ([string]$revision -notmatch '^[0-9a-f]{40}$') { Fail "closure measured revision is not a full commit: $revision" }
    }
    if ($closure.inventory.measured.extras -ne $baseline.buckets[1].revision) { Fail 'closure measured Extras revision differs from the baseline' }
    if ($closure.inventory.baseline.main -ne $baseline.buckets[0].revision) { Fail 'closure baseline Main revision differs from the baseline' }
    if ($closure.inventory.baseline.total -ne $baseline.denominator.total) { Fail 'closure baseline total differs from the baseline' }
    if ($closure.inventory.measured.denominator -ne 4149) { Fail 'closure measured denominator must stay 4149' }
    if ($closure.inventory.measured.plan_executable -ne 4141) { Fail "closure plan_executable=$($closure.inventory.measured.plan_executable), expected 4141" }
    if ($closure.inventory.measured.plan_blocked -ne 6) { Fail "closure plan_blocked=$($closure.inventory.measured.plan_blocked), expected 6" }
    if ($dependencySources -and $closure.inventory.measured.versions -ne @($dependencySources.buckets | Where-Object { $_.name -eq 'versions' })[0].revision) { Fail 'closure versions revision differs from dependency-sources.json' }
    foreach ($status in 'resolved','blocked-precondition','approved-exception') {
        if ($null -eq $closure.row_status[$status]) { Fail "closure.row_status is missing $status" }
    }
    if ($closure.row_status.resolved -ne 49) { Fail "closure resolved rows=$($closure.row_status.resolved), expected 49" }
    if ($closure.row_status['blocked-precondition'] -ne 3) { Fail "closure blocked-precondition rows=$($closure.row_status['blocked-precondition']), expected 3" }
    if ($closure.row_status['approved-exception'] -ne 3) { Fail "closure approved-exception rows=$($closure.row_status['approved-exception']), expected 3" }
    if (($closure.row_status.resolved + $closure.row_status['blocked-precondition'] + $closure.row_status['approved-exception']) -ne $entryRows) { Fail 'closure row_status does not cover every ledger entry' }
    $expectedRemaining = @(
        'extras/cpu-z-arm64|architecture-artifact|approved-exception'
        'extras/pdd|command-entry-host|blocked-precondition'
        'main/gel-arm64|architecture-artifact|approved-exception'
        'main/llvm-arm64|architecture-artifact|approved-exception'
        'main/retdec|command-entry-host|blocked-precondition'
        'main/vapoursynth|command-entry-host|blocked-precondition'
    )
    $actualRemaining = @($closure.remaining | ForEach-Object { "$($_.id)|$($_.mechanism)|$($_.status)" } | Sort-Object)
    if (($actualRemaining -join ',') -ne (($expectedRemaining | Sort-Object) -join ',')) { Fail "closure remaining set changed: $($actualRemaining -join ', ')" }
    if (@($closure.remaining).Count -ne 6) { Fail "closure must list exactly six remaining rows, found $(@($closure.remaining).Count)" }
    foreach ($row in @($closure.remaining)) {
        if ([string]::IsNullOrWhiteSpace([string]$row.reason) -or ([string]$row.reason).Length -lt 20) { Fail "remaining row $($row.id) needs a substantive reason" }
        if ([string]::IsNullOrWhiteSpace([string]$row.evidence)) { Fail "remaining row $($row.id) needs evidence" }
        if ($row.status -notin @('blocked-precondition','approved-exception')) { Fail "remaining row $($row.id) has unexpected status $($row.status)" }
        if ($row.status -eq 'approved-exception' -and $row.mechanism -ne 'architecture-artifact') { Fail "only arm64 rows may use approved-exception: $($row.id)" }
    }
    $expectedByKey = @{}
    foreach ($item in $expectedRemaining) { $expectedByKey[$item] = $true }
    $counts = @{ resolved = 0; 'blocked-precondition' = 0; 'approved-exception' = 0 }
    foreach ($entry in $ledger.entries) {
        $key = "$($entry.id)|$($entry.mechanism)|$($entry.closure)"
        if ($entry.closure -notin @('resolved','blocked-precondition','approved-exception')) { Fail "entry $($entry.id)/$($entry.mechanism) has no valid closure status" ; continue }
        $counts[$entry.closure]++
        if ($expectedByKey.ContainsKey($key)) { Continue }
        $stillRemaining = @($closure.remaining | Where-Object { $_.id -eq $entry.id -and $_.mechanism -eq $entry.mechanism })
        if ($stillRemaining.Count -gt 0) { Fail "entry $($entry.id)/$($entry.mechanism) closure '$($entry.closure)' disagrees with the remaining list" }
        if ($entry.closure -ne 'resolved') { Fail "entry $($entry.id)/$($entry.mechanism) must be resolved" }
    }
    foreach ($status in @('resolved','blocked-precondition','approved-exception')) {
        if ($counts[$status] -ne $closure.row_status[$status]) { Fail "entry closure counts ($($counts[$status])) disagree with row_status.$status ($($closure.row_status[$status]))" }
    }
    $approval = @($closure.human_approvals)[0]
    if ($approval.date -ne '2026-10-27') { Fail 'closure must record the 2026-10-27 human approval' }
    if ([string]$approval.scope -notmatch 'ARM64') { Fail 'human approval scope must name the ARM64-only packages' }
    if ([string]$approval.terms -notmatch 'not run|unverified') { Fail 'human approval terms must keep the ARM64 lifecycle unrun/unverified' }
    if ($ledger.boundaries[0].approval_date -ne '2026-10-27') { Fail 'arm64 boundary must cite the human approval date' }
    if ([string]$ledger.boundaries[0].approval_scope -notmatch 'ARM64') { Fail 'arm64 boundary must cite the approved scope' }
    $correction = $closure.shape_fixture_correction
    if ($correction.old_status -ne 'void') { Fail 'the old shape fixture must be marked void' }
    if (@($correction.corrected_bin_four).Count -ne 4) { Fail 'the corrected bin fixture must be one 4-element tuple' }
    if ([string]$correction.historical_observation -ne 'Invalid bin entry') { Fail 'the corrected fixture must record the Invalid bin entry observation' }
    if ([string]::IsNullOrWhiteSpace([string]$correction.current_head_observation)) { Fail 'the corrected fixture must record the current-head observation' }
    $evidence = @($closure.evidence)
    foreach ($required in 'shape-fixture-summary.json','closure-verify-summary.json','coverage-20261027-054326/summary.json') {
        if (-not ($evidence -match [regex]::Escape($required))) { Fail "closure evidence does not cite $required" }
    }
}

if ($failures.Count) {
    $failures | ForEach-Object { Write-Output "FAIL $_" }
    exit 1
}
Write-Output ("PASS gap closure ledger: {0} entries over {1} unique blocked packages, {2} closed child tickets, {3} resolved rows, {4} remaining rows" -f $entryRows, $baselineIds.Count, $tickets.Count, $ledger.closure.row_status.resolved, @($ledger.closure.remaining).Count)
exit 0


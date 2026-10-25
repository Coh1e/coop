param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$sessionRoot = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sessionRoot -Force | Out-Null
$fixture1 = Join-Path (Split-Path $CoopExe) 'fixture-1.exe'
$fixture2 = Join-Path (Split-Path $CoopExe) 'fixture-2.exe'
foreach ($path in @($fixture1,$fixture2)) { if (-not (Test-Path -LiteralPath $path)) { throw "Missing fixed test input: $path" } }

function Set-Manifest([string]$Root,[string]$Version,[string]$Url) {
    $source = if ($Version -eq '1') { $fixture1 } else { $fixture2 }
    @{version=$Version;url=$Url;hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLower();bin='fixture.exe'} |
        ConvertTo-Json | Set-Content -LiteralPath "$Root/buckets/test/bucket/fixture.json" -Encoding utf8
}
function File-Uri([string]$Path) { return ([Uri][IO.Path]::GetFullPath($Path)).AbsoluteUri+'#/fixture.exe' }
function Pending-Journals([string]$Root) {
    if (-not (Test-Path -LiteralPath "$Root/.coop/transactions")) { return @() }
    return @(Get-ChildItem -LiteralPath "$Root/.coop/transactions" -Recurse -Filter journal.json |
        ForEach-Object { @{Path=$_.FullName;Value=(Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json)} } |
        Where-Object { $_.Value.state -eq 'pending' })
}
function Start-Coordinated([string]$Exe,[string]$Root,[string[]]$Arguments,[Net.Sockets.TcpListener]$Listener) {
    $connection = $Listener.AcceptTcpClientAsync()
    $start = [Diagnostics.ProcessStartInfo]::new($Exe)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    if (-not $connection.Wait(15000)) { $process.Kill($true); throw 'Coop did not reach the controlled server' }
    $client = $connection.GetAwaiter().GetResult()
    $stream = $client.GetStream()
    $stream.ReadTimeout = 10000
    $request = ''
    while (-not $request.EndsWith("`r`n`r`n")) {
        $value = $stream.ReadByte()
        if ($value -lt 0 -or $request.Length -gt 16384) { throw 'incomplete local HTTP request' }
        $request += [char]$value
    }
    return @{Process=$process;Client=$client;Output=$process.StandardOutput.ReadToEndAsync();Error=$process.StandardError.ReadToEndAsync()}
}

try {
    # A: actual interruption while an update holds the root lock. A second writer must be
    # refused, readers must work, the old program must remain runnable, and recovery must
    # make the update retryable.
    $root = "$sessionRoot/update"
    New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null
    Set-Manifest $root '1' (File-Uri $fixture1)
    $install = & $CoopExe --root $root install test/fixture --json
    if ($LASTEXITCODE -ne 0 -or (& "$root/shims/fixture.exe") -ne 'fixture 1') { throw "Initial fixture install failed: $install" }
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $coordinated = $null
    try {
        Set-Manifest $root '2' "http://127.0.0.1:$port/fixture.exe"
        $coordinated = Start-Coordinated $CoopExe $root @('--root',$root,'update','fixture','--json') $listener
        $pending = @(Pending-Journals $root)
        if ($pending.Count -ne 1 -or $pending[0].Value.action -ne 'update') { throw 'Actual update interruption did not leave one pending update journal' }
        if ((& "$root/shims/fixture.exe") -ne 'fixture 1') { throw 'Old program stopped working while update was in progress' }

        $during = & $CoopExe --root $root list --json
        if ($LASTEXITCODE -ne 0) { throw 'Read query was blocked while an update was in progress' }
        $duringItem = @($during | ConvertFrom-Json | Where-Object name -eq 'fixture')
        if ($duringItem.Count -ne 1 -or $duringItem[0].version -ne '1' -or
            $duringItem[0].last_operation -ne 'pending-recovery' -or
            $duringItem[0].recovery.mode -ne 'automatic' -or $duringItem[0].recovery.action -ne 'update') {
            throw "Read query did not expose the in-progress update consistently: $during"
        }

        $secondStart = [Diagnostics.ProcessStartInfo]::new($CoopExe)
        $secondStart.UseShellExecute = $false; $secondStart.RedirectStandardOutput = $true; $secondStart.RedirectStandardError = $true
        foreach ($argument in @('--root',$root,'uninstall','fixture','--json')) { $secondStart.ArgumentList.Add($argument) }
        $second = [Diagnostics.Process]::Start($secondStart)
        $secondOutput = $second.StandardOutput.ReadToEndAsync(); $secondError = $second.StandardError.ReadToEndAsync()
        if (-not $second.WaitForExit(15000)) { $second.Kill($true); throw 'Second writer did not finish while the root lock was held' }
        $secondText = $secondOutput.GetAwaiter().GetResult()+"`n"+$secondError.GetAwaiter().GetResult()
        if ($second.ExitCode -eq 0) { throw 'A second write process changed the root while another writer held the lock' }
        if ($secondText -notmatch 'Root is busy|write lock|another Coop') { throw "Second writer failed for an unrelated reason: $secondText" }
        if ((& "$root/shims/fixture.exe") -ne 'fixture 1' -or (Test-Path "$root/apps/fixture/2") -or
            (Get-Content "$root/.coop/packages/fixture.json" -Raw | ConvertFrom-Json).version -ne '1') {
            throw 'The refused concurrent write changed installed state'
        }
        $recoverDuring = & $CoopExe --root $root recover --json 2>&1
        if ($LASTEXITCODE -eq 0 -or ($recoverDuring -join "`n") -notmatch 'Root is busy|write lock|another Coop') {
            throw "Recovery ignored the active writer lock: $recoverDuring"
        }

        $coordinated.Process.Kill($true)
        $coordinated.Process.WaitForExit()
    } finally {
        if ($coordinated) {
            $coordinated.Output.GetAwaiter().GetResult() | Out-Null
            $coordinated.Error.GetAwaiter().GetResult() | Out-Null
            $coordinated.Client.Dispose()
            $coordinated.Process.Dispose()
        }
        $listener.Stop()
    }

    $journalPath = $pending[0].Path
    $afterCrash = & $CoopExe --root $root list --json
    $afterItem = @($afterCrash | ConvertFrom-Json | Where-Object name -eq 'fixture')
    if ($LASTEXITCODE -ne 0 -or $afterItem.Count -ne 1 -or $afterItem[0].last_operation -ne 'pending-recovery' -or
        $afterItem[0].recovery.mode -ne 'automatic' -or $afterItem[0].recovery.status -ne 'recoverable') {
        throw "Restarted query did not report the interrupted update: $afterCrash"
    }
    if ((& "$root/shims/fixture.exe") -ne 'fixture 1') { throw 'Interrupted update did not leave the current program runnable' }
    $refused = & $CoopExe --root $root update fixture --json 2>&1
    if ($LASTEXITCODE -eq 0 -or ($refused -join "`n") -notmatch 'Pending transaction requires recovery') { throw "Pending update was silently ignored: $refused" }

    $journalHash = (Get-FileHash -LiteralPath $journalPath).Hash
    $dry = & $CoopExe --root $root recover --dry-run --json
    $dryEntries = @($dry | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0 -or $dryEntries.Count -ne 1 -or $dryEntries[0].mode -ne 'automatic' -or
        $dryEntries[0].status -ne 'recoverable' -or (Get-FileHash -LiteralPath $journalPath).Hash -ne $journalHash -or
        (& "$root/shims/fixture.exe") -ne 'fixture 1') {
        throw "Recovery preview changed state or misclassified the transaction: $dry"
    }
    $recovered = & $CoopExe --root $root recover --json
    $recoveredEntries = @($recovered | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0 -or $recoveredEntries.Count -ne 1 -or $recoveredEntries[0].status -ne 'recovered') { throw "Automatic recovery failed: $recovered" }
    if ((Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json).state -ne 'rolled-back') { throw 'Recovered update journal was not marked rolled-back' }
    if (Test-Path "$root/apps/fixture/2") { throw 'Recovery left the interrupted target version published' }
    if ((& "$root/shims/fixture.exe") -ne 'fixture 1' -or (Get-Content "$root/.coop/packages/fixture.json" -Raw | ConvertFrom-Json).version -ne '1') {
        throw 'Recovery did not preserve the current package version'
    }

    Set-Manifest $root '2' (File-Uri $fixture2)
    $retry = & $CoopExe --root $root update fixture --json
    if ($LASTEXITCODE -ne 0 -or (& "$root/shims/fixture.exe") -ne 'fixture 2' -or
        (& "$root/apps/fixture/1/fixture.exe") -ne 'fixture 1') { throw "Update was not retryable after recovery: $retry" }
    $final = @(& $CoopExe --root $root list --json | ConvertFrom-Json | Where-Object name -eq 'fixture')
    if ($LASTEXITCODE -ne 0 -or $final.Count -ne 1 -or $final[0].version -ne '2' -or
        $final[0].last_operation -ne 'succeeded' -or 'recovery' -in $final[0].PSObject.Properties.Name) {
        throw 'Successful retry did not clear pending recovery state'
    }

    # B: a fresh install that never published an app record is still visible after restart.
    $rootB = "$sessionRoot/fresh"
    New-Item -ItemType Directory -Path "$rootB/buckets/test/bucket" -Force | Out-Null
    $listenerB = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listenerB.Start()
    $portB = $listenerB.LocalEndpoint.Port
    $coordinatedB = $null
    try {
        Set-Manifest $rootB '1' "http://127.0.0.1:$portB/fixture.exe"
        $coordinatedB = Start-Coordinated $CoopExe $rootB @('--root',$rootB,'install','test/fixture','--json') $listenerB
        if (@(Pending-Journals $rootB).Count -ne 1) { throw 'Actual fresh install interruption did not leave a pending journal' }
        $coordinatedB.Process.Kill($true)
        $coordinatedB.Process.WaitForExit()
    } finally {
        if ($coordinatedB) {
            $coordinatedB.Output.GetAwaiter().GetResult() | Out-Null
            $coordinatedB.Error.GetAwaiter().GetResult() | Out-Null
            $coordinatedB.Client.Dispose()
            $coordinatedB.Process.Dispose()
        }
        $listenerB.Stop()
    }
    $freshList = @(& $CoopExe --root $rootB list --json | ConvertFrom-Json | Where-Object name -eq 'fixture')
    if ($LASTEXITCODE -ne 0 -or $freshList.Count -ne 1 -or $freshList[0].management -ne 'none' -or
        $freshList[0].status -ne 'pending-recovery' -or $freshList[0].last_operation -ne 'pending-recovery' -or
        $freshList[0].recovery.action -ne 'install' -or $freshList[0].recovery.mode -ne 'automatic') {
        throw "Fresh interrupted install was not queryable after restart: $freshList"
    }
    $freshRecovered = & $CoopExe --root $rootB recover --json
    if ($LASTEXITCODE -ne 0 -or @($freshRecovered | ConvertFrom-Json)[0].status -ne 'recovered' -or
        (Test-Path "$rootB/apps/fixture/current") -or (Test-Path "$rootB/.coop/packages/fixture.json")) {
        throw "Fresh interrupted install recovery published unexpected state: $freshRecovered"
    }
    Set-Manifest $rootB '1' (File-Uri $fixture1)
    $freshRetry = & $CoopExe --root $rootB install test/fixture --json
    if ($LASTEXITCODE -ne 0 -or (& "$rootB/shims/fixture.exe") -ne 'fixture 1') { throw "Fresh install was not retryable after recovery: $freshRetry" }

    # C: deterministic publication-stage state. The journal and filesystem were produced with the
    # real install protocol, then the current link/record/entry moves were replayed and Coop was
    # interrupted before commit. Recovery must delete the new current/version and restore moves.
    $rootC = "$sessionRoot/publication"
    New-Item -ItemType Directory -Path "$rootC/buckets/test/bucket" -Force | Out-Null
    Set-Manifest $rootC '1' (File-Uri $fixture1)
    & $CoopExe --root $rootC install test/fixture --json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Publication recovery fixture install failed' }
    $tx = "$rootC/.coop/transactions/simulated-publication"
    New-Item -ItemType Directory -Path $tx -Force | Out-Null
    $current = "$rootC/apps/fixture/current"; $oldCurrent = "$tx/old-current"
    $shim = "$rootC/shims/fixture.exe"; $oldShim = "$tx/fixture.old.exe"
    $metadata = "$rootC/shims/fixture.coop-shim.json"; $oldMetadata = "$tx/fixture.old-metadata"
    $record = "$rootC/.coop/packages/fixture.json"; $oldRecord = "$tx/old-managed-record.json"
    [IO.Directory]::Move($current,$oldCurrent)
    [IO.File]::Move($shim,$oldShim)
    [IO.File]::Move($metadata,$oldMetadata)
    [IO.File]::Move($record,$oldRecord)
    New-Item -ItemType Directory -Path "$rootC/apps/fixture/2" -Force | Out-Null
    [IO.File]::WriteAllText("$rootC/apps/fixture/2/marker.txt",'new version')
    New-Item -ItemType Junction -Path $current -Target "$rootC/apps/fixture/2" | Out-Null
    @{state='pending';action='update';package='fixture';stage='publishing-version';
      created=@(@{path="$rootC/apps/fixture/2";owned=$true},@{path=$current;owned=$true});
      moves=@(@{from=$current;to=$oldCurrent;moved=$true},@{from=$shim;to=$oldShim;moved=$true},
              @{from=$metadata;to=$oldMetadata;moved=$true},@{from=$record;to=$oldRecord;moved=$true});
      scripts=@()} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$tx/journal.json" -Encoding utf8
    $publicationList = @(& $CoopExe --root $rootC list --json | ConvertFrom-Json | Where-Object name -eq 'fixture')
    if ($LASTEXITCODE -ne 0 -or $publicationList.Count -ne 1 -or $publicationList[0].version -ne '1' -or
        $publicationList[0].management -ne 'managed' -or $publicationList[0].status -ne 'ready' -or
        $publicationList[0].last_operation -ne 'pending-recovery' -or $publicationList[0].recovery.action -ne 'update') {
        throw "Query did not read the last published record during publication-stage interruption: $publicationList"
    }
    $publicationDry = & $CoopExe --root $rootC recover --dry-run --json
    $publicationDryEntry = @($publicationDry | ConvertFrom-Json)[0]
    if ($LASTEXITCODE -ne 0 -or $publicationDryEntry.mode -ne 'automatic' -or
        @($publicationDryEntry.actions | Where-Object kind -eq 'remove').Count -ne 2 -or
        @($publicationDryEntry.actions | Where-Object kind -eq 'restore').Count -ne 4) {
        throw "Publication recovery was misclassified: $publicationDry"
    }
    if (-not (Test-Path -LiteralPath $current) -or -not (Test-Path -LiteralPath "$rootC/apps/fixture/2")) { throw 'Recovery preview changed publication-stage state' }
    $publicationRecovered = & $CoopExe --root $rootC.ToUpper() recover --json
    if ($LASTEXITCODE -ne 0 -or @($publicationRecovered | ConvertFrom-Json)[0].status -ne 'recovered' -or
        (Test-Path "$rootC/apps/fixture/2") -or (& "$rootC/shims/fixture.exe") -ne 'fixture 1' -or
        (Get-Content -LiteralPath $record -Raw | ConvertFrom-Json).version -ne '1') {
        throw "Publication-stage rollback did not restore the prior installation: $publicationRecovered"
    }
    if ((Get-Content -LiteralPath "$tx/journal.json" -Raw | ConvertFrom-Json).state -ne 'rolled-back') { throw 'Publication-stage journal was not resolved' }

    # D: script evidence is preserved and never re-run; the result admits unknown external effects.
    $rootD = [IO.Path]::GetFullPath("$sessionRoot/scripts")
    $scriptTx = [IO.Path]::GetFullPath("$rootD/.coop/transactions/simulated-scripts")
    New-Item -ItemType Directory -Path "$scriptTx/scripts" -Force | Out-Null
    [IO.File]::WriteAllText("$scriptTx/scripts/1-post_install.stdout.log",'previous hook output')
    @{state='pending';action='install';package='hookfixture';created=@();moves=@();
      scripts=@(@{phase='post_install';status='succeeded';exit_code=0;stdout_log='scripts/1-post_install.stdout.log'})} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$scriptTx/journal.json" -Encoding utf8
    $scriptRecovered = & $CoopExe --root $rootD recover --json
    $scriptEntry = @($scriptRecovered | ConvertFrom-Json)[0]
    if ($LASTEXITCODE -ne 0 -or $scriptEntry.status -ne 'recovered-with-unknown-script-effects' -or
        $scriptEntry.external_side_effects -notmatch 'not re-run' -or
        $scriptEntry.transaction_evidence_retained -ne $scriptTx -or
        (Get-Content -LiteralPath "$scriptTx/scripts/1-post_install.stdout.log" -Raw) -ne 'previous hook output') {
        throw "Script transaction recovery was not explicit or lost evidence: $scriptRecovered"
    }
    $scriptJournal = Get-Content -LiteralPath "$scriptTx/journal.json" -Raw | ConvertFrom-Json
    if ($scriptJournal.state -ne 'rolled-back' -or @($scriptJournal.scripts).Count -ne 1 -or
        $scriptJournal.scripts[0].stdout_log -ne 'scripts/1-post_install.stdout.log' -or
        $scriptJournal.recovery_external_side_effects -notmatch 'not re-run') { throw 'Script evidence was lost or a script was retried' }

    # E: conflicting move endpoints are manual. No automatic deletion happens until a human
    # resolves the conflict, then the same recovery command completes.
    $rootE = "$sessionRoot/manual"
    New-Item -ItemType Directory -Path "$rootE/buckets/test/bucket" -Force | Out-Null
    Set-Manifest $rootE '1' (File-Uri $fixture1)
    & $CoopExe --root $rootE install test/fixture --json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Manual recovery fixture install failed' }
    $txE = "$rootE/.coop/transactions/simulated-conflict"
    New-Item -ItemType Directory -Path $txE -Force | Out-Null
    $currentE = "$rootE/apps/fixture/current"; $oldCurrentE = "$txE/old-current"
    $recordE = "$rootE/.coop/packages/fixture.json"; $oldRecordE = "$txE/old-managed-record.json"
    [IO.Directory]::Move($currentE,$oldCurrentE)
    [IO.File]::Move($recordE,$oldRecordE)
    New-Item -ItemType Directory -Path $currentE -Force | Out-Null
    [IO.File]::WriteAllText("$currentE/foreign.txt",'foreign data must survive')
    @{state='pending';action='update';package='fixture';created=@();moves=@(
        @{from=$currentE;to=$oldCurrentE;moved=$true},@{from=$recordE;to=$oldRecordE;moved=$true});scripts=@()} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$txE/journal.json" -Encoding utf8
    $manual = & $CoopExe --root $rootE recover --json
    $manualEntry = @($manual | ConvertFrom-Json)[0]
    if ($LASTEXITCODE -ne 1 -or $manualEntry.mode -ne 'manual' -or $manualEntry.status -ne 'manual') { throw "Conflicting transaction was not marked manual: $manual" }
    if ((Get-Content -LiteralPath "$currentE/foreign.txt" -Raw) -ne 'foreign data must survive' -or
        (Get-Content -LiteralPath "$txE/journal.json" -Raw | ConvertFrom-Json).state -ne 'pending' -or
        -not (Test-Path -LiteralPath $oldCurrentE) -or -not (Test-Path -LiteralPath $oldRecordE)) {
        throw 'Manual recovery changed or deleted unowned state'
    }
    Remove-Item -LiteralPath $currentE -Recurse -Force
    $manualRetry = & $CoopExe --root $rootE recover --json
    if ($LASTEXITCODE -ne 0 -or @($manualRetry | ConvertFrom-Json)[0].status -ne 'recovered' -or
        (& "$rootE/shims/fixture.exe") -ne 'fixture 1' -or
        (Get-Content -LiteralPath $recordE -Raw | ConvertFrom-Json).version -ne '1') {
        throw "Manual conflict resolution did not complete recovery: $manualRetry"
    }

    # F/G: the same recovery command routes adoption and cleanup journals to their own
    # idempotent protocols instead of treating them as package installs.
    $rootF = [IO.Path]::GetFullPath("$sessionRoot/adopt-journal")
    $adoptTx = [IO.Path]::GetFullPath("$rootF/.coop/transactions/simulated-adopt")
    $adoptBackup = [IO.Path]::GetFullPath("$rootF/.coop/backups/fixture/simulated-adopt")
    $adoptRecord = [IO.Path]::GetFullPath("$rootF/.coop/packages/fixture.json")
    New-Item -ItemType Directory -Path $adoptTx,$adoptBackup -Force | Out-Null
    [IO.File]::WriteAllText("$adoptBackup/evidence.json",'{}')
    @{state='pending';action='adopt';package='fixture';record=$adoptRecord;backup=$adoptBackup} |
        ConvertTo-Json | Set-Content -LiteralPath "$adoptTx/journal.json" -Encoding utf8
    $adoptRecovered = & $CoopExe --root $rootF recover --json
    $adoptEntry = @($adoptRecovered | ConvertFrom-Json)[0]
    if ($LASTEXITCODE -ne 0 -or $adoptEntry.action -ne 'adopt' -or $adoptEntry.mode -ne 'automatic' -or
        $adoptEntry.status -ne 'rolled-back' -or
        (Get-Content -LiteralPath "$adoptTx/journal.json" -Raw | ConvertFrom-Json).state -ne 'rolled-back') {
        throw "Adoption journal was not recovered through the shared command: $adoptRecovered"
    }
    $rootG = "$sessionRoot/cleanup-journal"
    $cleanupTx = "$rootG/.coop/transactions/simulated-cleanup"
    New-Item -ItemType Directory -Path "$rootG/apps","$cleanupTx/0-old" -Force | Out-Null
    [IO.File]::WriteAllText("$cleanupTx/0-old/old.txt",'old version')
    @{state='pending';action='cleanup';package='oldpkg';candidates=@(@{version='old';from="$rootG/apps/oldpkg";
        trash="$cleanupTx/0-old";moved=$true;recovery=$false})} |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$cleanupTx/journal.json" -Encoding utf8
    $cleanupRecovered = & $CoopExe --root $rootG recover --json
    $cleanupEntry = @($cleanupRecovered | ConvertFrom-Json)[0]
    if ($LASTEXITCODE -ne 0 -or $cleanupEntry.action -ne 'cleanup' -or $cleanupEntry.mode -ne 'automatic' -or
        $cleanupEntry.status -ne 'committed' -or (Test-Path -LiteralPath "$cleanupTx/0-old") -or
        (Get-Content -LiteralPath "$cleanupTx/journal.json" -Raw | ConvertFrom-Json).state -ne 'committed') {
        throw "Cleanup journal was not recovered through the shared command: $cleanupRecovered"
    }

    @{root=$root; fresh_root=$rootB; publication_root=$rootC; script_root=$rootD; manual_root=$rootE;
      adopt_journal_root=$rootF; cleanup_journal_root=$rootG;
      interrupted_update_journal=$journalPath; recovery_mode='automatic-and-manual';
      actual_process_interruptions=2; simulated_publication_stage=$true} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sessionRoot 'recovery-evidence.json') -Encoding utf8
    Write-Output "PASS interruption, concurrent writer, published-state query, automatic/manual recovery: $sessionRoot/recovery-evidence.json"
    exit 0
} catch {
    Write-Error ("recovery test failed: "+$_)
    exit 1
}

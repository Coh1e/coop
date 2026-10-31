param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# R16 / #37: cross-mechanism interruption, confirmed-change rollback and conflict diagnosis.
# The seam is the real coop CLI executing real archive extraction, persistence, entries,
# current-user environment, lifecycle hooks, declared installer programs and a real MSI image.
# A failure or a true process crash is injected at a named execution stage through the
# engineering-only test fault file (.coop/test-faults.json plus COOP_ALLOW_TEST_FAULTS=1), so the
# observed journal, rollback and pending state are the product's own code paths. The test also
# changes files and registry values as a later user/Scoop operation would, then checks that
# recovery diagnoses the conflict instead of deleting or overwriting it.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$coopDirectory = Split-Path $CoopExe
$sessionRoot = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sessionRoot -Force | Out-Null
New-Item -ItemType Directory -Path "$sessionRoot/temp" -Force | Out-Null
$fixture1 = Join-Path $coopDirectory 'fixture-1.exe'
$fixture2 = Join-Path $coopDirectory 'fixture-2.exe'
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
foreach ($path in @($fixture1,$fixture2)) { if (-not (Test-Path -LiteralPath $path)) { throw "Missing fixed test input: $path" } }
$script:checks = 0

function Check([bool]$condition,[string]$message) {
    if (-not $condition) { throw "recovery matrix check failed: $message" }
    ++$script:checks
}
function File-Hash([string]$path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
}
function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
function New-Root([string]$name) {
    $root = Join-Path $sessionRoot $name
    New-Item -ItemType Directory -Path "$root/buckets/test/bucket","$root/temp" -Force | Out-Null
    return $root
}
function Write-Manifest([string]$root,[string]$package,[hashtable]$manifest) {
    $json = $manifest | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText("$root/buckets/test/bucket/$package.json",$json,[Text.UTF8Encoding]::new($false))
}
function New-Payload([string]$root,[string]$name,[hashtable]$files) {
    $stage = "$root/build-$name"
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($entry in $files.GetEnumerator()) {
        $target = Join-Path $stage $entry.Key
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        if ($entry.Value -is [byte[]]) { [IO.File]::WriteAllBytes($target,$entry.Value) }
        else { [IO.File]::WriteAllText($target,([string]$entry.Value).Replace("`r`n","`n").Replace("`n","`r`n"),[Text.UTF8Encoding]::new($false)) }
    }
    $zip = "$root/build-$name.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($stage,$zip)
    return $zip
}
function Invoke-Coop([string]$label,[string]$root,[string[]]$arguments,[hashtable]$environment = @{}) {
    $start = [Diagnostics.ProcessStartInfo]::new($CoopExe)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $root
    foreach ($argument in @('--root',$root)+$arguments) { Add-ProcessArgument $start ($argument) }
    $start.EnvironmentVariables['TEMP'] = "$root/temp"
    $start.EnvironmentVariables['TMP'] = "$root/temp"
    # Two-key engineering switch: the environment token enables reading an existing fault file.
    $start.EnvironmentVariables['COOP_ALLOW_TEST_FAULTS'] = '1'
    foreach ($key in $environment.Keys) { $start.EnvironmentVariables[$key] = $environment[$key] }
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(600000)) { $process.Kill(); throw "$label timed out" }
    $result = @{exit=$process.ExitCode;output=$stdout.GetAwaiter().GetResult();error=$stderr.GetAwaiter().GetResult()}
    $process.Dispose()
    Set-Content -LiteralPath "$root/run-$label.json" -Value ($result | ConvertTo-Json -Depth 5) -Encoding utf8
    return $result
}
function Coop-Json([string]$label,[string]$root,[string[]]$arguments,[hashtable]$environment = @{}) {
    $result = Invoke-Coop $label $root $arguments $environment
    if ($result.exit -ne 0) { throw "$label failed (exit $($result.exit)): $($result.error)$($result.output)" }
    return ($result.output | ConvertFrom-Json)
}
function Use-Fault([string]$root,[ValidateSet('crash','fail')][string]$mode,[string]$stage) {
    New-Item -ItemType Directory -Path "$root/.coop" -Force | Out-Null
    @{ $mode = @($stage) } | ConvertTo-Json | Set-Content -LiteralPath "$root/.coop/test-faults.json" -Encoding utf8
}
function Clear-Fault([string]$root) {
    Remove-Item -LiteralPath "$root/.coop/test-faults.json" -Force -ErrorAction SilentlyContinue
}
function Pending-Journals([string]$root) {
    if (-not (Test-Path -LiteralPath "$root/.coop/transactions")) { return @() }
    return @(Get-ChildItem -LiteralPath "$root/.coop/transactions" -Recurse -Filter journal.json |
        ForEach-Object { [pscustomobject]@{Path=$_.FullName;Value=(Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json)} } |
        Where-Object { $_.Value.state -eq 'pending' })
}
function Single-Pending([string]$root,[string]$action) {
    $pending = @(Pending-Journals $root)
    if ($pending.Count -ne 1) { throw "Expected one pending transaction, found $($pending.Count)" }
    if ($pending[0].Value.action -ne $action) { throw "Pending transaction is $($pending[0].Value.action), expected $action" }
    return $pending[0]
}
function List-Entry([string]$root,[string]$name) {
    $items = @(Coop-Json "list-$name" $root @('list','--json'))
    return @($items | Where-Object { $_.name -eq $name })
}
function Assert-Runs([string]$label,[string]$executable,[string]$expected) {
    if (-not (Test-Path -LiteralPath $executable)) { throw "${label}: entry $executable is missing" }
    $output = (Invoke-CoopNative $executable ) | Out-String
    Check ($LASTEXITCODE -eq 0) "$label did not exit successfully: $output"
    Check ($output.Trim() -eq $expected) "${label} printed '$($output.Trim())' instead of '$expected'"
}
function Read-Value([string]$path) { if (Test-Path -LiteralPath $path) { return (Get-Content -LiteralPath $path -Raw) } return '' }
function Line-Count([string]$path) { if (-not (Test-Path -LiteralPath $path)) { return 0 }; return @(Get-Content -LiteralPath $path).Count }

# Registry helpers for the one real current-user environment value this test writes. Every value
# is snapshotted before the test and restored in the finally block.
function Get-UserRaw([string]$name) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    if ($null -eq $key) { throw 'HKCU\Environment is missing' }
    try {
        if (@($key.GetValueNames()) -notcontains $name) { return [pscustomobject]@{present=$false;value=$null;kind=$null} }
        return [pscustomobject]@{present=$true;
            value=[string]$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);
            kind=$key.GetValueKind($name).ToString()}
    } finally { $key.Dispose() }
}
function Set-UserRaw([string]$name,$snapshot) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$true)
    if ($null -eq $key) { throw 'HKCU\Environment is missing' }
    try {
        if ($snapshot.present) { $key.SetValue($name,$snapshot.value,[Microsoft.Win32.RegistryValueKind]$snapshot.kind) }
        else { $key.DeleteValue($name,$false) }
    } finally { $key.Dispose() }
}
function Invoke-UserChange([string]$name,[string]$value) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$true)
    try { $key.SetValue($name,$value,[Microsoft.Win32.RegistryValueKind]::String) } finally { $key.Dispose() }
}

$envNames = @('COOP_R16_FLAG')
$envSnapshots = @{}
foreach ($name in $envNames) { $envSnapshots[$name] = Get-UserRaw $name }
$jsonRoots = @{}
try {
    # ----------------------------------------------------------------------------------------
    # A. Archive version publication crash, post-crash external replacement conflict, retry.
    # ----------------------------------------------------------------------------------------
    $rootA = New-Root 'archive'
    $zipA1 = New-Payload $rootA 'a1' @{'app.exe'=[IO.File]::ReadAllBytes($fixture1);'config'="owner data one`n"}
    $zipA2 = New-Payload $rootA 'a2' @{'app.exe'=[IO.File]::ReadAllBytes($fixture2)}
    Write-Manifest $rootA 'matfixture' @{version='1';url=(File-Uri $zipA1);hash=(File-Hash $zipA1);
        bin='app.exe';persist=@('config')}
    Coop-Json 'a-install-1' $rootA @('install','test/matfixture','--json') | Out-Null
    Assert-Runs 'A initial install' "$rootA/shims/app.exe" 'fixture 1'
    [IO.File]::WriteAllText("$rootA/persist/matfixture/config",'user owns this config')
    $storeHash = File-Hash "$rootA/persist/matfixture/config"
    Write-Manifest $rootA 'matfixture' @{version='2';url=(File-Uri $zipA2);hash=(File-Hash $zipA2);
        bin='app.exe';persist=@('config')}

    Use-Fault $rootA 'crash' 'after-version-publish'
    $crashA = Invoke-Coop 'a-update-crash' $rootA @('update','matfixture','--json')
    Clear-Fault $rootA
    Check ($crashA.exit -ne 0) 'A crashing update reported success'
    $pendingA = Single-Pending $rootA 'update'
    Check (Test-Path -LiteralPath "$rootA/apps/matfixture/2") 'A crash did not publish the prepared version before interruption'
    Check (@($pendingA.Value.created | Where-Object { $_.path -like '*matfixture\2' -and $_.owned -eq $true -and $null -ne $_.evidence.file_identity }).Count -eq 1) 'A journal did not record created-object identity evidence'
    Check ($pendingA.Value.created[0].evidence.kind -eq 'directory') 'A journal recorded the wrong evidence kind for the version directory'
    # The plan removes the old current link and entries before publishing the new version, so
    # during this pending publication the old version directory and record remain the facts but
    # the entries are staged in the transaction until recovery restores them.
    Check (Test-Path -LiteralPath "$rootA/apps/matfixture/1/app.exe") 'A crash lost the current version directory'
    Check (@($pendingA.Value.moves | Where-Object { $_.from -like '*shims\app.exe' -and $_.moved -eq $true }).Count -eq 1) 'A journal did not record the moved old entry'
    $duringA = @(List-Entry $rootA 'matfixture')
    Check ($duringA.Count -eq 1 -and $duringA[0].version -eq '1' -and $duringA[0].last_operation -eq 'pending-recovery') 'A query did not read the last committed version during the pending update'
    $retryA = Invoke-Coop 'a-update-blocked' $rootA @('update','matfixture','--json')
    Check ($retryA.exit -ne 0 -and ($retryA.error+$retryA.output) -match 'Pending transaction requires recovery|No usable local current installation') 'A pending update was silently ignored by a second write'

    $journalHash = File-Hash $pendingA.Path
    $dryA = Coop-Json 'a-dry' $rootA @('recover','--dry-run','--json')
    Check ($dryA[0].mode -eq 'automatic' -and $dryA[0].status -eq 'recoverable') 'A dry run did not classify the transaction as recoverable'
    Check ($dryA[0].ownership_evidence -eq 'created-object-identity-recorded') 'A dry run did not report the recorded ownership evidence'
    Check (@($dryA[0].actions | Where-Object kind -eq 'remove').Count -eq 1) 'A dry run did not plan the prepared version removal'
    Check (@($dryA[0].actions | Where-Object kind -eq 'restore').Count -ge 2) 'A dry run did not plan to restore the staged current link and entries'
    Check ((File-Hash $pendingA.Path) -eq $journalHash) 'A recovery preview changed the journal'

    # External client replaces the prepared version directory after Coop crashed.
    Remove-Item -LiteralPath "$rootA/apps/matfixture/2" -Recurse -Force
    New-Item -ItemType Directory -Path "$rootA/apps/matfixture/2" -Force | Out-Null
    [IO.File]::WriteAllText("$rootA/apps/matfixture/2/foreign.txt",'another client owns this directory')
    $conflictA = Invoke-Coop 'a-conflict' $rootA @('recover','--json')
    $conflictAJson = $conflictA.output | ConvertFrom-Json
    Check ($conflictA.exit -ne 0 -and $conflictAJson.mode -eq 'manual' -and $conflictAJson.status -eq 'manual') 'A replaced version directory was not diagnosed as manual'
    Check (@($conflictAJson.conflicts | Where-Object { $_.code -eq 'created-path-replaced' }).Count -eq 1) 'A did not report the created-path-replaced conflict code'
    Check ((Read-Value "$rootA/apps/matfixture/2/foreign.txt") -eq 'another client owns this directory') 'A removed or overwrote the externally created version directory'
    Check ((Get-Content -LiteralPath $pendingA.Path -Raw | ConvertFrom-Json).state -eq 'pending') 'A conflict resolved a pending journal silently'
    Check (-not (Test-Path -LiteralPath "$rootA/shims/app.exe")) 'A conflict restored entries without human resolution'

    Remove-Item -LiteralPath "$rootA/apps/matfixture/2" -Recurse -Force
    $recoveredA = Coop-Json 'a-recover' $rootA @('recover','--json')
    Check ($recoveredA[0].status -eq 'recovered' -and -not (Test-Path -LiteralPath "$rootA/apps/matfixture/2")) 'A recovery did not remove the confirmed Coop-created version'
    Check ((Get-Content -LiteralPath $pendingA.Path -Raw | ConvertFrom-Json).state -eq 'rolled-back') 'A resolved journal was not marked rolled-back'
    Assert-Runs 'A current program after recovery' "$rootA/shims/app.exe" 'fixture 1'
    Check ((File-Hash "$rootA/persist/matfixture/config") -eq $storeHash) 'A recovery moved or rewrote persistent data'
    $retryA2 = Coop-Json 'a-retry' $rootA @('update','matfixture','--json')
    Assert-Runs 'A retried update' "$rootA/shims/app.exe" 'fixture 2'
    Check (Test-Path -LiteralPath "$rootA/apps/matfixture/1") 'A retried update did not retain the previous version'
    Check ($retryA2.status -eq 'success') 'A retried update did not report success'

    # Extraction-stage failure keeps the current version and discards only staging state.
    $zipA3 = New-Payload $rootA 'a3' @{'app.exe'=[IO.File]::ReadAllBytes($fixture1)}
    Write-Manifest $rootA 'matfixture' @{version='3';url=(File-Uri $zipA3);hash=(File-Hash $zipA3);
        bin='app.exe';persist=@('config')}
    Use-Fault $rootA 'crash' 'after-extract'
    $extractA = Invoke-Coop 'a-extract-crash' $rootA @('update','matfixture','--json')
    Clear-Fault $rootA
    Check ($extractA.exit -ne 0) 'A extraction crash reported success'
    Assert-Runs 'A current program after extraction crash' "$rootA/shims/app.exe" 'fixture 2'
    $extractPending = @(Pending-Journals $rootA)
    Check ($extractPending.Count -eq 1 -and @($extractPending[0].Value.created).Count -eq 0) 'A extraction crash left published state in the journal'
    $extractDry = Coop-Json 'a-extract-dry' $rootA @('recover','--dry-run','--json')
    Check ($extractDry[0].status -eq 'recoverable' -and @($extractDry[0].actions).Count -eq 0) 'A extraction-only transaction was not classified as a discardable preparation'
    $extractRecovered = Coop-Json 'a-extract-recover' $rootA @('recover','--json')
    Check ($extractRecovered[0].status -eq 'recovered') 'A extraction-only recovery failed'
    Assert-Runs 'A current program after extraction recovery' "$rootA/shims/app.exe" 'fixture 2'

    # ----------------------------------------------------------------------------------------
    # B. Entry and user-environment stages, including a later user change during recovery.
    # ----------------------------------------------------------------------------------------
    $rootB = New-Root 'entries-environment'
    $zipB1 = New-Payload $rootB 'b1' @{'one.exe'=[IO.File]::ReadAllBytes($fixture1);'two.exe'=[IO.File]::ReadAllBytes($fixture1)}
    $zipB2 = New-Payload $rootB 'b2' @{'one.exe'=[IO.File]::ReadAllBytes($fixture2);'two.exe'=[IO.File]::ReadAllBytes($fixture2)}
    Write-Manifest $rootB 'envfixture' @{version='1';url=(File-Uri $zipB1);hash=(File-Hash $zipB1);
        bin=@('one.exe','two.exe');env_set=@{COOP_R16_FLAG='env-1'}}
    Coop-Json 'b-install-1' $rootB @('install','test/envfixture','--json') | Out-Null
    Write-Manifest $rootB 'envfixture' @{version='2';url=(File-Uri $zipB2);hash=(File-Hash $zipB2);
        bin=@('one.exe','two.exe');env_set=@{COOP_R16_FLAG='env-2'}}
    Check ((Get-UserRaw 'COOP_R16_FLAG').value -eq 'env-1') 'B install did not publish the declared user environment value'
    Assert-Runs 'B initial entry one' "$rootB/shims/one.exe" 'fixture 1'
    Assert-Runs 'B initial entry two' "$rootB/shims/two.exe" 'fixture 1'

    Use-Fault $rootB 'fail' 'after-entry'
    $entryFail = Invoke-Coop 'b-entry-fail' $rootB @('update','envfixture','--json')
    Clear-Fault $rootB
    Check ($entryFail.exit -ne 0) 'B injected entry failure reported success'
    $entryJournal = @(Get-ChildItem -LiteralPath "$rootB/.coop/transactions" -Recurse -Filter journal.json |
        Sort-Object LastWriteTime |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } |
        Where-Object { $_.package -eq 'envfixture' -and $_.state -eq 'rolled-back' }) | Select-Object -Last 1
    Check ($entryJournal.state -eq 'rolled-back') 'B in-process entry failure did not roll back its journal'
    Check (-not (Test-Path -LiteralPath "$rootB/apps/envfixture/2")) 'B in-process entry failure left the new version published'
    Assert-Runs 'B entry one after rollback' "$rootB/shims/one.exe" 'fixture 1'
    Assert-Runs 'B entry two after rollback' "$rootB/shims/two.exe" 'fixture 1'
    Check ((Get-UserRaw 'COOP_R16_FLAG').value -eq 'env-1') 'B in-process entry failure changed the user environment'

    Use-Fault $rootB 'crash' 'after-environment'
    $envCrash = Invoke-Coop 'b-environment-crash' $rootB @('update','envfixture','--json')
    Clear-Fault $rootB
    Check ($envCrash.exit -ne 0) 'B environment crash reported success'
    $pendingB = Single-Pending $rootB 'update'
    Check (@($pendingB.Value.environment_undo).Count -ge 1) 'B journal did not persist the environment undo evidence'
    Check ((Get-UserRaw 'COOP_R16_FLAG').value -eq 'env-2') 'B crash did not leave the environment write the test wants to recover'
    $envDry = Coop-Json 'b-environment-dry' $rootB @('recover','--dry-run','--json')
    Check ($envDry[0].status -eq 'recoverable') 'B environment dry run did not classify the transaction as recoverable'
    Check (@($envDry[0].environment_rollback_preview | Where-Object { $_.status -eq 'would-restore' }).Count -ge 1) 'B environment preview did not name the value it would restore'
    Check ((Get-UserRaw 'COOP_R16_FLAG').value -eq 'env-2') 'B environment preview changed the user value'
    $envRecovered = Coop-Json 'b-environment-recover' $rootB @('recover','--json')
    Check ($envRecovered[0].status -eq 'recovered') 'B environment recovery did not report a plain recovered state'
    Check ((Get-UserRaw 'COOP_R16_FLAG').value -eq 'env-1') 'B recovery did not restore the previous user environment value'
    Assert-Runs 'B entry one after environment recovery' "$rootB/shims/one.exe" 'fixture 1'

    # The user changes the value after the crash; recovery keeps it and diagnoses the conflict.
    Use-Fault $rootB 'crash' 'after-environment'
    $envCrash2 = Invoke-Coop 'b-environment-crash-2' $rootB @('update','envfixture','--json')
    Clear-Fault $rootB
    Check ($envCrash2.exit -ne 0) 'B second environment crash reported success'
    Single-Pending $rootB 'update' | Out-Null
    Invoke-UserChange 'COOP_R16_FLAG' 'changed-by-user'
    $envUser = Coop-Json 'b-environment-user' $rootB @('recover','--json')
    Check ($envUser[0].status -eq 'recovered-with-user-changes') 'B recovery did not report the preserved user environment value'
    Check (@($envUser[0].conflicts | Where-Object { $_.code -eq 'environment-value-modified' }).Count -eq 1) 'B recovery did not diagnose the changed environment value'
    Check ((Get-UserRaw 'COOP_R16_FLAG').value -eq 'changed-by-user') 'B recovery overwrote a newer user environment value'
    Set-UserRaw 'COOP_R16_FLAG' $envSnapshots['COOP_R16_FLAG']

    # ----------------------------------------------------------------------------------------
    # C. Hook and declared installer-program stages are never replayed and keep their evidence.
    # ----------------------------------------------------------------------------------------
    $rootC = New-Root 'scripts-installers'
    $hookMarker = Join-Path $rootC 'hook-runs.txt'
    $installerMarker = Join-Path $rootC 'installer-runs.txt'
    $setupCmd = @"
@echo off
>> "%COOP_R16_INSTALLER_MARKER%" echo installer
exit /b 0
"@
    $zipC1 = New-Payload $rootC 'c1' @{'app.exe'=[IO.File]::ReadAllBytes($fixture1);'setup.cmd'=$setupCmd}
    $zipC2 = New-Payload $rootC 'c2' @{'app.exe'=[IO.File]::ReadAllBytes($fixture2);'setup.cmd'=$setupCmd}
    $hookText = "Add-Content -LiteralPath '"+$hookMarker+"' -Value ('hook ' + `$version)"
    Write-Manifest $rootC 'hookfixture' @{version='1';url=(File-Uri $zipC1);hash=(File-Hash $zipC1);
        bin='app.exe';installer=@{file='setup.cmd'};post_install=$hookText}
    $installerEnv = @{COOP_R16_INSTALLER_MARKER=$installerMarker}
    $installC = Invoke-Coop 'c-install-1' $rootC @('install','test/hookfixture','--json') $installerEnv
    Check ($installC.exit -eq 0) "C initial install failed: $($installC.error)"
    Check ((Line-Count $installerMarker) -eq 1) 'C declared installer program did not run exactly once'
    Check ((Line-Count $hookMarker) -eq 1) 'C post_install hook did not run exactly once'
    Assert-Runs 'C initial program' "$rootC/shims/app.exe" 'fixture 1'
    Write-Manifest $rootC 'hookfixture' @{version='2';url=(File-Uri $zipC2);hash=(File-Hash $zipC2);
        bin='app.exe';installer=@{file='setup.cmd'};post_install=$hookText}

    Use-Fault $rootC 'crash' 'after-script:post_install'
    $hookCrash = Invoke-Coop 'c-hook-crash' $rootC @('update','hookfixture','--json') $installerEnv
    Clear-Fault $rootC
    Check ($hookCrash.exit -ne 0) 'C hook crash reported success'
    $pendingC = Single-Pending $rootC 'update'
    Check ((Line-Count $hookMarker) -eq 2) 'C hook did not run before the injected interruption'
    $hookRecovered = Coop-Json 'c-hook-recover' $rootC @('recover','--json')
    Check ($hookRecovered[0].status -eq 'recovered-with-unknown-script-effects') 'C script recovery did not admit unknown external effects'
    Check ($hookRecovered[0].external_side_effects -match 'not re-run') 'C script recovery did not state that hooks are not re-run'
    Check ($hookRecovered[0].transaction_evidence_retained -eq (Split-Path $pendingC.Path -Parent)) 'C script recovery did not retain the transaction evidence directory'
    Check ((Line-Count $hookMarker) -eq 2) 'C recovery re-ran a hook'
    Check (Test-Path -LiteralPath (Join-Path (Split-Path $pendingC.Path -Parent) 'journal.json')) 'C script evidence journal disappeared'
    Assert-Runs 'C program after hook recovery' "$rootC/shims/app.exe" 'fixture 1'

    Use-Fault $rootC 'crash' 'after-installer'
    $installerCrash = Invoke-Coop 'c-installer-crash' $rootC @('update','hookfixture','--json') $installerEnv
    Clear-Fault $rootC
    Check ($installerCrash.exit -ne 0) 'C installer crash reported success'
    $pendingC2 = Single-Pending $rootC 'update'
    Check ((Line-Count $installerMarker) -eq 3) 'C declared installer program did not run before the injected interruption'
    $installerRecovered = Coop-Json 'c-installer-recover' $rootC @('recover','--json')
    Check ($installerRecovered[0].status -eq 'recovered-with-unknown-script-effects') 'C installer-program recovery did not admit unknown external effects'
    Check ($installerRecovered[0].installer_programs_started -eq $true) 'C installer-program recovery did not report the program evidence'
    Check ((Line-Count $installerMarker) -eq 3) 'C recovery re-ran a declared installer program'
    Assert-Runs 'C program after installer recovery' "$rootC/shims/app.exe" 'fixture 1'

    $updateC = Invoke-Coop 'c-update' $rootC @('update','hookfixture','--json') $installerEnv
    Check ($updateC.exit -eq 0) "C clean retry after recoveries failed: $($updateC.error)"
    Check ((Line-Count $installerMarker) -eq 4) 'C clean retry did not run the installer program exactly once'
    Check ((Line-Count $hookMarker) -eq 3) 'C clean retry did not run the hook exactly once'
    Assert-Runs 'C updated program' "$rootC/shims/app.exe" 'fixture 2'

    # In-process failure after the installer program ran rolls back paths only.
    $zipC3 = New-Payload $rootC 'c3' @{'app.exe'=[IO.File]::ReadAllBytes($fixture1);'setup.cmd'=$setupCmd}
    Write-Manifest $rootC 'hookfixture' @{version='3';url=(File-Uri $zipC3);hash=(File-Hash $zipC3);
        bin='app.exe';installer=@{file='setup.cmd'};post_install=$hookText}
    Use-Fault $rootC 'fail' 'after-installer'
    $installerFail = Invoke-Coop 'c-installer-fail' $rootC @('update','hookfixture','--json') $installerEnv
    Clear-Fault $rootC
    Check ($installerFail.exit -ne 0) 'C injected installer failure reported success'
    Check ((Line-Count $installerMarker) -eq 5) 'C injected installer failure did not happen after the real program ran'
    Assert-Runs 'C program after in-process installer failure' "$rootC/shims/app.exe" 'fixture 2'

    # ----------------------------------------------------------------------------------------
    # D. A real MSI image: extraction stage interruption and retry.
    # ----------------------------------------------------------------------------------------
    $msi2605 = Join-Path $archives '7z2605-x64.msi'
    $msi2603 = Join-Path $archives '7z2603-x64.msi'
    if ((Test-Path -LiteralPath $msi2605) -and (Test-Path -LiteralPath $msi2603)) {
        $rootD = New-Root 'msi'
        Write-Manifest $rootD 'seven' @{version='26.05';url=(File-Uri $msi2605);hash=(File-Hash $msi2605);
            extract_dir='Files\7-Zip';bin='7z.exe'}
        Coop-Json 'd-install' $rootD @('install','test/seven','--json') | Out-Null
        $v2605 = (Invoke-CoopNative "$rootD/apps/seven/current/7z.exe" ) | Out-String
        Check ($v2605 -match '26\.05') 'D real MSI install did not produce a runnable 26.05 program'
        Write-Manifest $rootD 'seven' @{version='26.03';url=(File-Uri $msi2603);hash=(File-Hash $msi2603);
            extract_dir='Files\7-Zip';bin='7z.exe'}
        Use-Fault $rootD 'crash' 'after-extract'
        $msiCrash = Invoke-Coop 'd-msi-crash' $rootD @('update','seven','--json')
        Clear-Fault $rootD
        Check ($msiCrash.exit -ne 0) 'D MSI extraction crash reported success'
        $pendingD = Single-Pending $rootD 'update'
        Check (@($pendingD.Value.msi_extractions).Count -eq 1) 'D journal did not record the real MSI extraction'
        $msiDuring = (Invoke-CoopNative "$rootD/apps/seven/current/7z.exe" ) | Out-String
        Check ($msiDuring -match '26\.05') 'D current MSI program stopped working during the pending update'
        $msiDry = Coop-Json 'd-msi-dry' $rootD @('recover','--dry-run','--json')
        Check ($msiDry[0].status -eq 'recoverable' -and @($msiDry[0].actions).Count -eq 0) 'D MSI staging-only transaction was not discardable'
        $msiRecovered = Coop-Json 'd-msi-recover' $rootD @('recover','--json')
        Check ($msiRecovered[0].status -eq 'recovered') 'D MSI staging recovery failed'
        $msiAfter = (Invoke-CoopNative "$rootD/apps/seven/current/7z.exe" ) | Out-String
        Check ($msiAfter -match '26\.05') 'D recovery changed the current MSI program'
        Coop-Json 'd-msi-retry' $rootD @('update','seven','--json') | Out-Null
        $msiUpdated = (Invoke-CoopNative "$rootD/apps/seven/current/7z.exe" ) | Out-String
        Check ($msiUpdated -match '26\.03') 'D retried MSI update did not publish 26.03'
    } else {
        throw "Missing real MSI artifacts in $archives; run scripts/fetch-deps.ps1"
    }

    # ----------------------------------------------------------------------------------------
    # E. Real Inno Setup payload: extraction-stage crash, retry.
    # ----------------------------------------------------------------------------------------
    $units227 = Join-Path $archives 'units-2.27-setup.exe'
    $units226 = Join-Path $archives 'units-2.26-setup.exe'
    $innounpArchive = Join-Path $archives 'innounp-2.zip'
    if ((Test-Path -LiteralPath $units227) -and (Test-Path -LiteralPath $units226) -and (Test-Path -LiteralPath $innounpArchive)) {
        $rootE = New-Root 'inno'
        # The innounp helper is a normal shared package in this root, provisioned from its pinned
        # Scoop archive exactly as inno-lifecycle.ps1 does; Coop never downloads or ships it.
        New-Item -ItemType Directory -Path "$rootE/apps/innounp/current" -Force | Out-Null
        [IO.Compression.ZipFile]::ExtractToDirectory($innounpArchive,"$rootE/apps/innounp/current")
        @{version='2.71.2';description='Inno Setup Unpacker (Unicode)';url=(File-Uri $innounpArchive);
          hash=(File-Hash $innounpArchive);bin='innounp.exe'} | ConvertTo-Json -Depth 6 |
            Set-Content -LiteralPath "$rootE/apps/innounp/current/scoop-manifest.json" -Encoding utf8
        @{architecture='64bit';bucket='main'} | ConvertTo-Json |
            Set-Content -LiteralPath "$rootE/apps/innounp/current/scoop-install.json" -Encoding utf8
        Write-Manifest $rootE 'units' @{version='2.27';url=(File-Uri $units227);hash=(File-Hash $units227);
            innosetup=$true;bin='units.exe';persist='settings'}
        Coop-Json 'e-inno-install' $rootE @('install','test/units','--json') | Out-Null
        $innoV227 = (Invoke-CoopNative "$rootE/apps/units/current/units.exe"  --version) | Out-String
        Check ($innoV227 -match '2\.27') 'E real Inno install did not produce a runnable 2.27 program'
        Write-Manifest $rootE 'units' @{version='2.26';url=(File-Uri $units226);hash=(File-Hash $units226);
            innosetup=$true;bin='units.exe';persist='settings'}
        Use-Fault $rootE 'crash' 'after-extract'
        $innoCrash = Invoke-Coop 'e-inno-crash' $rootE @('update','units','--json')
        Clear-Fault $rootE
        Check ($innoCrash.exit -ne 0) 'E Inno extraction crash reported success'
        $pendingInno = Single-Pending $rootE 'update'
        Check (@($pendingInno.Value.inno_extractions).Count -eq 1) 'E journal did not record the real Inno extraction'
        $innoDuring = (Invoke-CoopNative "$rootE/apps/units/current/units.exe"  --version) | Out-String
        Check ($innoDuring -match '2\.27') 'E current Inno program stopped working during the pending update'
        $innoRecovered = Coop-Json 'e-inno-recover' $rootE @('recover','--json')
        Check ($innoRecovered[0].status -eq 'recovered') 'E Inno staging recovery failed'
        $innoAfter = (Invoke-CoopNative "$rootE/apps/units/current/units.exe"  --version) | Out-String
        Check ($innoAfter -match '2\.27') 'E Inno recovery changed the current program'
        Coop-Json 'e-inno-retry' $rootE @('update','units','--json') | Out-Null
        $innoUpdated = (Invoke-CoopNative "$rootE/apps/units/current/units.exe"  --version) | Out-String
        Check ($innoUpdated -match '2\.26') 'E retried Inno update did not publish 2.26'
    } else {
        throw "Missing Inno artifacts in $archives; run scripts/fetch-deps.ps1"
    }

    # ----------------------------------------------------------------------------------------
    # F. Real NSIS payload: extraction-stage crash with the 7-Zip helper, retry.
    # ----------------------------------------------------------------------------------------
    $apng311 = Join-Path $archives 'apngasm-3.1.1-AMD64.exe'
    $apng313 = Join-Path $archives 'apngasm-3.1.3-AMD64.exe'
    if ((Test-Path -LiteralPath $apng311) -and (Test-Path -LiteralPath $apng313) -and (Test-Path -LiteralPath $msi2605)) {
        $rootF = New-Root 'nsis'
        Write-Manifest $rootF '7zip' @{version='26.05';url=(File-Uri $msi2605);hash=(File-Hash $msi2605);
            extract_dir='Files\7-Zip';bin=@('7z.exe')}
        Coop-Json 'f-helper-install' $rootF @('install','test/7zip','--json') | Out-Null
        Check (Test-Path -LiteralPath "$rootF/apps/7zip/current/7z.exe") 'F 7-Zip helper was not published at the Scoop-compatible path'
        $preInstall = "'`$PLUGINSDIR', 'Uninstall.exe' | ForEach-Object { Remove-Item `"`$dir\`$_`" -Recurse -Force }"
        Write-Manifest $rootF 'apng' @{version='3.1.1';url=((File-Uri $apng311)+'#/dl.7z');hash=(File-Hash $apng311);
            pre_install=$preInstall;bin=@('bin\apngasm.exe',@('bin\apngasm.exe','apngasm-cli'))}
        Coop-Json 'f-nsis-install' $rootF @('install','test/apng','--json') | Out-Null
        $nsisV311 = (Invoke-CoopNative "$rootF/shims/apngasm.exe"  --version) | Out-String
        Check ($nsisV311 -match '3\.1\.1') 'F real NSIS install did not produce a runnable 3.1.1 program'
        Write-Manifest $rootF 'apng' @{version='3.1.3';url=((File-Uri $apng313)+'#/dl.7z');hash=(File-Hash $apng313);
            pre_install=$preInstall;bin=@('bin\apngasm.exe',@('bin\apngasm.exe','apngasm-cli'))}
        Use-Fault $rootF 'crash' 'after-extract'
        $nsisCrash = Invoke-Coop 'f-nsis-crash' $rootF @('update','apng','--json')
        Clear-Fault $rootF
        Check ($nsisCrash.exit -ne 0) 'F NSIS extraction crash reported success'
        $pendingNsis = Single-Pending $rootF 'update'
        Check (@($pendingNsis.Value.nsis_extractions).Count -eq 1) 'F journal did not record the real NSIS extraction'
        $nsisDuring = (Invoke-CoopNative "$rootF/shims/apngasm.exe"  --version) | Out-String
        Check ($nsisDuring -match '3\.1\.1') 'F current NSIS program stopped working during the pending update'
        $nsisRecovered = Coop-Json 'f-nsis-recover' $rootF @('recover','--json')
        Check ($nsisRecovered[0].status -in @('recovered','recovered-with-unknown-script-effects')) 'F NSIS staging recovery failed'
        $nsisAfter = (Invoke-CoopNative "$rootF/shims/apngasm.exe"  --version) | Out-String
        Check ($nsisAfter -match '3\.1\.1') 'F NSIS recovery changed the current program'
        Coop-Json 'f-nsis-retry' $rootF @('update','apng','--json') | Out-Null
        $nsisUpdated = (Invoke-CoopNative "$rootF/shims/apngasm.exe"  --version) | Out-String
        Check ($nsisUpdated -match '3\.1\.3') 'F retried NSIS update did not publish 3.1.3'
    } else {
        throw "Missing NSIS artifacts in $archives; run scripts/fetch-deps.ps1"
    }

    # ----------------------------------------------------------------------------------------
    # G. Created command entry replaced after the crash is a diagnosed conflict, not a deletion.
    # ----------------------------------------------------------------------------------------
    $rootG = New-Root 'entry-conflict'
    $zipE = New-Payload $rootG 'e1' @{'app.exe'=[IO.File]::ReadAllBytes($fixture1)}
    Write-Manifest $rootG 'entryfixture' @{version='1';url=(File-Uri $zipE);hash=(File-Hash $zipE);bin='app.exe'}
    Use-Fault $rootG 'crash' 'after-entry'
    $entryCrash = Invoke-Coop 'e-entry-crash' $rootG @('install','test/entryfixture','--json')
    Clear-Fault $rootG
    Check ($entryCrash.exit -ne 0) 'G crashing install reported success'
    $pendingG = Single-Pending $rootG 'install'
    $shimEntry = @($pendingG.Value.created | Where-Object { $_.path -like '*shims\app.exe' })
    Check ($shimEntry.Count -eq 1 -and $shimEntry[0].evidence.kind -eq 'file') 'G journal did not record the created shim identity and digest'
    [IO.File]::AppendAllText("$rootG/shims/app.exe",'external edit')
    $entryConflict = Invoke-Coop 'e-entry-conflict' $rootG @('recover','--json')
    $entryConflictJson = $entryConflict.output | ConvertFrom-Json
    Check ($entryConflict.exit -ne 0 -and $entryConflictJson.mode -eq 'manual') 'G modified created shim was not diagnosed as a manual conflict'
    Check (@($entryConflictJson.conflicts | Where-Object { $_.code -eq 'created-file-modified' }).Count -eq 1) 'G did not report the created-file-modified conflict code'
    Check (Test-Path -LiteralPath "$rootG/shims/app.exe") 'G recovery deleted or replaced the externally modified shim'
    Check (-not (Test-Path -LiteralPath "$rootG/.coop/packages/entryfixture.json")) 'G conflict unexpectedly published a management record'
    Remove-Item -LiteralPath "$rootG/shims/app.exe" -Force
    $entryRecovered = Coop-Json 'e-entry-recover' $rootG @('recover','--json')
    Check ($entryRecovered[0].status -eq 'recovered' -and -not (Test-Path -LiteralPath "$rootG/apps/entryfixture/1")) 'G recovery did not discard the confirmed Coop-created install state after the conflict was removed'

    $jsonRoots = [ordered]@{archive=$rootA;entries_environment=$rootB;scripts_installers=$rootC;msi=$rootD;
        inno=$rootE;nsis=$rootF;entry_conflict=$rootG}
    @{session_root=$sessionRoot;roots=$jsonRoots;checks=$script:checks;
      fault_stages=@('after-version-publish','after-extract','after-entry','after-environment','after-script:post_install','after-installer');
      crash_injections=10;failure_injections=2;real_artifacts=@($msi2605,$units227,$apng311);
      environment_values=@('COOP_R16_FLAG')} |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $sessionRoot 'recovery-matrix-evidence.json') -Encoding utf8
    Write-Output "PASS recovery matrix: $($script:checks) checks; evidence $sessionRoot/recovery-matrix-evidence.json"
    exit 0
} catch {
    Write-Error ("recovery matrix failed: "+$_)
    exit 1
} finally {
    foreach ($name in $envNames) { Set-UserRaw $name $envSnapshots[$name] }
}

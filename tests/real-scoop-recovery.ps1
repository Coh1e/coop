param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$EvidenceDir,
    [string]$ScoopRoot = 'C:\Users\Neo\scoop'
)
# R16 real shared-root acceptance. It creates one test package in a temporary bucket inside the
# human-selected Scoop root, alternates Coop and real Scoop on it, injects a real process crash
# and a real failure at named execution stages, and removes every object it created in the finally
# block. Existing installations, buckets, configuration, records and stores are not modified or
# deleted; recovery is always scoped to the test package.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
$allowed = [IO.Path]::GetFullPath((Join-Path $projectRoot '.local')).TrimEnd('\') + '\'
if (-not ($EvidenceDir.TrimEnd('\') + '\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence must stay inside the project .local directory' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$ScoopRoot = [IO.Path]::GetFullPath($ScoopRoot)
$scoop = (Get-Command scoop.ps1 -ErrorAction Stop).Source
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$commands = [System.Collections.Generic.List[object]]::new()
$package = 'coop-r16-fixture'
$bucketName = 'coop-r16-recovery'
$bucket = Join-Path $ScoopRoot "buckets/$bucketName"
$app = Join-Path $ScoopRoot "apps/$package"
$store = Join-Path $ScoopRoot "persist/$package"
$marker = Join-Path $ScoopRoot 'coop-r16-hook-marker.txt'
$faultFile = Join-Path $ScoopRoot '.coop/test-faults.json'
$fixture1 = Join-Path (Split-Path $CoopExe) 'fixture-1.exe'
$fixture2 = Join-Path (Split-Path $CoopExe) 'fixture-2.exe'
function Run([string]$name,[string]$exe,[string[]]$arguments,[string]$WorkingDirectory = '') {
    $log = Join-Path $EvidenceDir (($name -replace '[\\/:*?"<>|]','-')+'.log')
    $previous = (Get-Location).Path
    try {
        if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }
        $output = & $exe @arguments *>&1 | Out-String
        $exit = $LASTEXITCODE
    } finally { Set-Location -LiteralPath $previous }
    Set-Content -LiteralPath $log -Value $output -Encoding utf8
    $commands.Add([pscustomobject]@{name=$name;exe=$exe;arguments=$arguments;working_directory=$WorkingDirectory;exit=$exit;log=$log})
    return [pscustomobject]@{exit=$exit;output=$output;log=$log}
}
function Invoke-CoopFault([string]$name,[string[]]$arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($CoopExe)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $ScoopRoot
    foreach ($argument in @('--root',$ScoopRoot)+$arguments) { Add-ProcessArgument $start ($argument) }
    $start.EnvironmentVariables['COOP_ALLOW_TEST_FAULTS'] = '1'
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(600000)) { $process.Kill(); throw "$name timed out" }
    $output = $stdout.GetAwaiter().GetResult(); $errorText = $stderr.GetAwaiter().GetResult()
    $result = [pscustomobject]@{exit=$process.ExitCode;output=$output;error=$errorText}
    $process.Dispose()
    $log = Join-Path $EvidenceDir (($name -replace '[\\/:*?"<>|]','-')+'.log')
    Set-Content -LiteralPath $log -Value ($output+"`n"+$errorText) -Encoding utf8
    $commands.Add([pscustomobject]@{name=$name;exe=$CoopExe;arguments=(@('--root',$ScoopRoot)+$arguments);
        working_directory=$ScoopRoot;exit=$result.exit;log=$log})
    return $result
}
function Coop([string]$name,[string[]]$arguments) { return Run $name $CoopExe (@('--root',$ScoopRoot)+$arguments) }
function Scoop([string]$name,[string[]]$arguments) { return Run $name $scoop $arguments }
function Assert-True([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
function Read-Json([object]$output) {
    $text = ($output -join "`n")
    $start = $text.IndexOfAny([char[]]@('{','['))
    $end = $text.LastIndexOfAny([char[]]@('}',']'))
    if ($start -lt 0 -or $end -lt $start) { throw "No JSON document in output: $text" }
    return ($text.Substring($start,$end-$start+1) | ConvertFrom-Json)
}
function Save-Json([string]$name,$value) {
    $value | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $EvidenceDir $name) -Encoding utf8
}
function New-Payload([string]$version,[string]$source,[string]$destination) {
    $stage = Join-Path $EvidenceDir "payload-$version"
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    [IO.File]::Copy($source,(Join-Path $stage "$package.exe"))
    [IO.File]::Copy($source,(Join-Path $stage "$package-tool.exe"))
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($stage,$destination)
    return $destination
}
function Write-Manifest([string]$version,[string]$archive) {
    $value = @{version=$version;url=([Uri][IO.Path]::GetFullPath($archive)).AbsoluteUri;
        hash=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower();
        bin=@("$package.exe","$package-tool.exe");persist=@('config');
        post_install="Add-Content -LiteralPath '$marker' -Value ('hook ' + `$version)"}
    [IO.File]::WriteAllText((Join-Path $bucket "bucket/$package.json"),($value | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
function Set-Fault([ValidateSet('crash','fail')][string]$mode,[string]$stage) {
    New-Item -ItemType Directory -Path (Split-Path $faultFile -Parent) -Force | Out-Null
    @{ $mode = @($stage) } | ConvertTo-Json | Set-Content -LiteralPath $faultFile -Encoding utf8
}
function Clear-Fault { Remove-Item -LiteralPath $faultFile -Force -ErrorAction SilentlyContinue }
function CoopEntry([string]$name) {
    $items = (Coop ($name+'-list') @('list','--json')).output | ConvertFrom-Json
    return @($items | Where-Object { $_.name -eq $package })
}
function Pending-Journal {
    $journals = @(Get-ChildItem "$ScoopRoot/.coop/transactions" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $path = Join-Path $_.FullName 'journal.json'
        if (-not (Test-Path -LiteralPath $path)) { return }
        $value = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($value.state -eq 'pending' -and $value.package -eq $package) { [pscustomobject]@{Path=$path;Value=$value} }
    })
    Assert-True ($journals.Count -eq 1) "Expected one pending transaction for $package, found $($journals.Count)"
    return $journals[0]
}
function Hook-Lines { if (-not (Test-Path -LiteralPath $marker)) { return 0 }; return @(Get-Content -LiteralPath $marker).Count }

$summary = [ordered]@{scoop_root=$ScoopRoot;package=$package;bucket=$bucket;coop=$CoopExe;
    coop_version=(& $CoopExe --version);
    coop_sha256=(Get-FileHash -LiteralPath $CoopExe -Algorithm SHA256).Hash.ToLower();
    scoop_source=$scoop;scenarios=[ordered]@{}}
$installedBefore = $null
$created = $false
$faultFileExisted = Test-Path -LiteralPath $faultFile
$existingPendingBefore = @(Get-ChildItem "$ScoopRoot/.coop/transactions" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $path = Join-Path $_.FullName 'journal.json'
    if (Test-Path -LiteralPath $path) {
        $value = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($value.state -eq 'pending') { $path }
    }
})
try {
    Assert-True ((Test-Path -LiteralPath $scoop)) "Scoop was not found at $scoop"
    Assert-True (-not (Test-Path -LiteralPath $bucket)) "Temporary bucket already exists: $bucket"
    Assert-True (-not (Test-Path -LiteralPath $app)) "Test package already exists: $app"
    Assert-True (-not (Test-Path -LiteralPath $store)) "Test persist store already exists: $store"
    Assert-True (-not (Test-Path -LiteralPath $marker)) "Test hook marker already exists: $marker"
    Assert-True ($existingPendingBefore.Count -eq 0) "The real root already has pending transactions: $($existingPendingBefore -join ',')"
    $installedBefore = (Coop 'list-before' @('list','--json')).output | ConvertFrom-Json
    Save-Json 'installed-before.json' $installedBefore
    New-Item -ItemType Directory -Path (Join-Path $bucket 'bucket') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $store 'config') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $store 'config/settings.ini') -Value 'coop-r16-user-data' -NoNewline
    New-Payload '1' $fixture1 (Join-Path $EvidenceDir 'payload-v1.zip') | Out-Null
    New-Payload '2' $fixture2 (Join-Path $EvidenceDir 'payload-v2.zip') | Out-Null
    Write-Manifest '1' (Join-Path $EvidenceDir 'payload-v1.zip')
    $created = $true

    # --- 1. Coop installs v1 and Scoop continues to manage it. --------------------------------
    $install = Coop 'install-v1' @('install',"$bucketName/$package",'--json')
    Assert-True ($install.exit -eq 0) "Coop install failed: $($install.output)"
    $installed = Read-Json $install.output
    Assert-True ((& (Join-Path $ScoopRoot "shims/$package.exe")) -eq 'fixture 1') 'Coop v1 program did not run'
    Assert-True ((& (Join-Path $ScoopRoot "shims/$package-tool.exe")) -eq 'fixture 1') 'Coop v1 second entry did not run'
    Assert-True ((Hook-Lines) -eq 1) 'Coop install did not run the declared post_install hook exactly once'
    $scoopList = Scoop 'scoop-list-v1' @('list')
    Assert-True ($scoopList.exit -eq 0 -and $scoopList.output -match [regex]::Escape($package)) 'Scoop did not list the Coop-installed package'
    $scoopReset = Scoop 'scoop-reset-v1' @('reset',$package)
    Assert-True ($scoopReset.exit -eq 0) "Scoop reset v1 failed: $($scoopReset.output)"
    Assert-True ((& (Join-Path $ScoopRoot "shims/$package.exe")) -eq 'fixture 1') 'Scoop reset v1 did not keep the Coop version runnable'
    $storeHash = (Get-FileHash -LiteralPath (Join-Path $store 'config/settings.ini') -Algorithm SHA256).Hash
    $summary.scenarios.coop_install_then_scoop = @{version=$installed.version;hook_runs=(Hook-Lines);
        scoop_list_exit=$scoopList.exit;scoop_reset_exit=$scoopReset.exit;store_hash=$storeHash}

    # --- 2. Real update crash at the extraction stage; Scoop then resets; recovery discards the
    # preparation and the retried update completes for both clients. -----------------------------
    Write-Manifest '2' (Join-Path $EvidenceDir 'payload-v2.zip')
    Set-Fault 'crash' 'after-extract'
    $crash = Invoke-CoopFault 'update-crash' @('update',$package,'--json')
    Clear-Fault
    Assert-True ($crash.exit -eq -1073740791) "Injected real update crash did not terminate the process: exit $($crash.exit)"
    $pending = Pending-Journal
    Assert-True (@($pending.Value.created).Count -eq 0) 'Extraction-stage crash left published state in the journal'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $app '2'))) 'Extraction-stage crash published the target version'
    $during = CoopEntry 'during'
    Assert-True ($during.Count -eq 1 -and $during[0].version -eq '1' -and $during[0].last_operation -eq 'pending-recovery') "Coop query did not report v1 with pending recovery: $($during | ConvertTo-Json -Depth 8)"
    $scoopResetDuring = Scoop 'scoop-reset-during' @('reset',$package)
    Assert-True ($scoopResetDuring.exit -eq 0) "Scoop could not operate on the installed package after the Coop crash: $($scoopResetDuring.output)"
    Assert-True ((& (Join-Path $ScoopRoot "shims/$package.exe")) -eq 'fixture 1') 'Scoop reset after the Coop crash did not keep v1 runnable'
    Assert-True ((Hook-Lines) -eq 1) 'The interrupted update ran the v2 hook before the injected stage'
    $dry = Read-Json (Coop 'recover-dry' @('recover',$package,'--dry-run','--json')).output
    Assert-True ($dry[0].status -eq 'recoverable' -and @($dry[0].actions).Count -eq 0) 'The extraction-only transaction was not classified as a discardable preparation'
    $recovered = Coop 'recover-after-crash' @('recover',$package,'--json')
    Assert-True ($recovered.exit -eq 0) "Recovery after the real crash failed: $($recovered.output)"
    $recoveredJson = Read-Json $recovered.output
    Assert-True ($recoveredJson[0].status -eq 'recovered') 'Recovery did not report a recovered transaction'
    Assert-True ((& (Join-Path $ScoopRoot "shims/$package.exe")) -eq 'fixture 1') 'Recovery changed the Scoop-reset v1 program'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $store 'config/settings.ini') -Algorithm SHA256).Hash -eq $storeHash) 'Recovery changed stored persistent data'
    $retry = Coop 'update-retry' @('update',$package,'--json')
    Assert-True ($retry.exit -eq 0) "Update retry after recovery failed: $($retry.output)"
    Assert-True ((& (Join-Path $ScoopRoot "shims/$package.exe")) -eq 'fixture 2') 'Retried update did not publish v2'
    Assert-True ((Hook-Lines) -eq 2) 'Retried update did not run the v2 hook exactly once'
    $scoopResetV2 = Scoop 'scoop-reset-v2' @('reset',$package)
    Assert-True ($scoopResetV2.exit -eq 0) "Scoop reset v2 failed after the Coop recovery: $($scoopResetV2.output)"
    Assert-True ((& (Join-Path $ScoopRoot "shims/$package.exe")) -eq 'fixture 2') 'Scoop reset v2 did not keep the updated program runnable'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $store 'config/settings.ini') -Algorithm SHA256).Hash -eq $storeHash) 'The update or Scoop reset moved the stored persistent data'
    $summary.scenarios.interrupted_update = @{crash_exit=$crash.exit;pending_stage=$pending.Value.stage;
        recovery_status=$recoveredJson[0].status;scoop_reset_during=$scoopResetDuring.exit;
        scoop_reset_v2=$scoopResetV2.exit;hook_runs=(Hook-Lines);store_hash=$storeHash}

    # --- 3. Interrupted fresh install, then a real Scoop operation publishes the same package.
    # Coop must diagnose the replaced Coop-created objects instead of deleting Scoop's state, and
    # must read the real installation facts after the Scoop operation. ---------------------------
    $uninstall = Coop 'uninstall-v2' @('uninstall',$package,'--json')
    Assert-True ($uninstall.exit -eq 0) "Uninstall before the install-interruption scenario failed: $($uninstall.output)"
    # The uninstall keeps v2 as a retained local version; cleanup removes that test-owned version
    # so the next scenario starts from a fresh install instead of an update.
    $preCleanup = Coop 'cleanup-before-install-crash' @('cleanup',$package,'--json')
    Assert-True ($preCleanup.exit -eq 0) "Cleanup of the retained test version failed: $($preCleanup.output)"
    if (Test-Path -LiteralPath $app) {
        $full = [IO.Path]::GetFullPath($app).TrimEnd('\')
        $rootPrefix = [IO.Path]::GetFullPath($ScoopRoot).TrimEnd('\') + '\'
        Assert-True (($full+'\').StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) "Refusing to touch a path outside the real root: $full"
        Assert-True (@(Get-ChildItem -LiteralPath $app -Force | Where-Object { $_.Name -ne '1' }).Count -eq 0) 'Unexpected non-version content in the test package directory'
        Remove-Item -LiteralPath $app -Recurse -Force
    }
    Write-Manifest '1' (Join-Path $EvidenceDir 'payload-v1.zip')
    Set-Fault 'crash' 'after-entry'
    $installCrash = Invoke-CoopFault 'install-crash' @('install',"$bucketName/$package",'--json')
    Clear-Fault
    Assert-True ($installCrash.exit -eq -1073740791) "Injected real install crash did not terminate the process: exit $($installCrash.exit)"
    $installPending = Pending-Journal
    Assert-True ($installPending.Value.action -eq 'install') 'The interrupted transaction is not an install'
    Assert-True (@($installPending.Value.created | Where-Object { $_.path -like '*shims*' }).Count -ge 1) 'The install crash did not create a command entry before the injected stage'
    $scoopResetAfterCrash = Scoop 'scoop-reset-after-install-crash' @('reset',$package)
    if ($scoopResetAfterCrash.exit -ne 0) {
        # Scoop cannot reset an installation without the Coop-created current link; let the real
        # client remove and install the package so the conflict is still produced by Scoop itself.
        $scoopUninstall = Scoop 'scoop-uninstall-after-install-crash' @('uninstall',$package)
        Assert-True ($scoopUninstall.exit -eq 0) "Scoop could not remove the interrupted installation: $($scoopUninstall.output)"
        $scoopInstall = Scoop 'scoop-install-after-crash' @('install',"$bucketName/$package")
        Assert-True ($scoopInstall.exit -eq 0) "Scoop could not install the package after the Coop crash: $($scoopInstall.output)"
    }
    $factsAfterScoop = CoopEntry 'after-scoop-install'
    Assert-True ($factsAfterScoop.Count -eq 1 -and $factsAfterScoop[0].version -eq '1') "Coop did not re-recognize the package Scoop installed: $($factsAfterScoop | ConvertTo-Json -Depth 8)"
    Assert-True ($factsAfterScoop[0].last_operation -eq 'pending-recovery') 'Coop did not keep the interrupted transaction visible after the Scoop operation'
    Assert-True ($factsAfterScoop[0].management -in @('none','unadopted')) 'Coop presented the Scoop-installed package as its own managed install'
    $conflict = Coop 'recover-conflict' @('recover',$package,'--json')
    $conflictJson = Read-Json $conflict.output
    Assert-True ($conflict.exit -ne 0 -and $conflictJson[0].mode -eq 'manual') 'Coop rolled back Coop-created objects that Scoop replaced instead of diagnosing a conflict'
    Assert-True (@($conflictJson[0].conflicts | Where-Object { $_.code -in @('created-path-replaced','created-file-modified','created-link-repointed') }).Count -ge 1) "Coop did not report a stable created-object conflict code: $($conflict.output)"
    Assert-True (Test-Path -LiteralPath "$app/current") 'Coop deleted the current link Scoop published'
    Assert-True (Test-Path -LiteralPath (Join-Path $ScoopRoot "shims/$package.exe")) 'Coop deleted the command entry Scoop published'
    Assert-True ((Get-Content -LiteralPath $installPending.Path -Raw | ConvertFrom-Json).state -eq 'pending') 'A diagnosed conflict resolved the pending journal'
    Assert-True ((& (Join-Path $ScoopRoot "shims/$package.exe")) -eq 'fixture 1') 'Scoop installed program did not run after the Coop conflict diagnosis'

    # Real client removes its installation; Coop then completes recovery without deleting anything.
    $scoopUninstallFinal = Scoop 'scoop-uninstall-final' @('uninstall',$package)
    Assert-True ($scoopUninstallFinal.exit -eq 0) "Scoop could not uninstall the test package: $($scoopUninstallFinal.output)"
    $afterUninstall = CoopEntry 'after-scoop-uninstall'
    Assert-True ($afterUninstall.Count -le 1) "Coop reported duplicate rows after Scoop removed the package: $($afterUninstall | ConvertTo-Json -Depth 8)"
    if ($afterUninstall.Count -eq 1) {
        Assert-True ($afterUninstall[0].version -eq $null -and $afterUninstall[0].status -eq 'pending-recovery') "Coop still presented an installed version after Scoop removed it: $($afterUninstall | ConvertTo-Json -Depth 8)"
    }
    $finalRecovery = Coop 'recover-after-uninstall' @('recover',$package,'--json')
    Assert-True ($finalRecovery.exit -eq 0) "Recovery after Scoop removed the installation failed: $($finalRecovery.output)"
    $finalJson = Read-Json $finalRecovery.output
    Assert-True ($finalJson[0].status -eq 'recovered') 'Final recovery did not resolve the pending install'
    Assert-True (@($finalJson[0].actions | Where-Object { $_.kind -eq 'remove' }).Count -eq 0) 'Final recovery removed objects Scoop had already deleted'
    $afterFinalRecovery = CoopEntry 'after-final-recovery'
    Assert-True ($afterFinalRecovery.Count -eq 0) "Coop still listed the removed test package after recovery: $($afterFinalRecovery | ConvertTo-Json -Depth 8)"
    $summary.scenarios.interrupted_install_conflict = @{install_crash_exit=$installCrash.exit;
        scoop_reset_exit=$scoopResetAfterCrash.exit;conflict_exit=$conflict.exit;
        conflict_codes=@($conflictJson[0].conflicts | ForEach-Object code);
        facts_version=$factsAfterScoop[0].version;facts_management=$factsAfterScoop[0].management;
        final_recovery_status=$finalJson[0].status;final_remove_actions=@($finalJson[0].actions | Where-Object { $_.kind -eq 'remove' }).Count}

    $installedAfter = (Coop 'list-after' @('list','--json')).output | ConvertFrom-Json
    $beforeNames = @($installedBefore | ForEach-Object name | Sort-Object)
    $afterNames = @($installedAfter | ForEach-Object name | Sort-Object)
    Assert-True (($beforeNames -join ',') -eq ($afterNames -join ',')) "Real-root inventory changed: before=$($beforeNames -join ',') after=$($afterNames -join ',')"
    $pendingAfter = @(Get-ChildItem "$ScoopRoot/.coop/transactions" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $path = Join-Path $_.FullName 'journal.json'
        if (Test-Path -LiteralPath $path) {
            $value = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($value.state -eq 'pending') { $path }
        }
    })
    Assert-True ($pendingAfter.Count -eq 0) "Pending transactions remain on the real root: $($pendingAfter -join ',')"
    $summary.inventory_before = $beforeNames
    $summary.inventory_after = $afterNames
    $summary.status = 'pass'
} finally {
    Clear-Fault
    if (-not $faultFileExisted -and (Test-Path -LiteralPath (Split-Path $faultFile -Parent))) {
        $coopState = Split-Path $faultFile -Parent
        if (Test-Path -LiteralPath $coopState -PathType Container) {
            $remaining = @(Get-ChildItem -LiteralPath $coopState -Force)
            if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $coopState -Force }
        }
    }
    if ($created) {
        try { Scoop 'cleanup-scoop-uninstall' @('uninstall',$package) | Out-Null } catch { }
        # Resolve any test transaction left pending by a failed scenario before removing objects.
        try { Coop 'cleanup-recover' @('recover',$package,'--json') | Out-Null } catch { }
        try { Coop 'cleanup-coop-uninstall' @('uninstall',$package,'--json') | Out-Null } catch { }
        foreach ($path in @($app,$store)) {
            if (Test-Path -LiteralPath $path) {
                $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
                $rootPrefix = [IO.Path]::GetFullPath($ScoopRoot).TrimEnd('\') + '\'
                if (-not ($full+'\').StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to remove a path outside the real root: $full" }
                Remove-Item -LiteralPath $full -Recurse -Force
            }
        }
        if (Test-Path -LiteralPath $bucket) { Remove-Item -LiteralPath $bucket -Recurse -Force }
        if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
        foreach ($path in @((Join-Path $ScoopRoot ".coop/packages/$package.json"),(Join-Path $ScoopRoot ".coop/retained/$package.json"))) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
        foreach ($suffix in @('.exe','.shim','.coop-shim.json')) {
            $entry = Join-Path $ScoopRoot "shims/$package$suffix"
            if (Test-Path -LiteralPath $entry) { Remove-Item -LiteralPath $entry -Force }
            $tool = Join-Path $ScoopRoot "shims/$package-tool$suffix"
            if (Test-Path -LiteralPath $tool) { Remove-Item -LiteralPath $tool -Force }
        }
    }
    $summary.commands = $commands
    $summary.commands | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceDir 'commands.json') -Encoding utf8
    Save-Json 'summary.json' $summary
}
if ($summary.status -ne 'pass') { throw 'Real-root recovery acceptance did not complete' }
Write-Output "PASS real Scoop/Coop interrupted mechanisms, recovery and conflict diagnosis: $ScoopRoot"
exit 0

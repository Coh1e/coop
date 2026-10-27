param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# R12 / #33: real MSI artifact lifecycle through the real CLI in a project-local Scoop layout.
# The MSI database is read read-only and embedded cabinets are decompressed by the Windows cabinet
# API, so no msiexec process, elevation, reboot or Windows Installer machine-cache write is allowed
# anywhere in this test. Real 7-Zip 26.05 and 26.03 MSI artifacts provide the install, update,
# persist and uninstall evidence, and a truncated artifact provides an accurate extraction failure.
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$coopDirectory = Split-Path $CoopExe
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$guard = Join-Path $coopDirectory 'process_guard.exe'
$msi2605 = Join-Path $archives '7z2605-x64.msi'
$msi2603 = Join-Path $archives '7z2603-x64.msi'
$pwshPath = (Get-Process -Id $PID).Path
foreach ($path in @($guard,$msi2605,$msi2603,$pwshPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing fixed test input: $path; run scripts/fetch-deps.ps1" }
}

$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/main/bucket","$root/buckets/extras/bucket","$root/temp","$root/build","$root/programs" -Force | Out-Null
$script:runs = 0
$script:checks = 0

function Check([bool]$condition,[string]$message) {
    if (-not $condition) { throw "MSI lifecycle check failed: $message" }
    ++$script:checks
}
function File-Hash([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
function Write-Manifest([string]$bucket,[string]$name,[hashtable]$manifest) {
    $json = $manifest | ConvertTo-Json -Depth 16
    [IO.File]::WriteAllText("$root/buckets/$bucket/bucket/$name.json",$json,[Text.UTF8Encoding]::new($false))
}
function Invoke-Process([string]$label,[string]$file,[string[]]$arguments,[hashtable]$environment = @{}) {
    $start = [Diagnostics.ProcessStartInfo]::new($file)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $root
    foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
    $start.Environment['TEMP'] = "$root/temp"
    $start.Environment['TMP'] = "$root/temp"
    $start.Environment['COOP_PROGRAMS_DIR'] = "$root/programs"
    foreach ($key in $environment.Keys) { $start.Environment[$key] = $environment[$key] }
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(600000)) { $process.Kill($true); throw "$label timed out" }
    $result = @{exit=$process.ExitCode;output=$stdout.GetAwaiter().GetResult();error=$stderr.GetAwaiter().GetResult()}
    $process.Dispose()
    ++$script:runs
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath ("$root/run-{0:d2}-{1}.json" -f $script:runs,$label) -Encoding utf8
    return $result
}
function Invoke-Coop([string]$label,[string[]]$arguments,[hashtable]$environment = @{}) {
    return Invoke-Process $label $CoopExe $arguments $environment
}
function Invoke-Guard([string]$label,[string[]]$arguments,[hashtable]$environment = @{}) {
    return Invoke-Process $label $guard (@($CoopExe)+$arguments) $environment
}
function Parse-Json([string]$label,$result) {
    try { return $result.output | ConvertFrom-Json } catch { throw "$label did not print JSON: $($result.output)" }
}
function Last-Journal([string]$package) {
    $journals = @(Get-ChildItem "$root/.coop/transactions" -Recurse -Filter journal.json -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } |
        Where-Object { $_.package -eq $package })
    return $journals[-1]
}
function Get-WindowsInstallerCacheState {
    $directory = Join-Path $env:WINDIR 'Installer'
    if (-not (Test-Path -LiteralPath $directory)) { return @() }
    return @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.ToString('o'))" })
}
function Get-TreeSnapshot([string]$path) {
    return @(Get-ChildItem -LiteralPath $path -Recurse -File | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($path.Length).Replace('\','/')+'|'+(File-Hash $_.FullName)
    })
}
function Get-ProgramVersion([string]$exe) {
    $result = Invoke-Process 'program-version' $exe @()
    return $result
}
function Assert-CacheUnchanged([string]$label) {
    $current = @(Get-WindowsInstallerCacheState)
    Check (($current -join "`n") -eq ($script:installerCacheBefore -join "`n")) "Windows Installer machine cache changed during $label"
}

$hash2605 = File-Hash $msi2605
$hash2603 = File-Hash $msi2603
$manifest2605 = @{version='26.05';url=(File-Uri $msi2605);hash=$hash2605;extract_dir='Files\7-Zip';
    bin=@('7z.exe','7zG.exe','7zFM.exe');persist=@('Codecs','Formats')}
$manifest2603 = @{version='26.03';url=(File-Uri $msi2603);hash=$hash2603;extract_dir='Files\7-Zip';
    bin=@('7z.exe','7zG.exe','7zFM.exe');persist=@('Codecs','Formats')}
$script:installerCacheBefore = @(Get-WindowsInstallerCacheState)

# --- 1. Preview states the real mechanism, permissions and reboot facts. -------
Write-Manifest 'main' 'seven' $manifest2605
$preview = Invoke-Guard 'msi-preview' @('--root',$root,'install','main/seven','--dry-run','--json')
Check ($preview.exit -eq 0) "MSI preview failed: $($preview.error)"
Check ($preview.error -match 'Observed workload processes: 1') 'MSI preview started msiexec or PowerShell'
$plan = Parse-Json 'msi-preview' $preview
Check ($plan.execution_available -eq $true) 'MSI preview is not executable'
Check ($plan.artifacts[0].archive -eq 'msi' -and $plan.artifacts[0].extraction -eq 'read-only-msi-image') 'MSI artifact or extraction method is not reported'
Check ($plan.artifacts[0].requires_elevation -eq $false -and $plan.artifacts[0].reboot_required -eq $false) 'MSI preview does not state that no elevation or reboot is required'
Check ((@($plan.ir_operations | Where-Object { $_.operation -eq 'extract' }).Count -eq 1) -and
    ((@($plan.ir_operations | ForEach-Object { $_.operation }) -join ',') -eq 'download,verify,extract,publish-current,entries,persistence,commit-state')) 'MSI plan does not carry the expected operation order'
$facts = $plan.package.msi_extraction
Check ($facts.mechanism -match 'read-only Windows Installer database' -and $facts.msiexec_started -eq $false -and
    $facts.administrative_install -eq $false) 'MSI preview does not describe the read-only extraction mechanism'
Check ($facts.elevation -match 'not required' -and $facts.reboot -match 'not required') 'MSI preview does not state the permission and reboot requirements'
Check ($facts.machine_cache -match 'not written' -and $facts.external_cabinets -match 'unsupported') 'MSI preview does not state the machine-cache and external-cabinet boundary'
Check ($facts.database_api -match 'msi\.dll$' -and $facts.cabinet_api -match 'cabinet\.dll$') 'MSI preview does not name the Windows APIs it uses'
Check (@($plan.external_tools).Count -eq 1 -and $plan.external_tools[0].name -eq 'Windows Installer APIs' -and
    $plan.external_tools[0].available -eq $true -and $plan.external_tools[0].enabled -eq $true) 'MSI preview does not disclose the Windows Installer APIs without an external tool download'
Check ($plan.external_tools[0].limitation -match 'no msiexec\.exe process' -and $plan.external_tools[0].limitation -match 'no elevation' -and
    $plan.external_tools[0].limitation -match 'no reboot') 'MSI external API limitation omits the read-only boundary'
Check (@($plan.capabilities | Where-Object { $_.id -eq 'windows-installer' -and $_.supported -eq $true }).Count -eq 1) 'windows-installer capability is not reported as supported'
Check (@($plan.diagnostics | Where-Object { $_.code -eq 'execution-blocked' }).Count -eq 0) 'MSI preview still reports an execution blocker'
Check ($plan.lifecycle_checks.msi_extraction -match 'no elevation, reboot, msiexec process or machine-cache write') 'MSI lifecycle check does not state the boundary'
Check (-not (Test-Path -LiteralPath "$root/apps/seven") -and -not (Test-Path -LiteralPath "$root/.coop/transactions")) 'MSI preview wrote installation state'
Assert-CacheUnchanged 'the MSI preview'

# --- 2. Install the real 7-Zip 26.05 MSI artifact. ---------------------------
$install = Invoke-Guard 'msi-install' @('--root',$root,'install','main/seven','--json')
Check ($install.exit -eq 0) "MSI install failed: $($install.error)"
Check ($install.error -match 'Observed workload processes: 1') 'MSI install started msiexec or PowerShell'
$installResult = Parse-Json 'msi-install' $install
Check ($installResult.status -eq 'success') 'MSI install result is not successful'
$versionDirectory = Join-Path $root 'apps/seven/26.05'
foreach ($relative in @('7z.exe','7z.dll','7zFM.exe','7-zip.chm','Lang\en.ttt','descript.ion')) {
    Check (Test-Path -LiteralPath (Join-Path $versionDirectory $relative)) "MSI image is missing $relative"
}
Check (-not (Test-Path -LiteralPath "$versionDirectory/7z2605-x64.msi")) 'MSI image copied the installer file into the version directory'
Check (@(Get-ChildItem -LiteralPath "$versionDirectory/Lang" -File).Count -gt 50) 'MSI subdirectory layout was not preserved'
$currentTarget = [IO.Path]::GetFullPath([string](Get-Item -LiteralPath "$root/apps/seven/current").Target)
Check ($currentTarget -eq [IO.Path]::GetFullPath($versionDirectory)) 'MSI current link points at the wrong version'
Check (Test-Path -LiteralPath "$root/shims/7z.exe") 'MSI install did not create the Scoop-compatible command entry'
$sevenVersion = Get-ProgramVersion "$root/shims/7z.exe"
Check ($sevenVersion.output -match '7-Zip 26\.05') "MSI-installed program reports the wrong version: $($sevenVersion.output)"
foreach ($store in @('Codecs','Formats')) {
    Check (Test-Path -LiteralPath "$root/persist/seven/$store") "MSI persist store $store was not created"
    $link = Get-Item -LiteralPath "$versionDirectory/$store"
    Check ($link.LinkType -eq 'Junction' -and [IO.Path]::GetFullPath([string]$link.Target) -eq [IO.Path]::GetFullPath("$root/persist/seven/$store")) "MSI persist mapping $store is not a junction into the store"
}
Check ((Test-Path -LiteralPath "$versionDirectory/scoop-install.json") -and (Test-Path -LiteralPath "$versionDirectory/scoop-manifest.json")) 'MSI install did not write the shared Scoop records'
$installJournal = Last-Journal 'seven'
Check ($installJournal.state -eq 'committed' -and (@($installJournal.observed_steps) -join ',') -eq (@($plan.ir_operations | ForEach-Object { $_.operation }) -join ',')) 'MSI journal does not match the previewed plan'
$msiRecord = @($installJournal.msi_extractions)[0]
Check ($msiRecord.database_access -eq 'read-only' -and $msiRecord.msiexec_started -eq $false -and
    $msiRecord.administrative_install -eq $false) 'MSI journal does not record the read-only extraction'
Check ($msiRecord.elevation -match 'not requested' -and $msiRecord.reboot -match 'not scheduled' -and
    $msiRecord.machine_cache -match 'not written') 'MSI journal does not record the permission, reboot and cache facts'
Check ((@($msiRecord.cabinets) -join ',') -eq 'product.cab' -and $msiRecord.cabinet_files -eq 106 -and
    $msiRecord.files -eq 106 -and $msiRecord.uncompressed_streams -eq 0) 'MSI journal does not record the cabinet contents it read'
Check ($msiRecord.bytes -eq 5903862) 'MSI journal byte count does not match the extracted image'
$installedList = Invoke-Coop 'msi-list' @('--root',$root,'list','--json')
Check ($installedList.exit -eq 0 -and $installedList.output -match 'seven') 'Coop list does not see the MSI installation'
Assert-CacheUnchanged 'the MSI install'
Set-Content -LiteralPath "$root/persist/seven/Codecs/probe.txt" -Value 'msi-persist-probe' -Encoding ascii
Check ((Get-Content -LiteralPath "$root/apps/seven/current/Codecs/probe.txt" -Raw).Trim() -eq 'msi-persist-probe') 'MSI persist store is not visible through current'
$image2605 = Get-TreeSnapshot $versionDirectory

# --- 3. Update to the real 7-Zip 26.03 MSI artifact and keep the old version. --
Write-Manifest 'main' 'seven' $manifest2603
$updatePreview = Invoke-Guard 'msi-update-preview' @('--root',$root,'update','seven','--dry-run','--json')
Check ($updatePreview.exit -eq 0 -and $updatePreview.error -match 'Observed workload processes: 1') 'MSI update preview failed or started an external process'
$updatePlan = Parse-Json 'msi-update-preview' $updatePreview
Check ($updatePlan.execution_available -eq $true) 'MSI update preview is not executable'
$update = Invoke-Guard 'msi-update' @('--root',$root,'update','seven','--json')
Check ($update.exit -eq 0) "MSI update failed: $($update.error)"
Check ($update.error -match 'Observed workload processes: 1') 'MSI update started msiexec or PowerShell'
$updateResult = Parse-Json 'msi-update' $update
Check ($updateResult.status -eq 'success' -and ($updateResult.retained_versions -contains '26.05')) 'MSI update did not retain the previous version'
Check ([IO.Path]::GetFullPath([string](Get-Item -LiteralPath "$root/apps/seven/current").Target) -eq [IO.Path]::GetFullPath((Join-Path $root 'apps/seven/26.03'))) 'MSI update did not repoint current'
$updatedVersion = Get-ProgramVersion "$root/shims/7z.exe"
Check ($updatedVersion.output -match '7-Zip 26\.03') "MSI update did not switch the real program version: $($updatedVersion.output)"
Check ((Test-Path -LiteralPath "$root/apps/seven/26.05/7z.exe") -and (Test-Path -LiteralPath "$root/apps/seven/26.03/7z.exe")) 'MSI update did not keep both version directories'
Check ((Get-Content -LiteralPath "$root/apps/seven/current/Codecs/probe.txt" -Raw).Trim() -eq 'msi-persist-probe') 'MSI update did not reuse the persisted data'
$updateJournal = Last-Journal 'seven'
Check ($updateJournal.state -eq 'committed' -and @($updateJournal.msi_extractions).Count -eq 1) 'MSI update journal is incomplete'
$image2603 = Get-TreeSnapshot "$root/apps/seven/26.03"
Check (($image2603 -join "`n") -ne ($image2605 -join "`n")) 'MSI update did not actually replace the image contents'
Assert-CacheUnchanged 'the MSI update'

# --- 4. A corrupt MSI update fails accurately and protects the current version. ----
$broken = Join-Path $root 'build/broken-7z.msi'
[IO.File]::WriteAllBytes($broken,[IO.File]::ReadAllBytes($msi2605)[0..999])
Write-Manifest 'main' 'seven' @{version='26.06';url=(File-Uri $broken);hash=(File-Hash $broken);extract_dir='Files\7-Zip';bin='7z.exe';persist=@('Codecs','Formats')}
$failedUpdate = Invoke-Guard 'msi-broken-update' @('--root',$root,'update','seven','--json')
Check ($failedUpdate.exit -ne 0) 'Corrupt MSI update unexpectedly succeeded'
Check ($failedUpdate.error -match 'MSI database' -and $failedUpdate.error -match 'Observed workload processes: 1') "Corrupt MSI failure was not reported at the database stage: $($failedUpdate.error)"
Check ((Get-ProgramVersion "$root/shims/7z.exe").output -match '7-Zip 26\.03') 'Corrupt MSI update changed the working program'
Check (-not (Test-Path -LiteralPath "$root/apps/seven/26.06")) 'Corrupt MSI update published a version directory'
$failedJournal = Last-Journal 'seven'
Check ($failedJournal.state -eq 'rolled-back') 'Corrupt MSI update journal does not show rollback'
Check (-not (@($failedJournal.PSObject.Properties.Name) -contains 'msi_extractions')) 'Corrupt MSI update recorded a successful extraction'

# --- 5. Ordinary uninstall removes the package and keeps declared data. ------
$uninstall = Invoke-Guard 'msi-uninstall' @('--root',$root,'uninstall','seven','--json')
Check ($uninstall.exit -eq 0) "MSI uninstall failed: $($uninstall.error)"
Check ($uninstall.error -match 'Observed workload processes: 1') 'MSI uninstall started msiexec or PowerShell'
Check (-not (Test-Path -LiteralPath "$root/apps/seven/current")) 'MSI uninstall left current published'
Check (-not (Test-Path -LiteralPath "$root/shims/7z.exe") -and -not (Test-Path -LiteralPath "$root/shims/7zFM.exe")) 'MSI uninstall left command entries'
Check (Test-Path -LiteralPath "$root/persist/seven/Codecs/probe.txt") 'MSI uninstall removed declared persistent data'
Check ((Get-Content -LiteralPath "$root/persist/seven/Codecs/probe.txt" -Raw).Trim() -eq 'msi-persist-probe') 'MSI uninstall changed declared persistent data'
Write-Manifest 'main' 'broken' @{version='1';url=(File-Uri $broken);hash=(File-Hash $broken);extract_dir='Files\7-Zip';bin='7z.exe'}
$failedInstall = Invoke-Guard 'msi-broken-install' @('--root',$root,'install','main/broken','--json')
Check ($failedInstall.exit -ne 0 -and $failedInstall.error -match 'MSI database') 'Corrupt MSI install did not fail at the database stage'
Check (-not (Test-Path -LiteralPath "$root/apps/broken") -and -not (Test-Path -LiteralPath "$root/.coop/packages/broken.json")) 'Corrupt MSI install published state'
Assert-CacheUnchanged 'the MSI uninstall and corrupt MSI failures'

# --- 6. Evidence ------------------------------------------------------------
$cacheAfter = @(Get-WindowsInstallerCacheState)
@{
    timestamp=[DateTime]::UtcNow.ToString('o')
    root=$root
    checks=$script:checks
    runs=$script:runs
    coop_sha256=(File-Hash $CoopExe)
    powershell=$pwshPath
    artifacts=@(
        @{path=$msi2605;sha256=$hash2605;reported_version='26.05'},
        @{path=$msi2603;sha256=$hash2603;reported_version='26.03'},
        @{path=$broken;sha256=(File-Hash $broken);reported_version='corrupt copy of the 26.05 artifact'}
    )
    plan=@{operations=@($plan.ir_operations | ForEach-Object { $_.operation }); elevation=$facts.elevation; reboot=$facts.reboot; mechanism=$facts.mechanism}
    install=@{files=$msiRecord.files;bytes=$msiRecord.bytes;cabinet_files=$msiRecord.cabinet_files;cabinets=@($msiRecord.cabinets);stdout='7-Zip 26.05'}
    update=@{reported_version='7-Zip 26.03';retained_versions=@($updateResult.retained_versions)}
    uninstall=@{persist_data_retained=$true;current_removed=$true;entries_removed=$true}
    failure=@{exit=$failedUpdate.exit;error=$failedUpdate.error.Trim();journal=$failedJournal.state}
    windows_installer_cache=@{
        path=(Join-Path $env:WINDIR 'Installer')
        entries_before=@($script:installerCacheBefore).Count
        entries_after=$cacheAfter.Count
        unchanged=(($script:installerCacheBefore -join "`n") -eq ($cacheAfter -join "`n"))
    }
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$root/evidence.json" -Encoding utf8
Write-Output "PASS real MSI install, update, uninstall and failure lifecycle without msiexec, elevation or machine-cache writes: $root/evidence.json ($script:checks checks)"
exit 0

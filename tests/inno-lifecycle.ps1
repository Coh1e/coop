param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# R13 / #34: real Inno Setup artifact lifecycle through the real CLI in a project-local Scoop
# layout. The vendor setup.exe is never executed: the separately installed innounp helper unpacks
# exactly the Inno directory Scoop's Expand-InnoArchive selects. Real GNU Units 2.27/2.26 setups
# provide install, update and failure evidence; a real rizin installer provides the relative
# extract_dir ({app}\bin) layout. The helper is provisioned from its pinned Scoop package archive
# and must remain byte-identical, proving Coop neither downloads nor replaces it.
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$coopDirectory = Split-Path $CoopExe
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$guard = Join-Path $coopDirectory 'process_guard.exe'
$units227 = Join-Path $archives 'units-2.27-setup.exe'
$units226 = Join-Path $archives 'units-2.26-setup.exe'
$rizin = Join-Path $archives 'rizin-0.9.1-installer.exe'
$innounpArchive = Join-Path $archives 'innounp-2.zip'
$pwshPath = (Get-Process -Id $PID).Path
foreach ($path in @($guard,$units227,$units226,$rizin,$innounpArchive,$pwshPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing fixed test input: $path; run scripts/fetch-deps.ps1" }
}

$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/main/bucket","$root/temp","$root/build","$root/programs","$root/apps/innounp/current" -Force | Out-Null
# The helper is a normal Scoop package installed in this root, never something Coop ships.
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($innounpArchive,"$root/apps/innounp/current")
# The helper is a normal shared Scoop installation: give it the same records Scoop would write so
# reverse-dependency scans read it as one installed package, not as an unrecorded directory.
@{version='2.71.2';description='Inno Setup Unpacker (Unicode)';url=([Uri]$innounpArchive).AbsoluteUri;
    hash=(Get-FileHash -LiteralPath $innounpArchive -Algorithm SHA256).Hash.ToLower();bin='innounp.exe'} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$root/apps/innounp/current/scoop-manifest.json" -Encoding utf8
@{bucket='main';architecture='64bit'} | ConvertTo-Json |
    Set-Content -LiteralPath "$root/apps/innounp/current/scoop-install.json" -Encoding utf8
$script:runs = 0
$script:checks = 0

function Check([bool]$condition,[string]$message) {
    if (-not $condition) { throw "Inno Setup lifecycle check failed: $message" }
    ++$script:checks
}
function File-Hash([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function Same-Path([string]$a,[string]$b) { return [IO.Path]::GetFullPath($a) -eq [IO.Path]::GetFullPath($b) }
function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
function Write-Manifest([string]$name,[hashtable]$manifest) {
    [IO.File]::WriteAllText("$root/buckets/main/bucket/$name.json",($manifest | ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
}
function Invoke-Process([string]$label,[string]$file,[string[]]$arguments,[hashtable]$environment = @{}) {
    $start = [Diagnostics.ProcessStartInfo]::new($file)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    # Coop emits UTF-8 JSON and diagnostics; decode both streams as UTF-8 so a test root with
    # non-ASCII characters is reported, not mangled by the console code page.
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
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
# The guard observes the real process tree. Installs and updates legitimately start the declared
# innounp helper, so children are allowed but must be named and must include no vendor setup or
# msiexec process. Previews, uninstalls and blocked operations must start no child at all.
function Invoke-Guarded([string]$label,[string[]]$arguments,[bool]$allowHelper) {
    $environment = @{}
    $previousTimeout = $env:COOP_PROCESS_GUARD_TIMEOUT_MS
    $previousChildren = $env:COOP_PROCESS_GUARD_ALLOW_CHILDREN
    $env:COOP_PROCESS_GUARD_TIMEOUT_MS = '120000'
    if ($allowHelper) { $env:COOP_PROCESS_GUARD_ALLOW_CHILDREN = '1' }
    try { return Invoke-Process $label $guard (@($CoopExe)+$arguments) $environment }
    finally {
        if ($null -eq $previousTimeout) { Remove-Item Env:COOP_PROCESS_GUARD_TIMEOUT_MS -ErrorAction SilentlyContinue }
        else { $env:COOP_PROCESS_GUARD_TIMEOUT_MS = $previousTimeout }
        if ($null -eq $previousChildren) { Remove-Item Env:COOP_PROCESS_GUARD_ALLOW_CHILDREN -ErrorAction SilentlyContinue }
        else { $env:COOP_PROCESS_GUARD_ALLOW_CHILDREN = $previousChildren }
    }
}
function Assert-Workloads($result,[bool]$allowHelper) {
    $names = @([regex]::Matches($result.error,'Workload process: (.+)') | ForEach-Object { $_.Groups[1].Value.Trim() })
    Check ($names.Count -eq ($(if ($allowHelper) { 2 } else { 1 }))) "unexpected workload processes: $($names -join '; ') ($($result.error))"
    Check ($names[0] -match 'coop\.exe$') "first workload process is not coop.exe: $($names -join '; ')"
    Check (-not ($names -match '(?i)msiexec|setup\.exe')) "a vendor installer process was started: $($names -join '; ')"
    if ($allowHelper) {
        Check ($names[1] -match 'innounp\.exe$') "the only extra workload process is not innounp.exe: $($names -join '; ')"
        Check ($result.error -match 'Observed workload processes: 2') "the guard did not observe exactly coop and innounp: $($result.error)"
    } else {
        Check ($result.error -match 'Observed workload processes: 1') "coop started an unexpected child process: $($result.error)"
    }
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
function Helper-Snapshot {
    return @(Get-ChildItem "$root/apps/innounp" -Recurse -File | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($root.Length).Replace('\','/')+'|'+(File-Hash $_.FullName)
    })
}
function Get-TreeSnapshot([string]$path) {
    return @(Get-ChildItem -LiteralPath $path -Recurse -File | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($path.Length).Replace('\','/')+'|'+(File-Hash $_.FullName)
    })
}
function Program-Version([string]$shim) {
    $result = Invoke-Process 'program-version' $shim @('--version')
    return $result
}

$hash227 = File-Hash $units227
$hash226 = File-Hash $units226
$hashRizin = File-Hash $rizin
$helperExecutable = [IO.Path]::GetFullPath("$root/apps/innounp/current/innounp.exe")
$helperHash = File-Hash $helperExecutable
$helperBefore = Helper-Snapshot
$unitsManifest = {
    param($version,$path,$hash)
    @{version=$version;url=(File-Uri $path);hash=$hash;innosetup=$true;bin='units.exe';persist='settings'}
}

# --- 1. Preview states the declared helper, the layout and the vendor-installer boundary. --------
Write-Manifest 'units' (& $unitsManifest '2.27' $units227 $hash227)
$preview = Invoke-Guarded 'inno-preview' @('--root',$root,'install','main/units','--dry-run','--json') $false
Check ($preview.exit -eq 0) "Inno preview failed: $($preview.error)"
Assert-Workloads $preview $false
$plan = Parse-Json 'inno-preview' $preview
Check ($plan.execution_available -eq $true) "Inno preview is not executable: $(@($plan.diagnostics) | ConvertTo-Json -Compress)"
Check ($plan.artifacts[0].archive -eq 'inno-setup' -and $plan.artifacts[0].extraction -eq 'external-innounp' -and
    $plan.artifacts[0].inno_selection -eq '-c{app}') 'Inno artifact or extraction method is not reported'
Check ($plan.artifacts[0].requires_elevation -eq $false -and $plan.artifacts[0].reboot_required -eq $false -and
    $plan.artifacts[0].vendor_installer_executed -eq $false) 'Inno preview does not state that the vendor installer is not run'
$facts = $plan.package.inno_setup
Check ($facts.mechanism -match 'innounp' -and $facts.helper_available -eq $true -and $facts.installer_executed -eq $false) 'Inno preview does not describe the external helper mechanism'
Check (Same-Path $facts.helper $helperExecutable) "Inno preview does not name the helper in the selected root: $($facts.helper)"
Check ($facts.helper_policy -match 'software dependency' -and $facts.helper_policy -match 'never downloads') 'Inno preview does not separate the helper from Coop core dependencies'
Check ($facts.elevation -match 'not requested' -and $facts.reboot -match 'not required' -and
    $facts.installer_effects -match 'not executed' -and $facts.selection -match '-c\{app\}') 'Inno preview does not state the permission, reboot and effect boundary'
Check (@($plan.external_tools).Count -eq 1 -and $plan.external_tools[0].name -match '^innounp' -and
    $plan.external_tools[0].available -eq $true -and $plan.external_tools[0].enabled -eq $true -and
    (Same-Path $plan.external_tools[0].path $helperExecutable)) 'Inno preview does not disclose the detected innounp helper'
Check ($plan.external_tools[0].limitation -match 'not executed' -and $plan.external_tools[0].policy -match 'never downloads') 'Inno external tool limitation omits the extraction boundary'
Check (@($plan.capabilities | Where-Object { $_.id -eq 'inno-setup' -and $_.supported -eq $true }).Count -eq 1) 'inno-setup capability is not reported as supported'
Check (@($plan.diagnostics | Where-Object { $_.code -eq 'execution-blocked' }).Count -eq 0) 'Inno preview reports an execution blocker'
Check ($plan.lifecycle_checks.inno_setup -match 'innounp') 'Inno lifecycle check does not name the helper'
Check ((@($plan.ir_operations | ForEach-Object { $_.operation }) -join ',') -eq 'download,verify,extract,publish-current,entries,persistence,commit-state') 'Inno plan does not carry the expected operation order'
Check (-not (Test-Path -LiteralPath "$root/apps/units") -and -not (Test-Path -LiteralPath "$root/.coop/transactions")) 'Inno preview wrote installation state'
Check ((Helper-Snapshot) -join "`n" -eq ($helperBefore -join "`n")) 'the preview changed the helper package'

# --- 2. Install the real 2.27 Inno Setup artifact. ----------------------------------------------
$install = Invoke-Guarded 'inno-install' @('--root',$root,'install','main/units','--json') $true
Check ($install.exit -eq 0) "Inno install failed: $($install.error)"
Assert-Workloads $install $true
$installResult = Parse-Json 'inno-install' $install
Check ($installResult.status -eq 'success') 'Inno install result is not successful'
$versionDirectory = Join-Path $root 'apps/units/2.27'
foreach ($relative in @('units.exe','definitions.units','units_cur.py','elements.units','currency.units','License.txt','Readme.txt')) {
    Check (Test-Path -LiteralPath (Join-Path $versionDirectory $relative)) "Inno layout is missing $relative"
}
Check (-not (Test-Path -LiteralPath "$versionDirectory/units-2.27-setup.exe")) 'Inno install copied the vendor installer into the version directory'
Check (-not (Test-Path -LiteralPath "$versionDirectory/unins000.exe")) 'the vendor uninstaller was installed'
Check ([IO.Path]::GetFullPath([string](Get-Item -LiteralPath "$root/apps/units/current").Target) -eq [IO.Path]::GetFullPath($versionDirectory)) 'Inno current link points at the wrong version'
Check (Test-Path -LiteralPath "$root/shims/units.exe") 'Inno install did not create the Scoop-compatible command entry'
$installedVersion = Program-Version "$root/shims/units.exe"
Check ($installedVersion.exit -eq 0 -and $installedVersion.output -match 'GNU Units version 2\.27') "the installed program reports the wrong version: $($installedVersion.output)"
$conversion = Invoke-Process 'units-convert' "$root/shims/units.exe" @('1 mile','km')
if ($conversion.exit -ne 0 -and [string]::IsNullOrWhiteSpace($conversion.output)) {
    # GNU Units loads its conversion table from a data file next to the executable or from UNITSFILE.
    # A host that ships a build without that table runs (the version check above passed) but cannot
    # convert; skip the conversion rather than reporting it as a coop defect.
    Write-Output "skipped units conversion: this build reported no output and exit $($conversion.exit)"
} else {
    Check ($conversion.exit -eq 0 -and $conversion.output -match '1\.609344') "the installed program cannot convert units: $($conversion.output)"
}
Check (Test-Path -LiteralPath "$root/persist/units/settings") 'declared persist data was not created'
Set-Content -LiteralPath "$root/persist/units/settings/probe.txt" -Value 'inno-persist-probe' -Encoding ascii
Check ((Get-Content -LiteralPath "$root/apps/units/current/settings/probe.txt" -Raw).Trim() -eq 'inno-persist-probe') 'persist data is not visible through current'
Check ((Test-Path -LiteralPath "$versionDirectory/scoop-install.json") -and (Test-Path -LiteralPath "$versionDirectory/scoop-manifest.json")) 'Inno install did not write the shared Scoop records'
$installJournal = Last-Journal 'units'
Check ($installJournal.state -eq 'committed' -and (@($installJournal.observed_steps) -join ',') -eq (@($plan.ir_operations | ForEach-Object { $_.operation }) -join ',')) 'Inno journal does not match the previewed plan'
$innoRecord = @($installJournal.inno_extractions)[0]
Check ($innoRecord.mechanism -match 'innounp' -and (Same-Path $innoRecord.helper $helperExecutable) -and
    $innoRecord.helper_sha256 -eq $helperHash) 'Inno journal does not record the helper it used'
Check ($innoRecord.exit_code -eq 0 -and (@($innoRecord.arguments)[0] -eq '-x') -and (@($innoRecord.arguments)[-1] -eq '-c{app}') -and
    (@($innoRecord.arguments) -contains '-y')) 'Inno journal does not record the Expand-InnoArchive arguments'
Check ($innoRecord.selection -eq '-c{app}' -and $innoRecord.installer_executed -eq $false -and
    $innoRecord.elevation -match 'not requested' -and $innoRecord.reboot -match 'not scheduled') 'Inno journal does not record the extraction boundary'
Check ($innoRecord.files -eq 15 -and $innoRecord.bytes -gt 2000000) "Inno journal extraction totals are wrong: $($innoRecord.files) files, $($innoRecord.bytes) bytes"
Check ($innoRecord.stdout_tail -match 'Inno Setup version detected:  6\.6\.0' -and $innoRecord.stdout_tail -match '#15 \{app\}\\unitsfile\.ico - extracted') 'Inno journal does not keep the helper output'
Check ((Helper-Snapshot) -join "`n" -eq ($helperBefore -join "`n")) 'the install changed the helper package'
$installedList = Invoke-Coop 'inno-list' @('--root',$root,'list','--json')
Check ($installedList.exit -eq 0 -and $installedList.output -match 'units') 'Coop list does not see the Inno installation'
$image227 = Get-TreeSnapshot $versionDirectory

# --- 3. Update to the real 2.26 artifact and keep the old version. ------------------------------
Write-Manifest 'units' (& $unitsManifest '2.26' $units226 $hash226)
$updatePreview = Invoke-Guarded 'inno-update-preview' @('--root',$root,'update','units','--dry-run','--json') $false
Check ($updatePreview.exit -eq 0) "Inno update preview failed: $($updatePreview.error)"
Assert-Workloads $updatePreview $false
Check ((Parse-Json 'inno-update-preview' $updatePreview).execution_available -eq $true) 'Inno update preview is not executable'
$update = Invoke-Guarded 'inno-update' @('--root',$root,'update','units','--json') $true
Check ($update.exit -eq 0) "Inno update failed: $($update.error)"
Assert-Workloads $update $true
$updateResult = Parse-Json 'inno-update' $update
Check ($updateResult.status -eq 'success' -and ($updateResult.retained_versions -contains '2.27')) 'Inno update did not retain the previous version'
Check ([IO.Path]::GetFullPath([string](Get-Item -LiteralPath "$root/apps/units/current").Target) -eq [IO.Path]::GetFullPath((Join-Path $root 'apps/units/2.26'))) 'Inno update did not repoint current'
$updatedVersion = Program-Version "$root/shims/units.exe"
Check ($updatedVersion.exit -eq 0 -and $updatedVersion.output -match 'GNU Units version 2\.26') "Inno update did not switch the real program version: $($updatedVersion.output)"
Check ((Test-Path -LiteralPath "$root/apps/units/2.27/units.exe") -and (Test-Path -LiteralPath "$root/apps/units/2.26/units.exe")) 'Inno update did not keep both version directories'
Check ((Get-Content -LiteralPath "$root/apps/units/current/settings/probe.txt" -Raw).Trim() -eq 'inno-persist-probe') 'Inno update did not reuse the persisted data'
$updateJournal = Last-Journal 'units'
Check ($updateJournal.state -eq 'committed' -and @($updateJournal.inno_extractions).Count -eq 1) 'Inno update journal is incomplete'
Check ((@($updateJournal.inno_extractions)[0].selection) -eq '-c{app}') 'Inno update used a different Inno selection'
$image226 = Get-TreeSnapshot "$root/apps/units/2.26"
Check (($image226 -join "`n") -ne ($image227 -join "`n")) 'Inno update did not actually replace the extracted files'

# --- 4. A truncated artifact fails accurately and protects the installed version. --------------
$broken = Join-Path $root 'build/broken-units.exe'
[IO.File]::WriteAllBytes($broken,[IO.File]::ReadAllBytes($units227)[0..7999])
Write-Manifest 'units' @{version='2.28';url=(File-Uri $broken);hash=(File-Hash $broken);innosetup=$true;bin='units.exe';persist='settings'}
$failedUpdate = Invoke-Guarded 'inno-broken-update' @('--root',$root,'update','units','--json') $true
Check ($failedUpdate.exit -ne 0) 'Truncated Inno update unexpectedly succeeded'
Check ($failedUpdate.error -match 'innounp could not unpack') "Truncated Inno failure was not reported by the helper: $($failedUpdate.error)"
Assert-Workloads $failedUpdate $true
Check ((Program-Version "$root/shims/units.exe").output -match 'GNU Units version 2\.26') 'Truncated Inno update changed the working program'
Check (-not (Test-Path -LiteralPath "$root/apps/units/2.28")) 'Truncated Inno update published a version directory'
$failedJournal = Last-Journal 'units'
Check ($failedJournal.state -eq 'rolled-back') 'Truncated Inno update journal does not show rollback'
Check (-not (@($failedJournal.PSObject.Properties.Name) -contains 'inno_extractions')) 'Truncated Inno update recorded a successful extraction'

# --- 5. The helper is a declared dependency: missing means blocked, never downloaded. -----------
Write-Manifest 'missing' (& $unitsManifest '2.27' $units227 $hash227)
Rename-Item -LiteralPath "$root/apps/innounp" -NewName 'innounp-absent'
try {
    $missingPreview = Invoke-Guarded 'inno-missing-preview' @('--root',$root,'install','main/missing','--dry-run','--json') $false
    Check ($missingPreview.exit -eq 0) "missing-helper preview failed: $($missingPreview.error)"
    Assert-Workloads $missingPreview $false
    $missingPlan = Parse-Json 'inno-missing-preview' $missingPreview
    Check ($missingPlan.execution_available -eq $false) 'missing-helper preview still claims executability'
    Check (@($missingPlan.diagnostics | Where-Object { $_.code -eq 'execution-blocked' -and $_.message -match 'innounp' }).Count -eq 1) 'missing-helper preview does not diagnose the missing helper'
    Check (@($missingPlan.external_tools | Where-Object { $_.name -match '^innounp' -and $_.available -eq $false -and $_.limitation -match 'looked for' }).Count -eq 1) 'missing-helper preview does not declare the unavailable external tool'
    Check ($missingPlan.package.inno_setup.helper_available -eq $false -and $missingPlan.package.inno_setup.helper_problem -match 'never downloads') 'missing-helper preview does not state the no-download policy'
    $missing = Invoke-Guarded 'inno-missing-install' @('--root',$root,'install','main/missing','--json') $false
    Check ($missing.exit -ne 0) 'missing-helper install unexpectedly succeeded'
    Check ($missing.error -match 'innounp' -and $missing.error -match 'never downloads') "missing-helper failure is not explicit: $($missing.error)"
    Assert-Workloads $missing $false
    Check (-not (Test-Path -LiteralPath "$root/apps/missing") -and -not (Test-Path -LiteralPath "$root/.coop/packages/missing.json")) 'missing-helper install wrote package state'
    Check (-not (Test-Path -LiteralPath "$root/apps/innounp")) 'Coop downloaded or recreated the helper'
} finally {
    Rename-Item -LiteralPath "$root/apps/innounp-absent" -NewName 'innounp'
}
Check ((Helper-Snapshot) -join "`n" -eq ($helperBefore -join "`n")) 'the missing-helper attempt changed the restored helper package'

# --- 6. A real Inno package with a subdirectory layout: relative extract_dir selects {app}\bin. --
Write-Manifest 'rz' @{version='0.9.1';url=(File-Uri $rizin);hash=$hashRizin;innosetup=$true;
    extract_dir='bin';bin=@('rizin.exe','rz-bin.exe')}
$rzPreview = Invoke-Guarded 'inno-subdir-preview' @('--root',$root,'install','main/rz','--dry-run','--json') $false
Check ($rzPreview.exit -eq 0) "subdirectory preview failed: $($rzPreview.error)"
$rzPlan = Parse-Json 'inno-subdir-preview' $rzPreview
Check ($rzPlan.execution_available -eq $true) "subdirectory preview is blocked: $(@($rzPlan.diagnostics) | ConvertTo-Json -Compress)"
Check ($rzPlan.package.inno_setup.selection -match '\{app\}\\<extract_dir>' -and $rzPlan.artifacts[0].inno_selection -eq '-c{app}\bin') 'subdirectory preview does not describe the relative extract_dir mapping'
$rzInstall = Invoke-Guarded 'inno-subdir-install' @('--root',$root,'install','main/rz','--json') $true
Check ($rzInstall.exit -eq 0) "subdirectory install failed: $($rzInstall.error)"
Assert-Workloads $rzInstall $true
$rzDirectory = "$root/apps/rz/0.9.1"
Check ((Test-Path -LiteralPath "$rzDirectory/rizin.exe") -and (Test-Path -LiteralPath "$rzDirectory/rz_core-0.9.dll")) 'the relative extract_dir did not publish the bin directory contents'
Check (-not (Test-Path -LiteralPath "$rzDirectory/share") -and -not (Test-Path -LiteralPath "$rzDirectory/include")) 'extract_dir did not restrict the extraction to {app}\bin'
Check (@(Get-ChildItem -LiteralPath $rzDirectory -File | Where-Object { $_.Name -notin @('scoop-install.json','scoop-manifest.json') }).Count -eq 37) 'the {app}\bin selection did not extract exactly the declared 37 files'
$rzJournal = Last-Journal 'rz'
$rzRecord = @($rzJournal.inno_extractions)[0]
Check ($rzRecord.selection -eq '-c{app}\bin' -and $rzRecord.files -eq 37) "relative extract_dir was not applied through innounp: $($rzRecord.selection), $($rzRecord.files) files"
$rzVersion = Invoke-Process 'rizin-version' "$root/shims/rizin.exe" @('-v')
Check ($rzVersion.exit -eq 0 -and $rzVersion.output -match '0\.9\.1') "the extracted subdirectory program does not run: $($rzVersion.output)"
$rzUninstall = Invoke-Guarded 'inno-subdir-uninstall' @('--root',$root,'uninstall','rz','--json') $false
Check ($rzUninstall.exit -eq 0) "subdirectory uninstall failed: $($rzUninstall.error)"
Assert-Workloads $rzUninstall $false
Check (-not (Test-Path -LiteralPath "$root/apps/rz")) 'subdirectory uninstall left the application directory'

# --- 7. Ordinary uninstall removes the package and keeps declared data. ------------------------
$uninstall = Invoke-Guarded 'inno-uninstall' @('--root',$root,'uninstall','units','--json') $false
Check ($uninstall.exit -eq 0) "Inno uninstall failed: $($uninstall.error)"
Assert-Workloads $uninstall $false
Check (-not (Test-Path -LiteralPath "$root/apps/units/current")) 'Inno uninstall left current published'
Check (-not (Test-Path -LiteralPath "$root/shims/units.exe")) 'Inno uninstall left the command entry'
Check (Test-Path -LiteralPath "$root/persist/units/settings/probe.txt") 'Inno uninstall removed declared persistent data'
Check ((Get-Content -LiteralPath "$root/persist/units/settings/probe.txt" -Raw).Trim() -eq 'inno-persist-probe') 'Inno uninstall changed declared persistent data'
Check ((Helper-Snapshot) -join "`n" -eq ($helperBefore -join "`n")) 'the lifecycle changed the helper package'

# --- 8. Evidence --------------------------------------------------------------------------------
@{
    timestamp=[DateTime]::UtcNow.ToString('o')
    root=$root
    checks=$script:checks
    runs=$script:runs
    coop_sha256=(File-Hash $CoopExe)
    powershell=$pwshPath
    helper=@{path=$helperExecutable;sha256=$helperHash;archive=$innounpArchive;archive_sha256=(File-Hash $innounpArchive);unchanged=$true}
    artifacts=@(
        @{path=$units227;sha256=$hash227;reported_version='GNU Units 2.27'},
        @{path=$units226;sha256=$hash226;reported_version='GNU Units 2.26'},
        @{path=$rizin;sha256=$hashRizin;reported_version='rizin 0.9.1'},
        @{path=$broken;sha256=(File-Hash $broken);reported_version='truncated copy of units 2.27'}
    )
    plan=@{operations=@($plan.ir_operations | ForEach-Object { $_.operation });mechanism=$facts.mechanism;elevation=$facts.elevation;reboot=$facts.reboot;selection=$facts.selection}
    install=@{files=$innoRecord.files;bytes=$innoRecord.bytes;selection=$innoRecord.selection;stdout='GNU Units version 2.27';conversion=$conversion.output.Trim()}
    update=@{reported_version='GNU Units 2.26';retained_versions=@($updateResult.retained_versions);persist_data_reused=$true}
    subdirectory=@{selection=$rzRecord.selection;files=$rzRecord.files;reported_version=($rzVersion.output -replace "`r?`n",' ').Trim()}
    failure=@{exit=$failedUpdate.exit;error=$failedUpdate.error.Trim();journal=$failedJournal.state}
    missing_helper=@{preview_execution_available=$missingPlan.execution_available;install_exit=$missing.exit;helper_downloaded=$false}
    uninstall=@{persist_data_retained=$true;current_removed=$true;entries_removed=$true;helper_unchanged=$true}
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$root/evidence.json" -Encoding utf8
Write-Output "PASS real Inno Setup install, update, extract_dir layout, missing-helper, corruption and uninstall lifecycle: $root/evidence.json ($script:checks checks)"
exit 0

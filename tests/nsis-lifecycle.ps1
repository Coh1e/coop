param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# R14 / #35: real NSIS installer lifecycle through the real CLI in a project-local Scoop layout.
# The vendor NSIS setup.exe is never executed: the 7-Zip helper that Scoop already installs in the
# same root unpacks the payload with Scoop's Expand-7zipArchive arguments. Real apngasm 3.1.1/3.1.3
# NSIS installers provide install, update and failure evidence; the helper itself is first installed
# from the pinned 7-Zip 26.05 MSI so the root looks like a normal shared Scoop root, and it must
# remain byte-identical afterwards.
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$coopDirectory = Split-Path $CoopExe
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$guard = Join-Path $coopDirectory 'process_guard.exe'
$apng313 = Join-Path $archives 'apngasm-3.1.3-AMD64.exe'
$apng311 = Join-Path $archives 'apngasm-3.1.1-AMD64.exe'
$elm = Join-Path $archives 'elm-0.19.3-installer.exe'
$msi2605 = Join-Path $archives '7z2605-x64.msi'
$pwshPath = (Get-Process -Id $PID).Path
foreach ($path in @($guard,$apng313,$apng311,$elm,$msi2605,$pwshPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing fixed test input: $path; run scripts/fetch-deps.ps1" }
}

$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/main/bucket","$root/temp","$root/build","$root/programs" -Force | Out-Null
$script:runs = 0
$script:checks = 0

function Check([bool]$condition,[string]$message) {
    if (-not $condition) { throw "NSIS lifecycle check failed: $message" }
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
# The guard observes the real process tree. Install and update legitimately start the declared
# 7-Zip helper, so children are allowed but must be named; previews, the blocked operation and
# uninstall must start no child at all. A vendor NSIS setup executable is never allowed.
function Invoke-Guarded([string]$label,[string[]]$arguments,[bool]$allowHelper) {
    $previousTimeout = $env:COOP_PROCESS_GUARD_TIMEOUT_MS
    $previousChildren = $env:COOP_PROCESS_GUARD_ALLOW_CHILDREN
    $env:COOP_PROCESS_GUARD_TIMEOUT_MS = '120000'
    if ($allowHelper) { $env:COOP_PROCESS_GUARD_ALLOW_CHILDREN = '1' }
    try { return Invoke-Process $label $guard (@($CoopExe)+$arguments) @{} }
    finally {
        if ($null -eq $previousTimeout) { Remove-Item Env:COOP_PROCESS_GUARD_TIMEOUT_MS -ErrorAction SilentlyContinue }
        else { $env:COOP_PROCESS_GUARD_TIMEOUT_MS = $previousTimeout }
        if ($null -eq $previousChildren) { Remove-Item Env:COOP_PROCESS_GUARD_ALLOW_CHILDREN -ErrorAction SilentlyContinue }
        else { $env:COOP_PROCESS_GUARD_ALLOW_CHILDREN = $previousChildren }
    }
}
function Workload-Names($result) {
    return @([regex]::Matches($result.error,'Workload process: (.+)') | ForEach-Object { $_.Groups[1].Value.Trim() })
}
function Assert-Workloads($result,[string[]]$allowed = @()) {
    $names = @(Workload-Names $result)
    Check ($names.Count -eq (1+$allowed.Count)) "unexpected workload processes: $($names -join '; ') ($($result.error))"
    Check ($names[0] -match 'coop\.exe$') "first workload process is not coop.exe: $($names -join '; ')"
    Check (-not ($names -match '(?i)msiexec|setup\.exe|apngasm\.exe')) "a vendor installer process was started: $($names -join '; ')"
    $observed = @($names | Select-Object -Skip 1)
    foreach ($pattern in $allowed) {
        Check (@($observed | Where-Object { $_ -match $pattern }).Count -eq 1) "expected exactly one workload matching $pattern : $($names -join '; ')"
    }
    Check ($result.error -match ("Observed workload processes: "+$names.Count)) "the guard did not observe the expected process count: $($result.error)"
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
function Get-TreeSnapshot([string]$path) {
    return @(Get-ChildItem -LiteralPath $path -Recurse -File | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($path.Length).Replace('\','/')+'|'+(File-Hash $_.FullName)
    })
}
function Program-Banner([string]$shim) {
    return Invoke-Process 'program-banner' $shim @()
}

$hash313 = File-Hash $apng313
$hash311 = File-Hash $apng311
$preInstall = @'
'$PLUGINSDIR', 'Uninstall.exe' | ForEach-Object { Remove-Item "$dir\$_" -Recurse -Force }
'@
$apngManifest = {
    param($version,$path,$hash)
    @{version=$version;url=((File-Uri $path)+'#/dl.7z');hash=$hash;pre_install=$preInstall;
      bin=@('bin\apngasm.exe',@('bin\apngasm.exe','apngasm-cli'))}
}

# --- 0. Provision the shared-root 7-Zip helper the same way Scoop gets it: an installed 7-Zip. --
Write-Manifest '7zip' @{version='26.05';url=(File-Uri $msi2605);hash=(File-Hash $msi2605);
    extract_dir='Files\7-Zip';bin=@('7z.exe')}
$helperInstall = Invoke-Guarded 'nsis-helper-install' @('--root',$root,'install','main/7zip','--json') $false
Check ($helperInstall.exit -eq 0) "7-Zip helper provisioning failed: $($helperInstall.error)"
Assert-Workloads $helperInstall @()
$helperExecutable = [IO.Path]::GetFullPath("$root/apps/7zip/current/7z.exe")
Check (Test-Path -LiteralPath $helperExecutable) 'the 7-Zip helper was not published at the Scoop-compatible path'
$helperVersion = Invoke-Process 'helper-version' $helperExecutable @()
Check ($helperVersion.exit -eq 0 -and $helperVersion.output -match '7-Zip 26\.05') "the provisioned helper is not 7-Zip 26.05: $($helperVersion.output)"
$helperHash = File-Hash $helperExecutable
$helperBefore = @(Get-TreeSnapshot "$root/apps/7zip/26.05")

# --- 1. Preview states the NSIS route, the helper and the vendor-installer boundary. -------------
Write-Manifest 'apng' (& $apngManifest '3.1.3' $apng313 $hash313)
$transactionsBefore = @(Get-ChildItem "$root/.coop/transactions" -Directory -ErrorAction SilentlyContinue).Count
$preview = Invoke-Guarded 'nsis-preview' @('--root',$root,'install','main/apng','--dry-run','--json') $false
Check ($preview.exit -eq 0) "NSIS preview failed: $($preview.error)"
Assert-Workloads $preview @()
$plan = Parse-Json 'nsis-preview' $preview
Check ($plan.execution_available -eq $true) "NSIS preview is not executable: $(@($plan.diagnostics) | ConvertTo-Json -Compress)"
Check ($plan.artifacts[0].archive -eq '7z' -and $plan.artifacts[0].extraction -eq 'native-archive-or-external-7zip-nsis') 'NSIS payload artifact or extraction method is not reported'
Check ($plan.artifacts[0].payload_check -match 'NSIS' -and $plan.artifacts[0].requires_elevation -eq $false -and
    $plan.artifacts[0].reboot_required -eq $false -and $plan.artifacts[0].vendor_installer_executed -eq $false) 'NSIS preview does not state the payload check and the vendor-installer boundary'
$facts = $plan.package.nsis_extraction
Check ($facts.mechanism -match '7-Zip' -and $facts.helper_available -eq $true -and $facts.installer_executed -eq $false) 'NSIS preview does not describe the external helper mechanism'
Check (Same-Path $facts.helper $helperExecutable) "NSIS preview does not name the helper in the selected root: $($facts.helper)"
Check ($facts.content_detection -match 'after digest verification' -and $facts.signature -match 'NullsoftInst') 'NSIS preview does not describe content detection'
Check ($facts.helper_policy -match 'software dependency' -and $facts.helper_policy -match 'never downloads') 'NSIS preview does not separate the helper from Coop core dependencies'
Check ($facts.arguments -match '-xr!\*\.nsis' -and $facts.arguments -match '-ir!' -and $facts.arguments -match '-y') 'NSIS preview does not describe the Expand-7zipArchive arguments'
Check ($facts.elevation -match 'not requested' -and $facts.reboot -match 'not required' -and
    $facts.installer_effects -match 'not executed') 'NSIS preview does not state the permission, reboot and effect boundary'
Check (@($plan.external_tools).Count -eq 1 -and $plan.external_tools[0].name -match '^7-Zip' -and
    $plan.external_tools[0].available -eq $true -and $plan.external_tools[0].enabled -eq $true -and
    (Same-Path $plan.external_tools[0].path $helperExecutable)) 'NSIS preview does not disclose the detected 7-Zip helper'
Check ($plan.external_tools[0].limitation -match 'NSIS' -and $plan.external_tools[0].limitation -match 'native') 'NSIS external tool limitation omits the conditional use'
Check (@($plan.capabilities | Where-Object { $_.id -eq 'nsis-installer' -and $_.supported -eq $true }).Count -eq 1) 'nsis-installer capability is not reported as supported'
Check (@($plan.diagnostics | Where-Object { $_.code -eq 'execution-blocked' }).Count -eq 0) 'NSIS preview reports an execution blocker'
Check ($plan.lifecycle_checks.nsis_extraction -match '7-Zip') 'NSIS lifecycle check does not name the helper'
Check ((@($plan.ir_operations | ForEach-Object { $_.operation }) -join ',') -eq 'download,verify,extract,hook,publish-current,entries,commit-state') 'NSIS plan does not carry the expected operation order'
Check (-not (Test-Path -LiteralPath "$root/apps/apng") -and
    @(Get-ChildItem "$root/.coop/transactions" -Directory -ErrorAction SilentlyContinue).Count -eq $transactionsBefore) 'NSIS preview wrote installation state'
Check (((Get-TreeSnapshot "$root/apps/7zip/26.05") -join "`n") -eq ($helperBefore -join "`n")) 'the preview changed the helper package'

# --- 2. Install the real 3.1.3 NSIS installer payload. -----------------------------------------
$install = Invoke-Guarded 'nsis-install' @('--root',$root,'install','main/apng','--json') $true
Check ($install.exit -eq 0) "NSIS install failed: $($install.error)"
Assert-Workloads $install @('7z\.exe$','pwsh\.exe$')
Check (@((Workload-Names $install) | Where-Object { $_ -match '7z\.exe$' })[0] -match '(?i)apps[\\/]7zip') 'the 7-Zip helper did not come from the shared root'
$installResult = Parse-Json 'nsis-install' $install
Check ($installResult.status -eq 'success') 'NSIS install result is not successful'
$versionDirectory = Join-Path $root 'apps/apng/3.1.3'
foreach ($relative in @('bin/apngasm.exe','bin/apngasm.dll','bin/msvcp120.dll','include/apngasm.h')) {
    Check (Test-Path -LiteralPath (Join-Path $versionDirectory $relative)) "NSIS layout is missing $relative"
}
Check (-not (Test-Path -LiteralPath "$versionDirectory/`$PLUGINSDIR")) 'the NSIS $PLUGINSDIR was published instead of being removed by the Manifest hook'
Check (-not (Test-Path -LiteralPath "$versionDirectory/Uninstall.exe")) 'the vendor NSIS Uninstall.exe was published'
Check (-not (Test-Path -LiteralPath "$versionDirectory/dl.7z")) 'the NSIS payload was copied into the version directory'
Check ([IO.Path]::GetFullPath([string](Get-Item -LiteralPath "$root/apps/apng/current").Target) -eq [IO.Path]::GetFullPath($versionDirectory)) 'NSIS current link points at the wrong version'
Check (Test-Path -LiteralPath "$root/shims/apngasm.exe") 'NSIS install did not create the Scoop-compatible command entry'
Check (Test-Path -LiteralPath "$root/shims/apngasm-cli.exe") 'NSIS install did not create the aliased command entry'
$installedBanner = Program-Banner "$root/shims/apngasm.exe"
Check ($installedBanner.output -match 'apngasm 3\.1\.3') "the installed program reports the wrong version: $($installedBanner.output)"
Check ((Test-Path -LiteralPath "$versionDirectory/scoop-install.json") -and (Test-Path -LiteralPath "$versionDirectory/scoop-manifest.json")) 'NSIS install did not write the shared Scoop records'
$installJournal = Last-Journal 'apng'
Check ($installJournal.state -eq 'committed' -and (@($installJournal.observed_steps) -join ',') -eq (@($plan.ir_operations | ForEach-Object { $_.operation }) -join ',')) 'NSIS journal does not match the previewed plan'
$nsisRecord = @($installJournal.nsis_extractions)[0]
Check ($nsisRecord.mechanism -match '7-Zip' -and (Same-Path $nsisRecord.helper $helperExecutable) -and
    $nsisRecord.helper_sha256 -eq $helperHash) 'NSIS journal does not record the helper it used'
Check ($nsisRecord.exit_code -eq 0 -and (@($nsisRecord.arguments)[0] -eq 'x') -and
    (@($nsisRecord.arguments) -contains '-xr!*.nsis') -and (@($nsisRecord.arguments) -contains '-y')) 'NSIS journal does not record the Expand-7zipArchive arguments'
Check ($nsisRecord.detection.signature -match 'NullsoftInst' -and $nsisRecord.detection.offset -eq 65028) 'NSIS journal does not record the content detection that selected the helper'
Check ($nsisRecord.installer_executed -eq $false -and $nsisRecord.elevation -match 'not requested' -and
    $nsisRecord.reboot -match 'not scheduled' -and $nsisRecord.installer_effects -match 'not executed') 'NSIS journal does not record the extraction boundary'
Check ($nsisRecord.files -eq 16 -and $nsisRecord.bytes -eq 2549477) "NSIS journal extraction totals are wrong: $($nsisRecord.files) files, $($nsisRecord.bytes) bytes"
Check ($nsisRecord.stdout_tail -match 'Everything is Ok') 'NSIS journal does not keep the helper output'
Check (((Get-TreeSnapshot "$root/apps/7zip/26.05") -join "`n") -eq ($helperBefore -join "`n")) 'the install changed the helper package'
$installedList = Invoke-Coop 'nsis-list' @('--root',$root,'list','--json')
Check ($installedList.exit -eq 0 -and $installedList.output -match 'apng') 'Coop list does not see the NSIS installation'
$image313 = Get-TreeSnapshot $versionDirectory

# --- 3. Update to the real 3.1.1 NSIS installer and keep the old version. -----------------------
Write-Manifest 'apng' (& $apngManifest '3.1.1' $apng311 $hash311)
$updatePreview = Invoke-Guarded 'nsis-update-preview' @('--root',$root,'update','apng','--dry-run','--json') $false
Check ($updatePreview.exit -eq 0) "NSIS update preview failed: $($updatePreview.error)"
Assert-Workloads $updatePreview @()
Check ((Parse-Json 'nsis-update-preview' $updatePreview).execution_available -eq $true) 'NSIS update preview is not executable'
$update = Invoke-Guarded 'nsis-update' @('--root',$root,'update','apng','--json') $true
Check ($update.exit -eq 0) "NSIS update failed: $($update.error)"
Assert-Workloads $update @('7z\.exe$','pwsh\.exe$')
$updateResult = Parse-Json 'nsis-update' $update
Check ($updateResult.status -eq 'success' -and ($updateResult.retained_versions -contains '3.1.3')) 'NSIS update did not retain the previous version'
Check ([IO.Path]::GetFullPath([string](Get-Item -LiteralPath "$root/apps/apng/current").Target) -eq [IO.Path]::GetFullPath((Join-Path $root 'apps/apng/3.1.1'))) 'NSIS update did not repoint current'
$updatedBanner = Program-Banner "$root/shims/apngasm.exe"
Check ($updatedBanner.output -match 'apngasm 3\.1\.1') "NSIS update did not switch the real program version: $($updatedBanner.output)"
Check ((Test-Path -LiteralPath "$root/apps/apng/3.1.3/bin/apngasm.exe") -and (Test-Path -LiteralPath "$root/apps/apng/3.1.1/bin/apngasm.exe")) 'NSIS update did not keep both version directories'
$updateJournal = Last-Journal 'apng'
Check ($updateJournal.state -eq 'committed' -and @($updateJournal.nsis_extractions).Count -eq 1) 'NSIS update journal is incomplete'
Check ((@($updateJournal.nsis_extractions)[0].files) -eq 16) 'NSIS update did not unpack the new payload through the helper'
$image311 = Get-TreeSnapshot "$root/apps/apng/3.1.1"
Check (($image311 -join "`n") -ne ($image313 -join "`n")) 'NSIS update did not actually replace the extracted files'

# --- 4. A truncated NSIS payload fails accurately and protects the installed version. -----------
$broken = Join-Path $root 'build/broken-apngasm.exe'
[IO.File]::WriteAllBytes($broken,[IO.File]::ReadAllBytes($apng313)[0..99999])
Write-Manifest 'apng' (& $apngManifest '3.1.9' $broken (File-Hash $broken))
$failedUpdate = Invoke-Guarded 'nsis-broken-update' @('--root',$root,'update','apng','--json') $true
Check ($failedUpdate.exit -ne 0) 'Truncated NSIS update unexpectedly succeeded'
Check ($failedUpdate.error -match '7-Zip could not unpack the NSIS installer') "Truncated NSIS failure was not reported by the helper: $($failedUpdate.error)"
Assert-Workloads $failedUpdate @('7z\.exe$')
Check ((Program-Banner "$root/shims/apngasm.exe").output -match 'apngasm 3\.1\.1') 'Truncated NSIS update changed the working program'
Check (-not (Test-Path -LiteralPath "$root/apps/apng/3.1.9")) 'Truncated NSIS update published a version directory'
$failedJournal = Last-Journal 'apng'
Check ($failedJournal.state -eq 'rolled-back') 'Truncated NSIS update journal does not show rollback'
Check (-not (@($failedJournal.PSObject.Properties.Name) -contains 'nsis_extractions')) 'Truncated NSIS update recorded a successful extraction'
Check (((Get-TreeSnapshot "$root/apps/7zip/26.05") -join "`n") -eq ($helperBefore -join "`n")) 'the failed update changed the helper package'

# --- 5. The helper is a declared dependency: missing means blocked, never downloaded. -----------
Write-Manifest 'apngnsis' @{version='3.1.3';url=((File-Uri $apng313)+'#/dl.7z');hash=$hash313;pre_install=$preInstall;
    bin=@(,@('bin\apngasm.exe','apngnsis'))}
Rename-Item -LiteralPath "$root/apps/7zip" -NewName '7zip-absent'
try {
    $missingPreview = Invoke-Guarded 'nsis-missing-preview' @('--root',$root,'install','main/apngnsis','--dry-run','--json') $false
    Check ($missingPreview.exit -eq 0) "missing-helper preview failed: $($missingPreview.error)"
    Assert-Workloads $missingPreview @()
    $missingPlan = Parse-Json 'nsis-missing-preview' $missingPreview
    Check ($missingPlan.package.nsis_extraction.helper_available -eq $false) 'missing-helper preview still claims a helper'
    Check ($missingPlan.package.nsis_extraction.helper_problem -match 'never downloads') 'missing-helper preview does not state the no-download policy'
    Check (@($missingPlan.external_tools | Where-Object { $_.name -match '^7-Zip' -and $_.available -eq $false -and $_.limitation -match 'looked for' }).Count -eq 1) 'missing-helper preview does not declare the unavailable external tool'
    $missing = Invoke-Guarded 'nsis-missing-install' @('--root',$root,'install','main/apngnsis','--json') $false
    Check ($missing.exit -ne 0) 'missing-helper install unexpectedly succeeded'
    Check ($missing.error -match '7-Zip helper' -and $missing.error -match 'never downloads') "missing-helper failure is not explicit: $($missing.error)"
    Assert-Workloads $missing @()
    Check (-not (Test-Path -LiteralPath "$root/apps/apngnsis") -and -not (Test-Path -LiteralPath "$root/.coop/packages/apngnsis.json")) 'missing-helper install wrote package state'
    Check (-not (Test-Path -LiteralPath "$root/apps/7zip")) 'Coop downloaded or recreated the helper'
} finally {
    Rename-Item -LiteralPath "$root/apps/7zip-absent" -NewName '7zip'
}
Check (((Get-TreeSnapshot "$root/apps/7zip/26.05") -join "`n") -eq ($helperBefore -join "`n")) 'the missing-helper attempt changed the restored helper package'

# --- 6. Ordinary uninstall removes the package and leaves the shared helper untouched. ----------
$uninstall = Invoke-Guarded 'nsis-uninstall' @('--root',$root,'uninstall','apng','--json') $false
Check ($uninstall.exit -eq 0) "NSIS uninstall failed: $($uninstall.error)"
Assert-Workloads $uninstall @()
Check (-not (Test-Path -LiteralPath "$root/apps/apng/current")) 'NSIS uninstall left current published'
Check (-not (Test-Path -LiteralPath "$root/shims/apngasm.exe")) 'NSIS uninstall left the command entry'
Check (-not (Test-Path -LiteralPath "$root/shims/apngasm-cli.exe")) 'NSIS uninstall left the aliased command entry'
Check (-not (Test-Path -LiteralPath "$root/apps/apng/3.1.1")) 'NSIS uninstall left the current version directory'
Check (Test-Path -LiteralPath "$root/apps/apng/3.1.3") 'NSIS uninstall deleted the retained previous version instead of keeping it for cleanup'
Check (-not (Test-Path -LiteralPath "$root/.coop/packages/apng.json")) 'NSIS uninstall left the managed package record'
Check (-not (Test-Path -LiteralPath "$root/apps/apngnsis")) 'the blocked NSIS install left an application directory'
$finalList = Invoke-Coop 'nsis-list-final' @('--root',$root,'list','--json')
Check ($finalList.exit -eq 0) "final list failed: $($finalList.error)"
$finalEntries = @(Parse-Json 'nsis-list-final' $finalList)
$apngEntry = @($finalEntries | Where-Object { $_.name -eq 'apng' })
Check ($apngEntry.Count -eq 1 -and $apngEntry[0].status -eq 'uninstalled' -and $null -eq $apngEntry[0].version -and
    @($apngEntry[0].old_versions).Count -eq 1 -and @($apngEntry[0].old_versions)[0].version -eq '3.1.3' -and
    @($apngEntry[0].old_versions)[0].status -eq 'cleanable') 'Coop does not report the uninstalled NSIS package and its retained cleanable version accurately'
Check (((Get-TreeSnapshot "$root/apps/7zip/26.05") -join "`n") -eq ($helperBefore -join "`n")) 'the lifecycle changed the helper package'

# --- 7. A real NSIS package with extract_dir: Scoop's Expand-7zipArchive -ir! selection. ---------
$hashElm = File-Hash $elm
Write-Manifest 'elm' @{version='0.19.3';url=((File-Uri $elm)+'#/dl.7z');hash=$hashElm;extract_dir='bin';bin='elm.exe'}
$elmPreview = Invoke-Guarded 'nsis-subdir-preview' @('--root',$root,'install','main/elm','--dry-run','--json') $false
Check ($elmPreview.exit -eq 0) "NSIS subdirectory preview failed: $($elmPreview.error)"
Assert-Workloads $elmPreview @()
$elmPlan = Parse-Json 'nsis-subdir-preview' $elmPreview
Check ($elmPlan.execution_available -eq $true) "NSIS subdirectory preview is blocked: $(@($elmPlan.diagnostics) | ConvertTo-Json -Compress)"
Check ($elmPlan.artifacts[0].extract_dir -eq 'bin' -and $elmPlan.artifacts[0].extraction -eq 'native-archive-or-external-7zip-nsis') 'NSIS subdirectory artifact is not reported'
Check ($elmPlan.package.nsis_extraction.arguments -match '-ir!<extract_dir>' -and
    $elmPlan.package.nsis_extraction.arguments -match 'Expand-7zipArchive') 'NSIS subdirectory preview does not describe the -ir! selection'
$elmInstall = Invoke-Guarded 'nsis-subdir-install' @('--root',$root,'install','main/elm','--json') $true
Check ($elmInstall.exit -eq 0) "NSIS subdirectory install failed: $($elmInstall.error)"
Assert-Workloads $elmInstall @('7z\.exe$')
$elmDirectory = "$root/apps/elm/0.19.3"
Check (Test-Path -LiteralPath "$elmDirectory/elm.exe") 'the NSIS extract_dir selection did not publish bin\elm.exe at the package root'
Check (-not (Test-Path -LiteralPath "$elmDirectory/bin")) 'the NSIS extract_dir name was kept instead of promoting its contents'
Check (@(Get-ChildItem -LiteralPath $elmDirectory -File | Where-Object { $_.Name -notin @('scoop-install.json','scoop-manifest.json') }).Count -eq 1) 'the NSIS extract_dir selection published more than the one declared file'
$elmVersion = Invoke-Process 'elm-version' "$root/shims/elm.exe" @('--version')
Check ($elmVersion.exit -eq 0 -and $elmVersion.output -match '0\.19\.3') "the extracted elm binary does not run: $($elmVersion.output)"
$elmJournal = Last-Journal 'elm'
$elmRecord = @($elmJournal.nsis_extractions)[0]
Check ($elmRecord.selection -eq '-ir!bin\*' -and (@($elmRecord.arguments) -contains '-ir!bin\*')) 'NSIS journal does not record the -ir! extract_dir selection'
Check ($elmRecord.files -eq 1 -and $elmRecord.bytes -eq 34455552) "NSIS extract_dir journal totals are wrong: $($elmRecord.files) files, $($elmRecord.bytes) bytes"
$elmUninstall = Invoke-Guarded 'nsis-subdir-uninstall' @('--root',$root,'uninstall','elm','--json') $false
Check ($elmUninstall.exit -eq 0) "NSIS subdirectory uninstall failed: $($elmUninstall.error)"
Assert-Workloads $elmUninstall @()
Check (-not (Test-Path -LiteralPath "$root/apps/elm")) 'NSIS subdirectory uninstall left the application directory'
Check (-not (Test-Path -LiteralPath "$root/shims/elm.exe")) 'NSIS subdirectory uninstall left its command entry'
Check (((Get-TreeSnapshot "$root/apps/7zip/26.05") -join "`n") -eq ($helperBefore -join "`n")) 'NSIS subdirectory uninstall changed the helper'

# --- 8. Evidence --------------------------------------------------------------------------------
@{
    timestamp=[DateTime]::UtcNow.ToString('o')
    root=$root
    checks=$script:checks
    runs=$script:runs
    coop_sha256=(File-Hash $CoopExe)
    powershell=$pwshPath
    helper=@{path=$helperExecutable;sha256=$helperHash;
        version=@(($helperVersion.output -split "`r?`n") | Where-Object { $_.Trim() })[0].Trim();
        source=$msi2605;source_sha256=(File-Hash $msi2605);unchanged=$true}
    artifacts=@(
        @{path=$apng313;sha256=$hash313;reported_version='apngasm 3.1.3'},
        @{path=$apng311;sha256=$hash311;reported_version='apngasm 3.1.1'},
        @{path=$elm;sha256=$hashElm;reported_version='elm 0.19.3'},
        @{path=$broken;sha256=(File-Hash $broken);reported_version='truncated 100000-byte copy of apngasm 3.1.3 NSIS installer'}
    )
    plan=@{operations=@($plan.ir_operations | ForEach-Object { $_.operation });mechanism=$facts.mechanism;
        detection=$facts.content_detection;arguments=$facts.arguments;elevation=$facts.elevation;reboot=$facts.reboot}
    install=@{files=$nsisRecord.files;bytes=$nsisRecord.bytes;detection_offset=$nsisRecord.detection.offset;
        reported_version='apngasm 3.1.3'}
    update=@{reported_version='apngasm 3.1.1';retained_versions=@($updateResult.retained_versions)}
    subdirectory=@{selection=$elmRecord.selection;files=$elmRecord.files;reported_version='elm 0.19.3'}
    failure=@{exit=$failedUpdate.exit;error=$failedUpdate.error.Trim();journal=$failedJournal.state}
    missing_helper=@{preview_helper_available=$missingPlan.package.nsis_extraction.helper_available;
        install_exit=$missing.exit;helper_downloaded=$false}
    uninstall=@{current_removed=$true;entries_removed=$true;retained_version_kept=$true;helper_unchanged=$true}
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$root/evidence.json" -Encoding utf8
Write-Output "PASS real NSIS install, update, missing-helper, truncation and uninstall lifecycle: $root/evidence.json ($script:checks checks)"
exit 0

param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$coopDirectory = Split-Path $CoopExe
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$fixture1 = Join-Path $coopDirectory 'fixture-1.exe'
$fixture2 = Join-Path $coopDirectory 'fixture-2.exe'
$guard = Join-Path $coopDirectory 'process_guard.exe'
$nodeArchive = Join-Path $archives 'node-v26.12.1-win-x64.7z'
$pwshPath = (Get-Process -Id $PID).Path
foreach ($path in @($fixture1,$fixture2,$guard,$nodeArchive,$pwshPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing fixed test input: $path; run scripts/fetch-deps.ps1" }
}

$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/main/bucket","$root/buckets/extras/bucket","$root/temp","$root/build","$root/programs" -Force | Out-Null
$script:runs = 0
$script:checks = 0

function Check([bool]$condition,[string]$message) {
    if (-not $condition) { throw "installer check failed: $message" }
    ++$script:checks
}
function File-Hash([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
function Write-Manifest([string]$bucket,[string]$name,[hashtable]$manifest) {
    $json = $manifest | ConvertTo-Json -Depth 16
    [IO.File]::WriteAllText("$root/buckets/$bucket/bucket/$name.json",$json,[Text.UTF8Encoding]::new($false))
}
function New-PayloadZip([string]$name,[hashtable]$files) {
    $stage = "$root/build/$name"
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($entry in $files.GetEnumerator()) {
        $target = Join-Path $stage $entry.Key
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        if ($entry.Value -is [byte[]]) { [IO.File]::WriteAllBytes($target,$entry.Value) }
        else { [IO.File]::WriteAllText($target,[string]$entry.Value,[Text.UTF8Encoding]::new($false)) }
    }
    $zip = "$root/build/$name.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($stage,$zip)
    return $zip
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
    if (-not $process.WaitForExit(300000)) { $process.Kill($true); throw "$label timed out" }
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
function Get-CorpusManifest([string]$relative) {
    return Get-Content -LiteralPath (Join-Path $PSScriptRoot $relative) -Raw | ConvertFrom-Json
}
function Get-WindowsInstallerCacheState {
    $directory = Join-Path $env:WINDIR 'Installer'
    if (-not (Test-Path -LiteralPath $directory)) { return @() }
    return @(Get-ChildItem -LiteralPath $directory -Filter 'SourceHash*' -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object { "$($_.Name)|$($_.LastWriteTimeUtc.ToString('o'))|$($_.Length)" })
}
function Operations-After([object]$plan,[string]$kind,[object[]]$scriptPhases) {
    $operations = @($plan.ir_operations)
    $publish = -1
    for ($index = 0; $index -lt $operations.Count; ++$index) { if ($operations[$index].operation -eq $kind) { $publish = $index; break } }
    $positions = @{}
    for ($index = 0; $index -lt $operations.Count; ++$index) {
        $operation = $operations[$index]
        if ($operation.operation -ne 'hook') { continue }
        $phase = $plan.package.scripts[$operation.index].phase
        $positions[$phase] = $index
    }
    return @{publish=$publish;positions=$positions;operations=$operations}
}

$nodeHash = File-Hash $nodeArchive
$installerCacheBefore = @(Get-WindowsInstallerCacheState)

# --- 1. Native 7z archive extraction with the real Main/nodejs artifact. ----
$nodeManifest = @{version='26.12.1';url=(File-Uri $nodeArchive);hash=$nodeHash;
    extract_dir='node-v26.12.1-win-x64';bin='node.exe'}
Write-Manifest 'main' 'nodepkg' $nodeManifest
$nodePreview = Invoke-Guard 'node-preview' @('--root',$root,'install','main/nodepkg','--dry-run','--json')
Check ($nodePreview.exit -eq 0) "7z preview failed: $($nodePreview.error)"
Check ($nodePreview.error -match 'Observed workload processes: 1') '7z preview started an external decompressor'
$nodePlan = Parse-Json 'node-preview' $nodePreview
Check ($nodePlan.execution_available -eq $true) '7z archive path stayed disabled'
Check ($nodePlan.artifacts[0].archive -eq '7z') '7z preview did not report the 7z artifact'
Check (@($nodePlan.external_tools).Count -eq 0) 'native 7z extraction falsely requires an external tool'
$nodeInstall = Invoke-Guard 'node-install' @('--root',$root,'install','main/nodepkg','--json') @{COOP_PROCESS_GUARD_TIMEOUT_MS='120000'}
Check ($nodeInstall.exit -eq 0) "7z install failed: $($nodeInstall.error)"
Check ($nodeInstall.error -match 'Observed workload processes: 1') '7z install started an external decompressor or PowerShell'
$nodeVersion = ((& "$root/shims/node.exe" --version) -join "`n")
Check ($LASTEXITCODE -eq 0 -and $nodeVersion.Trim() -eq 'v26.12.1') "7z archive entry ran wrong program: $nodeVersion"
Check (Test-Path -LiteralPath "$root/apps/nodepkg/current/node.exe") '7z archive layout is wrong'
$nodeUninstall = Invoke-Coop 'node-uninstall' @('--root',$root,'uninstall','nodepkg','--json')
Check ($nodeUninstall.exit -eq 0) "7z uninstall failed: $($nodeUninstall.error)"

# --- 2. installer.script runs in Scoop order with the documented context. ---
$installerZip = New-PayloadZip 'installerpkg' @{'app.exe'=[IO.File]::ReadAllBytes($fixture1);'payload/inner.txt'='inner'}
$installerScript = @(
    '$marker = Join-Path -Path $dir -ChildPath ''installer-context.txt''',
    'Set-Content -Path $marker -Value "cmd_defined=$($null -ne $cmd)|$app|$version|$architecture|$fname" -Encoding Ascii'
)
$preInstallScript = @('Set-Content -Path "$dir\pre.txt" -Value "pre" -Encoding Ascii')
$postInstallScript = @('Copy-Item "$dir\installer-context.txt" "$dir\post-seen.txt"')
Write-Manifest 'main' 'installerscript' @{version='1';url=(File-Uri $installerZip);hash=(File-Hash $installerZip);bin='app.exe';
    pre_install=$preInstallScript;installer=@{script=$installerScript};post_install=$postInstallScript}
$installerPreview = Invoke-Coop 'installer-preview' @('--root',$root,'install','main/installerscript','--dry-run','--json')
Check ($installerPreview.exit -eq 0) "installer script preview failed: $($installerPreview.error)"
$installerPlan = Parse-Json 'installer-preview' $installerPreview
Check ($installerPlan.execution_available -eq $true) 'installer script path stayed disabled'
$installerReport = @($installerPlan.package.scripts | Where-Object { $_.phase -eq 'installer' })
Check ($installerReport.Count -eq 1 -and $installerReport[0].host -match 'PowerShell' -and
    $installerReport[0].text -match 'cmd_defined') 'installer script report does not show the real PowerShell host and text'
Check ($installerPlan.package.script_support.library_version -match 'v0\.6\.0') 'installer script preview did not name the pinned Scoop library'
$order = Operations-After $installerPlan 'publish-current' @()
Check ($order.positions['pre_install'] -lt $order.positions['installer'] -and $order.positions['installer'] -lt $order.publish -and
    $order.publish -lt $order.positions['post_install']) 'installer script did not stay between pre_install and current publication'
$installerInstall = Invoke-Coop 'installer-install' @('--root',$root,'install','main/installerscript','--json')
Check ($installerInstall.exit -eq 0) "installer script install failed: $($installerInstall.error)"
$installerResult = Parse-Json 'installer-install' $installerInstall
Check ((@($installerResult.scripts | ForEach-Object { $_.phase }) -join ',') -eq 'pre_install,installer,post_install') 'installer script lifecycle order is wrong'
$installerRun = @($installerResult.scripts | Where-Object { $_.phase -eq 'installer' })[0]
Check ($installerRun.command -eq 'install' -and $installerRun.exit_code -eq 0 -and
    [IO.Path]::GetFullPath($installerRun.directory) -eq [IO.Path]::GetFullPath("$root/apps/installerscript/1")) 'installer script context or exit code is wrong'
$contextText = (Get-Content -LiteralPath "$root/apps/installerscript/1/installer-context.txt" -Raw).Trim()
Check ($contextText -eq 'cmd_defined=False|installerscript|1|64bit|installerpkg.zip') "installer script context is wrong: $contextText"
Check ((Test-Path -LiteralPath "$root/apps/installerscript/1/pre.txt") -and
    ((Get-Content -LiteralPath "$root/apps/installerscript/current/post-seen.txt" -Raw).Trim() -eq $contextText)) 'installer script was not visible to later phases'
$installerJournal = Last-Journal 'installerscript'
Check ((@($installerJournal.scripts | ForEach-Object { $_.phase }) -join ',') -eq 'pre_install,installer,post_install') 'installer journal order is wrong'

$installerUpdateZip = New-PayloadZip 'installerscript2' @{'app.exe'=[IO.File]::ReadAllBytes($fixture2);'payload/inner2.txt'='inner2'}
Write-Manifest 'main' 'installerscript' @{version='2';url=(File-Uri $installerUpdateZip);hash=(File-Hash $installerUpdateZip);bin='app.exe';
    pre_install=$preInstallScript;installer=@{script=$installerScript};post_install=$postInstallScript}
$installerUpdate = Invoke-Coop 'installer-update' @('--root',$root,'update','installerscript','--json')
Check ($installerUpdate.exit -eq 0) "installer script update failed: $($installerUpdate.error)"
$installerUpdateResult = Parse-Json 'installer-update' $installerUpdate
Check ((@($installerUpdateResult.scripts | ForEach-Object { $_.phase }) -join ',') -eq 'pre_install,installer,post_install') 'installer script update order is wrong'
$installerUpdateRun = @($installerUpdateResult.scripts | Where-Object { $_.phase -eq 'installer' })[0]
$updateContext = (Get-Content -LiteralPath "$root/apps/installerscript/2/installer-context.txt" -Raw).Trim()
Check ($installerUpdateRun.command -eq 'update' -and $installerUpdateRun.exit_code -eq 0 -and
    $updateContext -eq 'cmd_defined=False|installerscript|2|64bit|installerscript2.zip') 'installer script update context is wrong'
Check ((Test-Path -LiteralPath "$root/apps/installerscript/1/app.exe") -and ($installerUpdateResult.retained_versions -contains '1')) 'installer script update did not retain the old version'

$installerFailureZip = New-PayloadZip 'installerfail' @{'installerfail.exe'=[IO.File]::ReadAllBytes($fixture1)}
$failingInstaller = @(
    'Copy-Item "$dir\absent.txt" "$dir\copied.txt"'
)
Write-Manifest 'main' 'installerfail' @{version='1';url=(File-Uri $installerFailureZip);hash=(File-Hash $installerFailureZip);bin='installerfail.exe';
    installer=@{script=$failingInstaller}}
$installerFailure = Invoke-Coop 'installer-failure' @('--root',$root,'install','main/installerfail','--json')
Check ($installerFailure.exit -ne 0) 'failing installer script was reported as success'
Check ($installerFailure.error -match 'installer hook failed with exit code 1') "installer failure was not propagated: $($installerFailure.error)"
$installerFailureJournal = Last-Journal 'installerfail'
Check ($installerFailureJournal.state -eq 'rolled-back' -and @($installerFailureJournal.scripts).Count -eq 1 -and
    $installerFailureJournal.scripts[0].phase -eq 'installer' -and $installerFailureJournal.scripts[0].status -eq 'failed' -and
    $installerFailureJournal.scripts[0].exit_code -eq 1) 'installer failure journal is inaccurate'
Check (-not (Test-Path -LiteralPath "$root/apps/installerfail/current") -and -not (Test-Path -LiteralPath "$root/apps/installerfail/1") -and
    -not (Test-Path -LiteralPath "$root/shims/installerfail.exe")) 'installer failure published state'

# --- 3. Real rclone uninstaller.script with Get-Item LinkType. ---------------
$rcloneManifest = Get-CorpusManifest 'corpus/main/rclone.json'
$rcloneUninstaller = $rcloneManifest.uninstaller.script
Check ($rcloneUninstaller -match 'Get-Item' -and $rcloneUninstaller -match 'LinkType') 'real rclone uninstaller text was not loaded'
$rcloneZip = New-PayloadZip 'rclonepkg' @{'rclone.exe'=[IO.File]::ReadAllBytes($fixture1);'rclone.conf'='rclone config';
    'data/config.txt'='persisted data'}
$preUninstallScript = @('Set-Content -Path "$dir\pre-uninstall.txt" -Value "pre" -Encoding Ascii')
Write-Manifest 'main' 'rclonepkg' @{version='1';url=(File-Uri $rcloneZip);hash=(File-Hash $rcloneZip);bin='rclone.exe';
    persist='data';pre_uninstall=$preUninstallScript;uninstaller=@{script=$rcloneUninstaller}}
$rclonePreview = Invoke-Guard 'rclone-preview' @('--root',$root,'install','main/rclonepkg','--dry-run','--json')
Check ($rclonePreview.exit -eq 0) "rclone uninstaller preview failed: $($rclonePreview.error)"
Check ($rclonePreview.error -match 'Observed workload processes: 1') 'rclone uninstaller preview started PowerShell'
$rclonePlan = Parse-Json 'rclone-preview' $rclonePreview
$rcloneReport = @($rclonePlan.package.scripts | Where-Object { $_.phase -eq 'uninstaller' })
Check ($rclonePlan.execution_available -eq $true -and $rcloneReport.Count -eq 1 -and
    $rcloneReport[0].host -match 'PowerShell' -and $rcloneReport[0].text -match 'LinkType') 'real rclone uninstaller script was not accepted'
$rcloneInstall = Invoke-Coop 'rclone-install' @('--root',$root,'install','main/rclonepkg','--json')
Check ($rcloneInstall.exit -eq 0) "rclone package install failed: $($rcloneInstall.error)"
Check (Test-Path -LiteralPath "$root/persist/rclonepkg/data/config.txt") 'rclone persist directory was not created'
$rcloneUninstall = Invoke-Coop 'rclone-uninstall' @('--root',$root,'uninstall','rclonepkg','--json')
Check ($rcloneUninstall.exit -eq 0) "rclone uninstall failed: $($rcloneUninstall.error)"
$rcloneResult = Parse-Json 'rclone-uninstall' $rcloneUninstall
Check ((@($rcloneResult.scripts | ForEach-Object { $_.phase }) -join ',') -eq 'pre_uninstall,uninstaller') 'uninstaller script lifecycle order is wrong'
$rcloneRun = @($rcloneResult.scripts | Where-Object { $_.phase -eq 'uninstaller' })[0]
Check ($rcloneRun.command -eq 'uninstall' -and $rcloneRun.exit_code -eq 0 -and
    [IO.Path]::GetFullPath($rcloneRun.directory) -eq [IO.Path]::GetFullPath("$root/apps/rclonepkg/1")) 'uninstaller script context or exit code is wrong'
Check ((Get-Content -LiteralPath "$root/persist/rclonepkg/rclone.conf" -Raw).Trim() -eq 'rclone config') 'real rclone uninstaller script did not use Get-Item/LinkType and copy the config'
Check ((Get-Content -LiteralPath "$root/persist/rclonepkg/data/config.txt" -Raw).Trim() -eq 'persisted data') 'uninstaller removed declared persistent data'
Check (-not (Test-Path -LiteralPath "$root/apps/rclonepkg/current") -and -not (Test-Path -LiteralPath "$root/apps/rclonepkg/1") -and
    -not (Test-Path -LiteralPath "$root/shims/rclone.exe") -and -not (Test-Path -LiteralPath "$root/.coop/packages/rclonepkg.json")) 'rclone uninstall left package state'
$rcloneJournal = Last-Journal 'rclonepkg'
Check ((@($rcloneJournal.scripts | ForEach-Object { $_.phase }) -join ',') -eq 'pre_uninstall,uninstaller' -and
    $rcloneJournal.scripts[1].status -eq 'succeeded') 'rclone uninstall journal is inaccurate'

$uninstallFailureZip = New-PayloadZip 'uninstallfail' @{'uninstallfail.exe'=[IO.File]::ReadAllBytes($fixture1)}
$failingUninstaller = @('Copy-Item "$dir\absent.txt" "$dir\copied.txt"')
Write-Manifest 'main' 'uninstallfail' @{version='1';url=(File-Uri $uninstallFailureZip);hash=(File-Hash $uninstallFailureZip);bin='uninstallfail.exe';
    uninstaller=@{script=$failingUninstaller}}
$uninstallFailureInstall = Invoke-Coop 'uninstall-failure-install' @('--root',$root,'install','main/uninstallfail','--json')
Check ($uninstallFailureInstall.exit -eq 0) "uninstaller failure fixture install failed: $($uninstallFailureInstall.error)"
$uninstallFailure = Invoke-Coop 'uninstall-failure' @('--root',$root,'uninstall','uninstallfail','--json')
Check ($uninstallFailure.exit -ne 0) 'failing uninstaller script was reported as success'
Check ($uninstallFailure.error -match 'uninstaller hook failed with exit code 1') "uninstaller failure was not propagated: $($uninstallFailure.error)"
$uninstallFailureJournal = Last-Journal 'uninstallfail'
Check ($uninstallFailureJournal.state -eq 'rolled-back' -and @($uninstallFailureJournal.scripts).Count -eq 1 -and
    $uninstallFailureJournal.scripts[0].phase -eq 'uninstaller' -and $uninstallFailureJournal.scripts[0].status -eq 'failed' -and
    $uninstallFailureJournal.scripts[0].exit_code -eq 1) 'uninstaller failure journal is inaccurate'
Check ((Test-Path -LiteralPath "$root/apps/uninstallfail/current") -and (Test-Path -LiteralPath "$root/shims/uninstallfail.exe") -and
    (Test-Path -LiteralPath "$root/.coop/packages/uninstallfail.json")) 'uninstaller failure removed the installed package'

# --- 4. Real samples: remaining execution gaps are installer mechanisms. -----
Copy-Item -LiteralPath "$PSScriptRoot/corpus/main/7zip.json" "$root/buckets/main/bucket/7zip.json"
Copy-Item -LiteralPath "$PSScriptRoot/corpus/main/python.json" "$root/buckets/main/bucket/python.json"
Copy-Item -LiteralPath "$PSScriptRoot/corpus/extras/notepadplusplus.json" "$root/buckets/extras/bucket/notepadplusplus.json"
$sevenSample = Invoke-Guard 'seven-sample-preview' @('--root',$root,'install','main/7zip','--dry-run','--json')
Check ($sevenSample.exit -eq 0) "Main/7zip preview failed: $($sevenSample.error)"
Check ($sevenSample.error -match 'Observed workload processes: 1') 'Main/7zip preview started PowerShell or msiexec'
$sevenPlan = Parse-Json 'seven-sample-preview' $sevenSample
Check ($sevenPlan.execution_available -eq $true) "Main/7zip MSI preview stayed blocked: $(@($sevenPlan.diagnostics) | ConvertTo-Json -Compress)"
Check ($sevenPlan.package.msi_extraction.msiexec_started -eq $false -and $sevenPlan.package.msi_extraction.elevation -match 'not required' -and
    $sevenPlan.package.msi_extraction.reboot -match 'not required') 'Main/7zip preview does not state the MSI permission and reboot facts'
Check (@($sevenPlan.package.scripts).Count -eq 2 -and @($sevenPlan.package.scripts | Where-Object { $_.text -match 'reg' }).Count -eq 2) 'Main/7zip script text was refused instead of being reported as executable text'

$nppSample = Invoke-Guard 'npp-sample-preview' @('--root',$root,'install','extras/notepadplusplus','--dry-run','--json')
Check ($nppSample.exit -eq 0) "Extras/notepadplusplus preview failed: $($nppSample.error)"
Check ($nppSample.error -match 'Observed workload processes: 1') 'notepadplusplus preview started PowerShell or reg.exe'
$nppPlan = Parse-Json 'npp-sample-preview' $nppSample
$nppUninstaller = @($nppPlan.package.scripts | Where-Object { $_.phase -eq 'uninstaller' })[0]
Check ($nppPlan.execution_available -eq $true) 'notepadplusplus stayed blocked even though only script text was the old reason'
Check ($nppUninstaller.host -match 'PowerShell' -and $nppUninstaller.text -match 'reg import') 'notepadplusplus uninstaller did not report the real PowerShell text'

$pythonSample = Invoke-Guard 'python-sample-preview' @('--root',$root,'install','main/python','--dry-run','--json')
Check ($pythonSample.exit -eq 0) "Main/python preview failed: $($pythonSample.error)"
Check ($pythonSample.error -match 'Observed workload processes: 1') 'Main/python preview started an external tool'
$pythonPlan = Parse-Json 'python-sample-preview' $pythonSample
$pythonInstaller = @($pythonPlan.package.scripts | Where-Object { $_.phase -eq 'installer' })[0]
$pythonUninstaller = @($pythonPlan.package.scripts | Where-Object { $_.phase -eq 'uninstaller' })[0]
Check ($pythonPlan.execution_available -eq $true) 'Main/python installer script stayed blocked by its text'
Check ($pythonInstaller.host -match 'PowerShell' -and $pythonInstaller.text -match 'Expand-DarkArchive') 'Main/python installer script text was not reported for the real host'
Check ($pythonUninstaller.host -match 'PowerShell' -and $pythonUninstaller.text -match 'Set-EnvVar') 'Main/python uninstaller script text was not reported for the real host'
# The interpreter and helper library are real; the MSI/Inno/NSIS mechanics behind the text remain
# separate tickets, so no sample is executed here.
Check ($pythonPlan.package.script_support.problem -eq '') 'Main/python preview reported a missing hook host'

# --- 5. Measured system state and evidence paths. ----------------------------
$installerCacheAfter = @(Get-WindowsInstallerCacheState)
$installerCacheUnchanged = (($installerCacheBefore -join "`n") -eq ($installerCacheAfter -join "`n"))
Check ($installerCacheUnchanged) 'MSI preview changed the Windows Installer machine cache'
Check ($rcloneJournal.scripts[1].stdout_log.StartsWith($root)) 'script evidence escaped the isolated test root'

@{
    timestamp=[DateTime]::UtcNow.ToString('o')
    root=$root
    checks=$script:checks
    runs=$script:runs
    coop_sha256=(File-Hash $CoopExe)
    powershell=$pwshPath
    sevenzip_artifact=@{path=$nodeArchive;sha256=$nodeHash}
    windows_installer_cache=@{
        path=(Join-Path $env:WINDIR 'Installer')
        entries_before=@($installerCacheBefore).Count
        entries_after=@($installerCacheAfter).Count
        unchanged=$installerCacheUnchanged
        sample_before=@($installerCacheBefore | Select-Object -First 3)
        sample_after=@($installerCacheAfter | Select-Object -First 3)
    }
    real_script_sources=@('Main/7zip MSI preview and post_install/uninstaller script text','Main/nodejs 7z artifact','Main/rclone uninstaller.script (executed)','Extras/notepadplusplus uninstaller.script text','Main/python installer.script text and uninstaller.script text')
    script_text_policy='Script text is not classified as compatible or incompatible; the remaining execution gaps are installer mechanisms tracked by their own tickets.'
    node_program_version=$nodeVersion
    fixture_artifacts='project fixture programs; no external tool stand-in was executed'
    system_writes='measured C:\Windows\Installer SourceHash entries before/after the MSI previews; unchanged. MSI execution is covered by tests/msi-lifecycle.ps1.'
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$root/evidence.json" -Encoding utf8
Write-Output "PASS installer/uninstaller scripts, MSI preview facts, native 7z and external-tool disclosure: $root/evidence.json ($script:checks checks)"
exit 0

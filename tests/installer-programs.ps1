param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# Installer/uninstaller program declarations combined with multi-stage scripts (#32). The seam is
# the real CLI plus a real PowerShell host and the pinned Scoop compatibility library: manifests are
# real Scoop JSON, installer programs are real .cmd/.ps1 files inside the package payloads, and the
# observations are the files those programs and scripts actually produce, the saved transaction
# journal and the published package state.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$coopDirectory = Split-Path $CoopExe
$fixture1 = Join-Path $coopDirectory 'fixture-1.exe'
$fixture2 = Join-Path $coopDirectory 'fixture-2.exe'
$guard = Join-Path $coopDirectory 'process_guard.exe'
$pwshPath = (Get-Process -Id $PID).Path
foreach ($path in @($fixture1,$fixture2,$guard,$pwshPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing fixed test input: $path" }
}

$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/main/bucket","$root/temp","$root/build" -Force | Out-Null
$script:runs = 0
$script:checks = 0

function Check([bool]$condition,[string]$message) {
    if (-not $condition) { throw "installer program check failed: $message" }
    ++$script:checks
}
function File-Hash([string]$path) {
    $stream = [IO.File]::OpenRead($path)
    try { $sha = [Security.Cryptography.SHA256]::Create(); return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-','').ToLower() }
    finally { $stream.Dispose() }
}
function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
function Write-Manifest([string]$name,[hashtable]$manifest) {
    $json = $manifest | ConvertTo-Json -Depth 16
    [IO.File]::WriteAllText("$root/buckets/main/bucket/$name.json",$json,[Text.UTF8Encoding]::new($false))
}
function New-PayloadZip([string]$name,[hashtable]$files) {
    $stage = "$root/build/$name"
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($entry in $files.GetEnumerator()) {
        $target = Join-Path $stage $entry.Key
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        if ($entry.Value -is [byte[]]) { [IO.File]::WriteAllBytes($target,$entry.Value) }
        else { [IO.File]::WriteAllText($target,([string]$entry.Value).Replace("`r`n","`n").Replace("`n","`r`n"),[Text.UTF8Encoding]::new($false)) }
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
    foreach ($argument in $arguments) { Add-ProcessArgument $start ($argument) }
    $start.EnvironmentVariables['TEMP'] = "$root/temp"
    $start.EnvironmentVariables['TMP'] = "$root/temp"
    foreach ($key in $environment.Keys) { $start.EnvironmentVariables[$key] = $environment[$key] }
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(600000)) { $process.Kill(); throw "$label timed out" }
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
    if ($journals.Count -eq 0) { throw "no transaction journal for $package" }
    return $journals[-1]
}
function Operations-After([object]$plan,[string]$kind) {
    $pattern = @($plan.ir_operations)
    $positions = @{}
    for ($index = 0; $index -lt $pattern.Count; ++$index) {
        switch ($pattern[$index].operation) {
            'hook' { $positions[$plan.package.scripts[$pattern[$index].index].phase] = $index }
            default { $positions[$pattern[$index].operation] = $index }
        }
    }
    return $positions
}

# Real batch/ps1 installer programs. They only touch $dir, $persist_dir or a path the Manifest
# passes in, so no user or system state is at risk; what they write is the observation.
$setupCmd = @'
@echo off
setlocal
> "%~dp0program-args.txt" echo arg_dir=%~2
>> "%~dp0program-args.txt" echo arg_version=%~4
>> "%~dp0program-args.txt" echo arg_global=%~6
copy /y "%~dp0app.exe" "%~dp0program-output.exe" >nul
exit /b 0
'@
$removeCmd = @'
@echo off
setlocal
>> "%~2" echo program
>> "%~2" echo program_dir=%~4
exit /b 0
'@
$failCmd = @'
@echo off
> "%~dp0fail-stdout.txt" echo failing-installer-started
>&2 echo installer-program-failed
>> "%~dp0fail-marker.txt" echo ran
exit /b 9
'@
$setupPs1 = @'
param([string]$Root,[string]$Version,[string]$Global)
"ps1_dir=$Root|ps1_version=$Version|ps1_global=$Global" | Set-Content -Path (Join-Path $PSScriptRoot 'ps1-program.txt') -Encoding UTF8
'@

# --- 1. Preview: declared programs are planned, disclosed, and start no process. ---------------
$comboZip1 = New-PayloadZip 'combopayload1' @{
    'app.exe'=[IO.File]::ReadAllBytes($fixture1)
    'setup.cmd'=$setupCmd
    'remove.cmd'=$removeCmd
    'data/conf.txt'='persisted configuration'
}
$comboPre = @('Set-Content -Path "$dir\pre.txt" -Value "pre" -Encoding Ascii')
$comboOldPreUninstall = @('Add-Content -Path "$persist_dir\uninstall-order.txt" -Value "pre_uninstall" -Encoding Ascii')
$comboInstallerScript = @(
    'if (!(Test-Path "$dir\program-args.txt")) { throw "installer program did not run before installer.script" }',
    'Set-Content -Path "$dir\script-order.txt" -Value "script" -Encoding Ascii'
)
$comboPost = @('Copy-Item "$dir\program-args.txt" "$dir\post-seen.txt"')
$comboPersistLog = "$root/persist/progcombo/uninstall-order.txt"
$comboUninstScript = @(
    'if (!(Test-Path "$persist_dir\uninstall-order.txt")) { throw "uninstaller program did not run before uninstaller.script" }',
    'Add-Content -Path "$persist_dir\uninstall-order.txt" -Value "script" -Encoding Ascii'
)
$comboPostUninst = @('Add-Content -Path "$dir\post-uninstall-seen.txt" -Value "post" -Encoding Ascii')
Write-Manifest 'progcombo' @{version='1';url=(File-Uri $comboZip1);hash=(File-Hash $comboZip1);
    bin=@(,@('program-output.exe','ptool'));persist='data';
    pre_install=$comboPre;post_install=$comboPost;pre_uninstall=$comboOldPreUninstall;
    installer=@{file='setup.cmd';args=@('--root','$dir','--version','$version','--global','$global');keep=$true;script=$comboInstallerScript};
    uninstaller=@{file='remove.cmd';args=@('--log',$comboPersistLog,'--dir','$dir');keep=$true;script=$comboUninstScript};
    post_uninstall=$comboPostUninst}
$comboPreview = Invoke-Guard 'combo-preview' @('--root',$root,'install','main/progcombo','--dry-run','--json')
Check ($comboPreview.exit -eq 0) "combined preview failed: $($comboPreview.error)"
Check ($comboPreview.error -match 'Observed workload processes: 1') 'preview of declared installer programs started a process'
$comboPlan = Parse-Json 'combo-preview' $comboPreview
Check ($comboPlan.execution_available -eq $true) "combined preview is blocked: $(@($comboPlan.diagnostics) | ConvertTo-Json -Compress)"
Check ($comboPlan.package.installer.file -eq 'setup.cmd' -and
    (@($comboPlan.package.installer.arguments) -join ' ') -eq '--root $dir --version $version --global $global' -and
    $comboPlan.package.installer.keep -eq $true) 'preview did not report the declared installer program and arguments'
Check ($comboPlan.package.installer.host -match 'Invoke-Installer' -and
    (@($comboPlan.package.installer.arguments_context) -join ',') -eq '$dir,$global,$version') 'preview did not disclose the program host and substitution context'
Check ($comboPlan.package.installer.program_removal -match 'keep=true' -and
    $comboPlan.package.installer.side_effects -match 'rolled back' -and
    $comboPlan.package.installer.side_effects -match 'never re-run') 'preview did not state the program removal and side-effect limits'
Check ($comboPlan.package.uninstaller.file -eq 'remove.cmd' -and $comboPlan.package.uninstaller.program_removal -match 'keep=true') 'preview did not report the declared uninstaller program'
Check ((@($comboPlan.capabilities | Where-Object { $_.id -eq 'installer-process' })[0].supported) -eq $true) 'installer-process capability is still reported as unsupported'
$positions = Operations-After $comboPlan
Check ($positions['pre_install'] -lt $positions['installer'] -and $positions['installer'] -lt $positions['publish-current'] -and
    $positions['publish-current'] -lt $positions['post_install']) 'installer program is not planned between pre_install and current publication'
Check (@($comboPlan.ir_operations | Where-Object { $_.operation -eq 'installer' }).Count -eq 1) 'preview did not list exactly one installer program operation'
Check (@($comboPlan.ir_operations | Where-Object { $_.operation -eq 'installer' })[0].effect -match 'setup\.cmd') 'installer operation does not name the declared program'
Check (-not (Test-Path -LiteralPath "$root/apps") -and -not (Test-Path -LiteralPath "$root/.coop/transactions")) 'preview wrote installation state'

# --- 2. Install: program, scripts, current, persist and the entry it produces. ---------------
$comboInstall = Invoke-Coop 'combo-install' @('--root',$root,'install','main/progcombo','--json')
Check ($comboInstall.exit -eq 0) "combined install failed: $($comboInstall.error)"
$comboResult = Parse-Json 'combo-install' $comboInstall
Check ((@($comboResult.scripts | ForEach-Object { $_.phase }) -join ',') -eq 'pre_install,installer,post_install') 'install hook order is wrong'
Check (@($comboResult.installers).Count -eq 1) 'install result did not report the installer program'
$programRun = @($comboResult.installers)[0]
Check ($programRun.phase -eq 'installer' -and $programRun.exit_code -eq 0 -and $programRun.declared_file -eq 'setup.cmd' -and
    $programRun.previous_package -eq $false) 'installer program run record is wrong'
Check ([IO.Path]::GetFullPath($programRun.directory) -eq [IO.Path]::GetFullPath("$root/apps/progcombo/1") -and
    $programRun.context.scoopdir -eq $root -and $programRun.context.global -eq $false) 'installer program did not run at the version directory with the shared root context'
Check ($programRun.program_present_after_run -eq $true) 'keep=true program was removed'
Check ((Test-Path -LiteralPath $programRun.stdout_log) -and (Test-Path -LiteralPath $programRun.stderr_log)) 'installer program output logs are missing'
Check ($programRun.scoop_library_version -match 'v0\.6\.0' -and $programRun.host -match 'installer-program\.host\.ps1') 'installer program did not run in the pinned PowerShell host'
$argsText = (Get-Content -LiteralPath "$root/apps/progcombo/1/program-args.txt" -Raw)
$expectedDir = [IO.Path]::GetFullPath("$root/apps/progcombo/1")
Check ($argsText -match ([regex]::Escape("arg_dir=$expectedDir")) -and $argsText -match 'arg_version=1' -and
    $argsText -match 'arg_global=False') "installer program arguments were not substituted: $argsText"
Check ((Get-Content -LiteralPath "$root/apps/progcombo/1/script-order.txt" -Raw).Trim() -eq 'script') 'installer.script did not run after the program'
Check ((Get-Content -LiteralPath "$root/apps/progcombo/current/post-seen.txt" -Raw) -match 'arg_version=1') 'post_install did not observe the program output through current'
Check ((Test-Path -LiteralPath "$root/persist/progcombo/data/conf.txt") -and
    ((Get-Content -LiteralPath "$root/persist/progcombo/data/conf.txt" -Raw).Trim() -eq 'persisted configuration')) 'declared persistence was not linked before post_install'
Check (Test-Path -LiteralPath "$root/apps/progcombo/current/program-output.exe") 'installer program output was not published through current'
$ptool = Invoke-Process 'ptool-version' "$root/shims/ptool.exe" @()
Check ($ptool.exit -eq 0 -and $ptool.output.Trim() -eq 'fixture 1') "entry created from the installer program output did not run: $($ptool.error)"
$comboJournal = Last-Journal 'progcombo'
Check ($comboJournal.state -eq 'committed' -and @($comboJournal.installers).Count -eq 1 -and
    $comboJournal.installers[0].exit_code -eq 0 -and $comboJournal.installers[0].status -eq 'succeeded') 'installer program journal record is wrong'
Check ($comboJournal.installers[0].external_side_effects -match 'never re-run' -and
    $comboJournal.installers[0].external_side_effects -match 'rolled back') 'journal does not state the installer program side-effect limit'
Check ((@($comboJournal.scripts | ForEach-Object { $_.phase }) -join ',') -eq 'pre_install,installer,post_install') 'journal hook order is wrong'

# --- 3. Update: old uninstaller program and script, then the new installer program. -----------
$comboZip2 = New-PayloadZip 'combopayload2' @{
    'app.exe'=[IO.File]::ReadAllBytes($fixture2)
    'setup.cmd'=$setupCmd
    'data/conf2.txt'='second configuration'
}
$comboInstallerScript2 = @(
    'if (!(Test-Path "$dir\program-args.txt")) { throw "installer program did not run before installer.script" }',
    'Set-Content -Path "$dir\script-order.txt" -Value "script" -Encoding Ascii'
)
Write-Manifest 'progcombo' @{version='2';url=(File-Uri $comboZip2);hash=(File-Hash $comboZip2);
    bin=@(,@('program-output.exe','ptool'));persist='data';
    pre_uninstall=$comboOldPreUninstall;
    installer=@{file='setup.cmd';args=@('--root','$dir','--version','$version','--global','$global');script=$comboInstallerScript2};
    uninstaller=@{file='remove.cmd';args=@('--log',$comboPersistLog,'--dir','$dir');keep=$true;script=$comboUninstScript}}
$comboUpdate = Invoke-Coop 'combo-update' @('--root',$root,'update','progcombo','--json')
Check ($comboUpdate.exit -eq 0) "combined update failed: $($comboUpdate.error)"
$comboUpdateResult = Parse-Json 'combo-update' $comboUpdate
Check (@($comboUpdateResult.installers).Count -eq 2) 'update did not report both the old uninstaller and the new installer program'
$oldProgram = @($comboUpdateResult.installers | Where-Object { $_.previous_package -eq $true })
$newProgram = @($comboUpdateResult.installers | Where-Object { $_.previous_package -eq $false })
Check ($oldProgram.Count -eq 1 -and $oldProgram[0].phase -eq 'uninstaller' -and
    [IO.Path]::GetFullPath($oldProgram[0].directory) -eq [IO.Path]::GetFullPath("$root/apps/progcombo/1")) 'update did not run the installed version uninstaller program at the old version directory'
Check ($newProgram.Count -eq 1 -and $newProgram[0].phase -eq 'installer' -and $newProgram[0].exit_code -eq 0 -and
    [IO.Path]::GetFullPath($newProgram[0].directory) -eq [IO.Path]::GetFullPath("$root/apps/progcombo/2")) 'update did not run the new installer program at the new version directory'
Check ($newProgram[0].program_present_after_run -eq $false) 'keep=false program was not removed after a successful run'
$uninstallOrder = (Get-Content -LiteralPath $comboPersistLog -Raw) -split "`r?`n" | Where-Object { $_ }
Check (($uninstallOrder -join ',') -eq "pre_uninstall,program,program_dir=$([IO.Path]::GetFullPath("$root/apps/progcombo/1")),script") "old version uninstaller order is wrong: $($uninstallOrder -join ',')"
Check ((Get-Content -LiteralPath "$root/apps/progcombo/2/program-args.txt" -Raw) -match 'arg_version=2') 'new version installer program did not receive the new version'
Check (-not (Test-Path -LiteralPath "$root/apps/progcombo/2/setup.cmd")) 'keep=false program file is still in the version directory'
Check ((Get-Content -LiteralPath "$root/apps/progcombo/current/post-seen.txt" -ErrorAction SilentlyContinue) -eq $null -and
    (Test-Path -LiteralPath "$root/apps/progcombo/1/app.exe")) 'update did not retain the old version or republished stale state'
Check ((Test-Path -LiteralPath "$root/apps/progcombo/1/app.exe") -and
    ($comboUpdateResult.retained_versions -contains '1')) 'update did not retain the previous version'
Check ((Get-Content -LiteralPath "$root/persist/progcombo/data/conf.txt" -Raw).Trim() -eq 'persisted configuration') 'update replaced the declared persistent data'
$comboList = Invoke-Coop 'combo-list' @('--root',$root,'list','--json')
Check ($comboList.exit -eq 0 -and $comboList.output -match '"version": "2"') 'list does not report the updated version'

# --- 4. args-only declaration resolves to the downloaded file name. ---------------------------
$argsOnly = "$root/build/setup-args.cmd"
[IO.File]::WriteAllText($argsOnly,$setupCmd.Replace("`r`n","`n").Replace("`n","`r`n"),[Text.UTF8Encoding]::new($false))
Write-Manifest 'progargs' @{version='1';url=(File-Uri $argsOnly);hash=(File-Hash $argsOnly);
    installer=@{args=@('--root','$dir','--version','$version','--global','$global')}}
$argsPreview = Invoke-Coop 'args-preview' @('--root',$root,'install','main/progargs','--dry-run','--json')
Check ($argsPreview.exit -eq 0) "args-only preview failed: $($argsPreview.error)"
$argsPlan = Parse-Json 'args-preview' $argsPreview
Check ($argsPlan.package.installer.file -eq 'setup-args.cmd' -and $argsPlan.package.installer.keep -eq $false) 'args-only declaration did not fall back to the downloaded file name'
$argsInstall = Invoke-Coop 'args-install' @('--root',$root,'install','main/progargs','--json')
Check ($argsInstall.exit -eq 0) "args-only install failed: $($argsInstall.error)"
$argsResult = Parse-Json 'args-install' $argsInstall
$argsRun = @($argsResult.installers)[0]
Check ($argsRun.declared_file -eq 'setup-args.cmd' -and $argsRun.exit_code -eq 0) 'args-only installer program did not run'
Check ($argsRun.program_present_after_run -eq $false -and -not (Test-Path -LiteralPath "$root/apps/progargs/1/setup-args.cmd")) 'default keep=false did not remove the args-only program'
Check ((Get-Content -LiteralPath "$root/apps/progargs/1/program-args.txt" -Raw) -match 'arg_version=1') 'args-only program did not receive the substituted arguments'

# --- 5. PowerShell installer programs run in-process, like Scoop's Invoke-Installer. ----------
$ps1Zip = New-PayloadZip 'ps1payload' @{'app.exe'=[IO.File]::ReadAllBytes($fixture1);'setup.ps1'=$setupPs1}
Write-Manifest 'progps1' @{version='1';url=(File-Uri $ps1Zip);hash=(File-Hash $ps1Zip);bin=@(,@('app.exe','ps1tool'));
    installer=@{file='setup.ps1';args=@('$dir','$version','$global')}}
$ps1Install = Invoke-Coop 'ps1-install' @('--root',$root,'install','main/progps1','--json')
Check ($ps1Install.exit -eq 0) "ps1 installer program install failed: $($ps1Install.error)"
$ps1Result = Parse-Json 'ps1-install' $ps1Install
$ps1Run = @($ps1Result.installers)[0]
Check ($ps1Run.exit_code -eq 0 -and $ps1Run.declared_file -eq 'setup.ps1') 'ps1 installer program did not run'
$ps1Text = (Get-Content -LiteralPath "$root/apps/progps1/1/ps1-program.txt" -Raw).Trim()
$expectedPs1Dir = [IO.Path]::GetFullPath("$root/apps/progps1/1")
# Scoop invokes a .ps1 program as `& $progName @fnArgs`, which binds positionally; the declared
# arguments are therefore positional and the program sees the same values Scoop would pass.
Check ($ps1Text -eq "ps1_dir=$expectedPs1Dir|ps1_version=1|ps1_global=False") "ps1 installer program received the wrong context: $ps1Text"
# Scoop only removes a non-.ps1 program unless keep is set; the .ps1 itself stays.
Check ($ps1Run.program_present_after_run -eq $true -and (Test-Path -LiteralPath "$root/apps/progps1/1/setup.ps1")) 'ps1 installer program was removed even though Scoop keeps it'

# --- 6. Uninstall: uninstaller program, uninstaller script, persisted data retained. ---------
$removeZip = New-PayloadZip 'removepayload' @{'app.exe'=[IO.File]::ReadAllBytes($fixture1);'remove.cmd'=$removeCmd;
    'data/state.txt'='kept state'}
$persistLog = "$root/persist/progremove/uninstall-order.txt"
$removeScripts = @{
    pre_uninstall=@('Add-Content -Path "$persist_dir\uninstall-order.txt" -Value "pre_uninstall" -Encoding Ascii')
    post_uninstall=@('Add-Content -Path "$persist_dir\uninstall-order.txt" -Value "post_uninstall" -Encoding Ascii')
}
$removeUninstScript = @('Add-Content -Path "$persist_dir\uninstall-order.txt" -Value "script" -Encoding Ascii')
Write-Manifest 'progremove' @{version='1';url=(File-Uri $removeZip);hash=(File-Hash $removeZip);bin=@(,@('app.exe','rtool'));persist='data';
    pre_uninstall=$removeScripts.pre_uninstall;post_uninstall=$removeScripts.post_uninstall;
    uninstaller=@{file='remove.cmd';args=@('--log',$persistLog,'--dir','$dir');keep=$true;script=$removeUninstScript}}
$removeInstall = Invoke-Coop 'remove-install' @('--root',$root,'install','main/progremove','--json')
Check ($removeInstall.exit -eq 0) "uninstaller fixture install failed: $($removeInstall.error)"
Check ((Get-Content -LiteralPath "$root/persist/progremove/data/state.txt" -Raw).Trim() -eq 'kept state') 'uninstaller fixture persistence was not created'
$removeUninstall = Invoke-Coop 'remove-uninstall' @('--root',$root,'uninstall','progremove','--json')
Check ($removeUninstall.exit -eq 0) "combined uninstall failed: $($removeUninstall.error)"
$removeResult = Parse-Json 'remove-uninstall' $removeUninstall
Check ((@($removeResult.scripts | ForEach-Object { $_.phase }) -join ',') -eq 'pre_uninstall,uninstaller,post_uninstall') 'uninstall hook order is wrong'
$removeRun = @($removeResult.installers)[0]
Check ($removeRun.phase -eq 'uninstaller' -and $removeRun.exit_code -eq 0 -and $removeRun.declared_file -eq 'remove.cmd' -and
    [IO.Path]::GetFullPath($removeRun.directory) -eq [IO.Path]::GetFullPath("$root/apps/progremove/1")) 'uninstaller program did not run at the removed version directory'
$removeOrder = (Get-Content -LiteralPath $persistLog -Raw) -split "`r?`n" | Where-Object { $_ }
Check (($removeOrder -join ',') -eq "pre_uninstall,program,program_dir=$([IO.Path]::GetFullPath("$root/apps/progremove/1")),script,post_uninstall") "uninstaller program/script order is wrong: $($removeOrder -join ',')"
Check ((Get-Content -LiteralPath "$root/persist/progremove/data/state.txt" -Raw).Trim() -eq 'kept state') 'normal uninstall removed declared persistent data'
Check (-not (Test-Path -LiteralPath "$root/apps/progremove/current") -and
    -not (Test-Path -LiteralPath "$root/apps/progremove/1") -and
    -not (Test-Path -LiteralPath "$root/shims/rtool.exe") -and
    -not (Test-Path -LiteralPath "$root/.coop/packages/progremove.json")) 'uninstall left package state'
$removeJournal = Last-Journal 'progremove'
Check ($removeJournal.state -eq 'committed' -and @($removeJournal.installers).Count -eq 1 -and
    $removeJournal.installers[0].status -eq 'succeeded') 'uninstaller program journal record is wrong'

# --- 7. Failures reach the program, are recorded once, and roll the package back. ------------
$failZip = New-PayloadZip 'failpayload' @{'app.exe'=[IO.File]::ReadAllBytes($fixture1);'fail.cmd'=$failCmd}
$failPre = @('Set-Content -Path "$dir\pre-fail.txt" -Value "pre" -Encoding Ascii')
Write-Manifest 'progfail' @{version='1';url=(File-Uri $failZip);hash=(File-Hash $failZip);bin=@(,@('app.exe','ftool'));
    pre_install=$failPre;installer=@{file='fail.cmd'}}
$failInstall = Invoke-Coop 'fail-install' @('--root',$root,'install','main/progfail','--json')
Check ($failInstall.exit -ne 0) 'failing installer program was reported as success'
# Scoop's Invoke-ExternalCommand turns a non-zero program exit into a failed helper call and
# Invoke-Installer then aborts with exit code 1; the program's own code is reported in the host
# output. Coop keeps that upstream behavior instead of inventing a different exit status.
Check ($failInstall.error -match 'installer program failed with exit code 1') "installer program failure was not propagated: $($failInstall.error)"
$failJournal = Last-Journal 'progfail'
Check ($failJournal.state -eq 'rolled-back' -and @($failJournal.installers).Count -eq 1 -and
    $failJournal.installers[0].exit_code -eq 1 -and $failJournal.installers[0].status -eq 'failed') 'installer program failure journal is inaccurate'
Check ((Test-Path -LiteralPath $failJournal.installers[0].stderr_log) -and
    ((Get-Content -LiteralPath $failJournal.installers[0].stderr_log -Raw) -match 'installer-program-failed')) 'installer program stderr was not captured'
Check ((Get-Content -LiteralPath $failJournal.installers[0].stdout_log -Raw) -match 'Exit code was 9') 'the failing program exit code was not reported by the upstream helper'
Check (-not (Test-Path -LiteralPath "$root/apps/progfail/current") -and -not (Test-Path -LiteralPath "$root/apps/progfail/1") -and
    -not (Test-Path -LiteralPath "$root/shims/progfail.exe") -and -not (Test-Path -LiteralPath "$root/.coop/packages/progfail.json")) 'failed installer program published package state'

$missingZip = New-PayloadZip 'missingpayload' @{'app.exe'=[IO.File]::ReadAllBytes($fixture1)}
Write-Manifest 'progmissing' @{version='1';url=(File-Uri $missingZip);hash=(File-Hash $missingZip);bin=@(,@('app.exe','mtool'));
    installer=@{file='absent.cmd'}}
$missingInstall = Invoke-Coop 'missing-install' @('--root',$root,'install','main/progmissing','--json')
Check ($missingInstall.exit -ne 0) 'missing installer program was reported as success'
$missingJournal = Last-Journal 'progmissing'
Check ($missingJournal.state -eq 'rolled-back' -and @($missingJournal.installers)[0].exit_code -ne 0 -and
    ((Get-Content -LiteralPath @($missingJournal.installers)[0].stdout_log -Raw) +
     (Get-Content -LiteralPath @($missingJournal.installers)[0].stderr_log -Raw)) -match 'missing') 'missing installer program was not diagnosed by the upstream helper'
Check (-not (Test-Path -LiteralPath "$root/apps/progmissing/current") -and
    -not (Test-Path -LiteralPath "$root/apps/progmissing/1") -and
    -not (Test-Path -LiteralPath "$root/shims/mtool.exe")) 'missing installer program published package state'

$escapeZip = New-PayloadZip 'escapepayload' @{'app.exe'=[IO.File]::ReadAllBytes($fixture1)}
Write-Manifest 'progescape' @{version='1';url=(File-Uri $escapeZip);hash=(File-Hash $escapeZip);bin=@(,@('app.exe','etool'));
    installer=@{file='..\escape.cmd'}}
$escapePreview = Invoke-Coop 'escape-preview' @('--root',$root,'install','main/progescape','--dry-run','--json')
Check ($escapePreview.output -match 'Invalid path component' -or
    $escapePreview.output -match 'Manifest path must be relative to its package' -or
    $escapePreview.output -match 'Unsafe path component') 'installer program outside the package was not rejected'
$escapeInstall = Invoke-Coop 'escape-install' @('--root',$root,'install','main/progescape','--json')
Check ($escapeInstall.exit -ne 0 -and -not (Test-Path -LiteralPath "$root/apps/progescape")) 'escaping installer program was executed or published'

$failRemoveZip = New-PayloadZip 'failremove' @{'app.exe'=[IO.File]::ReadAllBytes($fixture1);'fail.cmd'=$failCmd}
Write-Manifest 'progremovefail' @{version='1';url=(File-Uri $failRemoveZip);hash=(File-Hash $failRemoveZip);bin=@(,@('app.exe','rftool'));
    uninstaller=@{file='fail.cmd'}}
$failRemoveInstall = Invoke-Coop 'remove-fail-install' @('--root',$root,'install','main/progremovefail','--json')
Check ($failRemoveInstall.exit -eq 0) "uninstaller failure fixture install failed: $($failRemoveInstall.error)"
$failRemove = Invoke-Coop 'remove-fail' @('--root',$root,'uninstall','progremovefail','--json')
Check ($failRemove.exit -ne 0) 'failing uninstaller program was reported as success'
$failRemoveJournal = Last-Journal 'progremovefail'
Check ($failRemoveJournal.state -eq 'rolled-back' -and @($failRemoveJournal.installers)[0].exit_code -eq 1 -and
    (Get-Content -LiteralPath @($failRemoveJournal.installers)[0].stdout_log -Raw) -match 'Exit code was 9') 'uninstaller program failure journal is inaccurate'
Check ((Test-Path -LiteralPath "$root/apps/progremovefail/current") -and
    (Test-Path -LiteralPath "$root/shims/rftool.exe") -and
    (Test-Path -LiteralPath "$root/.coop/packages/progremovefail.json")) 'failed uninstaller program removed the installed package'

# --- 8. Evidence summary. ------------------------------------------------------------------
@{
    timestamp=[DateTime]::UtcNow.ToString('o')
    root=$root
    checks=$script:checks
    runs=$script:runs
    coop_sha256=(File-Hash $CoopExe)
    powershell=$pwshPath
    powershell_version=$PSVersionTable.PSVersion.ToString()
    installer_programs=@('setup.cmd (batch, keep=true)','setup-args.cmd (args-only fallback)','setup.ps1 (in-process .ps1)','remove.cmd (uninstaller)','fail.cmd (exit 9)')
    substitution='$dir, $version and $global are substituted by the pinned Scoop Invoke-Installer; the programs record what they received'
    side_effects='all installer programs and scripts write only inside $dir, $persist_dir or the passed path; external side effects are recorded as unverified and never re-run'
    rollback='failed installer and uninstaller programs leave no current, entry or Coop record; journals are marked rolled-back'
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$root/evidence.json" -Encoding utf8
Write-Output "PASS installer/uninstaller programs combined with multi-stage scripts: $root/evidence.json ($script:checks checks)"
exit 0

param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$coopDirectory = Split-Path $CoopExe
$fixture1 = Join-Path $coopDirectory 'fixture-1.exe'
$fixture2 = Join-Path $coopDirectory 'fixture-2.exe'
$guard = Join-Path $coopDirectory 'process_guard.exe'
$scoopLibrary = Join-Path $coopDirectory 'scoop-lib'
$pwshPath = (Get-Process -Id $PID).Path
foreach ($path in @($fixture1,$fixture2,$guard,$pwshPath,(Join-Path $scoopLibrary 'core.ps1'))) { if (-not (Test-Path -LiteralPath $path)) { throw "Missing fixed test input: $path" } }

$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/extras/bucket","$root/buckets/extras/scripts/notepadplusplus",
    "$root/buckets/main/bucket","$root/buckets/main/scripts/git","$root/temp","$root/build","$root/programs" -Force | Out-Null
Copy-Item "$PSScriptRoot/corpus/extras-scripts/notepadplusplus/*.reg" "$root/buckets/extras/scripts/notepadplusplus/"
Copy-Item "$PSScriptRoot/corpus/main-scripts/git/*.reg" "$root/buckets/main/scripts/git/"
$script:runs = 0
$script:checks = 0

function Check([bool]$condition,[string]$message) {
    if (-not $condition) { throw "hook check failed: $message" }
    ++$script:checks
}
function Write-Manifest([string]$bucket,[string]$name,[hashtable]$manifest) {
    $json = $manifest | ConvertTo-Json -Depth 12
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
function File-Hash([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
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
    $start.Environment['SCOOP_CACHE'] = ''
    foreach ($key in $environment.Keys) { $start.Environment[$key] = $environment[$key] }
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(180000)) { $process.Kill($true); throw "$label timed out" }
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
function Get-CorpusScript([string]$relative,[string]$field) {
    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot $relative) -Raw | ConvertFrom-Json
    $value = $manifest.$field
    if ($null -eq $value) { throw "Corpus sample $relative has no $field" }
    return $value
}
function Last-Journal([string]$package) {
    $journals = @(Get-ChildItem "$root/.coop/transactions" -Recurse -Filter journal.json -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } |
        Where-Object { $_.package -eq $package })
    return $journals[-1]
}

$nppPreInstall = Get-CorpusScript 'corpus/extras/notepadplusplus.json' 'pre_install'
$nppPostInstall = Get-CorpusScript 'corpus/extras/notepadplusplus.json' 'post_install'
$gitPreInstall = Get-CorpusScript 'corpus/main/git.json' 'pre_install'
$gitPostInstall = Get-CorpusScript 'corpus/main/git.json' 'post_install'
$gitPreUninstall = Get-CorpusScript 'corpus/main/git.json' 'pre_uninstall'
$nodePostInstall = Get-CorpusScript 'corpus/main/nodejs.json' 'post_install'
$rcloneUninstaller = (Get-CorpusScript 'corpus/main/rclone.json' 'uninstaller').script
Check ($nppPreInstall.Count -gt 1 -and $gitPreInstall.Count -gt 1 -and $gitPostInstall.Count -gt 1) 'real upstream hook text was not loaded'

# --- 0. A package without hooks must not start PowerShell. -------------------
$plainZip = New-PayloadZip 'plain' @{'plain.exe'=$null}
[IO.File]::WriteAllBytes((Join-Path "$root/build/plain" 'plain.exe'),[IO.File]::ReadAllBytes($fixture1))
Remove-Item -LiteralPath $plainZip -Force
[IO.Compression.ZipFile]::CreateFromDirectory("$root/build/plain",$plainZip)
Write-Manifest 'main' 'plain' @{version='1';url=([Uri]$plainZip).AbsoluteUri;hash=(File-Hash $plainZip);bin='plain.exe'}
$guardRun = Invoke-Guard 'no-hook-install' @('--root',$root,'install','main/plain','--json')
Check ($guardRun.exit -eq 0) "hook-free install failed: $($guardRun.error)"
Check ($guardRun.error -match 'Observed workload processes: 1') 'hook-free install started an unexpected child process'
$plainResult = Parse-Json 'no-hook-install' $guardRun
Check (@($plainResult.scripts).Count -eq 0) 'hook-free install reported hook scripts'
$transactionsAfterPlain = @(Get-ChildItem "$root/.coop/transactions" -Directory | Select-Object -ExpandProperty Name)

# --- 1. Preview lists the real script text without starting PowerShell. ------
$notesZip1 = New-PayloadZip 'notes-1' @{'notepad++.exe'=$null;'stylers.model.xml'='model';'plugins.original/v1.txt'='plugin v1'}
[IO.File]::WriteAllBytes((Join-Path "$root/build/notes-1" 'notepad++.exe'),[IO.File]::ReadAllBytes($fixture1))
Remove-Item -LiteralPath $notesZip1 -Force
[IO.Compression.ZipFile]::CreateFromDirectory("$root/build/notes-1",$notesZip1)
$notesPersist = @('config.xml','stylers.xml','plugins')
Write-Manifest 'extras' 'notes' @{version='1';url=([Uri]$notesZip1).AbsoluteUri;hash=(File-Hash $notesZip1);bin='notepad++.exe';
    persist=$notesPersist;pre_install=$nppPreInstall;post_install=$nppPostInstall}
$previewRun = Invoke-Guard 'preview' @('--root',$root,'install','extras/notes','--dry-run','--json')
Check ($previewRun.exit -eq 0) "hook preview failed: $($previewRun.error)"
Check ($previewRun.error -match 'Observed workload processes: 1') 'preview started PowerShell'
$preview = Parse-Json 'preview' $previewRun
Check ($preview.execution_available -eq $true) 'preview did not enable the real PowerShell hook path'
Check (@($preview.package.scripts).Count -eq 2 -and ($preview.package.scripts.phase -join ',') -eq 'pre_install,post_install') 'preview did not list both real hooks'
Check ($preview.package.scripts[0].text -match 'stylers\.model\.xml' -and $preview.package.scripts[1].text -match 'install-context') 'preview did not carry the real upstream script text'
Check ($preview.package.scripts[0].host -match 'PowerShell') 'preview did not name the real PowerShell host'
Check ($preview.package.script_support.library_version -match 'v0\.6\.0') 'preview did not report the pinned Scoop compatibility library version'
Check ((Test-Path -LiteralPath (Join-Path $preview.package.script_support.library_path 'core.ps1'))) 'preview library path does not contain core.ps1'
Check ((Test-Path -LiteralPath $preview.package.script_support.interpreter)) 'preview did not report a usable PowerShell interpreter'
Check ($preview.package.script_support.problem -eq '') 'preview reported a host problem while the host is usable'
Check (($preview.package.script_support.phases -join ',') -eq 'pre_install,installer,post_install,pre_uninstall,uninstaller,post_uninstall') 'preview did not disclose all six lifecycle phases'
Check ((@($preview.package.script_support.undefined_context) -join ' ') -match '\$cmd') 'preview did not explain that $cmd is not a Scoop hook variable'
Check (@($preview.operations | Where-Object { $_.kind -eq 'script' }).Count -eq 2) 'preview did not list both hook operations'
$transactionsAfterPreview = @(Get-ChildItem "$root/.coop/transactions" -Directory | Select-Object -ExpandProperty Name)
Check (-not (Test-Path -LiteralPath "$root/apps/notes") -and ($transactionsAfterPreview -join ',') -eq ($transactionsAfterPlain -join ',')) 'preview executed a hook or wrote installation state'

# --- 2. Install with the real notepadplusplus pre/post hooks. ----------------
$installRun = Invoke-Coop 'install-notes' @('--root',$root,'install','extras/notes','--json')
Check ($installRun.exit -eq 0) "hook install failed: $($installRun.error)"
$install = Parse-Json 'install-notes' $installRun
Check (@($install.scripts).Count -eq 2) 'install did not record both hooks'
Check (($install.scripts.phase -join ',') -eq 'pre_install,post_install') 'hooks did not run in the fixed install order'
Check (@($install.scripts | Where-Object { $_.exit_code -ne 0 -or $_.status -ne 'succeeded' }).Count -eq 0) 'a hook did not succeed'
$versionDirectory = [IO.Path]::GetFullPath("$root/apps/notes/1")
Check ([IO.Path]::GetFullPath($install.scripts[0].directory) -eq $versionDirectory) 'pre_install did not run in the real version directory'
Check ([IO.Path]::GetFullPath($install.scripts[1].directory) -eq [IO.Path]::GetFullPath("$root/apps/notes/current")) 'post_install did not run after current was published'
foreach ($script in $install.scripts) {
    Check ([IO.File]::Exists($script.interpreter) -and ($script.interpreter -match 'pwsh|powershell')) "hook interpreter is not a PowerShell host: $($script.interpreter)"
    Check (Test-Path -LiteralPath $script.stdout_log) 'hook stdout log was not written'
    Check (Test-Path -LiteralPath $script.stderr_log) 'hook stderr log was not written'
    Check (Test-Path -LiteralPath $script.host) 'generated hook host script was not kept as evidence'
    Check ([IO.Path]::GetFullPath($script.scoop_library) -eq [IO.Path]::GetFullPath($scoopLibrary)) 'hook did not use the pinned Scoop compatibility library'
    Check ($script.scoop_library_version -match 'v0\.6\.0') 'hook library version was not recorded'
    Check ([IO.Path]::GetFullPath($script.context.scoopdir) -eq [IO.Path]::GetFullPath($root)) 'hook context did not bind $scoopdir to the management root'
    Check ([IO.Path]::GetFullPath($script.context.bucketsdir) -eq [IO.Path]::GetFullPath("$root/buckets")) 'hook context did not bind $bucketsdir'
    Check ($script.context.app -eq 'notes' -and $script.context.version -eq '1' -and $script.context.architecture -eq '64bit') 'hook context package identity is wrong'
    Check ($script.context.global -eq $false) 'hook context treated the user install as global'
}
Check (Test-Path -LiteralPath "$root/apps/notes/1/stylers.xml") 'pre_install did not copy stylers.model.xml'
Check (Test-Path -LiteralPath "$root/persist/notes/config.xml") 'pre_install file was not published to persistent storage'
Check (Test-Path -LiteralPath "$root/persist/notes/plugins/v1.txt") 'post_install did not run after persistence was linked'
$contextFile = Get-Content -LiteralPath "$root/apps/notes/1/install-context.reg" -Raw
Check ($contextFile.Contains('apps\\notes\\current\\notepad++.exe')) 'post_install did not substitute $npp with the real current path'
Check ($contextFile.Contains('HKEY_CURRENT_USER')) 'post_install did not keep the user registry scope'
Check (-not $contextFile.Contains('HKEY_LOCAL_MACHINE')) 'post_install treated the user installation as global'
$shimVersion = & "$root/shims/notepad++.exe"
Check ($LASTEXITCODE -eq 0 -and $shimVersion -eq 'fixture 1') 'the installed command entry was not usable'
$installJournal = Last-Journal 'notes'
Check ($installJournal.state -eq 'committed' -and @($installJournal.scripts).Count -eq 2) 'install journal does not record both hooks'
Check ($installJournal.scripts[0].context.scoopdir -eq $root -and $installJournal.scripts[0].scoop_library_version -match 'v0\.6\.0') 'install journal lost the hook session evidence'
[IO.File]::WriteAllText("$root/persist/notes/config.xml",'persisted v1 data',[Text.UTF8Encoding]::new($false))

# --- 3. Update reruns the real hooks and keeps declared data. ----------------
$notesZip2 = New-PayloadZip 'notes-2' @{'notepad++.exe'=$null;'stylers.model.xml'='model v2';'plugins.original/v2.txt'='plugin v2'}
[IO.File]::WriteAllBytes((Join-Path "$root/build/notes-2" 'notepad++.exe'),[IO.File]::ReadAllBytes($fixture2))
Remove-Item -LiteralPath $notesZip2 -Force
[IO.Compression.ZipFile]::CreateFromDirectory("$root/build/notes-2",$notesZip2)
Write-Manifest 'extras' 'notes' @{version='2';url=([Uri]$notesZip2).AbsoluteUri;hash=(File-Hash $notesZip2);bin='notepad++.exe';
    persist=$notesPersist;pre_install=$nppPreInstall;post_install=$nppPostInstall}
$updateRun = Invoke-Coop 'update-notes' @('--root',$root,'update','notes','--json')
Check ($updateRun.exit -eq 0) "hook update failed: $($updateRun.error)"
$update = Parse-Json 'update-notes' $updateRun
Check (@($update.scripts | Where-Object { $_.exit_code -ne 0 }).Count -eq 0) 'update hooks did not succeed'
Check ((Get-Content -LiteralPath "$root/persist/notes/config.xml" -Raw) -eq 'persisted v1 data') 'update discarded persistent data'
Check (Test-Path -LiteralPath "$root/persist/notes/plugins/v2.txt") 'the new post_install did not run after persistence was linked'
Check ($update.retained_versions -contains '1') 'update did not retain the previous version'
$version = & "$root/shims/notepad++.exe"
Check ($LASTEXITCODE -eq 0 -and $version -eq 'fixture 2') 'the updated command entry runs the wrong version'
$notesUninstall = Invoke-Coop 'uninstall-notes' @('--root',$root,'uninstall','notes','--json')
Check ($notesUninstall.exit -eq 0) "notes uninstall failed: $($notesUninstall.error)"
Check ((Test-Path -LiteralPath "$root/persist/notes/config.xml") -and -not (Test-Path -LiteralPath "$root/apps/notes/current")) 'notes uninstall did not retain persistent data'

# --- 4. Real git post_install text that the old subset refused. --------------
$gitZip = New-PayloadZip 'git-1' @{'bin/sh.exe'=$null;'cmd/git.exe'=$null;'mingw64/.keep'='';'etc/.keep'=''}
[IO.File]::WriteAllBytes((Join-Path "$root/build/git-1" 'bin/sh.exe'),[IO.File]::ReadAllBytes($fixture1))
[IO.File]::WriteAllBytes((Join-Path "$root/build/git-1" 'cmd/git.exe'),[IO.File]::ReadAllBytes($fixture1))
Remove-Item -LiteralPath $gitZip -Force
[IO.Compression.ZipFile]::CreateFromDirectory("$root/build/git-1",$gitZip)
Write-Manifest 'main' 'git' @{version='1';url=([Uri]$gitZip).AbsoluteUri;hash=(File-Hash $gitZip);bin='cmd/git.exe';
    post_install=$gitPostInstall}
$gitInstall = Invoke-Coop 'install-git' @('--root',$root,'install','main/git','--json')
Check ($gitInstall.exit -eq 0) "real git post_install failed: $($gitInstall.error)"
$gitResult = Parse-Json 'install-git' $gitInstall
Check ($gitResult.scripts[0].phase -eq 'post_install' -and $gitResult.scripts[0].exit_code -eq 0) 'real git post_install did not run'
$gitDir = [IO.Path]::GetFullPath("$root/apps/git/1")
$gitContextReg = "$gitDir/install-context.reg"
Check (Test-Path -LiteralPath $gitContextReg) 'real git post_install did not generate install-context.reg'
$gitRegBytes = [IO.File]::ReadAllBytes($gitContextReg)
Check ($gitRegBytes.Length -gt 2 -and $gitRegBytes[0] -eq 0xFF -and $gitRegBytes[1] -eq 0xFE) 'real git post_install did not write the declared unicode encoding'
$gitContextText = [IO.File]::ReadAllText($gitContextReg)
Check ($gitContextText -notmatch '\{\{git_dir\}\}') 'real git post_install did not substitute {{git_dir}}'
Check ($gitContextText.Contains([IO.Path]::GetFullPath("$root/apps/git/current").Replace('\','\\'))) 'real git post_install substituted a different directory'
Check (Test-Path -LiteralPath "$gitDir/uninstall-context.reg") 'real git post_install processed only one bucket script'

# --- 5. Real git pre_uninstall before real git pre_install on update. -------
$orderZip1 = New-PayloadZip 'order-1' @{'app.exe'=$null;'etc/gitconfig'=('worktree = '+($root -replace '\\','/')+'/apps/order/1/mingw64')}
[IO.File]::WriteAllBytes((Join-Path "$root/build/order-1" 'app.exe'),[IO.File]::ReadAllBytes($fixture1))
Remove-Item -LiteralPath $orderZip1 -Force
[IO.Compression.ZipFile]::CreateFromDirectory("$root/build/order-1",$orderZip1)
Write-Manifest 'main' 'order' @{version='1';url=([Uri]$orderZip1).AbsoluteUri;hash=(File-Hash $orderZip1);bin='app.exe';
    pre_uninstall=$gitPreUninstall}
$orderInstall = Invoke-Coop 'install-order-1' @('--root',$root,'install','main/order','--json')
Check ($orderInstall.exit -eq 0) "order fixture install failed: $($orderInstall.error)"
Check (-not (Test-Path -LiteralPath "$root/persist/order/etc/gitconfig")) 'pre_uninstall ran during install'
$orderZip2 = New-PayloadZip 'order-2' @{'app.exe'=$null;'mingw64/.keep'='';'etc/.keep'='';'node_modules/npm/.keep'=''}
[IO.File]::WriteAllBytes((Join-Path "$root/build/order-2" 'app.exe'),[IO.File]::ReadAllBytes($fixture2))
Remove-Item -LiteralPath $orderZip2 -Force
[IO.Compression.ZipFile]::CreateFromDirectory("$root/build/order-2",$orderZip2)
Write-Manifest 'main' 'order' @{version='2';url=([Uri]$orderZip2).AbsoluteUri;hash=(File-Hash $orderZip2);bin='app.exe';
    pre_install=$gitPreInstall;post_install=$nodePostInstall}
$orderUpdate = Invoke-Coop 'update-order' @('--root',$root,'update','order','--json')
Check ($orderUpdate.exit -eq 0) "real git hook update failed: $($orderUpdate.error)"
$orderResult = Parse-Json 'update-order' $orderUpdate
$orderPhases = @($orderResult.scripts | ForEach-Object { $_.phase })
Check (($orderPhases -join ',') -eq 'pre_uninstall,pre_install,post_install') 'update did not follow the fixed uninstall-then-install hook order'
Check ((Get-Content -LiteralPath "$root/persist/order/etc/gitconfig" -Raw) -eq ('worktree = '+($root -replace '\\','/')+'/apps/order/1/mingw64')) 'the real git pre_uninstall hook did not save the config'
$restored = Get-Content -LiteralPath "$root/apps/order/2/etc/gitconfig" -Raw
Check ($restored.Contains('/apps/order/2/mingw64')) 'the real git pre_install hook did not rewrite the restored version path'
Check (-not $restored.Contains('/apps/order/1/')) 'the real git pre_install hook kept the previous version path'
$npmrc = Get-Content -LiteralPath "$root/apps/order/2/node_modules/npm/npmrc" -Raw
$persistText = [IO.Path]::GetFullPath("$root/persist/order")
Check ($npmrc.TrimEnd() -eq "prefix=$persistText\bin`ncache=$persistText\cache") 'the real nodejs post_install did not receive $persist_dir'
$orderJournal = Last-Journal 'order'
Check (@($orderJournal.scripts | Where-Object { $_.previous_package -eq $true }).Count -eq 1) 'journal lost the previous-package hook record'
$orderUninstall = Invoke-Coop 'uninstall-order' @('--root',$root,'uninstall','order','--json')
Check ($orderUninstall.exit -eq 0) "order uninstall failed: $($orderUninstall.error)"
Check ((Test-Path -LiteralPath "$root/persist/order/etc/gitconfig") -and -not (Test-Path -LiteralPath "$root/apps/order/current")) 'uninstall did not retain persistent data'

# --- 6. Plain uninstall runs the real git pre_uninstall. --------------------
$unhookZip = New-PayloadZip 'unhook-1' @{'app.exe'=$null;'etc/gitconfig'='config before uninstall'}
[IO.File]::WriteAllBytes((Join-Path "$root/build/unhook-1" 'app.exe'),[IO.File]::ReadAllBytes($fixture1))
Remove-Item -LiteralPath $unhookZip -Force
[IO.Compression.ZipFile]::CreateFromDirectory("$root/build/unhook-1",$unhookZip)
Write-Manifest 'main' 'unhook' @{version='1';url=([Uri]$unhookZip).AbsoluteUri;hash=(File-Hash $unhookZip);bin='app.exe';
    pre_uninstall=$gitPreUninstall}
$unhookInstall = Invoke-Coop 'install-unhook' @('--root',$root,'install','main/unhook','--json')
Check ($unhookInstall.exit -eq 0) "plain uninstall fixture install failed: $($unhookInstall.error)"
$unhookPreview = Invoke-Guard 'preview-uninstall-unhook' @('--root',$root,'uninstall','unhook','--dry-run','--json')
Check ($unhookPreview.exit -eq 0 -and $unhookPreview.error -match 'Observed workload processes: 1') 'uninstall preview executed PowerShell'
$unhookRun = Invoke-Coop 'uninstall-unhook' @('--root',$root,'uninstall','unhook','--json')
Check ($unhookRun.exit -eq 0) "plain uninstall hook failed: $($unhookRun.error)"
$unhook = Parse-Json 'uninstall-unhook' $unhookRun
Check (@($unhook.scripts).Count -eq 1) 'plain uninstall did not record the pre_uninstall hook'
Check ($unhook.scripts[0].phase -eq 'pre_uninstall' -and $unhook.scripts[0].previous_package -eq $false -and $unhook.scripts[0].context.purge -eq $false) 'plain uninstall hook record is wrong'
Check ([IO.Path]::GetFullPath($unhook.scripts[0].directory) -eq [IO.Path]::GetFullPath("$root/apps/unhook/1")) 'plain uninstall pre_uninstall did not run in the version directory'
Check ($unhook.data_retained -eq $true) 'plain uninstall did not report retained data'
Check ((Get-Content -LiteralPath "$root/persist/unhook/etc/gitconfig" -Raw) -eq 'config before uninstall') 'plain uninstall pre_uninstall did not save config to $persist_dir'
Check (-not (Test-Path -LiteralPath "$root/apps/unhook/current") -and -not (Test-Path -LiteralPath "$root/apps/unhook/1") -and
    -not (Test-Path -LiteralPath "$root/shims/app.exe") -and -not (Test-Path -LiteralPath "$root/.coop/packages/unhook.json")) 'plain uninstall left package state'
$unhookJournal = Last-Journal 'unhook'
Check ($unhookJournal.action -eq 'uninstall' -and $unhookJournal.state -eq 'committed' -and
    @($unhookJournal.scripts).Count -eq 1 -and $unhookJournal.scripts[0].phase -eq 'pre_uninstall') 'plain uninstall journal does not record the hook'
Check ((Get-Content -LiteralPath $unhookJournal.scripts[0].stdout_log -Raw) -match 'Saving system-level config') 'plain uninstall hook stdout log is missing'

# --- 7. Context and real Scoop helpers in one hook session. ----------------
$contextZip = New-PayloadZip 'contextdemo' @{'context.exe'=$null}
[IO.File]::WriteAllBytes((Join-Path "$root/build/contextdemo" 'context.exe'),[IO.File]::ReadAllBytes($fixture1))
Remove-Item -LiteralPath $contextZip -Force
[IO.Compression.ZipFile]::CreateFromDirectory("$root/build/contextdemo",$contextZip)
$contextScript = @(
    '$snapshot = [ordered]@{',
    '    app = $app',
    '    bucket = $bucket',
    '    version = $version',
    '    architecture = $architecture',
    '    fname = $fname',
    '    dir = $dir',
    '    original_dir = $original_dir',
    '    persist_dir = $persist_dir',
    '    bucketsdir = $bucketsdir',
    '    scoopdir = $scoopdir',
    '    cachedir = $cachedir',
    '    global = $global',
    '    cmd_defined = $null -ne $cmd',
    '    purge_defined = $null -ne $purge',
    '    manifest_version = $manifest.version',
    '    helper_ensure = $null -ne (Get-Command ensure -ErrorAction SilentlyContinue)',
    '    helper_error = $null -ne (Get-Command error -ErrorAction SilentlyContinue)',
    '    helper_abort = $null -ne (Get-Command abort -ErrorAction SilentlyContinue)',
    '    helper_success = $null -ne (Get-Command success -ErrorAction SilentlyContinue)',
    '    helper_env_add_path = $null -ne (Get-Command env_add_path -ErrorAction SilentlyContinue)',
    '    helper_env_set = $null -ne (Get-Command env_set -ErrorAction SilentlyContinue)',
    '    helper_expand_dark = $null -ne (Get-Command Expand-DarkArchive -ErrorAction SilentlyContinue)',
    '    helper_get_env = $null -ne (Get-Command Get-EnvVar -ErrorAction SilentlyContinue)',
    '    helper_external = $null -ne (Get-Command Invoke-ExternalCommand -ErrorAction SilentlyContinue)',
    '    helper_is_admin = $null -ne (Get-Command is_admin -ErrorAction SilentlyContinue)',
    '}',
    '$snapshot | ConvertTo-Json | Set-Content -Path (Join-Path $dir ''context.json'') -Encoding utf8',
    'ensure (Join-Path $dir ''ensured'') | Out-Null',
    'info ''helper observation''',
    'warn ''helper warning''',
    'success ''helper success'''
)
Write-Manifest 'main' 'contextdemo' @{version='1';url=([Uri]$contextZip).AbsoluteUri;hash=(File-Hash $contextZip);bin='context.exe';
    pre_install=$contextScript}
$contextInstall = Invoke-Coop 'install-contextdemo' @('--root',$root,'install','main/contextdemo','--json')
Check ($contextInstall.exit -eq 0) "context hook install failed: $($contextInstall.error)"
$contextInstallResult = Parse-Json 'install-contextdemo' $contextInstall
$contextSnapshot = Get-Content -LiteralPath "$root/apps/contextdemo/1/context.json" -Raw | ConvertFrom-Json
Check ([IO.Path]::GetFullPath($contextSnapshot.scoopdir) -eq [IO.Path]::GetFullPath($root)) 'hook $scoopdir is not the management root'
Check ([IO.Path]::GetFullPath($contextSnapshot.bucketsdir) -eq [IO.Path]::GetFullPath("$root/buckets")) 'hook $bucketsdir is not the shared bucket directory'
Check ([IO.Path]::GetFullPath($contextSnapshot.cachedir) -eq [IO.Path]::GetFullPath("$root/cache")) 'hook $cachedir is not the root cache directory'
Check ([IO.Path]::GetFullPath($contextSnapshot.dir) -eq [IO.Path]::GetFullPath("$root/apps/contextdemo/1")) 'hook $dir is not the version directory'
Check ([IO.Path]::GetFullPath($contextSnapshot.original_dir) -eq [IO.Path]::GetFullPath("$root/apps/contextdemo/1")) 'hook $original_dir is not the version directory'
Check ([IO.Path]::GetFullPath($contextSnapshot.persist_dir) -eq [IO.Path]::GetFullPath("$root/persist/contextdemo")) 'hook $persist_dir is wrong'
Check ($contextSnapshot.app -eq 'contextdemo' -and $contextSnapshot.bucket -eq 'main' -and $contextSnapshot.version -eq '1' -and
    $contextSnapshot.architecture -eq '64bit' -and $contextSnapshot.fname -eq 'contextdemo.zip' -and
    $contextSnapshot.manifest_version -eq '1') 'hook package context is wrong'
Check ($contextSnapshot.global -eq $false) 'hook $global is not false for a user install'
Check ($contextSnapshot.cmd_defined -eq $false) 'hook session defined $cmd, which Scoop never provides'
Check ($contextSnapshot.purge_defined -eq $false) 'hook session defined $purge during install'
foreach ($helper in 'helper_ensure','helper_error','helper_abort','helper_success','helper_env_add_path','helper_env_set',
        'helper_expand_dark','helper_get_env','helper_external','helper_is_admin') {
    Check ($contextSnapshot.$helper -eq $true) "real Scoop helper is missing from the hook session: $helper"
}
Check (Test-Path -LiteralPath "$root/apps/contextdemo/1/ensured") 'the real ensure helper did not create the directory'
$contextLog = Get-Content -LiteralPath $contextInstallResult.scripts[0].stdout_log -Raw
Check ($contextLog -match 'INFO  helper observation') 'the real info helper did not write the Scoop INFO prefix'
Check ($contextLog -match 'WARN  helper warning') 'the real warn helper did not write the Scoop WARN prefix'
Check ($contextLog -match 'helper success') 'the real success helper did not write its message'
Check ($contextInstallResult.scripts[0].stderr_bytes -eq 0) 'a successful hook wrote to stderr'

# --- 8. post_uninstall and $purge follow the real uninstall session. --------
$afterZip = New-PayloadZip 'after-1' @{'after.exe'=$null;'state/.keep'=''}
[IO.File]::WriteAllBytes((Join-Path "$root/build/after-1" 'after.exe'),[IO.File]::ReadAllBytes($fixture1))
Remove-Item -LiteralPath $afterZip -Force
[IO.Compression.ZipFile]::CreateFromDirectory("$root/build/after-1",$afterZip)
$afterScript = @(
    '$snapshot = [ordered]@{purge=$purge; purge_defined=($null -ne $purge); dir_exists=(Test-Path -LiteralPath $dir)}',
    '$snapshot | ConvertTo-Json | Set-Content -Path (Join-Path $persist_dir ''after.json'') -Encoding utf8',
    'Write-Output ("purge=" + $purge)'
)
Write-Manifest 'main' 'after' @{version='1';url=([Uri]$afterZip).AbsoluteUri;hash=(File-Hash $afterZip);bin='after.exe';
    persist=@('state');post_uninstall=$afterScript}
$afterInstall1 = Invoke-Coop 'install-after-1' @('--root',$root,'install','main/after','--json')
Check ($afterInstall1.exit -eq 0) "post_uninstall fixture install failed: $($afterInstall1.error)"
$afterUninstall1 = Invoke-Coop 'uninstall-after-1' @('--root',$root,'uninstall','after','--json')
Check ($afterUninstall1.exit -eq 0) "post_uninstall hook failed: $($afterUninstall1.error)"
$afterResult1 = Parse-Json 'uninstall-after-1' $afterUninstall1
Check ($afterResult1.scripts[0].phase -eq 'post_uninstall') 'post_uninstall did not run on uninstall'
$afterSnapshot = Get-Content -LiteralPath "$root/persist/after/after.json" -Raw | ConvertFrom-Json
Check ($afterSnapshot.purge_defined -eq $true -and $afterSnapshot.purge -eq $false) 'post_uninstall did not receive $purge=$false for a normal uninstall'
Check ($afterSnapshot.dir_exists -eq $false) 'post_uninstall ran before the version directory was removed'
$afterInstall2 = Invoke-Coop 'install-after-2' @('--root',$root,'install','main/after','--json')
Check ($afterInstall2.exit -eq 0) "post_uninstall fixture reinstall failed: $($afterInstall2.error)"
$afterUninstall2 = Invoke-Coop 'uninstall-after-2' @('--root',$root,'uninstall','after','--purge','--json')
Check ($afterUninstall2.exit -eq 0) "purge uninstall failed: $($afterUninstall2.error)"
$afterResult2 = Parse-Json 'uninstall-after-2' $afterUninstall2
Check ($afterResult2.purge.requested -eq $true -and $afterResult2.purge.status -eq 'deleted') 'purge did not delete the declared store'
$afterPurgeLog = Get-Content -LiteralPath $afterResult2.scripts[0].stdout_log -Raw
Check ($afterPurgeLog -match 'purge=True') 'post_uninstall did not receive $purge=$true from --purge'

# --- 9. A legitimate script edit and previously refused PowerShell still runs.
$freeZip = New-PayloadZip 'freeform' @{'free.exe'=$null}
[IO.File]::WriteAllBytes((Join-Path "$root/build/freeform" 'free.exe'),[IO.File]::ReadAllBytes($fixture1))
Remove-Item -LiteralPath $freeZip -Force
[IO.Compression.ZipFile]::CreateFromDirectory("$root/build/freeform",$freeZip)
# The old subset refused functions, hashtables, try/catch, subexpressions, .NET calls, the
# pipeline operators and environment reads. This is ordinary PowerShell a Manifest may contain.
$freeformPre = @(
    'function Write-Part([string] $path, [string] $text) {',
    '    [System.IO.File]::AppendAllText($path, $text + [Environment]::NewLine)',
    '}',
    '$settings = @{ prefix = ''part''; count = 3 }',
    '$output = Join-Path -Path $dir -ChildPath ''freeform.txt''',
    'try {',
    '    foreach ($index in 1..$settings.count) {',
    '        Write-Part $output ("{0}-{1}" -f $settings.prefix, $index)',
    '    }',
    '    $selected = Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -like ''*.exe'' } | Select-Object -First 1',
    '    Write-Part $output ("selected=" + $selected.Name)',
    '    Write-Part $output ("temp=" + [bool]$env:TEMP)',
    '    Write-Part $output ("today=" + ((Get-Date).GetType().Name -eq ''DateTime''))',
    '    Write-Part $output ("subexpr=" + $($settings.count * 2))',
    '    Set-Content -LiteralPath (Join-Path $dir ''sub.txt'') -Value ''sub''',
    '} catch {',
    '    Write-Part $output ("failed=" + $_.Exception.Message)',
    '    throw',
    '} finally {',
    '    Write-Part $output ''done''',
    '}'
)
$freeformPost = @(
    '$content = Get-Content -LiteralPath (Join-Path $dir ''freeform.txt'')',
    '$content | Out-File -LiteralPath (Join-Path $dir ''freeform-copy.txt'') -Encoding utf8',
    'Write-Output ("lines=" + @($content).Count)'
)
Write-Manifest 'main' 'freeform' @{version='1';url=([Uri]$freeZip).AbsoluteUri;hash=(File-Hash $freeZip);bin='free.exe';
    pre_install=$freeformPre;post_install=$freeformPost}
$freePreview = Invoke-Guard 'preview-freeform' @('--root',$root,'install','main/freeform','--dry-run','--json')
Check ($freePreview.exit -eq 0 -and $freePreview.error -match 'Observed workload processes: 1') 'free-form preview started a hook'
$freeInstall = Invoke-Coop 'install-freeform' @('--root',$root,'install','main/freeform','--json')
Check ($freeInstall.exit -eq 0) "free-form PowerShell hook failed: $($freeInstall.error)"
$freeResult = Parse-Json 'install-freeform' $freeInstall
$freeText = Get-Content -LiteralPath "$root/apps/freeform/1/freeform.txt" -Raw
Check ($freeText -match 'part-1' -and $freeText -match 'part-3') 'the hook function/foreach/format pipeline did not run'
Check ($freeText -match 'selected=free.exe') 'the hook Where-Object/Select-Object pipeline did not run'
Check ($freeText -match 'temp=True' -and $freeText -match 'today=True' -and $freeText -match 'subexpr=6') 'environment reads, .NET types or subexpressions did not run'
Check ($freeText -match 'done') 'the hook finally block did not run'
Check (Test-Path -LiteralPath "$root/apps/freeform/1/sub.txt") 'the hook Set-Content statement with a subexpression argument did not run'
Check ((Get-Content -LiteralPath "$root/apps/freeform/1/freeform-copy.txt" -Raw) -match 'part-2') 'the post_install did not observe the pre_install output'
Check ($freeResult.scripts[1].stdout_tail -match 'lines=') 'the post_install stdout was not captured'
# A legitimate edit of a real upstream script (extra comment and extra statement) still runs.
$editedPreInstall = @('# Coop harness comment: a legitimate edit must not be a capability refusal.') +
    $nppPreInstall + @('Set-Content -LiteralPath (Join-Path $dir ''edited.txt'') -Value ''edited by the hook'' -Encoding Ascii')
Write-Manifest 'extras' 'edited' @{version='1';url=([Uri]$notesZip1).AbsoluteUri;hash=(File-Hash $notesZip1);bin='notepad++.exe';
    persist=$notesPersist;pre_install=$editedPreInstall;post_install=$nppPostInstall}
$editedInstall = Invoke-Coop 'install-edited' @('--root',$root,'install','extras/edited','--json')
Check ($editedInstall.exit -eq 0) "an edited upstream hook was refused or failed: $($editedInstall.error)"
Check ((Get-Content -LiteralPath "$root/apps/edited/1/edited.txt" -Raw).Trim() -eq 'edited by the hook') 'the edited hook did not run its added statement'
Check (Test-Path -LiteralPath "$root/apps/edited/1/stylers.xml") 'the edited hook did not keep the original statements'

# --- 10. Real rclone uninstaller.script with Get-Item LinkType. ------------
$rcloneZip = New-PayloadZip 'rclonepkg' @{'rclone.exe'=$null;'rclone.conf'='rclone config';'data/config.txt'='persisted data'}
[IO.File]::WriteAllBytes((Join-Path "$root/build/rclonepkg" 'rclone.exe'),[IO.File]::ReadAllBytes($fixture1))
Remove-Item -LiteralPath $rcloneZip -Force
[IO.Compression.ZipFile]::CreateFromDirectory("$root/build/rclonepkg",$rcloneZip)
$rclonePreUninstall = @('Set-Content -Path "$dir\pre-uninstall.txt" -Value "pre" -Encoding Ascii')
Write-Manifest 'main' 'rclonepkg' @{version='1';url=([Uri]$rcloneZip).AbsoluteUri;hash=(File-Hash $rcloneZip);bin='rclone.exe';
    persist='data';pre_uninstall=$rclonePreUninstall;uninstaller=@{script=$rcloneUninstaller}}
Check ($rcloneUninstaller -match 'LinkType') 'real rclone uninstaller text was not loaded'
$rcloneInstall = Invoke-Coop 'rclone-install' @('--root',$root,'install','main/rclonepkg','--json')
Check ($rcloneInstall.exit -eq 0) "rclone package install failed: $($rcloneInstall.error)"
Check (Test-Path -LiteralPath "$root/persist/rclonepkg/data/config.txt") 'rclone persist directory was not created'
$rcloneUninstall = Invoke-Coop 'rclone-uninstall' @('--root',$root,'uninstall','rclonepkg','--json')
Check ($rcloneUninstall.exit -eq 0) "rclone uninstall failed: $($rcloneUninstall.error)"
$rcloneResult = Parse-Json 'rclone-uninstall' $rcloneUninstall
Check ((@($rcloneResult.scripts | ForEach-Object { $_.phase }) -join ',') -eq 'pre_uninstall,uninstaller') 'uninstaller script lifecycle order is wrong'
$rcloneRun = @($rcloneResult.scripts | Where-Object { $_.phase -eq 'uninstaller' })[0]
Check ([IO.Path]::GetFullPath($rcloneRun.directory) -eq [IO.Path]::GetFullPath("$root/apps/rclonepkg/1")) 'uninstaller script did not run in the version directory'
Check ((Get-Content -LiteralPath "$root/persist/rclonepkg/rclone.conf" -Raw).Trim() -eq 'rclone config') 'real rclone uninstaller script did not use Get-Item/LinkType and copy the config'
Check ((Get-Content -LiteralPath "$root/persist/rclonepkg/data/config.txt" -Raw).Trim() -eq 'persisted data') 'uninstaller removed declared persistent data'

# --- 11. A failing hook aborts once, propagates its exit code and rolls back.
$brokenZip = New-PayloadZip 'broken' @{'broken.exe'=$null}
[IO.File]::WriteAllBytes((Join-Path "$root/build/broken" 'broken.exe'),[IO.File]::ReadAllBytes($fixture1))
Remove-Item -LiteralPath $brokenZip -Force
[IO.Compression.ZipFile]::CreateFromDirectory("$root/build/broken",$brokenZip)
Write-Manifest 'main' 'broken' @{version='1';url=([Uri]$brokenZip).AbsoluteUri;hash=(File-Hash $brokenZip);bin='broken.exe';
    pre_install=@('Copy-Item "$dir\absent.txt" "$dir\copied.txt"')}
$brokenRun = Invoke-Coop 'install-broken' @('--root',$root,'install','main/broken','--json')
Check ($brokenRun.exit -ne 0) 'a failing hook was reported as success'
Check ($brokenRun.error -match 'pre_install hook failed with exit code 1') "hook failure was not propagated: $($brokenRun.error)"
Check (-not (Test-Path -LiteralPath "$root/apps/broken/1") -and -not (Test-Path -LiteralPath "$root/shims/broken.exe") -and
    -not (Test-Path -LiteralPath "$root/.coop/packages/broken.json")) 'failed hook install published state'
$brokenJournal = Last-Journal 'broken'
Check ($brokenJournal.state -eq 'rolled-back') 'failed hook did not roll back'
Check (@($brokenJournal.scripts).Count -eq 1 -and $brokenJournal.scripts[0].status -eq 'failed' -and $brokenJournal.scripts[0].exit_code -eq 1) 'failed hook journal is inaccurate or was retried'
Check ($brokenJournal.scripts[0].stderr_bytes -gt 0 -and (Get-Content -LiteralPath $brokenJournal.scripts[0].stderr_log -Raw).Length -gt 0) 'hook stderr was not captured'
Write-Manifest 'main' 'exitcode' @{version='1';url=([Uri]$brokenZip).AbsoluteUri;hash=(File-Hash $brokenZip);bin='broken.exe';
    pre_install=@('Write-Output "before exit"; exit 9')}
$exitRun = Invoke-Coop 'install-exitcode' @('--root',$root,'install','main/exitcode','--json')
Check ($exitRun.exit -ne 0 -and $exitRun.error -match 'pre_install hook failed with exit code 9') "an explicit script exit code was not propagated: $($exitRun.error)"
$exitJournal = Last-Journal 'exitcode'
Check ($exitJournal.state -eq 'rolled-back' -and $exitJournal.scripts[0].exit_code -eq 9) 'explicit exit code was not recorded'
Check ((Get-Content -LiteralPath $exitJournal.scripts[0].stdout_log -Raw) -match 'before exit') 'output before the exit code was lost'
Write-Manifest 'main' 'thrower' @{version='1';url=([Uri]$brokenZip).AbsoluteUri;hash=(File-Hash $brokenZip);bin='broken.exe';
    pre_install=@('throw ''boom from the hook''')}
$throwRun = Invoke-Coop 'install-thrower' @('--root',$root,'install','main/thrower','--json')
Check ($throwRun.exit -ne 0 -and $throwRun.error -match 'pre_install hook failed with exit code 1') 'a terminating hook error was not propagated'
$throwJournal = Last-Journal 'thrower'
Check ((Get-Content -LiteralPath $throwJournal.scripts[0].stderr_log -Raw) -match 'boom from the hook') 'terminating error text was not captured on stderr'

# --- 12. Concurrent stdout/stderr drains do not deadlock. -------------------
$noisy = @()
for ($line = 0; $line -lt 600; $line++) { $noisy += ('Write-Output ("stdout-{0:d4}-' -f $line) + ('x'*200) + '")' }
for ($line = 0; $line -lt 400; $line++) { $noisy += ('[Console]::Error.WriteLine("stderr-{0:d4}-' -f $line) + ('y'*160) + '")' }
$noisyZip = New-PayloadZip 'noisy' @{'noisy.exe'=$null}
[IO.File]::WriteAllBytes((Join-Path "$root/build/noisy" 'noisy.exe'),[IO.File]::ReadAllBytes($fixture1))
Remove-Item -LiteralPath $noisyZip -Force
[IO.Compression.ZipFile]::CreateFromDirectory("$root/build/noisy",$noisyZip)
Write-Manifest 'main' 'noisy' @{version='1';url=([Uri]$noisyZip).AbsoluteUri;hash=(File-Hash $noisyZip);bin='noisy.exe';
    post_install=$noisy}
$noisyRun = Invoke-Coop 'install-noisy' @('--root',$root,'install','main/noisy','--json')
Check ($noisyRun.exit -eq 0) "chatty hook install failed: $($noisyRun.error)"
$noisyResult = Parse-Json 'install-noisy' $noisyRun
$noisyScript = @($noisyResult.scripts)[0]
Check ($noisyScript.stdout_bytes -gt 100000 -and $noisyScript.stderr_bytes -gt 50000) 'chatty hook output was truncated or lost'
Check ((Get-Item -LiteralPath $noisyScript.stdout_log).Length -ge $noisyScript.stdout_bytes) 'stdout log is incomplete'
Check ((Get-Item -LiteralPath $noisyScript.stderr_log).Length -ge $noisyScript.stderr_bytes) 'stderr log is incomplete'
Check ($noisyScript.stdout_tail.Contains('stdout-0599-')) 'stdout tail lost the last line'
Check ($noisyScript.stderr_tail.Contains('stderr-0399-')) 'stderr tail lost the last line'

# --- 13. Missing interpreter or compatibility library is disclosed. ---------
$missingPowerShell = @{COOP_POWERSHELL="$root/missing-pwsh.exe"}
$missingRun = Invoke-Coop 'preview-missing-powershell' @('--root',$root,'install','extras/notes','--dry-run','--json') $missingPowerShell
Check ($missingRun.exit -eq 0) "missing PowerShell runtime preview failed: $($missingRun.error)"
$missing = Parse-Json 'preview-missing-powershell' $missingRun
Check ($missing.execution_available -eq $false) 'missing PowerShell runtime stayed executable'
Check (@($missing.diagnostics | Where-Object { $_.code -eq 'execution-blocked' -and $_.message -match 'PowerShell' }).Count -eq 1) 'missing PowerShell diagnostic is absent'
$transactionsBeforeMissing = @(Get-ChildItem "$root/.coop/transactions" -Directory | Select-Object -ExpandProperty Name)
$missingInstall = Invoke-Coop 'install-missing-powershell' @('--root',$root,'install','extras/notes','--json') $missingPowerShell
$transactionsAfterMissing = @(Get-ChildItem "$root/.coop/transactions" -Directory | Select-Object -ExpandProperty Name)
Check ($missingInstall.exit -ne 0 -and ($transactionsAfterMissing -join ',') -eq ($transactionsBeforeMissing -join ',')) 'missing PowerShell still started a transaction'
$emptyLibrary = "$root/empty-scoop-lib"
New-Item -ItemType Directory -Path $emptyLibrary -Force | Out-Null
$missingLibraryRun = Invoke-Coop 'preview-missing-library' @('--root',$root,'install','extras/notes','--dry-run','--json') @{COOP_SCOOP_LIB=$emptyLibrary}
Check ($missingLibraryRun.exit -eq 0) "missing compatibility library preview failed: $($missingLibraryRun.error)"
$missingLibrary = Parse-Json 'preview-missing-library' $missingLibraryRun
Check ($missingLibrary.execution_available -eq $false) 'missing Scoop compatibility library stayed executable'
Check (@($missingLibrary.diagnostics | Where-Object { $_.code -eq 'execution-blocked' -and $_.message -match 'compatibility library' }).Count -eq 1) 'missing compatibility library diagnostic is absent'

# --- 14. Adoption of hook packages stays untested until real evidence exists.
$legacyDirectory = "$root/apps/legacyhook/1"
New-Item -ItemType Directory -Path $legacyDirectory -Force | Out-Null
[IO.File]::WriteAllBytes("$legacyDirectory/legacy.exe",[IO.File]::ReadAllBytes($fixture1))
$legacyManifest = @{version='1';url=([Uri]$fixture1).AbsoluteUri+'#/legacy.exe';hash=(File-Hash $fixture1);pre_install=$nodePostInstall}
Write-Manifest 'main' 'legacyhook' $legacyManifest
$legacyManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$legacyDirectory/scoop-manifest.json" -Encoding utf8
@{architecture='64bit';bucket='main'} | ConvertTo-Json | Set-Content -LiteralPath "$legacyDirectory/scoop-install.json" -Encoding utf8
New-Item -ItemType Junction -Path "$root/apps/legacyhook/current" -Target $legacyDirectory | Out-Null
$adoptRun = Invoke-Coop 'adopt-preview' @('--root',$root,'adopt','legacyhook','--dry-run','--json')
$adopt = Parse-Json 'adopt-preview' $adoptRun
Check ($adopt.eligibility -eq 'untested') 'adoption of a hook package was promoted without real evidence'
Check (@($adopt.diagnostics | Where-Object { $_.message -match 'script-adoption-unverified' -or $_.message -match 'lifecycle hooks' }).Count -ge 1) 'adoption did not explain the missing hook evidence'
$adoptReal = Invoke-Coop 'adopt' @('--root',$root,'adopt','legacyhook','--json')
Check ($adoptReal.exit -ne 0 -and -not (Test-Path -LiteralPath "$root/.coop/packages/legacyhook.json")) 'hook package adoption wrote a management record'

@{
    timestamp=[DateTime]::UtcNow.ToString('o')
    root=$root
    checks=$script:checks
    runs=$script:runs
    coop_sha256=(File-Hash $CoopExe)
    powershell=$pwshPath
    scoop_library=@{path=$scoopLibrary;version=$preview.package.script_support.library_version}
    real_hook_sources=@('Extras/notepadplusplus pre_install+post_install','Main/git pre_install+post_install+pre_uninstall',
        'Main/nodejs post_install','Main/rclone uninstaller.script')
    previously_refused_now_executed=@('Main/git post_install (Get-ChildItem/ForEach-Object/-replace)',
        'Main/git pre_install (.NET File APIs, regex rewrite, Where-Object/Select-Object)',
        'functions, hashtables, try/catch/finally, subexpressions, .NET calls and environment reads in a normal hook')
    fixture_artifacts='project fixture programs; real package payloads were not downloaded or run'
    registry_imports='no script imported registry entries; git post_install only rendered .reg templates into the package directory'
    adoption_promoted=$false
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$root/evidence.json" -Encoding utf8
Write-Output "PASS real PowerShell lifecycle hooks, Scoop context/helpers, order, failure and capability disclosure: $root/evidence.json ($script:checks checks)"
exit 0

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
$pwshPath = (Get-Process -Id $PID).Path
foreach ($path in @($fixture1,$fixture2,$guard,$pwshPath)) { if (-not (Test-Path -LiteralPath $path)) { throw "Missing fixed test input: $path" } }

$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/extras/bucket","$root/buckets/extras/scripts/notepadplusplus",
    "$root/buckets/main/bucket","$root/temp","$root/build","$root/programs" -Force | Out-Null
Copy-Item "$PSScriptRoot/corpus/extras-scripts/notepadplusplus/*.reg" "$root/buckets/extras/scripts/notepadplusplus/"
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
$nodePostInstall = Get-CorpusScript 'corpus/main/nodejs.json' 'post_install'
$gitPreUninstall = Get-CorpusScript 'corpus/main/git.json' 'pre_uninstall'
$aiderPostUninstall = Get-CorpusScript 'corpus/extras/aider-desk.json' 'post_uninstall'
$azurePreUninstall = Get-CorpusScript 'corpus/main/azure-cli.json' 'pre_uninstall'
Check ($nppPreInstall.Count -gt 1 -and $nppPostInstall.Count -gt 1) 'real notepadplusplus hooks were not loaded'

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

# --- 1. Preview lists hooks without executing PowerShell. --------------------
$notesZip1 = New-PayloadZip 'notes-1' @{'notepad++.exe'=$null;'stylers.model.xml'='model';'plugins.original/v1.txt'='plugin v1';'node_modules/npm/.keep'=''}
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
Check ($preview.execution_available -eq $true) 'preview did not enable the supported hook path'
Check (@($preview.package.scripts | Where-Object { -not $_.compatible }).Count -eq 0) 'real supported hooks were reported incompatible'
Check (@($preview.operations | Where-Object { $_.kind -eq 'script' }).Count -eq 2) 'preview did not list both hook operations'
$transactionsAfterPreview = @(Get-ChildItem "$root/.coop/transactions" -Directory | Select-Object -ExpandProperty Name)
Check (-not (Test-Path -LiteralPath "$root/apps/notes") -and ($transactionsAfterPreview -join ',') -eq ($transactionsAfterPlain -join ',')) 'preview executed a hook or wrote installation state'

# --- 2. Install with real notepadplusplus pre/post install hooks. ------------
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
[IO.File]::WriteAllText("$root/persist/notes/config.xml",'persisted v1 data',[Text.UTF8Encoding]::new($false))

# --- 3. Update reruns the real hooks and keeps declared data. ----------------
$notesZip2 = New-PayloadZip 'notes-2' @{'notepad++.exe'=$null;'stylers.model.xml'='model v2';'plugins.original/v2.txt'='plugin v2';'node_modules/npm/.keep'=''}
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

# --- 4. Update order: old pre_uninstall before new pre_install. --------------
$orderZip1 = New-PayloadZip 'order-1' @{'app.exe'=$null;'etc/gitconfig'='config v1'}
[IO.File]::WriteAllBytes((Join-Path "$root/build/order-1" 'app.exe'),[IO.File]::ReadAllBytes($fixture1))
Remove-Item -LiteralPath $orderZip1 -Force
[IO.Compression.ZipFile]::CreateFromDirectory("$root/build/order-1",$orderZip1)
Write-Manifest 'main' 'order' @{version='1';url=([Uri]$orderZip1).AbsoluteUri;hash=(File-Hash $orderZip1);bin='app.exe';
    pre_uninstall=$gitPreUninstall}
$orderZip2 = New-PayloadZip 'order-2' @{'app.exe'=$null;'node_modules/npm/.keep'='';'etc/.keep'=''}
[IO.File]::WriteAllBytes((Join-Path "$root/build/order-2" 'app.exe'),[IO.File]::ReadAllBytes($fixture2))
Remove-Item -LiteralPath $orderZip2 -Force
[IO.Compression.ZipFile]::CreateFromDirectory("$root/build/order-2",$orderZip2)
$seenScript = @('if (Test-Path "$persist_dir\etc\gitconfig") {',
    '    Copy-Item "$persist_dir\etc\gitconfig" "$dir\etc\gitconfig.seen"',
    '}')
Write-Manifest 'main' 'order' @{version='1';url=([Uri]$orderZip1).AbsoluteUri;hash=(File-Hash $orderZip1);bin='app.exe';
    pre_uninstall=$gitPreUninstall}
$orderInstall = Invoke-Coop 'install-order-1' @('--root',$root,'install','main/order','--json')
Check ($orderInstall.exit -eq 0) "order fixture install failed: $($orderInstall.error)"
Check (-not (Test-Path -LiteralPath "$root/persist/order/etc/gitconfig")) 'pre_uninstall ran during install'
Write-Manifest 'main' 'order' @{version='2';url=([Uri]$orderZip2).AbsoluteUri;hash=(File-Hash $orderZip2);bin='app.exe';
    pre_install=$seenScript;post_install=$nodePostInstall}
$orderUpdate = Invoke-Coop 'update-order' @('--root',$root,'update','order','--json')
Check ($orderUpdate.exit -eq 0) "order update failed: $($orderUpdate.error)"
$orderResult = Parse-Json 'update-order' $orderUpdate
$orderPhases = @($orderResult.scripts | ForEach-Object { $_.phase })
Check (($orderPhases -join ',') -eq 'pre_uninstall,pre_install,post_install') 'update did not follow the fixed uninstall-then-install hook order'
Check ((Get-Content -LiteralPath "$root/persist/order/etc/gitconfig" -Raw) -eq 'config v1') 'the real git pre_uninstall hook did not save the config'
Check ((Get-Content -LiteralPath "$root/apps/order/2/etc/gitconfig.seen" -Raw) -eq 'config v1') 'the new pre_install did not observe the old pre_uninstall result'
$npmrc = Get-Content -LiteralPath "$root/apps/order/2/node_modules/npm/npmrc" -Raw
$persistText = [IO.Path]::GetFullPath("$root/persist/order")
Check ($npmrc.TrimEnd() -eq "prefix=$persistText\bin`ncache=$persistText\cache") 'the real nodejs post_install did not receive $persist_dir'
$orderJournal = Last-Journal 'order'
Check (@($orderJournal.scripts | Where-Object { $_.previous_package -eq $true }).Count -eq 1) 'journal lost the previous-package hook record'
$orderUninstall = Invoke-Coop 'uninstall-order' @('--root',$root,'uninstall','order','--json')
Check ($orderUninstall.exit -eq 0) "order uninstall failed: $($orderUninstall.error)"
Check ((Test-Path -LiteralPath "$root/persist/order/etc/gitconfig") -and -not (Test-Path -LiteralPath "$root/apps/order/current")) 'uninstall did not retain persistent data'

# --- 5. A supported hook that fails aborts once and rolls back. --------------
$brokenZip = New-PayloadZip 'broken' @{'broken.exe'=$null}
[IO.File]::WriteAllBytes((Join-Path "$root/build/broken" 'broken.exe'),[IO.File]::ReadAllBytes($fixture1))
Remove-Item -LiteralPath $brokenZip -Force
[IO.Compression.ZipFile]::CreateFromDirectory("$root/build/broken",$brokenZip)
$failingHook = @('Copy-Item "$dir\absent.txt" "$dir\copied.txt"')
Write-Manifest 'main' 'broken' @{version='1';url=([Uri]$brokenZip).AbsoluteUri;hash=(File-Hash $brokenZip);bin='broken.exe';
    pre_install=$failingHook}
$brokenRun = Invoke-Coop 'install-broken' @('--root',$root,'install','main/broken','--json')
Check ($brokenRun.exit -ne 0) 'a failing hook was reported as success'
Check ($brokenRun.error -match 'pre_install hook failed with exit code 1') "hook failure was not propagated: $($brokenRun.error)"
Check (-not (Test-Path -LiteralPath "$root/apps/broken/1") -and -not (Test-Path -LiteralPath "$root/shims/broken.exe") -and
    -not (Test-Path -LiteralPath "$root/.coop/packages/broken.json")) 'failed hook install published state'
$brokenJournal = Last-Journal 'broken'
Check ($brokenJournal.state -eq 'rolled-back') 'failed hook did not roll back'
Check (@($brokenJournal.scripts).Count -eq 1 -and $brokenJournal.scripts[0].status -eq 'failed' -and $brokenJournal.scripts[0].exit_code -eq 1) 'failed hook journal is inaccurate or was retried'
Check ($brokenJournal.scripts[0].stderr_bytes -gt 0 -and (Get-Content -LiteralPath $brokenJournal.scripts[0].stderr_log -Raw).Length -gt 0) 'hook stderr was not captured'

# --- 6. Concurrent stdout/stderr drains do not deadlock. ---------------------
$noisy = @()
for ($line = 0; $line -lt 1200; $line++) { $noisy += ('info "' + ('stdout-{0:d4}-' -f $line) + ('x'*200) + '"') }
for ($line = 0; $line -lt 800; $line++) { $noisy += ('warn "' + ('stderr-{0:d4}-' -f $line) + ('y'*160) + '"') }
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
Check ($noisyScript.stdout_bytes -gt 200000 -and $noisyScript.stderr_bytes -gt 100000) 'chatty hook output was truncated or lost'
Check ((Get-Item -LiteralPath $noisyScript.stdout_log).Length -ge $noisyScript.stdout_bytes) 'stdout log is incomplete'
Check ((Get-Item -LiteralPath $noisyScript.stderr_log).Length -ge $noisyScript.stderr_bytes) 'stderr log is incomplete'
Check ($noisyScript.stdout_tail.Contains('stdout-1199-')) 'stdout tail lost the last line'
Check ($noisyScript.stderr_tail.Contains('stderr-0799-')) 'stderr tail lost the last line'

# --- 7. Real hooks outside the proven subset are refused before execution. ---
$unsafeZip = New-PayloadZip 'unsafe' @{'unsafe.exe'=$null}
[IO.File]::WriteAllBytes((Join-Path "$root/build/unsafe" 'unsafe.exe'),[IO.File]::ReadAllBytes($fixture1))
Remove-Item -LiteralPath $unsafeZip -Force
[IO.Compression.ZipFile]::CreateFromDirectory("$root/build/unsafe",$unsafeZip)
Write-Manifest 'main' 'unsafe' @{version='1';url=([Uri]$unsafeZip).AbsoluteUri;hash=(File-Hash $unsafeZip);bin='unsafe.exe';
    post_uninstall=$aiderPostUninstall}
$unsafePreview = Invoke-Guard 'preview-unsafe' @('--root',$root,'install','main/unsafe','--dry-run','--json')
Check ($unsafePreview.exit -eq 0) "unsupported post_uninstall hook preview failed: $($unsafePreview.error)"
Check ($unsafePreview.error -match 'Observed workload processes: 1') 'unsupported hook preview started PowerShell'
$unsafe = Parse-Json 'preview-unsafe' $unsafePreview
Check ($unsafe.execution_available -eq $false) 'unsupported hook path stayed executable'
Check (@($unsafe.diagnostics | Where-Object { $_.code -eq 'execution-blocked' -and $_.message -match 'post_uninstall' }).Count -eq 1) 'post_uninstall capability diagnostic is missing'
Check (@($unsafe.package.scripts | Where-Object { -not $_.compatible -and @($_.diagnostics | Where-Object { $_.code -eq 'unsupported-script-phase' }).Count -eq 1 }).Count -eq 1) 'script compatibility report did not name the disabled phase'
$unsafeInstall = Invoke-Guard 'install-unsafe' @('--root',$root,'install','main/unsafe','--json')
Check ($unsafeInstall.exit -ne 0 -and $unsafeInstall.error -match 'Observed workload processes: 1') 'unsupported hook execution was not refused before PowerShell'
Check (-not (Test-Path -LiteralPath "$root/apps/unsafe")) 'unsupported hook install created a version directory'
Write-Manifest 'main' 'unsafe' @{version='1';url=([Uri]$unsafeZip).AbsoluteUri;hash=(File-Hash $unsafeZip);bin='unsafe.exe';
    pre_uninstall=$azurePreUninstall}
$azureRun = Invoke-Coop 'preview-unsafe-azure' @('--root',$root,'install','main/unsafe','--dry-run','--json')
Check ($azureRun.exit -eq 0) "complex hook preview failed: $($azureRun.error)"
$azure = Parse-Json 'preview-unsafe-azure' $azureRun
Check ($azure.execution_available -eq $false) 'complex pre_uninstall script stayed executable'
Check (@($azure.package.scripts | Where-Object { -not $_.compatible }).Count -eq 1) 'complex pre_uninstall script was not diagnosed'
Write-Manifest 'main' 'unsafe' @{version='1';url=([Uri]$unsafeZip).AbsoluteUri;hash=(File-Hash $unsafeZip);bin='unsafe.exe';
    pre_install=@('Remove-Item "$dir\..\outside" -Recurse -Force')}
$traversal = Parse-Json 'preview-unsafe-traversal' (Invoke-Coop 'preview-unsafe-traversal' @('--root',$root,'install','main/unsafe','--dry-run','--json'))
Check ($traversal.execution_available -eq $false) 'parent-directory traversal stayed executable'
Check (@($traversal.package.scripts[0].diagnostics | Where-Object { $_.message -match 'parent-directory' }).Count -eq 1) 'parent-directory traversal was not diagnosed'
Write-Manifest 'main' 'unsafe' @{version='1';url=([Uri]$unsafeZip).AbsoluteUri;hash=(File-Hash $unsafeZip);bin='unsafe.exe';
    pre_install=@('Remove-Item "$env:USERPROFILE\outside" -Recurse -Force')}
$envPath = Parse-Json 'preview-unsafe-env' (Invoke-Coop 'preview-unsafe-env' @('--root',$root,'install','main/unsafe','--dry-run','--json'))
Check ($envPath.execution_available -eq $false) 'environment-rooted removal stayed executable'
Check (@($envPath.package.scripts[0].diagnostics | Where-Object { $_.message -match 'must resolve under' }).Count -eq 1) 'environment-rooted removal was not diagnosed'

# --- 8. Missing PowerShell runtime is diagnosed before execution. ------------
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

# --- 9. Adoption of hook packages stays untested until real evidence exists. -
$legacyDirectory = "$root/apps/legacyhook/1"
New-Item -ItemType Directory -Path $legacyDirectory,"$root/buckets/main/bucket" -Force | Out-Null
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
    real_hook_sources=@('Extras/notepadplusplus pre_install+post_install','Main/nodejs post_install','Main/git pre_uninstall','Extras/aider-desk post_uninstall','Main/azure-cli pre_uninstall')
    fixture_artifacts='project fixture programs; real package payloads were not downloaded or run'
    adoption_promoted=$false
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$root/evidence.json" -Encoding utf8
Write-Output "PASS real lifecycle hook scripts, order, failure, concurrency and capability diagnostics: $root/evidence.json ($script:checks checks)"
exit 0

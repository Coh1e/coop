param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$EvidenceDir,
    [string]$Root = 'C:\Users\Neo\scoop')
# Real shared-root evidence for #31: preview real installed hook packages read-only, then run one
# bounded product lifecycle (Coop install/uninstall of Main/rclone, which declares real pre_install
# and uninstaller.script text) and observe Scoop reading the same state. Only the records this run
# creates are removed afterwards; the pre-existing installations and stores are never touched.
$ErrorActionPreference = 'Stop'
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$script:runs = 0
function Write-Text([string]$name,[string]$text) { [IO.File]::WriteAllText((Join-Path $EvidenceDir $name),$text,[Text.UTF8Encoding]::new($false)) }
function Run([string]$label,[string]$file,[string[]]$arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($file)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(900000)) { $process.Kill($true); throw "$label timed out" }
    $process.WaitForExit()
    $result = [pscustomobject]@{
        label=$label; file=$file; arguments=@($arguments); exit=$process.ExitCode
        output=$stdout.GetAwaiter().GetResult(); error=$stderr.GetAwaiter().GetResult()
    }
    $process.Dispose()
    ++$script:runs
    Write-Text ("{0:d2}-{1}.stdout.log" -f $script:runs,$label) $result.output
    Write-Text ("{0:d2}-{1}.stderr.log" -f $script:runs,$label) $result.error
    Write-Text ("{0:d2}-{1}.command.txt" -f $script:runs,$label) (($file+' '+($arguments -join ' ')))
    return $result
}
function Get-Json($result) { return ($result.output | ConvertFrom-Json) }
function Test-Coop([string]$label,[string[]]$arguments) {
    return Run $label $CoopExe (@('--root',$Root)+$arguments)
}
function Assert([bool]$condition,[string]$message) { if (-not $condition) { throw "real-root check failed: $message" } }
$pwshPath = (Get-Process -Id $PID).Path
function Run-Scoop([string]$label,[string[]]$arguments) {
    return Run $label $pwshPath (@('-NoProfile','-NonInteractive','-Command',('scoop '+($arguments -join ' '))))
}
$before = [ordered]@{
    platform = (Get-CimInstance Win32_OperatingSystem).Caption
    ps_version = $PSVersionTable.PSVersion.ToString()
    coop_sha256 = (Get-FileHash -LiteralPath $CoopExe -Algorithm SHA256).Hash.ToLower()
    apps = @(Get-ChildItem "$Root/apps" -Directory | Select-Object -ExpandProperty Name)
    persist = @(Get-ChildItem "$Root/persist" -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    shims = @(Get-ChildItem "$Root/shims" -File | Select-Object -ExpandProperty Name)
    rclone_installed = Test-Path -LiteralPath "$Root/apps/rclone"
    rclone_persist = Test-Path -LiteralPath "$Root/persist/rclone"
    rclone_shim = Test-Path -LiteralPath "$Root/shims/rclone.exe"
    rclone_record = Test-Path -LiteralPath "$Root/.coop/packages/rclone.json"
}
Write-Text '00-before.json' ($before | ConvertTo-Json -Depth 5)
Assert (-not $before.rclone_installed -and -not $before.rclone_persist -and -not $before.rclone_shim -and -not $before.rclone_record) 'rclone state exists before the run; refusing to touch it'
$scoopVersion = Run-Scoop 'scoop-version' @('--version')
Write-Text '00-scoop-list-before.log' (Run-Scoop 'scoop-list-before' @('list')).output
$version = Run 'coop-version' $CoopExe @('--version')
Write-Text '00-versions.txt' ("coop: "+$version.output.Trim()+"`nscoop: "+$scoopVersion.output.Trim())

# 1. Read-only preview of real installed packages whose hook text is now executed by Coop.
$gitInfo = Test-Coop 'git-info' @('info','main/git','--json')
Assert ($gitInfo.exit -eq 0) "git info failed: $($gitInfo.error)"
$gitUpdate = Test-Coop 'git-update-preview' @('update','git','--dry-run','--json')
Assert ($gitUpdate.exit -eq 0) "git update preview failed: $($gitUpdate.error)"
$gitUpdatePlan = Get-Json $gitUpdate
Assert (@($gitUpdatePlan.package.scripts).Count -eq 4) 'installed git update plan did not expose four hook phases'
Assert ($gitUpdatePlan.package.script_support.library_version -match 'v0\.6\.0') 'hook library version missing from real preview'
Assert ($gitUpdatePlan.execution_available -eq $true) "installed git update preview is still blocked: $(@($gitUpdatePlan.diagnostics) | ConvertTo-Json -Compress)"
Assert (@($gitUpdatePlan.operations | Where-Object { $_.kind -eq 'script' }).Count -eq 4) 'git update preview did not list the four hook operations'
Assert (@($gitUpdatePlan.package.scripts | ForEach-Object { $_.phase }) -contains 'post_install') 'git update plan lost the post_install phase'
$sevenUpdate = Test-Coop '7zip-update-preview' @('update','7zip','--dry-run','--json')
Assert ($sevenUpdate.exit -eq 0) "7zip update preview failed: $($sevenUpdate.error)"
$sevenUpdatePlan = Get-Json $sevenUpdate
Assert (@($sevenUpdatePlan.package.scripts).Count -eq 2) 'installed 7zip update plan did not expose its two hook phases'
Assert ($sevenUpdatePlan.execution_available -eq $false) '7zip MSI update stayed executable'
Assert (@($sevenUpdatePlan.diagnostics | Where-Object { $_.code -eq 'execution-blocked' -and $_.message -match 'machine cache' }).Count -eq 1) '7zip MSI limitation is not reported'

# 2. The bounded real lifecycle: Main/rclone declares real pre_install and uninstaller.script.
$rcloneManifest = Get-Content -LiteralPath "$Root/buckets/main/bucket/rclone.json" -Raw | ConvertFrom-Json
Write-Text '01-rclone-hooks.json' (@{pre_install=$rcloneManifest.pre_install;uninstaller=$rcloneManifest.uninstaller} | ConvertTo-Json -Depth 8)
$rclonePreview = Test-Coop 'rclone-install-preview' @('install','main/rclone','--dry-run','--json')
Assert ($rclonePreview.exit -eq 0) "rclone install preview failed: $($rclonePreview.error)"
$rclonePlan = Get-Json $rclonePreview
Assert ($rclonePlan.execution_available -eq $true) "rclone install preview is blocked: $(@($rclonePlan.diagnostics) | ConvertTo-Json -Compress)"
Assert (@($rclonePlan.package.scripts | ForEach-Object { $_.phase }) -contains 'pre_install') 'rclone preview did not list the real pre_install hook'
Assert ($rclonePlan.package.script_support.library_version -match 'v0\.6\.0') 'rclone preview did not pin the hook library'
Write-Text '02-rclone-plan.json' ($rclonePlan | ConvertTo-Json -Depth 8)
$rcloneInstall = Test-Coop 'rclone-install' @('install','main/rclone','--json')
Assert ($rcloneInstall.exit -eq 0) "real rclone install failed: $($rcloneInstall.error)"
$rcloneInstallResult = Get-Json $rcloneInstall
Write-Text '03-rclone-install-result.json' ($rcloneInstallResult | ConvertTo-Json -Depth 8)
$preInstall = @($rcloneInstallResult.scripts | Where-Object { $_.phase -eq 'pre_install' })
Assert ($preInstall.Count -eq 1 -and $preInstall[0].exit_code -eq 0) 'real rclone pre_install did not run'
Assert ($preInstall[0].context.scoopdir -eq $Root) 'rclone hook session did not bind the real shared root'
Assert ($preInstall[0].scoop_library_version -match 'v0\.6\.0') 'rclone hook did not use the pinned Scoop library'
Assert (Test-Path -LiteralPath "$Root/persist/rclone/rclone.conf") 'real pre_install did not create the persisted config'
Assert (Test-Path -LiteralPath "$Root/apps/rclone/current/rclone.exe") 'rclone current was not published'
$rcloneVersion = Run 'rclone-version' "$Root/shims/rclone.exe" @('version')
Assert ($rcloneVersion.exit -eq 0 -and $rcloneVersion.output -match 'rclone v1\.75\.2') "installed rclone program did not run: $($rcloneVersion.error)"
Write-Text '04-rclone-version.txt' $rcloneVersion.output
$scoopList = Run-Scoop 'scoop-list-installed' @('list')
Write-Text '05-scoop-list-installed.log' $scoopList.output
Assert ($scoopList.output -match 'rclone') 'Scoop did not list the Coop-installed rclone'
$coopList = Test-Coop 'coop-list-installed' @('list','--json')
Assert ($coopList.exit -eq 0 -and $coopList.output -match 'rclone') 'Coop did not list the installed rclone'
$configBefore = @{
    exists=(Test-Path -LiteralPath "$Root/persist/rclone/rclone.conf")
    length=(Get-Item -LiteralPath "$Root/persist/rclone/rclone.conf").Length
    sha256=(Get-FileHash -LiteralPath "$Root/persist/rclone/rclone.conf" -Algorithm SHA256).Hash.ToLower()
}
Write-Text '06-rclone-config-before-uninstall.json' ($configBefore | ConvertTo-Json)

# 3. Coop uninstall runs the real uninstaller.script; Scoop must then see rclone gone.
$rcloneUninstallPreview = Test-Coop 'rclone-uninstall-preview' @('uninstall','rclone','--dry-run','--json')
Assert ($rcloneUninstallPreview.exit -eq 0) "rclone uninstall preview failed: $($rcloneUninstallPreview.error)"
$rcloneUninstall = Test-Coop 'rclone-uninstall' @('uninstall','rclone','--json')
Assert ($rcloneUninstall.exit -eq 0) "real rclone uninstall failed: $($rcloneUninstall.error)"
$rcloneUninstallResult = Get-Json $rcloneUninstall
Write-Text '07-rclone-uninstall-result.json' ($rcloneUninstallResult | ConvertTo-Json -Depth 8)
$uninstallerRun = @($rcloneUninstallResult.scripts | Where-Object { $_.phase -eq 'uninstaller' })
Assert ($uninstallerRun.Count -eq 1 -and $uninstallerRun[0].exit_code -eq 0) 'real rclone uninstaller.script did not run'
$configAfter = @{
    exists=(Test-Path -LiteralPath "$Root/persist/rclone/rclone.conf")
    length=(Get-Item -LiteralPath "$Root/persist/rclone/rclone.conf").Length
    sha256=(Get-FileHash -LiteralPath "$Root/persist/rclone/rclone.conf" -Algorithm SHA256).Hash.ToLower()
}
Write-Text '08-rclone-config-after-uninstall.json' ($configAfter | ConvertTo-Json)
Assert ($configAfter.exists -and $configAfter.sha256 -eq $configBefore.sha256) 'normal uninstall did not retain the persisted rclone config'
Assert (-not (Test-Path -LiteralPath "$Root/apps/rclone") -and -not (Test-Path -LiteralPath "$Root/shims/rclone.exe")) 'uninstall left rclone program state'
$scoopListAfter = Run-Scoop 'scoop-list-after' @('list')
Write-Text '09-scoop-list-after.log' $scoopListAfter.output
Assert ($scoopListAfter.output -notmatch 'rclone') 'Scoop still lists rclone after the Coop uninstall'

# 4. Remove only the store this run created, then record the restored environment.
Remove-Item -LiteralPath "$Root/persist/rclone" -Recurse -Force
Write-Text '10-cleanup.txt' 'removed the persist/rclone store created by this run'
$after = [ordered]@{
    apps = @(Get-ChildItem "$Root/apps" -Directory | Select-Object -ExpandProperty Name)
    persist = @(Get-ChildItem "$Root/persist" -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    shims = @(Get-ChildItem "$Root/shims" -File | Select-Object -ExpandProperty Name)
    rclone_installed = Test-Path -LiteralPath "$Root/apps/rclone"
    rclone_persist = Test-Path -LiteralPath "$Root/persist/rclone"
    rclone_shim = Test-Path -LiteralPath "$Root/shims/rclone.exe"
    rclone_record = Test-Path -LiteralPath "$Root/.coop/packages/rclone.json"
    pending_transactions = @(Get-ChildItem "$Root/.coop/transactions" -Directory | Where-Object {
        (Get-Content -LiteralPath "$(Join-Path $_.FullName 'journal.json')" -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json).state -eq 'pending' }).Count
}
Write-Text '11-after.json' ($after | ConvertTo-Json -Depth 5)
Assert (-not $after.rclone_installed -and -not $after.rclone_persist -and -not $after.rclone_shim -and
    -not $after.rclone_record -and $after.pending_transactions -eq 0) 'cleanup did not restore the pre-run rclone state'
Assert (($after.apps -join ',') -eq ($before.apps -join ',')) 'the installed application set changed'
Assert (($after.shims -join ',') -eq ($before.shims -join ',')) 'the shared shim set changed'
Write-Text '12-evidence.txt' ("runs="+$script:runs+"`nroot="+$Root+"`ncoop="+$version.output.Trim()+"`nscoop="+($scoopVersion.output -replace "`r?`n",' / ').Trim())
Write-Output "PASS real shared-root previews and rclone pre_install/uninstaller.script lifecycle: $EvidenceDir"
exit 0

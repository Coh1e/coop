param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$EvidenceDir,
    [string]$Root = 'C:\Users\Neo\scoop')
# Real shared-root evidence for #33: MSI software lifecycle and alternating management.
# Two real Main MSI packages are installed by Coop, removed by Scoop, reinstalled by Scoop and
# removed by Coop, with the produced version directory trees compared between the clients. Coop's
# operations must never start msiexec, request elevation, schedule a reboot or change the Windows
# Installer machine cache; Scoop's own MSI extraction is the other client's behaviour and is
# measured separately. Only state this run creates is removed afterwards; pre-existing
# installations, stores and the read-only 7zip/other packages are never touched.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$guard = Join-Path (Split-Path $CoopExe) 'process_guard.exe'
if (-not (Test-Path -LiteralPath $guard)) { throw "Missing process guard beside coop.exe: $guard" }
$script:runs = 0
function Write-Text([string]$name,[string]$text) { [IO.File]::WriteAllText((Join-Path $EvidenceDir $name),$text,[Text.UTF8Encoding]::new($false)) }
function Run([string]$label,[string]$file,[string[]]$arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($file)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $Root
    foreach ($argument in $arguments) { Add-ProcessArgument $start ($argument) }
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(900000)) { $process.Kill(); throw "$label timed out" }
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
function Test-CoopGuarded([string]$label,[string[]]$arguments) {
    # A real MSI download and extraction can take longer than the guard's default observation
    # window; the timeout only bounds the guard, not the operation.
    $previous = $env:COOP_PROCESS_GUARD_TIMEOUT_MS
    $env:COOP_PROCESS_GUARD_TIMEOUT_MS = '120000'
    try {
        return Run $label $guard (@($CoopExe,'--root',$Root)+$arguments)
    } finally {
        if ($null -eq $previous) { Remove-Item Env:COOP_PROCESS_GUARD_TIMEOUT_MS -ErrorAction SilentlyContinue }
        else { $env:COOP_PROCESS_GUARD_TIMEOUT_MS = $previous }
    }
}
function Assert([bool]$condition,[string]$message) { if (-not $condition) { throw "real-root MSI check failed: $message" } }
$pwshPath = (Get-Process -Id $PID).Path
function Run-Scoop([string]$label,[string[]]$arguments) {
    return Run $label $pwshPath (@('-NoProfile','-NonInteractive','-Command',('scoop '+($arguments -join ' '))))
}
function Get-CoopList([string]$label) {
    $result = Test-Coop $label @('list','--json')
    Assert ($result.exit -eq 0) "$label failed: $($result.error)"
    return @(Get-Json $result)
}
function Get-WindowsInstallerCacheState {
    $directory = Join-Path $env:WINDIR 'Installer'
    if (-not (Test-Path -LiteralPath $directory)) { return @() }
    return @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.ToString('o'))" })
}
function Snapshot([string]$name) {
    $value = [ordered]@{
        apps = @(Get-ChildItem "$Root/apps" -Directory | Select-Object -ExpandProperty Name)
        persist = @(Get-ChildItem "$Root/persist" -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        shims = @(Get-ChildItem "$Root/shims" -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        coop_records = @(Get-ChildItem "$Root/.coop/packages" -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        pending_transactions = @(Get-ChildItem "$Root/.coop/transactions" -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'journal.json') } |
            Where-Object { (Get-Content -LiteralPath (Join-Path $_.FullName 'journal.json') -Raw | ConvertFrom-Json).state -eq 'pending' } |
            Select-Object -ExpandProperty Name)
        installer_cache = @(Get-WindowsInstallerCacheState)
    }
    Write-Text $name ($value | ConvertTo-Json -Depth 5)
    return $value
}
function Get-ImageSnapshot([string]$directory) {
    Assert (Test-Path -LiteralPath $directory) "missing image directory $directory"
    return @(Get-ChildItem -LiteralPath $directory -Recurse -File |
        Where-Object { $_.Name -notin @('scoop-install.json','scoop-manifest.json') } |
        Sort-Object FullName |
        ForEach-Object {
            $relative = $_.FullName.Substring($directory.Length).Replace('\','/')
            $relative+'|'+((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower())
        })
}
function Get-BundleVersion([string]$package) {
    $manifest = Get-Content -LiteralPath "$Root/buckets/main/bucket/$package.json" -Raw | ConvertFrom-Json
    return $manifest.version
}

$scoopVersion = Run-Scoop 'scoop-version' @('--version')
$coopVersion = Run 'coop-version' $CoopExe @('--version')
$mainRevision = Run 'main-bucket-revision' 'git' @('-C',"$Root/buckets/main",'rev-parse','HEAD')
$before = [ordered]@{
    timestamp = [DateTime]::UtcNow.ToString('o')
    platform = (Get-CimInstance Win32_OperatingSystem).Caption
    ps_version = $PSVersionTable.PSVersion.ToString()
    coop_version = $coopVersion.output.Trim()
    coop_sha256 = (([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($CoopExe))) -replace '-','').ToLower())
    scoop_version = ($scoopVersion.output -replace "`r?`n",' / ').Trim()
    main_bucket_revision = $mainRevision.output.Trim()
    kalker_version = Get-BundleVersion 'kalker'
    pkgconf_version = Get-BundleVersion 'pkgconf'
}
Write-Text '00-versions.txt' (($before | ConvertTo-Json -Depth 4))
Write-Text '00-scoop-list-before.log' (Run-Scoop 'scoop-list-before' @('list')).output
$appsBefore = Snapshot '00-snapshot-before.json'
$packageImages = [ordered]@{}
foreach ($package in @('kalker','pkgconf')) {
    Assert (-not (Test-Path -LiteralPath "$Root/apps/$package")) "$package is already installed; refusing to touch it"
    Assert (-not (Test-Path -LiteralPath "$Root/.coop/packages/$package.json")) "$package already has a Coop record; refusing to touch it"
}
Assert (-not (Test-Path -LiteralPath "$Root/shims/kalker.exe") -and -not (Test-Path -LiteralPath "$Root/shims/pkgconf.exe")) 'an expected shim already exists; refusing to touch it'

# 1. Read-only: the installed real MSI package (Main/7zip) is recognized and its update is planned
#    with the read-only extraction facts, without executing anything.
$sevenInfo = Test-Coop '7zip-info' @('info','main/7zip','--json')
Assert ($sevenInfo.exit -eq 0) "7zip info failed: $($sevenInfo.error)"
$sevenUpdate = Test-Coop '7zip-update-preview' @('update','7zip','--dry-run','--json')
Assert ($sevenUpdate.exit -eq 0) "7zip update preview failed: $($sevenUpdate.error)"
$sevenPlan = Get-Json $sevenUpdate
Write-Text '01-7zip-update-plan.json' ($sevenPlan | ConvertTo-Json -Depth 8)
Assert ($sevenPlan.execution_available -eq $true) "installed 7zip MSI update is not executable: $(@($sevenPlan.diagnostics) | ConvertTo-Json -Compress)"
Assert ($sevenPlan.package.msi_extraction.mechanism -match 'read-only Windows Installer database' -and
    $sevenPlan.package.msi_extraction.msiexec_started -eq $false -and
    $sevenPlan.package.msi_extraction.administrative_install -eq $false) '7zip preview does not describe the read-only MSI mechanism'
Assert ($sevenPlan.package.msi_extraction.elevation -match 'not required' -and $sevenPlan.package.msi_extraction.reboot -match 'not required') '7zip preview does not state the permission and reboot facts'
Assert (-not (Test-Path -LiteralPath "$Root/apps/7zip/current/installer-ran.txt")) 'the 7zip preview executed package content'

foreach ($package in @('kalker','pkgconf')) {
    $version = Get-BundleVersion $package
    $app = "$Root/apps/$package"
    $directory = "$app/$version"
    $packageImages[$package] = [ordered]@{version=$version;coop=$null;scoop=$null}

    # 2. Coop installs the real MSI package with the read-only extractor.
    $preview = Test-Coop "$package-coop-install-preview" @('install',"main/$package",'--dry-run','--json')
    Assert ($preview.exit -eq 0) "$package Coop preview failed: $($preview.error)"
    $plan = Get-Json $preview
    Write-Text "02-$package-coop-plan.json" ($plan | ConvertTo-Json -Depth 8)
    Assert ($plan.execution_available -eq $true) "$package Coop preview is blocked: $(@($plan.diagnostics) | ConvertTo-Json -Compress)"
    Assert ($plan.artifacts[0].archive -eq 'msi' -and $plan.artifacts[0].extraction -eq 'read-only-msi-image') "$package is not reported as an MSI artifact"
    Assert ($plan.package.msi_extraction.msiexec_started -eq $false -and $plan.package.msi_extraction.elevation -match 'not required' -and
        $plan.package.msi_extraction.reboot -match 'not required') "$package preview does not state the MSI permission and reboot facts"
    $cacheBeforeCoop = @(Get-WindowsInstallerCacheState)
    $install = Test-CoopGuarded "$package-coop-install" @('install',"main/$package",'--json')
    Assert ($install.exit -eq 0) "$package Coop install failed: $($install.error)"
    Assert ($install.error -match 'Observed workload processes: 1') "$package Coop install started an external process such as msiexec"
    $installResult = Get-Json $install
    Write-Text "03-$package-coop-install.json" ($installResult | ConvertTo-Json -Depth 8)
    $cacheAfterCoop = @(Get-WindowsInstallerCacheState)
    Assert (($cacheBeforeCoop -join "`n") -eq ($cacheAfterCoop -join "`n")) "$package Coop install changed the Windows Installer machine cache"
    Assert (Test-Path -LiteralPath $directory) "$package Coop install did not create $directory"
    $coopImage = Get-ImageSnapshot $directory
    $packageImages[$package].coop = $coopImage
    Write-Text "04-$package-coop-image.txt" ($coopImage -join "`n")
    $journal = Get-Content -LiteralPath $installResult.journal -Raw | ConvertFrom-Json
    Write-Text "05-$package-coop-journal.json" ($journal | ConvertTo-Json -Depth 8)
    Assert ($journal.state -eq 'committed') "$package Coop journal is not committed"
    $record = @($journal.msi_extractions)[0]
    Assert ($record.database_access -eq 'read-only' -and $record.msiexec_started -eq $false -and $record.administrative_install -eq $false) "$package Coop journal does not record the read-only extraction"
    Assert ($record.files -gt 0 -and $record.bytes -gt 0) "$package Coop journal does not record the extracted files"
    $listed = Get-CoopList "$package-coop-list"
    Assert (@($listed | Where-Object { $_.name -eq $package }).Count -eq 1) "Coop list does not show its $package installation"
    $scoopList = Run-Scoop "$package-scoop-list-after-coop" @('list')
    Assert ($scoopList.output -match ("(?m)^"+[regex]::Escape($package)+"\s+")) "Scoop does not list the Coop-installed $package"

    # 3. The other client removes the Coop installation, then installs it again.
    $scoopUninstall = Run-Scoop "$package-scoop-uninstall" @('uninstall',$package)
    Assert ($scoopUninstall.exit -eq 0) "Scoop could not uninstall the Coop-installed $package`: $($scoopUninstall.error)"
    Assert (-not (Test-Path -LiteralPath $app)) "$package survived the Scoop uninstall"
    $listedAfter = Get-CoopList "$package-coop-list-after-scoop-uninstall"
    Assert (@($listedAfter | Where-Object { $_.name -eq $package }).Count -eq 0) "Coop still lists $package after Scoop removed it"
    $scoopInstall = Run-Scoop "$package-scoop-install" @('install',$package)
    Assert ($scoopInstall.exit -eq 0) "Scoop could not install $package`: $($scoopInstall.error)"
    Assert (Test-Path -LiteralPath $directory) "$package Scoop install did not create $directory"
    $scoopImage = Get-ImageSnapshot $directory
    $packageImages[$package].scoop = $scoopImage
    Write-Text "06-$package-scoop-image.txt" ($scoopImage -join "`n")
    Assert (($scoopImage -join "`n") -eq ($coopImage -join "`n")) "$package Coop and Scoop produced different version directory contents"
    $info = Test-Coop "$package-coop-info" @('info',"main/$package",'--json')
    Assert ($info.exit -eq 0) "$package Coop info failed: $($info.error)"
    Write-Text "07-$package-coop-info.json" $info.output
    $uninstallPreview = Test-Coop "$package-coop-uninstall-preview" @('uninstall',$package,'--dry-run','--json')
    Assert ($uninstallPreview.exit -eq 0) "$package Coop uninstall preview failed: $($uninstallPreview.error)"
    Assert ((Get-Json $uninstallPreview).execution_available -eq $true) "$package Coop uninstall preview is not executable"

    # 4. Coop removes the Scoop installation without a takeover step.
    $cacheBeforeCoopUninstall = @(Get-WindowsInstallerCacheState)
    $uninstall = Test-CoopGuarded "$package-coop-uninstall" @('uninstall',$package,'--json')
    Assert ($uninstall.exit -eq 0) "$package Coop uninstall failed: $($uninstall.error)"
    Assert ($uninstall.error -match 'Observed workload processes: 1') "$package Coop uninstall started an external process"
    $cacheAfterCoopUninstall = @(Get-WindowsInstallerCacheState)
    Assert (($cacheBeforeCoopUninstall -join "`n") -eq ($cacheAfterCoopUninstall -join "`n")) "$package Coop uninstall changed the Windows Installer machine cache"
    Assert (-not (Test-Path -LiteralPath $app)) "$package Coop uninstall left the application directory"
    Assert (-not (Test-Path -LiteralPath "$Root/shims/$package.exe")) "$package Coop uninstall left its main command entry"
    $finalList = Get-CoopList "$package-coop-list-final"
    Assert (@($finalList | Where-Object { $_.name -eq $package }).Count -eq 0) "Coop still lists $package after its uninstall"
    $scoopListFinal = Run-Scoop "$package-scoop-list-final" @('list')
    Assert ($scoopListFinal.output -notmatch ("(?m)^"+[regex]::Escape($package)+"\s+")) "Scoop still lists $package after the Coop uninstall"
}

# 5. Final state matches the pre-run state apart from the shared download cache.
$after = Snapshot '99-snapshot-after.json'
Assert ((($after.apps -join ',') -eq ($appsBefore.apps -join ','))) 'the apps directory list changed after the run'
Assert ((($after.persist -join ',') -eq ($appsBefore.persist -join ','))) 'the persist directory list changed after the run'
Assert ((($after.shims -join ',') -eq ($appsBefore.shims -join ','))) 'the shims directory list changed after the run'
Assert ((($after.coop_records -join ',') -eq ($appsBefore.coop_records -join ','))) 'Coop records changed after the run'
Assert (@($after.pending_transactions).Count -eq 0) 'the run left a pending transaction'
$cacheBeforeCoopOnly = @($appsBefore.installer_cache)
$cacheAfterRun = @($after.installer_cache)
foreach ($package in @('kalker','pkgconf')) {
    $version = Get-BundleVersion $package
    Assert (@($packageImages[$package].coop).Count -gt 0 -and @($packageImages[$package].scoop).Count -gt 0) "$package has no compared images"
}
$coopImage = $null
$scoopImage = $null
Write-Text '99-summary.json' ([ordered]@{
    coop_sha256 = $before.coop_sha256
    scoop_version = $before.scoop_version
    main_bucket_revision = $before.main_bucket_revision
    packages = @($packageImages.Keys | ForEach-Object { [ordered]@{name=$_;version=$packageImages[$_].version;images_identical=(($packageImages[$_].coop -join "`n") -eq ($packageImages[$_].scoop -join "`n"));image_files=@($packageImages[$_].coop).Count} })
    windows_installer_cache = [ordered]@{
        before=$cacheBeforeCoopOnly.Count
        after=$cacheAfterRun.Count
        coop_operations_unchanged=$true
        scoop_installs_may_change_it=$true
    }
    final_state_matches_before = $true
} | ConvertTo-Json -Depth 6)
Write-Output "PASS real MSI lifecycle: Coop install/uninstall and Scoop alternation for kalker and pkgconf, identical version directory contents, no Coop msiexec/elevation/reboot/machine-cache effect"

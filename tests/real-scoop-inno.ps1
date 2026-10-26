param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$EvidenceDir,
    [string]$Root = 'C:\Users\Neo\scoop')
# Real shared-root evidence for #34: Inno Setup software lifecycle and alternating management.
# Main/units 2.27 is a real Inno Setup package. Coop unpacks it with the innounp helper that is
# already installed in this root (the same helper Scoop's Expand-InnoArchive uses), Scoop removes
# and reinstalls it, and Coop removes the Scoop installation. The version directory trees produced
# by both clients are compared file by file. Only state this run creates is removed afterwards;
# pre-existing installations and the helper package are never touched.
$ErrorActionPreference = 'Stop'
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
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
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
function Test-Coop([string]$label,[string[]]$arguments) { return Run $label $CoopExe (@('--root',$Root)+$arguments) }
function Test-CoopGuarded([string]$label,[string[]]$arguments,[bool]$allowHelper = $true) {
    $previousTimeout = $env:COOP_PROCESS_GUARD_TIMEOUT_MS
    $previousChildren = $env:COOP_PROCESS_GUARD_ALLOW_CHILDREN
    $env:COOP_PROCESS_GUARD_TIMEOUT_MS = '120000'
    if ($allowHelper) { $env:COOP_PROCESS_GUARD_ALLOW_CHILDREN = '1' }
    try { return Run $label $guard (@($CoopExe,'--root',$Root)+$arguments) }
    finally {
        if ($null -eq $previousTimeout) { Remove-Item Env:COOP_PROCESS_GUARD_TIMEOUT_MS -ErrorAction SilentlyContinue }
        else { $env:COOP_PROCESS_GUARD_TIMEOUT_MS = $previousTimeout }
        if ($null -eq $previousChildren) { Remove-Item Env:COOP_PROCESS_GUARD_ALLOW_CHILDREN -ErrorAction SilentlyContinue }
        else { $env:COOP_PROCESS_GUARD_ALLOW_CHILDREN = $previousChildren }
    }
}
function Assert([bool]$condition,[string]$message) { if (-not $condition) { throw "real-root Inno check failed: $message" } }
function Workload-Processes($result) {
    $items = @([regex]::Matches($result.error,'Workload process: (.+)') | ForEach-Object { $_.Groups[1].Value.Trim() })
    return ,$items
}
$pwshPath = (Get-Process -Id $PID).Path
function Run-Scoop([string]$label,[string[]]$arguments) {
    return Run $label $pwshPath (@('-NoProfile','-NonInteractive','-Command',('scoop '+($arguments -join ' '))))
}
function Get-CoopList([string]$label) {
    $result = Test-Coop $label @('list','--json')
    Assert ($result.exit -eq 0) "$label failed: $($result.error)"
    return @(Get-Json $result)
}
function File-Hash([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function Same-Path([string]$a,[string]$b) { return [IO.Path]::GetFullPath($a) -eq [IO.Path]::GetFullPath($b) }
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
        helper = @(Get-ChildItem "$Root/apps/innounp" -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName |
            ForEach-Object { $_.FullName.Substring($Root.Length).Replace('\','/')+'|'+(File-Hash $_.FullName) })
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
$helperExecutable = [IO.Path]::GetFullPath("$Root/apps/innounp/current/innounp.exe")
Assert (Test-Path -LiteralPath $helperExecutable) "the real root has no innounp helper: $helperExecutable"
$before = [ordered]@{
    timestamp = [DateTime]::UtcNow.ToString('o')
    platform = (Get-CimInstance Win32_OperatingSystem).Caption
    ps_version = $PSVersionTable.PSVersion.ToString()
    coop_version = $coopVersion.output.Trim()
    coop_sha256 = (File-Hash $CoopExe)
    scoop_version = ($scoopVersion.output -replace "`r?`n",' / ').Trim()
    main_bucket_revision = $mainRevision.output.Trim()
    package = 'units'
    package_version = Get-BundleVersion 'units'
    helper = $helperExecutable
    helper_sha256 = (File-Hash $helperExecutable)
}
Write-Text '00-versions.txt' (($before | ConvertTo-Json -Depth 4))
Write-Text '00-scoop-list-before.log' (Run-Scoop 'scoop-list-before' @('list')).output
$appsBefore = Snapshot '00-snapshot-before.json'
$version = Get-BundleVersion 'units'
$app = "$Root/apps/units"
$directory = "$app/$version"
Assert (-not (Test-Path -LiteralPath $app)) 'units is already installed; refusing to touch it'
Assert (-not (Test-Path -LiteralPath "$Root/.coop/packages/units.json")) 'units already has a Coop record; refusing to touch it'
Assert (-not (Test-Path -LiteralPath "$Root/shims/units.exe")) 'units already has a command entry; refusing to touch it'

# 1. Read-only: the real Inno Setup package is planned with its declared helper, without writes.
$preview = Test-CoopGuarded 'units-install-preview' @('install','main/units','--dry-run','--json') $false
Assert ($preview.exit -eq 0) "units Coop preview failed: $($preview.error)"
Assert ($preview.error -match 'Observed workload processes: 1') "units preview started an external process: $($preview.error)"
$plan = Get-Json $preview
Write-Text '01-units-coop-plan.json' ($plan | ConvertTo-Json -Depth 8)
Assert ($plan.execution_available -eq $true) "units preview is blocked: $(@($plan.diagnostics) | ConvertTo-Json -Compress)"
Assert ($plan.artifacts[0].archive -eq 'inno-setup' -and $plan.artifacts[0].extraction -eq 'external-innounp' -and
    $plan.artifacts[0].inno_selection -eq '-c{app}') 'units is not reported as an Inno Setup artifact'
Assert ($plan.artifacts[0].requires_elevation -eq $false -and $plan.artifacts[0].reboot_required -eq $false -and
    $plan.artifacts[0].vendor_installer_executed -eq $false) 'units preview does not state the vendor-installer boundary'
Assert ((Same-Path $plan.package.inno_setup.helper $helperExecutable) -and $plan.package.inno_setup.helper_available -eq $true) 'units preview does not name the installed innounp helper'
Assert ($plan.package.inno_setup.installer_executed -eq $false -and $plan.package.inno_setup.helper_policy -match 'never downloads') 'units preview does not state the helper policy'
Assert (@($plan.external_tools | Where-Object { $_.name -match '^innounp' -and $_.available -eq $true -and (Same-Path $_.path $helperExecutable) }).Count -eq 1) 'units preview does not disclose the helper as an external tool'
Assert (@($plan.capabilities | Where-Object { $_.id -eq 'inno-setup' -and $_.supported -eq $true }).Count -eq 1) 'inno-setup capability is not reported'
Assert (-not (Test-Path -LiteralPath $app) -and -not (Test-Path -LiteralPath "$Root/.coop/transactions/units")) 'the preview wrote installation state'
$helperBefore = @(Get-ChildItem "$Root/apps/innounp" -Recurse -File | Sort-Object FullName | ForEach-Object { $_.FullName+'|'+(File-Hash $_.FullName) })

# 2. Coop installs the real Inno Setup package with the declared helper.
$install = Test-CoopGuarded 'units-coop-install' @('install','main/units','--json')
Assert ($install.exit -eq 0) "units Coop install failed: $($install.error)"
$workload = Workload-Processes $install
Assert ($workload.Count -eq 2 -and $workload[0] -match 'coop\.exe$' -and $workload[1] -match 'innounp\.exe$') "units Coop install did not start exactly coop and innounp: $($workload -join '; ')"
Assert (-not ($workload -match '(?i)msiexec|setup\.exe')) "a vendor installer process was started: $($workload -join '; ')"
$installResult = Get-Json $install
Write-Text '02-units-coop-install.json' ($installResult | ConvertTo-Json -Depth 8)
Assert (Test-Path -LiteralPath $directory) "units Coop install did not create $directory"
Assert (Test-Path -LiteralPath "$directory/units.exe") 'units Coop install did not publish the extracted program'
Assert (-not (Test-Path -LiteralPath "$directory/$($before.package_version)-setup.exe")) 'the vendor installer was copied into the version directory'
$coopImage = Get-ImageSnapshot $directory
Write-Text '03-units-coop-image.txt' ($coopImage -join "`n")
$journal = Get-Content -LiteralPath $installResult.journal -Raw | ConvertFrom-Json
Write-Text '04-units-coop-journal.json' ($journal | ConvertTo-Json -Depth 8)
Assert ($journal.state -eq 'committed') 'units Coop journal is not committed'
$record = @($journal.inno_extractions)[0]
Assert ((Same-Path $record.helper $helperExecutable) -and $record.exit_code -eq 0 -and $record.installer_executed -eq $false) 'units Coop journal does not record the declared helper extraction'
Assert ($record.selection -eq '-c{app}' -and $record.files -eq 15) "units Coop journal extraction facts are wrong: $($record.selection), $($record.files) files"
$coopProgram = Run 'units-coop-program' "$Root/shims/units.exe" @('--version')
Assert ($coopProgram.exit -eq 0 -and $coopProgram.output -match 'GNU Units version 2\.27') "the Coop-installed program does not run: $($coopProgram.output)"
$listed = Get-CoopList 'units-coop-list'
Assert (@($listed | Where-Object { $_.name -eq 'units' }).Count -eq 1) 'Coop list does not show its units installation'
$scoopList = Run-Scoop 'units-scoop-list-after-coop' @('list')
Assert ($scoopList.output -match '(?m)^units\s+') 'Scoop does not list the Coop-installed units'
Assert ((@(Get-ChildItem "$Root/apps/innounp" -Recurse -File | Sort-Object FullName | ForEach-Object { $_.FullName+'|'+(File-Hash $_.FullName) }) -join "`n") -eq ($helperBefore -join "`n")) 'the Coop install changed the helper package'

# 3. The other client removes the Coop installation, then installs it again.
$scoopUninstall = Run-Scoop 'units-scoop-uninstall' @('uninstall','units')
Assert ($scoopUninstall.exit -eq 0) "Scoop could not uninstall the Coop-installed units: $($scoopUninstall.error)"
Assert (-not (Test-Path -LiteralPath $app)) 'units survived the Scoop uninstall'
$listedAfter = Get-CoopList 'units-coop-list-after-scoop-uninstall'
Assert (@($listedAfter | Where-Object { $_.name -eq 'units' }).Count -eq 0) 'Coop still lists units after Scoop removed it'
$scoopInstall = Run-Scoop 'units-scoop-install' @('install','units')
Assert ($scoopInstall.exit -eq 0) "Scoop could not install units: $($scoopInstall.error)"
Assert (Test-Path -LiteralPath $directory) "units Scoop install did not create $directory"
$scoopImage = Get-ImageSnapshot $directory
Write-Text '05-units-scoop-image.txt' ($scoopImage -join "`n")
Assert (($scoopImage -join "`n") -eq ($coopImage -join "`n")) 'units Coop and Scoop produced different version directory contents'
$scoopProgram = Run 'units-scoop-program' "$Root/shims/units.exe" @('--version')
Assert ($scoopProgram.exit -eq 0 -and $scoopProgram.output -match 'GNU Units version 2\.27') "the Scoop-installed program does not run: $($scoopProgram.output)"
$info = Test-Coop 'units-coop-info' @('info','main/units','--json')
Assert ($info.exit -eq 0) "units Coop info failed: $($info.error)"
Write-Text '06-units-coop-info.json' $info.output
$uninstallPreview = Test-Coop 'units-coop-uninstall-preview' @('uninstall','units','--dry-run','--json')
Assert ($uninstallPreview.exit -eq 0) "units Coop uninstall preview failed: $($uninstallPreview.error)"
Assert ((Get-Json $uninstallPreview).execution_available -eq $true) 'units Coop uninstall preview is not executable'

# 4. Coop removes the Scoop installation without a takeover step.
$uninstall = Test-CoopGuarded 'units-coop-uninstall' @('uninstall','units','--json') $false
Assert ($uninstall.exit -eq 0) "units Coop uninstall failed: $($uninstall.error)"
$uninstallWorkload = Workload-Processes $uninstall
Assert ($uninstallWorkload.Count -eq 1 -and $uninstallWorkload[0] -match 'coop\.exe$') "units Coop uninstall started an external process: $($uninstallWorkload -join '; ')"
Assert (-not (Test-Path -LiteralPath $app)) 'units Coop uninstall left the application directory'
Assert (-not (Test-Path -LiteralPath "$Root/shims/units.exe")) 'units Coop uninstall left its command entry'
$finalList = Get-CoopList 'units-coop-list-final'
Assert (@($finalList | Where-Object { $_.name -eq 'units' }).Count -eq 0) 'Coop still lists units after its uninstall'
$scoopListFinal = Run-Scoop 'units-scoop-list-final' @('list')
Assert ($scoopListFinal.output -notmatch '(?m)^units\s+') 'Scoop still lists units after the Coop uninstall'

# 5. Final state matches the pre-run state; the helper package is unchanged.
$after = Snapshot '99-snapshot-after.json'
Assert ((($after.apps -join ',') -eq ($appsBefore.apps -join ','))) 'the apps directory list changed after the run'
Assert ((($after.persist -join ',') -eq ($appsBefore.persist -join ','))) 'the persist directory list changed after the run'
Assert ((($after.shims -join ',') -eq ($appsBefore.shims -join ','))) 'the shims directory list changed after the run'
Assert ((($after.coop_records -join ',') -eq ($appsBefore.coop_records -join ','))) 'Coop records changed after the run'
Assert (@($after.pending_transactions).Count -eq 0) 'the run left a pending transaction'
Assert ((($after.helper -join "`n") -eq ($appsBefore.helper -join "`n"))) 'the helper package changed after the run'
Write-Text '99-summary.json' ([ordered]@{
    coop_sha256 = $before.coop_sha256
    scoop_version = $before.scoop_version
    main_bucket_revision = $before.main_bucket_revision
    package = [ordered]@{name='units';version=$version;images_identical=(($coopImage -join "`n") -eq ($scoopImage -join "`n"));image_files=@($coopImage).Count}
    helper = [ordered]@{path=$helperExecutable;sha256=$before.helper_sha256;unchanged=$true}
    coop_install = [ordered]@{selection=$record.selection;files=$record.files;installer_executed=$record.installer_executed;processes=@($workload)}
    final_state_matches_before = $true
} | ConvertTo-Json -Depth 6)
Write-Output "PASS real Inno Setup lifecycle: Coop install/uninstall and Scoop alternation for units $version, identical version directory contents, declared innounp helper, no vendor installer process"

param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$EvidenceDir,
    [string]$Root = 'C:\Users\Neo\scoop')
# Real shared-root evidence for #35: NSIS software lifecycle and alternating management.
# Main/apngasm 3.1.3 is a real NSIS package whose Manifest declares the setup.exe as dl.7z; the
# payload is unpacked by the 7-Zip helper already installed in this root (the same helper Scoop's
# Expand-7zipArchive uses), Scoop removes and reinstalls it, and Coop removes the Scoop
# installation. The version directory trees produced by both clients are compared file by file.
# Only state this run creates is removed afterwards; pre-existing installations and the helper
# package are never touched.
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
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
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
function Test-Coop([string]$label,[string[]]$arguments) { return Run $label $CoopExe (@('--root',$Root)+$arguments) }
function Test-CoopGuarded([string]$label,[string[]]$arguments) {
    $previousTimeout = $env:COOP_PROCESS_GUARD_TIMEOUT_MS
    $previousChildren = $env:COOP_PROCESS_GUARD_ALLOW_CHILDREN
    $env:COOP_PROCESS_GUARD_TIMEOUT_MS = '120000'
    $env:COOP_PROCESS_GUARD_ALLOW_CHILDREN = '1'
    try { return Run $label $guard (@($CoopExe,'--root',$Root)+$arguments) }
    finally {
        if ($null -eq $previousTimeout) { Remove-Item Env:COOP_PROCESS_GUARD_TIMEOUT_MS -ErrorAction SilentlyContinue }
        else { $env:COOP_PROCESS_GUARD_TIMEOUT_MS = $previousTimeout }
        if ($null -eq $previousChildren) { Remove-Item Env:COOP_PROCESS_GUARD_ALLOW_CHILDREN -ErrorAction SilentlyContinue }
        else { $env:COOP_PROCESS_GUARD_ALLOW_CHILDREN = $previousChildren }
    }
}
function Assert([bool]$condition,[string]$message) { if (-not $condition) { throw "real-root NSIS check failed: $message" } }
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
    $helperDirectory = [IO.Path]::GetFullPath([string](Get-Item -LiteralPath "$Root/apps/7zip/current").Target)
    $value = [ordered]@{
        apps = @(Get-ChildItem "$Root/apps" -Directory | Select-Object -ExpandProperty Name)
        persist = @(Get-ChildItem "$Root/persist" -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        shims = @(Get-ChildItem "$Root/shims" -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        coop_records = @(Get-ChildItem "$Root/.coop/packages" -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        pending_transactions = @(Get-ChildItem "$Root/.coop/transactions" -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'journal.json') } |
            Where-Object { (Get-Content -LiteralPath (Join-Path $_.FullName 'journal.json') -Raw | ConvertFrom-Json).state -eq 'pending' } |
            Select-Object -ExpandProperty Name)
        helper_directory = $helperDirectory
        helper_current_target = [IO.Path]::GetFullPath([string](Get-Item -LiteralPath "$Root/apps/7zip/current").Target)
        helper = @(Get-ChildItem $helperDirectory -Recurse -File | Sort-Object FullName |
            ForEach-Object { $_.FullName.Substring($helperDirectory.Length).Replace('\','/')+'|'+(File-Hash $_.FullName) })
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
$helperExecutable = [IO.Path]::GetFullPath("$Root/apps/7zip/current/7z.exe")
Assert (Test-Path -LiteralPath $helperExecutable) "the real root has no 7-Zip helper: $helperExecutable"
$helperVersionRun = Run 'helper-version' $helperExecutable @()
$helperVersion = (($helperVersionRun.output -split "`r?`n")[0]).Trim()
$before = [ordered]@{
    timestamp = [DateTime]::UtcNow.ToString('o')
    platform = (Get-CimInstance Win32_OperatingSystem).Caption
    ps_version = $PSVersionTable.PSVersion.ToString()
    coop_version = $coopVersion.output.Trim()
    coop_sha256 = (File-Hash $CoopExe)
    scoop_version = ($scoopVersion.output -replace "`r?`n",' / ').Trim()
    main_bucket_revision = $mainRevision.output.Trim()
    package = 'apngasm'
    package_version = Get-BundleVersion 'apngasm'
    helper = $helperExecutable
    helper_sha256 = (File-Hash $helperExecutable)
    helper_version = $helperVersion
    planned_actions = @('coop preview (read-only)','coop install','scoop uninstall','scoop install','coop uninstall')
}
Write-Text '00-versions.txt' (($before | ConvertTo-Json -Depth 4))
Write-Text '00-scoop-list-before.log' (Run-Scoop 'scoop-list-before' @('list')).output
$appsBefore = Snapshot '00-snapshot-before.json'
$version = Get-BundleVersion 'apngasm'
$app = "$Root/apps/apngasm"
$directory = "$app/$version"
Assert (-not (Test-Path -LiteralPath $app)) 'apngasm is already installed; refusing to touch it'
Assert (-not (Test-Path -LiteralPath "$Root/.coop/packages/apngasm.json")) 'apngasm already has a Coop record; refusing to touch it'
Assert (-not (Test-Path -LiteralPath "$Root/shims/apngasm.exe")) 'apngasm already has a command entry; refusing to touch it'

# 1. Read-only: the real NSIS package is planned with its declared helper, without writes.
$preview = Test-Coop 'apngasm-install-preview' @('install','main/apngasm','--dry-run','--json')
Assert ($preview.exit -eq 0) "apngasm Coop preview failed: $($preview.error)"
Assert (-not ($preview.error -match 'Workload process:')) "apngasm preview started an external process: $($preview.error)"
$plan = Get-Json $preview
Write-Text '01-apngasm-coop-plan.json' ($plan | ConvertTo-Json -Depth 8)
Assert ($plan.execution_available -eq $true) "apngasm preview is blocked: $(@($plan.diagnostics) | ConvertTo-Json -Compress)"
Assert ($plan.artifacts[0].archive -eq '7z' -and $plan.artifacts[0].extraction -eq 'native-archive-or-external-7zip-nsis') 'apngasm is not reported as an NSIS payload archive'
Assert ($plan.artifacts[0].requires_elevation -eq $false -and $plan.artifacts[0].reboot_required -eq $false -and
    $plan.artifacts[0].vendor_installer_executed -eq $false) 'apngasm preview does not state the vendor-installer boundary'
Assert ((Same-Path $plan.package.nsis_extraction.helper $helperExecutable) -and $plan.package.nsis_extraction.helper_available -eq $true) 'apngasm preview does not name the installed 7-Zip helper'
Assert ($plan.package.nsis_extraction.installer_executed -eq $false -and $plan.package.nsis_extraction.helper_policy -match 'never downloads') 'apngasm preview does not state the helper policy'
Assert (@($plan.external_tools | Where-Object { $_.name -match '^7-Zip' -and $_.available -eq $true -and (Same-Path $_.path $helperExecutable) }).Count -eq 1) 'apngasm preview does not disclose the helper as an external tool'
Assert (@($plan.capabilities | Where-Object { $_.id -eq 'nsis-installer' -and $_.supported -eq $true }).Count -eq 1) 'nsis-installer capability is not reported'
Assert (-not (Test-Path -LiteralPath $app)) 'the preview wrote installation state'

# 2. Coop installs the real NSIS package with the declared helper.
$install = Test-CoopGuarded 'apngasm-coop-install' @('install','main/apngasm','--json')
Assert ($install.exit -eq 0) "apngasm Coop install failed: $($install.error)"
$workload = Workload-Processes $install
Assert ($workload.Count -eq 3 -and $workload[0] -match 'coop\.exe$' -and $workload[1] -match '7z\.exe$' -and $workload[2] -match 'pwsh\.exe$') "apngasm Coop install did not start exactly coop, 7z and the hook host: $($workload -join '; ')"
Assert (-not ($workload -match '(?i)msiexec|setup\.exe|apngasm\.exe$')) "a vendor installer process was started: $($workload -join '; ')"
$installResult = Get-Json $install
Write-Text '02-apngasm-coop-install.json' ($installResult | ConvertTo-Json -Depth 8)
Assert (Test-Path -LiteralPath $directory) "apngasm Coop install did not create $directory"
Assert (Test-Path -LiteralPath "$directory/bin/apngasm.exe") 'apngasm Coop install did not publish the extracted program'
Assert (-not (Test-Path -LiteralPath "$directory/`$PLUGINSDIR")) 'the NSIS $PLUGINSDIR was published instead of being removed by the Manifest hook'
Assert (-not (Test-Path -LiteralPath "$directory/Uninstall.exe")) 'the vendor NSIS Uninstall.exe was published'
$coopImage = Get-ImageSnapshot $directory
Write-Text '03-apngasm-coop-image.txt' ($coopImage -join "`n")
$journal = Get-Content -LiteralPath $installResult.journal -Raw | ConvertFrom-Json
Write-Text '04-apngasm-coop-journal.json' ($journal | ConvertTo-Json -Depth 8)
Assert ($journal.state -eq 'committed') 'apngasm Coop journal is not committed'
$record = @($journal.nsis_extractions)[0]
Assert ((Same-Path $record.helper $helperExecutable) -and $record.exit_code -eq 0 -and $record.installer_executed -eq $false) 'apngasm Coop journal does not record the declared helper extraction'
Assert ($record.detection.signature -match 'NullsoftInst' -and $record.files -eq 16) "apngasm Coop journal extraction facts are wrong: $($record.files) files, detection $($record.detection.offset)"
$coopProgram = Run 'apngasm-coop-program' "$Root/shims/apngasm.exe" @()
Assert ($coopProgram.output -match 'apngasm 3\.1\.3') "the Coop-installed program does not run: $($coopProgram.output)"
$listed = Get-CoopList 'apngasm-coop-list'
Assert (@($listed | Where-Object { $_.name -eq 'apngasm' -and $_.status -eq 'ready' }).Count -eq 1) 'Coop list does not show its apngasm installation'
$scoopList = Run-Scoop 'apngasm-scoop-list-after-coop' @('list')
Assert ($scoopList.output -match '(?m)^apngasm\s+') 'Scoop does not list the Coop-installed apngasm'

# 3. The other client removes the Coop installation, then installs it again.
$scoopUninstall = Run-Scoop 'apngasm-scoop-uninstall' @('uninstall','apngasm')
Assert ($scoopUninstall.exit -eq 0) "Scoop could not uninstall the Coop-installed apngasm: $($scoopUninstall.error)"
Assert (-not (Test-Path -LiteralPath $app)) 'apngasm survived the Scoop uninstall'
$listedAfter = Get-CoopList 'apngasm-coop-list-after-scoop-uninstall'
Assert (@($listedAfter | Where-Object { $_.name -eq 'apngasm' }).Count -eq 0) 'Coop still lists apngasm after Scoop removed it'
$scoopInstall = Run-Scoop 'apngasm-scoop-install' @('install','apngasm')
Assert ($scoopInstall.exit -eq 0) "Scoop could not install apngasm: $($scoopInstall.error)"
Assert (Test-Path -LiteralPath $directory) "apngasm Scoop install did not create $directory"
$scoopImage = Get-ImageSnapshot $directory
Write-Text '05-apngasm-scoop-image.txt' ($scoopImage -join "`n")
Assert (($scoopImage -join "`n") -eq ($coopImage -join "`n")) 'apngasm Coop and Scoop produced different version directory contents'
$scoopProgram = Run 'apngasm-scoop-program' "$Root/shims/apngasm.exe" @()
Assert ($scoopProgram.output -match 'apngasm 3\.1\.3') "the Scoop-installed program does not run: $($scoopProgram.output)"
$info = Test-Coop 'apngasm-coop-info' @('info','main/apngasm','--json')
Assert ($info.exit -eq 0) "apngasm Coop info failed: $($info.error)"
Write-Text '06-apngasm-coop-info.json' $info.output
$uninstallPreview = Test-Coop 'apngasm-coop-uninstall-preview' @('uninstall','apngasm','--dry-run','--json')
Assert ($uninstallPreview.exit -eq 0) "apngasm Coop uninstall preview failed: $($uninstallPreview.error)"
Assert ((Get-Json $uninstallPreview).execution_available -eq $true) 'apngasm Coop uninstall preview is not executable'

# 4. Coop removes the Scoop installation without a takeover step.
$uninstall = Test-CoopGuarded 'apngasm-coop-uninstall' @('uninstall','apngasm','--json')
Assert ($uninstall.exit -eq 0) "apngasm Coop uninstall failed: $($uninstall.error)"
$uninstallWorkload = Workload-Processes $uninstall
Assert ($uninstallWorkload.Count -eq 1 -and $uninstallWorkload[0] -match 'coop\.exe$') "apngasm Coop uninstall started an external process: $($uninstallWorkload -join '; ')"
Assert (-not (Test-Path -LiteralPath $app)) 'apngasm Coop uninstall left the application directory'
Assert (-not (Test-Path -LiteralPath "$Root/shims/apngasm.exe")) 'apngasm Coop uninstall left its command entry'
$finalList = Get-CoopList 'apngasm-coop-list-final'
Assert (@($finalList | Where-Object { $_.name -eq 'apngasm' }).Count -eq 0) 'Coop still lists apngasm after its uninstall'
$scoopListFinal = Run-Scoop 'apngasm-scoop-list-final' @('list')
Assert ($scoopListFinal.output -notmatch '(?m)^apngasm\s+') 'Scoop still lists apngasm after the Coop uninstall'

# 5. Final state matches the pre-run state; the helper package is unchanged.
$after = Snapshot '99-snapshot-after.json'
Assert ((($after.apps -join ',') -eq ($appsBefore.apps -join ','))) 'the apps directory list changed after the run'
Assert ((($after.persist -join ',') -eq ($appsBefore.persist -join ','))) 'the persist directory list changed after the run'
Assert ((($after.shims -join ',') -eq ($appsBefore.shims -join ','))) 'the shims directory list changed after the run'
Assert ((($after.coop_records -join ',') -eq ($appsBefore.coop_records -join ','))) 'Coop records changed after the run'
Assert (@($after.pending_transactions).Count -eq 0) 'the run left a pending transaction'
Assert ((($after.helper -join "`n") -eq ($appsBefore.helper -join "`n"))) 'the helper package changed after the run'
Write-Text '99-summary.json' ([ordered]@{
    checks='all assertions passed'
    runs=$script:runs
    package='apngasm'
    version=$version
    coop_sha256=$before.coop_sha256
    helper_sha256=$before.helper_sha256
    helper_version=$before.helper_version
    coop_image_entries=@($coopImage).Count
    scoop_image_identical=$true
    journal_nsis_files=$record.files
    journal_detection_offset=$record.detection.offset
} | ConvertTo-Json -Depth 4)
Write-Output "PASS real shared-root NSIS alternating lifecycle: $EvidenceDir/99-summary.json"
exit 0

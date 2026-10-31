param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$EvidenceDir,
    [string]$Root = 'C:\Users\Neo\scoop')
# Real shared-root evidence for #32: declare-and-run installer/uninstaller programs.
# Read-only preview of the real Main/vcpkg manifest (the only Main package that combines an
# installer.file declaration with pre_install/post_install/uninstaller scripts) and one bounded real
# product lifecycle of Main/groovyserv, whose real installer.file is bin\setup.bat with keep=true and
# whose bin entries only exist after that program has run. Only state this run creates is removed
# afterwards; pre-existing installations and stores are never touched.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
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
function Assert([bool]$condition,[string]$message) { if (-not $condition) { throw "real-root check failed: $message" } }
$pwshPath = (Get-Process -Id $PID).Path
function Run-Scoop([string]$label,[string[]]$arguments) {
    return Run $label $pwshPath (@('-NoProfile','-NonInteractive','-Command',('scoop '+($arguments -join ' '))))
}
function Test-PortableExecutable([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $stream = [IO.File]::OpenRead($path)
    try {
        if ($stream.Length -lt 2) { return $false }
        return ($stream.ReadByte() -eq 0x4D -and $stream.ReadByte() -eq 0x5A)
    } finally { $stream.Dispose() }
}
function Snapshot([string]$name) {
    $value = [ordered]@{
        apps = @(Get-ChildItem "$Root/apps" -Directory | Select-Object -ExpandProperty Name)
        persist = @(Get-ChildItem "$Root/persist" -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        shims = @(Get-ChildItem "$Root/shims" -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    }
    Write-Text $name ($value | ConvertTo-Json -Depth 5)
    return $value
}

$scoopVersion = Run-Scoop 'scoop-version' @('--version')
$coopVersion = Run 'coop-version' $CoopExe @('--version')
$mainRevision = Run 'main-bucket-revision' 'git' @('-C',"$Root/buckets/main",'rev-parse','HEAD')
Write-Text '00-versions.txt' ("coop: "+$coopVersion.output.Trim()+"`nscoop: "+($scoopVersion.output -replace "`r?`n",' / ').Trim()+
    "`nmain bucket: "+$mainRevision.output.Trim())
$before = [ordered]@{
    platform = (Get-CimInstance Win32_OperatingSystem).Caption
    ps_version = $PSVersionTable.PSVersion.ToString()
    coop_sha256 = (([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($CoopExe))) -replace '-','').ToLower())
    groovyserv_installed = Test-Path -LiteralPath "$Root/apps/groovyserv"
    groovyserv_shim = Test-Path -LiteralPath "$Root/shims/groovyclient.exe"
    groovyserv_record = Test-Path -LiteralPath "$Root/.coop/packages/groovyserv.json"
}
$appsBefore = Snapshot '00-apps-before.json'
Write-Text '00-before.json' ($before | ConvertTo-Json -Depth 5)
Assert (-not $before.groovyserv_installed -and -not $before.groovyserv_shim -and -not $before.groovyserv_record) 'groovyserv state exists before the run; refusing to touch it'
Write-Text '00-scoop-list-before.log' (Run-Scoop 'scoop-list-before' @('list')).output

# 1. Read-only: the real Main/vcpkg declaration combines an installer program with multiple stages.
$vcpkgPreview = Test-Coop 'vcpkg-install-preview' @('install','main/vcpkg','--dry-run','--json')
Assert ($vcpkgPreview.exit -eq 0) "vcpkg preview failed: $($vcpkgPreview.error)"
$vcpkgPlan = Get-Json $vcpkgPreview
Write-Text '01-vcpkg-plan.json' ($vcpkgPlan | ConvertTo-Json -Depth 8)
Assert ($vcpkgPlan.execution_available -eq $true) "real vcpkg preview is blocked: $(@($vcpkgPlan.diagnostics) | ConvertTo-Json -Compress)"
Assert ($vcpkgPlan.package.installer.file -eq 'bootstrap-vcpkg.bat' -and
    (@($vcpkgPlan.package.installer.arguments) -join ' ') -eq '-disableMetrics' -and
    $vcpkgPlan.package.installer.keep -eq $true) 'real vcpkg installer program declaration was not reported'
Assert ((@($vcpkgPlan.package.scripts | ForEach-Object { $_.phase }) -join ',') -eq 'pre_install,post_install,uninstaller') 'real vcpkg multi-stage scripts were not reported'
$vcpkgOperations = @($vcpkgPlan.ir_operations | ForEach-Object { $_.operation })
Assert (($vcpkgOperations -join ',') -eq 'download,verify,extract,hook,installer,publish-current,entries,environment,persistence,hook,commit-state') "real vcpkg operation order is wrong: $($vcpkgOperations -join ',')"
Assert ((@($vcpkgPlan.capabilities | Where-Object { $_.id -eq 'installer-process' })[0].supported) -eq $true) 'real vcpkg installer program is not executable'
Assert ($vcpkgPlan.package.installer.side_effects -match 'rolled back' -and $vcpkgPlan.package.installer.side_effects -match 'never re-run') 'real vcpkg preview does not state the external side-effect limit'
Assert (-not (Test-Path -LiteralPath "$Root/apps/vcpkg")) 'the vcpkg preview created installation state'

# 2. Read-only: the real Main/groovyserv installer program is a batch file that must run.
$groovyManifest = Run 'groovyserv-manifest' $pwshPath @('-NoProfile','-NonInteractive','-Command',
    "Get-Content -Raw -LiteralPath '$Root/buckets/main/bucket/groovyserv.json'")
Write-Text '02-groovyserv-manifest.json' $groovyManifest.output
$groovyPreview = Test-Coop 'groovyserv-install-preview' @('install','main/groovyserv','--dry-run','--json')
Assert ($groovyPreview.exit -eq 0) "groovyserv preview failed: $($groovyPreview.error)"
$groovyPlan = Get-Json $groovyPreview
Write-Text '03-groovyserv-plan.json' ($groovyPlan | ConvertTo-Json -Depth 8)
Assert ($groovyPlan.execution_available -eq $true) "real groovyserv preview is blocked: $(@($groovyPlan.diagnostics) | ConvertTo-Json -Compress)"
Assert ($groovyPlan.package.installer.file -eq 'bin\setup.bat' -and $groovyPlan.package.installer.keep -eq $true -and
    @($groovyPlan.package.installer.arguments).Count -eq 0) 'real groovyserv installer declaration was not reported'
Assert ((@($groovyPlan.ir_operations | ForEach-Object { $_.operation }) -join ',') -eq
    'download,verify,extract,installer,publish-current,entries,commit-state') 'real groovyserv plan does not place the installer program before current and entries'
Assert (@($groovyPlan.package.commands).Count -eq 2 -and
    (@($groovyPlan.package.commands | ForEach-Object { $_.target }) -join ',') -eq 'bin\groovyclient.exe,bin\groovyserver.exe') 'real groovyserv entry targets are not the files the installer program produces'

# 3. Bounded real lifecycle: install, observe the program effect, Scoop reads the installation.
$groovyInstall = Test-Coop 'groovyserv-install' @('install','main/groovyserv','--json')
Assert ($groovyInstall.exit -eq 0) "real groovyserv install failed: $($groovyInstall.error)"
$groovyInstallResult = Get-Json $groovyInstall
Write-Text '04-groovyserv-install-result.json' ($groovyInstallResult | ConvertTo-Json -Depth 8)
$programRuns = @($groovyInstallResult.installers)
Assert ($programRuns.Count -eq 1 -and $programRuns[0].phase -eq 'installer' -and $programRuns[0].exit_code -eq 0) 'real groovyserv installer program did not run successfully'
Assert ($programRuns[0].declared_file -eq 'bin\setup.bat' -and $programRuns[0].keep -eq $true) 'real groovyserv installer program record is wrong'
Assert ([IO.Path]::GetFullPath($programRuns[0].directory) -eq
    [IO.Path]::GetFullPath("$Root/apps/groovyserv/$($groovyPlan.package.version)")) 'real installer program did not run at the version directory'
Assert ($programRuns[0].scoop_library_version -match 'v0\.6\.0' -and $programRuns[0].scoop_library -match 'scoop-lib') 'real installer program did not use the pinned Scoop library'
$programStdout = Run 'groovyserv-program-output' $pwshPath @('-NoProfile','-NonInteractive','-Command',
    "Get-Content -Raw -LiteralPath '$($programRuns[0].stdout_log)'")
Write-Text '05-groovyserv-program-stdout.log' $programStdout.output
Assert ($programStdout.output -match 'Setup completed successfully for windows_386') 'the real setup.bat program did not report completion in its captured output'
# The manifest's own program copies the platform binaries into bin\ and then deletes its dummy
# launchers in the background, so the observed state is the produced executable rather than setup.bat.
Assert (Test-PortableExecutable "$Root/apps/groovyserv/current/bin/groovyclient.exe") 'the real installer program did not produce the groovyclient executable'
Assert (Test-PortableExecutable "$Root/apps/groovyserv/current/bin/groovyserver.exe") 'the real installer program did not produce the groovyserver executable'
Assert (Test-PortableExecutable "$Root/shims/groovyclient.exe") 'the command entry for the produced executable is missing'
$shimTarget = (Get-Item -LiteralPath "$Root/shims/groovyclient.exe").LinkTarget
Write-Text '06-groovyserv-shim.txt' ("linktarget="+$shimTarget)
$scoopList = Run-Scoop 'scoop-list-installed' @('list')
Write-Text '07-scoop-list-installed.log' $scoopList.output
Assert ($scoopList.output -match 'groovyserv') 'Scoop did not list the Coop-installed groovyserv'
$coopList = Test-Coop 'coop-list-installed' @('list','--json')
Assert ($coopList.exit -eq 0 -and $coopList.output -match 'groovyserv') 'Coop did not list the installed groovyserv'
$journal = Run 'groovyserv-journal' $pwshPath @('-NoProfile','-NonInteractive','-Command',
    "Get-Content -Raw -LiteralPath '$($groovyInstallResult.journal)'")
$journalObject = $journal.output | ConvertFrom-Json
Write-Text '08-groovyserv-journal.json' $journal.output
Assert ($journalObject.state -eq 'committed' -and @($journalObject.installers).Count -eq 1 -and
    @($journalObject.installers)[0].exit_code -eq 0) 'real installer program journal is inaccurate'
$observed = @($journalObject.observed_steps | ForEach-Object { $_ })
$installerIndex = [array]::IndexOf($observed,'installer')
$currentIndex = [array]::IndexOf($observed,'publish-current')
$entriesIndex = [array]::IndexOf($observed,'entries')
Assert ($installerIndex -ge 0 -and $currentIndex -gt $installerIndex -and $entriesIndex -gt $currentIndex) "journal does not place the installer program before current and entries: $($observed -join ',')"

# 4. Coop uninstall removes the installation; Scoop then sees it gone. No persist data is declared.
$groovyUninstall = Test-Coop 'groovyserv-uninstall' @('uninstall','groovyserv','--json')
Assert ($groovyUninstall.exit -eq 0) "real groovyserv uninstall failed: $($groovyUninstall.error)"
$groovyUninstallResult = Get-Json $groovyUninstall
Write-Text '09-groovyserv-uninstall-result.json' ($groovyUninstallResult | ConvertTo-Json -Depth 8)
Assert (@($groovyUninstallResult.installers).Count -eq 0) 'uninstall ran an installer program for a package that declares none'
$scoopListAfter = Run-Scoop 'scoop-list-after' @('list')
Write-Text '10-scoop-list-after.log' $scoopListAfter.output
Assert ($scoopListAfter.output -notmatch 'groovyserv') 'Scoop still lists groovyserv after the Coop uninstall'
Assert (-not (Test-Path -LiteralPath "$Root/apps/groovyserv") -and
    -not (Test-Path -LiteralPath "$Root/shims/groovyclient.exe") -and
    -not (Test-Path -LiteralPath "$Root/.coop/packages/groovyserv.json")) 'uninstall left groovyserv program state'

# 5. Restore comparison: only this run's state may differ.
$appsAfter = Snapshot '11-apps-after.json'
$pending = @(Get-ChildItem "$Root/.coop/transactions" -Directory -ErrorAction SilentlyContinue | Where-Object {
    (Get-Content -LiteralPath "$(Join-Path $_.FullName 'journal.json')" -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json).state -eq 'pending' }).Count
Write-Text '11-pending-transactions.txt' ("pending="+$pending)
Assert ($pending -eq 0) 'a pending transaction was left behind'
Assert (($appsAfter.apps -join ',') -eq ($appsBefore.apps -join ',')) 'the installed application set changed'
Assert (($appsAfter.shims -join ',') -eq ($appsBefore.shims -join ',')) 'the shared shim set changed'
Assert (($appsAfter.persist -join ',') -eq ($appsBefore.persist -join ',')) 'the persist store set changed'
Write-Text '12-evidence.txt' ("runs="+$script:runs+"`nroot="+$Root+"`ncoop="+$coopVersion.output.Trim()+
    "`nscoop="+($scoopVersion.output -replace "`r?`n",' / ').Trim()+
    "`nreal installer program: Main/groovyserv bin\setup.bat (keep=true), executed in the shared root"+
    "`nread-only combined declaration: Main/vcpkg bootstrap-vcpkg.bat + pre_install/post_install/uninstaller scripts"+
    "`nnot run on the shared root: Main/vcpkg (its own pre_install fetches the complete vcpkg repository into persist and its post_install writes user MSBuild integration)")
Write-Output "PASS real shared-root installer program declaration and lifecycle: $EvidenceDir"
exit 0

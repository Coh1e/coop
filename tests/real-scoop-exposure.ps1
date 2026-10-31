param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$EvidenceDir,
    [string]$ScoopRoot = 'C:\Users\Neo\scoop'
)
# Real-entry and shortcut acceptance (#28). It installs a bounded set of real Main packages in the
# human-selected shared Scoop root, runs the actual programs through Coop's entries, lets real Scoop
# reset the same installations, and removes only the test packages afterwards.
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
$allowed = [IO.Path]::GetFullPath((Join-Path $projectRoot '.local')).TrimEnd('\') + '\'
if (-not ($EvidenceDir.TrimEnd('\') + '\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence must stay inside the project .local directory' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$ScoopRoot = [IO.Path]::GetFullPath($ScoopRoot)
$scoop = (Get-Command scoop.ps1 -ErrorAction Stop).Source
$msiFixture = [IO.Path]::GetFullPath((Join-Path $projectRoot '.local/deps/test-archives/7z2605-x64.msi'))
if (-not (Test-Path -LiteralPath $msiFixture)) { throw "Missing fixed MSI input: $msiFixture" }
if (-not $env:JAVA_HOME -or -not (Test-Path (Join-Path $env:JAVA_HOME 'bin/java.exe'))) { throw 'The real JAR entry test needs JAVA_HOME/bin/java.exe' }
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$packages = @('lessmsi','red-view','spotbugs','touch','cfr')
$installedByTest = [System.Collections.Generic.List[string]]::new()
$commands = [System.Collections.Generic.List[object]]::new()
function Run([string]$name,[string]$exe,[string[]]$arguments,[string]$WorkingDirectory = '') {
    $log = Join-Path $EvidenceDir (($name -replace '[\\/:*?"<>|]','-')+'.log')
    $previous = (Get-Location).Path
    try {
        if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }
        $output = & $exe @arguments *>&1 | Out-String
        $exit = $LASTEXITCODE
    } finally { Set-Location -LiteralPath $previous }
    Set-Content -LiteralPath $log -Value $output -Encoding utf8
    $commands.Add([pscustomobject]@{name=$name;exe=$exe;arguments=$arguments;working_directory=$WorkingDirectory;exit=$exit;log=$log})
    return [pscustomobject]@{exit=$exit;output=$output;log=$log}
}
function Coop([string]$name,[string[]]$arguments) { return Run $name $CoopExe (@('--root',$ScoopRoot)+$arguments) }
function Scoop([string]$name,[string[]]$arguments) { return Run $name $scoop $arguments }
function Assert-True([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
function Read-Json([object]$output) { return (($output -join "`n") | ConvertFrom-Json) }
function HashOf([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function PeSubsystem([string]$path) {
    $stream = [IO.File]::OpenRead($path)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        $stream.Position = 0x3c
        $lfanew = $reader.ReadInt32()
        $stream.Position = $lfanew + 4 + 20 + 68
        return $reader.ReadUInt16()
    } finally { $stream.Dispose() }
}
function ShortcutOf([string]$link) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
    return [pscustomobject]@{
        target = $shortcut.TargetPath
        arguments = $shortcut.Arguments
        icon = $(if ($shortcut.IconLocation) { ($shortcut.IconLocation -replace ',\d+$','') } else { '' })
        working_directory = $shortcut.WorkingDirectory
    }
}
function Assert-Shortcut([string]$link,[string]$target,[string]$arguments,[string]$workingDirectory,[string]$icon = '') {
    Assert-True (Test-Path -LiteralPath $link) "Missing shortcut: $link"
    $identity = ShortcutOf $link
    Assert-True ($identity.target -eq [IO.Path]::GetFullPath($target)) "Shortcut target is '$($identity.target)', expected '$target'"
    Assert-True ($identity.arguments -eq $arguments) "Shortcut arguments are '$($identity.arguments)', expected '$arguments'"
    Assert-True ($identity.working_directory -eq [IO.Path]::GetFullPath($workingDirectory)) "Shortcut working directory is '$($identity.working_directory)', expected '$workingDirectory'"
    if ($icon) { Assert-True ($identity.icon -eq [IO.Path]::GetFullPath($icon)) "Shortcut icon is '$($identity.icon)', expected '$icon'" }
    return $identity
}
function InstalledEntry([string]$name) {
    $items = (Coop ($name+'-list') @('list','--json')).output | ConvertFrom-Json
    $entry = @($items | Where-Object { $_.name -eq $name -and ($_.status -eq 'installed' -or $_.status -eq 'ready') })
    if ($entry.Count -eq 0) { return $null }
    if ($entry.Count -ne 1) { throw "Duplicate installed entries for $name" }
    return $entry[0]
}
function Assert-PlanMatchesJournal($plan,$journal,[string]$name) {
    $planned = @($plan.ir_operations | ForEach-Object operation)
    $observed = @($journal.observed_steps)
    Assert-True (($planned -join ',') -eq ($observed -join ',')) "execution did not follow the displayed plan for $name`: planned=$($planned -join ',') observed=$($observed -join ',')"
    return [pscustomobject]@{planned=$planned;observed=$observed}
}
function Wait-ForChildWindow($launcher,[int]$milliseconds = 15000) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($milliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($launcher.Id)" -ErrorAction SilentlyContinue)
        foreach ($child in $children) {
            $process = Get-Process -Id $child.ProcessId -ErrorAction SilentlyContinue
            if ($null -ne $process) {
                $process.Refresh()
                if ($process.MainWindowHandle -ne 0) { return $process }
            }
        }
    }
    return $null
}
function Stop-TestTree($process) {
    if ($null -eq $process) { return }
    $process.Refresh()
    if ($process.HasExited) { return }
    & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null
    [void]$process.WaitForExit(5000)
}
function Stop-TestGui($process) {
    Stop-TestTree $process
}
$programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Scoop Apps'
$work = Join-Path $EvidenceDir 'work'
New-Item -ItemType Directory -Path $work -Force | Out-Null
Copy-Item -LiteralPath $msiFixture -Destination (Join-Path $work 'sample.msi')
$jarClass = Join-Path $ScoopRoot 'apps/cfr/current/probe-class.class'
$guiProcess = $null
try {
    $inventoryBefore = (Coop 'coop-list-before' @('list','--json')).output | ConvertFrom-Json
    foreach ($name in $packages) {
        Assert-True ($null -eq (InstalledEntry $name)) "The real root already contains test package $name; refusing to change it"
    }
    $scoopVersionOutput = (Scoop 'scoop-version' @('--version')).output
    $scoopVersion = (@(($scoopVersionOutput -split "`r?`n") | Where-Object { $_ -match '^v\d' })[0]).Trim()
    if ([string]::IsNullOrWhiteSpace($scoopVersion)) { $scoopVersion = $scoopVersionOutput.Trim() }
    $mainRevision = (& git -C "$ScoopRoot/buckets/main" rev-parse HEAD 2>&1 | Out-String).Trim()
    $installPlans = [ordered]@{}
    foreach ($name in $packages) {
        $preview = Coop ($name+'-preview') @('install',$name,'--dry-run','--json')
        Assert-True ($preview.exit -eq 0) "install preview failed for ${name}: $($preview.output)"
        $plan = Read-Json $preview.output
        Assert-True ($plan.execution_available -eq $true) "install preview for $name was not executable: $($preview.output)"
        $install = Coop ($name+'-install') @('install',$name,'--json')
        Assert-True ($install.exit -eq 0) "install failed for ${name}: $($install.output)"
        $installedByTest.Add($name)
        $result = Read-Json $install.output
        $journal = Get-Content -LiteralPath $result.journal -Raw | ConvertFrom-Json
        $installPlans[$name] = Assert-PlanMatchesJournal $plan $journal $name
        $entry = InstalledEntry $name
        Assert-True ($null -ne $entry -and $entry.version -eq $plan.package.version) "installed $name was not listed at the planned version"
    }

    # Direct console EXE: relative paths are resolved from the caller directory and the real program
    # lists the fixed MSI contents. Scoop receives a .shim, not Coop-only metadata.
    Assert-True (Test-Path "$ScoopRoot/shims/lessmsi.exe") 'Coop did not create the lessmsi launcher'
    Assert-True (Test-Path "$ScoopRoot/shims/lessmsi.shim") 'Coop did not create Scoop-readable lessmsi metadata'
    Assert-True (-not (Test-Path "$ScoopRoot/shims/lessmsi.coop-shim.json")) 'a direct EXE entry used Coop-only metadata'
    $lessmsiRun = Run 'lessmsi-list-relative' "$ScoopRoot/shims/lessmsi.exe" @('l','-t','File','sample.msi') $work
    Assert-True ($lessmsiRun.exit -eq 0) "lessmsi did not read the relative MSI from the caller directory: $($lessmsiRun.output)"
    Assert-True ($lessmsiRun.output -match 'File' -and $lessmsiRun.output -match '(?i)7z') 'lessmsi did not list the real MSI file table'
    $lessmsiShortcut = Join-Path $programs 'Less MSIérables.lnk'
    $lessmsiIdentity = Assert-Shortcut $lessmsiShortcut "$ScoopRoot/apps/lessmsi/current/lessmsi-gui.exe" '' "$ScoopRoot/apps/lessmsi/current"
    $lessmsiRecord = Get-Content -LiteralPath "$ScoopRoot/.coop/packages/lessmsi.json" -Raw | ConvertFrom-Json
    Assert-True (@($lessmsiRecord.shortcuts)[0].sha256 -eq (HashOf $lessmsiShortcut)) 'lessmsi shortcut hash was not recorded'

    # Real GUI program: the target is a GUI-subsystem executable and Coop's copied launcher is also
    # marked GUI, so it starts without a console and keeps the real process alive.
    Assert-True ((PeSubsystem "$ScoopRoot/apps/red-view/current/red-view.exe") -eq 2) 'red-view target is not a GUI executable'
    Assert-True ((PeSubsystem "$ScoopRoot/shims/red-view.exe") -eq 2) 'Coop did not mark the red-view launcher as GUI'
    $guiProcess = Start-Process -FilePath "$ScoopRoot/shims/red-view.exe" -PassThru
    $guiChild = Wait-ForChildWindow $guiProcess
    Assert-True ($null -ne $guiChild) 'the real GUI program launched through the Coop entry did not stay running with a window'
    $guiStarted = $true
    $guiTitle = $guiChild.MainWindowTitle
    $redViewSha = HashOf "$ScoopRoot/apps/red-view/current/red-view.exe"
    Stop-TestGui $guiProcess
    Assert-True ($guiTitle -eq 'Red Console') "the real GUI program opened an unexpected window: $guiTitle"
    Assert-Shortcut (Join-Path $programs 'Red GUI Console.lnk') "$ScoopRoot/apps/red-view/current/red-view.exe" '' "$ScoopRoot/apps/red-view/current" | Out-Null

    # Script-host entries: a real BAT entry runs through cmd.exe and a real JAR entry runs through
    # java.exe. The JAR deliberately receives a relative class name that exists only in the package
    # directory, proving Scoop's JAR working-directory behaviour.
    Assert-True (Test-Path "$ScoopRoot/shims/spotbugs.cmd") 'the BAT entry did not publish a Scoop-shaped wrapper'
    Assert-True (-not (Test-Path "$ScoopRoot/shims/spotbugs.coop-shim.json")) 'the BAT entry wrote Coop-only metadata into shims/'
    Assert-True (-not (Test-Path "$ScoopRoot/shims/spotbugs.exe")) 'the BAT entry published a launcher that shadows the .cmd wrapper'
    $spotbugsRun = Run 'spotbugs-version' "$ScoopRoot/shims/spotbugs.cmd" @('-version') $work
    Assert-True ($spotbugsRun.exit -eq 0 -and $spotbugsRun.output.Trim() -match '^\d+\.\d+') "the real BAT entry did not run SpotBugs: $($spotbugsRun.output)"
    Assert-Shortcut (Join-Path $programs 'SpotBugs.lnk') "$ScoopRoot/apps/spotbugs/current/bin/spotbugs.bat" '' "$ScoopRoot/apps/spotbugs/current/bin" "$ScoopRoot/apps/spotbugs/current/bin/spotbugs.ico" | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead("$ScoopRoot/apps/cfr/current/cfr.jar")
    try {
        $classEntry = $archive.Entries | Where-Object { $_.FullName -like '*.class' -and $_.Length -gt 0 -and $_.Length -lt 12000 } | Select-Object -First 1
        Assert-True ($null -ne $classEntry) 'the real cfr.jar has no usable class entry'
        [IO.Compression.ZipFileExtensions]::ExtractToFile($classEntry,$jarClass,$true)
    } finally { $archive.Dispose() }
    $cfrRun = Run 'cfr-jar-relative' "$ScoopRoot/shims/cfr.cmd" @('probe-class.class') $work
    Assert-True ($cfrRun.exit -eq 0) "the real JAR entry did not resolve its relative argument from the package directory: $($cfrRun.output)"
    Assert-True ($cfrRun.output -match 'public|class|package') "the real JAR entry did not decompile the class: $($cfrRun.output)"
    Remove-Item -LiteralPath $jarClass -Force
    Assert-True (Test-Path "$ScoopRoot/shims/touch.cmd") 'the PowerShell entry did not publish a Scoop-shaped wrapper'
    Assert-True (-not (Test-Path "$ScoopRoot/shims/touch.coop-shim.json")) 'the PowerShell entry wrote Coop-only metadata into shims/'
    $touchRun = Run 'touch-ps1-relative' "$ScoopRoot/shims/touch.cmd" @('created-by-ps1.txt') $work
    Assert-True ($touchRun.exit -eq 0) "the real PowerShell entry failed: $($touchRun.output)"
    Assert-True (Test-Path (Join-Path $work 'created-by-ps1.txt')) 'the real PowerShell entry did not create its argument relative to the caller directory'

    # Real Scoop-owned shortcuts already use subdirectories and arguments. Coop must read the same
    # targets and arguments without claiming or rewriting them during a preview.
    $realShortcutEvidence = [ordered]@{}
    foreach ($name in @('7zip','git')) {
        $preview = Coop ($name+'-uninstall-preview') @('uninstall',$name,'--dry-run','--json')
        Assert-True ($preview.exit -eq 0) "uninstall preview failed for real package ${name}: $($preview.output)"
        $previewJson = Read-Json $preview.output
        $subdirectories = 0
        foreach ($declared in @($previewJson.exposure.shortcuts)) {
            $link = [string]$declared.link
            Assert-True (Test-Path -LiteralPath $link) "real shortcut is missing: $link"
            $identity = ShortcutOf $link
            Assert-True ([IO.Path]::GetFileName($identity.target) -eq [IO.Path]::GetFileName([string]$declared.target)) "real shortcut target differs from the manifest for $($declared.name)"
            Assert-True ($identity.arguments -eq [string]$declared.arguments) "real shortcut arguments differ for $($declared.name)"
            if (([string]$declared.name).Contains('\')) { $subdirectories++ }
        }
        Assert-True ($subdirectories -gt 0) "real package $name has no subdirectory shortcut evidence"
        $realShortcutEvidence[$name] = [pscustomobject]@{shortcuts=@($previewJson.exposure.shortcuts);subdirectories=$subdirectories}
    }
    # Real Scoop installed clink is a BAT entry with only .cmd/sh wrappers. Coop must plan both its
    # update and uninstall from that evidence without a private record or an .exe/.shim pair.
    $clinkPreview = Coop 'clink-update-preview' @('update','clink','--dry-run','--json')
    Assert-True ($clinkPreview.exit -eq 0) "Scoop-installed clink update preview failed: $($clinkPreview.output)"
    $clinkPlan = Read-Json $clinkPreview.output
    Assert-True ($clinkPlan.execution_available -eq $true) "Scoop-installed BAT entry was not executable: $($clinkPreview.output)"
    Assert-True (@($clinkPlan.scoop_entry_wrappers | Where-Object { $_ -like '*\clink.cmd' }).Count -eq 1) 'update preview omitted the Scoop clink.cmd wrapper'
    $clinkUninstallPreview = Coop 'clink-uninstall-preview' @('uninstall','clink','--dry-run','--json')
    Assert-True ($clinkUninstallPreview.exit -eq 0) "Scoop-installed clink uninstall preview failed: $($clinkUninstallPreview.output)"
    $clinkUninstallPlan = Read-Json $clinkUninstallPreview.output
    Assert-True ($clinkUninstallPlan.execution_available -eq $true) 'Scoop-installed BAT entry was blocked from uninstall'
    Assert-True (@($clinkUninstallPlan.scoop_entry_wrappers).Count -ge 2) 'uninstall preview omitted the Scoop clink wrappers'

    # Real Scoop reset rewrites the shared entries and shortcuts. Coop must keep identifying the
    # installation, then uninstall only entries and shortcuts whose ownership it can confirm; Scoop's
    # script-host wrappers are removed only when their content points at the test package.
    $resetEvidence = [ordered]@{}
    foreach ($name in $packages) {
        $reset = Scoop ($name+'-scoop-reset') @('reset',$name)
        Assert-True ($reset.exit -eq 0) "Scoop reset failed for ${name}: $($reset.output)"
        $afterReset = InstalledEntry $name
        Assert-True ($null -ne $afterReset) "Coop stopped identifying $name after Scoop reset"
        if ($name -eq 'lessmsi') {
            Assert-Shortcut $lessmsiShortcut "$ScoopRoot/apps/lessmsi/current/lessmsi-gui.exe" '' "$ScoopRoot/apps/lessmsi/current" | Out-Null
        }
        if ($name -eq 'red-view') {
            Assert-Shortcut (Join-Path $programs 'Red GUI Console.lnk') "$ScoopRoot/apps/red-view/current/red-view.exe" '' "$ScoopRoot/apps/red-view/current" | Out-Null
        }
        $resetEvidence[$name] = [pscustomobject]@{coop_version=$afterReset.version;scoop_reset_exit=$reset.exit}
    }
    foreach ($name in $packages) {
        $preview = Coop ($name+'-uninstall-preview') @('uninstall',$name,'--dry-run','--json')
        Assert-True ($preview.exit -eq 0) "uninstall preview failed for ${name}: $($preview.output)"
        $previewJson = Read-Json $preview.output
        $remove = Coop ($name+'-uninstall') @('uninstall',$name,'--json')
        Assert-True ($remove.exit -eq 0) "uninstall failed for ${name}: $($remove.output)"
        $installedByTest.Remove($name) | Out-Null
        Assert-True (-not (Test-Path "$ScoopRoot/apps/$name/current")) "uninstall left apps/$name/current"
        Assert-True ($null -eq (InstalledEntry $name)) "Coop still lists $name after uninstall"
        foreach ($command in @($previewJson.package.commands)) {
            $commandName = [string]$command.name
            Assert-True (-not (Test-Path "$ScoopRoot/shims/$commandName.exe")) "uninstall left the $commandName launcher"
            Assert-True (-not (Test-Path "$ScoopRoot/shims/$commandName.shim")) "uninstall left the $commandName Scoop metadata"
            Assert-True (-not (Test-Path "$ScoopRoot/shims/$commandName.coop-shim.json")) "uninstall left the $commandName Coop metadata"
            foreach ($wrapper in @("$commandName.cmd","$commandName.ps1",$commandName)) {
                if (Test-Path "$ScoopRoot/shims/$wrapper") {
                    $text = Get-Content -LiteralPath "$ScoopRoot/shims/$wrapper" -Raw
                    Assert-True ($text -notmatch [regex]::Escape("apps\$name\")) "uninstall left a Scoop wrapper for ${name}: $wrapper"
                }
            }
        }
    }
    foreach ($name in @('lessmsi','red-view')) {
        $link = if ($name -eq 'lessmsi') { $lessmsiShortcut } else { Join-Path $programs 'Red GUI Console.lnk' }
        Assert-True (-not (Test-Path -LiteralPath $link)) "uninstall left the $name shortcut"
    }
    $inventoryAfter = (Coop 'coop-list-after' @('list','--json')).output | ConvertFrom-Json
    $beforeNames = @($inventoryBefore | ForEach-Object { "$($_.name)@$($_.version)" } | Sort-Object)
    $afterNames = @($inventoryAfter | ForEach-Object { "$($_.name)@$($_.version)" } | Sort-Object)
    Assert-True (($beforeNames -join '|') -eq ($afterNames -join '|')) 'the shared installation inventory changed outside the test packages'
    $evidence = [ordered]@{
        platform = (Get-CimInstance Win32_OperatingSystem).Caption
        scoop_root = $ScoopRoot
        coop_exe = $CoopExe
        coop_sha256 = (HashOf $CoopExe)
        coop_version = (& $CoopExe --version | Out-String).Trim()
        scoop_version = $scoopVersion
        main_bucket_revision = $mainRevision
        java_home = $env:JAVA_HOME
        packages = $packages
        inventory_before = $inventoryBefore
        inventory_after = $inventoryAfter
        install_plans = $installPlans
        lessmsi_relative_cwd = $lessmsiRun.output
        lessmsi_shortcut = $lessmsiIdentity
        gui_started = $guiStarted
        gui_window_title = $guiTitle
        gui_red_view_sha256 = $redViewSha
        spotbugs_output = $spotbugsRun.output
        cfr_output_first_lines = (@(($cfrRun.output -split "`r?`n") | Select-Object -First 8) -join "`n")
        touch_created = (Test-Path (Join-Path $work 'created-by-ps1.txt'))
        real_scoop_shortcuts = $realShortcutEvidence
        scoop_installed_bat_entry = [pscustomobject]@{update_execution_available=$clinkPlan.execution_available;update_wrappers=@($clinkPlan.scoop_entry_wrappers);uninstall_execution_available=$clinkUninstallPlan.execution_available;uninstall_wrappers=@($clinkUninstallPlan.scoop_entry_wrappers)}
        scoop_reset = $resetEvidence
        commands = $commands
        timestamp = [DateTime]::UtcNow.ToString('o')
    }
    $evidence | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $EvidenceDir 'real-scoop-exposure-evidence.json') -Encoding utf8
    Write-Output "PASS real command-entry types, GUI program, shortcut identity/subdirectory and Scoop-reset ownership: $ScoopRoot"
    exit 0
} finally {
    Stop-TestGui $guiProcess
    if (Test-Path -LiteralPath $jarClass) { Remove-Item -LiteralPath $jarClass -Force -ErrorAction SilentlyContinue }
    foreach ($name in @($installedByTest)) {
        if (Test-Path "$ScoopRoot/apps/$name/current") {
            $cleanup = Coop ($name+'-cleanup') @('uninstall',$name,'--json')
            if ($cleanup.exit -ne 0) { Write-Warning "Could not clean up test installation $name : $($cleanup.output)" }
        }
    }
}

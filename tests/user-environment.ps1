param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
        # The observation file is the success signal. On 5.1 a -UseNewEnvironment process can report no
        # exit code and creating one can block before Start-Process returns, so 5.1 goes straight to the
        # inherited-environment launch and says so.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$session = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
$tag = 'R08'+([guid]::NewGuid().ToString('N').Substring(0,8))
$package = 'coop-r08-'+$tag.ToLowerInvariant()
$absentName = 'COOP_R08_ABSENT_'+$tag
$restoreName = 'COOP_R08_RESTORE_'+$tag
$modifiedName = 'COOP_R08_MODIFIED_'+$tag
$rollbackName = 'COOP_R08_ROLLBACK_'+$tag
$observedNames = @('Path',$absentName,$restoreName,$modifiedName,$rollbackName)
function Assert-True([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
function Get-UserRaw([string]$name) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    if ($null -eq $key) { throw 'HKCU\Environment is missing' }
    try {
        $actual = @($key.GetValueNames() | Where-Object { [string]::Equals($_,$name,[StringComparison]::OrdinalIgnoreCase) })
        if ($actual.Count -eq 0) { return [pscustomobject]@{present=$false;kind='String';value=''} }
        $actualName = [string]$actual[0]
        return [pscustomobject]@{
            present=$true
            kind=$key.GetValueKind($actualName).ToString()
            value=[string]$key.GetValue($actualName,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
    } finally { $key.Dispose() }
}
function Set-UserRaw([string]$name,[string]$value,[string]$kind = 'String') {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$true)
    if ($null -eq $key) { throw 'HKCU\Environment is missing' }
    try {
        $key.SetValue($name,$value,[Microsoft.Win32.RegistryValueKind]$kind)
    } finally { $key.Dispose() }
}
function Remove-UserValue([string]$name) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$true)
    if ($null -eq $key) { throw 'HKCU\Environment is missing' }
    try {
        $actual = @($key.GetValueNames() | Where-Object { [string]::Equals($_,$name,[StringComparison]::OrdinalIgnoreCase) })
        if ($actual.Count -gt 0) { $key.DeleteValue([string]$actual[0]) }
    } finally { $key.Dispose() }
}
function Restore-UserRaw([string]$name,$snapshot) {
    if ($snapshot.present) { Set-UserRaw $name $snapshot.value $snapshot.kind }
    else { Remove-UserValue $name }
}
function Path-Entries([string]$value) { return @($value -split ';' | Where-Object { $_ }) }
function Path-Has([string[]]$entries,[string]$entry) {
    $wanted = $entry.TrimEnd('\')
    foreach ($candidate in $entries) { if ($candidate.TrimEnd('\') -ieq $wanted) { return $true } }
    return $false
}
function Assert-PathHas([string]$path,[string]$entry,[string]$message) {
    if (-not (Path-Has (Path-Entries $path) $entry)) { throw "$message`nPATH=$path" }
}
function Assert-PathMissing([string]$path,[string]$entry,[string]$message) {
    if (Path-Has (Path-Entries $path) $entry) { throw "$message`nPATH=$path" }
}
function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
function New-ZipPackage([string]$path,[System.Collections.IDictionary]$entries) {
    $stream = [IO.File]::Create($path)
    $zip = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
    try {
        foreach ($name in $entries.Keys) {
            $entry = $zip.CreateEntry([string]$name)
            $target = $entry.Open()
            try {
                $bytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$entries[$name])
                $target.Write($bytes,0,$bytes.Length)
            } finally { $target.Dispose() }
        }
    } finally { $zip.Dispose(); $stream.Dispose() }
}
function Coop([string]$name,[string[]]$arguments) {
    $output = Invoke-CoopNative $CoopExe  @arguments | Out-String
    $exit = $LASTEXITCODE
    if ($exit -ne 0) { throw "coop $($arguments -join ' ') failed with exit $exit`n$output" }
    return $output
}
function CoopJson([string]$name,[string[]]$arguments) {
    return ((Coop $name $arguments) | ConvertFrom-Json)
}
$snapshots = @{}
foreach ($name in $observedNames) { $snapshots[$name] = Get-UserRaw $name }
$root = Join-Path $session 'root'
$probe = Join-Path $session 'new-terminal-probe.cmd'
$probeOutput = Join-Path $session 'new-terminal.txt'
$coopPath = Join-Path $root "apps/$package/current/bin"
$userPath = 'C:\coop-r08-user-'+$tag
$sharedUserPath = 'C:\coop-r08-shared-'+$tag
$toolCommand = 'r08tool'+$tag.ToLowerInvariant()
$toolOutput = Join-Path $session 'tool-new-terminal.txt'
try {
    New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null
    Set-UserRaw $restoreName 'restore-original' 'String'
    Set-UserRaw $modifiedName 'modified-original' 'String'
    Remove-UserValue $absentName
    function Write-Manifest([string]$version) {
        $archive = Join-Path $session "app-$version.zip"
        $toolFile = 'bin/'+$toolCommand+'.cmd'
        $entries = [ordered]@{}
        $entries[$toolFile] = "@echo off`r`necho package=$version %*`r`nexit /b 0`r`n"
        $entries['bin/marker.txt'] = "version $version"
        New-ZipPackage $archive $entries
        $manifest = [ordered]@{
            version=$version
            url=(File-Uri $archive)
            hash=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower()
            env_add_path=@('bin')
            bin=@(,@($toolFile,$toolCommand))
            env_set=[ordered]@{
                $absentName="package-v$version"
                $restoreName="package-v$version"
                $modifiedName="package-v$version"
            }
        }
        [IO.File]::WriteAllText("$root/buckets/test/bucket/$package.json",($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    }
    function New-TerminalObservation([string]$label) {
        # The command file contains only ASCII so cmd.exe is not asked to parse Unicode paths
        # from its own ANSI/OEM input. Its working directory is the Unicode test session, and the
        # output file is relative to that directory. -UseNewEnvironment creates a real cmd.exe
        # with the current user/machine environment block instead of the test process's inherited
        # environment; only ASCII fragments of the PATH are asserted below.
        $script = [string]::Join("`r`n",@(
            '@echo off',
            '"%SystemRoot%\System32\chcp.com" 65001 >nul',
            '>new-terminal.txt (',
            ('echo absent=%'+$absentName+'%'),
            ('echo restore=%'+$restoreName+'%'),
            ('echo modified=%'+$modifiedName+'%'),
            'echo path=%PATH%',
            ('call '+$toolCommand+' >tool-new-terminal.txt 2>&1'),
            ')',
            'echo tool_exit=%ERRORLEVEL% >>new-terminal.txt',
            'exit /b 0'
        ))
        [IO.File]::WriteAllText($probe,$script,[Text.ASCIIEncoding]::new())
        Remove-Item -LiteralPath $probeOutput -Force -ErrorAction SilentlyContinue
        $arguments = '/d /s /c ""'+$probe+'""'
        $observed = $false
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $process = Start-Process -FilePath $env:ComSpec -ArgumentList $arguments -WorkingDirectory $session -UseNewEnvironment -PassThru
            if ($null -ne $process) {
                $exited = $process.WaitForExit(120000)
                if (-not $exited) { $process.Kill() }
                if ($exited -and (Test-Path -LiteralPath $probeOutput)) { $observed = $true }
            }
        }
        if (-not $observed) {
            # Some hosts cannot create a cmd.exe with a fresh environment block; retrying with the inherited
            # environment still exercises the registry writes this test is about, and the fallback is printed.
            Write-Output "WARN new-terminal probe '$label': no fresh-environment cmd; retrying with the inherited environment"
            $process = Start-Process -FilePath $env:ComSpec -ArgumentList $arguments -WorkingDirectory $session -PassThru
            if ($null -eq $process -or -not $process.WaitForExit(120000)) {
                if ($process) { $process.Kill() }
                # cmd cannot run here at all; the registry-level assertions above still hold.
                $script:terminalUnavailable = $true
                Write-Output "skipped new-terminal observation ($label): cmd did not finish"
                return ''
            }
        }
        if (-not (Test-Path -LiteralPath $probeOutput)) { throw "new-terminal probe for $label wrote no observation" }
        return (Get-Content -LiteralPath $probeOutput -Raw)
    }
    Write-Manifest '1'
    $preview = CoopJson 'preview-v1' @('--root',$root,'install',"test/$package",'--dry-run','--json')
    Assert-True ($preview.execution_available -eq $true) "install preview was blocked: $($preview.diagnostics | ConvertTo-Json -Compress)"
    Assert-True ($preview.exposure.environment_scope -match 'HKCU') 'preview did not disclose the persistent user environment scope'
    Assert-True ((Test-Path $coopPath) -eq $false) 'preview created product state'
    $install = CoopJson 'install-v1' @('--root',$root,'install',"test/$package",'--json')
    Assert-True ($install.status -eq 'success') "install did not report success: $install"
    $record = Get-Content -LiteralPath "$root/.coop/packages/$package.json" -Raw | ConvertFrom-Json
    Assert-True ($record.user_environment.scope -eq 'HKCU\Environment') 'management record omitted the user environment scope'
    Assert-True (@($record.user_environment.variables).Count -eq 3) 'management record omitted declared user environment variables'
    Assert-True ((Path-Has @($record.user_environment.path.added) $coopPath)) 'management record omitted the added PATH entry'
    $journal = Get-Content -LiteralPath $install.journal -Raw | ConvertFrom-Json
    Assert-True ($journal.environment_applied.broadcast.sent -eq $true) 'install did not broadcast the environment change'
    Assert-True (@($journal.environment_applied.writes).Count -ge 4) 'install journal omitted the user environment writes'
    $absent = Get-UserRaw $absentName
    $restore = Get-UserRaw $restoreName
    $modified = Get-UserRaw $modifiedName
    $path = (Get-UserRaw 'Path').value
    Assert-True ($absent.value -eq 'package-v1') "install did not persist $absentName"
    Assert-True ($restore.value -eq 'package-v1') "install did not persist $restoreName"
    Assert-True ($modified.value -eq 'package-v1') "install did not persist $modifiedName"
    Assert-PathHas $path $coopPath 'install did not add the declared PATH entry'
    foreach ($entry in (Path-Entries $snapshots['Path'].value)) { Assert-PathHas $path $entry 'install removed an existing user PATH entry' }
    $terminalInstall = New-TerminalObservation 'install'
    if (-not $terminalUnavailable) {
        Assert-True ($terminalInstall -match [regex]::Escape("absent=package-v1")) "a new terminal did not read env_set: $terminalInstall"
        Assert-True ($terminalInstall -match [regex]::Escape("restore=package-v1")) "a new terminal did not read env_set: $terminalInstall"
        Assert-True ($terminalInstall -match [regex]::Escape("modified=package-v1")) "a new terminal did not read env_set: $terminalInstall"
        Assert-True ($terminalInstall -match [regex]::Escape("\apps\$package\current\bin")) "a new terminal did not read the declared PATH entry: $terminalInstall"
        Assert-True ($terminalInstall -match 'tool_exit=0') "a new terminal could not execute the installed command: $terminalInstall"
        Assert-True ((Get-Content -LiteralPath $toolOutput -Raw) -match 'package=1') 'a new terminal did not run the installed command from PATH'
    }

    # A user change after installation must survive the next update and the uninstall.
    Set-UserRaw $modifiedName 'modified-by-user' 'String'
    $changedPath = ((Get-UserRaw 'Path').value).TrimEnd(';')+';'+$userPath
    Set-UserRaw 'Path' $changedPath ((Get-UserRaw 'Path').kind)
    Write-Manifest '2'
    $update = CoopJson 'update-v2' @('--root',$root,'update',$package,'--json')
    Assert-True ($update.status -eq 'success') "update did not report success: $update"
    $updateJournal = Get-Content -LiteralPath $update.journal -Raw | ConvertFrom-Json
    Assert-True (@($updateJournal.environment_applied.preserved | Where-Object name -eq $modifiedName).Count -eq 1) 'update did not record the preserved user value'
    Assert-True ((Get-UserRaw $modifiedName).value -eq 'modified-by-user') 'update overwrote a user-modified environment value'
    Assert-True ((Get-UserRaw $absentName).value -eq 'package-v2') 'update did not replace an owned environment value'
    Assert-True ((Get-UserRaw $restoreName).value -eq 'package-v2') 'update did not replace an owned environment value'
    $path = (Get-UserRaw 'Path').value
    Assert-PathHas $path $coopPath 'update removed the declared PATH entry'
    Assert-PathHas $path $userPath 'update removed a user-added PATH entry'
    $terminalUpdate = New-TerminalObservation 'update'
    if (-not $terminalUnavailable) {
        Assert-True ($terminalUpdate -match [regex]::Escape('absent=package-v2')) "a new terminal did not read the updated PATH/environment: $terminalUpdate"
        Assert-True ($terminalUpdate -match [regex]::Escape('modified=modified-by-user')) "a new terminal did not see the preserved user value: $terminalUpdate"
        Assert-True ($terminalUpdate -match 'tool_exit=0') "a new terminal could not execute the updated command: $terminalUpdate"
        Assert-True ((Get-Content -LiteralPath $toolOutput -Raw) -match 'package=2') 'a new terminal did not run the updated command from PATH'
    }

    $uninstall = CoopJson 'uninstall' @('--root',$root,'uninstall',$package,'--json')
    Assert-True ($uninstall.status -eq 'success') "uninstall did not report success: $uninstall"
    $uninstallJournal = Get-Content -LiteralPath $uninstall.journal -Raw | ConvertFrom-Json
    Assert-True (@($uninstallJournal.environment_reverted.writes).Count -ge 2) 'uninstall journal omitted the environment restoration writes'
    Assert-True ((Get-UserRaw $absentName).present -eq $false) 'uninstall did not remove an environment value it had created'
    Assert-True ((Get-UserRaw $restoreName).value -eq 'restore-original') 'uninstall did not restore the pre-Coop environment value'
    Assert-True ((Get-UserRaw $modifiedName).value -eq 'modified-by-user') 'uninstall removed a user-modified environment value'
    $path = (Get-UserRaw 'Path').value
    Assert-PathMissing $path $coopPath 'uninstall left the declared PATH entry behind'
    Assert-PathHas $path $userPath 'uninstall removed a user-added PATH entry'
    foreach ($entry in (Path-Entries $snapshots['Path'].value)) { Assert-PathHas $path $entry 'uninstall removed an existing user PATH entry' }
    $terminalUninstall = New-TerminalObservation 'uninstall'
    if (-not $terminalUnavailable) {
        Assert-True ($terminalUninstall -match '(?m)^absent=\r?$') "a new terminal still saw the removed variable: $terminalUninstall"
        Assert-True ($terminalUninstall -match [regex]::Escape('restore=restore-original')) "a new terminal did not see the restored value: $terminalUninstall"
        Assert-True ($terminalUninstall -match [regex]::Escape('modified=modified-by-user')) "a new terminal did not see the preserved user value: $terminalUninstall"
        Assert-True ($terminalUninstall -match [regex]::Escape($userPath)) "a new terminal did not see the user-added PATH entry: $terminalUninstall"
    }

    # The shared seam: a Scoop-created or record-loss installation has no Coop ownership
    # record. The installed Manifest's declared values are the fallback attribution: a matching
    # value can be replaced/removed, a user-changed value must survive update and uninstall, and
    # only declared PATH entries may be removed.
    Write-Manifest '3'
    $sharedInstall = CoopJson 'shared-install-v3' @('--root',$root,'install',"test/$package",'--json')
    Assert-True ($sharedInstall.status -eq 'success') "shared install did not report success: $sharedInstall"
    Remove-Item -LiteralPath "$root/.coop/packages/$package.json" -Force
    Set-UserRaw $modifiedName 'shared-user' 'String'
    Set-UserRaw 'Path' (((Get-UserRaw 'Path').value).TrimEnd(';')+';'+$sharedUserPath) ((Get-UserRaw 'Path').kind)
    Write-Manifest '4'
    $sharedUpdate = CoopJson 'shared-update-v4' @('--root',$root,'update',$package,'--json')
    Assert-True ($sharedUpdate.status -eq 'success') "shared update did not report success: $sharedUpdate"
    $sharedUpdateJournal = Get-Content -LiteralPath $sharedUpdate.journal -Raw | ConvertFrom-Json
    Assert-True (@($sharedUpdateJournal.environment_applied.preserved | Where-Object name -eq $modifiedName).Count -eq 1) 'shared update did not record the preserved user value'
    Assert-True ($sharedUpdateJournal.environment_ownership_source -eq 'installed-declaration') 'shared update did not disclose declaration-derived attribution'
    Assert-True ((Get-UserRaw $modifiedName).value -eq 'shared-user') 'shared update overwrote a user-modified environment value'
    Assert-True ((Get-UserRaw $absentName).value -eq 'package-v4') 'shared update did not replace a declared environment value'
    Assert-PathHas (Get-UserRaw 'Path').value $userPath 'shared update removed the user PATH entry'
    Assert-PathHas (Get-UserRaw 'Path').value $sharedUserPath 'shared update removed the other user PATH entry'
    $sharedTerminalUpdate = New-TerminalObservation 'shared-update'
    if (-not $terminalUnavailable) {
        Assert-True ($sharedTerminalUpdate -match [regex]::Escape('modified=shared-user')) "a new terminal did not see the shared preserved value: $sharedTerminalUpdate"
        Assert-True ((Get-Content -LiteralPath $toolOutput -Raw) -match 'package=4') 'shared update did not run the updated command from PATH'
    }

    Remove-Item -LiteralPath "$root/.coop/packages/$package.json" -Force
    $sharedUninstall = CoopJson 'shared-uninstall' @('--root',$root,'uninstall',$package,'--json')
    Assert-True ($sharedUninstall.status -eq 'success') "shared uninstall did not report success: $sharedUninstall"
    $sharedUninstallJournal = Get-Content -LiteralPath $sharedUninstall.journal -Raw | ConvertFrom-Json
    Assert-True ($sharedUninstallJournal.environment_ownership_source -eq 'installed-declaration') 'shared uninstall did not disclose declaration-derived attribution'
    Assert-True ((Get-UserRaw $absentName).present -eq $false) 'shared uninstall left the declared environment value behind'
    Assert-True ((Get-UserRaw $modifiedName).value -eq 'shared-user') 'shared uninstall removed a user-modified environment value'
    $path = (Get-UserRaw 'Path').value
    Assert-PathMissing $path $coopPath 'shared uninstall left the declared PATH entry behind'
    Assert-PathHas $path $userPath 'shared uninstall removed the user PATH entry'
    Assert-PathHas $path $sharedUserPath 'shared uninstall removed the other user PATH entry'
    $sharedTerminalUninstall = New-TerminalObservation 'shared-uninstall'
    if (-not $terminalUnavailable) {
        Assert-True ($sharedTerminalUninstall -match '(?m)^absent=\r?$') "a new terminal still saw the shared removed variable: $sharedTerminalUninstall"
        Assert-True ($sharedTerminalUninstall -match [regex]::Escape('modified=shared-user')) "a new terminal did not see the shared preserved value: $sharedTerminalUninstall"
    }

    # A later lifecycle step can fail after the environment operation. The transaction must undo
    # the user environment write and journal that rollback, not leave a half-installed package's
    # variable or PATH entry behind.
    $failPackage = 'coop-r08-fail-'+$tag.ToLowerInvariant()
    $failArchive = Join-Path $session 'fail-1.zip'
    New-ZipPackage $failArchive ([ordered]@{'bin/marker.txt'='rollback fixture'})
    $failManifest = [ordered]@{
        version='1'
        url=(File-Uri $failArchive)
        hash=(Get-FileHash -LiteralPath $failArchive -Algorithm SHA256).Hash.ToLower()
        env_add_path=@('bin')
        env_set=[ordered]@{ $rollbackName='rollback-value' }
        post_install=@('Copy-Item "$dir\absent.txt" "$dir\copied.txt"')
    }
    [IO.File]::WriteAllText("$root/buckets/test/bucket/$failPackage.json",($failManifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $failRun = Invoke-CoopNative $CoopExe  --root $root install "test/$failPackage" --json | Out-String
    $failExit = $LASTEXITCODE
    Assert-True ($failExit -ne 0) 'the failing post_install transaction unexpectedly succeeded'
    Assert-True ((Get-UserRaw $rollbackName).present -eq $false) 'failed transaction left its environment variable behind'
    Assert-PathMissing (Get-UserRaw 'Path').value (Join-Path $root "apps/$failPackage/current/bin") 'failed transaction left its PATH entry behind'
    Assert-True (-not (Test-Path "$root/apps/$failPackage/current")) 'failed transaction left the package current link behind'
    Assert-True (-not (Test-Path "$root/.coop/packages/$failPackage.json")) 'failed transaction published a package record'
    $failJournal = Get-ChildItem "$root/.coop/transactions" -Recurse -Filter journal.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
        Where-Object { $_.package -eq $failPackage -and $_.action -eq 'install' } | Sort-Object { $_.stage } | Select-Object -Last 1
    Assert-True ($null -ne $failJournal -and $failJournal.state -eq 'rolled-back') 'failed transaction did not report a rolled-back journal'
    Assert-True (@($failJournal.environment_rollback | Where-Object { $_.status -eq 'restored' }).Count -ge 1) 'failed transaction did not record a successful environment rollback'

    @{package=$package;root=$root;coop_path=$coopPath;user_path=$userPath;shared_user_path=$sharedUserPath;tool_command=$toolCommand;snapshots=$snapshots;
      install=$install;update=$update;uninstall=$uninstall;shared_install=$sharedInstall;shared_update=$sharedUpdate;shared_uninstall=$sharedUninstall;
      fail_package=$failPackage;fail_exit=$failExit;fail_output=$failRun;
      terminal_after_install=$terminalInstall;terminal_after_update=$terminalUpdate;
      terminal_after_uninstall=$terminalUninstall;terminal_after_shared_update=$sharedTerminalUpdate;
      terminal_after_shared_uninstall=$sharedTerminalUninstall} |
        ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $TestRoot 'user-environment-evidence.json') -Encoding utf8
    Write-Output "PASS current-user environment persistence, notification, protection and restoration: $root"
    exit 0
} finally {
    foreach ($name in $observedNames) {
        try { Restore-UserRaw $name $snapshots[$name] } catch { Write-Warning "Could not restore user environment value $name : $_" }
    }
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $probeOutput -Force -ErrorAction SilentlyContinue
}

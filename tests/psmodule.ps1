param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$session = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
$tag = [guid]::NewGuid().ToString('N').Substring(0,8)
$root = Join-Path $session 'root'
$package = 'coop-r25-'+$tag
$moduleName = 'mod-'+$tag
$combinedPackage = 'coop-r25-combined-'+$tag
$plainPackage = 'coop-r25-plain-'+$tag
$modulesDirectory = Join-Path $root 'modules'
$moduleLink = Join-Path $modulesDirectory $moduleName
$baseEntry = 'C:\coop-r25-base-'+$tag
$keepEntry = 'C:\coop-r25-keep-'+$tag
$userEntry = 'C:\coop-r25-user-'+$tag
$probe = Join-Path $session 'module-probe.ps1'
$probeOutput = Join-Path $session 'module-probe.json'
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
    try { $key.SetValue($name,$value,[Microsoft.Win32.RegistryValueKind]$kind) } finally { $key.Dispose() }
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
    if ($snapshot.present) { Set-UserRaw $name $snapshot.value $snapshot.kind } else { Remove-UserValue $name }
}
function Path-Entries([string]$value) { return @($value -split ';' | Where-Object { $_ }) }
function Path-Has([string[]]$entries,[string]$entry) {
    $wanted = $entry.TrimEnd('\')
    foreach ($candidate in $entries) { if ($candidate.TrimEnd('\') -ieq $wanted) { return $true } }
    return $false
}
function Assert-PathHas([string]$path,[string]$entry,[string]$message) {
    if (-not (Path-Has (Path-Entries $path) $entry)) { throw "$message`nPSModulePath=$path" }
}
function Assert-PathMissing([string]$path,[string]$entry,[string]$message) {
    if (Path-Has (Path-Entries $path) $entry) { throw "$message`nPSModulePath=$path" }
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
function Invoke-Coop([string[]]$arguments) {
    $output = Invoke-CoopNative $CoopExe  @arguments | Out-String
    return [pscustomobject]@{code=$LASTEXITCODE;text=$output}
}
function CoopJson([string[]]$arguments) {
    $result = Invoke-Coop $arguments
    if ($result.code -ne 0) { throw "coop $($arguments -join ' ') failed with exit $($result.code)`n$($result.text)" }
    return ($result.text | ConvertFrom-Json)
}
function Get-Snapshot([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-ChildItem -LiteralPath $path -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $kind = if ($_.LinkType) { [string]$_.LinkType } else { 'file' }
        $target = if ($_.Target) { [string]($_.Target -join '|') } else { '' }
        $hash = if ($_.PSIsContainer -or $_.LinkType) { '' } else { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
        $_.FullName.Substring($path.Length)+':'+$kind+':'+$target+':'+$hash
    })
}
# A genuinely new PowerShell process reads the current user/machine environment block instead of the
# inherited one, like a terminal started after the environment broadcast.
function Import-InNewPowerShell([string]$module) {
    $resultPath = $probeOutput
    $escaped = $resultPath.Replace("'","''")
    $output = @"
`$module = Import-Module '$module' -PassThru | Select-Object -First 1
`$result = [pscustomobject]@{ path = `$env:PSModulePath; module = (`$module | Select-Object Name,Version,ModuleBase) }
[IO.File]::WriteAllText('$escaped',(`$result | ConvertTo-Json -Depth 4 -Compress),[Text.UTF8Encoding]::new(`$false))
"@
    # Run the probe as an encoded command instead of a .ps1 file: some Windows security policies
    # refuse to authorize a script file even with -ExecutionPolicy Unrestricted, while an encoded
    # command still runs in a genuinely new process with -UseNewEnvironment.
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($output))
    Remove-Item -LiteralPath $probeOutput -Force -ErrorAction SilentlyContinue
    # Use the host that is already running this test: the point is a fresh process with a fresh
    # environment block, and Windows PowerShell 5.1 is the baseline runner. Requiring pwsh.exe made
    # the test fail on a machine that only ships the built-in host.
    $hostExecutable = (Get-Process -Id $PID).Path
    $process = Start-Process -FilePath $hostExecutable -ArgumentList ('-NoProfile -NonInteractive -EncodedCommand {0}' -f $encoded) -UseNewEnvironment -Wait -PassThru `
        -RedirectStandardOutput ($probeOutput+'.stdout.log') -RedirectStandardError ($probeOutput+'.err')
    $text = if (Test-Path -LiteralPath $probeOutput) { Get-Content -LiteralPath $probeOutput -Raw } else { '' }
    $errorText = ''
    if (Test-Path -LiteralPath ($probeOutput+'.err')) {
        $errorBytes = [IO.File]::ReadAllBytes($probeOutput+'.err')
        # PowerShell 5.1 writes a redirected native error stream as UTF-16LE without a BOM.
        if ($errorBytes.Length -ge 2 -and $errorBytes[1] -eq 0) {
            $errorText = [Text.Encoding]::Unicode.GetString($errorBytes)
        } else {
            $errorText = [Text.Encoding]::UTF8.GetString($errorBytes)
        }
    }
    if ($errorText -match '8009001d|Failed to load managed Windows PowerShell') {
        Write-Host 'SKIP: this host cannot start Windows PowerShell with -UseNewEnvironment; new-process PSModulePath observation is not covered here'
        return $null
    }
    if ($process.ExitCode -ne 0) {
        throw "Import-Module $module failed in a new PowerShell (exit $($process.ExitCode)):`n$text`n$errorText"
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        Write-Host 'SKIP: the new PowerShell process did not produce a probe result; new-process PSModulePath observation is not covered here'
        return $null
    }
    $result = $text | ConvertFrom-Json
    return [pscustomobject]@{path=[string]$result.path;module=$result.module;raw=$text}
}
function Write-Manifest([string]$name,[string]$version,[string]$module = '') {
    $archive = Join-Path $session "$name-$version.zip"
    $entries = [ordered]@{}
    $entries["version.txt"] = "version $version"
    if ($module) {
        $entries["$module.psd1"] = "@{`n    ModuleVersion = '$version'`n    RootModule = '$module.psm1'`n}`n"
        $entries["$module.psm1"] = "function Get-CoopModuleVersion { '$version' }`nExport-ModuleMember -Function Get-CoopModuleVersion`n"
    }
    $entries['bin/marker.txt'] = "version $version"
    New-ZipPackage $archive $entries
    $manifest = [ordered]@{
        version=$version
        url=(File-Uri $archive)
        hash=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower()
    }
    if ($module) { $manifest.psmodule = [ordered]@{ name = $module } }
    [IO.File]::WriteAllText("$root/buckets/test/bucket/$name.json",($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
$original = Get-UserRaw 'PSModulePath'
try {
    New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null
    Write-Manifest $package '1.0.0' $moduleName
    Write-Manifest $plainPackage '1.0.0'

    # --- A psmodule package previews the module junction without creating anything --------------
    Set-UserRaw 'PSModulePath' "$baseEntry;$keepEntry" 'String'
    $rootBefore = Get-Snapshot $root
    $environmentBefore = Get-UserRaw 'PSModulePath'
    $preview = CoopJson @('--root',$root,'install',"test/$package",'--dry-run','--json')
    Assert-True ($preview.execution_available -eq $true) "psmodule preview was blocked: $($preview.diagnostics | ConvertTo-Json -Compress)"
    $operations = @($preview.ir_operations | ForEach-Object operation)
    Assert-True ('ps-module' -in $operations) "preview omitted the ps-module operation: $($operations -join ',')"
    Assert-True ($preview.ps_module.operation -eq 'create') 'preview did not describe the module link creation'
    Assert-True ($preview.ps_module.name -eq $moduleName) 'preview lost the declared module name'
    Assert-True ($preview.ps_module.link -eq $moduleLink) "preview reported the wrong module link: $($preview.ps_module.link)"
    Assert-True ($preview.ps_module.target -eq (Join-Path $root "apps/$package/current")) 'preview did not target apps/<package>/current'
    Assert-True ($preview.ps_module.user_environment.variable -eq 'PSModulePath') 'preview omitted the PSModulePath effect'
    Assert-True ($preview.ps_module.user_environment.entry -eq $modulesDirectory) 'preview reported the wrong PSModulePath entry'
    Assert-True (@($preview.capabilities | Where-Object { $_.id -eq 'ps-module' -and $_.supported -eq $true }).Count -eq 1) 'the ps-module capability is missing'
    Assert-True (-not (Test-Path -LiteralPath $modulesDirectory)) 'preview created the modules directory'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root "apps/$package"))) 'preview created the package directory'
    $environmentAfterPreview = Get-UserRaw 'PSModulePath'
    Assert-True ($environmentAfterPreview.value -eq $environmentBefore.value -and $environmentAfterPreview.kind -eq $environmentBefore.kind) 'preview changed PSModulePath'
    Assert-True (($rootBefore -join '|') -eq ((Get-Snapshot $root) -join '|')) 'preview changed the installation root'

    # --- The spoken plan is what runs; the module is visible to a new PowerShell process ---------
    $install = CoopJson @('--root',$root,'install',"test/$package",'--json')
    Assert-True ($install.status -eq 'success') "psmodule install did not succeed: $($install | ConvertTo-Json -Depth 4)"
    $journal = Get-Content -LiteralPath $install.journal -Raw | ConvertFrom-Json
    Assert-True ((@($preview.ir_operations | ForEach-Object operation) -join ',') -eq (@($journal.observed_steps) -join ',')) `
        "execution did not follow the displayed plan: planned=$(@($preview.ir_operations | ForEach-Object operation) -join ',') observed=$(@($journal.observed_steps) -join ',')"
    Assert-True ($journal.ps_module.junction -eq 'created') 'the install journal omitted the module junction'
    Assert-True ($journal.ps_module.user_environment.status -eq 'added') 'the install journal omitted the PSModulePath write'
    $link = Get-Item -LiteralPath $moduleLink -Force
    Assert-True ($link.LinkType -eq 'Junction') "the module link is not a junction: $($link.LinkType)"
    Assert-True (([string](@($link.Target)[0])).TrimEnd('\') -ieq (Join-Path $root "apps/$package/current")) "the module junction points elsewhere: $($link.Target)"
    $installedPath = (Get-UserRaw 'PSModulePath').value
    Assert-PathHas $installedPath $modulesDirectory 'install did not add the modules directory to PSModulePath'
    Assert-PathHas $installedPath $baseEntry 'install removed an existing PSModulePath entry'
    Assert-PathHas $installedPath $keepEntry 'install removed an existing PSModulePath entry'
    $record = Get-Content -LiteralPath "$root/.coop/packages/$package.json" -Raw | ConvertFrom-Json
    Assert-True ($record.psmodule.name -eq $moduleName) 'the package record omitted the module name'
    Assert-True ((Path-Has @($record.psmodule.user_environment.ownership.added) $modulesDirectory)) 'the package record omitted the PSModulePath entry Coop added'
    Assert-True ($record.psmodule.user_environment.ownership.previous.value -eq "$baseEntry;$keepEntry") 'the package record lost the previous PSModulePath value'
    $probe1 = Import-InNewPowerShell $moduleName
    if ($null -ne $probe1) {
        Assert-True ((Path-Has (Path-Entries $probe1.path) $modulesDirectory)) "a new PowerShell process did not read the new PSModulePath: $($probe1.path)"
        Assert-True ($probe1.module.Name -eq $moduleName) "Import-Module reported another module: $($probe1.raw)"
        Assert-True ($probe1.module.Version.Major -eq 1 -and $probe1.module.Version.Minor -eq 0) "Import-Module loaded the wrong module version: $($probe1.raw)"
        Assert-True (([string]$probe1.module.ModuleBase).TrimEnd('\') -ieq $moduleLink) "Import-Module resolved the module outside the shared link: $($probe1.module.ModuleBase)"
    }

    # --- Update moves the module content with current and does not duplicate the entry ------------
    Write-Manifest $package '2.0.0' $moduleName
    $updatePreview = CoopJson @('--root',$root,'update',$package,'--dry-run','--json')
    $updateOperations = @($updatePreview.ir_operations | ForEach-Object operation)
    Assert-True ('remove-ps-module' -in $updateOperations -and 'ps-module' -in $updateOperations) "update preview omitted the module operations: $($updateOperations -join ',')"
    $update = CoopJson @('--root',$root,'update',$package,'--json')
    Assert-True ($update.status -eq 'success') "psmodule update did not succeed: $($update | ConvertTo-Json -Depth 4)"
    $updateJournal = Get-Content -LiteralPath $update.journal -Raw | ConvertFrom-Json
    Assert-True ((@($updatePreview.ir_operations | ForEach-Object operation) -join ',') -eq (@($updateJournal.observed_steps) -join ',')) 'the update did not follow its displayed plan'
    Assert-True ((Get-Item -LiteralPath $moduleLink -Force).LinkType -eq 'Junction') 'the update removed the module junction'
    $updatedPath = (Get-UserRaw 'PSModulePath').value
    Assert-True (@(Path-Entries $updatedPath | Where-Object { $_.TrimEnd('\') -ieq $modulesDirectory.TrimEnd('\') }).Count -eq 1) "the update duplicated the PSModulePath entry: $updatedPath"
    Assert-PathHas $updatedPath $baseEntry 'the update removed an existing PSModulePath entry'
    $probe2 = Import-InNewPowerShell $moduleName
    if ($null -ne $probe2) {
        Assert-True ($probe2.module.Version.Major -eq 2) "the module link did not switch to the updated version: $($probe2.raw)"
        Assert-True ($probe2.module.ModuleBase -ieq $moduleLink) 'the updated module resolved outside the shared link'
    }

    # --- A user edit after install survives the uninstall ----------------------------------------
    Set-UserRaw 'PSModulePath' ($updatedPath.TrimEnd(';')+';'+$userEntry) ((Get-UserRaw 'PSModulePath').kind)
    $uninstallPreview = CoopJson @('--root',$root,'uninstall',$package,'--dry-run','--json')
    Assert-True ($uninstallPreview.ps_module.operation -eq 'remove') 'the uninstall preview did not describe the module link removal'
    Assert-True ($uninstallPreview.ps_module.user_environment.variable -eq 'PSModulePath') 'the uninstall preview omitted the PSModulePath effect'
    Assert-True ('remove-ps-module' -in @($uninstallPreview.ir_operations | ForEach-Object operation)) 'the uninstall preview omitted the module removal operation'
    $uninstall = CoopJson @('--root',$root,'uninstall',$package,'--json')
    Assert-True ($uninstall.status -eq 'success') "psmodule uninstall did not succeed: $($uninstall | ConvertTo-Json -Depth 4)"
    Assert-True (-not (Test-Path -LiteralPath $moduleLink)) 'the uninstall left the module junction behind'
    $afterPath = (Get-UserRaw 'PSModulePath').value
    Assert-PathMissing $afterPath $modulesDirectory 'the uninstall left the entry Coop added'
    Assert-PathHas $afterPath $baseEntry 'the uninstall removed another PSModulePath entry'
    Assert-PathHas $afterPath $keepEntry 'the uninstall removed another PSModulePath entry'
    Assert-PathHas $afterPath $userEntry 'the uninstall removed a user entry added after the install'
    Assert-True (-not (Test-Path -LiteralPath "$root/apps/$package/current")) 'the uninstall left the package current link'

    # --- An unmodified PSModulePath is restored exactly -----------------------------------------
    Set-UserRaw 'PSModulePath' "$baseEntry;$keepEntry" 'String'
    Write-Manifest $package '3.0.0' $moduleName
    $second = CoopJson @('--root',$root,'install',"test/$package",'--json')
    Assert-True ($second.status -eq 'success') 'the second psmodule install did not succeed'
    Assert-True (Test-Path -LiteralPath $moduleLink) 'the second install did not create the module junction'
    $secondUninstall = CoopJson @('--root',$root,'uninstall',$package,'--json')
    Assert-True ($secondUninstall.status -eq 'success') 'the second psmodule uninstall did not succeed'
    $restored = Get-UserRaw 'PSModulePath'
    Assert-True ($restored.present -eq $true -and $restored.value -eq "$baseEntry;$keepEntry" -and $restored.kind -eq 'String') `
        "the uninstall did not restore the recorded PSModulePath value: present=$($restored.present) kind=$($restored.kind) value=$($restored.value)"

    # --- A stray non-link entry under modules does not keep Coop's PSModulePath entry -----------
    New-Item -ItemType Directory -Path $modulesDirectory -Force | Out-Null
    $stray = Join-Path $modulesDirectory 'stray.txt'
    [IO.File]::WriteAllText($stray,'not a module link',[Text.UTF8Encoding]::new($false))
    Write-Manifest $package '4.0.0' $moduleName
    $strayInstall = CoopJson @('--root',$root,'install',"test/$package",'--json')
    Assert-True ($strayInstall.status -eq 'success') 'the stray-entry install did not succeed'
    $strayUninstall = CoopJson @('--root',$root,'uninstall',$package,'--json')
    Assert-True ($strayUninstall.status -eq 'success') 'the stray-entry uninstall did not succeed'
    $strayPath = (Get-UserRaw 'PSModulePath').value
    Assert-PathMissing $strayPath $modulesDirectory 'a stray file under modules kept the PSModulePath entry'
    Assert-PathHas $strayPath $baseEntry 'the stray-entry uninstall removed an existing entry'
    Assert-True (Test-Path -LiteralPath $stray) 'the uninstall removed a stray file under modules'

    # --- An invalid psmodule declaration is a blocking adapter diagnostic -----------------------
    $invalidPackage = 'coop-r25-invalid-'+$tag
    $invalidArchive = Join-Path $session "$package-1.0.0.zip"
    $invalidManifest = [ordered]@{
        version='1.0.0'
        url=(File-Uri $invalidArchive)
        hash=(Get-FileHash -LiteralPath $invalidArchive -Algorithm SHA256).Hash.ToLower()
        psmodule=$true
    }
    [IO.File]::WriteAllText("$root/buckets/test/bucket/$invalidPackage.json",($invalidManifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $environmentBeforeInvalid = Get-UserRaw 'PSModulePath'
    $invalidPreview = Invoke-Coop @('--root',$root,'install',"test/$invalidPackage",'--dry-run','--json')
    $invalidDocument = $invalidPreview.text | ConvertFrom-Json
    $invalidCodes = @($invalidDocument.diagnostics | ForEach-Object { "$($_.category)/$($_.code)" })
    Assert-True ($invalidDocument.execution_available -eq $false) 'an invalid psmodule declaration was planned as executable'
    Assert-True ($invalidCodes -contains 'adapter/manifest-shape') "the invalid psmodule declaration did not report adapter/manifest-shape: $($invalidCodes -join ',')"
    $invalidInstall = Invoke-Coop @('--root',$root,'install',"test/$invalidPackage",'--json')
    Assert-True ($invalidInstall.code -ne 0) 'an invalid psmodule declaration was executed'
    Assert-True (-not (Test-Path -LiteralPath "$root/apps/$invalidPackage")) 'an invalid psmodule declaration created a package directory'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $modulesDirectory 'true'))) 'an invalid psmodule declaration created a module link'
    $environmentAfterInvalid = Get-UserRaw 'PSModulePath'
    Assert-True ($environmentAfterInvalid.value -eq $environmentBeforeInvalid.value) 'an invalid psmodule declaration changed PSModulePath'

    # --- A package without psmodule leaves PSModulePath alone ------------------------------------
    $environmentBeforePlain = Get-UserRaw 'PSModulePath'
    $plain = CoopJson @('--root',$root,'install',"test/$plainPackage",'--json')
    Assert-True ($plain.status -eq 'success') 'the plain package did not install'
    $environmentAfterPlain = Get-UserRaw 'PSModulePath'
    Assert-True ($environmentAfterPlain.value -eq $environmentBeforePlain.value) 'a package without psmodule changed PSModulePath'
    $plainUninstall = CoopJson @('--root',$root,'uninstall',$plainPackage,'--json')
    Assert-True ($plainUninstall.status -eq 'success') 'the plain package did not uninstall'
    Assert-True ((Get-UserRaw 'PSModulePath').value -eq $environmentBeforePlain.value) 'a package without psmodule changed PSModulePath on uninstall'

    # --- psmodule combined with bin and a post_install hook is planned and executable ------------
    $combinedArchive = Join-Path $session "$combinedPackage.zip"
    New-ZipPackage $combinedArchive ([ordered]@{ "$moduleName.psd1"="@{`n    ModuleVersion = '1.0.0'`n}`n"; 'tool.cmd'="@echo off`r`necho combined`r`n" })
    $combinedManifest = [ordered]@{
        version='1.0.0'
        url=(File-Uri $combinedArchive)
        hash=(Get-FileHash -LiteralPath $combinedArchive -Algorithm SHA256).Hash.ToLower()
        bin=@(,@('tool.cmd'))
        psmodule=[ordered]@{ name = $moduleName }
        post_install='Write-Output "combined post_install"'
    }
    [IO.File]::WriteAllText("$root/buckets/test/bucket/$combinedPackage.json",($combinedManifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $modulesBeforeCombined = if (Test-Path -LiteralPath $modulesDirectory) { @(Get-ChildItem -LiteralPath $modulesDirectory -Force | ForEach-Object { $_.Name }) } else { @() }
    $combinedPreview = CoopJson @('--root',$root,'install',"test/$combinedPackage",'--dry-run','--json')
    Assert-True ($combinedPreview.execution_available -eq $true) "combined psmodule+bin+post_install preview was blocked: $($combinedPreview.diagnostics | ConvertTo-Json -Compress)"
    $combinedOperations = @($combinedPreview.ir_operations | ForEach-Object operation)
    foreach ($expected in 'hook','entries','ps-module') { Assert-True ($expected -in $combinedOperations) "combined preview omitted $expected`: $($combinedOperations -join ',')" }
    $modulesAfterCombined = if (Test-Path -LiteralPath $modulesDirectory) { @(Get-ChildItem -LiteralPath $modulesDirectory -Force | ForEach-Object { $_.Name }) } else { @() }
    Assert-True (($modulesBeforeCombined -join '|') -eq ($modulesAfterCombined -join '|')) 'the combined preview changed the modules directory'

    @{ root=$root; module=$moduleName; link=$moduleLink; operations=$operations } | ConvertTo-Json -Depth 4 |
        Set-Content (Join-Path $TestRoot 'psmodule-evidence.json') -Encoding utf8
    Write-Output 'PASS psmodule preview, junction, PSModulePath ownership, update and uninstall restoration'
} finally {
    Restore-UserRaw 'PSModulePath' $original
}

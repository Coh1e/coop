param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$EvidenceDir,
    [Parameter(Mandatory)][string]$Package,
    [string]$ScoopRoot = (Join-Path $env:USERPROFILE 'scoop'),
    [string]$ModuleName = '',
    [string]$ExtraPreviewPackages = '',
    [switch]$SkipScoopList
)
# Real psmodule (PowerShell module) lifecycle (R25 / #46).
#
# Runs the real CLI against the selected installation root: read-only preview, install, a new
# PowerShell process that reads the current user environment block and imports the module, the
# other client's recognition of the same installation, and the removal of the junction plus only
# the PSModulePath entry Coop itself recorded. `Package` is a qualified request such as
# `extras/posh-git` or `main/gsudo`. The current user's PSModulePath and Path are snapshotted and
# restored in a finally block so a failed run does not leave the human's environment changed.
#
# `-SkipScoopList` is for a project-local compatible root: this machine's Scoop installation only
# manages its own root, so recognition there is proven by reading <root>/modules instead.
$ErrorActionPreference = 'Stop'
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$ScoopRoot = [IO.Path]::GetFullPath($ScoopRoot).TrimEnd('\')
if ($Package -notmatch '^([^/]+)/([^/]+)$') { throw 'Package must be qualified as bucket/name' }
$bucket = $Matches[1]
$packageName = $Matches[2]
$manifestPath = Join-Path $ScoopRoot "buckets/$bucket/bucket/$packageName.json"
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Package Manifest not found: $manifestPath" }
if (-not $ModuleName) {
    $ModuleName = (Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).psmodule.name
    if (-not $ModuleName) { throw "$Package does not declare psmodule" }
}
$modulesDirectory = Join-Path $ScoopRoot 'modules'
$moduleLink = Join-Path $modulesDirectory $ModuleName
$coopRecord = Join-Path $ScoopRoot ".coop/packages/$packageName.json"
$commands = [System.Collections.Generic.List[object]]::new()
$installedByTest = $false
function Run([string]$name,[string]$exe,[string[]]$arguments) {
    $log = Join-Path $EvidenceDir (($name -replace '[\\/:*?"<>|]','-')+'.log')
    $output = & $exe @arguments *>&1 | Out-String
    $exit = $LASTEXITCODE
    Set-Content -LiteralPath $log -Value $output -Encoding utf8
    $commands.Add([pscustomobject]@{name=$name;exe=$exe;arguments=$arguments;exit=$exit;log=$log})
    return [pscustomobject]@{exit=$exit;output=$output;log=$log}
}
function Coop([string]$name,[string[]]$arguments) { return Run $name $CoopExe (@('--root',$ScoopRoot)+$arguments) }
function Assert-True([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
function Read-Json([object]$output) { return (($output -join "`n") | ConvertFrom-Json) }
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
    try { $key.SetValue($name,$value,[Microsoft.Win32.RegistryValueKind]$kind) } finally { $key.Dispose() }
}
function Remove-UserValue([string]$name) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$true)
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
    if (-not (Path-Has (Path-Entries $path) $entry)) { throw "$message`nvalue=$path" }
}
function Assert-PathMissing([string]$path,[string]$entry,[string]$message) {
    if (Path-Has (Path-Entries $path) $entry) { throw "$message`nvalue=$path" }
}
function Assert-Junction([string]$link,[string]$target) {
    Assert-True (Test-Path -LiteralPath $link) "missing junction: $link"
    $item = Get-Item -LiteralPath $link -Force
    Assert-True ($item.LinkType -eq 'Junction') "path is not a junction: $link ($($item.LinkType))"
    $actual = [string](@($item.Target)[0])
    Assert-True ($actual.TrimEnd('\') -ieq $target.TrimEnd('\')) "junction target is $actual, expected $target"
}
function Import-InNewPowerShell([string]$module) {
    $probe = Join-Path $EvidenceDir 'module-probe.ps1'
    $out = Join-Path $EvidenceDir 'module-probe.json'
    $escaped = $out.Replace("'","''")
    [IO.File]::WriteAllText($probe,@"
`$module = Import-Module '$module' -PassThru | Select-Object -First 1
`$result = [pscustomobject]@{ path = `$env:PSModulePath; module = (`$module | Select-Object Name,Version,ModuleBase) }
[IO.File]::WriteAllText('$escaped',(`$result | ConvertTo-Json -Depth 4 -Compress),[Text.UTF8Encoding]::new(`$false))
"@,[Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath pwsh -ArgumentList ('-NoProfile -NonInteractive -File "{0}"' -f $probe) -UseNewEnvironment -Wait -PassThru `
        -RedirectStandardOutput ($out+'.stdout.log') -RedirectStandardError ($out+'.err')
    $text = if (Test-Path -LiteralPath $out) { Get-Content -LiteralPath $out -Raw } else { '' }
    $errorText = if (Test-Path -LiteralPath ($out+'.err')) { Get-Content -LiteralPath ($out+'.err') -Raw } else { '' }
    Set-Content -LiteralPath (Join-Path $EvidenceDir 'module-probe.raw.log') -Value ($text+"`n"+$errorText) -Encoding utf8
    $commands.Add([pscustomobject]@{name='import-module-new-powershell';exe='pwsh';arguments=@('-NoProfile','-File',$probe);exit=$process.ExitCode;log=(Join-Path $EvidenceDir 'module-probe.raw.log')})
    Assert-True ($process.ExitCode -eq 0) "Import-Module $module failed in a new PowerShell process (exit $($process.ExitCode)):`n$text`n$errorText"
    $result = $text | ConvertFrom-Json
    return [pscustomobject]@{path=[string]$result.path;module=$result.module;raw=$text}
}
$psmodulePathBefore = Get-UserRaw 'PSModulePath'
$pathBefore = Get-UserRaw 'Path'
$summary = [ordered]@{
    package = $Package
    module = $ModuleName
    scoop_root = $ScoopRoot
    psmodulepath_before = $psmodulePathBefore
    path_before = $pathBefore
    modules_directory_before = (Test-Path -LiteralPath $modulesDirectory)
    started = (Get-Date).ToUniversalTime().ToString('o')
}
try {
    $coopVersion = (Run 'coop-version' $CoopExe @('--version')).output.Trim()
    $summary.coop_version = $coopVersion
    $bucketHead = (& git -C (Join-Path $ScoopRoot "buckets/$bucket") rev-parse HEAD 2>&1 | Out-String).Trim()
    $summary.bucket_revision = $bucketHead
    $scoopVersionOutput = if ($SkipScoopList) { '' } else { (Run 'scoop-version' (Get-Command scoop.ps1 -ErrorAction Stop).Source @('--version')).output }
    if ($scoopVersionOutput) { $summary.scoop_version = (@(($scoopVersionOutput -split "`r?`n") | Where-Object { $_ -match '^v\d' })[0]).Trim() }
    if (Test-Path -LiteralPath $coopRecord) { throw "$packageName already has a Coop record; refusing to change the selected root" }

    # --- Preview: the same operations, no junction and no environment write ---------------------
    $preview = Coop 'preview' @('install',$Package,'--dry-run','--json')
    Assert-True ($preview.exit -eq 0) "real psmodule preview failed: $($preview.output)"
    $plan = Read-Json $preview.output
    Assert-True ($plan.execution_available -eq $true) "real psmodule preview was blocked: $($plan.diagnostics | ConvertTo-Json -Compress)"
    $operations = @($plan.ir_operations | ForEach-Object operation)
    Assert-True ('ps-module' -in $operations) "preview omitted the ps-module operation: $($operations -join ',')"
    Assert-True ($plan.ps_module.name -eq $ModuleName) 'preview lost the declared module name'
    Assert-True ($plan.ps_module.link -eq $moduleLink) "preview reported the wrong module link: $($plan.ps_module.link)"
    Assert-True ($plan.ps_module.target -eq (Join-Path $ScoopRoot "apps/$packageName/current")) 'preview did not target apps/<package>/current'
    Assert-True (-not (Test-Path -LiteralPath $moduleLink)) 'preview created the module junction'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $ScoopRoot "apps/$packageName"))) 'preview created the package directory'
    $previewEnvironment = Get-UserRaw 'PSModulePath'
    Assert-True ($previewEnvironment.value -eq $psmodulePathBefore.value -and $previewEnvironment.kind -eq $psmodulePathBefore.kind) 'preview changed PSModulePath'

    # --- Install and verified module visibility -------------------------------------------------
    $install = Coop 'install' @('install',$Package,'--json')
    Assert-True ($install.exit -eq 0) "real psmodule install failed: $($install.output)"
    $installedByTest = $true
    $result = Read-Json $install.output
    Assert-True ($result.status -eq 'success') "install did not report success: $($install.output)"
    $journal = Get-Content -LiteralPath $result.journal -Raw | ConvertFrom-Json
    Assert-True ((@($plan.ir_operations | ForEach-Object operation) -join ',') -eq (@($journal.observed_steps) -join ',')) `
        "execution did not follow the displayed plan: planned=$(@($plan.ir_operations | ForEach-Object operation) -join ',') observed=$(@($journal.observed_steps) -join ',')"
    Assert-True ($journal.ps_module.junction -eq 'created') 'journal omitted the created module junction'
    Assert-True ($journal.ps_module.user_environment.status -eq 'added') 'journal omitted the PSModulePath write'
    Assert-Junction $moduleLink (Join-Path $ScoopRoot "apps/$packageName/current")
    $installedPath = (Get-UserRaw 'PSModulePath').value
    Assert-PathHas $installedPath $modulesDirectory 'install did not add the modules directory to PSModulePath'
    foreach ($entry in @(Path-Entries $psmodulePathBefore.value)) { Assert-PathHas $installedPath $entry 'install removed an existing PSModulePath entry' }
    $record = Get-Content -LiteralPath $coopRecord -Raw | ConvertFrom-Json
    Assert-True ($record.psmodule.name -eq $ModuleName) 'the package record omitted the module name'
    Assert-True ((Path-Has @($record.psmodule.user_environment.ownership.added) $modulesDirectory)) 'the package record omitted the PSModulePath entry Coop added'
    Assert-True ($record.psmodule.user_environment.ownership.previous.value -eq $psmodulePathBefore.value -and
        $record.psmodule.user_environment.ownership.previous.present -eq $psmodulePathBefore.present) 'the package record lost the previous PSModulePath value'
    $probe = Import-InNewPowerShell $ModuleName
    Assert-True ((Path-Has (Path-Entries $probe.path) $modulesDirectory)) "a new PowerShell process did not read the new PSModulePath: $($probe.path)"
    Assert-True ($probe.module.Name -eq $ModuleName) "Import-Module reported another module: $($probe.raw)"
    Assert-True (([string]$probe.module.ModuleBase).TrimEnd('\') -ieq $moduleLink) "Import-Module resolved outside the shared link: $($probe.module.ModuleBase)"
    $summary.module = $probe.module

    # --- The other client and the shared directory see the same module --------------------------
    $exposed = Get-Item -LiteralPath $moduleLink -Force
    Assert-True ($exposed.LinkType -eq 'Junction') 'the shared modules directory does not expose the installed module'
    if (-not $SkipScoopList) {
        $scoopList = Run 'scoop-list' (Get-Command scoop.ps1 -ErrorAction Stop).Source @('list')
        Assert-True ($scoopList.exit -eq 0) "scoop list failed: $($scoopList.output)"
        Assert-True (($scoopList.output -split "`r?`n" | Where-Object { $_ -match ('^\s*'+[regex]::Escape($packageName)+'\s') }).Count -ge 1) `
            "Scoop did not list the Coop-installed package: $($scoopList.output)"
    }

    # --- Dependent packages no longer cascade on an unsupported dependency ----------------------
    foreach ($request in @($ExtraPreviewPackages -split ',' | Where-Object { $_ })) {
        $request = $request.Trim()
        $dependent = Coop ('preview-'+($request -replace '[\\/:*?"<>|]','-')) @('install',$request,'--dry-run','--json')
        Assert-True ($dependent.exit -eq 0) "dependent preview for $request failed: $($dependent.output)"
        $dependentPlan = Read-Json $dependent.output
        Assert-True ($dependentPlan.execution_available -eq $true) "dependent preview for $request stayed blocked: $($dependentPlan.diagnostics | ConvertTo-Json -Compress)"
        $codes = @($dependentPlan.diagnostics | ForEach-Object code)
        Assert-True ('dependency-unsupported' -notin $codes -and 'unsupported-capability' -notin $codes) "dependent preview for $request still cascades: $($codes -join ',')"
        Assert-True (@($dependentPlan.dependency_order | Where-Object { $_.package -eq $packageName -and $_.installed -eq $true }).Count -eq 1) "dependent preview for $request did not reuse the installed module package"
    }

    # --- Uninstall removes the junction and only the entry Coop recorded ------------------------
    $uninstall = Coop 'uninstall' @('uninstall',$packageName,'--json')
    Assert-True ($uninstall.exit -eq 0) "real psmodule uninstall failed: $($uninstall.output)"
    $installedByTest = $false
    $uninstallResult = Read-Json $uninstall.output
    Assert-True ($uninstallResult.status -eq 'success') 'uninstall did not report success'
    Assert-True (-not (Test-Path -LiteralPath $moduleLink)) 'the uninstall left the module junction behind'
    $restoredPath = Get-UserRaw 'PSModulePath'
    Assert-True ($restoredPath.present -eq $psmodulePathBefore.present) "uninstall did not restore PSModulePath presence: $($restoredPath.present)"
    Assert-True ($restoredPath.kind -eq $psmodulePathBefore.kind) "uninstall did not restore the PSModulePath value kind: $($restoredPath.kind)"
    Assert-True ($restoredPath.value -eq $psmodulePathBefore.value) "uninstall did not restore the recorded PSModulePath value: $($restoredPath.value)"
    $restoredPathValue = (Get-UserRaw 'Path')
    Assert-True ($restoredPathValue.present -eq $pathBefore.present -and $restoredPathValue.value -eq $pathBefore.value) 'uninstall did not restore the recorded user Path value'
    if (-not $SkipScoopList) {
        $scoopListAfter = Run 'scoop-list-after' (Get-Command scoop.ps1 -ErrorAction Stop).Source @('list')
        Assert-True ($scoopListAfter.exit -eq 0) "scoop list failed after uninstall: $($scoopListAfter.output)"
        Assert-True (($scoopListAfter.output -split "`r?`n" | Where-Object { $_ -match ('^\s*'+[regex]::Escape($packageName)+'\s') }).Count -eq 0) `
            "Scoop still lists the uninstalled package: $($scoopListAfter.output)"
    }
    $summary.status = 'passed'
} catch {
    $summary.status = 'failed'
    $summary.error = $_.Exception.Message
    throw
} finally {
    # Restore the human's environment and remove a package a failed run left behind. The direct
    # registry restore is test scaffolding for a failed run, not a product operation.
    if ($installedByTest) {
        try { & $CoopExe --root $ScoopRoot uninstall $packageName --json *> (Join-Path $EvidenceDir 'cleanup-uninstall.log') } catch { }
    }
    $current = Get-UserRaw 'PSModulePath'
    if ($current.value -ne $psmodulePathBefore.value -or $current.present -ne $psmodulePathBefore.present -or $current.kind -ne $psmodulePathBefore.kind) {
        Restore-UserRaw 'PSModulePath' $psmodulePathBefore
        $summary.psmodulepath_restored = 'snapshot'
    }
    $currentPath = Get-UserRaw 'Path'
    if ($currentPath.value -ne $pathBefore.value -or $currentPath.present -ne $pathBefore.present -or $currentPath.kind -ne $pathBefore.kind) {
        Restore-UserRaw 'Path' $pathBefore
        $summary.path_restored = 'snapshot'
    }
    $summary.commands = $commands
    $summary.psmodulepath_after = Get-UserRaw 'PSModulePath'
    $summary.path_after = Get-UserRaw 'Path'
    $summary.finished = (Get-Date).ToUniversalTime().ToString('o')
    $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $EvidenceDir 'summary.json') -Encoding utf8
}
Write-Output "PASS real psmodule lifecycle for $Package (module $ModuleName) on $ScoopRoot"

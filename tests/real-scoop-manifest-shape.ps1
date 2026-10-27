param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$EvidenceDir,
    [string]$ScoopRoot = (Join-Path $env:USERPROFILE 'scoop'),
    [string]$InventoryRoot = '',
    [string]$PythonHost = '',
    [switch]$InventoryOnly
)
# R27/#48 real-machine acceptance. Two independent measurements in one bounded session:
#  1. the six Manifest-shape packages are planned on the project-local full Main/Extras inventory
#     root at the pinned revisions and every planned bin argument, env_add_path value and shortcut
#     is compared item by item with the pinned Scoop 0.6.0 semantics (create_shims, env_add_path,
#     create_startmenu_shortcuts);
#  2. wgcf, zigup and lessmsi are installed, run and removed in the human-selected shared Scoop
#     root, alternating with the real Scoop client, then the original installation list and raw
#     user Path are verified unchanged.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
$allowed = [IO.Path]::GetFullPath((Join-Path $projectRoot '.local')).TrimEnd('\') + '\'
if (-not ($EvidenceDir.TrimEnd('\') + '\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence must stay inside the project .local directory' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$ScoopRoot = [IO.Path]::GetFullPath($ScoopRoot)
if (-not $InventoryRoot) { $InventoryRoot = Join-Path $projectRoot '.local/coverage/root' }
$InventoryRoot = [IO.Path]::GetFullPath($InventoryRoot)
if (-not ($InventoryRoot.TrimEnd('\') + '\').StartsWith($projectRoot.TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'InventoryRoot must stay inside the project directory' }
if (-not (Test-Path -LiteralPath $CoopExe)) { throw "Coop executable not found: $CoopExe" }
if (-not (Test-Path -LiteralPath $ScoopRoot)) { throw "Shared Scoop root not found: $ScoopRoot" }
if (-not (Test-Path -LiteralPath $InventoryRoot)) { throw "Inventory root not found: $InventoryRoot" }
$scoop = (Get-Command scoop.ps1 -ErrorAction Stop).Source
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$commands = [System.Collections.Generic.List[object]]::new()
function Write-Text([string]$path,[string]$text) { [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false)) }
function Run([string]$name,[string]$exe,[string[]]$arguments) {
    $log = Join-Path $EvidenceDir (($name -replace '[\\/:*?"<>|]','-') + '.log')
    $output = & $exe @arguments *>&1 | Out-String
    $exit = $LASTEXITCODE
    Write-Text $log $output
    $commands.Add([ordered]@{name=$name;exe=$exe;arguments=$arguments;exit=$exit;log=[IO.Path]::GetFileName($log)})
    return [pscustomobject]@{exit=$exit;output=$output;log=$log}
}
function Coop([string]$name,[string[]]$arguments) { return Run $name $CoopExe (@('--root',$ScoopRoot) + $arguments) }
function Scoop([string]$name,[string[]]$arguments) { return Run $name $scoop $arguments }
function Read-Json([string]$text) { return ($text | ConvertFrom-Json) }
function Assert-True([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
function HashOf([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function Get-RawUserPath {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    try { if ($null -eq $key) { return $null }; return [string]$key.GetValue('Path',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    finally { if ($key) { $key.Dispose() } }
}
function ShortcutOf([string]$link) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
    return [pscustomobject]@{target=$shortcut.TargetPath;arguments=$shortcut.Arguments;working_directory=$shortcut.WorkingDirectory;
        icon=$(if ($shortcut.IconLocation) { ($shortcut.IconLocation -replace ',\d+$','') } else { '' })}
}
function Read-ShimArguments([string]$alias) {
    $path = Join-Path $ScoopRoot "shims/$alias.shim"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $line = @(Get-Content -LiteralPath $path | Where-Object { $_ -match '^args = ' }) | Select-Object -First 1
    if (-not $line) { return '' }
    return ($line -replace '^args = ','')
}
function Test-Installed([string]$name) {
    $entry = @((& $CoopExe --root $ScoopRoot list --json | Out-String | ConvertFrom-Json) | Where-Object { $_.name -eq $name -and $_.status -ne 'uninstalled' })
    return $entry.Count -gt 0
}
function Get-ScoopExportApps {
    $export = (& $scoop export 2>&1 | Out-String) | ConvertFrom-Json
    return @(@($export.apps) | ForEach-Object { "$($_.Name)@$($_.Version)" } | Sort-Object)
}
function Test-ScoopInstalled([string]$name) {
    return @((Get-ScoopExportApps) | Where-Object { $_ -match ('^' + [regex]::Escape($name) + '@') }).Count -gt 0
}
function Find-PythonHost {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($PythonHost) { $candidates.Add($PythonHost) }
    $command = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($command) { $candidates.Add($command.Source) }
    $toolRoot = Join-Path $projectRoot '.local/tools/python'
    if (Test-Path -LiteralPath $toolRoot) {
        foreach ($item in @(Get-ChildItem -LiteralPath $toolRoot -Directory | Sort-Object LastWriteTimeUtc -Descending)) {
            $candidates.Add((Join-Path $item.FullName 'python.exe'))
        }
    }
    foreach ($candidate in $candidates) {
        if (-not $candidate -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $version = (& $candidate --version 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $version -match '^Python 3\.') { return [IO.Path]::GetFullPath($candidate) }
        } catch { }
    }
    return $null
}

# --- Pinned-source Scoop 0.6.0 semantics used for the parity comparison -------------------------
# assets/scoop-lib/install.ps1:171-193 (shim_def/create_shims),
# assets/scoop-lib/install.ps1:309-318 (env_add_path), assets/scoop-lib/shortcuts.ps1:1-22.
function Test-Effective([object]$value) {
    if ($null -eq $value) { return $false }
    if ($value -is [bool]) { return $value }
    if ($value -is [string]) { return $value.Length -gt 0 }
    if ($value -is [System.Collections.IList]) { return $value.Count -gt 0 }
    return $true
}
function Convert-ScoopValue([string]$value,[string]$directory,[string]$persistDirectory) {
    return $value.Replace('$persist_dir',$persistDirectory).Replace('$original_dir',$directory).Replace('$dir',$directory)
}
function Add-ScoopCommandExpectation([System.Collections.IDictionary]$manifest,[string]$directory,[string]$persistDirectory,[System.Collections.IDictionary]$result,[string]$architecture = '64bit') {
    # The result dictionary is owned by the caller: mutating it avoids returning an enumerable
    # dictionary or a nested array through the pipeline, which would unroll both.
    $bin = $null
    if ($manifest.Contains('architecture') -and $manifest['architecture'] -is [System.Collections.IDictionary] -and
        $manifest['architecture'].Contains($architecture) -and $manifest['architecture'][$architecture] -is [System.Collections.IDictionary]) {
        $bin = $manifest['architecture'][$architecture]['bin']
    }
    if (-not (Test-Effective $bin) -and $manifest.Contains('bin')) { $bin = $manifest['bin'] }
    if ($null -eq $bin) { return }
    # Iterate the value directly: @($value) recursively flattens a nested bin tuple list.
    foreach ($item in $bin) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) {
            $target = $item
            $name = [IO.Path]::GetFileNameWithoutExtension($target)
            $arguments = ''
        } else {
            $parts = $item
            $target = [string]$parts[0]
            $name = if ($parts.Count -gt 1) { [string]$parts[1] } else { [IO.Path]::GetFileNameWithoutExtension($target) }
            $arguments = if ($parts.Count -gt 2) { (@($parts[2..($parts.Count-1)]) -join ' ') } else { '' }
        }
        # create_shims publishes in declaration order; the last declaration of a name wins.
        $result[$name.ToLowerInvariant()] = [pscustomobject]@{
            target=$target; name=$name; arguments=(Convert-ScoopValue $arguments $directory $persistDirectory)
        }
    }
}
function Get-ScoopLauncher([string]$target) {
    $extension = [IO.Path]::GetExtension($target).ToLowerInvariant()
    switch ($extension) {
        '.exe' { return 'direct' }
        '.com' { return 'direct' }
        '.bat' { return 'cmd' }
        '.cmd' { return 'cmd' }
        '.ps1' { return 'powershell' }
        '.jar' { return 'java' }
        '.py' { return 'python' }
        default { return 'bash' }
    }
}
function Add-ScoopPathExpectation([System.Collections.IDictionary]$manifest,[string]$directory,[System.Collections.Generic.List[string]]$result,[string]$architecture = '64bit') {
    $values = $null
    if ($manifest.Contains('architecture') -and $manifest['architecture'] -is [System.Collections.IDictionary] -and
        $manifest['architecture'].Contains($architecture) -and $manifest['architecture'][$architecture] -is [System.Collections.IDictionary]) {
        $values = $manifest['architecture'][$architecture]['env_add_path']
    }
    if (-not (Test-Effective $values) -and $manifest.Contains('env_add_path')) { $values = $manifest['env_add_path'] }
    if ($null -eq $values) { return }
    foreach ($item in $values) {
        if (-not $item) { continue }
        $resolved = [IO.Path]::GetFullPath((Join-Path $directory ([string]$item)))
        $base = $directory.TrimEnd('\')
        if ($resolved.TrimEnd('\') -ieq $base -or $resolved.StartsWith($base + '\',[StringComparison]::OrdinalIgnoreCase)) { $result.Add($resolved) }
    }
}
function Add-ScoopShortcutExpectation([System.Collections.IDictionary]$manifest,[string]$directory,[string]$persistDirectory,[System.Collections.Generic.List[object]]$result,[string]$architecture = '64bit') {
    $values = $null
    if ($manifest.Contains('architecture') -and $manifest['architecture'] -is [System.Collections.IDictionary] -and
        $manifest['architecture'].Contains($architecture) -and $manifest['architecture'][$architecture] -is [System.Collections.IDictionary]) {
        $values = $manifest['architecture'][$architecture]['shortcuts']
    }
    if (-not (Test-Effective $values) -and $manifest.Contains('shortcuts')) { $values = $manifest['shortcuts'] }
    if ($null -eq $values) { return }
    foreach ($item in $values) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) { $parts = @($item) } else { $parts = $item }
        $target = [IO.Path]::GetFullPath([IO.Path]::Combine($directory,[string]$parts[0]))
        $arguments = if ($parts.Count -ge 3) { Convert-ScoopValue ([string]$parts[2]) $directory $persistDirectory } else { '' }
        $icon = if ($parts.Count -ge 4) { [IO.Path]::GetFullPath([IO.Path]::Combine($directory,[string]$parts[3])) } else { '' }
        $result.Add([pscustomobject]@{name=[string]$parts[1];target=$target;arguments=$arguments;icon=$icon})
    }
}

$python = Find-PythonHost
Assert-True ($null -ne $python) 'A real Python 3 host is required to plan retdec, whose .py entries need python.exe on PATH'
$pythonPath = (Split-Path $python -Parent) + ';' + $env:PATH

# --- Preconditions and versions ----------------------------------------------------------------
$testPackages = [ordered]@{wgcf='main';zigup='main';lessmsi='main'}
foreach ($name in $testPackages.Keys) {
    Assert-True (-not (Test-Installed $name)) "The shared root already contains $name; refusing to change it"
    Assert-True (-not (Test-ScoopInstalled $name)) "Scoop already lists $name in the shared root; refusing to change it"
}
$rawPathBefore = Get-RawUserPath
$coopListBefore = @((& $CoopExe --root $ScoopRoot list --json | Out-String | ConvertFrom-Json) | ForEach-Object { "$($_.name)@$($_.version)" } | Sort-Object)
$scoopListBefore = Get-ScoopExportApps
$sharedMain = Join-Path $ScoopRoot 'buckets/main'
$versions = [ordered]@{
    generated_at = [DateTime]::UtcNow.ToString('o')
    project_head = (& git -C $projectRoot rev-parse HEAD | Out-String).Trim()
    coop = (& $CoopExe --version | Out-String).Trim()
    coop_sha256 = HashOf $CoopExe
    powershell = $PSVersionTable.PSVersion.ToString()
    scoop_root = $ScoopRoot
    scoop_version = (@(((& $scoop --version 2>&1 | Out-String) -split "`r?`n") | Where-Object { $_ -match '^v\d' }) | Select-Object -First 1)
    shared_main_revision = (& git -C $sharedMain rev-parse HEAD | Out-String).Trim()
    inventory_main_revision = (& git -C (Join-Path $InventoryRoot 'buckets/main') rev-parse HEAD | Out-String).Trim()
    inventory_extras_revision = (& git -C (Join-Path $InventoryRoot 'buckets/extras') rev-parse HEAD | Out-String).Trim()
    python_host = $python
}
Write-Text (Join-Path $EvidenceDir 'versions-and-commands.txt') (($versions.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n")

# --- 1. Six Manifest-shape packages on the full inventory root ---------------------------------
$inventoryCases = @(
    @{request='main/dcmtk';bucket='main';name='dcmtk';warnings=0}
    @{request='main/stdiscosrv';bucket='main';name='stdiscosrv';warnings=0}
    @{request='main/wgcf';bucket='main';name='wgcf';warnings=0}
    @{request='main/zigup';bucket='main';name='zigup';warnings=0}
    @{request='main/retdec';bucket='main';name='retdec';warnings=2}
    @{request='extras/mqtt-spy';bucket='extras';name='mqtt-spy';warnings=0}
)
$parity = [ordered]@{}
# The inventory root runs with a child PATH that contains the project-local Python 3 host: retdec
# declares .py entries, and the fixed Scoop branch runs them through python.exe. This is an
# environment premise, not a product capability claim; it is recorded in the evidence.
$savedProcessPath = $env:PATH
$env:PATH = $pythonPath
try {
foreach ($case in $inventoryCases) {
    $name = $case.name
    $manifestPath = Join-Path $InventoryRoot ("buckets/$($case.bucket)/bucket/$name.json")
    Assert-True (Test-Path -LiteralPath $manifestPath) "Inventories Manifest missing: $manifestPath"
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    $directory = Join-Path $InventoryRoot "apps/$name/current"
    $persistDirectory = Join-Path $InventoryRoot "persist/$name"
    $preview = Run "shape-plan-$name" $CoopExe @('--root',$InventoryRoot,'install',$case.request,'--dry-run','--json')
    Assert-True ($preview.exit -eq 0) "$name preview failed with exit $($preview.exit)"
    $plan = Read-Json $preview.output
    Assert-True ([bool]$plan.execution_available) "$name is not execution_available on the inventory root"
    $nonVerification = @($plan.diagnostics | Where-Object { $_.category -ne 'verification' })
    Assert-True ($nonVerification.Count -eq 0) "$name still reports diagnostics: $($nonVerification | ConvertTo-Json -Compress)"
    Assert-True (@($plan.warnings).Count -eq $case.warnings) "$name reported $(@($plan.warnings).Count) warnings, expected $($case.warnings)"
    foreach ($warning in @($plan.warnings)) {
        Assert-True ($warning.category -eq 'adapter' -and $warning.code -eq 'duplicate-command-alias') "$name warning is '$($warning.category)/$($warning.code)'"
    }
    # bin tuples: target, derived alias, joined arguments and launcher host
    $expectedCommands = [ordered]@{}
    Add-ScoopCommandExpectation $manifest $directory $persistDirectory $expectedCommands
    $actualCommands = [ordered]@{}
    foreach ($command in @($plan.package.commands)) { $actualCommands[$command.name.ToLowerInvariant()] = $command }
    Assert-True ($expectedCommands.Count -eq $actualCommands.Count) "$name command count is $($actualCommands.Count), Scoop would create $($expectedCommands.Count)"
    foreach ($key in $expectedCommands.Keys) {
        Assert-True ($actualCommands.Contains($key)) "$name is missing command '$key'"
        $actual = $actualCommands[$key]; $expected = $expectedCommands[$key]
        Assert-True ($actual.target -eq $expected.target) "$name command '$key' target is '$($actual.target)', expected '$($expected.target)'"
        Assert-True ($actual.name -eq $expected.name) "$name command '$key' name is '$($actual.name)', expected '$($expected.name)'"
        Assert-True ($actual.arguments -eq $expected.arguments) "$name command '$key' arguments are '$($actual.arguments)', expected '$($expected.arguments)'"
        Assert-True ($actual.launcher -eq (Get-ScoopLauncher $expected.target)) "$name command '$key' launcher is '$($actual.launcher)', expected '$(Get-ScoopLauncher $expected.target)'"
    }
    # env_add_path values resolved against $dir exactly like Join-Path + Get-AbsolutePath
    $expectedPaths = [System.Collections.Generic.List[string]]::new()
    Add-ScoopPathExpectation $manifest $directory $expectedPaths
    $actualPaths = @($plan.exposure.path_entries)
    Assert-True ($expectedPaths.Count -eq $actualPaths.Count) "$name has $($actualPaths.Count) PATH entries, Scoop resolves $($expectedPaths.Count)"
    for ($index = 0; $index -lt $expectedPaths.Count; $index++) {
        Assert-True (([IO.Path]::GetFullPath($actualPaths[$index]).TrimEnd('\')) -ieq ([IO.Path]::GetFullPath($expectedPaths[$index]).TrimEnd('\'))) "$name PATH entry $index is '$($actualPaths[$index])', expected '$($expectedPaths[$index])'"
    }
    # shortcut target, arguments and icon combined with $dir and resolved as FileInfo
    $expectedShortcuts = [System.Collections.Generic.List[object]]::new()
    Add-ScoopShortcutExpectation $manifest $directory $persistDirectory $expectedShortcuts
    $actualShortcuts = @($plan.exposure.shortcuts)
    Assert-True ($expectedShortcuts.Count -eq $actualShortcuts.Count) "$name has $($actualShortcuts.Count) shortcuts, Scoop creates $($expectedShortcuts.Count)"
    for ($index = 0; $index -lt $expectedShortcuts.Count; $index++) {
        $actual = $actualShortcuts[$index]; $expected = $expectedShortcuts[$index]
        Assert-True ($actual.name -eq $expected.name) "$name shortcut $index name is '$($actual.name)', expected '$($expected.name)'"
        Assert-True (([IO.Path]::GetFullPath($actual.target)) -ieq ([IO.Path]::GetFullPath($expected.target))) "$name shortcut $index target is '$($actual.target)', expected '$($expected.target)'"
        Assert-True ($actual.arguments -eq $expected.arguments) "$name shortcut $index arguments are '$($actual.arguments)', expected '$($expected.arguments)'"
        if ($expected.icon) {
            Assert-True (([IO.Path]::GetFullPath($actual.icon)) -ieq ([IO.Path]::GetFullPath($expected.icon))) "$name shortcut $index icon is '$($actual.icon)', expected '$($expected.icon)'"
        }
    }
    $parity[$case.request] = [ordered]@{
        exit=$preview.exit; execution_available=[bool]$plan.execution_available
        commands=@($plan.package.commands); path_entries=@($plan.exposure.path_entries); shortcuts=@($plan.exposure.shortcuts)
        warnings=@($plan.warnings); expected_commands=@($expectedCommands.Values); expected_path_entries=@($expectedPaths); expected_shortcuts=@($expectedShortcuts)
        log=[IO.Path]::GetFileName($preview.log)
    }
}
} finally { $env:PATH = $savedProcessPath }
$parity | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceDir 'inventory-parity.json') -Encoding utf8
if ($InventoryOnly) {
    Write-Text (Join-Path $EvidenceDir 'versions-and-commands.txt') (($versions.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "`n")
    Write-Text (Join-Path $EvidenceDir 'commands.json') (($commands | ConvertTo-Json -Depth 6))
    Write-Output 'PASS inventory parity for the six Manifest-shape packages'
    return
}

# --- 2. Real shared-root lifecycle, alternating with Scoop -------------------------------------
$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Scoop Apps'
$msiFixture = Join-Path $projectRoot '.local/deps/test-archives/7z2605-x64.msi'
if (-not (Test-Path -LiteralPath $msiFixture)) { throw "Missing fixed MSI input: $msiFixture" }
$work = Join-Path $EvidenceDir 'work'
New-Item -ItemType Directory -Path $work -Force | Out-Null
Copy-Item -LiteralPath $msiFixture -Destination (Join-Path $work 'sample.msi') -Force
$lifecycle = [ordered]@{}
$installedByCoop = [System.Collections.Generic.HashSet[string]]::new()
$installedByScoop = [System.Collections.Generic.HashSet[string]]::new()
$sharedManifest = {
    param([string]$name)
    Get-Content -LiteralPath (Join-Path $ScoopRoot "buckets/main/bucket/$name.json") -Raw | ConvertFrom-Json -AsHashtable
}
try {
    # wgcf: multi-argument shim, Coop install -> run -> real scoop reset -> run -> Coop uninstall
    $wgcfDirectory = Join-Path $ScoopRoot 'apps/wgcf/current'
    $wgcfPersist = Join-Path $ScoopRoot 'persist/wgcf'
    $wgcfExpected = [ordered]@{}
    Add-ScoopCommandExpectation (& $sharedManifest 'wgcf') $wgcfDirectory $wgcfPersist $wgcfExpected
    $wgcfExpected = $wgcfExpected['wgcf']
    $wgcfPreview = Coop 'wgcf-preview' @('install','main/wgcf','--dry-run','--json')
    Assert-True ($wgcfPreview.exit -eq 0) "wgcf preview failed: $($wgcfPreview.output)"
    $wgcfPlan = Read-Json $wgcfPreview.output
    Assert-True ([bool]$wgcfPlan.execution_available) 'wgcf is not executable in the shared root'
    $wgcfInstall = Coop 'wgcf-install' @('install','main/wgcf','--json')
    [void]$installedByCoop.Add('wgcf')
    Assert-True ($wgcfInstall.exit -eq 0) "wgcf install failed: $($wgcfInstall.output)"
    $wgcfArgsCoop = Read-ShimArguments 'wgcf'
    Assert-True ($wgcfArgsCoop -eq $wgcfExpected.arguments) "coop wgcf shim arguments are '$wgcfArgsCoop', expected '$($wgcfExpected.arguments)'"
    $wgcfRun = Run 'wgcf-run-coop' (Join-Path $ScoopRoot 'shims/wgcf.exe') @('--help')
    Assert-True ($wgcfRun.exit -eq 0 -and $wgcfRun.output -match 'Usage' -and $wgcfRun.output -match 'wgcf') "wgcf --help through the coop shim failed: exit=$($wgcfRun.exit) output=$($wgcfRun.output)"
    $wgcfReset = Scoop 'wgcf-scoop-reset' @('reset','wgcf')
    Assert-True ($wgcfReset.exit -eq 0) "scoop reset wgcf failed: $($wgcfReset.output)"
    $wgcfArgsScoop = Read-ShimArguments 'wgcf'
    Assert-True ($wgcfArgsScoop -eq $wgcfArgsCoop) "scoop reset changed the wgcf shim arguments: '$wgcfArgsScoop' vs '$wgcfArgsCoop'"
    $wgcfRunAfter = Run 'wgcf-run-after-reset' (Join-Path $ScoopRoot 'shims/wgcf.exe') @('--help')
    Assert-True ($wgcfRunAfter.exit -eq 0 -and $wgcfRunAfter.output -match 'Usage') "wgcf after scoop reset failed: exit=$($wgcfRunAfter.exit) output=$($wgcfRunAfter.output)"
    $wgcfUninstall = Coop 'wgcf-uninstall' @('uninstall','wgcf','--json')
    [void]$installedByCoop.Remove('wgcf')
    Assert-True ($wgcfUninstall.exit -eq 0) "wgcf uninstall failed: $($wgcfUninstall.output)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $ScoopRoot 'shims/wgcf.exe')) -and -not (Test-Path -LiteralPath (Join-Path $ScoopRoot 'shims/wgcf.shim'))) 'wgcf uninstall left the shim'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $ScoopRoot 'apps/wgcf/current'))) 'wgcf uninstall left the current link'
    Assert-True (Test-Path -LiteralPath (Join-Path $wgcfPersist 'wgcf-account.toml')) 'normal uninstall removed declared persistent data'
    Assert-True (-not (Test-Installed 'wgcf')) 'Coop still lists wgcf after uninstall'
    $lifecycle.wgcf = [ordered]@{
        preview=$wgcfPlan.execution_available; shim_arguments_coop=$wgcfArgsCoop; shim_arguments_scoop=$wgcfArgsScoop
        expected_arguments=$wgcfExpected.arguments; run_coop_exit=$wgcfRun.exit; run_after_scoop_reset_exit=$wgcfRunAfter.exit
        scoop_reset_exit=$wgcfReset.exit; uninstall_exit=$wgcfUninstall.exit; persist_retained=(Test-Path -LiteralPath (Join-Path $wgcfPersist 'wgcf-account.toml'))
        plan_log=[IO.Path]::GetFileName($wgcfInstall.log)
    }

    # zigup: Scoop install -> run -> Scoop uninstall restores Path -> Coop install (env_add_path ".") -> run -> Coop uninstall
    $zigupDirectory = Join-Path $ScoopRoot 'apps/zigup/current'
    $zigupPersist = Join-Path $ScoopRoot 'persist/zigup'
    $rawPathBeforeZigup = Get-RawUserPath
    $zigupScoopInstall = Scoop 'zigup-scoop-install' @('install','zigup')
    [void]$installedByScoop.Add('zigup')
    Assert-True ($zigupScoopInstall.exit -eq 0) "scoop install zigup failed: $($zigupScoopInstall.output)"
    $zigupArgsScoop = Read-ShimArguments 'zigup'
    $zigupScoopRun = Run 'zigup-run-scoop' (Join-Path $ScoopRoot 'shims/zigup.exe') @('--help')
    Assert-True ($zigupScoopRun.exit -eq 0 -and $zigupScoopRun.output -match 'Usage') "zigup --help through the Scoop shim failed: exit=$($zigupScoopRun.exit) output=$($zigupScoopRun.output)"
    $zigupPathScoop = @((Get-RawUserPath) -split ';' | Where-Object { $_.TrimEnd('\') -ieq $zigupDirectory.TrimEnd('\') })
    Assert-True ($zigupPathScoop.Count -ge 1) "Scoop did not add '$zigupDirectory' to the user Path"
    $zigupScoopUninstall = Scoop 'zigup-scoop-uninstall' @('uninstall','zigup')
    [void]$installedByScoop.Remove('zigup')
    Assert-True ($zigupScoopUninstall.exit -eq 0) "scoop uninstall zigup failed: $($zigupScoopUninstall.output)"
    Assert-True ((Get-RawUserPath) -eq $rawPathBeforeZigup) 'scoop uninstall zigup did not restore the raw user Path'
    $zigupPreview = Coop 'zigup-preview' @('install','main/zigup','--dry-run','--json')
    Assert-True ($zigupPreview.exit -eq 0) "zigup preview failed: $($zigupPreview.output)"
    $zigupPlan = Read-Json $zigupPreview.output
    Assert-True ([bool]$zigupPlan.execution_available) 'zigup is not executable in the shared root'
    $zigupInstall = Coop 'zigup-install' @('install','main/zigup','--json')
    [void]$installedByCoop.Add('zigup')
    Assert-True ($zigupInstall.exit -eq 0) "zigup install failed: $($zigupInstall.output)"
    $zigupArgsCoop = Read-ShimArguments 'zigup'
    Assert-True ($zigupArgsCoop -eq $zigupArgsScoop) "coop zigup shim arguments are '$zigupArgsCoop', Scoop wrote '$zigupArgsScoop'"
    $zigupExpectedPath = [System.Collections.Generic.List[string]]::new()
    Add-ScoopPathExpectation (& $sharedManifest 'zigup') $zigupDirectory $zigupExpectedPath
    $zigupPathAfter = @((Get-RawUserPath) -split ';' | Where-Object { $_.TrimEnd('\') -ieq $zigupDirectory.TrimEnd('\') })
    Assert-True ($zigupPathAfter.Count -ge 1) "Coop did not add '$zigupDirectory' to the user Path (expected from env_add_path '.')"
    $zigupRun = Run 'zigup-run-coop' (Join-Path $ScoopRoot 'shims/zigup.exe') @('--help')
    Assert-True ($zigupRun.exit -eq 0 -and $zigupRun.output -match 'Usage') "zigup --help through the coop shim failed: exit=$($zigupRun.exit) output=$($zigupRun.output)"
    $zigupUninstall = Coop 'zigup-uninstall' @('uninstall','zigup','--json')
    [void]$installedByCoop.Remove('zigup')
    Assert-True ($zigupUninstall.exit -eq 0) "zigup uninstall failed: $($zigupUninstall.output)"
    Assert-True ((Get-RawUserPath) -eq $rawPathBeforeZigup) 'coop uninstall zigup did not restore the raw user Path'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $ScoopRoot 'shims/zigup.exe')) -and -not (Test-Path -LiteralPath (Join-Path $ScoopRoot 'shims/zigup.shim'))) 'zigup uninstall left the shim'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $ScoopRoot 'apps/zigup/current'))) 'zigup uninstall left the current link'
    $lifecycle.zigup = [ordered]@{
        scoop_shim_arguments=$zigupArgsScoop; coop_shim_arguments=$zigupArgsCoop
        expected_path_entries=@($zigupExpectedPath); path_entry_present=$zigupPathAfter.Count
        scoop_run_exit=$zigupScoopRun.exit; coop_run_exit=$zigupRun.exit
        raw_path_restored=((Get-RawUserPath) -eq $rawPathBeforeZigup)
        scoop_install_exit=$zigupScoopInstall.exit; scoop_uninstall_exit=$zigupScoopUninstall.exit
        coop_uninstall_exit=$zigupUninstall.exit; plan_log=[IO.Path]::GetFileName($zigupInstall.log)
    }

    # lessmsi: real shortcut target/icon and a real direct entry, then uninstall revokes both
    $lessmsiDirectory = Join-Path $ScoopRoot 'apps/lessmsi/current'
    $lessmsiPersist = Join-Path $ScoopRoot 'persist/lessmsi'
    $lessmsiExpected = [System.Collections.Generic.List[object]]::new()
    Add-ScoopShortcutExpectation (& $sharedManifest 'lessmsi') $lessmsiDirectory $lessmsiPersist $lessmsiExpected
    Assert-True ($lessmsiExpected.Count -eq 1) "lessmsi declares $($lessmsiExpected.Count) shortcuts, expected 1"
    $lessmsiPreview = Coop 'lessmsi-preview' @('install','main/lessmsi','--dry-run','--json')
    Assert-True ($lessmsiPreview.exit -eq 0) "lessmsi preview failed: $($lessmsiPreview.output)"
    $lessmsiInstall = Coop 'lessmsi-install' @('install','main/lessmsi','--json')
    [void]$installedByCoop.Add('lessmsi')
    Assert-True ($lessmsiInstall.exit -eq 0) "lessmsi install failed: $($lessmsiInstall.output)"
    $lessmsiLink = Join-Path $startMenu 'Less MSIérables.lnk'
    Assert-True (Test-Path -LiteralPath $lessmsiLink) "lessmsi shortcut missing: $lessmsiLink"
    $lessmsiIdentity = ShortcutOf $lessmsiLink
    Assert-True (([IO.Path]::GetFullPath($lessmsiIdentity.target)) -ieq ([IO.Path]::GetFullPath($lessmsiExpected[0].target))) "lessmsi shortcut target is '$($lessmsiIdentity.target)', expected '$($lessmsiExpected[0].target)'"
    Assert-True (([IO.Path]::GetFullPath($lessmsiIdentity.working_directory)) -ieq ([IO.Path]::GetFullPath($lessmsiDirectory))) "lessmsi shortcut working directory is '$($lessmsiIdentity.working_directory)'"
    $lessmsiRun = Run 'lessmsi-run' (Join-Path $ScoopRoot 'shims/lessmsi.exe') @('l','-t','File',(Join-Path $work 'sample.msi'))
    Assert-True ($lessmsiRun.exit -eq 0 -and $lessmsiRun.output -match 'File') "lessmsi did not list the MSI file table: exit=$($lessmsiRun.exit) output=$($lessmsiRun.output)"
    $lessmsiUninstall = Coop 'lessmsi-uninstall' @('uninstall','lessmsi','--json')
    [void]$installedByCoop.Remove('lessmsi')
    Assert-True ($lessmsiUninstall.exit -eq 0) "lessmsi uninstall failed: $($lessmsiUninstall.output)"
    Assert-True (-not (Test-Path -LiteralPath $lessmsiLink)) 'lessmsi uninstall left the shortcut'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $ScoopRoot 'shims/lessmsi.exe'))) 'lessmsi uninstall left the entry'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $ScoopRoot 'apps/lessmsi/current'))) 'lessmsi uninstall left the current link'
    $lifecycle.lessmsi = [ordered]@{
        shortcut_target=$lessmsiIdentity.target; expected_target=$lessmsiExpected[0].target
        shortcut_working_directory=$lessmsiIdentity.working_directory
        run_exit=$lessmsiRun.exit; uninstall_exit=$lessmsiUninstall.exit
        shortcut_removed=(-not (Test-Path -LiteralPath $lessmsiLink)); log=[IO.Path]::GetFileName($lessmsiInstall.log)
    }
} finally {
    foreach ($name in @($installedByCoop)) {
        try { $null = Coop "cleanup-coop-$name" @('uninstall',$name,'--json') } catch { Write-Text (Join-Path $EvidenceDir "cleanup-coop-$name-error.log") $_.Exception.Message }
    }
    foreach ($name in @($installedByScoop)) {
        try { $null = Scoop "cleanup-scoop-$name" @('uninstall',$name) } catch { Write-Text (Join-Path $EvidenceDir "cleanup-scoop-$name-error.log") $_.Exception.Message }
    }
}

# --- 3. Final state: only the test packages are gone; nothing else changed ----------------------
$coopListAfter = @((& $CoopExe --root $ScoopRoot list --json | Out-String | ConvertFrom-Json) | ForEach-Object { "$($_.name)@$($_.version)" } | Sort-Object)
$scoopListAfter = Get-ScoopExportApps
$rawPathAfter = Get-RawUserPath
Assert-True (($coopListBefore -join '|') -eq ($coopListAfter -join '|')) "the managed installation list changed outside the test packages: before=$($coopListBefore -join ',') after=$($coopListAfter -join ',')"
Assert-True (($scoopListBefore -join '|') -eq ($scoopListAfter -join '|')) "the Scoop installation list changed outside the test packages: before=$($scoopListBefore -join ',') after=$($scoopListAfter -join ',')"
Assert-True ($rawPathAfter -eq $rawPathBefore) "the raw user Path was not restored: before='$rawPathBefore' after='$rawPathAfter'"
foreach ($name in $testPackages.Keys) {
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $ScoopRoot "apps/$name/current"))) "test package directory left behind: $name"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $ScoopRoot ".coop/packages/$name.json"))) "Coop management record left behind: $name"
}
Write-Text (Join-Path $EvidenceDir 'commands.json') (($commands | ConvertTo-Json -Depth 6))
$result = [ordered]@{
    versions = $versions
    shared_main_revision_after = (& git -C $sharedMain rev-parse HEAD | Out-String).Trim()
    inventory_parity = $parity
    lifecycle = $lifecycle
    raw_user_path_restored = ($rawPathAfter -eq $rawPathBefore)
    coop_list_unchanged = (($coopListBefore -join '|') -eq ($coopListAfter -join '|'))
    scoop_list_unchanged = (($scoopListBefore -join '|') -eq ($scoopListAfter -join '|'))
    commands = $commands
}
Write-Text (Join-Path $EvidenceDir 'summary.json') ($result | ConvertTo-Json -Depth 10)
Write-Output "PASS real Manifest-shape acceptance: 6 inventory plans match Scoop; wgcf/zigup/lessmsi installed, run, alternated and removed"

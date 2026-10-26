param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$EvidenceDir,
    [Parameter(Mandatory)][string]$TestRoot,
    [string]$ScoopRoot = 'C:\Users\Neo\scoop',
    [string]$Package = 'jq',
    [string]$Version = '1.8.2'
)
# R17 (#38) real acceptance: create a fresh installation root without Scoop, initialize it with
# Coop while git.exe, 7z.exe and scoop are unreachable on PATH (none of them are uninstalled from
# the machine), install a real Main package, then install the real Scoop program tree into the same
# root as a later user action and manage the package from both clients in turn.
$ErrorActionPreference = 'Stop'
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test data must stay within the project test directory'
}
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$ScoopRoot = [IO.Path]::GetFullPath($ScoopRoot)
$runLabel = Split-Path $EvidenceDir -Leaf
$root = Join-Path $TestRoot ('coop-initialized-' + $runLabel)
$realScoop = Join-Path $ScoopRoot 'shims/scoop.ps1'
$realBucket = Join-Path $ScoopRoot 'buckets/main'
$scoopApp = Join-Path $ScoopRoot 'apps/scoop/current'
$guard = Join-Path (Split-Path $CoopExe) 'process_guard.exe'
foreach ($path in @($CoopExe, $realScoop, $realBucket, $scoopApp, $guard)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing fixed input: $path" }
}
if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
$emptyBin = Join-Path $TestRoot ('empty-bin-' + $runLabel)
if (Test-Path -LiteralPath $emptyBin) { Remove-Item -LiteralPath $emptyBin -Recurse -Force }
New-Item -ItemType Directory -Path $emptyBin -Force | Out-Null
$commands = [System.Collections.Generic.List[object]]::new()
function Run([string]$name, [string]$exe, [string[]]$arguments, [hashtable]$environment = @{}) {
    $stdoutLog = Join-Path $EvidenceDir ($name + '.stdout.log')
    $stderrLog = Join-Path $EvidenceDir ($name + '.stderr.log')
    $previous = @{}
    foreach ($key in $environment.Keys) {
        $previous[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $environment[$key], 'Process')
    }
    try {
        $stdout = & $exe @arguments 2> $stderrLog | Out-String
        $exit = $LASTEXITCODE
    } finally {
        foreach ($key in $environment.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key], 'Process') }
    }
    $stderr = if (Test-Path -LiteralPath $stderrLog) { Get-Content -LiteralPath $stderrLog -Raw } else { '' }
    Set-Content -LiteralPath $stdoutLog -Value $stdout -Encoding utf8
    $commands.Add([pscustomobject]@{ name = $name; exe = $exe; arguments = $arguments; exit = $exit
        stdout_log = $stdoutLog; stderr_log = $stderrLog; environment = $environment })
    return [pscustomobject]@{ exit = $exit; stdout = $stdout; stderr = $stderr }
}
function Coop([string]$name, [string[]]$arguments, [hashtable]$environment = @{}) {
    return Run $name $CoopExe (@('--root', $root) + $arguments) $environment
}
function GuardedCoop([string]$name, [string[]]$arguments, [hashtable]$environment = @{}) {
    $guardEnvironment = $environment.Clone()
    # A real download can legitimately take longer than the guard default; the guard still fails
    # when the workload starts an extra process or exits non-zero.
    $guardEnvironment['COOP_PROCESS_GUARD_TIMEOUT_MS'] = '180000'
    return Run $name $guard (@($CoopExe, '--root', $root) + $arguments) $guardEnvironment
}
function FreshScoop([string]$name, [string[]]$arguments) {
    # The real Scoop program tree copied into the target root: its entry script resolves the root
    # from its own location. SCOOP/SCOOP_GLOBAL are cleared so the project-local root is used and
    # the shared installation is never touched.
    return Run $name 'pwsh' (@('-NoProfile', '-NonInteractive', '-File', (Join-Path $root 'apps/scoop/current/bin/scoop.ps1')) + $arguments) @{ SCOOP = ''; SCOOP_GLOBAL = '' }
}
function Assert-True([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
function Get-UserPath {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    if ($null -eq $key) { throw 'HKCU\Environment is missing' }
    try {
        return [pscustomobject]@{
            value = [string]$key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            kind = $key.GetValueKind('Path').ToString()
        }
    } finally { $key.Dispose() }
}
function Set-UserPath($snapshot) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if ($null -eq $key) { throw 'HKCU\Environment is missing' }
    try {
        $kind = [Enum]::Parse([Microsoft.Win32.RegistryValueKind], $snapshot.kind)
        $key.SetValue('Path', $snapshot.value, $kind)
    } finally { $key.Dispose() }
}
function Path-Delta($before, $after) {
    $beforeEntries = @(($before.value -split ';') | Where-Object { $_ -ne '' })
    $afterEntries = @(($after.value -split ';') | Where-Object { $_ -ne '' })
    return @($afterEntries | Where-Object { $beforeEntries -notcontains $_ })
}
function Tree-Fingerprint([string]$path) {
    $lines = Get-ChildItem -LiteralPath $path -Recurse -Force | ForEach-Object {
        $relative = $_.FullName.Substring($path.Length).TrimStart('\') -replace '\\', '/'
        if ($_.PSIsContainer) { "d|$relative" } else { "f|$relative|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }
    }
    return @($lines | Sort-Object)
}
$userPathBefore = Get-UserPath
$processPath = $env:PATH
$evidence = $null
$failure = $null
try {
    # 1. The selected root is genuinely fresh: no Scoop, Git or 7-Zip artifacts and no layout.
    $freshness = [ordered]@{
        root = $root
        root_existed = $false
        entries_before = @()
        scoop_program_present = $false
        git_present = $false
        seven_zip_present = $false
    }
    $freshness.root_existed = Test-Path -LiteralPath $root
    $freshness.entries_before = if ($freshness.root_existed) { @(Get-ChildItem -LiteralPath $root -Force | ForEach-Object { $_.Name }) } else { @() }
    $freshness.scoop_program_present = Test-Path -LiteralPath (Join-Path $root 'apps/scoop')
    $freshness.git_present = Test-Path -LiteralPath (Join-Path $root 'buckets/main/.git')
    $freshness.seven_zip_present = Test-Path -LiteralPath (Join-Path $root 'apps/7zip')
    Assert-True (-not $freshness.root_existed) "The run-specific root already existed: $root"

    # 2. The independence condition: git, 7z and scoop cannot be found on PATH. They are not
    #    uninstalled; only this test process tree gets a PATH without them.
    $probe = [ordered]@{ path = $emptyBin; git = 'not-run'; seven_zip = 'not-run'; scoop = 'not-run'; git_execution = 'not-run' }
    $env:PATH = $emptyBin
    try {
        $probe.git = if (Get-Command git -ErrorAction SilentlyContinue) { 'found' } else { 'absent' }
        $probe.seven_zip = if (Get-Command 7z -ErrorAction SilentlyContinue) { 'found' } else { 'absent' }
        $probe.scoop = if (Get-Command scoop -ErrorAction SilentlyContinue) { 'found' } else { 'absent' }
        try {
            $gitAttempt = (& git --version 2>&1 | Out-String).Trim()
            $probe.git_execution = "exit=$LASTEXITCODE output=$gitAttempt"
        } catch {
            $probe.git_execution = 'command not found: ' + $_.Exception.Message
        }
    } finally { $env:PATH = $processPath }
    Set-Content -LiteralPath (Join-Path $EvidenceDir 'restricted-path-probe.json') -Value ($probe | ConvertTo-Json -Depth 4) -Encoding utf8
    Assert-True ($probe.git -eq 'absent' -and $probe.seven_zip -eq 'absent' -and $probe.scoop -eq 'absent') "An external tool was reachable on the restricted PATH: $($probe | ConvertTo-Json -Compress)"
    Assert-True ($probe.git_execution -match 'command not found|not recognized') "git.exe executed under the restricted PATH: $($probe.git_execution)"
    $restricted = @{ PATH = $emptyBin }

    # 3. Contrast: real Scoop cannot use a directory that was never initialized.
    $uninitialized = Run 'scoop-uninitialized-root' 'pwsh' @('-NoProfile', '-NonInteractive', '-File', $realScoop, 'list', $Package) @{ SCOOP = $root }
    Assert-True ($uninitialized.exit -ne 0) "Real Scoop reported a usable uninitialized root: $($uninitialized.stdout)$($uninitialized.stderr)"
    Assert-True (-not (Test-Path -LiteralPath $root)) 'The uninitialized-root probe created the root'

    # 4. Coop preview and initialization run with the restricted PATH and start no child process.
    $preview = Coop 'init-preview' @('init', '--dry-run', '--json') $restricted
    Assert-True ($preview.exit -eq 0) "init preview failed: $($preview.stdout)$($preview.stderr)"
    $previewJson = $preview.stdout | ConvertFrom-Json
    Assert-True ($previewJson.dry_run -eq $true -and @($previewJson.created).Count -eq 5) "init preview did not list the standard layout: $($preview.stdout)"
    Assert-True (-not (Test-Path -LiteralPath $root)) 'init preview created the installation root'
    $init = GuardedCoop 'init-process-guard' @('init', '--json') $restricted
    Assert-True ($init.exit -eq 0) "guarded init failed: $($init.stdout)$($init.stderr)"
    Assert-True ($init.stderr -match 'Observed workload processes: 1;') "init started an extra process: $($init.stderr)"
    $initJson = $init.stdout | ConvertFrom-Json
    Assert-True ((@($initJson.created) -join ',') -eq 'apps,buckets,cache,persist,shims') "init created the wrong layout: $($init.stdout)"
    $layoutAfterInit = @(Get-ChildItem -LiteralPath $root -Force | Sort-Object Name | ForEach-Object { $_.Name })
    Assert-True (($layoutAfterInit -join ',') -eq 'apps,buckets,cache,persist,shims') "init created unexpected entries: $($layoutAfterInit -join ',')"
    $idempotent = Coop 'init-idempotent' @('init', '--json') $restricted
    Assert-True ($idempotent.exit -eq 0) "repeated init failed: $($idempotent.stdout)$($idempotent.stderr)"
    $idempotentJson = $idempotent.stdout | ConvertFrom-Json
    Assert-True (@($idempotentJson.created).Count -eq 0 -and @($idempotentJson.existing).Count -eq 5) "repeated init was not idempotent: $($idempotent.stdout)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.coop'))) 'init created Coop private state in a fresh root'

    # 5. A real Main bucket is cloned with the embedded Git library, and a real package is
    #    installed and run with the restricted PATH.
    $bucketUrl = ([Uri]$realBucket).AbsoluteUri
    $bucketAdd = Coop 'bucket-add' @('bucket', 'add', 'main', $bucketUrl) $restricted
    Assert-True ($bucketAdd.exit -eq 0) "bucket add failed: $($bucketAdd.stdout)$($bucketAdd.stderr)"
    $bucketJson = $bucketAdd.stdout | ConvertFrom-Json
    $sourceRevision = (& git -C $realBucket rev-parse HEAD 2>&1 | Out-String).Trim()
    Assert-True ($bucketJson.kind -eq 'git' -and $bucketJson.revision -eq $sourceRevision) "the shared bucket clone does not match the real revision: $($bucketAdd.stdout) expected=$sourceRevision"
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'buckets/main/.git')) 'the bucket was not cloned into the shared layout'
    $install = GuardedCoop 'install-process-guard' @('install', $Package, '--json') $restricted
    Assert-True ($install.exit -eq 0) "guarded install failed: $($install.stdout)$($install.stderr)"
    Assert-True ($install.stderr -match 'Observed workload processes: 1;') "install started an extra process: $($install.stderr)"
    $installJson = $install.stdout | ConvertFrom-Json
    Assert-True ($installJson.status -eq 'success' -and $installJson.version -eq $Version) "install did not report success: $($install.stdout)"
    $program = Run 'program-run' (Join-Path $root "shims/$Package.exe") @('--version') $restricted
    Assert-True ($program.exit -eq 0 -and $program.stdout.Trim() -eq "$Package-$Version") "the installed program did not run: $($program.stdout)$($program.stderr)"
    $list = Coop 'coop-list-after-install' @('list', '--json') $restricted
    Assert-True ($list.exit -eq 0) "coop list failed: $($list.stdout)$($list.stderr)"
    $listed = @(($list.stdout | ConvertFrom-Json) | Where-Object { $_.name -eq $Package })
    Assert-True ($listed.Count -eq 1 -and $listed[0].version -eq $Version -and $listed[0].bucket -eq 'main') "coop did not list the installed package: $($list.stdout)"
    $standardRecords = [ordered]@{
        manifest = Join-Path $root "apps/$Package/current/scoop-manifest.json"
        install = Join-Path $root "apps/$Package/current/scoop-install.json"
        current = Join-Path $root "apps/$Package/current"
        shim = Join-Path $root "shims/$Package.shim"
        launcher = Join-Path $root "shims/$Package.exe"
    }
    foreach ($record in $standardRecords.Values) { Assert-True (Test-Path -LiteralPath $record) "missing standard installation record: $record" }
    $manifestVersion = (Get-Content -LiteralPath $standardRecords.manifest -Raw | ConvertFrom-Json).version
    Assert-True ($manifestVersion -eq $Version) "the standard installation record carries the wrong version: $manifestVersion"

    # 6. Later the user installs the real Scoop program into the same root (the component is
    #    reused from the machine, not downloaded): record version, license and size first.
    $scoopVersion = Run 'scoop-version' 'pwsh' @('-NoProfile', '-NonInteractive', '-File', $realScoop, '--version')
    Assert-True ($scoopVersion.exit -eq 0 -and $scoopVersion.stdout -match 'v[0-9]+\.[0-9]+\.[0-9]+') "cannot determine the reused Scoop version: $($scoopVersion.stdout)$($scoopVersion.stderr)"
    $licensePath = Join-Path $scoopApp 'LICENSE'
    Assert-True (Test-Path -LiteralPath $licensePath) "the reused Scoop program tree has no license file: $licensePath"
    $scoopTree = Get-ChildItem -LiteralPath $scoopApp -Recurse -File -Force | Measure-Object -Property Length -Sum
    $licenseHash = (Get-FileHash -LiteralPath $licensePath -Algorithm SHA256).Hash.ToLower()
    $beforeScoopInstall = Tree-Fingerprint $root
    Copy-Item -LiteralPath $scoopApp -Destination (Join-Path $root 'apps/scoop/current') -Recurse -Force
    foreach ($wrapper in 'scoop', 'scoop.cmd', 'scoop.ps1') {
        $source = Join-Path $ScoopRoot "shims/$wrapper"
        Assert-True (Test-Path -LiteralPath $source) "the reusable Scoop shim wrapper is missing: $source"
        Copy-Item -LiteralPath $source -Destination (Join-Path $root "shims/$wrapper") -Force
    }
    $afterScoopInstall = Tree-Fingerprint $root
    $addedByScoopInstall = @($afterScoopInstall | Where-Object { $beforeScoopInstall -notcontains $_ })
    Assert-True (@($addedByScoopInstall | Where-Object { $_ -like 'd|apps*' -and $_ -notlike 'd|apps/scoop*' }).Count -eq 0) 'copying Scoop changed existing application state'
    $initAfterScoop = Coop 'init-after-scoop' @('init', '--json')
    Assert-True ($initAfterScoop.exit -eq 0) "init after Scoop failed: $($initAfterScoop.stdout)$($initAfterScoop.stderr)"
    $initAfterScoopJson = $initAfterScoop.stdout | ConvertFrom-Json
    Assert-True (@($initAfterScoopJson.created).Count -eq 0 -and $initAfterScoopJson.scoop_installation.present -eq $true) "init did not report the later Scoop installation: $($initAfterScoop.stdout)"

    # 7. The later-installed Scoop recognizes and manages the Coop installation, and Coop
    #    re-identifies the facts afterwards. Its own PATH update is observed and restored.
    $scoopList = FreshScoop 'scoop-list-after-coop-install' @('list', $Package)
    Assert-True ($scoopList.exit -eq 0 -and $scoopList.stdout -match [regex]::Escape($Version)) "Scoop did not recognize the Coop installation: $($scoopList.stdout)$($scoopList.stderr)"
    $scoopReset = FreshScoop 'scoop-reset' @('reset', $Package)
    Assert-True ($scoopReset.exit -eq 0) "Scoop reset failed: $($scoopReset.stdout)$($scoopReset.stderr)"
    $resetRun = Run 'program-run-after-scoop-reset' (Join-Path $root "shims/$Package.exe") @('--version')
    Assert-True ($resetRun.exit -eq 0 -and $resetRun.stdout.Trim() -eq "$Package-$Version") "the Scoop-reset entry did not run: $($resetRun.stdout)$($resetRun.stderr)"
    $scoopResetEntry = [ordered]@{
        shim_metadata = (Get-Content -LiteralPath (Join-Path $root "shims/$Package.shim") -Raw).Trim()
        launcher_sha256 = (Get-FileHash -LiteralPath (Join-Path $root "shims/$Package.exe") -Algorithm SHA256).Hash.ToLower()
        launcher_is_coop_exe = ((Get-FileHash -LiteralPath (Join-Path $root "shims/$Package.exe") -Algorithm SHA256).Hash.ToLower() -eq (Get-FileHash -LiteralPath $CoopExe -Algorithm SHA256).Hash.ToLower())
        scoop_output = ($scoopReset.stdout + $scoopReset.stderr).Trim()
    }
    Assert-True ($scoopResetEntry.shim_metadata -match [regex]::Escape("apps\$Package\current")) "Scoop reset did not publish its own shared entry: $($scoopResetEntry.shim_metadata)"
    $userPathAfterReset = Get-UserPath
    $scoopPathEntries = Path-Delta $userPathBefore $userPathAfterReset
    $listAfterReset = Coop 'coop-list-after-scoop-reset' @('list', '--json')
    Assert-True ($listAfterReset.exit -eq 0) "coop list after Scoop reset failed: $($listAfterReset.stdout)$($listAfterReset.stderr)"
    $listedAfterReset = @(($listAfterReset.stdout | ConvertFrom-Json) | Where-Object { $_.name -eq $Package })
    Assert-True ($listedAfterReset.Count -eq 1 -and $listedAfterReset[0].version -eq $Version) "Coop did not re-identify the Scoop-reset installation: $($listAfterReset.stdout)"
    $scoopResetEntry['coop_management_after'] = $listedAfterReset[0].management
    $scoopUninstall = FreshScoop 'scoop-uninstall' @('uninstall', $Package)
    Assert-True ($scoopUninstall.exit -eq 0) "Scoop uninstall failed: $($scoopUninstall.stdout)$($scoopUninstall.stderr)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root "apps/$Package/current"))) 'Scoop uninstall left the application current link'
    $listAfterScoopUninstall = Coop 'coop-list-after-scoop-uninstall' @('list', '--json')
    Assert-True ($listAfterScoopUninstall.exit -eq 0) "coop list after Scoop uninstall failed: $($listAfterScoopUninstall.stdout)$($listAfterScoopUninstall.stderr)"
    Assert-True (@((($listAfterScoopUninstall.stdout | ConvertFrom-Json) | Where-Object { $_.name -eq $Package })).Count -eq 0) "Coop still listed the Scoop-uninstalled package: $($listAfterScoopUninstall.stdout)"

    # 8. Reverse direction in the initialized root: Coop creates the installation again and the
    #    later-installed Scoop recognizes it, then Coop removes its own entry again.
    $reinstall = Coop 'coop-reinstall' @('install', $Package, '--json')
    Assert-True ($reinstall.exit -eq 0) "Coop reinstall failed: $($reinstall.stdout)$($reinstall.stderr)"
    $scoopListAgain = FreshScoop 'scoop-list-after-coop-reinstall' @('list', $Package)
    Assert-True ($scoopListAgain.exit -eq 0 -and $scoopListAgain.stdout -match [regex]::Escape($Version)) "Scoop did not recognize the Coop reinstall: $($scoopListAgain.stdout)$($scoopListAgain.stderr)"
    $uninstall = Coop 'coop-uninstall' @('uninstall', $Package, '--json')
    Assert-True ($uninstall.exit -eq 0) "Coop uninstall failed: $($uninstall.stdout)$($uninstall.stderr)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root "apps/$Package/current")) -and -not (Test-Path -LiteralPath (Join-Path $root "shims/$Package.exe"))) 'Coop uninstall left published state'
    $scoopListFinal = FreshScoop 'scoop-list-final' @('list', $Package)
    Assert-True ($scoopListFinal.stdout -notmatch [regex]::Escape($Package)) "Scoop still listed the Coop-uninstalled package: $($scoopListFinal.stdout)$($scoopListFinal.stderr)"

    $evidence = [ordered]@{
        platform = (Get-CimInstance Win32_OperatingSystem).Caption
        run = $runLabel
        timestamp = [DateTime]::UtcNow.ToString('o')
        coop_exe = $CoopExe
        coop_sha256 = (Get-FileHash -LiteralPath $CoopExe -Algorithm SHA256).Hash.ToLower()
        coop_version = (& $CoopExe --version | Out-String).Trim()
        scoop_root = $ScoopRoot
        fresh_root = $root
        freshness = $freshness
        restricted_path = $probe
        uninitialized_scoop = [ordered]@{ exit = $uninitialized.exit; output = ($uninitialized.stdout + $uninitialized.stderr).Trim() }
        init_directories = @($initJson.created)
        init_processes = $init.stderr.Trim()
        install_processes = $install.stderr.Trim()
        bucket_url = $bucketUrl
        bucket_revision = $bucketJson.revision
        real_bucket_revision = $sourceRevision
        package = $Package
        version = $Version
        standard_records = $standardRecords
        scoop_version = $scoopVersion.stdout.Trim()
        scoop_license = [ordered]@{ path = $licensePath; sha256 = $licenseHash; files = $scoopTree.Count; bytes = $scoopTree.Sum }
        scoop_path_entries_added = $scoopPathEntries
        scoop_reset_entry = $scoopResetEntry
        external_tools_still_installed = [ordered]@{
            git = if (Get-Command git -ErrorAction SilentlyContinue) { (Get-Command git).Source } else { $null }
            seven_zip = if (Get-Command 7z -ErrorAction SilentlyContinue) { (Get-Command 7z).Source } else { $null }
            scoop = $realScoop
        }
        user_path_before = $userPathBefore.value
        user_path_after_reset = $userPathAfterReset.value
        user_path_restored = $null
        commands = @($commands)
    }
} catch {
    $failure = $_
} finally {
    Set-UserPath $userPathBefore
    $env:PATH = $processPath
    $userPathAfter = Get-UserPath
    $restored = ($userPathAfter.value -ceq $userPathBefore.value) -and ($userPathAfter.kind -eq $userPathBefore.kind)
    if ($null -eq $evidence) {
        $evidence = [ordered]@{
            platform = (Get-CimInstance Win32_OperatingSystem).Caption
            run = $runLabel
            timestamp = [DateTime]::UtcNow.ToString('o')
            fresh_root = $root
            commands = @($commands)
        }
    }
    $evidence['user_path_restored'] = $restored
    $evidence['user_path_after_restore'] = $userPathAfter.value
    $evidence['test_root_path_entries_after_restore'] = @((($userPathAfter.value -split ';') | Where-Object { $_ -like "*$runLabel*" }))
    if ($null -ne $failure) { $evidence['error'] = $failure.Exception.Message }
    $evidencePath = Join-Path $EvidenceDir 'initialization-evidence.json'
    $evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $evidencePath -Encoding utf8
    if (-not $restored) { throw 'The user PATH was not restored to its pre-run value' }
}
if ($null -ne $failure) { throw $failure }
if (@($evidence.scoop_path_entries_added).Count -eq 0) { throw 'Real Scoop did not report its PATH update; the observation is incomplete' }
if (@($evidence.test_root_path_entries_after_restore).Count -ne 0) { throw 'A test-root PATH entry remained after restoration' }
Write-Output "PASS initialization without Scoop/Git/7-Zip, later real Scoop recognition and alternating management: $(Join-Path $EvidenceDir 'initialization-evidence.json')"


#requires -Version 5.1
<#
Manual acceptance for #96--#101. Not registered as a lifecycle CTest.
Without -RunLifecycle this script only validates project-local inputs; it never resolves Scoop.
SourceFile schema and the separately authorized live procedure: docs/four-sample-acceptance.md.
#>
param(
    [Parameter(Mandatory = $true)][string]$SourceFile,
    [string]$CoopExe,
    [string]$EvidenceDir,
    [string]$ScoopRoot,
    [switch]$RunLifecycle
)
$ErrorActionPreference = 'Stop'
if (-not $CoopExe) { $CoopExe = Join-Path $PSScriptRoot '../.local/build/coop.exe' }
if (-not $EvidenceDir) { $EvidenceDir = Join-Path $PSScriptRoot '../.local/four-samples' }
. (Join-Path $PSScriptRoot 'four-sample-evidence.ps1')
. (Join-Path $PSScriptRoot '../tests/invoke-coop.ps1')
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
function ProjectFile([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($project + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Input must be inside this project: $full" }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Missing input: $full" }
    # Refuse junction-based escapes as well as lexical '..' escapes.
    $part = Get-Item -LiteralPath $full -Force
    while ($part.FullName -ine $project) {
        if ($part.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked input is not allowed: $full" }
        if ($part -is [IO.FileInfo]) { $part = $part.Directory } else { $part = $part.Parent }
        if ($null -eq $part) { throw 'Input escaped project' }
    }
    return $full
}
$SourceFile = ProjectFile $SourceFile
$CoopExe = ProjectFile $CoopExe
$sources = Get-Content -Encoding UTF8 -LiteralPath $SourceFile -Raw | ConvertFrom-Json
$byId = @{}
foreach ($source in @($sources.sources)) {
    if ($source.id -notin @('jq-old', 'jq', 'wgcf', 'pdd', 'posh-git', 'python', 'python-dateutil', 'six') -or $source.version -notmatch '^[0-9][0-9A-Za-z.+_-]*$') { throw 'Invalid source id or version' }
    if ($byId.ContainsKey($source.id)) { throw "Duplicate source: $($source.id)" }
    if ($source.source_url -notmatch '^https://' -or $source.artifact_url -notmatch '^https://') { throw 'HTTPS provenance URLs are required' }
    $source.artifact = ProjectFile $source.artifact
    if (-not (Test-FourSampleHash $source.artifact $source.artifact_sha256)) { throw "Artifact digest mismatch: $($source.id)" }
    if ($source.id -in @('jq-old', 'jq', 'wgcf', 'pdd', 'posh-git')) {
        $expectedBucket = 'main'
        if ($source.id -in @('pdd', 'posh-git')) { $expectedBucket = 'extras' }
        if ($source.bucket -ne $expectedBucket) { throw 'Unexpected source bucket' }
        $source.manifest = ProjectFile $source.manifest
        if ($source.revision -notmatch '^[0-9a-fA-F]{40}$' -or -not (Test-FourSampleHash $source.manifest $source.manifest_sha256)) { throw "Manifest provenance mismatch: $($source.id)" }
        $manifest = Get-Content -Encoding UTF8 -LiteralPath $source.manifest -Raw | ConvertFrom-Json
        $selected = $manifest
        if ($manifest.architecture -and $manifest.architecture.'64bit') { $selected = $manifest.architecture.'64bit' }
        if ($manifest.version -ne $source.version -or @($selected.url).Count -ne 1 -or $selected.url -ne $source.artifact_url -or $selected.hash -ne $source.artifact_sha256) {
            throw "Source must match the single 64bit artifact declared in the manifest: $($source.id)"
        }
    }
    $byId[$source.id] = $source
}
foreach ($id in @('jq-old', 'jq', 'wgcf', 'pdd', 'posh-git', 'python', 'python-dateutil', 'six')) {
    if (-not $byId.ContainsKey($id)) { throw "Missing provenance: $id" }
}
if ($byId['jq-old'].version -eq $byId['jq'].version) { throw 'jq needs two different versions' }
if ((Split-Path $byId['jq-old'].manifest -Leaf) -ne 'jq.json') { throw 'Historical manifest must be named jq.json, in its own project directory' }
$pythonExe = ProjectFile $sources.python_exe
$pythonModules = [IO.Path]::GetDirectoryName((ProjectFile (Join-Path $sources.python_modules 'dateutil/__init__.py')))
$pythonModules = Split-Path $pythonModules -Parent
if (-not (Test-FourSampleHash $pythonExe $sources.python_exe_sha256)) { throw 'Python executable digest mismatch' }
if (-not $RunLifecycle) {
    Write-Host 'Project-local input validation passed. No Scoop commands, snapshots, or lifecycle operations ran.'
    return
}
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Live acceptance requires Windows PowerShell 5.1' }
if (-not $ScoopRoot) { throw 'Live acceptance requires an explicit ScoopRoot' }
if ($env:COOP_STATE_DIR) { throw 'Remove the process COOP_STATE_DIR override before live acceptance' }
$ScoopRoot = [IO.Path]::GetFullPath($ScoopRoot).TrimEnd('\')
$scoop = (Get-Command scoop.ps1 -ErrorAction Stop).Source
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
if (-not $EvidenceDir.StartsWith($project + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence must stay in the project' }
# Unique evidence is never overwritten, including failed attempts.
$run = Join-Path $EvidenceDir ('run-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $run -Force | Out-Null
$binaryHash = (Get-FileHash -LiteralPath $CoopExe -Algorithm SHA256).Hash
$commands = New-Object 'System.Collections.Generic.List[object]'
$results = New-Object 'System.Collections.Generic.List[object]'
$plan = [ordered]@{
    jq = @('preflight', 'forward', 'reverse', 'cleanup', 'restore')
    wgcf = @('preflight', 'install', 'reset', 'scoop-uninstall', 'reinstall', 'coop-uninstall', 'restore')
    pdd = @('preflight', 'missing-host', 'install', 'reset', 'scoop-uninstall', 'reinstall', 'coop-uninstall', 'restore')
    'posh-git' = @('preflight', 'install', 'reset', 'scoop-uninstall', 'reinstall', 'coop-uninstall', 'restore')
}
foreach ($name in $plan.Keys) { foreach ($stage in $plan[$name]) {
    $results.Add([pscustomobject]@{ package = $name; scene = $stage; status = 'not-run'; detail = ''; commands = @(); evidence = @() })
} }
$report = [ordered]@{ schema = 1; status = 'incomplete'; repository_checks = 'not-run: attach final build, CTest, hygiene and diff evidence separately'; started_utc = [DateTime]::UtcNow.ToString('o'); binary_sha256 = $binaryHash; commands = $commands; scenes = $results; limitations = @('ARM64, full corpus, performance and fault injection not run', 'Unrelated apps: top-level identity only; modules: content hashes without recursive link traversal', 'Cache, bucket refresh and transaction records are retained; no automatic failure cleanup', 'wgcf quoted config is checked on this root only; a root without spaces does not prove a spaced-root lifecycle') }
function SaveReport {
    Write-FourSampleJson (Join-Path $run 'report.json') $report
    $lines = @('# Four-sample acceptance', '', ('Status: ' + $report.status), '', ('Binary SHA256: `' + $binaryHash + '`'), '', ('Repository checks: ' + $report.repository_checks), '', '| Package | Scene | Status | Command IDs | Detail |', '| --- | --- | --- | --- | --- |')
    foreach ($row in $results) {
        $detail = $row.detail.Replace('|', '/').Replace("`r", ' ').Replace("`n", ' ')
        $lines += '| ' + $row.package + ' | ' + $row.scene + ' | ' + $row.status + ' | ' + ($row.commands -join ', ') + ' | ' + $detail + ' |'
    }
    $lines += @('', 'See report.json for command arguments, exits, snapshot references and limitations.', '', 'Snapshots contain local environment data; redact before sharing.')
    [IO.File]::WriteAllText((Join-Path $run 'report.md'), ($lines -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding($false)))
}
function Scene([string]$Package, [string]$Stage, [scriptblock]$Body) {
    $script:active = $results | Where-Object { $_.package -eq $Package -and $_.scene -eq $Stage }
    try { & $Body; $script:active.status = 'pass' }
    catch {
        $script:active.status = 'fail'
        if ($_.Exception.Message -like 'Blocked:*') { $script:active.status = 'blocked' }
        $script:active.detail = $_.Exception.Message
        throw
    }
    finally { SaveReport; $script:active = $null }
}
function Tool([string]$Name, [string]$Exe, [string[]]$Arguments, [switch]$AllowFailure) {
    if ((Get-FileHash -LiteralPath $CoopExe -Algorithm SHA256).Hash -ne $binaryHash) { throw 'Coop binary changed during acceptance' }
    $id = '{0:D3}-{1}' -f $commands.Count, $Name
    $output = Invoke-CoopNative $Exe @Arguments | Out-String
    $code = $LASTEXITCODE
    [IO.File]::WriteAllText((Join-Path $run "$id.log"), $output, (New-Object Text.UTF8Encoding($false)))
    $commands.Add([pscustomobject]@{ id = $id; executable = $Exe; arguments = $Arguments; exit = $code; output = "$id.log"; utc = [DateTime]::UtcNow.ToString('o') })
    if ($script:active) { $script:active.commands += $id }
    SaveReport
    if ($code -ne 0 -and -not $AllowFailure) { throw "$Name exited $code (see $id.log)" }
    return $output
}
function C([string]$Name, [string[]]$Arguments) {
    $out = Tool $Name $CoopExe (@('--root', $ScoopRoot) + $Arguments)
    if ($Arguments -contains '--json' -and $Arguments -notcontains '--dry-run' -and $Arguments[0] -in @('install', 'update', 'uninstall', 'cleanup', 'reset')) {
        $result = $out | ConvertFrom-Json
        if (@($result).Count -eq 0 -or @($result | Where-Object status -ne 'success').Count) { throw "Unexpected execution status for $Name" }
        $hooks = @($result | ForEach-Object { $_.scripts } | Where-Object { $null -ne $_ })
        foreach ($hook in $hooks) {
            if ($hook.exit_code -ne 0 -or $hook.status -ne 'succeeded') { throw 'Lifecycle script did not succeed' }
        }
        if ($Arguments[0] -eq 'install' -and $Arguments[1] -in @('main/wgcf', 'extras/posh-git') -and $hooks.Count -eq 0) { throw 'Required real installation hook was not recorded' }
    }
    return $out
}
function S([string]$Name, [string[]]$Arguments) {
    $literals = @($Arguments | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
    $code = '$ErrorActionPreference="Stop"; $global:LASTEXITCODE=0; $scoopArguments=@(' + $literals + '); try { & ' + "'" + $scoop.Replace("'", "''") + "' @scoopArguments; if (-not " + '$?' + ') { exit 1 }; exit $LASTEXITCODE } catch { Write-Output $_; exit 1 }'
    Tool $Name 'powershell.exe' @('-NoProfile', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code)))
}
function Snapshot([string]$Name, [string]$Package) {
    $snapshot = Get-FourSampleSnapshot $ScoopRoot $Package
    Write-FourSampleJson (Join-Path $run "$Name.json") $snapshot
    $script:active.evidence += "$Name.json"
    return $snapshot
}
function Preview([string]$Package, [string]$Action, [bool]$Available = $true) {
    $label = "$Package-$Action-preview-$($commands.Count)"
    $before = Snapshot "$label-before" $Package
    $target = $Package
    if ($Action -eq 'install') { $target = "$($byId[$Package].bucket)/$Package" }
    $output = C $label @($Action, $target, '--dry-run', '--json')
    $after = Snapshot "$label-after" $Package
    if (-not (Compare-FourSampleSnapshot $before $after)) { throw 'Preview changed protected installation, entries, data or user environment' }
    $parsed = $output | ConvertFrom-Json
    if ($parsed.execution_available -ne $Available) { throw 'Unexpected preview availability' }
    return $parsed
}
function CurrentManifest([string]$Package) {
    $source = $byId[$Package]
    $path = Join-Path $ScoopRoot "buckets/$($source.bucket)/bucket/$Package.json"
    $comparison = Get-FourSampleManifestComparison $source.manifest $path $source.manifest_sha256
    $evidence = "$Package-manifest-$([Guid]::NewGuid().ToString('N')).json"
    Write-FourSampleJson (Join-Path $run $evidence) $comparison
    $script:active.evidence += $evidence
    SaveReport
    if (-not $comparison.source_digest_matches_expected) { throw "Reviewed source manifest digest changed: $Package" }
    if (-not $comparison.content_equal) { throw "Bucket manifest drift: $Package (see $evidence)" }
    Tool "$Package-bucket-revision" 'git.exe' @('-C', (Join-Path $ScoopRoot "buckets/$($source.bucket)"), 'rev-parse', 'HEAD') | Out-Null
}
function Absent([string]$Package) {
    foreach ($path in @("apps/$Package", "modules/$Package")) {
        if (Test-Path -LiteralPath (Join-Path $ScoopRoot $path)) { throw "Blocked: existing user object $path" }
    }
    if (@(Get-ChildItem -LiteralPath (Join-Path $ScoopRoot 'shims') -Force | Where-Object { $_.BaseName -eq $Package -or $_.Name -eq $Package }).Count) { throw "Blocked: existing entry for $Package" }
}
function OldJqManifest {
    # Scoop -f releases version pins only when the installation source is its own workspace file.
    # Read the existing cache; never overwrite it. It must match every field of the reviewed source.
    $source = $byId['jq-old']
    $path = Join-Path $ScoopRoot 'workspace/jq.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Blocked: verified jq historical workspace manifest is missing' }
    $comparison = Get-FourSampleManifestComparison $source.manifest $path $source.manifest_sha256
    $evidence = "jq-old-workspace-$([Guid]::NewGuid().ToString('N')).json"
    Write-FourSampleJson (Join-Path $run $evidence) $comparison
    $script:active.evidence += $evidence
    SaveReport
    if (-not $comparison.source_digest_matches_expected -or -not $comparison.content_equal) { throw 'Blocked: historical jq workspace manifest differs from the reviewed source' }
    return $path
}
function Installed([string]$Package, [string]$Version) {
    $id = $Package
    if ($Package -eq 'jq' -and $Version -eq $byId['jq-old'].version) { $id = 'jq-old' }
    $dir = Join-Path $ScoopRoot "apps/$Package/$Version"
    $records = Get-FourSampleInstallRecords $dir $byId[$id].manifest
    $record = $records.install
    if ($record.architecture -ne '64bit') { throw 'Unexpected standard installation architecture' }
    $link = Get-Item -LiteralPath (Join-Path $ScoopRoot "apps/$Package/current") -Force
    if ($link.LinkType -ne 'Junction' -or @($link.Target).Count -ne 1 -or [IO.Path]::GetFullPath($link.Target[0]).TrimEnd('\') -ine $dir.TrimEnd('\')) { throw 'Current does not target the expected installed version' }
    $coopList = C "$Package-coop-view" @('list', '--json') | ConvertFrom-Json
    $coopView = @($coopList | Where-Object name -eq $Package)
    if (@($coopView).Count -ne 1 -or $coopView.version -ne $Version) { throw 'Coop view disagrees with standard installation' }
    $code = '$ErrorActionPreference="Stop"; & ' + "'" + $scoop.Replace("'", "''") + "' list '" + $Package + "' 6>" + '$null' + ' | Select-Object Name,Version,Source | ConvertTo-Json'
    $scoopView = @(Tool "$Package-scoop-view" 'powershell.exe' @('-NoProfile', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))) | ConvertFrom-Json)
    if ($scoopView.Count -ne 1 -or $scoopView[0].Name -ne $Package -or $scoopView[0].Version -ne $Version) { throw 'Scoop view disagrees with standard installation' }
    Write-FourSampleJson (Join-Path $run "$Package-installation-$($commands.Count).json") @{ current = $link.Target; records = $records; source_manifest_sha256 = $byId[$id].manifest_sha256; coop = $coopView; scoop = $scoopView }
}
function FunctionProbe([string]$Package) {
    switch ($Package) {
        jq {
            $version = Tool 'jq-version' (Join-Path $ScoopRoot 'shims/jq.exe') @('--version')
            if ($version.Trim() -ne ('jq-' + $script:jqVersion)) { throw 'jq executable version mismatch' }
            $out = Tool 'jq-json' (Join-Path $ScoopRoot 'shims/jq.exe') @('-n', '2+3')
            if ($out.Trim() -cne '5') { throw 'jq JSON calculation failed' }
        }
        wgcf {
            $out = Tool 'wgcf-help' (Join-Path $ScoopRoot 'shims/wgcf.exe') @('--help')
            if ($out -notmatch 'Usage:' -or $out -notmatch '--config') { throw 'Unexpected wgcf help output' }
            $shim = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $ScoopRoot 'shims/wgcf.shim') -Raw
            $target = Join-Path $ScoopRoot 'apps/wgcf/current/wgcf.exe'
            $config = Join-Path $ScoopRoot 'persist/wgcf/wgcf-account.toml'
            if ($shim -notmatch ('(?m)^path = "' + [regex]::Escape($target.Replace('/', '\')) + '"\s*$') -or $shim -notmatch ('(?m)^args = --config "' + [regex]::Escape($config.Replace('/', '\')) + '"\s*$')) { throw 'wgcf shim target or quoted config differs' }
        }
        pdd {
            $out = Tool 'pdd-date' (Join-Path $ScoopRoot 'shims/pdd.cmd') @('-d', '2024', 'jan', '1', '2024', 'jan', '11')
            Assert-FourSampleDate $out
        }
        posh-git {
            $code = '$env:PSModulePath=[Environment]::GetEnvironmentVariable("PSModulePath","User")+";"+[Environment]::GetEnvironmentVariable("PSModulePath","Machine"); Import-Module posh-git -ErrorAction Stop; Get-Module posh-git | Select-Object @{n="Version";e={$_.Version.ToString()}},ModuleBase | ConvertTo-Json'
            $out = Tool 'posh-import' 'powershell.exe' @('-NoProfile', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code)))
            Assert-FourSampleModule ($out | ConvertFrom-Json) $byId['posh-git'].version (Join-Path $ScoopRoot 'modules/posh-git')
            $link = Get-Item -LiteralPath (Join-Path $ScoopRoot 'modules/posh-git') -Force
            $expected = Join-Path $ScoopRoot "apps/posh-git/current"
            if ($link.LinkType -ne 'Junction' -or @($link.Target).Count -ne 1 -or [IO.Path]::GetFullPath($link.Target[0]).TrimEnd('\') -ine $expected.TrimEnd('\')) { throw 'Unexpected module junction target' }
        }
    }
}
function AuditModuleRemoval {
    if (-not $sources.scoop_removal_audit -or -not $sources.scoop_removal_audit.scope) { throw 'Blocked: a reviewed Scoop module-removal audit is required' }
    foreach ($file in @($sources.scoop_removal_audit.files)) {
        $path = Join-Path $ScoopRoot $file.relative_path
        $full = [IO.Path]::GetFullPath($path)
        if (-not $full.StartsWith($ScoopRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or -not (Test-FourSampleHash $full $file.sha256)) { throw 'Blocked: audited Scoop removal implementation changed' }
    }
    if (@($sources.scoop_removal_audit.files).Count -eq 0) { throw 'Blocked: empty Scoop removal audit' }
    FunctionProbe 'posh-git'
    Write-FourSampleJson (Join-Path $run "module-removal-audit-$($commands.Count).json") $sources.scoop_removal_audit
}
$savedPath = $env:PATH
$savedPythonPath = $env:PYTHONPATH
$savedScoop = $env:SCOOP
try {
    $env:SCOOP = $ScoopRoot
    Copy-Item -LiteralPath $SourceFile -Destination (Join-Path $run 'sources.json')
    $commit = Tool 'commit' 'git.exe' @('-C', $project, 'rev-parse', 'HEAD')
    $dirty = Tool 'working-diff' 'git.exe' @('-C', $project, 'status', '--porcelain')
    Write-FourSampleJson (Join-Path $run 'build.json') @{ commit = $commit.Trim(); dirty = $dirty; sha256 = $binaryHash; powershell = $PSVersionTable.PSVersion.ToString(); root = $ScoopRoot }
    S 'scoop-version' @('--version') | Out-Null
    foreach ($name in $plan.Keys) {
        Scene $name 'preflight' {
            CurrentManifest $name
            foreach ($path in @("apps/$name", "persist/$name", "modules/$name")) {
                if (Test-Path -LiteralPath (Join-Path $ScoopRoot $path)) { throw "Blocked: existing user object $path" }
            }
            if (@(Get-ChildItem -LiteralPath (Join-Path $ScoopRoot 'shims') -Force | Where-Object { $_.BaseName -eq $name -or $_.Name -eq $name }).Count) { throw "Blocked: existing entry for $name" }
            Snapshot "$name-baseline" $name | Out-Null
        }
    }
    Scene 'jq' 'forward' {
        Absent 'jq'
        S 'jq-install-old-forward' @('install', (OldJqManifest)) | Out-Null
        $script:jqVersion = $byId['jq-old'].version
        Installed 'jq' $script:jqVersion; FunctionProbe 'jq'
        Preview 'jq' 'update' | Out-Null
        CurrentManifest 'jq'
        C 'jq-update-forward' @('update', 'jq', '--json') | Out-Null
        $script:jqVersion = $byId['jq'].version
        Installed 'jq' $script:jqVersion; FunctionProbe 'jq'
        if (-not (Test-Path -LiteralPath (Join-Path $ScoopRoot "apps/jq/$($byId['jq-old'].version)"))) { throw 'Old jq was not retained' }
        S 'jq-scoop-uninstall' @('uninstall', 'jq') | Out-Null
    }
    Scene 'jq' 'reverse' {
        Absent 'jq'
        S 'jq-install-old-reverse' @('install', (OldJqManifest)) | Out-Null
        CurrentManifest 'jq'
        C 'jq-prepare-newer' @('update', 'jq', '--json') | Out-Null
        C 'jq-reset-old' @('reset', ('jq@' + $byId['jq-old'].version), '--json') | Out-Null
        $script:jqVersion = $byId['jq-old'].version
        Installed 'jq' $script:jqVersion; FunctionProbe 'jq'
        # -f releases Scoop's verified workspace version pin and resolves the accepted main source.
        S 'jq-scoop-update' @('update', 'main/jq', '-f') | Out-Null
        $script:jqVersion = $byId['jq'].version
        Installed 'jq' $script:jqVersion; FunctionProbe 'jq'
        if (-not (Test-Path -LiteralPath (Join-Path $ScoopRoot "apps/jq/$($byId['jq-old'].version)"))) { throw 'Reverse update lost old jq' }
    }
    Scene 'jq' 'cleanup' {
        Installed 'jq' $byId['jq'].version
        C 'jq-cleanup' @('cleanup', 'jq', '--json') | Out-Null
        if (Test-Path -LiteralPath (Join-Path $ScoopRoot "apps/jq/$($byId['jq-old'].version)")) { throw 'jq cleanup retained old version' }
        Installed 'jq' $byId['jq'].version
        C 'jq-coop-uninstall' @('uninstall', 'jq', '--json') | Out-Null
    }
    Scene 'jq' 'restore' {
        $before = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $run 'jq-baseline.json') -Raw | ConvertFrom-Json
        if (-not (Compare-FourSampleSnapshot $before (Snapshot 'jq-final' 'jq'))) { throw 'jq protected state not restored' }
    }
    foreach ($name in @('wgcf', 'pdd', 'posh-git')) {
        $baseline = Get-FourSampleSnapshot $ScoopRoot $name
        if ($name -eq 'pdd') {
            Scene $name 'missing-host' {
                try {
                    $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
                    $preview = Preview 'pdd' 'install' $false
                    if (($preview | ConvertTo-Json -Depth 30) -notmatch 'Python interpreter not found') { throw 'Missing Python diagnostic absent' }
                } finally { $env:PATH = $savedPath }
            }
            $env:PATH = (Split-Path $pythonExe -Parent) + ';' + $savedPath
            $env:PYTHONPATH = $pythonModules
        }
        Scene $name 'install' {
            Absent $name
            if ($name -eq 'pdd') {
                $probe = 'import sys,dateutil,six,json; print(json.dumps(dict(python=sys.version.split()[0],dateutil=dateutil.__version__,six=six.__version__,dateutil_file=dateutil.__file__,six_file=six.__file__)))'
                $runtime = Tool 'python-runtime' $pythonExe @('-c', $probe) | ConvertFrom-Json
                $modulePrefix = $pythonModules.TrimEnd('\') + '\'
                if ($runtime.python -ne $byId['python'].version -or $runtime.dateutil -ne $byId['python-dateutil'].version -or $runtime.six -ne $byId['six'].version -or -not $runtime.dateutil_file.StartsWith($modulePrefix, [StringComparison]::OrdinalIgnoreCase) -or -not $runtime.six_file.StartsWith($modulePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Python runtime or module origins differ' }
                Write-FourSampleJson (Join-Path $run 'python-installed-tree.json') @(Get-FourSampleTree $pythonModules 'python-modules')
            }
            Preview $name 'install' | Out-Null
            CurrentManifest $name
            C "$name-install" @('install', "$($byId[$name].bucket)/$name", '--json') | Out-Null
            Installed $name $byId[$name].version; FunctionProbe $name
            if ($name -eq 'wgcf') {
                $script:config = Join-Path $ScoopRoot 'persist/wgcf/wgcf-account.toml'
                if ((Get-Item -LiteralPath $config).Length -ne 0) { throw 'Unexpected wgcf configuration; left untouched' }
                [IO.File]::WriteAllText($config, '# Coop verification: no account credentials', [Text.Encoding]::ASCII)
                $script:configHash = (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash
            }
            $script:moduleEnvironment = [Environment]::GetEnvironmentVariable('PSModulePath', 'User')
            Snapshot "$name-installed" $name | Out-Null
        }
        Scene $name 'reset' {
            S "$name-reset" @('reset', $name) | Out-Null
            Installed $name $byId[$name].version; FunctionProbe $name
            if ($name -eq 'wgcf' -and -not (Test-FourSampleHash $config $configHash)) { throw 'Reset changed test configuration' }
            Snapshot "$name-reset" $name | Out-Null
        }
        Scene $name 'scoop-uninstall' {
            Installed $name $byId[$name].version
            if ($name -eq 'posh-git') { AuditModuleRemoval }
            S "$name-scoop-uninstall" @('uninstall', $name) | Out-Null
            if ($name -eq 'wgcf' -and -not (Test-FourSampleHash $config $configHash)) { throw 'Scoop uninstall changed test configuration' }
            Snapshot "$name-scoop-uninstalled" $name | Out-Null
        }
        Scene $name 'reinstall' {
            Absent $name
            CurrentManifest $name
            S "$name-scoop-install" @('install', "$($byId[$name].bucket)/$name") | Out-Null
            Installed $name $byId[$name].version; FunctionProbe $name
            if ($name -eq 'wgcf' -and -not (Test-FourSampleHash $config $configHash)) { throw 'Reinstall changed test configuration' }
            Snapshot "$name-reinstalled" $name | Out-Null
        }
        Scene $name 'coop-uninstall' {
            Installed $name $byId[$name].version
            if ($name -eq 'posh-git') { FunctionProbe $name }
            C "$name-coop-uninstall" @('uninstall', $name, '--json') | Out-Null
            if ($name -eq 'wgcf' -and -not (Test-FourSampleHash $config $configHash)) { throw 'Coop uninstall changed test configuration' }
            Snapshot "$name-coop-uninstalled" $name | Out-Null
        }
        Scene $name 'restore' {
            if ($name -eq 'wgcf') {
                if (-not (Test-FourSampleHash $config $configHash)) { throw 'Config changed concurrently; left untouched' }
                Remove-Item -LiteralPath $config
                $parent = Split-Path $config -Parent
                if (@(Get-ChildItem -LiteralPath $parent -Force).Count -eq 0) { Remove-Item -LiteralPath $parent }
            }
            if ($name -eq 'posh-git') {
                $original = @($baseline.user_environment | Where-Object name -eq 'PSModulePath')
                $originalValue = $null
                if ($original.Count) { $originalValue = $original[0].value }
                $current = [Environment]::GetEnvironmentVariable('PSModulePath', 'User')
                if ($current -ne $originalValue) {
                    if ($current -ne $moduleEnvironment) { throw 'User PSModulePath changed concurrently; left untouched' }
                    [Environment]::SetEnvironmentVariable('PSModulePath', $originalValue, 'User')
                }
            }
            if (-not (Compare-FourSampleSnapshot $baseline (Snapshot "$name-final" $name))) { throw "$name protected state not restored" }
        }
        $env:PATH = $savedPath
        $env:PYTHONPATH = $savedPythonPath
    }
    $report.status = 'lifecycle-pass-repository-checks-pending'
} catch {
    $report.status = 'incomplete'
    $report['error'] = $_.Exception.Message
    throw
} finally {
    $env:PATH = $savedPath
    $env:PYTHONPATH = $savedPythonPath
    $env:SCOOP = $savedScoop
    $report['finished_utc'] = [DateTime]::UtcNow.ToString('o')
    foreach ($package in $plan.Keys) {
        try {
            Write-FourSampleJson (Join-Path $run "$package-exit-state.json") (Get-FourSampleSnapshot $ScoopRoot $package)
        } catch {
            $report["$package-exit-snapshot-error"] = $_.Exception.Message
            $report.status = 'incomplete'
        }
    }
    SaveReport
    # No automatic uninstall or recursive deletion on failure. Preserve evidence and user state.
    Write-Host "Evidence: $run"
}

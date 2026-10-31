param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$EvidenceDir,
    [Parameter(Mandatory)][string]$Package,
    [Parameter(Mandatory)][string]$Command,
    [string[]]$CommandArguments = @(),
    [Parameter(Mandatory)][string]$ExpectedOutput,
    [int]$ExpectedExit = 0,
    [ValidateSet('bash','python')][string]$ExpectedHost = 'bash',
    [string]$ScoopRoot = (Join-Path $env:USERPROFILE 'scoop'),
    [string]$PythonHost = '',
    [switch]$SkipScoopReset
)
# Real command-entry host lifecycle (R26 / #47).
#
# Runs the real CLI against the selected installation root: read-only preview, install, inspection
# of the generated Scoop .cmd/sh wrapper, the real program through that .cmd, optionally a real
# `scoop reset` followed by the same entry, the other client's list view, and Coop uninstall.
# The child PATH for Coop and for the wrapper contains a real Git bash and, when needed, a real
# Python 3, but not the Windows system directory: Scoop's bash branch must take the cygpath path
# instead of accidentally running the WSL bash/wslpath pair. TERM=xterm is scoped to the wrapper
# child because the test starts from a non-terminal process.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
if (-not ($EvidenceDir.TrimEnd('\')+'\').StartsWith($projectRoot+'\',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'EvidenceDir must stay inside the project directory'
}
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$ScoopRoot = [IO.Path]::GetFullPath($ScoopRoot).TrimEnd('\')
if ($Package -notmatch '^([^/]+)/([^/]+)$') { throw 'Package must be qualified as bucket/name' }
$bucket = $Matches[1]
$packageName = $Matches[2]
$manifestPath = Join-Path $ScoopRoot "buckets/$bucket/bucket/$packageName.json"
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Package Manifest not found: $manifestPath" }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$coopRecord = Join-Path $ScoopRoot ".coop/packages/$packageName.json"
$entryCmd = Join-Path $ScoopRoot "shims/$Command.cmd"
$entryShell = Join-Path $ScoopRoot "shims/$Command"
$commands = [System.Collections.Generic.List[object]]::new()
$installedByTest = $false
function Assert-True([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
function Read-Json([object]$output) { return (($output -join "`n") | ConvertFrom-Json) }
function Find-GitBash {
    $candidates = [System.Collections.Generic.List[string]]::new()
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) {
        try {
            $execPath = (& $git.Source --exec-path 2>$null | Out-String).Trim()
            if ($execPath) { $candidates.Add([IO.Path]::GetFullPath((Join-Path $execPath '../../..'))) }
        } catch { }
        $candidates.Add([IO.Path]::GetFullPath((Join-Path (Split-Path $git.Source -Parent) 'apps/git/current')))
    }
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'Git')) }
    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Git')) }
    if ($env:LOCALAPPDATA) { $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs/Git')) }
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $usr = Join-Path $candidate 'usr/bin'
        if ((Test-Path -LiteralPath (Join-Path $usr 'bash.exe')) -and (Test-Path -LiteralPath (Join-Path $usr 'cygpath.exe'))) {
            return [pscustomobject]@{Root=$candidate;UsrBin=$usr;CommandBin=(Join-Path $candidate 'cmd');Bash=(Join-Path $usr 'bash.exe')}
        }
    }
    throw 'A real Git for Windows bash.exe and cygpath.exe are required'
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
            $version = (Invoke-CoopNative $candidate  --version | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $version -match '^Python 3\.') { return [IO.Path]::GetFullPath($candidate) }
        } catch { }
    }
    return $null
}
function Run([string]$name,[string]$exe,[string[]]$arguments,[string]$pathValue = $null,[string]$term = $null) {
    $savedPath = $env:PATH
    $savedTerm = $env:TERM
    try {
        if ($pathValue) { $env:PATH = $pathValue }
        if ($term) { $env:TERM = $term }
        $output = & $exe @arguments *>&1 | Out-String
        $exit = $LASTEXITCODE
    } finally {
        $env:PATH = $savedPath
        $env:TERM = $savedTerm
    }
    $log = Join-Path $EvidenceDir (($name -replace '[\\/:*?"<>|]','-')+'.log')
    Set-Content -LiteralPath $log -Value $output -Encoding utf8
    $commands.Add([pscustomobject]@{name=$name;exe=$exe;arguments=$arguments;exit=$exit;log=$log;path=$pathValue;term=$term})
    return [pscustomobject]@{exit=$exit;output=$output;log=$log}
}
function Coop([string]$name,[string[]]$arguments) {
    return Run $name $CoopExe (@('--root',$ScoopRoot)+$arguments) $hostPath
}
$git = Find-GitBash
$python = Find-PythonHost
if ($ExpectedHost -eq 'python' -and -not $python) { throw "This scenario needs a real Python 3 host; set -PythonHost" }
$pathParts = @($git.UsrBin,$git.CommandBin)
if ($python) { $pathParts = @((Split-Path $python -Parent))+$pathParts }
$hostPath = $pathParts -join ';'
$pathBefore = (Get-ItemProperty 'HKCU:\Environment' -Name Path -ErrorAction SilentlyContinue).Path
$pathKind = $null
try {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    $pathKind = if ($key.GetValueNames() -contains 'Path') { $key.GetValueKind('Path').ToString() } else { 'String' }
} finally { if ($key) { $key.Dispose() } }
$summary = [ordered]@{
    package = $Package
    command = $Command
    command_arguments = $CommandArguments
    expected_host = $ExpectedHost
    expected_output = $ExpectedOutput
    expected_exit = $ExpectedExit
    scoop_root = $ScoopRoot
    path_before = $pathBefore
    started = (Get-Date).ToUniversalTime().ToString('o')
}
try {
    $summary.coop_version = (Run 'coop-version' $CoopExe @('--version')).output.Trim()
    $summary.coop_sha256 = (Get-FileHash -LiteralPath $CoopExe -Algorithm SHA256).Hash.ToLower()
    $summary.package_version = [string]$manifest.version
    $summary.bucket_revision = (& git -C (Join-Path $ScoopRoot "buckets/$bucket") rev-parse HEAD 2>&1 | Out-String).Trim()
    $summary.bash = $git.Bash
    $summary.python = $python
    if (Test-Path -LiteralPath $coopRecord) { throw "$packageName already has a Coop record; refusing to change the selected root" }
    if (Test-Path -LiteralPath (Join-Path $ScoopRoot "apps/$packageName")) { throw "$packageName is already installed in $ScoopRoot" }
    if (-not $SkipScoopReset) { Run 'scoop-list-before' (Get-Command scoop.ps1 -ErrorAction Stop).Source @('list') | Out-Null }

    # --- Preview: no entry, package directory or Coop record ------------------------------------
    $preview = Coop 'preview' @('install',$Package,'--dry-run','--json')
    Assert-True ($preview.exit -eq 0) "preview failed: $($preview.output)"
    $plan = Read-Json $preview.output
    Assert-True ($plan.execution_available -eq $true) "preview was blocked: $($plan.diagnostics | ConvertTo-Json -Compress)"
    $launchers = @($plan.package.commands | ForEach-Object { "$($_.name):$($_.launcher)" })
    Assert-True ($launchers -contains "$($Command):$ExpectedHost") "preview did not disclose the $ExpectedHost host for ${Command}: $($launchers -join ',')"
    $hostTool = @($plan.external_tools | Where-Object { ($ExpectedHost -eq 'python' -and $_.name -like 'Python*') -or ($ExpectedHost -eq 'bash' -and $_.name -like 'bash*') })
    Assert-True ($hostTool.Count -eq 1 -and $hostTool[0].available -eq $true) 'preview did not detect the external command host'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $ScoopRoot "apps/$packageName"))) 'preview created the package directory'
    Assert-True (-not (Test-Path -LiteralPath $entryCmd)) 'preview created the command entry'

    # --- Install: the generated wrapper is the Scoop branch, and the real program runs ----------
    $install = Coop 'install' @('install',$Package,'--json')
    Assert-True ($install.exit -eq 0) "install failed: $($install.output)"
    $installedByTest = $true
    $result = Read-Json $install.output
    Assert-True ($result.status -eq 'success') "install did not report success: $($install.output)"
    $journal = Get-Content -LiteralPath $result.journal -Raw | ConvertFrom-Json
    Assert-True ((@($plan.ir_operations | ForEach-Object operation) -join ',') -eq (@($journal.observed_steps) -join ',')) `
        "execution did not follow the displayed plan: planned=$(@($plan.ir_operations | ForEach-Object operation) -join ',') observed=$(@($journal.observed_steps) -join ',')"
    Assert-True ((Test-Path -LiteralPath $entryCmd -PathType Leaf) -and (Test-Path -LiteralPath $entryShell -PathType Leaf)) "missing Scoop wrapper files: $entryCmd / $entryShell"
    foreach ($stale in @("$Command.exe","$Command.shim","$Command.coop-shim.json")) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $ScoopRoot "shims/$stale"))) "unexpected $stale for a $ExpectedHost entry"
    }
    $cmdText = Get-Content -LiteralPath $entryCmd -Raw
    $shellText = Get-Content -LiteralPath $entryShell -Raw
    $target = Join-Path $ScoopRoot "apps/$packageName/current"
    Assert-True ($cmdText.StartsWith("@rem ")) 'the generated .cmd is not a Scoop wrapper'
    Assert-True ($shellText.StartsWith("#!/bin/sh`n# ")) 'the generated shell wrapper is not a Scoop shim'
    if ($ExpectedHost -eq 'python') {
        Assert-True ($cmdText -match ('(?m)^@python "'+[regex]::Escape($target)+'\\')) '.py .cmd does not use the python host'
        Assert-True ($shellText -match 'python\.exe "') '.py shell wrapper does not use python.exe'
    } else {
        Assert-True ($cmdText -match 'bash -c "command -v wslpath') 'bash .cmd does not carry the Scoop wslpath/cygpath branch'
        Assert-True ($cmdText -match 'bash -c "\$\(cygpath -u') 'bash .cmd does not carry the Scoop cygpath branch'
        Assert-True ($shellText -match 'if \[ \$WSL_INTEROP \]') 'bash shell wrapper does not carry the Scoop WSL/cygpath branch'
    }
    $record = Get-Content -LiteralPath $coopRecord -Raw | ConvertFrom-Json
    $recorded = @($record.commands | Where-Object name -eq $Command)
    Assert-True ($recorded.Count -eq 1 -and $recorded[0].format -eq 'scoop-wrapper' -and $recorded[0].launcher -eq $ExpectedHost) 'the package record did not keep the Scoop wrapper identity'
    $firstRun = Run 'run-before-reset' $entryCmd $CommandArguments $hostPath 'xterm'
    Assert-True ($firstRun.exit -eq $ExpectedExit) "the entry exit code was $($firstRun.exit), expected $ExpectedExit`: $($firstRun.output)"
    Assert-True ($firstRun.output -match $ExpectedOutput) "the entry output did not match '$ExpectedOutput': $($firstRun.output)"

    # --- The other client rebuilds the same entry and it still runs ------------------------------
    if (-not $SkipScoopReset) {
        $scoop = (Get-Command scoop.ps1 -ErrorAction Stop).Source
        $reset = Run 'scoop-reset' $scoop @('reset',$packageName)
        Assert-True ($reset.exit -eq 0) "scoop reset failed: $($reset.output)"
        $resetText = Get-Content -LiteralPath $entryCmd -Raw
        Assert-True ($resetText.StartsWith("@rem ")) 'scoop reset did not leave a Scoop .cmd entry'
        if ($ExpectedHost -eq 'python') { Assert-True ($resetText -match '(?m)^@python "') 'scoop reset did not rebuild the .py branch' }
        else { Assert-True ($resetText -match 'bash -c "command -v wslpath') 'scoop reset did not rebuild the bash branch' }
        $secondRun = Run 'run-after-reset' $entryCmd $CommandArguments $hostPath 'xterm'
        Assert-True ($secondRun.exit -eq $ExpectedExit) "the entry after scoop reset exited $($secondRun.exit), expected $ExpectedExit`: $($secondRun.output)"
        Assert-True ($secondRun.output -match $ExpectedOutput) "the entry after scoop reset did not match '$ExpectedOutput': $($secondRun.output)"
        $scoopList = Run 'scoop-list' $scoop @('list')
        Assert-True ($scoopList.exit -eq 0) "scoop list failed: $($scoopList.output)"
        Assert-True (($scoopList.output -split "`r?`n" | Where-Object { $_ -match ('^\s*'+[regex]::Escape($packageName)+'\s') }).Count -ge 1) `
            "Scoop did not list the Coop-installed package: $($scoopList.output)"
    }

    # --- Uninstall removes the wrapper files and the package ------------------------------------
    $uninstall = Coop 'uninstall' @('uninstall',$packageName,'--json')
    Assert-True ($uninstall.exit -eq 0) "uninstall failed: $($uninstall.output)"
    $installedByTest = $false
    $uninstallResult = Read-Json $uninstall.output
    Assert-True ($uninstallResult.status -eq 'success') 'uninstall did not report success'
    foreach ($left in @("apps/$packageName","shims/$Command.cmd","shims/$Command",".coop/packages/$packageName.json")) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $ScoopRoot $left))) "uninstall left $left"
    }
    if (-not $SkipScoopReset) {
        $scoop = (Get-Command scoop.ps1 -ErrorAction Stop).Source
        $scoopListAfter = Run 'scoop-list-after' $scoop @('list')
        Assert-True ($scoopListAfter.exit -eq 0) "scoop list failed after uninstall: $($scoopListAfter.output)"
        Assert-True (($scoopListAfter.output -split "`r?`n" | Where-Object { $_ -match ('^\s*'+[regex]::Escape($packageName)+'\s') }).Count -eq 0) `
            "Scoop still lists the uninstalled package: $($scoopListAfter.output)"
    }
    $pathAfter = (Get-ItemProperty 'HKCU:\Environment' -Name Path -ErrorAction SilentlyContinue).Path
    Assert-True ($pathAfter -eq $pathBefore) 'the command-entry install changed the user Path'
    $summary.status = 'passed'
} catch {
    $summary.status = 'failed'
    $summary.error = $_.Exception.Message
    throw
} finally {
    if ($installedByTest) {
        try { & $CoopExe --root $ScoopRoot uninstall $packageName --json *> (Join-Path $EvidenceDir 'cleanup-uninstall.log') } catch { }
    }
    $pathAfter = (Get-ItemProperty 'HKCU:\Environment' -Name Path -ErrorAction SilentlyContinue).Path
    if ($pathAfter -ne $pathBefore) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$true)
        try { $key.SetValue('Path',$pathBefore,[Microsoft.Win32.RegistryValueKind]$pathKind) } finally { $key.Dispose() }
        $summary.path_restored = 'snapshot'
    }
    $summary.commands = $commands
    $summary.path_after = (Get-ItemProperty 'HKCU:\Environment' -Name Path -ErrorAction SilentlyContinue).Path
    $summary.finished = (Get-Date).ToUniversalTime().ToString('o')
    $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $EvidenceDir 'summary.json') -Encoding utf8
}
Write-Output "PASS real command-entry lifecycle for $Package ($Command via $ExpectedHost) on $ScoopRoot"

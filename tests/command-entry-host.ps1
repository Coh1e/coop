param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$TestRoot,
    [string]$PythonHost = '',
    [switch]$RequirePythonHost
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$session = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
$root = Join-Path $session 'root'
$tag = [guid]::NewGuid().ToString('N').Substring(0,8)
$emptyPath = Join-Path $session 'empty-path'
New-Item -ItemType Directory -Path "$root/buckets/test/bucket",$emptyPath -Force | Out-Null
function Assert-True([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
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
function Write-Manifest([string]$name,[string]$version,[string]$entry,[string]$arguments = '') {
    $archive = Join-Path $session "$name-$version.zip"
    $body = if ($entry.EndsWith('.py')) {
        "import sys`nprint('py-host=' + '|'.join(sys.argv[1:]))`nsys.exit(6)`n"
    } elseif ($entry.EndsWith('.config')) {
        "#!/bin/sh`nprintf 'config-host=%s\n' `"`$*`"`nexit 8`n"
    } else {
        "#!/bin/sh`nprintf 'plain-host=%s\n' `"`$*`"`nexit 7`n"
    }
    New-ZipPackage $archive ([ordered]@{ $entry = $body })
    $tuple = @($entry,($name+'-tool'))
    if ($arguments) { $tuple += $arguments }
    $bin = @(,$tuple)
    $manifest = @{version=$version;url=(File-Uri $archive)+'#/dl.zip';hash=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower();bin=$bin}
    [IO.File]::WriteAllText("$root/buckets/test/bucket/$name.json",($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
function Invoke-Coop([string[]]$arguments,[string]$pathValue = $null) {
    $saved = $env:PATH
    if ($null -ne $pathValue) { $env:PATH = $pathValue }
    try {
        $output = Invoke-CoopNative $CoopExe  @arguments | Out-String
        return [pscustomobject]@{code=$LASTEXITCODE;text=$output}
    } finally { $env:PATH = $saved }
}
function CoopJson([string[]]$arguments,[string]$pathValue = $null) {
    $result = Invoke-Coop $arguments $pathValue
    if ($result.code -ne 0) { throw "coop $($arguments -join ' ') failed with exit $($result.code)`n$($result.text)" }
    return ($result.text | ConvertFrom-Json)
}
function Invoke-Program([string]$exe,[string[]]$arguments,[string]$pathValue) {
    $saved = $env:PATH
    $env:PATH = $pathValue
    try {
        $output = Invoke-CoopNative $exe  @arguments | Out-String
        return [pscustomobject]@{code=$LASTEXITCODE;text=$output.Trim()}
    } finally { $env:PATH = $saved }
}
function Get-Snapshot([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-ChildItem -LiteralPath $path -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $kind = if ($_.LinkType) { [string]$_.LinkType } else { 'file' }
        $hash = if ($_.PSIsContainer -or $_.LinkType) { '' } else { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
        $_.FullName.Substring($path.Length)+':'+$kind+':'+$hash
    })
}
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
        $bin = Join-Path $candidate 'usr/bin'
        if ((Test-Path -LiteralPath (Join-Path $bin 'bash.exe')) -and (Test-Path -LiteralPath (Join-Path $bin 'cygpath.exe'))) {
            return [pscustomobject]@{Directory=$bin;Bash=(Join-Path $bin 'bash.exe')}
        }
    }
    throw 'A real Git for Windows bash.exe and cygpath.exe are required for the bash entry cases'
}
function Test-PythonHost([string]$exe) {
    if (-not $exe -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $false }
    try {
        $version = (Invoke-CoopNative $exe  --version | Out-String).Trim()
        return $LASTEXITCODE -eq 0 -and $version -match '^Python 3\.'
    } catch { return $false }
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
    foreach ($candidate in $candidates) { if (Test-PythonHost $candidate) { return [IO.Path]::GetFullPath($candidate) } }
    return $null
}
$git = Find-GitBash
$python = Find-PythonHost
if (-not $python -and $RequirePythonHost) { throw 'RequirePythonHost was set but no real Python 3 host was found' }
$bashPath = $git.Directory
$hostPath = if ($python) { (Split-Path $python -Parent)+';'+$bashPath } else { $bashPath }
$pyPath = if ($python) { (Split-Path $python -Parent)+';'+$bashPath } else { $bashPath }
Write-Output ("command-entry hosts: bash={0} python={1}" -f $git.Bash,$(if ($python) { $python } else { 'not found; positive .py run skipped' }))

function Assert-Content([string]$path,[string]$expected,[string]$label) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "missing $label`: $path"
    $actual = Get-Content -LiteralPath $path -Raw
    if ($actual -ne $expected) {
        # The exact bytes matter here, so the failure shows the line endings instead of letting the
        # console silently normalise them.
        $show = { param($text) $text -replace "`r",'<CR>' -replace "`n",'<LF>' }
        throw "$label content differs`nexpected:`n$(& $show $expected)`nactual:`n$(& $show $actual)"
    }
}
function Assert-EntryFiles([string]$name,[string]$kind,[string]$target,[string]$arguments) {
    $shims = Join-Path $root 'shims'
    foreach ($unexpected in @("$name.exe","$name.shim","$name.coop-shim.json")) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $shims $unexpected))) "unexpected $unexpected for a $kind entry"
    }
    $quoted = if ($arguments) { '"'+$arguments+'"' } else { '' }
    if ($kind -eq 'python') {
        $cmdExpected = @'
@rem {TARGET}
@python "{TARGET}" {ARG} %*
'@.Replace('{TARGET}',$target).Replace('{ARG}',$arguments)
        $shellExpected = @'
#!/bin/sh
# {TARGET}
python.exe "{TARGET}" {ARG} "$@"
'@.Replace('{TARGET}',$target).Replace('{ARG}',$arguments)
    } else {
        $cmdExpected = @'
@rem {TARGET}
@echo off
bash -c "command -v wslpath >/dev/null"
if %errorlevel% equ 0 (
  bash "$(wslpath -u '{TARGET}')" {ARGQUOTED} %*
) else (
  set args={ARGQUOTED} %*
  setlocal enabledelayedexpansion
  if not "!args!"=="" set args=!args:"=""!
  bash -c "$(cygpath -u '{TARGET}') !args!"
)
'@.Replace('{TARGET}',$target).Replace('{ARGQUOTED}',$quoted)
        $shellExpected = @'
#!/bin/sh
# {TARGET}
if [ $WSL_INTEROP ]
then
  "$(wslpath -u '{TARGET}')" {ARG} "$@"
else
  "$(cygpath -u '{TARGET}')" {ARG} "$@"
fi
'@.Replace('{TARGET}',$target).Replace('{ARG}',$arguments)
    }
    # The repository stores this script with LF; Scoop's .cmd files use CRLF.
    Assert-Content (Join-Path $shims "$name.cmd") ($cmdExpected.Replace("`n","`r`n")) "Scoop $kind .cmd"
    Assert-Content (Join-Path $shims $name) $shellExpected "Scoop $kind shell wrapper"
}

if ($python) {
    # --- .py: preview and real Python host through the generated Scoop .cmd and shell wrapper -----
    Write-Manifest 'pyhost' '1.0.0' 'tool.py' '--default'
    $pyRootBefore = Get-Snapshot $root
    $pyPreview = CoopJson @('--root',$root,'install','test/pyhost','--dry-run','--json') $pyPath
    Assert-True ($pyPreview.execution_available -eq $true) "py preview was blocked: $($pyPreview.diagnostics | ConvertTo-Json -Compress)"
    Assert-True ((@($pyPreview.package.commands | ForEach-Object launcher) -contains 'python')) 'py preview did not disclose the python host'
    $pythonTool = @($pyPreview.external_tools | Where-Object { $_.name -like 'Python*' })
    Assert-True ($pythonTool.Count -eq 1 -and $pythonTool[0].available -eq $true) 'py preview did not disclose the Python host as available'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'shims'))) 'py preview created shims'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'apps/pyhost'))) 'py preview created the package'
    Assert-True (($pyRootBefore -join '|') -eq ((Get-Snapshot $root) -join '|')) 'py preview changed the root'

    $pyInstall = CoopJson @('--root',$root,'install','test/pyhost','--json') $pyPath
    Assert-True ($pyInstall.status -eq 'success') "py install failed: $($pyInstall | ConvertTo-Json -Depth 4)"
    $journal = Get-Content -LiteralPath $pyInstall.journal -Raw | ConvertFrom-Json
    Assert-True ((@($pyPreview.ir_operations | ForEach-Object operation) -join ',') -eq (@($journal.observed_steps) -join ',')) 'py install did not follow its displayed plan'
    $pyTarget = Join-Path $root 'apps/pyhost/current/tool.py'
    Assert-EntryFiles 'pyhost-tool' 'python' $pyTarget '--default'
    $record = Get-Content -LiteralPath (Join-Path $root '.coop/packages/pyhost.json') -Raw | ConvertFrom-Json
    $pyRecord = @($record.commands | Where-Object name -eq 'pyhost-tool')
    Assert-True ($pyRecord.Count -eq 1 -and $pyRecord[0].format -eq 'scoop-wrapper' -and $pyRecord[0].launcher -eq 'python') 'py management record did not keep the Scoop wrapper identity'
    $run = Invoke-Program (Join-Path $root 'shims/pyhost-tool.cmd') @('extra') $pyPath
    Assert-True ($run.code -eq 6 -and $run.text -eq 'py-host=--default|extra') "py .cmd did not run through Python with arguments and exit code: exit=$($run.code) output=$($run.text)"
    $shellRun = Invoke-Program $git.Bash @((Join-Path $root 'shims/pyhost-tool'),'extra') $pyPath
    Assert-True ($shellRun.code -eq 6 -and $shellRun.text -eq 'py-host=--default|extra') "py shell wrapper did not run through Python: exit=$($shellRun.code) output=$($shellRun.text)"

    # --- update replaces the wrapper and uninstall removes both files -----------------------------
    Write-Manifest 'pyhost' '2.0.0' 'tool.py' '--default'
    $updatePreview = CoopJson @('--root',$root,'update','pyhost','--dry-run','--json') $pyPath
    Assert-True ($updatePreview.execution_available -eq $true) 'py update preview was blocked'
    $update = CoopJson @('--root',$root,'update','pyhost','--json') $pyPath
    Assert-True ($update.status -eq 'success') "py update failed: $($update | ConvertTo-Json -Depth 4)"
    Assert-EntryFiles 'pyhost-tool' 'python' $pyTarget '--default'
    $updated = Invoke-Program (Join-Path $root 'shims/pyhost-tool.cmd') @('v2') $pyPath
    Assert-True ($updated.code -eq 6 -and $updated.text -eq 'py-host=--default|v2') 'py update did not republish a working wrapper'
    # Removing an existing wrapper must not require the host that is no longer needed.
    $pyUninstall = CoopJson @('--root',$root,'uninstall','pyhost','--json') $emptyPath
    Assert-True ($pyUninstall.status -eq 'success') "py uninstall failed: $($pyUninstall | ConvertTo-Json -Depth 4)"
    # The update keeps 1.0.0 by design; the current link and the 2.0.0 version must be gone.
    foreach ($left in @('shims/pyhost-tool.cmd','shims/pyhost-tool','apps/pyhost/current','apps/pyhost/2.0.0')) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $root $left))) "py uninstall left $left"
    }
} else {
    Write-Output 'SKIP positive .py run: no real Python 3 host is available; the missing-host path is still checked'
}

# --- Bash else-branch: extensionless and .config entries -----------------------------------------
Write-Manifest 'plainhost' '1.0.0' 'plain-script' '--default'
$plainPreview = CoopJson @('--root',$root,'install','test/plainhost','--dry-run','--json') $hostPath
Assert-True ($plainPreview.execution_available -eq $true) "extensionless preview was blocked: $($plainPreview.diagnostics | ConvertTo-Json -Compress)"
Assert-True ((@($plainPreview.package.commands | ForEach-Object launcher) -contains 'bash')) 'extensionless preview did not disclose the bash host'
foreach ($created in @('shims/plainhost-tool.cmd','shims/plainhost-tool','apps/plainhost')) {
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root $created))) "extensionless preview created $created"
}
$plainInstall = CoopJson @('--root',$root,'install','test/plainhost','--json') $hostPath
Assert-True ($plainInstall.status -eq 'success') "extensionless install failed: $($plainInstall | ConvertTo-Json -Depth 4)"
$plainTarget = Join-Path $root 'apps/plainhost/current/plain-script'
Assert-EntryFiles 'plainhost-tool' 'bash' $plainTarget '--default'
$plainRun = Invoke-Program (Join-Path $root 'shims/plainhost-tool.cmd') @('extra') $hostPath
Assert-True ($plainRun.code -eq 7 -and $plainRun.text -eq 'plain-host=--default extra') "extensionless .cmd did not run through bash: exit=$($plainRun.code) output=$($plainRun.text)"
$plainShell = Invoke-Program $git.Bash @((Join-Path $root 'shims/plainhost-tool'),'extra') $hostPath
Assert-True ($plainShell.code -eq 7 -and $plainShell.text -eq 'plain-host=--default extra') "extensionless shell wrapper did not run through bash: exit=$($plainShell.code) output=$($plainShell.text)"
$plainUninstall = CoopJson @('--root',$root,'uninstall','plainhost','--json') $emptyPath
Assert-True ($plainUninstall.status -eq 'success') 'extensionless uninstall failed'
foreach ($left in @('shims/plainhost-tool.cmd','shims/plainhost-tool','apps/plainhost')) {
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root $left))) "extensionless uninstall left $left"
}

Write-Manifest 'confighost' '1.0.0' 'tool.config'
$configPreview = CoopJson @('--root',$root,'install','test/confighost','--dry-run','--json') $hostPath
Assert-True ($configPreview.execution_available -eq $true) "config preview was blocked: $($configPreview.diagnostics | ConvertTo-Json -Compress)"
$configInstall = CoopJson @('--root',$root,'install','test/confighost','--json') $hostPath
Assert-True ($configInstall.status -eq 'success') "config install failed: $($configInstall | ConvertTo-Json -Depth 4)"
$configTarget = Join-Path $root 'apps/confighost/current/tool.config'
Assert-EntryFiles 'confighost-tool' 'bash' $configTarget ''
$configRun = Invoke-Program (Join-Path $root 'shims/confighost-tool.cmd') @('extra') $hostPath
Assert-True ($configRun.code -eq 8 -and $configRun.text -eq 'config-host=extra') "config .cmd did not run through bash: exit=$($configRun.code) output=$($configRun.text)"
$configUninstall = CoopJson @('--root',$root,'uninstall','confighost','--json') $emptyPath
Assert-True ($configUninstall.status -eq 'success') 'config uninstall failed'
foreach ($left in @('shims/confighost-tool.cmd','shims/confighost-tool','apps/confighost')) {
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root $left))) "config uninstall left $left"
}

# --- Missing external hosts: explicit, non-zero and before any entry is published ----------------
$missingRoot = Join-Path $session 'missing-root'
New-Item -ItemType Directory -Path "$missingRoot/buckets/test/bucket" -Force | Out-Null
$root = $missingRoot
Write-Manifest 'pymissing' '1.0.0' 'tool.py'
$pyMissingPreview = Invoke-Coop @('--root',$missingRoot,'install','test/pymissing','--dry-run','--json') $emptyPath
$pyMissingPlan = $pyMissingPreview.text | ConvertFrom-Json
Assert-True ($pyMissingPlan.execution_available -eq $false) 'py preview without Python reported an executable plan'
Assert-True (@($pyMissingPlan.diagnostics | Where-Object { $_.message -match 'Python interpreter not found' }).Count -ge 1) 'py preview did not name the missing Python host'
$pyMissingInstall = Invoke-Coop @('--root',$missingRoot,'install','test/pymissing','--json') $emptyPath
Assert-True ($pyMissingInstall.code -ne 0 -and $pyMissingInstall.text -match 'Python interpreter not found') 'py install without Python did not fail explicitly'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $missingRoot 'shims'))) 'failed py install created a command entry'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $missingRoot 'apps/pymissing'))) 'failed py install created the package'
Write-Manifest 'bashmissing' '1.0.0' 'plain-script'
$bashMissingPreview = Invoke-Coop @('--root',$missingRoot,'install','test/bashmissing','--dry-run','--json') $emptyPath
$bashMissingPlan = $bashMissingPreview.text | ConvertFrom-Json
Assert-True ($bashMissingPlan.execution_available -eq $false) 'extensionless preview without bash reported an executable plan'
Assert-True (@($bashMissingPlan.diagnostics | Where-Object { $_.message -match 'bash not found' }).Count -ge 1) 'extensionless preview did not name the missing bash host'
$bashMissingInstall = Invoke-Coop @('--root',$missingRoot,'install','test/bashmissing','--json') $emptyPath
Assert-True ($bashMissingInstall.code -ne 0 -and $bashMissingInstall.text -match 'bash not found') 'extensionless install without bash did not fail explicitly'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $missingRoot 'shims'))) 'failed extensionless install created a command entry'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $missingRoot 'apps/bashmissing'))) 'failed extensionless install created the package'

Write-Output ("PASS command entry hosts: python={0}, bash extensionless and .config ran, missing hosts diagnosed before writes ({1})" -f $(if ($python) { 'ran' } else { 'skipped' }),$root)

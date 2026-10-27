param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$TestRoot,
    [string]$PythonHost = ''
)
# R27/#48: Manifest shapes Scoop actually accepts. The adapter must normalize arbitrary bin tuples,
# env_add_path "." / "./" / trailing separators, shortcut targets and icons that use parent
# components, and a repeated derived alias with Scoop's last-wins overwrite (reported, never silent),
# while every absolute, drive-qualified and escaping write path stays rejected.
$ErrorActionPreference = 'Stop'
# Coop writes UTF-8; the test root deliberately contains non-ASCII characters, so decode child
# output with the same encoding before comparing paths and messages.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$build = Split-Path $CoopExe
$envFixture = Join-Path $build 'fixture-env.exe'
if (-not (Test-Path -LiteralPath $envFixture)) { throw "Missing fixed test input: $envFixture" }
$session = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
$root = Join-Path $session 'root'
$programs = Join-Path $session 'programs'
New-Item -ItemType Directory -Path "$root/buckets/test/bucket","$root/shims",$programs -Force | Out-Null
$env:COOP_PROGRAMS_DIR = $programs
$envFixtureBytes = [IO.File]::ReadAllBytes($envFixture)
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
                $bytes = if ($entries[$name] -is [byte[]]) { $entries[$name] } else { [Text.UTF8Encoding]::new($false).GetBytes([string]$entries[$name]) }
                $target.Write($bytes,0,$bytes.Length)
            } finally { $target.Dispose() }
        }
    } finally { $zip.Dispose(); $stream.Dispose() }
}
function Write-Manifest([string]$name,[hashtable]$body) {
    $manifest = [ordered]@{version='1.0';description=$name}
    foreach ($key in $body.Keys) { $manifest[$key] = $body[$key] }
    [IO.File]::WriteAllText("$root/buckets/test/bucket/$name.json",($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
function Invoke-Coop([string[]]$arguments,[string]$pathValue = $null) {
    $saved = $env:PATH
    if ($null -ne $pathValue) { $env:PATH = $pathValue }
    try {
        $output = & $CoopExe @arguments 2>&1 | Out-String
        return [pscustomobject]@{code=$LASTEXITCODE;text=$output}
    } finally { $env:PATH = $saved }
}
function CoopJson([string[]]$arguments,[string]$pathValue = $null) {
    $result = Invoke-Coop $arguments $pathValue
    if ($result.code -ne 0) { throw "coop $($arguments -join ' ') failed with exit $($result.code)`n$($result.text)" }
    return ($result.text | ConvertFrom-Json)
}
function Invoke-Program([string]$exe,[string[]]$arguments,[string]$pathValue = $null) {
    $saved = $env:PATH
    if ($null -ne $pathValue) { $env:PATH = $pathValue }
    try {
        $output = & $exe @arguments 2>&1 | Out-String
        return [pscustomobject]@{code=$LASTEXITCODE;text=$output}
    } finally { $env:PATH = $saved }
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
$python = Find-PythonHost
$hasPython = $null -ne $python
$pythonPath = if ($hasPython) { (Split-Path $python -Parent) + ';' + $env:PATH } else { $env:PATH }
$checks = [System.Collections.Generic.List[string]]::new()
function Check([bool]$condition,[string]$message) { if (-not $condition) { throw $message }; $checks.Add($message) }
function DiagnosticCodes($plan) {
    return @($plan.diagnostics | Where-Object { $_.category -ne 'verification' } | ForEach-Object { "$($_.category)/$($_.code)" })
}

# --- 1. Arbitrary-length bin tuple: every element after the alias is one argument string --------
$binArgs = Join-Path $session 'binargs.exe'
Copy-Item -LiteralPath $envFixture -Destination $binArgs
$persistArgs = Join-Path $root 'persist/binargs/probe.toml'
Write-Manifest 'binargs' @{url=(File-Uri $binArgs)+'#/probe.exe';hash=(Get-FileHash -LiteralPath $binArgs -Algorithm SHA256).Hash.ToLower();
    bin=@(,@('probe.exe','probe','--config','"$persist_dir\probe.toml"','--flag'))}
$binPlan = CoopJson @('--root',$root,'install','test/binargs','--dry-run','--json')
Check ([bool]$binPlan.execution_available) 'a five-element bin tuple is executable'
Check (@($binPlan.package.commands).Count -eq 1) 'the five-element bin tuple produced one command entry'
$command = @($binPlan.package.commands)[0]
Check ($command.target -eq 'probe.exe' -and $command.name -eq 'probe') 'the bin tuple target and alias are preserved'
$expectedArgs = (@('--config',('"'+$persistArgs+'"'),'--flag') -join ' ')
Check ($command.arguments -eq $expectedArgs) "bin tuple arguments are '$($command.arguments)', expected '$expectedArgs'"
$binInstall = CoopJson @('--root',$root,'install','test/binargs','--json')
Check ((Test-Path -LiteralPath "$root/shims/probe.exe") -and (Test-Path -LiteralPath "$root/shims/probe.shim")) 'the multi-argument shim was published'
$shimText = [IO.File]::ReadAllText("$root/shims/probe.shim")
Check ($shimText -match ('args = '+[regex]::Escape($expectedArgs))) "the .shim metadata does not carry the joined arguments: $shimText"
$run = Invoke-Program "$root/shims/probe.exe" @('extra')
Check ($run.code -eq 0) "the multi-argument shim did not run: $($run.text)"
Check (($run.text -match [regex]::Escape('[--config]')) -and ($run.text -match [regex]::Escape("[$persistArgs]")) -and
    ($run.text -match [regex]::Escape('[--flag]')) -and ($run.text -match [regex]::Escape('[extra]'))) "the shim did not forward every declared and caller argument: $($run.text)"
CoopJson @('--root',$root,'uninstall','binargs','--json') | Out-Null
Check (-not (Test-Path -LiteralPath "$root/shims/probe.exe") -and -not (Test-Path -LiteralPath "$root/shims/probe.shim")) 'uninstall removed the multi-argument shim'

# --- 2. env_add_path ".", "./", "./bin/" and a trailing separator -------------------------------
Write-Manifest 'envpaths' @{url='https://example.invalid/envpaths.zip';hash=('0'*64);env_add_path=@('./bin/','sub\','.','./')}
$envPlan = CoopJson @('--root',$root,'install','test/envpaths','--dry-run','--json')
Check ([bool]$envPlan.execution_available) 'the env_add_path variants are executable'
$base = Join-Path $root 'apps/envpaths/current'
# Each declared element resolves independently; "." and "./" both name the version directory.
$expectedPaths = @((Join-Path $base 'bin'),(Join-Path $base 'sub'),$base,$base)
$actualPaths = @($envPlan.exposure.path_entries)
Check ($actualPaths.Count -eq $expectedPaths.Count) "env_add_path resolved $($actualPaths.Count) entries, expected $($expectedPaths.Count): $($actualPaths -join ', ')"
for ($index = 0; $index -lt $expectedPaths.Count; $index++) {
    Check (([IO.Path]::GetFullPath($actualPaths[$index])) -eq ([IO.Path]::GetFullPath($expectedPaths[$index]))) "env_add_path[$index] is '$($actualPaths[$index])', expected '$($expectedPaths[$index])'"
}
Check (@($envPlan.diagnostics | Where-Object { $_.category -ne 'verification' }).Count -eq 0) 'the accepted env_add_path shapes reported no diagnostics'

# --- 3. Shortcut target and icon with parent components ----------------------------------------
$shortcutZip = Join-Path $session 'shortcut-parent.zip'
New-ZipPackage $shortcutZip ([ordered]@{'probe.exe'=$envFixtureBytes})
$selfCmd = Join-Path $root 'shims/self.cmd'
$selfIco = Join-Path $root 'shims/self.ico'
Set-Content -LiteralPath $selfCmd -Value '@echo off' -NoNewline
Set-Content -LiteralPath $selfIco -Value 'icon placeholder' -NoNewline
Write-Manifest 'shortcut-parent' @{url=(File-Uri $shortcutZip);hash=(Get-FileHash -LiteralPath $shortcutZip -Algorithm SHA256).Hash.ToLower();
    bin='probe.exe';shortcuts=@(,@('..\..\..\shims\self.cmd','Probe Tool','--flag','..\..\..\shims\self.ico'))}
$shortcutPlan = CoopJson @('--root',$root,'install','test/shortcut-parent','--dry-run','--json')
Check ([bool]$shortcutPlan.execution_available) 'the parent-relative shortcut is executable'
$declaredShortcut = @($shortcutPlan.package.shortcuts)[0]
$expectedTarget = [IO.Path]::GetFullPath((Join-Path (Join-Path $root 'apps/shortcut-parent/current') '..\..\..\shims\self.cmd'))
$expectedIcon = [IO.Path]::GetFullPath((Join-Path (Join-Path $root 'apps/shortcut-parent/current') '..\..\..\shims\self.ico'))
Check ($declaredShortcut.target -eq '..\..\..\shims\self.cmd') "the declared shortcut target changed: '$($declaredShortcut.target)'"
$plannedShortcut = @($shortcutPlan.exposure.shortcuts)[0]
Check ([IO.Path]::GetFullPath($plannedShortcut.target) -eq $expectedTarget) "the planned shortcut target is '$($plannedShortcut.target)', expected '$expectedTarget'"
Check ([IO.Path]::GetFullPath($plannedShortcut.icon) -eq $expectedIcon) "the planned shortcut icon is '$($plannedShortcut.icon)', expected '$expectedIcon'"
$shortcutInstall = CoopJson @('--root',$root,'install','test/shortcut-parent','--json')
$link = Join-Path $programs 'Probe Tool.lnk'
Check (Test-Path -LiteralPath $link) 'the parent-relative shortcut was created'
$shell = New-Object -ComObject WScript.Shell
$shortcutIdentity = $shell.CreateShortcut($link)
Check (([IO.Path]::GetFullPath($shortcutIdentity.TargetPath)) -eq $expectedTarget) "the real shortcut target is '$($shortcutIdentity.TargetPath)'"
Check (([IO.Path]::GetFullPath(($shortcutIdentity.IconLocation -replace ',\d+$',''))) -eq $expectedIcon) "the real shortcut icon is '$($shortcutIdentity.IconLocation)'"
Check ($shortcutIdentity.Arguments -eq '--flag') "the real shortcut arguments are '$($shortcutIdentity.Arguments)'"
CoopJson @('--root',$root,'uninstall','shortcut-parent','--json') | Out-Null
Check (-not (Test-Path -LiteralPath $link)) 'uninstall removed the parent-relative shortcut'

# --- 4. Repeated derived alias: Scoop last-wins with a reported warning ------------------------
$duplicateZip = Join-Path $session 'duplicate-alias.zip'
New-ZipPackage $duplicateZip ([ordered]@{
    'probe.exe'=$envFixtureBytes
    'probe.py'="print('python-entry')`n"
})
Write-Manifest 'duplicate-alias' @{url=(File-Uri $duplicateZip);hash=(Get-FileHash -LiteralPath $duplicateZip -Algorithm SHA256).Hash.ToLower();bin=@('probe.exe','probe.py')}
$duplicatePlan = CoopJson @('--root',$root,'install','test/duplicate-alias','--dry-run','--json')
$duplicateCommands = @($duplicatePlan.package.commands)
Check ($duplicateCommands.Count -eq 1) "the repeated alias produced $($duplicateCommands.Count) entries, expected 1"
Check ($duplicateCommands[0].name -eq 'probe' -and $duplicateCommands[0].target -eq 'probe.py') "the last declaration did not win: $($duplicateCommands[0] | ConvertTo-Json -Compress)"
$duplicateWarnings = @($duplicatePlan.warnings)
Check ($duplicateWarnings.Count -eq 1) "the overwrite was not reported as a warning: $($duplicatePlan | ConvertTo-Json -Depth 6)"
Check ($duplicateWarnings[0].category -eq 'adapter' -and $duplicateWarnings[0].code -eq 'duplicate-command-alias') "the warning code is '$($duplicateWarnings[0].category)/$($duplicateWarnings[0].code)'"
Check (($duplicateWarnings[0].message -match 'probe\.exe') -and ($duplicateWarnings[0].message -match 'probe\.py')) 'the warning names both declarations'
$duplicateInfo = CoopJson @('--root',$root,'info','test/duplicate-alias','--json')
$infoWarnings = @(@($duplicateInfo)[0].validation.warnings)
Check ($infoWarnings.Count -eq 1 -and $infoWarnings[0].code -eq 'duplicate-command-alias') 'info does not report the alias overwrite warning'
if ($hasPython) {
    $duplicateInstall = CoopJson @('--root',$root,'install','test/duplicate-alias','--json') $pythonPath
    Check ((Test-Path -LiteralPath "$root/shims/probe.cmd") -and -not (Test-Path -LiteralPath "$root/shims/probe.exe")) 'the last declaration published the python wrapper and no stale .exe shim'
    $duplicateRun = Invoke-Program "$root/shims/probe.cmd" @() $pythonPath
    Check ($duplicateRun.code -eq 0 -and $duplicateRun.text -match 'python-entry') "the surviving entry did not run: code=$($duplicateRun.code) output=$($duplicateRun.text)"
    CoopJson @('--root',$root,'uninstall','duplicate-alias','--json') | Out-Null
    Check (-not (Test-Path -LiteralPath "$root/shims/probe.cmd") -and -not (Test-Path -LiteralPath "$root/shims/probe")) 'uninstall removed the surviving wrapper'
} else {
    Write-Output 'SKIP the duplicate-alias install case: no real Python 3 host was found'
}

# --- 5. Safety boundary: absolute, drive-qualified and escaping write paths stay rejected ------
$safetyZip = Join-Path $session 'safety.zip'
New-ZipPackage $safetyZip ([ordered]@{'probe.exe'=$envFixtureBytes})
$safetyHash = (Get-FileHash -LiteralPath $safetyZip -Algorithm SHA256).Hash.ToLower()
$safetyCases = [ordered]@{
    'absolute-bin' = @{url=(File-Uri $safetyZip);hash=$safetyHash;bin='C:\Windows\notepad.exe'}
    'drive-bin' = @{url=(File-Uri $safetyZip);hash=$safetyHash;bin='C:probe.exe'}
    'parent-bin' = @{url=(File-Uri $safetyZip);hash=$safetyHash;bin='..\probe.exe'}
    'parent-persist' = @{url=(File-Uri $safetyZip);hash=$safetyHash;bin='probe.exe';persist='..\escape'}
    'parent-extract' = @{url=(File-Uri $safetyZip);hash=$safetyHash;extract_dir='..\escape'}
    'absolute-shortcut' = @{url=(File-Uri $safetyZip);hash=$safetyHash;bin='probe.exe';shortcuts=@(,@('C:\Windows\notepad.exe','Probe'))}
    'absolute-icon' = @{url=(File-Uri $safetyZip);hash=$safetyHash;bin='probe.exe';shortcuts=@(,@('probe.exe','Probe','','C:\Windows\notepad.exe'))}
    'parent-env-path' = @{url=(File-Uri $safetyZip);hash=$safetyHash;env_add_path='..\outside'}
}
foreach ($name in $safetyCases.Keys) {
    Write-Manifest $name $safetyCases[$name]
    $preview = Invoke-Coop @('--root',$root,'install',"test/$name",'--dry-run','--json')
    $document = $preview.text | ConvertFrom-Json
    $codes = DiagnosticCodes $document
    Check ($document.execution_available -eq $false) "$name was not rejected"
    Check ($codes -contains 'adapter/manifest-shape') "$name did not report adapter/manifest-shape: $($codes -join ',')"
    $install = Invoke-Coop @('--root',$root,'install',"test/$name",'--json')
    Check ($install.code -ne 0) "$name unexpectedly installed"
    Check (-not (Test-Path -LiteralPath "$root/apps/$name")) "$name wrote a package directory"
    Check (-not (Test-Path -LiteralPath (Join-Path $env:COOP_PROGRAMS_DIR 'Probe.lnk'))) "$name wrote a shortcut"
}
Check (-not (Test-Path -LiteralPath (Join-Path $root '.coop/packages/binargs.json'))) 'uninstall left a management record behind'

[pscustomobject]@{
    root = $root
    checks = $checks.Count
    python_host = if ($hasPython) { $python } else { $null }
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $session 'manifest-shape-evidence.json') -Encoding utf8
Write-Output "PASS manifest shape compatibility: $($checks.Count) checks in $session"

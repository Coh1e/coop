# Red when: `shim add` stops publishing a runnable launcher and the Scoop `.shim` metadata, `shim alter`
# stops changing the arguments the launcher uses, `shim rm` stops removing both files, or `shim list`
# stops reporting the target and arguments.
param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test data must stay within the project test directory'
}
$root = Join-Path $TestRoot 'shim'
if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
New-Item -ItemType Directory -Path "$root/shims" -Force | Out-Null
$target = Join-Path $env:ComSpec ''
$lines = @(& $CoopExe --root $root shim list)
if ($LASTEXITCODE -cne 0 -or ($lines -join 'n') -cnotmatch 'No shim found') { throw "an empty shim list said '$($lines -join ' | ')'" }

$lines = @(& $CoopExe --root $root shim add hello $env:ComSpec '/c' 'echo shim-ok')
if ($LASTEXITCODE -cne 0 -or ($lines -join "`n") -cnotmatch 'Adding local shim hello') { throw "shim add said '$($lines -join ' | ')'" }
if (-not (Test-Path -LiteralPath "$root/shims/hello.exe")) { throw 'shim add did not publish a launcher' }
if (-not (Test-Path -LiteralPath "$root/shims/hello.shim")) { throw 'shim add did not write the Scoop metadata' }

$lines = @(& $CoopExe --root $root shim list)
if ($lines[0] -cnotmatch '^Name\s+Target\s+Arguments\s*$') { throw "shim list header is '$($lines[0])'" }
if ($lines -join "`n" -cnotmatch 'hello\s+.*cmd\.exe\s+/c echo shim-ok') { throw "shim list rows are '$($lines -join ' | ')'" }
$lines = @(& $CoopExe --root $root shim info hello)
if ($lines -join "`n" -cnotmatch 'Target  : .*cmd\.exe') { throw "shim info said '$($lines -join ' | ')'" }

# The published shim really executes its target with the recorded arguments.
$output = & "$root/shims/hello.exe"
if ($LASTEXITCODE -cne 0 -or ($output -join '|') -cnotmatch '^shim-ok$') { throw "running the shim printed '$($output -join ' | ')'" }

$lines = @(& $CoopExe --root $root shim alter hello '/c' 'echo altered-ok')
if ($LASTEXITCODE -cne 0 -or ($lines -join "`n") -cnotmatch "Altering shim 'hello'") { throw "shim alter said '$($lines -join ' | ')'" }
$output = & "$root/shims/hello.exe"
if (($output -join '|') -cnotmatch '^altered-ok$') { throw "after alter the shim printed '$($output -join ' | ')'" }

$lines = @(& $CoopExe --root $root shim rm hello)
if ($LASTEXITCODE -cne 0 -or ($lines -join "`n") -cnotmatch "Removing shim 'hello'") { throw "shim rm said '$($lines -join ' | ')'" }
if ((Test-Path -LiteralPath "$root/shims/hello.exe") -or (Test-Path -LiteralPath "$root/shims/hello.shim")) { throw 'shim rm left a file behind' }

$lines = & $CoopExe --root $root shim add bad 'D:\no\such\tool.exe' 2>&1
if ($LASTEXITCODE -cne 1 -or ($lines -join '|') -cnotmatch 'does not exist') { throw "shim add on a missing target said '$($lines -join ' | ')'" }
Write-Output 'PASS: shim add/list/info/alter/rm with a runnable launcher'

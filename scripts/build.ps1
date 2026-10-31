param([ValidateSet('configure','build','test','test-fast','all')][string]$Action = 'all')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio Build Tools with MSVC is required' }
$vsRoot = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsRoot) { throw 'MSVC x64 build tools not found' }
$vcvars = Join-Path $vsRoot 'VC/Auxiliary/Build/vcvars64.bat'
$cmakeExe = (Get-Command cmake.exe -ErrorAction Stop).Source
$ctestExe = (Get-Command ctest.exe -ErrorAction Stop).Source
$buildRoot = Join-Path $projectRoot '.local/build'
$tempRoot = Join-Path $projectRoot '.local/tmp'
New-Item -ItemType Directory -Path $buildRoot,$tempRoot -Force | Out-Null
$steps = @()
if ($Action -in 'configure','all') { $steps += ('"{0}" -S "{1}" -B "{2}" -G Ninja -DCMAKE_BUILD_TYPE=Release' -f $cmakeExe,$projectRoot,$buildRoot) }
if ($Action -in 'build','all') { $steps += ('"{0}" --build "{1}"' -f $cmakeExe,$buildRoot) }
if ($Action -in 'test','all') { $steps += ('"{0}" --test-dir "{1}" --output-on-failure' -f $ctestExe,$buildRoot) }
# The inner loop: only the tests labelled fast, which finish in a couple of seconds each.
if ($Action -eq 'test-fast') { $steps += ('"{0}" --test-dir "{1}" -L fast --output-on-failure' -f $ctestExe,$buildRoot) }
# The suite runs under the PowerShell CMake found, which is Windows PowerShell 5.1 by default. A pwsh
# parent (CI uses `shell: pwsh`) would otherwise hand its own PSModulePath, whose 7.x module directories
# 5.1 cannot import, down to every test process: Get-FileHash then stops resolving. Rebuild the module
# path from the machine and user values so the child gets what a plain 5.1 shell would see.
$machineModules = [Environment]::GetEnvironmentVariable('PSModulePath','Machine')
$userModules = [Environment]::GetEnvironmentVariable('PSModulePath','User')
$env:PSModulePath = (@($machineModules,$userModules) | Where-Object { $_ }) -join ';'
# vcvars and TEMP/TMP are scoped to this child cmd process, never persisted.
$command = 'call "{0}" >nul && set "TEMP={1}" && set "TMP={1}" && {2}' -f $vcvars,$tempRoot,($steps -join ' && ')
# Merging the child's stderr keeps Windows PowerShell from raising a compiler warning as a
# terminating error; the exit code is the only failure signal.
$previousPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$output = & $env:ComSpec /d /s /c $command 2>&1
$code = $LASTEXITCODE
$ErrorActionPreference = $previousPreference
$output | ForEach-Object { Write-Host $_ }
if ($code -ne 0) { throw "Build action '$Action' failed with exit code $code" }

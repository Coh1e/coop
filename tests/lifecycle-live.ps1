param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/main/bucket","$root/temp" -Force | Out-Null
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$root/buckets/main/bucket/jq.json"
function Run([string]$name,[string]$exe,[string[]]$arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($exe)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $root
    foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
    # Only this test child loses external tools; temporary data stays in the project.
    $start.Environment['PATH'] = "$env:SystemRoot/System32"
    $start.Environment['TEMP'] = "$root/temp"
    $start.Environment['TMP'] = "$root/temp"
    $start.Environment['COOP_PROCESS_GUARD_TIMEOUT_MS'] = '120000'
    $process = [Diagnostics.Process]::Start($start)
    $output = $process.StandardOutput.ReadToEndAsync()
    $errorOutput = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(125000)) { $process.Kill(); throw "$name timed out" }
    $result = @{exit=$process.ExitCode;output=$output.GetAwaiter().GetResult();error=$errorOutput.GetAwaiter().GetResult()}
    $result | ConvertTo-Json -Depth 5 | Set-Content "$root/$name.json" -Encoding utf8
    $process.Dispose()
    return $result
}
$guard = Join-Path (Split-Path $CoopExe) 'process_guard.exe'
$install = Run 'install' $guard @($CoopExe,'--root',$root,'install','main/jq','--json')
if ($install.exit -ne 0) { throw "jq install failed: $($install.error)" }
$version = Run 'version' "$root/shims/jq.exe" @('--version')
if ($version.exit -ne 0 -or $version.output.Trim() -ne 'jq-1.8.2') { throw 'wrong jq version' }
$unicode = Run 'unicode' "$root/shims/jq.exe" @('-n','--arg','value','中文 space "quoted" slash\','$value')
if ($unicode.exit -ne 0 -or ($unicode.output | ConvertFrom-Json) -ne '中文 space "quoted" slash\') { throw 'native shim changed Unicode or arguments' }
$exitCode = Run 'exit-code' "$root/shims/jq.exe" @('-n','halt_error(37)')
if ($exitCode.exit -ne 37) { throw 'native shim lost child exit code' }
$uninstall = Run 'uninstall' $guard @($CoopExe,'--root',$root,'uninstall','jq','--json')
if ($uninstall.exit -ne 0 -or (Test-Path "$root/shims/jq.exe") -or (Test-Path "$root/apps/jq/current")) { throw 'jq uninstall failed' }
@{root=$root;version=$version.output.Trim();unicode=$true;exit_code_forwarded=37;no_tool_children=$true;coop_sha256=(Get-FileHash $CoopExe).Hash;timestamp=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content "$root/evidence.json" -Encoding utf8
Write-Output "PASS actual jq download/install/Unicode/exit/uninstall: $root/evidence.json"

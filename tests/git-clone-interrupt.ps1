param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$accept = $listener.AcceptTcpClientAsync()
$start = [Diagnostics.ProcessStartInfo]::new([IO.Path]::GetFullPath($CoopExe))
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.EnvironmentVariables['PATH'] = Join-Path $env:SystemRoot 'System32'
$start.EnvironmentVariables['HTTPS_PROXY'] = 'http://127.0.0.1:'+$port
$start.EnvironmentVariables['NO_PROXY'] = ''
foreach ($arg in @('--root',$root,'bucket','add','main','https://github.com/ScoopInstaller/Main','--json')) { Add-ProcessArgument $start ($arg) }
$process = [Diagnostics.Process]::Start($start)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
$client = $null
try {
    if (-not $accept.Wait(10000)) { throw 'Clone did not reach controlled proxy' }
    $client = $accept.GetAwaiter().GetResult()
    $cache = @(Get-ChildItem -LiteralPath "$root/.coop/staging" -Directory -ErrorAction SilentlyContinue)
    if (-not $cache.Count -or $process.HasExited) { throw 'Clone initialization was not observed in progress' }
    $process.Kill()
    $process.WaitForExit()
} finally {
    if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
    if ($client) { $client.Dispose() }
    $listener.Stop()
}
$stdout.GetAwaiter().GetResult() | Out-Null
$stderr.GetAwaiter().GetResult() | Set-Content -LiteralPath "$root/interrupted-error.txt" -Encoding utf8
if (Test-Path -LiteralPath "$root/.coop/buckets.json") { throw 'Interrupted first clone published a registry' }
Write-Output ('Interrupted actual clone process at '+$root)
$retryStart = [Diagnostics.ProcessStartInfo]::new([IO.Path]::GetFullPath($CoopExe))
$retryStart.UseShellExecute = $false
$retryStart.CreateNoWindow = $true
$retryStart.RedirectStandardOutput = $true
$retryStart.RedirectStandardError = $true
foreach ($arg in @('--root',$root,'bucket','add','main','https://github.com/ScoopInstaller/Main','--json')) { Add-ProcessArgument $retryStart ($arg) }
$retry = [Diagnostics.Process]::Start($retryStart)
$retryOutput = $retry.StandardOutput.ReadToEndAsync()
$retryError = $retry.StandardError.ReadToEndAsync()
if (-not $retry.WaitForExit(90000)) { $retry.Kill(); throw 'Clone retry timed out' }
$retryOutput.GetAwaiter().GetResult() | Set-Content -LiteralPath "$root/retry-output.json" -Encoding utf8
$retryError.GetAwaiter().GetResult() | Set-Content -LiteralPath "$root/retry-error.txt" -Encoding utf8
if ($retry.ExitCode -ne 0) { throw ('Retry after actual clone interruption failed; evidence: '+$root) }
$record = (Get-Content "$root/.coop/buckets.json" -Raw | ConvertFrom-Json)[0]
if ($record.branch -ne 'master' -or $record.path -ne (Join-Path $root 'buckets/main') -or -not (Test-Path -LiteralPath (Join-Path $record.path '.git')) -or -not (Test-Path -LiteralPath (Join-Path $record.path 'bucket/jq.json'))) { throw 'Retry did not publish a usable shared bucket' }
@{ root=$root; interrupted_exit=$process.ExitCode; retry_exit=$retry.ExitCode; revision=$record.revision; shared_path=$record.path; observed_partial_staging=$cache.Name } |
    ConvertTo-Json | Set-Content -LiteralPath "$root/evidence.json" -Encoding utf8
Write-Output ('PASS clone initialization interruption + retry: '+$root+'/evidence.json')

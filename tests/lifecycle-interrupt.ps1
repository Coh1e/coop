param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$process = $null
$client = $null
try {
    @{version='1';url="http://127.0.0.1:$port/fixture.exe";hash=('0'*64);bin='fixture.exe'} | ConvertTo-Json | Set-Content "$root/buckets/test/bucket/fixture.json" -Encoding utf8
    $connection = $listener.AcceptTcpClientAsync()
    $start = [Diagnostics.ProcessStartInfo]::new($CoopExe)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('--root',$root,'install','test/fixture','--json')) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    if (-not $connection.Wait(15000)) { throw 'native downloader did not connect to local listener' }
    $client = $connection.GetAwaiter().GetResult()
    $journals = @(Get-ChildItem "$root/.coop/transactions" -Recurse -Filter journal.json)
    if ($journals.Count -ne 1 -or (Get-Content $journals[0].FullName -Raw | ConvertFrom-Json).state -ne 'pending') { throw 'network mutation started without prior pending journal' }
    $process.Kill()
    $process.WaitForExit()
    if ((Test-Path "$root/apps/fixture/current") -or (Test-Path "$root/.coop/packages/fixture.json")) { throw 'interrupted install published success' }
    $retry = & $CoopExe --root $root install test/fixture --json 2>&1
    if ($LASTEXITCODE -eq 0 -or ($retry -join "`n") -notlike '*Pending transaction requires recovery*') { throw 'pending transaction was silently ignored' }
    $query = & $CoopExe --root $root list --json
    if ($LASTEXITCODE -ne 0) { throw 'pending writer blocked read-only query' }
    @{root=$root;interrupted_exit=$process.ExitCode;journal=$journals[0].FullName;retry_refused=$true;query_available=$true} | ConvertTo-Json | Set-Content "$root/evidence.json" -Encoding utf8
    Write-Output "PASS actual download interruption/pending/read-only query: $root/evidence.json"
} finally {
    if ($client) { $client.Dispose() }
    $listener.Stop()
    if ($process) { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }; $process.Dispose() }
}

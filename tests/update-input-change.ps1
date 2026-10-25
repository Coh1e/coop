param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$sessionRoot = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
$fixture1 = Join-Path (Split-Path $CoopExe) 'fixture-1.exe'
$fixture2 = Join-Path (Split-Path $CoopExe) 'fixture-2.exe'
foreach ($case in @('manifest','entry')) {
    $root = "$sessionRoot/$case"
    New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null
    @{version='1';url=([Uri][IO.Path]::GetFullPath($fixture1)).AbsoluteUri+'#/fixture.exe';hash=(Get-FileHash $fixture1).Hash.ToLower();bin='fixture.exe'} | ConvertTo-Json | Set-Content "$root/buckets/test/bucket/fixture.json" -Encoding utf8
    $installed = & $CoopExe --root $root install test/fixture --json
    if ($LASTEXITCODE -ne 0) { throw 'fixture installation failed' }
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $process = $null
    $client = $null
    try {
        @{version='2';url="http://127.0.0.1:$port/fixture.exe";hash=(Get-FileHash $fixture2).Hash.ToLower();bin='fixture.exe'} | ConvertTo-Json | Set-Content "$root/buckets/test/bucket/fixture.json" -Encoding utf8
        $connection = $listener.AcceptTcpClientAsync()
        $start = [Diagnostics.ProcessStartInfo]::new($CoopExe)
        $start.UseShellExecute = $false; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        foreach ($argument in @('--root',$root,'update','fixture','--json')) { $start.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($start)
        $output = $process.StandardOutput.ReadToEndAsync(); $errorOutput = $process.StandardError.ReadToEndAsync()
        if (-not $connection.Wait(15000)) { throw 'update did not reach controlled download' }
        $client = $connection.GetAwaiter().GetResult()
        $stream = $client.GetStream()
        $stream.ReadTimeout = 10000
        $request = ''
        while (-not $request.EndsWith("`r`n`r`n")) {
            $value = $stream.ReadByte()
            if ($value -lt 0 -or $request.Length -gt 16384) { throw 'incomplete local HTTP request' }
            $request += [char]$value
        }
        if ($case -eq 'manifest') {
            $changedPath = "$root/buckets/test/bucket/fixture.json"
            $changed = Get-Content $changedPath -Raw | ConvertFrom-Json
            $changed.version = '3'
        } else {
            $changedPath = "$root/shims/fixture.coop-shim.json"
            $changed = Get-Content $changedPath -Raw | ConvertFrom-Json
            $changed | Add-Member -NotePropertyName external_note -NotePropertyValue 'preserve this change'
        }
        $changed | ConvertTo-Json | Set-Content $changedPath -Encoding utf8
        $changedHash = (Get-FileHash $changedPath).Hash
        $bytes = [IO.File]::ReadAllBytes($fixture2)
        $stream.Write([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"))
        $stream.Write($bytes); $stream.Flush()
        $client.Client.Shutdown([Net.Sockets.SocketShutdown]::Send)
        if (-not $process.WaitForExit(15000)) { throw 'update did not finish' }
        $result = @{exit=$process.ExitCode;output=$output.GetAwaiter().GetResult();error=$errorOutput.GetAwaiter().GetResult()}
        $result | ConvertTo-Json | Set-Content "$root/result.json" -Encoding utf8
        if ($result.error -notmatch '(Plan input changed|Managed input changed during preparation)') { throw "Input test did not reach precondition check: $($result.error)" }
        if ($process.ExitCode -eq 0 -or (Get-FileHash $changedPath).Hash -ne $changedHash -or (& "$root/shims/fixture.exe") -ne 'fixture 1' -or (Test-Path "$root/apps/fixture/2")) { throw "Changed $case input did not stop update safely" }
    } finally {
        if ($client) { $client.Dispose() }; $listener.Stop()
        if ($process) { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }; $process.Dispose() }
    }
}
Write-Output "PASS update refuses changed Manifest and command metadata: $sessionRoot"

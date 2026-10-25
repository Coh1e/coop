param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$sessionRoot = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sessionRoot -Force | Out-Null
Copy-Item $CoopExe "$sessionRoot/artifact.exe"
$bytes = [IO.File]::ReadAllBytes("$sessionRoot/artifact.exe")
$hash = (Get-FileHash "$sessionRoot/artifact.exe" -Algorithm SHA256).Hash.ToLower()
foreach ($case in @('version','exe','metadata','record')) {
    $root = "$sessionRoot/$case"
    New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $process = $null
    $client = $null
    try {
        @{version='1';url="http://127.0.0.1:$port/fixture.exe";hash=$hash;bin='fixture.exe'} | ConvertTo-Json | Set-Content "$root/buckets/test/bucket/fixture.json" -Encoding utf8
        $connection = $listener.AcceptTcpClientAsync()
        $start = [Diagnostics.ProcessStartInfo]::new($CoopExe)
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('--root',$root,'install','test/fixture','--json')) { $start.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($start)
        $output = $process.StandardOutput.ReadToEndAsync()
        $errorOutput = $process.StandardError.ReadToEndAsync()
        if (-not $connection.Wait(15000)) { throw 'downloader did not reach controlled server' }
        $client = $connection.GetAwaiter().GetResult()
        $foreign = switch ($case) {
            'version' { "$root/apps/fixture/1/foreign.txt" }
            'exe' { "$root/shims/fixture.exe" }
            'metadata' { "$root/shims/fixture.coop-shim.json" }
            'record' { "$root/.coop/packages/fixture.json" }
        }
        New-Item -ItemType Directory -Path (Split-Path $foreign) -Force | Out-Null
        [IO.File]::WriteAllText($foreign,'foreign data must survive')
        $stream = $client.GetStream()
        $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
        $stream.Write($header)
        $stream.Write($bytes)
        $client.Dispose(); $client = $null
        if (-not $process.WaitForExit(15000)) { throw 'conflict install did not finish' }
        @{exit=$process.ExitCode;output=$output.GetAwaiter().GetResult();error=$errorOutput.GetAwaiter().GetResult()} | ConvertTo-Json | Set-Content "$root/result.json" -Encoding utf8
        if ($process.ExitCode -eq 0 -or -not (Test-Path $foreign) -or [IO.File]::ReadAllText($foreign) -ne 'foreign data must survive') { throw "Concurrent $case conflict was overwritten or removed" }
        if (Test-Path "$root/apps/fixture/current") { throw 'failed install left current published' }
    } finally {
        if ($client) { $client.Dispose() }
        $listener.Stop()
        if ($process) { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }; $process.Dispose() }
    }
}
Write-Output "PASS concurrent version/EXE/metadata/record conflicts preserved: $sessionRoot"

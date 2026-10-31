param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$sessionRoot = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sessionRoot -Force | Out-Null
Copy-Item $CoopExe "$sessionRoot/artifact.exe"
$bytes = [IO.File]::ReadAllBytes("$sessionRoot/artifact.exe")
$hash = (Get-FileHash "$sessionRoot/artifact.exe" -Algorithm SHA256).Hash.ToLower()
foreach ($case in @('version','exe','metadata','record','manifest')) {
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
        foreach ($argument in @('--root',$root,'install','test/fixture','--json')) { Add-ProcessArgument $start ($argument) }
        $process = [Diagnostics.Process]::Start($start)
        $output = $process.StandardOutput.ReadToEndAsync()
        $errorOutput = $process.StandardError.ReadToEndAsync()
        if (-not $connection.Wait(15000)) { throw 'downloader did not reach controlled server' }
        $client = $connection.GetAwaiter().GetResult()
        $stream = $client.GetStream()
        $stream.ReadTimeout = 10000
        $request = ''
        while (-not $request.EndsWith("`r`n`r`n")) {
            $value = $stream.ReadByte()
            if ($value -lt 0 -or $request.Length -gt 16384) { throw 'incomplete local HTTP request' }
            $request += [char]$value
        }
        $foreign = switch ($case) {
            'version' { "$root/apps/fixture/1/foreign.txt" }
            'exe' { "$root/shims/fixture.exe" }
            'metadata' { "$root/shims/fixture.shim" }
            'record' { "$root/.coop/packages/fixture.json" }
            'manifest' { "$root/buckets/test/bucket/fixture.json" }
        }
        New-Item -ItemType Directory -Path (Split-Path $foreign) -Force | Out-Null
        [IO.File]::WriteAllText($foreign,'foreign data must survive')
        $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
        $stream.Write($header, 0, $header.Length)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $client.Client.Shutdown([Net.Sockets.SocketShutdown]::Send)
        if (-not $process.WaitForExit(15000)) { throw 'conflict install did not finish' }
        $result = @{exit=$process.ExitCode;output=$output.GetAwaiter().GetResult();error=$errorOutput.GetAwaiter().GetResult()}
        $result | ConvertTo-Json | Set-Content "$root/result.json" -Encoding utf8
        if ($case -eq 'manifest') {
            if ($result.error -notlike '*Plan input changed*') { throw 'Manifest test did not reach input recheck' }
        } elseif ($result.error -notlike '*Destination cannot be published*') { throw "Conflict $case did not reach atomic publication: $($result.error)" }
        if ($process.ExitCode -eq 0 -or -not (Test-Path $foreign) -or [IO.File]::ReadAllText($foreign) -ne 'foreign data must survive') { throw "Concurrent $case conflict was overwritten or removed" }
        if (Test-Path "$root/apps/fixture/current") { throw 'failed install left current published' }
    } finally {
        if ($client) { $client.Dispose() }
        $listener.Stop()
        if ($process) { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }; $process.Dispose() }
    }
}
Write-Output "PASS concurrent version/EXE/metadata/record conflicts and changed Manifest: $sessionRoot"

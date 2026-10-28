param(
    [Parameter(Mandatory)][string]$CoopExe,
    [string]$ScoopShim = "$env:USERPROFILE\scoop\shims\scoop.ps1",
    [int]$Runs = 5,
    [string]$Output = (Join-Path $PSScriptRoot '../.local/perf-compare')
)
# #71: compare the two clients on the same byte stream. A loopback server paces the transfer, so the
# download share is known for both and what is left is each client's own work. The assertion is a
# ratio, never an absolute number: machine speed must not turn this red.
$ErrorActionPreference = 'Stop'
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$Output = [IO.Path]::GetFullPath($Output)
if (-not (Test-Path -LiteralPath $ScoopShim)) { throw "No Scoop installation at $ScoopShim; this comparison needs a real one." }
Remove-Item $Output -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $Output -Force | Out-Null
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$tidy = Join-Path $archives 'tidy-5.8.0-win64.zip'
if (-not (Test-Path -LiteralPath $tidy)) { throw "Missing fixed test input: $tidy; run scripts/fetch-deps.ps1" }
$bytes = [IO.File]::ReadAllBytes($tidy)
$hash = (Get-FileHash -LiteralPath $tidy -Algorithm SHA256).Hash.ToLower()

# One server for both clients: 8 paced pieces of 40 ms each, so a transfer costs about 0.32 s.
$port = Get-Random -Minimum 20000 -Maximum 40000
$serverScript = Join-Path $Output 'server.ps1'
$serverBody = @"
`$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port)
`$listener.Start()
try {
    while (`$true) {
        `$client = `$listener.AcceptTcpClient()
        try {
            `$stream = `$client.GetStream()
            `$reader = [IO.StreamReader]::new(`$stream,[Text.Encoding]::ASCII,`$false,1024,`$true)
            while (`$true) { `$line = `$reader.ReadLine(); if (-not `$line) { break } }
            `$data = [IO.File]::ReadAllBytes('$tidy')
            `$header = "HTTP/1.1 200 OK`r`nContent-Type: application/zip`r`nContent-Length: `$(`$data.Length)`r`nConnection: close`r`n`r`n"
            `$stream.Write([Text.Encoding]::ASCII.GetBytes(`$header),0,`$header.Length)
            `$chunk = [int][Math]::Ceiling(`$data.Length / 8.0)
            for (`$offset = 0; `$offset -lt `$data.Length; `$offset += `$chunk) {
                `$count = [Math]::Min(`$chunk,`$data.Length - `$offset)
                `$stream.Write(`$data,`$offset,`$count)
                `$stream.Flush()
                Start-Sleep -Milliseconds 40
            }
            `$stream.Flush()
        } catch { } finally { `$client.Close() }
    }
} finally { `$listener.Stop() }
"@
[IO.File]::WriteAllText($serverScript,$serverBody,[Text.UTF8Encoding]::new($false))
$server = Start-Process -FilePath ([Environment]::ProcessPath) -ArgumentList @('-NoProfile','-NonInteractive','-File',('"'+$serverScript+'"')) -PassThru -WindowStyle Hidden
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    try { $probe = [Net.Sockets.TcpClient]::new('127.0.0.1',$port); $probe.Close(); break } catch { Start-Sleep -Milliseconds 100 }
}
$url = "http://127.0.0.1:$port/tidy-5.8.0-win64.zip"

try {
    # --- Coop root -------------------------------------------------------------------------------
    $coopRoot = Join-Path $Output 'coop-root'
    New-Item -ItemType Directory -Path "$coopRoot/buckets/test/bucket" -Force | Out-Null
    $manifest = [ordered]@{ version='1.0.0'; url=$url; hash=$hash
        extract_dir='tidy-5.8.0-win64\bin'; bin='tidy.exe' }
    [IO.File]::WriteAllText("$coopRoot/buckets/test/bucket/tidy.json",
        ($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))

    # --- Scoop root ------------------------------------------------------------------------------
    $scoopRoot = Join-Path $Output 'scoop-root'
    New-Item -ItemType Directory -Path "$scoopRoot/buckets/test/bucket","$scoopRoot/shims","$scoopRoot/apps","$scoopRoot/cache" -Force | Out-Null
    [IO.File]::WriteAllText("$scoopRoot/buckets/test/bucket/tidy.json",
        ($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))

    function Measure-Run([string]$client) {
        # Every run has to transfer, so both clients pay the same paced download each time.
        Remove-Item (Join-Path $coopRoot 'cache/*') -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $scoopRoot 'cache/*') -Force -ErrorAction SilentlyContinue
        $start = [Diagnostics.Stopwatch]::StartNew()
        if ($client -eq 'coop') {
            & $CoopExe --root $coopRoot install test/tidy --json | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'coop install failed' }
        } else {
            $env:SCOOP = $scoopRoot
            $env:SCOOP_GLOBAL = Join-Path $Output 'scoop-global'
            $env:XDG_CONFIG_HOME = Join-Path $Output 'xdg'
            & $ScoopShim install tidy *>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'scoop install failed' }
        }
        $start.Stop()
        $total = $start.Elapsed.TotalSeconds
        if ($client -eq 'coop') {
            & $CoopExe --root $coopRoot uninstall tidy --json | Out-Null
        } else {
            $env:SCOOP = $scoopRoot
            & $ScoopShim uninstall tidy *>&1 | Out-Null
        }
        return $total
    }

    # The download share is the same for both clients: the server paces the same bytes the same way.
    $download = 0.32
    $results = [ordered]@{ coop = @(); scoop = @() }
    for ($run = 1; $run -le $Runs; $run++) {
        foreach ($client in 'coop','scoop') {
            $total = Measure-Run $client
            $results[$client] += [pscustomobject]@{ run=$run; total=$total; local=($total-$download) }
            Write-Output ("{0} run {1}: total {2:N3} s, local {3:N3} s" -f $client,$run,$total,($total-$download))
        }
    }
    function Median($values) {
        $sorted = @($values | Sort-Object)
        if ($sorted.Count -eq 0) { return 0 }
        $middle = [int]($sorted.Count/2)
        if ($sorted.Count % 2) { return $sorted[$middle] }
        return ($sorted[$middle-1]+$sorted[$middle])/2
    }
    $coopMedian = Median ($results.coop | ForEach-Object { $_.local })
    $scoopMedian = Median ($results.scoop | ForEach-Object { $_.local })
    $ratio = if ($scoopMedian -gt 0) { $coopMedian/$scoopMedian } else { 0 }
    $summary = [ordered]@{
        runs = $Runs
        download_seconds_assumed = $download
        coop_local_median = $coopMedian
        scoop_local_median = $scoopMedian
        ratio = $ratio
        machine = "$env:COMPUTERNAME / $([Environment]::OSVersion.VersionString)"
        coop = (& $CoopExe --version)
        threshold = 1.2
        verdict = if ($ratio -le 1.2) { 'within 1.2x' } else { 'slower than 1.2x' }
    }
    $summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Output 'summary.json') -Encoding utf8
    $summary | ConvertTo-Json
} finally {
    if ($server -and -not $server.HasExited) { $server.Kill($true) }
}

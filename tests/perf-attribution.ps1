param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# #61: the point of the record is attribution. A loopback server hands the same archive over at a
# known pace, so the download share is measurable and the local share is what is left. The identity
# total = download + local is what makes the two numbers comparable with another client later.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not (($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase))) { throw 'Test root outside project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$tidy = Join-Path $archives 'tidy-5.8.0-win64.zip'
if (-not (Test-Path -LiteralPath $tidy)) { throw "Missing fixed test input: $tidy; run scripts/fetch-deps.ps1" }

$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
$port = Get-Random -Minimum 20000 -Maximum 40000
New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null

# A loopback server that sends the archive in eight pieces with a pause between them.
# The server lives in its own process: an HttpListener created here cannot be handed to a job.
$serverScript = Join-Path $root 'server.ps1'
$serverBody = @"
# A bare TCP listener speaking HTTP/1.1: HttpListener needs a URL ACL, a socket does not.
`$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port)
`$listener.Start()
try {
    while (`$true) {
        `$client = `$listener.AcceptTcpClient()
        try {
            `$stream = `$client.GetStream()
            `$reader = [IO.StreamReader]::new(`$stream,[Text.Encoding]::ASCII,`$false,1024,`$true)
            while (`$true) { `$line = `$reader.ReadLine(); if (-not `$line) { break } }
            `$bytes = [IO.File]::ReadAllBytes('$tidy')
            `$header = "HTTP/1.1 200 OK`r`nContent-Type: application/zip`r`nContent-Length: `$(`$bytes.Length)`r`nConnection: close`r`n`r`n"
            `$stream.Write([Text.Encoding]::ASCII.GetBytes(`$header),0,`$header.Length)
            `$chunk = [int][Math]::Ceiling(`$bytes.Length / 8.0)
            for (`$offset = 0; `$offset -lt `$bytes.Length; `$offset += `$chunk) {
                `$count = [Math]::Min(`$chunk,`$bytes.Length - `$offset)
                `$stream.Write(`$bytes,`$offset,`$count)
                `$stream.Flush()
                Start-Sleep -Milliseconds 40
            }
            `$stream.Flush()
        } catch { } finally { `$client.Close() }
    }
} finally { `$listener.Stop() }
"@
[IO.File]::WriteAllText($serverScript,$serverBody,[Text.UTF8Encoding]::new($false))
$pwshPath = (Get-Process -Id $PID).Path
# ExecutionPolicy is passed explicitly: the helper script lives under .local, and Windows PowerShell
# 5.1 refuses to run an unsigned script from that path under RemoteSigned.
$serverProcess = Start-Process -FilePath $pwshPath -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$serverScript+'"')) -PassThru -WindowStyle Hidden
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    try { $probe = [Net.Sockets.TcpClient]::new('127.0.0.1',$port); $probe.Close(); break } catch { Start-Sleep -Milliseconds 100 }
}
function Invoke-Coop([string[]]$arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($CoopExe)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $start.WorkingDirectory = $root
    foreach ($argument in $arguments) { Add-ProcessArgument $start ($argument) }
    $start.EnvironmentVariables['TEMP'] = "$root/temp"
    $start.EnvironmentVariables['TMP'] = "$root/temp"
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(300000)) { $process.Kill(); throw 'coop timed out' }
    $result = [pscustomobject]@{ exit = $process.ExitCode
        output = $stdout.GetAwaiter().GetResult(); error = $stderr.GetAwaiter().GetResult() }
    $process.Dispose()
    return $result
}

try {
    $manifest = [ordered]@{
        version='1.0.0'; url="http://127.0.0.1:$port/tidy.zip"
        hash=(Get-FileHash -LiteralPath $tidy -Algorithm SHA256).Hash.ToLower()
        extract_dir='tidy-5.8.0-win64\bin'; bin='tidy.exe'
    }
    [IO.File]::WriteAllText("$root/buckets/test/bucket/slow.json",
        ($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $install = Invoke-Coop @('--root',$root,'install','test/slow','--json','--timings')
    $clock.Stop()
    if ($install.exit -ne 0) { throw "the install failed: $($install.error)$($install.output)" }
} finally {
    if ($serverProcess -and -not $serverProcess.HasExited) { $serverProcess.Kill() }
}

# A --json run must stay parseable with --timings: the summary is human output only.
$parsed = $install.output | ConvertFrom-Json
if (-not $parsed.timings) { throw "the --json result did not carry the timing fields: $($install.output)" }

$records = @(Get-ChildItem -LiteralPath "$root/.coop/timings" -Filter '*.json' -File)
if ($records.Count -eq 0) { throw 'no timing record was written' }
$record = Get-Content -LiteralPath $records[0].FullName -Raw | ConvertFrom-Json

# The record's total has to match the wall clock measured around the run; the two shares adding
# The paced transfer has to show up as download time.
if ([double]$record.download_seconds -lt 0.15) {
    throw "the paced download was not attributed to the download step: $($record.download_seconds) s"
}
$downloadStep = @($record.steps | Where-Object { $_.operation -eq 'download' })[0]
if ([uint64]$downloadStep.bytes -ne [uint64](Get-Item -LiteralPath $tidy).Length) { throw "the download step did not record the transferred bytes: $($downloadStep.bytes)" }
if ([double]$record.download_seconds -gt 2.0) { throw "the paced download took far longer than the server paces it: $($record.download_seconds) s" }
if ([Math]::Abs([double]$record.total_seconds - $clock.Elapsed.TotalSeconds) -gt 0.5) {
    throw "the recorded total does not match the measured wall clock: $($record.total_seconds) vs $($clock.Elapsed.TotalSeconds)"
}
if ([double]$record.local_seconds -le 0) { throw 'no local time was recorded' }
foreach ($operation in 'download','verify','extract','entries') {
    if (-not (@($record.steps | ForEach-Object { $_.operation }) -contains $operation)) {
        throw "the record is missing the '$operation' step: $($record.steps | ConvertTo-Json -Compress)"
    }
}

# The human summary prints the same split.
$second = Invoke-Coop @('--root',$root,'uninstall','slow','--json')
if ($second.exit -ne 0) { throw "the uninstall failed: $($second.error)" }
$text = Invoke-Coop @('--root',$root,'install','test/slow','--timings')
if ($text.exit -ne 0) { throw "the second install failed: $($text.error)" }
foreach ($line in 'Timings','-------') {
    if (($text.output -split "`r?`n") -notcontains $line) { throw "the timings summary is incomplete: $($text.output)" }
}
if ($text.output -notmatch 'download [0-9.]+ s' -or $text.output -notmatch 'local\s+[0-9.]+ s') {
    throw "the timings summary does not show both shares: $($text.output)"
}

Write-Output 'timings: attribution and record verified'

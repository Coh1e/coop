param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# #72: two gaps the acceptance matrix recorded were still open. The download line now names the size,
# as Scoop does, and a batch update prints the same per-package block a single update prints.
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not (($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase))) { throw 'Test root outside project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$tidy = Join-Path $archives 'tidy-5.8.0-win64.zip'
if (-not (Test-Path -LiteralPath $tidy)) { throw "Missing fixed test input: $tidy; run scripts/fetch-deps.ps1" }

$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null

function File-Hash([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
function Write-Manifest([string]$name,[string]$version) {
    $ordered = [ordered]@{ version=$version; url=(File-Uri $tidy); hash=(File-Hash $tidy)
        extract_dir='tidy-5.8.0-win64\bin'; bin=@(,@('tidy.exe',"bin$name")) }
    [IO.File]::WriteAllText("$root/buckets/test/bucket/$name.json",
        ($ordered | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
function Invoke-Coop([string[]]$arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($CoopExe)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $start.WorkingDirectory = $root
    foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
    $start.Environment['TEMP'] = "$root/temp"
    $start.Environment['TMP'] = "$root/temp"
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(300000)) { $process.Kill($true); throw 'coop timed out' }
    $result = [pscustomobject]@{ exit = $process.ExitCode
        output = $stdout.GetAwaiter().GetResult(); error = $stderr.GetAwaiter().GetResult() }
    $process.Dispose()
    return $result
}

# 1. The transfer line names the size, in Scoop's own format.
Write-Manifest 'sized' '1.0.0'
$install = Invoke-Coop @('--root',$root,'install','test/sized')
if ($install.exit -ne 0) { throw "the install failed: $($install.error)$($install.output)" }
$downloadLine = @($install.output -split "`r?`n" | Where-Object { $_ -like 'Downloading *' })
if ($downloadLine.Count -ne 1) { throw "expected one download line: $($install.output)" }
if ($downloadLine[0] -notmatch '\(1\.3 MB\)\.\.\.$') {
    throw "the download line does not name the size in Scoop's format: $($downloadLine[0])"
}
# A cached run has no transfer line at all, so nothing is claimed twice.
$again = Invoke-Coop @('--root',$root,'uninstall','sized','--json')
Write-Manifest 'sized' '1.0.0'
$cached = Invoke-Coop @('--root',$root,'install','test/sized')
if (@($cached.output -split "`r?`n" | Where-Object { $_ -like 'Downloading *' }).Count -ne 0) {
    throw "a cache hit printed a transfer line: $($cached.output)"
}

# 2. A batch update prints each package's block, with the same announcements a single update prints.
foreach ($name in 'alpha','beta') {
    Write-Manifest $name '1.0.0'
    $first = Invoke-Coop @('--root',$root,'install',"test/$name",'--json')
    if ($first.exit -ne 0) { throw "the install of $name failed: $($first.error)" }
    Write-Manifest $name '1.1.0'
}
$batch = Invoke-Coop @('--root',$root,'update','alpha','beta')
if ($batch.exit -ne 0) { throw "the batch update failed: $($batch.error)$($batch.output)" }
$lines = @($batch.output -split "`r?`n")
foreach ($name in 'alpha','beta') {
    if (-not ($lines -contains "${name}: 1.0.0 -> 1.1.0")) { throw "the version move for $name is missing:`n$($batch.output)" }
    if (-not ($lines -contains "'$name' (1.1.0) was installed successfully!")) { throw "the closing line for $name is missing:`n$($batch.output)" }
    if ($lines -contains "${name}: success") { throw "the batch printed an extra status line for $name" }
}
if (@($lines | Where-Object { $_ -eq 'Updating 2 outdated apps:' }).Count -ne 1) {
    throw "expected one heading for the whole batch:`n$($batch.output)"
}
if (@($lines | Where-Object { $_ -eq 'Updating one outdated app:' }).Count -ne 0) {
    throw "a batch repeated the per-package heading:`n$($batch.output)"
}
# 3. A batch whose packages are not all outdated announces only the ones that are, and a current
#    package reports up-to-date without a block of its own.
Write-Manifest 'alpha' '1.2.0'
$mixed = Invoke-Coop @('--root',$root,'update','alpha','beta')
if ($mixed.exit -ne 0) { throw "the mixed batch failed: $($mixed.error)$($mixed.output)" }
$mixedLines = @($mixed.output -split "`r?`n")
if (-not ($mixedLines -contains 'Updating one outdated app:')) {
    throw "the heading counted packages that were already current:`n$($mixed.output)"
}
if ($mixedLines -contains 'Updating 2 outdated apps:') { throw "the heading overcounted:`n$($mixed.output)" }
if (-not ($mixedLines -contains 'beta: up-to-date')) { throw "the current package did not report up-to-date:`n$($mixed.output)" }
if (@($mixedLines | Where-Object { $_ -like "Updating 'beta'*" }).Count -ne 0) {
    throw "the current package printed a block of its own:`n$($mixed.output)"
}

# 4. A batch that meets an installed package repeats Scoop's warning instead of claiming success.
$installed = Invoke-Coop @('--root',$root,'install','alpha','beta')
if ($installed.exit -ne 0) { throw "the reinstall batch failed: $($installed.error)$($installed.output)" }
$installedLines = @($installed.output -split "`r?`n" | Where-Object { $_ -ne '' })
$warnLines = @($installedLines | Where-Object { $_ -like 'WARN  *already installed.*' -or $_ -like "Use 'coop update*" })
if ($warnLines.Count -lt 2) { throw "the batch did not warn about the installed packages:`n$($installed.output)" }
if (@($installedLines | Where-Object { $_ -like "Installing 'alpha'*" }).Count -ne 0) {
    throw "an installed package still printed an install block:`n$($installed.output)"
}
if (@($installedLines | Where-Object { $_ -like "*'alpha' (1.2.0) was installed successfully!*" }).Count -ne 0) {
    throw "an installed package claimed success:`n$($installed.output)"
}

# 3. A network artifact names its size from the response headers of the transfer itself. A second
#    request would break servers that answer one connection, so the line is printed at transfer start.
$port = Get-Random -Minimum 20000 -Maximum 40000
$serverScript = Join-Path $root 'server.ps1'
$requestLog = Join-Path $root 'requests.log'
Remove-Item -LiteralPath $requestLog -Force -ErrorAction SilentlyContinue
$serverBody = @"
`$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port)
`$listener.Start()
try {
    while (`$true) {
        `$client = `$listener.AcceptTcpClient()
        try {
            `$stream = `$client.GetStream()
            `$reader = [IO.StreamReader]::new(`$stream,[Text.Encoding]::ASCII,`$false,1024,`$true)
            # Only a real request counts: the readiness probe connects and sends nothing.
            `$first = `$reader.ReadLine()
            if (`$first) { Add-Content -LiteralPath '$requestLog' -Value `$first }
            while (`$true) { `$line = `$reader.ReadLine(); if (-not `$line) { break } }
            `$bytes = [IO.File]::ReadAllBytes('$tidy')
            `$header = "HTTP/1.1 200 OK`r`nContent-Type: application/zip`r`nContent-Length: `$(`$bytes.Length)`r`nConnection: close`r`n`r`n"
            `$stream.Write([Text.Encoding]::ASCII.GetBytes(`$header),0,`$header.Length)
            `$stream.Write(`$bytes,0,`$bytes.Length)
            `$stream.Flush()
        } catch { } finally { `$client.Close() }
    }
} finally { `$listener.Stop() }
"@
[IO.File]::WriteAllText($serverScript,$serverBody,[Text.UTF8Encoding]::new($false))
$serverProcess = Start-Process -FilePath ([Environment]::ProcessPath) -ArgumentList @('-NoProfile','-NonInteractive','-File',('"'+$serverScript+'"')) -PassThru -WindowStyle Hidden
try {
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        try { $probe = [Net.Sockets.TcpClient]::new('127.0.0.1',$port); $probe.Close(); break } catch { Start-Sleep -Milliseconds 100 }
    }
    $network = [ordered]@{ version='1.0.0'; url="http://127.0.0.1:$port/tidy-5.8.0-win64.zip"
        hash=(File-Hash $tidy); extract_dir='tidy-5.8.0-win64\bin'; bin=@(,@('tidy.exe','netbin')) }
    [IO.File]::WriteAllText("$root/buckets/test/bucket/network.json",
        ($network | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    # The earlier cases filled the cache with the same filename, so it has to be empty here.
    Remove-Item -Path "$root/cache/*" -Force -ErrorAction SilentlyContinue
    $overHttp = Invoke-Coop @('--root',$root,'install','test/network')
    if ($overHttp.exit -ne 0) { throw "the network install failed: $($overHttp.error)$($overHttp.output)" }
    $line = @($overHttp.output -split "`r?`n" | Where-Object { $_ -like 'Downloading http*' })
    if ($line.Count -ne 1 -or $line[0] -notmatch '\(1\.3 MB\)\.\.\.$') {
        throw "a network transfer did not name its size: $($overHttp.output)"
    }
    # The size has to come from this transfer, not from a probe: one connection, not two.
    $requests = @(Get-Content -LiteralPath $requestLog -ErrorAction SilentlyContinue | Where-Object { $_ -match '^GET ' })
    if ($requests.Count -ne 1) {
        throw "the install opened $($requests.Count) connections; the size must come from the transfer itself"
    }
} finally {
    if ($serverProcess -and -not $serverProcess.HasExited) { Stop-Process -Id $serverProcess.Id -Force }
}

Write-Output 'output gaps: download size and batch update blocks verified'

param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
# System.Formats.Tar (used below to build symlink/hardlink fixtures) ships with .NET 7+; Windows
# PowerShell 5.1 runs on .NET Framework 4.8 and does not have it. Hand-building the tar would test our
# tar writer rather than coop, so the suite is skipped there and says so.
if ($null -eq ('System.Formats.Tar.TarWriter' -as [type])) {
    Write-Output 'archive safety: SKIPPED (System.Formats.Tar needs .NET 7+, absent in Windows PowerShell 5.1)'
    exit 0
}
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$fixture1 = Join-Path (Split-Path $CoopExe) 'fixture-1.exe'
$rg14 = Join-Path $archives 'ripgrep-14.1.1-x86_64-pc-windows-msvc.zip'
foreach ($path in @($rg14,$fixture1)) { if (-not (Test-Path -LiteralPath $path)) { throw "Missing fixed test input: $path; run scripts/fetch-deps.ps1" } }

function New-TestRoot {
    $root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null
    return $root
}
function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
function Write-Manifest([string]$root,[string]$name,[object]$manifest) {
    [IO.File]::WriteAllText("$root/buckets/test/bucket/$name.json",($manifest | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
}
function Assert-Failed([string]$message,[string]$output) {
    if ($LASTEXITCODE -eq 0) { throw $message }
    if ($output -notmatch 'coop:') { throw "$message (missing diagnostic output)" }
}
function First-Version([string]$output) { return ($output | Where-Object { $_ -match '\S' } | Select-Object -First 1) }
function New-Zip([string]$path,[hashtable]$entries) {
    $stream = [IO.File]::Create($path)
    $zip = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
    foreach ($name in $entries.Keys) {
        $entry = $zip.CreateEntry($name)
        $output = $entry.Open()
        $bytes = $entries[$name]
        $output.Write($bytes,0,$bytes.Length)
        $output.Dispose()
    }
    $zip.Dispose(); $stream.Dispose()
}
function New-LinkTar([string]$path) {
    $stream = [IO.File]::Create($path)
    $writer = [System.Formats.Tar.TarWriter]::new($stream,[System.Formats.Tar.TarEntryFormat]::Pax)
    $link = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::SymbolicLink,'link')
    $link.LinkName = '../../escape'
    $writer.WriteEntry($link)
    $writer.Dispose(); $stream.Dispose()
}
function New-HardLinkTar([string]$path) {
    $stream = [IO.File]::Create($path)
    $writer = [System.Formats.Tar.TarWriter]::new($stream,[System.Formats.Tar.TarEntryFormat]::Pax)
    $link = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::HardLink,'hard')
    $link.LinkName = 'target.exe'
    $writer.WriteEntry($link)
    $writer.Dispose(); $stream.Dispose()
}

# Bad archive and missing command target must fail without publishing state.
$root = New-TestRoot
$fixtures = Join-Path $root 'fixtures'; New-Item -ItemType Directory -Path $fixtures -Force | Out-Null
$bad = Join-Path $fixtures 'bad.zip'
[IO.File]::WriteAllBytes($bad,[byte[]](1..256 | ForEach-Object { $_ % 251 }))
Write-Manifest $root 'bad' @{version='1';url=(File-Uri $bad);hash=(Get-FileHash $bad -Algorithm SHA256).Hash.ToLower();bin='bad.exe'}
$output = Invoke-CoopNative $CoopExe  --root $root install test/bad --json
Assert-Failed 'bad archive install unexpectedly succeeded' ($output -join "`n")
if ((Test-Path "$root/apps/bad/current") -or (Test-Path "$root/.coop/packages/bad.json") -or (Test-Path "$root/shims/bad.exe")) { throw 'bad archive published state' }

$root = New-TestRoot
$fixtures = Join-Path $root 'fixtures'; New-Item -ItemType Directory -Path $fixtures -Force | Out-Null
$missing = Join-Path $fixtures 'missing.zip'
New-Zip $missing @{'other.txt'=[Text.Encoding]::UTF8.GetBytes('not the command')}
Write-Manifest $root 'missing' @{version='1';url=(File-Uri $missing);hash=(Get-FileHash $missing -Algorithm SHA256).Hash.ToLower();bin='missing.exe'}
$output = Invoke-CoopNative $CoopExe  --root $root install test/missing --json
Assert-Failed 'archive without command target unexpectedly succeeded' ($output -join "`n")
if (($output -join "`n") -notmatch 'Command entry target is missing') { throw 'missing command target was not reported clearly' }
if ((Test-Path "$root/apps/missing/current") -or (Test-Path "$root/.coop/packages/missing.json")) { throw 'missing command target published state' }

# Path traversal and link entries are rejected before any package publication.
$root = New-TestRoot
$fixtures = Join-Path $root 'fixtures'; New-Item -ItemType Directory -Path $fixtures -Force | Out-Null
$traversal = Join-Path $fixtures 'traversal.zip'
New-Zip $traversal @{'../escape.exe'=[IO.File]::ReadAllBytes($fixture1)}
Write-Manifest $root 'traversal' @{version='1';url=(File-Uri $traversal);hash=(Get-FileHash $traversal -Algorithm SHA256).Hash.ToLower();bin='escape.exe'}
$output = Invoke-CoopNative $CoopExe  --root $root install test/traversal --json
Assert-Failed 'path traversal archive unexpectedly succeeded' ($output -join "`n")
if (($output -join "`n") -notmatch 'path|Unsafe|Invalid') { throw 'path traversal was not reported clearly' }
if ((Test-Path "$root/apps/traversal/current") -or (Test-Path "$root/.coop/packages/traversal.json") -or (Test-Path "$root/escape.exe") -or (Test-Path "$TestRoot/escape.exe")) { throw 'path traversal escaped its package destination' }

$root = New-TestRoot
$fixtures = Join-Path $root 'fixtures'; New-Item -ItemType Directory -Path $fixtures -Force | Out-Null
$link = Join-Path $fixtures 'link.tar'
New-LinkTar $link
Write-Manifest $root 'link' @{version='1';url=(File-Uri $link);hash=(Get-FileHash $link -Algorithm SHA256).Hash.ToLower();bin='evil.exe'}
$output = Invoke-CoopNative $CoopExe  --root $root install test/link --json
Assert-Failed 'link archive unexpectedly succeeded' ($output -join "`n")
if (($output -join "`n") -notmatch 'link') { throw 'link entry was not reported clearly' }
if ((Test-Path "$root/apps/link/current") -or (Test-Path "$root/.coop/packages/link.json") -or (Test-Path "$root/evil.exe") -or (Test-Path "$TestRoot/evil.exe")) { throw 'link entry escaped its package destination' }

$root = New-TestRoot
$fixtures = Join-Path $root 'fixtures'; New-Item -ItemType Directory -Path $fixtures -Force | Out-Null
$hard = Join-Path $fixtures 'hardlink.tar'
New-HardLinkTar $hard
Write-Manifest $root 'hardlink' @{version='1';url=(File-Uri $hard);hash=(Get-FileHash $hard -Algorithm SHA256).Hash.ToLower();bin='hard.exe'}
$output = Invoke-CoopNative $CoopExe  --root $root install test/hardlink --json
Assert-Failed 'hardlink archive unexpectedly succeeded' ($output -join "`n")
if (($output -join "`n") -notmatch 'link') { throw 'hardlink entry was not reported clearly' }
if ((Test-Path "$root/apps/hardlink/current") -or (Test-Path "$root/.coop/packages/hardlink.json")) { throw 'hardlink entry published state' }

# A rejected archive during update must leave the working current version and record intact.
$root = New-TestRoot
function Write-Ripgrep([string]$version,[string]$url,[string]$hash) {
    Write-Manifest $root 'ripgrep' @{version=$version;architecture=@{'64bit'=@{url=$url;hash=$hash;extract_dir="ripgrep-$version-x86_64-pc-windows-msvc"}};bin='rg.exe'}
}
Write-Ripgrep '14.1.1' (File-Uri $rg14) 'd0f534024c42afd6cb4d38907c25cd2b249b79bbe6cc1dbee8e3e37c2b6e25a1'
$install = & $CoopExe --root $root install test/ripgrep --json
if ($LASTEXITCODE -ne 0) { throw 'update safety baseline install failed' }
$fixtures = Join-Path $root 'fixtures'; New-Item -ItemType Directory -Path $fixtures -Force | Out-Null
$link = Join-Path $fixtures 'link.tar'
New-LinkTar $link
Write-Ripgrep '15.2.0' (File-Uri $link) (Get-FileHash $link -Algorithm SHA256).Hash.ToLower()
$output = Invoke-CoopNative $CoopExe  --root $root update ripgrep --json
Assert-Failed 'link archive update unexpectedly succeeded' ($output -join "`n")
$version = First-Version (& "$root/shims/rg.exe" --version)
if ($version -notlike 'ripgrep 14.1.1*') { throw 'rejected archive update changed the current entry' }
if ((Test-Path "$root/apps/ripgrep/15.2.0") -or ([IO.File]::ReadAllText("$root/.coop/packages/ripgrep.json") | ConvertFrom-Json).version -ne '14.1.1') { throw 'rejected archive update changed publication state' }
$journal = Get-ChildItem "$root/.coop/transactions" -Recurse -Filter journal.json | Sort-Object LastWriteTime | Select-Object -Last 1
if ((Get-Content $journal.FullName -Raw | ConvertFrom-Json).state -ne 'rolled-back') { throw 'rejected archive update journal does not show rollback' }

# A corrupt MSI database fails clearly at extraction without msiexec and without publishing state.
$root = New-TestRoot
$brokenMsi = Join-Path $root 'fixtures/broken.msi'
New-Item -ItemType Directory -Path (Split-Path $brokenMsi) -Force | Out-Null
[IO.File]::WriteAllText($brokenMsi,'this is not an installer database',[Text.UTF8Encoding]::new($false))
Write-Manifest $root 'msi' @{version='1';url=(File-Uri $brokenMsi);hash=(Get-FileHash -LiteralPath $brokenMsi -Algorithm SHA256).Hash.ToLower();bin='setup.exe'}
$output = Invoke-CoopNative $CoopExe  --root $root install test/msi --json
Assert-Failed 'corrupt MSI archive unexpectedly succeeded' ($output -join "`n")
if (($output -join "`n") -notmatch 'MSI database') { throw 'corrupt MSI failure was not reported clearly' }
if ((Test-Path "$root/apps/msi/current") -or (Test-Path "$root/.coop/packages/msi.json")) { throw 'corrupt MSI published state' }
$msiJournal = Get-ChildItem "$root/.coop/transactions" -Recurse -Filter journal.json -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if ($msiJournal -and (Get-Content $msiJournal.FullName -Raw | ConvertFrom-Json).state -ne 'rolled-back') { throw 'corrupt MSI journal does not show rollback' }

# Interrupted archive download keeps the previous current version and a pending journal.
$root = New-TestRoot
Write-Ripgrep '14.1.1' (File-Uri $rg14) 'd0f534024c42afd6cb4d38907c25cd2b249b79bbe6cc1dbee8e3e37c2b6e25a1'
$install = & $CoopExe --root $root install test/ripgrep --json
if ($LASTEXITCODE -ne 0) { throw 'interruption baseline install failed' }
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$process = $null
$client = $null
try {
    Write-Manifest $root 'ripgrep' @{version='15.2.0';architecture=@{'64bit'=@{url="http://127.0.0.1:$port/slow.zip";hash='71b2fef860abe467217a538ff31de02f5258807c0129f771846f87bd029aafc5';extract_dir='ripgrep-15.2.0-x86_64-pc-windows-msvc'}};bin='rg.exe'}
    $connection = $listener.AcceptTcpClientAsync()
    $start = [Diagnostics.ProcessStartInfo]::new($CoopExe)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('--root',$root,'update','ripgrep','--json')) { Add-ProcessArgument $start ($argument) }
    $process = [Diagnostics.Process]::Start($start)
    if (-not $connection.Wait(15000)) { throw 'archive downloader did not connect to local listener' }
    $client = $connection.GetAwaiter().GetResult()
    $stream = $client.GetStream()
    $buffer = [byte[]]::new(4096)
    $stream.Read($buffer,0,$buffer.Length) | Out-Null
    $header = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 100000000`r`n`r`n")
    $stream.Write($header,0,$header.Length)
    $stream.Write(([byte[]](1..1024 | ForEach-Object { $_ % 251 })),0,1024)
    $stream.Flush()
    $journal = $null
    for ($attempt = 0; $attempt -lt 100 -and -not $journal; $attempt++) {
        Start-Sleep -Milliseconds 100
        $journal = Get-ChildItem "$root/.coop/transactions" -Recurse -Filter journal.json -ErrorAction SilentlyContinue |
            Where-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).state -eq 'pending' } | Select-Object -Last 1
    }
    if (-not $journal) { throw 'interrupted archive update did not create a pending journal' }
    $process.Kill(); $process.WaitForExit()
    $version = First-Version (& "$root/shims/rg.exe" --version)
    if ($version -notlike 'ripgrep 14.1.1*') { throw 'interrupted archive update changed the current entry' }
    if (-not (Test-Path "$root/apps/ripgrep/current") -or (Test-Path "$root/apps/ripgrep/15.2.0")) { throw 'interrupted archive update changed publication state' }
    $journalState = (Get-Content $journal.FullName -Raw | ConvertFrom-Json).state
    if ($journalState -ne 'pending') { throw "interrupted archive update journal is $journalState, not pending" }
    $query = & $CoopExe --root $root list --json
    if ($LASTEXITCODE -ne 0) { throw 'pending archive writer blocked read-only query' }
    $retry = Invoke-CoopNative $CoopExe  --root $root update ripgrep --json
    if ($LASTEXITCODE -eq 0 -or ($retry -join "`n") -notmatch 'Pending transaction requires recovery') { throw 'pending archive transaction was silently ignored' }
} finally {
    if ($client) { $client.Dispose() }
    $listener.Stop()
    if ($process) { if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }; $process.Dispose() }
}

@{coop=$CoopExe;archives=$archives;unsupported=$unsupported.Count;interrupt_journal=$journal.FullName} | ConvertTo-Json | Set-Content (Join-Path $TestRoot 'archive-safety-evidence.json') -Encoding utf8
Write-Output "PASS archive bad/link/traversal rejection, unsupported formats and interrupted update: $TestRoot"
exit 0

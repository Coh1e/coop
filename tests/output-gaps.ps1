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

Write-Output 'output gaps: download size and batch update blocks verified'

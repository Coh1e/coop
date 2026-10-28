param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# #66: the contracts the publish seam owns, asserted through the real CLI.
#  1. A declared extract_dir that selects nothing must fail. It must not publish a version that
#     merely looks installed: with no `bin` declared, a silent skip produced a successful install
#     whose version directory held nothing but the two records.
#  2. Two entries that land on the same target must fail instead of overwriting each other.
#  3. A failed publication removes only what it wrote. A multi-artifact package publishes the first
#     archive, then fails on a corrupt second one; the first archive's content must still be in the
#     staging directory left behind, which the transaction keeps in a rolled-back state.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$ripgrep = Join-Path $archives 'ripgrep-15.2.0-x86_64-pc-windows-msvc.zip'
$tidy = Join-Path $archives 'tidy-5.8.0-win64.zip'
$luajit = Join-Path $archives 'luajit-2.1.1791988261-1-any.pkg.tar.zst'
foreach ($path in @($ripgrep,$tidy,$luajit)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing fixed test input: $path; run scripts/fetch-deps.ps1" }
}

$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null

function File-Hash([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
function Write-Manifest([string]$name,[hashtable]$manifest) {
    $ordered = [ordered]@{}
    foreach ($key in ($manifest.Keys | Sort-Object)) { $ordered[$key] = $manifest[$key] }
    [IO.File]::WriteAllText("$root/buckets/test/bucket/$name.json",
        ($ordered | ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
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
function Assert-NoCurrent([string]$name) {
    if (Test-Path -LiteralPath "$root/apps/$name/current") { throw "'$name' published current despite failing" }
}

# 1. A declared extract_dir that selects nothing fails, and names the directory.
Write-Manifest 'empty-selection' @{version='1.0.0';url=(File-Uri $ripgrep);hash=(File-Hash $ripgrep);extract_dir='missing-dir'}
$run = Invoke-Coop @('--root',$root,'install','test/empty-selection','--json')
$text = $run.error + $run.output
if ($run.exit -eq 0) { throw "a missing extract_dir installed successfully: $text" }
if ($text -notmatch 'missing-dir') { throw "the failure did not name the missing extract_dir: $text" }
Assert-NoCurrent 'empty-selection'

# 2. Two entries that collapse onto one target fail instead of overwriting.
$collision = Join-Path $root 'collision.zip'
$zip = [IO.Compression.ZipFile]::Open($collision,'Create')
try {
    foreach ($entry in @('d/a.txt','d/A.TXT')) {
        $handle = $zip.CreateEntry($entry)
        $writer = [IO.StreamWriter]::new($handle.Open())
        $writer.Write($entry)
        $writer.Dispose()
    }
} finally { $zip.Dispose() }
Write-Manifest 'collision' @{version='1.0.0';url=(File-Uri $collision);hash=(File-Hash $collision);extract_dir='d';bin='a.txt'}
$run = Invoke-Coop @('--root',$root,'install','test/collision','--json')
$text = $run.error + $run.output
if ($run.exit -eq 0) { throw "colliding archive entries installed successfully: $text" }
if ($text -notmatch '(?i)collide') { throw "the failure did not report a collision: $text" }
Assert-NoCurrent 'collision'

# 3. The same missing extract_dir on a package that does declare an entry fails through the extraction
#    contract, not through a downstream entry check noticing an empty directory.
Write-Manifest 'empty-with-bin' @{version='1.0.0';url=(File-Uri $ripgrep);hash=(File-Hash $ripgrep);extract_dir='missing-dir';bin='rg.exe'}
$run = Invoke-Coop @('--root',$root,'install','test/empty-with-bin','--json')
$text = $run.error + $run.output
if ($run.exit -eq 0) { throw "a missing extract_dir installed successfully: $text" }
if ($text -notmatch 'extract_dir') { throw "the failure came from somewhere other than the extraction contract: $text" }
Assert-NoCurrent 'empty-with-bin'

# 4. A multi-artifact package: the first archive publishes, the second is corrupt, and the first
#    archive's content must survive the failed publication in the staging directory.
# A truncated stream opens as a tar.zst and fails *inside* the entry loop, which is the failure a
# publication has to survive; random bytes would fail earlier, at open, and never reach the cleanup.
$truncated = Join-Path $root 'truncated.tar.zst'
$bytes = [IO.File]::ReadAllBytes($luajit)
[IO.File]::WriteAllBytes($truncated,$bytes[0..([int]($bytes.Length*0.6))])
Write-Manifest 'isolation' @{
    version='1.0.0'
    url=@((File-Uri $tidy),(File-Uri $truncated))
    hash=@((File-Hash $tidy),(File-Hash $truncated))
    extract_dir=@('tidy-5.8.0-win64\bin','mingw64')
    bin='tidy.exe'
}
$run = Invoke-Coop @('--root',$root,'install','test/isolation','--json')
$text = $run.error + $run.output
if ($run.exit -eq 0) { throw "the corrupt second artifact installed successfully: $text" }
Assert-NoCurrent 'isolation'
$staging = @(Get-ChildItem -LiteralPath "$root/.coop/transactions" -Directory -Force -ErrorAction SilentlyContinue |
    ForEach-Object { Join-Path $_.FullName 'payload' } | Where-Object { Test-Path -LiteralPath $_ })
if ($staging.Count -eq 0) { throw 'the failed multi-artifact install left no staging directory to inspect' }
$survived = @($staging | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'tidy.exe') })
if ($survived.Count -eq 0) {
    throw 'the failed second artifact removed the first artifact''s published content from the staging directory'
}

Write-Output 'publish contracts: 4 cases verified'

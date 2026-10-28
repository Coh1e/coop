param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# #57: an update is a visible two-phase operation. The block below is the recorded Scoop shape, with
# one deliberate difference: coop extracts and verifies before it unpublishes the old version, so the
# extract lines appear above the Uninstalling header. That order is what keeps `current` on the old
# version when the new payload cannot be extracted, which the same ticket requires.
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
function Write-Manifest([string]$version,[string]$file = $tidy) {
    $ordered = [ordered]@{ version=$version; url=(File-Uri $file); hash=(File-Hash $file)
        extract_dir='tidy-5.8.0-win64\bin'; bin='tidy.exe' }
    [IO.File]::WriteAllText("$root/buckets/test/bucket/tidy.json",
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

Write-Manifest '5.8.0'
if ((Invoke-Coop @('--root',$root,'install','test/tidy','--json')).exit -ne 0) { throw 'the first install failed' }

$esc = [string][char]27
$cyan = "$esc[36mtidy-5.8.0-win64.zip$esc[0m"
Write-Manifest '5.8.1'
$update = Invoke-Coop @('--root',$root,'update','tidy')
if ($update.exit -ne 0) { throw "the update failed: $($update.error)$($update.output)" }
$expected = @(
    'tidy: 5.8.0 -> 5.8.1'
    'Updating one outdated app:'
    "Updating 'tidy' (5.8.0 -> 5.8.1)"
    'Downloading new version'
    'Loading tidy-5.8.0-win64.zip from cache'
    "Checking hash of $cyan... "
    'OK.'
    "Extracting $cyan... "
    'Done.'
    "Uninstalling 'tidy' (5.8.0)"
    "Removing shim 'tidy.shim'."
    "Removing shim 'tidy.exe'."
    "Unlinking $root\apps\tidy\current"
    "Installing 'tidy' (5.8.1) [64bit] from 'test' bucket"
    "Linking $root\apps\tidy\current => $root\apps\tidy\5.8.1"
    "Creating shim for 'tidy'."
    "'tidy' (5.8.1) was installed successfully!"
)
$actual = @($update.output -split "`r?`n")
while ($actual.Count -gt 0 -and $actual[-1] -eq '') { $actual = $actual[0..($actual.Count-2)] }
if (($expected -join "`n") -ne ($actual -join "`n")) {
    throw "the update block does not match:`n--- expected ---`n$($expected -join "`n")`n--- actual ---`n$($actual -join "`n")"
}

# A newer version whose payload cannot be extracted leaves the working version in place.
$broken = Join-Path $root 'broken.tar.zst'
[IO.File]::WriteAllBytes($broken,[byte[]](1..4096 | ForEach-Object { $_ % 251 }))
$brokenManifest = [ordered]@{ version='5.8.2'; url=([Uri][IO.Path]::GetFullPath($broken)).AbsoluteUri
    hash=(Get-FileHash -LiteralPath $broken -Algorithm SHA256).Hash.ToLower()
    extract_dir='mingw64'; bin='bin\luajit.exe' }
[IO.File]::WriteAllText("$root/buckets/test/bucket/tidy.json",
    ($brokenManifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$failed = Invoke-Coop @('--root',$root,'update','tidy','--json')
if ($failed.exit -eq 0) { throw 'a corrupt update unexpectedly succeeded' }
if (-not (Test-Path -LiteralPath "$root/apps/tidy/5.8.1/tidy.exe")) { throw 'the working version was disturbed by the failed update' }
$target = (Get-Item -LiteralPath "$root/apps/tidy/current" -Force).LinkTarget
if (-not ([string]$target).EndsWith('5.8.1')) { throw "current moved away from the working version: $target" }

Write-Output 'update lines: block and failure protection verified'

param(
    [Parameter(Mandatory)][string]$CoopExe,
    [string]$Output = (Join-Path $PSScriptRoot '../.local/acceptance')
)
# #55: produces the acceptance evidence the matrix document quotes. Everything runs against a project-
# local root with file:// fixtures, so the result is reproducible without network, and every transcript
# records the exact command, its exit code and its output.
$ErrorActionPreference = 'Stop'
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$Output = [IO.Path]::GetFullPath($Output)
Remove-Item $Output -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $Output -Force | Out-Null
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$tidy = Join-Path $archives 'tidy-5.8.0-win64.zip'
if (-not (Test-Path -LiteralPath $tidy)) { throw "Missing fixed test input: $tidy; run scripts/fetch-deps.ps1" }

$root = Join-Path $Output 'root'
New-Item -ItemType Directory -Path "$root/buckets/test/bucket","$root/.coop" -Force | Out-Null

function File-Hash([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function Write-Manifest([string]$name,[string]$version,[string]$url = $null) {
    $ordered = [ordered]@{
        version=$version; url=$(if ($url) { $url } else { ([Uri][IO.Path]::GetFullPath($tidy)).AbsoluteUri })
        hash=(File-Hash $tidy); extract_dir='tidy-5.8.0-win64\bin'; bin=@(,@('tidy.exe',"bin$name"))
    }
    [IO.File]::WriteAllText("$root/buckets/test/bucket/$name.json",
        ($ordered | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
function Invoke-Recorded([string]$label,[string[]]$arguments,[hashtable]$environment = @{}) {
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
    foreach ($key in $environment.Keys) { $start.Environment[$key] = $environment[$key] }
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(300000)) { $process.Kill($true); throw "$label timed out" }
    $result = [pscustomobject]@{ exit = $process.ExitCode
        output = $stdout.GetAwaiter().GetResult(); error = $stderr.GetAwaiter().GetResult() }
    $process.Dispose()
    $transcript = @(
        "COMMAND: coop $($arguments -join ' ')"
        "EXIT: $($result.exit)"
        '--- stdout ---'
        ($result.output -replace "`e","<ESC>")
        '--- stderr ---'
        ($result.error -replace "`e","<ESC>")
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $Output "$label.txt"),$transcript,[Text.UTF8Encoding]::new($false))
    return $result
}
function Latest-Timings {
    $records = @(Get-ChildItem -LiteralPath "$root/.coop/timings" -Filter '*.json' -File | Sort-Object LastWriteTime)
    if ($records.Count -eq 0) { return $null }
    return (Get-Content -LiteralPath $records[-1].FullName -Raw | ConvertFrom-Json)
}

# --- install / uninstall / cache hit -------------------------------------------------------------
Write-Manifest 'cold' '1.0.0'
$install = Invoke-Recorded '01-install-cold' @('--root',$root,'install','test/cold','--timings')
if ($install.exit -ne 0) { throw "the cold install failed: $($install.error)" }
$coldTimings = Latest-Timings

$hit = Invoke-Recorded '02-install-cache-hit' @('--root',$root,'uninstall','test/cold','--json')
Write-Manifest 'cold' '1.0.0'
$installAgain = Invoke-Recorded '03-install-from-cache' @('--root',$root,'install','test/cold','--timings')
$hitTimings = Latest-Timings

# --- update / reset / cleanup --------------------------------------------------------------------
Write-Manifest 'cold' '1.1.0'
$update = Invoke-Recorded '04-update' @('--root',$root,'update','test/cold')
$reset = Invoke-Recorded '05-reset' @('--root',$root,'reset','test/cold@1.0.0')
$cleanup = Invoke-Recorded '06-cleanup' @('--root',$root,'cleanup')
$uninstall = Invoke-Recorded '07-uninstall' @('--root',$root,'uninstall','test/cold')

# --- recover (crash injection, then rollback) ----------------------------------------------------
Write-Manifest 'crashy' '1.0.0'
Set-Content -LiteralPath "$root/.coop/test-faults.json" -Value '{"crash":["after-extract"]}' -Encoding utf8
$crash = Invoke-Recorded '08-install-crash' @('--root',$root,'install','test/crashy','--json') @{ 'COOP_ALLOW_TEST_FAULTS' = '1' }
Remove-Item -LiteralPath "$root/.coop/test-faults.json" -Force
$recover = Invoke-Recorded '09-recover' @('--root',$root,'recover')

# --- cache self-healing --------------------------------------------------------------------------
Write-Manifest 'cacheable' '1.0.0'
$first = Invoke-Recorded '10-cache-fill' @('--root',$root,'install','test/cacheable','--json')
Invoke-Recorded '11-cache-fill-uninstall' @('--root',$root,'uninstall','test/cacheable','--json') | Out-Null
$cached = Join-Path $root 'cache/tidy-5.8.0-win64.zip'
if (-not (Test-Path -LiteralPath $cached)) { throw 'the cache file was not written' }
$bytes = [IO.File]::ReadAllBytes($cached)
$bytes[0] = 0x00
[IO.File]::WriteAllBytes($cached,$bytes)
$heal = Invoke-Recorded '12-cache-corrupt-install' @('--root',$root,'install','test/cacheable')
Invoke-Recorded '13-cache-heal-uninstall' @('--root',$root,'uninstall','test/cacheable','--json') | Out-Null

# --- offline reuse from cache --------------------------------------------------------------------
Write-Manifest 'offline' '1.0.0'
$fill = Invoke-Recorded '14-offline-fill' @('--root',$root,'install','test/offline','--json')
Invoke-Recorded '15-offline-fill-uninstall' @('--root',$root,'uninstall','test/offline','--json') | Out-Null
Write-Manifest 'offline' '1.0.0' 'https://example.invalid/tidy-5.8.0-win64.zip'
$offline = Invoke-Recorded '16-offline-install' @('--root',$root,'install','test/offline')

# --- summary -------------------------------------------------------------------------------------
$summary = [ordered]@{
    coop = (& $CoopExe --version)
    machine = "$env:COMPUTERNAME / $([Environment]::OSVersion.VersionString)"
    fixture = $tidy
    fixture_sha256 = (File-Hash $tidy)
    fixture_bytes = (Get-Item -LiteralPath $tidy).Length
    scenarios = [ordered]@{
        '01-install-cold' = $install.exit
        '03-install-from-cache' = $installAgain.exit
        '04-update' = $update.exit
        '05-reset' = $reset.exit
        '06-cleanup' = $cleanup.exit
        '07-uninstall' = $uninstall.exit
        '08-install-crash' = $crash.exit
        '09-recover' = $recover.exit
        '12-cache-corrupt-install' = $heal.exit
        '16-offline-install' = $offline.exit
    }
    cold_timings = $(if ($coldTimings) { $coldTimings } else { 'not recorded' })
    cache_hit_timings = $(if ($hitTimings) { $hitTimings } else { 'not recorded' })
}
$text = $summary | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText((Join-Path $Output 'summary.json'),$text,[Text.UTF8Encoding]::new($false))
Write-Output $text

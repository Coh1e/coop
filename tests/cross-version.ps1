param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# #74: installing a different version behaves like Scoop's install - the new version is created beside
# the old one, `current` moves, the old version stays and cleanup can still retire it. The file is kept
# out of the default CTest suite until the feature exists: it is the acceptance for the ticket, not a
# green test.
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
function Write-Manifest([string]$name,[string]$version,[hashtable]$extra = @{}) {
    $ordered = [ordered]@{ version=$version; url=(File-Uri $tidy); hash=(File-Hash $tidy)
        extract_dir='tidy-5.8.0-win64\bin'; bin=@(,@('tidy.exe',"bin$name")) }
    foreach ($key in $extra.Keys) { $ordered[$key] = $extra[$key] }
    [IO.File]::WriteAllText("$root/buckets/test/bucket/$name.json",
        ($ordered | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
function Invoke-Coop([string[]]$arguments,[hashtable]$environment = @{}) {
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
    if (-not $process.WaitForExit(300000)) { $process.Kill($true); throw 'coop timed out' }
    $result = [pscustomobject]@{ exit = $process.ExitCode
        output = $stdout.GetAwaiter().GetResult(); error = $stderr.GetAwaiter().GetResult() }
    $process.Dispose()
    return $result
}

# 1. The second version installs, both directories stay, current moves, and cleanup retires the old one.
Write-Manifest 'app' '1.0.0'
$first = Invoke-Coop @('--root',$root,'install','test/app','--json')
if ($first.exit -ne 0) { throw "the first install failed: $($first.error)" }
Write-Manifest 'app' '2.0.0'
$second = Invoke-Coop @('--root',$root,'install','test/app')
if ($second.exit -ne 0) { throw "the second install failed: $($second.error)$($second.output)" }
if (-not (Test-Path -LiteralPath "$root/apps/app/1.0.0")) { throw 'the install removed the version it replaced' }
if (-not (Test-Path -LiteralPath "$root/apps/app/2.0.0")) { throw 'the install did not create the new version' }
$target = (Get-Item -LiteralPath "$root/apps/app/current").Target
if ($target -notmatch '2\.0\.0') { throw "current does not point at the new version: $target" }
$run = & "$root/shims/binapp.exe" --version 2>&1
if (($run -join ' ') -notmatch '5\.8\.0') { throw "the replaced entry does not run: $run" }
$cleanup = Invoke-Coop @('--root',$root,'cleanup')
if ($cleanup.exit -ne 0) { throw "cleanup failed after a cross-version install: $($cleanup.error)$($cleanup.output)" }
if ($cleanup.output -notmatch 'Removing app:' -or $cleanup.output -notmatch ' 1\.0\.0') {
    throw "cleanup did not retire the old version: $($cleanup.output)"
}
if (Test-Path -LiteralPath "$root/apps/app/1.0.0") { throw 'cleanup left the old version behind' }

# 2. A foreign file at the entry name is never clobbered: the install has to fail atomically.
Write-Manifest 'guard' '1.0.0'
$guard = Invoke-Coop @('--root',$root,'install','test/guard','--json')
if ($guard.exit -ne 0) { throw "the guard install failed: $($guard.error)" }
Write-Manifest 'guard' '2.0.0'
[IO.File]::WriteAllText("$root/shims/binguard.exe",'foreign data must survive')
$conflict = Invoke-Coop @('--root',$root,'install','test/guard','--json')
if ($conflict.exit -eq 0) { throw 'the install overwrote a foreign entry' }
if ([IO.File]::ReadAllText("$root/shims/binguard.exe") -ne 'foreign data must survive') {
    throw 'the failed install changed the foreign file'
}

# 3. A crash during the second version leaves the first one usable after recovery.
Write-Manifest 'crashy' '1.0.0'
$crashFirst = Invoke-Coop @('--root',$root,'install','test/crashy','--json')
if ($crashFirst.exit -ne 0) { throw "the crash fixture install failed: $($crashFirst.error)" }
Write-Manifest 'crashy' '2.0.0'
'{"crash":["after-extract"]}' | Set-Content -LiteralPath "$root/.coop/test-faults.json" -Encoding utf8
$crash = Invoke-Coop @('--root',$root,'install','test/crashy','--json') @{ 'COOP_ALLOW_TEST_FAULTS' = '1' }
Remove-Item -LiteralPath "$root/.coop/test-faults.json" -Force
if ($crash.exit -eq 0) { throw 'the injected crash did not stop the install' }
$recover = Invoke-Coop @('--root',$root,'recover')
if ($recover.exit -ne 0) { throw "recover failed: $($recover.error)" }
$afterRecovery = (Get-Item -LiteralPath "$root/apps/crashy/current").Target
if ($afterRecovery -notmatch '1\.0\.0') { throw "recovery did not restore the old current: $afterRecovery" }
if (-not (Test-Path -LiteralPath "$root/apps/crashy/1.0.0")) { throw 'recovery lost the old version' }

Write-Output 'cross-version install: 3 cases verified'

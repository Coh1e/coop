# Red when: the install refuses a different version again, keeps the replaced version directory out of
# `versions`, skips the target-version guard, or stops retiring this package's own entries and shortcut.
param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# #74: installing a different version behaves like Scoop's install - the new version is created beside
# the old one, `current` moves, the old version stays and cleanup can still retire it. The file is kept
# out of the default CTest suite until the feature exists: it is the acceptance for the ticket, not a
# green test.
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
    foreach ($argument in $arguments) { Add-ProcessArgument $start ($argument) }
    $start.EnvironmentVariables['TEMP'] = "$root/temp"
    $start.EnvironmentVariables['TMP'] = "$root/temp"
    # Shortcuts normally land in the real Start Menu; the override keeps them inside the test root.
    $start.EnvironmentVariables['COOP_PROGRAMS_DIR'] = "$root/programs"
    foreach ($key in $environment.Keys) { $start.EnvironmentVariables[$key] = $environment[$key] }
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(300000)) { $process.Kill(); throw 'coop timed out' }
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
$run = Invoke-CoopNative "$root/shims/binapp.exe"  --version
if (($run -join ' ') -notmatch '5\.8\.0') { throw "the replaced entry does not run: $run" }
$cleanup = Invoke-Coop @('--root',$root,'cleanup')
if ($cleanup.exit -ne 0) { throw "cleanup failed after a cross-version install: $($cleanup.error)$($cleanup.output)" }
if ($cleanup.output -notmatch 'Removing app:' -or $cleanup.output -notmatch ' 1\.0\.0') {
    throw "cleanup did not retire the old version: $($cleanup.output)"
}
if (Test-Path -LiteralPath "$root/apps/app/1.0.0") { throw 'cleanup left the old version behind' }

# 2. A foreign file at the entry name is never clobbered. The failure is the ownership check that
#    compares the existing launcher with Coop's own, so the reason is named rather than "any failure".
Write-Manifest 'guard' '1.0.0'
$guard = Invoke-Coop @('--root',$root,'install','test/guard','--json')
if ($guard.exit -ne 0) { throw "the guard install failed: $($guard.error)" }
Write-Manifest 'guard' '2.0.0'
[IO.File]::WriteAllText("$root/shims/binguard.exe",'foreign data must survive')
$conflict = Invoke-Coop @('--root',$root,'install','test/guard','--json')
if ($conflict.exit -eq 0) { throw 'the install overwrote a foreign entry' }
if ($conflict.error -notmatch 'launcher|conflict|published') {
    throw "the install failed for an unrelated reason: $($conflict.error)"
}
if ([IO.File]::ReadAllText("$root/shims/binguard.exe") -ne 'foreign data must survive') {
    throw 'the failed install changed the foreign file'
}

# 3. A crash after the new entries were published leaves the old version recoverable: the fault fires
#    after `current` and the entries have moved, so recovery has real work to do.
Write-Manifest 'crashy' '1.0.0'
$crashFirst = Invoke-Coop @('--root',$root,'install','test/crashy','--json')
if ($crashFirst.exit -ne 0) { throw "the crash fixture install failed: $($crashFirst.error)" }
Write-Manifest 'crashy' '2.0.0'
'{"crash":["after-entry"]}' | Set-Content -LiteralPath "$root/.coop/test-faults.json" -Encoding utf8
$crash = Invoke-Coop @('--root',$root,'install','test/crashy','--json') @{ 'COOP_ALLOW_TEST_FAULTS' = '1' }
Remove-Item -LiteralPath "$root/.coop/test-faults.json" -Force
if ($crash.exit -eq 0) { throw 'the injected crash did not stop the install' }
# The crash has to leave a pending journal, otherwise recovery proves nothing.
$pending = @(Get-ChildItem -LiteralPath "$root/.coop/transactions" -Directory -ErrorAction SilentlyContinue | Where-Object {
    $journal = Join-Path $_.FullName 'journal.json'
    (Test-Path -LiteralPath $journal) -and ((Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json).state -eq 'pending')
})
if ($pending.Count -eq 0) { throw 'the crash left no pending transaction; recovery would be a no-op' }
$recover = Invoke-Coop @('--root',$root,'recover')
if ($recover.exit -ne 0) { throw "recover failed: $($recover.error)" }
$afterRecovery = (Get-Item -LiteralPath "$root/apps/crashy/current").Target
if ($afterRecovery -notmatch '1\.0\.0') { throw "recovery did not restore the old current: $afterRecovery" }
if (-not (Test-Path -LiteralPath "$root/apps/crashy/1.0.0")) { throw 'recovery lost the old version' }
if (Test-Path -LiteralPath "$root/apps/crashy/2.0.0") { throw 'recovery left the half-published version behind' }
$entry = Invoke-CoopNative "$root/shims/bincrashy.exe"  --version
if (($entry -join ' ') -notmatch '5\.8\.0') { throw "the restored entry does not run: $($entry -join ' ')" }

# 4. A package whose Manifest declares a shortcut installs across versions: the old shortcut belongs to
#    the same package, so it is replaced rather than treated as a foreign file.
Write-Manifest 'shorty' '1.0.0' @{ shortcuts=@(,@('tidy.exe','shorty')) }
$shortFirst = Invoke-Coop @('--root',$root,'install','test/shorty','--json')
if ($shortFirst.exit -ne 0) { throw "the shortcut fixture install failed: $($shortFirst.error)" }
Write-Manifest 'shorty' '2.0.0' @{ shortcuts=@(,@('tidy.exe','shorty')) }
$shortSecond = Invoke-Coop @('--root',$root,'install','test/shorty','--json')
if ($shortSecond.exit -ne 0) { throw "the cross-version shortcut install failed: $($shortSecond.error)" }
$shortTarget = (Get-Item -LiteralPath "$root/apps/shorty/current").Target
if ($shortTarget -notmatch '2\.0\.0') { throw "current was not repointed: $shortTarget" }

# 5. A version that adds an alias installs: the old version's entries are retired, not verified against
#    the new package's list.
Write-Manifest 'grow' '1.0.0'
$growFirst = Invoke-Coop @('--root',$root,'install','test/grow','--json')
if ($growFirst.exit -ne 0) { throw "the alias fixture install failed: $($growFirst.error)" }
$growManifest = [ordered]@{ version='2.0.0'; url=(File-Uri $tidy); hash=(File-Hash $tidy)
    extract_dir='tidy-5.8.0-win64\bin'; bin=@(@('tidy.exe','bingrow'),@('tidy.exe','bingrow2')) }
[IO.File]::WriteAllText("$root/buckets/test/bucket/grow.json",
    ($growManifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$growSecond = Invoke-Coop @('--root',$root,'install','test/grow')
if ($growSecond.exit -ne 0) { throw "the alias-adding install failed: $($growSecond.error)$($growSecond.output)" }
foreach ($alias in 'bingrow','bingrow2') {
    if (-not (Test-Path -LiteralPath "$root/shims/$alias.exe")) { throw "the install did not publish $alias" }
}

Write-Output 'cross-version install: 5 cases verified'

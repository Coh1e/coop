param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# #52: durability is owed at the commit points, not to every extracted file. The extraction tree lives
# in the transaction and is discarded on failure, so flushing each entry buys nothing a rollback cannot
# already fix. The record now counts the write-through flushes, which makes the claim measurable: an
# archive with hundreds of files must not produce hundreds of syncs.
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not (($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase))) { throw 'Test root outside project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$curl = Join-Path $archives 'curl-8.23.0_5-win64-mingw.tar.xz'
if (-not (Test-Path -LiteralPath $curl)) { throw "Missing fixed test input: $curl; run scripts/fetch-deps.ps1" }

$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null
$manifest = [ordered]@{ version='8.23.0_5'; url=([Uri][IO.Path]::GetFullPath($curl)).AbsoluteUri
    hash=(Get-FileHash -LiteralPath $curl -Algorithm SHA256).Hash.ToLower()
    extract_dir='curl-8.23.0_5-win64-mingw'; bin='bin\curl.exe' }
[IO.File]::WriteAllText("$root/buckets/test/bucket/curl.json",
    ($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))

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

$install = Invoke-Coop @('--root',$root,'install','test/curl','--json')
if ($install.exit -ne 0) { throw "the install failed: $($install.error)$($install.output)" }

$files = @(Get-ChildItem -LiteralPath "$root/apps/curl/current" -Recurse -File)
if ($files.Count -lt 300) { throw "the fixture did not publish enough files to be meaningful: $($files.Count)" }

$records = @(Get-ChildItem -LiteralPath "$root/.coop/timings" -Filter '*.json' -File)
if ($records.Count -eq 0) { throw 'no timing record was written' }
$record = Get-Content -LiteralPath $records[0].FullName -Raw | ConvertFrom-Json
if ($null -eq $record.durable_syncs) { throw 'the record does not carry the sync count' }

# Well below one per file: a regression that flushes every entry lands at or above the file count.
if ([int]$record.durable_syncs -ge $files.Count) {
    throw "the install synced once per file: $($record.durable_syncs) syncs for $($files.Count) files"
}
if ([int]$record.durable_syncs -gt 60) {
    throw "the install performed more write-through flushes than the commit points need: $($record.durable_syncs)"
}

Write-Output "sync points: $($record.durable_syncs) syncs for $($files.Count) files"

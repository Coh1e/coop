# Red when: `cleanup --transactions` does not trim finished records, touches a pending one, reports a
# wrong keep count or frees nothing; the previous binary rejected the switch as an unknown option.
param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }
$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
$transactions = Join-Path $root '.coop/transactions'
New-Item -ItemType Directory -Path $transactions -Force | Out-Null

# Twelve finished records and one pending: the pending one is what `recover` needs and must survive.
for ($index = 0; $index -lt 12; $index++) {
    $directory = Join-Path $transactions ('finished-{0:d2}' -f $index)
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $directory 'journal.json'),'{"state":"committed"}')
    [IO.File]::WriteAllText((Join-Path $directory 'payload.bin'),('x' * 1024))
    (Get-Item -LiteralPath $directory).LastWriteTime = (Get-Date).AddMinutes(-$index - 1)
}
$pending = Join-Path $transactions 'pending-run'
New-Item -ItemType Directory -Path $pending -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $pending 'journal.json'),'{"state":"pending"}')
(Get-Item -LiteralPath $pending).LastWriteTime = (Get-Date).AddMinutes(-120)

$dry = Invoke-CoopJson $CoopExe --root $root cleanup --transactions --dry-run --json
if (@($dry.removed).Count -ne 2) { throw "a dry run planned $((@($dry.removed)).Count) removals, expected 2" }
if (-not (Test-Path -LiteralPath (Join-Path $transactions 'finished-11'))) { throw 'a dry run deleted a record' }

$result = Invoke-CoopJson $CoopExe --root $root cleanup --transactions --json
if ($result.kept -ne 10) { throw "kept $($result.kept) records, expected the newest 10" }
if ($result.pending -ne 1) { throw "reported $($result.pending) pending records, expected 1" }
if (@($result.removed).Count -ne 2) { throw "removed $(@($result.removed).Count) records, expected 2" }
if ($result.bytes -lt 2048) { throw "reported $($result.bytes) bytes freed, expected the two payloads" }
if (-not (Test-Path -LiteralPath $pending)) { throw 'a pending transaction was deleted; recovery needs it' }
if (Test-Path -LiteralPath (Join-Path $transactions 'finished-11')) { throw 'the oldest record survived' }
if (-not (Test-Path -LiteralPath (Join-Path $transactions 'finished-00'))) { throw 'the newest record was deleted' }
if (@(Get-ChildItem -LiteralPath $transactions -Directory).Count -ne 11) { throw 'the record count does not match the report' }

# A second run has nothing left to trim, and says so without failing.
$again = Invoke-CoopJson $CoopExe --root $root cleanup --transactions --json
if (@($again.removed).Count -ne 0) { throw 'a second run removed records' }
if ($again.kept -ne 10) { throw 'a second run reported a different keep count' }

$text = (Invoke-CoopStdout $CoopExe --root $root cleanup --transactions) -join "`n"
if ($text -notmatch 'Kept 10 transaction record\(s\), 1 pending') { throw "the text output does not report the keep count: $text" }

# A root without any record is a clean state, not an error.
$empty = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $empty -Force | Out-Null
$none = Invoke-CoopStdout $CoopExe --root $empty cleanup --transactions
if (($none -join "`n") -notmatch 'No transaction records to clean') { throw "an empty root did not report a clean state: $none" }
if ($LASTEXITCODE -ne 0) { throw 'an empty root failed the command' }

Write-Output "PASS cleanup --transactions keeps ten records, spares pending work and reports the freed bytes: $TestRoot"

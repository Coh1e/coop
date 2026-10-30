# Red when: a write command stops leaving a record behind after being killed, `recover` stops naming
# that record, a normal run starts leaving one, or `recover --dry-run` consumes it.
param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test data must stay within the project test directory'
}
$archive = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives/ripgrep-15.2.0-x86_64-pc-windows-msvc.zip'))
if (-not (Test-Path -LiteralPath $archive)) { throw "Missing test archive: $archive" }
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower()
$url = 'file:///' + ($archive -replace '\\', '/')
$root = Join-Path $TestRoot 'run-record'
if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
New-Item -ItemType Directory -Path "$root/buckets/probe/bucket" -Force | Out-Null
@"
{
  "version": "1.0",
  "url": "$url",
  "hash": "$hash",
  "extract_dir": "ripgrep-15.2.0-x86_64-pc-windows-msvc",
  "bin": [ [ "rg.exe", "rgtrace" ] ]
}
"@ | Set-Content "$root/buckets/probe/bucket/slow.json" -Encoding utf8 -NoNewline

# A run that finishes leaves nothing behind.
& $CoopExe --root $root install probe/slow | Out-Null
if ($LASTEXITCODE -cne 0) { throw 'the fixture package did not install' }
if (@(Get-ChildItem "$root/.coop/runs" -File -ErrorAction SilentlyContinue).Count -cne 0) {
    throw 'a completed run left a record behind'
}

# A run that is killed leaves the record of what it was doing.
'{ "crash": ["after-extract"] }' | Set-Content "$root/.coop/test-faults.json" -Encoding utf8
$previousToken = $env:COOP_ALLOW_TEST_FAULTS
try {
    $env:COOP_ALLOW_TEST_FAULTS = '1'
    & $CoopExe --root $root update probe/slow -f 2>&1 | Out-Null
    if ($LASTEXITCODE -ceq 0) { throw 'the crash fault did not stop the command' }

    $records = @(Get-ChildItem "$root/.coop/runs" -File -ErrorAction SilentlyContinue)
    if ($records.Count -cne 1) { throw "expected one run record, found $($records.Count)" }
    $record = Get-Content $records[0].FullName -Raw | ConvertFrom-Json
    if ($record.command -cne 'update') { throw "the record names '$($record.command)'" }
    if (($record.packages -join ' ') -cne 'probe/slow') { throw "the record names '$($record.packages -join ' ')'" }
    if ([string]::IsNullOrWhiteSpace($record.stage)) { throw 'the record names no stage' }

    # A dry run reports it and leaves it in place.
    $dry = & $CoopExe --root $root recover --dry-run 2>&1
    if ($LASTEXITCODE -cne 0) { throw "recover --dry-run failed: $($dry -join ' | ')" }
    if (($dry -join "`n") -cnotmatch 'an interrupted run was recorded: coop update probe/slow') {
        throw "recover --dry-run did not name the run: $($dry -join ' | ')"
    }
    if (@(Get-ChildItem "$root/.coop/runs" -File -ErrorAction SilentlyContinue).Count -cne 1) {
        throw 'recover --dry-run consumed the record'
    }

    # A real recover reports it and consumes it.
    $recover = & $CoopExe --root $root recover 2>&1
    if (($recover -join "`n") -cnotmatch 'an interrupted run was recorded: coop update probe/slow') {
        throw "recover did not name the run: $($recover -join ' | ')"
    }
    if (@(Get-ChildItem "$root/.coop/runs" -File -ErrorAction SilentlyContinue).Count -cne 0) {
        throw 'recover did not consume the record'
    }
    $again = & $CoopExe --root $root recover 2>&1
    if (($again -join "`n") -cmatch 'interrupted run') { throw 'a consumed record was reported twice' }
} finally {
    if ($null -eq $previousToken) { Remove-Item Env:\COOP_ALLOW_TEST_FAULTS -ErrorAction SilentlyContinue }
    else { $env:COOP_ALLOW_TEST_FAULTS = $previousToken }
}
Write-Output 'PASS: a killed write command leaves a record that recover reports and consumes'

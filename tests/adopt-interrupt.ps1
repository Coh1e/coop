param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/test/bucket","$root/apps/fixture/1","$root/shims" -Force | Out-Null
$program = Join-Path (Split-Path $CoopExe) 'fixture-1.exe'
$shim = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-fixtures/scoop-shim-kiennq.exe'))
Copy-Item $program "$root/apps/fixture/1/fixture.exe"
# Hardlink from a per-root copy: many test runs leave roots behind for evidence, and NTFS
# limits one file to 1024 hardlinks, so the shared fixture must not accumulate links.
Copy-Item -LiteralPath $shim -Destination "$root/shim-source.exe"
$commands = [Collections.Generic.List[object]]::new()
for ($i=0;$i -lt 128;$i++) {
    $alias = "entry-$i"
    $commands.Add(@('fixture.exe',$alias))
    New-Item -ItemType HardLink -Path "$root/shims/$alias.exe" -Target "$root/shim-source.exe" | Out-Null
    [IO.File]::WriteAllText("$root/shims/$alias.shim",'path = "'+[IO.Path]::GetFullPath("$root/apps/fixture/1/fixture.exe")+'"'+"`r`n")
}
$manifest = @{version='1';url='http://127.0.0.1:1/fixture.exe';hash=(Get-FileHash $program).Hash.ToLower();bin=$commands.ToArray()}
$manifest | ConvertTo-Json -Depth 5 | Set-Content "$root/apps/fixture/1/scoop-manifest.json" -Encoding utf8
$manifest | ConvertTo-Json -Depth 5 | Set-Content "$root/buckets/test/bucket/fixture.json" -Encoding utf8
'{"bucket":"test","architecture":"64bit"}' | Set-Content "$root/apps/fixture/1/scoop-install.json" -Encoding utf8
New-Item -ItemType Junction -Path "$root/apps/fixture/current" -Target "$root/apps/fixture/1" | Out-Null
$facts = @(Get-ChildItem "$root/apps","$root/shims" -Recurse -File | ForEach-Object { @{path=$_.FullName;hash=(Get-FileHash $_.FullName).Hash} })
$start = [Diagnostics.ProcessStartInfo]::new($CoopExe)
$start.UseShellExecute = $false; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
foreach ($argument in @('--root',$root,'adopt','fixture','--json')) { $start.ArgumentList.Add($argument) }
$process = [Diagnostics.Process]::Start($start)
$output = $process.StandardOutput.ReadToEndAsync(); $errorOutput = $process.StandardError.ReadToEndAsync()
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    $journal = $null
    while ([DateTime]::UtcNow -lt $deadline -and -not $process.HasExited) {
        if (Test-Path "$root/.coop/transactions") {
            $journal = Get-ChildItem "$root/.coop/transactions" -Recurse -Filter journal.json | Select-Object -First 1
            if ($journal) { break }
        }
        Start-Sleep -Milliseconds 5
    }
    if (-not $journal -or $process.HasExited) { throw "Did not observe adoption before completion: $($errorOutput.GetAwaiter().GetResult())" }
    $process.Kill(); $process.WaitForExit()
    if ((Get-Content $journal.FullName -Raw | ConvertFrom-Json).state -ne 'pending') { throw 'Did not interrupt a pending adoption transaction' }
    foreach ($fact in $facts) { if ((Get-FileHash $fact.path).Hash -ne $fact.hash) { throw 'interrupted adoption changed original files' } }
    $journalHash = (Get-FileHash $journal.FullName).Hash
    $preview = & $CoopExe --root $root adopt fixture --dry-run --json
    if ($LASTEXITCODE -ne 0 -or (Get-FileHash $journal.FullName).Hash -ne $journalHash) { throw 'preview changed recovery state' }
    $retry = & $CoopExe --root $root adopt FIXTURE --json
    if ($LASTEXITCODE -ne 0) { throw 'retry did not safely recover pending adoption' }
    if ((Get-Content $journal.FullName -Raw | ConvertFrom-Json).state -notin @('rolled-back','committed')) { throw 'old adoption transaction unresolved' }
    foreach ($fact in $facts) { if ((Get-FileHash $fact.path).Hash -ne $fact.hash) { throw 'recovered adoption changed original files' } }
    $run = & "$root/shims/entry-0.exe"
    if ($LASTEXITCODE -ne 0 -or $run -ne 'fixture 1') { throw 'recovery broke original Scoop entry' }
    @{root=$root;interrupted_exit=$process.ExitCode;journal=$journal.FullName;retry_status=(($retry -join "`n") | ConvertFrom-Json).status;original_files_unchanged=$true} | ConvertTo-Json | Set-Content "$root/evidence.json" -Encoding utf8
    Write-Output "PASS actual adoption interruption and verified retry: $root/evidence.json"
} finally {
    if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
}

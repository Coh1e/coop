param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$session = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
$fixture1 = Join-Path (Split-Path $CoopExe) 'fixture-1.exe'
$fixture2 = Join-Path (Split-Path $CoopExe) 'fixture-2.exe'
$scoopShim = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-fixtures/scoop-shim-kiennq.exe'))
foreach ($path in @($fixture1,$fixture2,$scoopShim)) { if (-not (Test-Path -LiteralPath $path)) { throw "Missing fixed test input: $path" } }
if ((Get-FileHash -LiteralPath $scoopShim -Algorithm SHA256).Hash.ToLower() -ne '140e3801d8adeda639a21b14e62b93a4c7d26b7a758421f43c82be59753be49b') { throw 'unverified original Scoop test shim' }
function Manifest([string]$version,[string]$program) {
    @{version=$version;url=([Uri][IO.Path]::GetFullPath($program)).AbsoluteUri+'#/shared.exe';hash=(Get-FileHash -LiteralPath $program -Algorithm SHA256).Hash.ToLower();bin='shared.exe'} | ConvertTo-Json -Depth 5
}
function New-Root([string]$name,[string]$version,[string]$program) {
    $root = Join-Path $session $name
    New-Item -ItemType Directory -Path "$root/buckets/test/bucket","$root/apps/shared/$version","$root/shims" -Force | Out-Null
    [IO.File]::WriteAllText("$root/buckets/test/bucket/shared.json",(Manifest '2' $fixture2))
    Copy-Item -LiteralPath $program -Destination "$root/apps/shared/$version/shared.exe"
    [IO.File]::WriteAllText("$root/apps/shared/$version/manifest.json",(Manifest $version $program))
    [IO.File]::WriteAllText("$root/apps/shared/$version/install.json",'{"bucket":"test","architecture":"64bit"}')
    New-Item -ItemType Junction -Path "$root/apps/shared/current" -Target "$root/apps/shared/$version" | Out-Null
    Copy-Item -LiteralPath $scoopShim -Destination "$root/shims/shared.exe"
    [IO.File]::WriteAllText("$root/shims/shared.shim",'path = "'+[IO.Path]::GetFullPath("$root/apps/shared/$version/shared.exe")+'"'+"`r`n")
    return $root
}
# A real Scoop installation has no Coop private record. Update and uninstall must derive identity
# from apps/<name>/current, the standard install records, the real .shim and the actual program.
$rootA = New-Root 'scoop-owned' '1' $fixture1
$preview = & $CoopExe --root $rootA update shared --dry-run --json
if ($LASTEXITCODE -ne 0) { throw "shared preview failed: $preview" }
$previewEntry = $preview | ConvertFrom-Json
if (-not $previewEntry.execution_available) { throw "shared update was not executable: $preview" }
$planned = @($previewEntry.ir_operations | ForEach-Object operation)
if (@($planned | Where-Object { $_ -eq 'unlink-current' }).Count -ne 1 -or 'remove-entries' -notin $planned) { throw "shared update plan is incomplete: $planned" }
$updated = & $CoopExe --root $rootA update shared --json
if ($LASTEXITCODE -ne 0) { throw "shared update failed: $updated" }
$result = $updated | ConvertFrom-Json
$journal = Get-Content -LiteralPath $result.journal -Raw | ConvertFrom-Json
$observed = @($journal.observed_steps)
if (($observed -join ',') -ne ($planned -join ',')) { throw "execution did not follow the displayed plan: planned=$planned observed=$observed" }
if ((& "$rootA/shims/shared.exe") -ne 'fixture 2') { throw 'updated shared program did not run' }
if ((Get-Content -LiteralPath "$rootA/apps/shared/current/scoop-manifest.json" -Raw | ConvertFrom-Json).version -ne '2') { throw 'standard Scoop manifest was not published' }
if (-not (Test-Path -LiteralPath "$rootA/apps/shared/1/shared.exe")) { throw 'previous version was not retained' }
if (Test-Path -LiteralPath "$rootA/shims/shared.coop-shim.json") { throw 'direct EXE entry used non-Scoop metadata' }
$managed = Get-Content -LiteralPath "$rootA/.coop/packages/shared.json" -Raw | ConvertFrom-Json
if ($managed.origin -ne 'scoop' -or $managed.shim_format -ne 'scoop') { throw "shared record did not preserve Scoop origin: $managed" }
# Scoop reset replaces its shim and metadata. Coop must re-identify the shared state and continue.
Copy-Item -LiteralPath $scoopShim -Destination "$rootA/shims/shared.exe" -Force
[IO.File]::WriteAllText("$rootA/shims/shared.shim",'path = "'+[IO.Path]::GetFullPath("$rootA/apps/shared/2/shared.exe")+'"'+"`r`n")
if ((& "$rootA/shims/shared.exe") -ne 'fixture 2') { throw 'Scoop-style shim did not run' }
$removed = & $CoopExe --root $rootA uninstall shared --json
if ($LASTEXITCODE -ne 0) { throw "shared uninstall failed: $removed" }
if ((Test-Path "$rootA/apps/shared/current") -or (Test-Path "$rootA/shims/shared.exe") -or (Test-Path "$rootA/shims/shared.shim") -or (Test-Path "$rootA/.coop/packages/shared.json")) { throw 'shared uninstall left published state' }
# Reverse direction: Coop creates a standard single-file installation, Scoop resets the entry, and
# Coop continues to manage it without re-adoption or a private-record precondition.
$rootB = Join-Path $session 'coop-owned'
New-Item -ItemType Directory -Path "$rootB/buckets/test/bucket" -Force | Out-Null
[IO.File]::WriteAllText("$rootB/buckets/test/bucket/shared.json",(Manifest '2' $fixture2))
$installed = & $CoopExe --root $rootB install test/shared --json
if ($LASTEXITCODE -ne 0) { throw "Coop shared install failed: $installed" }
if ((& "$rootB/shims/shared.exe") -ne 'fixture 2') { throw 'Coop-installed shared program did not run' }
Copy-Item -LiteralPath $scoopShim -Destination "$rootB/shims/shared.exe" -Force
[IO.File]::WriteAllText("$rootB/shims/shared.shim",'path = "'+[IO.Path]::GetFullPath("$rootB/apps/shared/current/shared.exe")+'"'+"`r`n")
$list = & $CoopExe --root $rootB list --json | ConvertFrom-Json
if (@($list | Where-Object name -eq 'shared').Count -ne 1) { throw 'Coop did not re-identify the Scoop-reset installation' }
$removed = & $CoopExe --root $rootB uninstall shared --json
if ($LASTEXITCODE -ne 0) { throw "Coop uninstall after Scoop reset failed: $removed" }
if ((Test-Path "$rootB/apps/shared/current") -or (Test-Path "$rootB/shims/shared.exe") -or (Test-Path "$rootB/shims/shared.shim")) { throw 'Coop uninstall after Scoop reset left published state' }
@{root_scoop=$rootA;root_coop=$rootB;planned=$planned;observed=$observed;fixture_sha256=(Get-FileHash -LiteralPath $fixture2 -Algorithm SHA256).Hash.ToLower();timestamp=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$session/evidence.json" -Encoding utf8
Write-Output "PASS shared Scoop/Coop single-file update, reset and uninstall: $session/evidence.json"

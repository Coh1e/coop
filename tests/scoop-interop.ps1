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
$recordB = Get-Content -LiteralPath "$rootB/.coop/packages/shared.json" -Raw | ConvertFrom-Json
if ($recordB.origin -ne 'coop' -or $recordB.shim_format -ne 'scoop') { throw "Coop-created record did not report its own origin: $recordB" }
Copy-Item -LiteralPath $scoopShim -Destination "$rootB/shims/shared.exe" -Force
[IO.File]::WriteAllText("$rootB/shims/shared.shim",'path = "'+[IO.Path]::GetFullPath("$rootB/apps/shared/current/shared.exe")+'"'+"`r`n")
$list = & $CoopExe --root $rootB list --json | ConvertFrom-Json
if (@($list | Where-Object name -eq 'shared').Count -ne 1) { throw 'Coop did not re-identify the Scoop-reset installation' }
$removed = & $CoopExe --root $rootB uninstall shared --json
if ($LASTEXITCODE -ne 0) { throw "Coop uninstall after Scoop reset failed: $removed" }
if ((Test-Path "$rootB/apps/shared/current") -or (Test-Path "$rootB/shims/shared.exe") -or (Test-Path "$rootB/shims/shared.shim")) { throw 'Coop uninstall after Scoop reset left published state' }
# A Scoop GUI shim is the same shim program with a different PE subsystem, so launcher identity
# must come from the shim's program markers rather than a fixed digest allowlist.
$fixtureGui = Join-Path (Split-Path $CoopExe) 'fixture-gui.exe'
if (-not (Test-Path -LiteralPath $fixtureGui)) { throw "Missing fixed test input: $fixtureGui" }
$guiShim = Join-Path $session 'gui-shim.exe'
$shimBytes = [IO.File]::ReadAllBytes($scoopShim)
$peOffset = [BitConverter]::ToInt32($shimBytes,0x3c)
$subsystemOffset = $peOffset + 24 + 68
$shimBytes[$subsystemOffset] = 2
[IO.File]::WriteAllBytes($guiShim,$shimBytes)
function New-GuiRoot([string]$name,[string]$launcher) {
    $root = Join-Path $session $name
    New-Item -ItemType Directory -Path "$root/buckets/test/bucket","$root/apps/gui/1","$root/shims" -Force | Out-Null
    $manifest1 = @{version='1';url=([Uri][IO.Path]::GetFullPath($fixtureGui)).AbsoluteUri+'#/gui.exe';hash=(Get-FileHash -LiteralPath $fixtureGui -Algorithm SHA256).Hash.ToLower();bin='gui.exe'} | ConvertTo-Json -Depth 5
    $manifest2 = @{version='2';url=([Uri][IO.Path]::GetFullPath($fixtureGui)).AbsoluteUri+'#/gui.exe';hash=(Get-FileHash -LiteralPath $fixtureGui -Algorithm SHA256).Hash.ToLower();bin='gui.exe'} | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText("$root/buckets/test/bucket/gui.json",$manifest2)
    Copy-Item -LiteralPath $fixtureGui -Destination "$root/apps/gui/1/gui.exe"
    [IO.File]::WriteAllText("$root/apps/gui/1/manifest.json",$manifest1)
    [IO.File]::WriteAllText("$root/apps/gui/1/install.json",'{"bucket":"test","architecture":"64bit"}')
    New-Item -ItemType Junction -Path "$root/apps/gui/current" -Target "$root/apps/gui/1" | Out-Null
    Copy-Item -LiteralPath $launcher -Destination "$root/shims/gui.exe"
    [IO.File]::WriteAllText("$root/shims/gui.shim",'path = "'+[IO.Path]::GetFullPath("$root/apps/gui/1/gui.exe")+'"'+"`r`n")
    return $root
}
$guiRoot = New-GuiRoot 'gui-scoop-shim' $guiShim
$guiPreview = & $CoopExe --root $guiRoot update gui --dry-run --json
if ($LASTEXITCODE -ne 0) { throw "GUI-shim preview failed: $guiPreview" }
$guiPreviewEntry = $guiPreview | ConvertFrom-Json
if (-not $guiPreviewEntry.execution_available) { throw "GUI-shim update preview was not executable: $guiPreview" }
$guiUpdate = & $CoopExe --root $guiRoot update gui --json
if ($LASTEXITCODE -ne 0) { throw "GUI-shim update failed: $guiUpdate" }
if ((Get-Content -LiteralPath "$guiRoot/apps/gui/current/scoop-manifest.json" -Raw | ConvertFrom-Json).version -ne '2') { throw 'GUI-shim update did not publish version 2' }
$foreignRoot = New-GuiRoot 'foreign-launcher' $fixture1
$foreignPreview = & $CoopExe --root $foreignRoot update gui --dry-run --json
if ($LASTEXITCODE -ne 0) { throw "foreign-launcher preview failed: $foreignPreview" }
$foreignEntry = $foreignPreview | ConvertFrom-Json
if ($foreignEntry.execution_available -ne $false -or @($foreignEntry.diagnostics | Where-Object code -eq 'execution-blocked').Count -ne 1) { throw "foreign launcher was not blocked in preview: $foreignPreview" }
$foreignUpdate = & $CoopExe --root $foreignRoot update gui --json 2>&1
if ($LASTEXITCODE -eq 0 -or (Test-Path "$foreignRoot/.coop/packages/gui.json")) { throw "foreign launcher was accepted: $foreignUpdate" }
@{root_scoop=$rootA;root_coop=$rootB;root_gui=$guiRoot;root_foreign=$foreignRoot;planned=$planned;observed=$observed;fixture_sha256=(Get-FileHash -LiteralPath $fixture2 -Algorithm SHA256).Hash.ToLower();timestamp=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$session/evidence.json" -Encoding utf8
Write-Output "PASS shared Scoop/Coop single-file update, reset, GUI shim and foreign-launcher refusal: $session/evidence.json"

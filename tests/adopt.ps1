param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/test/bucket","$root/apps/Fixture/1","$root/shims" -Force | Out-Null
$fixture1 = Join-Path (Split-Path $CoopExe) 'fixture-1.exe'
$fixture2 = Join-Path (Split-Path $CoopExe) 'fixture-2.exe'
Copy-Item $fixture1 "$root/apps/Fixture/1/fixture.exe"
@{version='1';url='http://127.0.0.1:1/unreachable.exe#/fixture.exe';hash=(Get-FileHash $fixture1).Hash.ToLower();bin='fixture.exe'} | ConvertTo-Json | Set-Content "$root/apps/Fixture/1/scoop-manifest.json" -Encoding utf8
'{"bucket":"test","architecture":"64bit"}' | Set-Content "$root/apps/Fixture/1/scoop-install.json" -Encoding utf8
New-Item -ItemType Junction -Path "$root/apps/Fixture/current" -Target "$root/apps/Fixture/1" | Out-Null
$scoopShim = Join-Path $PSScriptRoot '../.local/deps/test-fixtures/scoop-shim-kiennq.exe'
if ((Get-FileHash $scoopShim).Hash.ToLower() -ne '140e3801d8adeda639a21b14e62b93a4c7d26b7a758421f43c82be59753be49b') { throw 'unverified original Scoop test shim' }
Copy-Item $scoopShim "$root/shims/fixture.exe"
[IO.File]::WriteAllText("$root/shims/fixture.shim",'path = "'+[IO.Path]::GetFullPath("$root/apps/Fixture/1/fixture.exe")+'"'+"`r`n")
@{version='2';url=([Uri][IO.Path]::GetFullPath($fixture2)).AbsoluteUri+'#/fixture.exe';hash=(Get-FileHash $fixture2).Hash.ToLower();bin='fixture.exe'} | ConvertTo-Json | Set-Content "$root/buckets/test/bucket/fixture.json" -Encoding utf8
if ((& "$root/shims/fixture.exe") -ne 'fixture 1') { throw 'original Scoop entry did not run real program' }
foreach ($name in @('scripted','unknown','corrupt','future')) {
    New-Item -ItemType Directory -Path "$root/apps/$name/1" -Force | Out-Null
    Copy-Item $fixture1 "$root/apps/$name/1/$name.exe"
    $manifest = @{version='1';url="http://127.0.0.1:1/unreachable.exe#/$name.exe";hash=(Get-FileHash $fixture1).Hash.ToLower();bin="$name.exe"}
    if ($name -eq 'scripted') { $manifest.pre_install = 'throw "preview must not execute this"' }
    if ($name -eq 'corrupt') { $manifest.hash = '0'*64 }
    $manifest | ConvertTo-Json | Set-Content "$root/apps/$name/1/scoop-manifest.json" -Encoding utf8
    '{"bucket":"test","architecture":"64bit"}' | Set-Content "$root/apps/$name/1/scoop-install.json" -Encoding utf8
    New-Item -ItemType Junction -Path "$root/apps/$name/current" -Target "$root/apps/$name/1" | Out-Null
    Copy-Item $(if ($name -eq 'unknown') { $fixture1 } else { $scoopShim }) "$root/shims/$name.exe"
    [IO.File]::WriteAllText("$root/shims/$name.shim",'path = "'+[IO.Path]::GetFullPath("$root/apps/$name/1/$name.exe")+'"'+"`r`n")
    if ($name -eq 'future') { $manifest.version = '2'; $manifest.url = 'https://invalid.example/program.zip'; $manifest.hash = '0'*64; $manifest.innosetup = $true }
    $manifest | ConvertTo-Json | Set-Content "$root/buckets/test/bucket/$name.json" -Encoding utf8
}
$globalRoot = "$root/system-read-only"
New-Item -ItemType Directory -Path "$globalRoot/apps/system-only/current" -Force | Out-Null
Copy-Item "$root/apps/fixture/1/scoop-manifest.json" "$globalRoot/apps/system-only/current/scoop-manifest.json"
Copy-Item "$root/apps/fixture/1/scoop-install.json" "$globalRoot/apps/system-only/current/scoop-install.json"
$mixed = & $CoopExe --root $root --global-root $globalRoot adopt --dry-run --json | ConvertFrom-Json
$expected = @{fixture='eligible';scripted='untested';unknown='untested';corrupt='inconsistent';future='unsupported';'system-only'='unsupported'}
foreach ($item in $mixed) { if ($expected[$item.package.name] -ne $item.eligibility) { throw "wrong mixed adoption status for $($item.package.name): $($item.eligibility)" } }
if ($mixed.Count -ne 6 -or (Test-Path "$root/.coop") -or (Test-Path "$globalRoot/.coop")) { throw 'mixed preview omitted entries or wrote state' }
$rejected = & $CoopExe --root $root adopt scripted --json 2>&1
if ($LASTEXITCODE -eq 0 -or (Test-Path "$root/.coop")) { throw 'unsupported adoption wrote state' }
$rejected = & $CoopExe --root $globalRoot --global-root $globalRoot adopt system-only --json 2>&1
if ($LASTEXITCODE -eq 0 -or (Test-Path "$globalRoot/.coop")) { throw 'global adoption wrote state' }
$before = @(Get-ChildItem $root -Recurse -File | ForEach-Object { $_.FullName+':'+(Get-FileHash $_.FullName).Hash })
$preview = & $CoopExe --root $root adopt fixture --dry-run --json
if ($LASTEXITCODE -ne 0 -or ($preview | ConvertFrom-Json).eligibility -ne 'eligible') { throw 'Scoop adoption preview not eligible' }
if (Test-Path "$root/.coop") { throw 'adoption preview wrote state' }
$guard = Join-Path (Split-Path $CoopExe) 'process_guard.exe'
$adopt = & $guard $CoopExe --root $root adopt fixture --json
if ($LASTEXITCODE -ne 0) { throw 'in-place adoption failed' }
$adoption = ($adopt -join "`n") | ConvertFrom-Json
$backup = Get-Content "$($adoption.backup)/evidence.json" -Raw | ConvertFrom-Json
if ($backup.scope -notlike '*metadata and command entries only*' -or @($backup.inputs | Where-Object backed_up).Count -lt 4) { throw 'backup scope omitted original installation evidence or entries' }
foreach ($input in $backup.inputs | Where-Object backed_up) {
    if ((Get-FileHash "$($adoption.backup)/$($input.backup_file)").Hash.ToLower() -ne $input.sha256 -or (Get-FileHash $input.path).Hash.ToLower() -ne $input.sha256) { throw 'backup does not match unchanged original evidence' }
}
foreach ($fact in $before) {
    $split = $fact.LastIndexOf(':'); $path = $fact.Substring(0,$split); $hash = $fact.Substring($split+1)
    if (-not (Test-Path $path) -or (Get-FileHash $path).Hash -ne $hash) { throw 'adoption altered original program, Scoop record or entry' }
}
if ((& "$root/shims/fixture.exe") -ne 'fixture 1') { throw 'adoption broke existing entry' }
$repeat = & $CoopExe --root $root adopt fixture --json
if ($LASTEXITCODE -ne 0 -or ($repeat | ConvertFrom-Json).status -ne 'already-managed') { throw 'repeated adoption not idempotent' }
$dependentPath = "$root/apps/unknown/1/scoop-manifest.json"
$dependent = Get-Content $dependentPath -Raw | ConvertFrom-Json
$dependent | Add-Member -NotePropertyName depends -NotePropertyValue 'test/fixture'
$dependent | ConvertTo-Json | Set-Content $dependentPath -Encoding utf8
$dependentHash = (Get-FileHash $dependentPath).Hash
$rejected = & $CoopExe --root $root uninstall fixture --json 2>&1
if ($LASTEXITCODE -eq 0 -or (Get-FileHash $dependentPath).Hash -ne $dependentHash -or (& "$root/shims/fixture.exe") -ne 'fixture 1') { throw 'unadopted dependent was not protected' }
# The fixture author removes this dependency to allow the separate uninstall scenario.
$dependent.PSObject.Properties.Remove('depends')
$dependent | ConvertTo-Json | Set-Content $dependentPath -Encoding utf8
$lock = [IO.File]::Open("$root/shims/fixture.exe",[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try {
    $failed = & $CoopExe --root $root update fixture --json 2>&1
    if ($LASTEXITCODE -eq 0) { throw 'occupied original Scoop entry unexpectedly replaced' }
} finally { $lock.Dispose() }
$items = & $CoopExe --root $root list --json | ConvertFrom-Json
$managed = $items | Where-Object name -eq 'Fixture'
if ($managed.management -ne 'managed' -or $managed.last_operation -ne 'failed' -or $managed.status -ne 'ready' -or (& "$root/shims/fixture.exe") -ne 'fixture 1') { throw 'operation failure confused management ownership or lost original entry' }
$updated = & $CoopExe --root $root update fixture --json
if ($LASTEXITCODE -ne 0 -or (& "$root/shims/fixture.exe") -ne 'fixture 2' -or -not (Test-Path "$root/apps/Fixture/1/scoop-manifest.json")) { throw 'adopted package could not update while preserving original records' }
$caseVariant = & $CoopExe --root $root update Fixture --json
if ($LASTEXITCODE -ne 0 -or (($caseVariant -join "`n") | ConvertFrom-Json).status -ne 'up-to-date' -or (& "$root/shims/fixture.exe") -ne 'fixture 2') { throw 'case-variant identity broke adopted update' }
$items = & $CoopExe --root $root list --json | ConvertFrom-Json
$managed = $items | Where-Object name -eq 'Fixture'
if ($managed.management -ne 'managed' -or $managed.last_operation -ne 'succeeded' -or $managed.version -ne '2') { throw 'case-variant update lost management identity' }
$removed = & $CoopExe --root $root uninstall Fixture --json
if ($LASTEXITCODE -ne 0 -or (Test-Path "$root/shims/fixture.exe")) { throw 'adopted package could not uninstall with a case-variant name' }
Write-Output "PASS original Scoop native entry, in-place adoption, update and uninstall: $root"
exit 0

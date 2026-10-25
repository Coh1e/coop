param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null
$source = [IO.Path]::GetFullPath($CoopExe)
$manifest = @{version='0.1.0';url=([Uri]$source).AbsoluteUri+'#/fixture.exe';hash=(Get-FileHash $source -Algorithm SHA256).Hash.ToLower();bin='fixture.exe'} | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText("$root/buckets/test/bucket/fixture.json",$manifest)
$text = & $CoopExe --root $root install test/fixture --json
if ($LASTEXITCODE -ne 0) { throw 'single EXE install failed' }
if (-not (Test-Path "$root/apps/fixture/current/fixture.exe") -or -not (Test-Path "$root/shims/fixture.exe")) { throw 'installation not published' }
$version = & "$root/shims/fixture.exe" --version
if ($LASTEXITCODE -ne 0 -or $version -ne 'coop 0.1.0') { throw 'native command entry failed' }
$items = & $CoopExe --root $root list --json | ConvertFrom-Json
if ($items[0].management -ne 'managed') { throw 'installed package not managed' }
$metadataPath = "$root/shims/fixture.coop-shim.json"
$metadata = [IO.File]::ReadAllText($metadataPath)
$changed = $metadata | ConvertFrom-Json
$changed.package = 'someone-else'
$changed | ConvertTo-Json | Set-Content $metadataPath -Encoding utf8
$failed = & $CoopExe --root $root uninstall fixture --json 2>&1
if ($LASTEXITCODE -eq 0 -or -not (Test-Path "$root/apps/fixture/current/fixture.exe")) { throw 'changed command ownership ignored' }
[IO.File]::WriteAllText($metadataPath,$metadata)
$lock = [IO.File]::Open("$root/shims/fixture.exe",[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try {
    $failed = & $CoopExe --root $root uninstall fixture --json 2>&1
    if ($LASTEXITCODE -eq 0) { throw 'locked command entry unexpectedly removed' }
    if (-not (Test-Path "$root/apps/fixture/current/fixture.exe") -or -not (Test-Path "$root/.coop/packages/fixture.json")) { throw 'uninstall rollback lost current or management' }
} finally { $lock.Dispose() }
$text = & $CoopExe --root $root uninstall fixture --json
if ($LASTEXITCODE -ne 0) { throw 'uninstall failed' }
if ((Test-Path "$root/apps/fixture/current") -or (Test-Path "$root/shims/fixture.exe")) { throw 'uninstall left published files' }
$bad = $manifest | ConvertFrom-Json
$bad.hash = '0'*64
$bad | ConvertTo-Json -Depth 5 | Set-Content "$root/buckets/test/bucket/fixture.json" -Encoding utf8
$failed = & $CoopExe --root $root install test/fixture --json 2>&1
if ($LASTEXITCODE -eq 0 -or (Test-Path "$root/apps/fixture/current") -or (Test-Path "$root/.coop/packages/fixture.json")) { throw 'bad hash published a successful install' }
[IO.File]::WriteAllText("$root/buckets/test/bucket/fixture.json",$manifest)
'another package' | Set-Content "$root/shims/fixture.exe" -Encoding utf8
$failed = & $CoopExe --root $root install test/fixture --json 2>&1
if ($LASTEXITCODE -eq 0 -or (Get-Content "$root/shims/fixture.exe") -ne 'another package') { throw 'command conflict overwritten' }
$journals = @(Get-ChildItem "$root/.coop/transactions" -Recurse -Filter journal.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
if ('pending' -in $journals.state -or 'rolled-back' -notin $journals.state -or 'committed' -notin $journals.state) { throw 'journal state inaccurate' }
Write-Output "PASS native single EXE install/entry/uninstall: $root"

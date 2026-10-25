param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$fixture1 = Join-Path (Split-Path $CoopExe) 'fixture-1.exe'
$fixture2 = Join-Path (Split-Path $CoopExe) 'fixture-2.exe'
foreach ($path in @(
    (Join-Path $archives 'ripgrep-14.1.1-x86_64-pc-windows-msvc.zip'),
    (Join-Path $archives 'ripgrep-15.2.0-x86_64-pc-windows-msvc.zip'),
    (Join-Path $archives 'air_1.67.3_windows_amd64.tar.gz'),
    (Join-Path $archives 'air_1.67.4_windows_amd64.tar.gz'),
    (Join-Path $archives 'air_1.67.4_windows_386.tar.gz'),
    $fixture1, $fixture2
)) { if (-not (Test-Path -LiteralPath $path)) { throw "Missing fixed test input: $path; run scripts/fetch-deps.ps1" } }

function New-TestRoot {
    $root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null
    return $root
}
function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
function Write-Manifest([string]$root,[string]$name,[object]$manifest) {
    $json = $manifest | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText("$root/buckets/test/bucket/$name.json",$json,[Text.UTF8Encoding]::new($false))
}
function Assert-Exit([string]$message) { if ($LASTEXITCODE -ne 0) { throw $message } }
function Invoke-CoopRetry([string]$label,[string[]]$arguments) {
    $output = $null
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        $output = & $CoopExe @arguments 2>&1
        if ($LASTEXITCODE -eq 0) { return $output }
        Start-Sleep -Milliseconds 500
    }
    throw "$label failed after retries: $($output -join "`n")"
}
function First-Version([string]$output) { return ($output | Where-Object { $_ -match '\S' } | Select-Object -First 1) }

# ZIP lifecycle: real Main/ripgrep archives, preview, preparation failure, update and uninstall.
$root = New-TestRoot
$rg14 = Join-Path $archives 'ripgrep-14.1.1-x86_64-pc-windows-msvc.zip'
$rg15 = Join-Path $archives 'ripgrep-15.2.0-x86_64-pc-windows-msvc.zip'
function Write-Ripgrep([string]$version) {
    if ($version -eq '14.1.1') {
        $file = $rg14; $hash = 'd0f534024c42afd6cb4d38907c25cd2b249b79bbe6cc1dbee8e3e37c2b6e25a1'; $dir = 'ripgrep-14.1.1-x86_64-pc-windows-msvc'
    } else {
        $file = $rg15; $hash = '71b2fef860abe467217a538ff31de02f5258807c0129f771846f87bd029aafc5'; $dir = 'ripgrep-15.2.0-x86_64-pc-windows-msvc'
    }
    Write-Manifest $root 'ripgrep' @{version=$version;architecture=@{'64bit'=@{url=(File-Uri $file);hash=$hash;extract_dir=$dir}};bin='rg.exe'}
}
Write-Ripgrep '14.1.1'
$rgReal = Get-Content (Join-Path $PSScriptRoot 'corpus/main/ripgrep.json') -Raw | ConvertFrom-Json
Write-Manifest $root 'ripgrep' $rgReal
foreach ($architecture in @('64bit','32bit','arm64')) {
    $plan = & $CoopExe --root $root install test/ripgrep --dry-run --arch $architecture --json | ConvertFrom-Json
    Assert-Exit "ZIP preview failed for $architecture"
    if (-not $plan.execution_available -or $plan.artifacts[0].archive -ne 'zip' -or $plan.package.architecture -ne $architecture -or
        $plan.artifacts[0].sha256 -ne $rgReal.architecture.$architecture.hash) { throw "ZIP preview did not cover $architecture" }
}
Write-Ripgrep '14.1.1'
$plan = & $CoopExe --root $root install test/ripgrep --dry-run --json | ConvertFrom-Json
Assert-Exit 'ZIP preview failed'
if (-not $plan.execution_available -or $plan.artifacts[0].archive -ne 'zip' -or 'extract' -notin @($plan.operations.kind)) { throw 'ZIP preview did not expose native extraction' }
if ((Test-Path "$root/apps") -or (Test-Path "$root/shims") -or (Test-Path "$root/.coop/transactions")) { throw 'ZIP preview changed installation state' }
$install = & $CoopExe --root $root install test/ripgrep --json
Assert-Exit 'ZIP install failed'
$version = First-Version (& "$root/shims/rg.exe" --version)
if ($version -notlike 'ripgrep 14.1.1*') { throw "ZIP entry ran wrong version: $version" }
$record = [IO.File]::ReadAllText("$root/.coop/packages/ripgrep.json") | ConvertFrom-Json
if ($record.version -ne '14.1.1' -or $record.command_targets.Count -ne 1 -or $record.command_targets[0].path -ne 'rg.exe') { throw 'ZIP management record is incomplete' }
if (-not (Test-Path "$root/apps/ripgrep/current/rg.exe")) { throw 'ZIP current layout was not published' }
Write-Ripgrep '15.2.0'
$bad = Get-Content "$root/buckets/test/bucket/ripgrep.json" -Raw | ConvertFrom-Json
$bad.architecture.'64bit'.hash = '0'*64
$bad | ConvertTo-Json -Depth 8 | Set-Content "$root/buckets/test/bucket/ripgrep.json" -Encoding utf8
$failed = & $CoopExe --root $root update ripgrep --json 2>&1
if ($LASTEXITCODE -eq 0) { throw 'ZIP hash mismatch update unexpectedly succeeded' }
$version = First-Version (& "$root/shims/rg.exe" --version)
if ($version -notlike 'ripgrep 14.1.1*' -or (Test-Path "$root/apps/ripgrep/15.2.0")) { throw 'ZIP preparation failure damaged the current version' }
Write-Ripgrep '15.2.0'
$update = & $CoopExe --root $root update ripgrep --json
Assert-Exit 'ZIP update failed'
$version = First-Version (& "$root/shims/rg.exe" --version)
if ($version -notlike 'ripgrep 15.2.0*') { throw "ZIP update entry ran wrong version: $version" }
$oldVersion = First-Version (& "$root/apps/ripgrep/14.1.1/rg.exe" --version)
if ($oldVersion -notlike 'ripgrep 14.1.1*') { throw 'ZIP update did not retain the old release' }
$items = & $CoopExe --root $root list --json | ConvertFrom-Json
if ($items[0].version -ne '15.2.0' -or $items[0].management -ne 'managed') { throw 'ZIP updated query is wrong' }
$uninstall = & $CoopExe --root $root uninstall ripgrep --json
Assert-Exit 'ZIP uninstall failed'
if ((Test-Path "$root/apps/ripgrep/current") -or (Test-Path "$root/apps/ripgrep/15.2.0") -or (Test-Path "$root/shims/rg.exe") -or (Test-Path "$root/.coop/packages/ripgrep.json")) { throw 'ZIP uninstall left published state' }

# tar.gz lifecycle: real Main/air archives, architecture selection, update and uninstall.
$root = New-TestRoot
$air3 = Join-Path $archives 'air_1.67.3_windows_amd64.tar.gz'
$air4 = Join-Path $archives 'air_1.67.4_windows_amd64.tar.gz'
$air32 = Join-Path $archives 'air_1.67.4_windows_386.tar.gz'
function Write-Air([string]$version,[bool]$local) {
    if ($version -eq '1.67.3') {
        Write-Manifest $root 'air' @{version=$version;architecture=@{'64bit'=@{url=(File-Uri $air3);hash='150ab78cf4a48f46ca845660b41a913b0bae94572c061ea5dbe75cd745849a5a'}};bin='air.exe'}
        return
    }
    $manifest = Get-Content (Join-Path $PSScriptRoot '../tests/corpus/main/air.json') -Raw | ConvertFrom-Json
    if ($local) {
        $manifest.architecture.'64bit'.url = File-Uri $air4
        $manifest.architecture.'32bit'.url = File-Uri $air32
    }
    Write-Manifest $root 'air' $manifest
}
Write-Air '1.67.4' $true
foreach ($architecture in @('64bit','32bit','arm64')) {
    $plan = & $CoopExe --root $root install test/air --dry-run --arch $architecture --json | ConvertFrom-Json
    Assert-Exit "tar preview failed for $architecture"
    if (-not $plan.execution_available -or $plan.artifacts[0].archive -ne 'tar' -or $plan.package.architecture -ne $architecture) { throw "tar preview did not cover $architecture" }
}
Write-Air '1.67.3' $false
$install = & $CoopExe --root $root install test/air --json
Assert-Exit 'tar.gz install failed'
$airOutput = (& "$root/shims/air.exe" -v) -join "`n"
if ($LASTEXITCODE -ne 0 -or $airOutput -notmatch '1\.67\.3,') { throw 'tar.gz entry ran wrong version' }
Write-Air '1.67.4' $true
$update = Invoke-CoopRetry 'tar.gz update' @('--root',$root,'update','air','--json')
$airOutput = (& "$root/shims/air.exe" -v) -join "`n"
if ($LASTEXITCODE -ne 0 -or $airOutput -notmatch '1\.67\.4,') { throw 'tar.gz update entry ran wrong version' }
$oldAir = (& "$root/apps/air/1.67.3/air.exe" -v) -join "`n"
if ($LASTEXITCODE -ne 0 -or $oldAir -notmatch '1\.67\.3,') { throw 'tar.gz update did not retain the old release' }
$uninstall = Invoke-CoopRetry 'tar.gz uninstall' @('--root',$root,'uninstall','air','--json')
Assert-Exit 'tar.gz uninstall failed'
if ((Test-Path "$root/apps/air/current") -or (Test-Path "$root/shims/air.exe") -or (Test-Path "$root/.coop/packages/air.json")) { throw 'tar.gz uninstall left published state' }

$root32 = New-TestRoot
Write-Manifest $root32 'air' @{version='1.67.4';architecture=@{'32bit'=@{url=(File-Uri $air32);hash='91df7ef7f35da4a23129e172675137e1b8cd6835392736d817bb443c0dc424c8'}};bin='air.exe'}
$install32 = & $CoopExe --root $root32 install test/air --arch 32bit --json
Assert-Exit '32bit tar.gz install failed'
$air32Output = (& "$root32/shims/air.exe" -v) -join "`n"
if ($LASTEXITCODE -ne 0 -or $air32Output -notmatch '1\.67\.4,') { throw '32bit tar.gz entry ran wrong version' }
$uninstall32 = Invoke-CoopRetry '32bit tar.gz uninstall' @('--root',$root32,'uninstall','air','--json')
Assert-Exit '32bit tar.gz uninstall failed'

# Unicode ZIP entry and multi-artifact extract_to scheduling.
$root = New-TestRoot
$fixtures = Join-Path $root 'fixtures'
New-Item -ItemType Directory -Path $fixtures -Force | Out-Null
$unicodeZip = Join-Path $fixtures 'unicode.zip'
$stream = [IO.File]::Create($unicodeZip)
$zip = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
$entry = $zip.CreateEntry('工具/程序.exe')
$entryStream = $entry.Open()
$bytes = [IO.File]::ReadAllBytes($fixture1)
$entryStream.Write($bytes,0,$bytes.Length)
$entryStream.Dispose(); $zip.Dispose(); $stream.Dispose()
Write-Manifest $root 'unicode' @{version='1';url=(File-Uri $unicodeZip);hash=(Get-FileHash $unicodeZip -Algorithm SHA256).Hash.ToLower();bin=@(,@('工具/程序.exe','unicode'))}
$unicodeInstall = & $CoopExe --root $root install test/unicode --json
Assert-Exit 'Unicode ZIP install failed'
$unicodeOutput = (& "$root/shims/unicode.exe") -join "`n"
if ($LASTEXITCODE -ne 0 -or $unicodeOutput -notmatch 'fixture 1') { throw 'Unicode ZIP entry failed to run' }
if (-not (Test-Path "$root/apps/unicode/current/工具/程序.exe")) { throw 'Unicode extraction layout is wrong' }
$unicodeUninstall = & $CoopExe --root $root uninstall unicode --json
Assert-Exit 'Unicode ZIP uninstall failed'

$root = New-TestRoot
$fixtures = Join-Path $root 'fixtures'
New-Item -ItemType Directory -Path $fixtures -Force | Out-Null
function Write-Assets([string]$version,[string]$text,[string]$fixture) {
    $archive = Join-Path $fixtures "assets-$version.zip"
    $stream = [IO.File]::Create($archive)
    $zip = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
    $entry = $zip.CreateEntry('data/config.txt')
    $writer = [IO.StreamWriter]::new($entry.Open(),[Text.UTF8Encoding]::new($false))
    $writer.Write($text); $writer.Dispose(); $zip.Dispose(); $stream.Dispose()
    Write-Manifest $root 'multi' @{version=$version;url=@((File-Uri $archive),((File-Uri $fixture)+'#/fixture.exe'));hash=@((Get-FileHash $archive -Algorithm SHA256).Hash.ToLower(),(Get-FileHash $fixture -Algorithm SHA256).Hash.ToLower());extract_to='themes';bin='fixture.exe'}
}
Write-Assets '1' 'one' $fixture1
$multiInstall = & $CoopExe --root $root install test/multi --json
Assert-Exit 'multi-artifact install failed'
if ((Get-Content "$root/apps/multi/current/themes/data/config.txt" -Raw).Trim() -ne 'one') { throw 'extract_to layout is wrong' }
if (((& "$root/shims/fixture.exe") -join "`n") -notmatch 'fixture 1') { throw 'multi-artifact direct entry failed' }
Write-Assets '2' 'two' $fixture2
$multiUpdate = & $CoopExe --root $root update multi --json
Assert-Exit 'multi-artifact update failed'
if ((Get-Content "$root/apps/multi/current/themes/data/config.txt" -Raw).Trim() -ne 'two') { throw 'extract_to layout was not updated' }
if (((& "$root/shims/fixture.exe") -join "`n") -notmatch 'fixture 2') { throw 'multi-artifact updated entry failed' }
$multiUninstall = & $CoopExe --root $root uninstall multi --json
Assert-Exit 'multi-artifact uninstall failed'

@{zip_root=$root;coop=$CoopExe;archives=$archives} | ConvertTo-Json | Set-Content (Join-Path $TestRoot 'archive-lifecycle-evidence.json') -Encoding utf8
Write-Output "PASS real ZIP/tar.gz lifecycle, architecture, Unicode and multi-artifact extraction: $TestRoot"
exit 0

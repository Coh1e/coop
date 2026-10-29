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
    (Join-Path $archives 'tidy-5.8.0-win64.zip'),
    (Join-Path $archives 'luajit-2.1.1791988261-1-any.pkg.tar.zst'),
    (Join-Path $archives 'curl-8.23.0_5-win64-mingw.tar.xz'),
    (Join-Path $archives 'unz600xn.exe'),
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
if (-not $plan.execution_available -or $plan.artifacts[0].archive -ne 'zip' -or 'extract' -notin @($plan.ir_operations | ForEach-Object { $_.operation })) { throw 'ZIP preview did not expose native extraction' }
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

# Nested ZIP layout: the real Main/tidy zip keeps its files below <version>\win64\bin.
$root = New-TestRoot
$tidy = Join-Path $archives 'tidy-5.8.0-win64.zip'
Write-Manifest $root 'tidy' @{version='5.8.0';architecture=@{'64bit'=@{url=(File-Uri $tidy);hash='ffb2f86484c66e70e6a6da369cb8f0f459ad2ffec7c7ca80d09a13445ee51a40';extract_dir='tidy-5.8.0-win64\bin'}};bin='tidy.exe'}
$tidyInstall = & $CoopExe --root $root install test/tidy --json
Assert-Exit 'nested ZIP install failed'
if (-not (Test-Path "$root/apps/tidy/current/tidy.exe")) { throw 'nested ZIP extract_dir did not flatten the selected directory' }
$tidyOutput = (& "$root/shims/tidy.exe" --version) -join "`n"
if ($LASTEXITCODE -ne 0 -or $tidyOutput -notmatch '5\.8\.0') { throw "nested ZIP entry ran wrong version: $tidyOutput" }
$tidyUninstall = & $CoopExe --root $root uninstall tidy --json
Assert-Exit 'nested ZIP uninstall failed'

# A declared extract_dir that the archive does not contain fails explicitly and publishes nothing.
$root = New-TestRoot
Write-Manifest $root 'missing-extract' @{version='1.0.0';architecture=@{'64bit'=@{url=(File-Uri $rg15);hash='71b2fef860abe467217a538ff31de02f5258807c0129f771846f87bd029aafc5';extract_dir='missing-dir'}};bin='rg.exe'}
$missingExtract = & $CoopExe --root $root install test/missing-extract --json 2>&1
if ($LASTEXITCODE -eq 0) { throw "a missing extract_dir unexpectedly installed: $($missingExtract -join "`n")" }
if (Test-Path "$root/apps/missing-extract/current") { throw 'a missing extract_dir published a current link' }

# tar.zst with a nested extract_dir: the real Main/luajit package is an Arch package whose
# mingw64 tree is selected before publishing.
$root = New-TestRoot
$luajit = Join-Path $archives 'luajit-2.1.1791988261-1-any.pkg.tar.zst'
Write-Manifest $root 'luajit' @{version='2.1.1791988261-1';architecture=@{'64bit'=@{url=(File-Uri $luajit);hash='d559881bffc105af4482eab52a34fa57963047cf45e735a5c0f8daca605c68a1';extract_dir='mingw64'}};bin='bin\luajit.exe'}
$plan = & $CoopExe --root $root install test/luajit --dry-run --json | ConvertFrom-Json
Assert-Exit 'tar.zst preview failed'
if (-not $plan.execution_available -or $plan.artifacts[0].archive -ne 'tar' -or $plan.artifacts[0].extract_dir -ne 'mingw64') { throw 'tar.zst preview did not preserve the nested layout' }
$guard = Join-Path (Split-Path $CoopExe) 'process_guard.exe'
if (-not (Test-Path -LiteralPath $guard)) { throw "Missing process guard: $guard" }
# Observe the real process tree during a zstd tar install: only coop.exe may run, no external
# 7z.exe, tar.exe or bzip2.exe is allowed to perform the extraction.
$luajitInstall = & $guard $CoopExe --root $root install test/luajit --json
Assert-Exit 'tar.zst install failed or started an external extractor'
$luajitOutput = (& "$root/shims/luajit.exe" -v) -join "`n"
if ($LASTEXITCODE -ne 0 -or $luajitOutput -notmatch 'LuaJIT 2\.1') { throw "tar.zst entry failed to run: $luajitOutput" }
if (-not (Test-Path "$root/apps/luajit/current/bin/luajit.exe") -or (Test-Path "$root/apps/luajit/current/mingw64")) { throw 'tar.zst extract_dir layout is wrong' }
# A corrupt tar.zst update must leave the working current version in place.
$badZst = Join-Path $root 'bad.tar.zst'
[IO.File]::WriteAllBytes($badZst,[byte[]](1..512 | ForEach-Object { $_ % 251 }))
Write-Manifest $root 'luajit' @{version='2.1.999';architecture=@{'64bit'=@{url=(File-Uri $badZst);hash=(Get-FileHash -LiteralPath $badZst -Algorithm SHA256).Hash.ToLower();extract_dir='mingw64'}};bin='bin\luajit.exe'}
$failed = & $CoopExe --root $root update luajit --json 2>&1
if ($LASTEXITCODE -eq 0) { throw 'corrupt tar.zst update unexpectedly succeeded' }
$luajitOutput = (& "$root/shims/luajit.exe" -v) -join "`n"
if ($LASTEXITCODE -ne 0 -or $luajitOutput -notmatch 'LuaJIT 2\.1' -or (Test-Path "$root/apps/luajit/2.1.999")) { throw 'corrupt tar.zst update damaged the current version' }
$luajitUninstall = & $CoopExe --root $root uninstall luajit --json
Assert-Exit 'tar.zst uninstall failed'

# tar.xz with a nested extract_dir: the real Main/curl archive contains a version root.
$root = New-TestRoot
$curl = Join-Path $archives 'curl-8.23.0_5-win64-mingw.tar.xz'
Write-Manifest $root 'curl' @{version='8.23.0_5';architecture=@{'64bit'=@{url=(File-Uri $curl);hash='b6ad235d1907d96615334532eab1db0040860e6b5adc3b8749a4331924449c3b';extract_dir='curl-8.23.0_5-win64-mingw'}};bin='bin\curl.exe'}
$curlInstall = & $CoopExe --root $root install test/curl --json
Assert-Exit 'tar.xz install failed'
$curlOutput = (& "$root/shims/curl.exe" --version) -join "`n"
if ($LASTEXITCODE -ne 0 -or $curlOutput -notmatch '8\.23\.0') { throw "tar.xz entry ran wrong version: $curlOutput" }
if (-not (Test-Path "$root/apps/curl/current/bin/curl.exe")) { throw 'tar.xz extract_dir layout is wrong' }
$curlUninstall = & $CoopExe --root $root uninstall curl --json
Assert-Exit 'tar.xz uninstall failed'

# A 7z self-extracting download: the real Main/unzip manifest downloads an .exe and renames it
# to dl.7z, so extraction has to read the 7z container behind the PE stub.
$root = New-TestRoot
$unzip = Join-Path $archives 'unz600xn.exe'
Write-Manifest $root 'unzip' @{version='6.00';url=((File-Uri $unzip)+'#/dl.7z');hash='7869ee36346b47701ef01efd0bc2889f970266b66c80b30f74303d50bf7fa33d';bin='unzip.exe'}
$unzipPlan = & $CoopExe --root $root install test/unzip --dry-run --json | ConvertFrom-Json
Assert-Exit '7z SFX preview failed'
if (-not $unzipPlan.execution_available -or $unzipPlan.artifacts[0].archive -ne '7z' -or $unzipPlan.artifacts[0].filename -ne 'dl.7z' -or -not $unzipPlan.artifacts[0].renamed) { throw '7z SFX preview did not preserve the rename and format' }
$unzipInstall = & $guard $CoopExe --root $root install test/unzip --json
Assert-Exit '7z SFX install failed or started an external extractor'
$unzipOutput = (& "$root/shims/unzip.exe" -v) -join "`n"
if ($LASTEXITCODE -ne 0 -or $unzipOutput -notmatch 'UnZip 6\.00') { throw "7z SFX entry ran wrong version: $unzipOutput" }
$unzipUninstall = & $CoopExe --root $root uninstall unzip --json
Assert-Exit '7z SFX uninstall failed'

# bzip2 and lzma tar streams plus the "move the contents of extract_dir" rule. The archive used by
# Scoop contains wrap/deep/wrap/deep/bin so extracting wrap\deep must leave wrap/deep/bin at the
# package root. The compression is produced with the system bsdtar only as a test fixture.
$root = New-TestRoot
$fixtures = Join-Path $root 'fixtures'
foreach ($version in @('1','2')) {
    New-Item -ItemType Directory -Path "$fixtures/v$version/wrap/deep/wrap/deep/bin" -Force | Out-Null
    $source = if ($version -eq '1') { $fixture1 } else { $fixture2 }
    Copy-Item -LiteralPath $source -Destination "$fixtures/v$version/wrap/deep/wrap/deep/bin/nested.exe"
}
$bzip2Fixture = $true
$lzmaFixture = $true
$xzsFixture = $true
foreach ($version in @('1','2')) {
    Push-Location "$fixtures/v$version"
    try {
        & tar.exe -cjf (Join-Path $fixtures "nested-$version.tar.bz2") 'wrap'
        # A tar without the matching compression support (the runner's System32 bsdtar lacks bzip2 and
        # lzma) cannot build that fixture. The streams it can build still exercise the extraction path;
        # skipping is printed, not hidden.
        if ($LASTEXITCODE -ne 0) {
            $bzip2Fixture = $false
            Write-Output 'skipped bzip2 stream: this tar cannot write bzip2'
        }
        & tar.exe --lzma -cf (Join-Path $fixtures "nested-$version.tar.lzma") 'wrap'
        if ($LASTEXITCODE -ne 0) {
            $lzmaFixture = $false
            Write-Output 'skipped lzma stream: this tar cannot write lzma'
        }
        & tar.exe -cJf (Join-Path $fixtures "nested-$version.tar.xz") 'wrap'
        if ($LASTEXITCODE -ne 0) {
            $xzsFixture = $false
            Write-Output 'skipped xz stream: this tar cannot write xz'
        }
    } finally { Pop-Location }
}
foreach ($case in @(
    @{name='bz2'; first='nested-1.tar.bz2'; second='nested-2.tar.bz2'; alias='bz2tool'; enabled=$bzip2Fixture},
    @{name='lzma'; first='nested-1.tar.lzma'; second='nested-2.tar.lzma'; alias='lzmatool'; enabled=$lzmaFixture},
    @{name='tarxz'; first='nested-1.tar.xz'; second='nested-2.tar.xz'; alias='tarxztool'; enabled=$xzsFixture}
)) {
    if (-not $case.enabled) { continue }
    $archive = Join-Path $fixtures $case.first
    Write-Manifest $root $case.name @{version='1';url=(File-Uri $archive);hash=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower();extract_dir='wrap\deep';bin=@(,@('wrap\deep\bin\nested.exe',$case.alias))}
    $install = & $CoopExe --root $root install "test/$($case.name)" --json
    Assert-Exit "$($case.name) install failed"
    $program = Join-Path $root "shims/$($case.alias).exe"
    $programOutput = (& $program) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $programOutput -notmatch 'fixture 1') { throw "$($case.name) nested extract_dir entry failed to run: $programOutput" }
    if (-not (Test-Path "$root/apps/$($case.name)/current/wrap/deep/bin/nested.exe")) { throw "$($case.name) nested same-name extract_dir layout is wrong" }
    $archive = Join-Path $fixtures $case.second
    Write-Manifest $root $case.name @{version='2';url=(File-Uri $archive);hash=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower();extract_dir='wrap\deep';bin=@(,@('wrap\deep\bin\nested.exe',$case.alias))}
    $update = & $CoopExe --root $root update $case.name --json
    Assert-Exit "$($case.name) update failed"
    $programOutput = (& $program) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $programOutput -notmatch 'fixture 2') { throw "$($case.name) updated nested entry failed to run: $programOutput" }
    if (-not (Test-Path "$root/apps/$($case.name)/1/wrap/deep/bin/nested.exe")) { throw "$($case.name) update did not retain the old version" }
    $uninstall = & $CoopExe --root $root uninstall $case.name --json
    Assert-Exit "$($case.name) uninstall failed"
}

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

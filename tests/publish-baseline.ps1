param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$TestRoot,
    [switch]$Update
)
# #64: characterisation baseline for the artifact-publish path. Every fixture is installed through
# the real CLI into a project-local root and reduced to a stable, comparable snapshot: the files the
# package published, what they hash to, what `current` points at, and the two install records.
# Snapshots live under tests/baseline/publish and are committed; -Update regenerates them after a
# deliberate behaviour change, which makes such a change visible in review instead of silent.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$baseline = Join-Path $PSScriptRoot 'baseline/publish'

$tidy = Join-Path $archives 'tidy-5.8.0-win64.zip'
$ripgrep = Join-Path $archives 'ripgrep-15.2.0-x86_64-pc-windows-msvc.zip'
$curl = Join-Path $archives 'curl-8.23.0_5-win64-mingw.tar.xz'
$luajit = Join-Path $archives 'luajit-2.1.1791988261-1-any.pkg.tar.zst'
$air = Join-Path $archives 'air_1.67.3_windows_amd64.tar.gz'
$msi = Join-Path $archives '7z2605-x64.msi'
$units = Join-Path $archives 'units-2.26-setup.exe'
$apng = Join-Path $archives 'apngasm-3.1.3-AMD64.exe'
$innounp = Join-Path $archives 'innounp-2.zip'
foreach ($path in @($tidy,$ripgrep,$curl,$luajit,$air,$msi,$units,$apng,$innounp)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing fixed test input: $path; run scripts/fetch-deps.ps1" }
}

if (-not (Test-Path -LiteralPath $baseline)) { New-Item -ItemType Directory -Path $baseline -Force | Out-Null }
$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/test/bucket","$root/temp","$root/programs" -Force | Out-Null

function File-Hash([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
# Hashtables enumerate in an order that changes between PowerShell processes, and Coop writes the
# Manifest it read back into the version directory, so an unsorted Manifest makes the record's bytes
# differ per run. Sort the keys so the snapshot stays comparable.
function Sort-Keys([hashtable]$value) {
    $ordered = [ordered]@{}
    foreach ($key in ($value.Keys | Sort-Object)) { $ordered[$key] = $value[$key] }
    return $ordered
}
function Write-Manifest([string]$name,[hashtable]$manifest) {
    [IO.File]::WriteAllText("$root/buckets/test/bucket/$name.json",
        ((Sort-Keys $manifest) | ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
}
function Invoke-Coop([string]$label,[string[]]$arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($CoopExe)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $start.WorkingDirectory = $root
    foreach ($argument in $arguments) { Add-ProcessArgument $start ($argument) }
    $start.EnvironmentVariables['TEMP'] = "$root/temp"
    $start.EnvironmentVariables['TMP'] = "$root/temp"
    $start.EnvironmentVariables['COOP_PROGRAMS_DIR'] = "$root/programs"
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(600000)) { $process.Kill(); throw "$label timed out" }
    $result = [pscustomobject]@{
        exit = $process.ExitCode
        output = $stdout.GetAwaiter().GetResult()
        error = $stderr.GetAwaiter().GetResult()
    }
    $process.Dispose()
    return $result
}

# One relative entry per published object, sorted, so a reordering of the tree is a visible diff.
# The two install records are recorded by presence only: Coop writes the Manifest it read back
# verbatim, and that Manifest carries the fixture's absolute file:// URL, so their bytes differ per
# checkout path. Their content is compared through the structured fields in the snapshot instead.
$record_files = @('scoop-install.json','scoop-manifest.json')
function Get-Entries([string]$directory) {
    $entries = [Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $directory)) { return }
    foreach ($item in Get-ChildItem -LiteralPath $directory -Recurse -Force) {
        $relative = $item.FullName.Substring($directory.Length).TrimStart('\').Replace('\','/')
        if ($item.PSIsContainer) { $entries.Add("dir|$relative") }
        elseif ($record_files -contains $relative) { $entries.Add("file|$relative|record") }
        else { $entries.Add("file|$relative|" + (File-Hash $item.FullName)) }
    }
    $sorted = $entries | Sort-Object
    return $sorted
}

function Get-Snapshot([string]$name) {
    $apps = "$root/apps/$name"
    $version = @(Get-ChildItem -LiteralPath $apps -Directory -Force | Where-Object { $_.Name -ne 'current' } | ForEach-Object { $_.Name })
    $currentTarget = $null
    $currentLink = "$apps/current"
    if (Test-Path -LiteralPath $currentLink) {
        $currentTarget = (Get-Item -LiteralPath $currentLink -Force).LinkTarget
        if (-not $currentTarget) { $currentTarget = (Get-Item -LiteralPath $currentLink -Force).Target }
        if ($currentTarget) { $currentTarget = [string]$currentTarget }
    }
    $install = $null
    $manifest = $null
    if ($version.Count -eq 1) {
        $installPath = "$apps/$($version[0])/scoop-install.json"
        $manifestPath = "$apps/$($version[0])/scoop-manifest.json"
        if (Test-Path -LiteralPath $installPath) {
            $record = Get-Content -LiteralPath $installPath -Raw | ConvertFrom-Json
            $install = [ordered]@{ bucket = [string]$record.bucket; architecture = [string]$record.architecture }
        }
        if (Test-Path -LiteralPath $manifestPath) {
            $record = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $manifest = [ordered]@{ version = [string]$record.version; bin = [string]($record.bin | ConvertTo-Json -Compress -Depth 8) }
        }
    }
    return [ordered]@{
        package = $name
        versions = @($version | Sort-Object)
        current = $(if ($currentTarget) { $currentTarget.Substring($root.Length).TrimStart('\').Replace('\','/') } else { $null })
        install_record = $install
        manifest_record = $manifest
        entries = @(Get-Entries "$apps/$($version[0])")
    } | ConvertTo-Json -Depth 8
}

function Assert-Matches([string]$name,[string]$actual) {
    $file = Join-Path $baseline "$name.json"
    # The baseline encodes JSON content, not the bytes of the file it lives in, so both sides are
    # compared with the same line endings. Otherwise a fresh checkout (LF) and a local one (CRLF)
    # disagree about a snapshot whose content is identical.
    $normalise = { param($text) (($text -replace "`r`n","`n") -replace "`r","`n") }
    if ($Update) {
        [IO.File]::WriteAllText($file,((& $normalise $actual)+"`n"),[Text.UTF8Encoding]::new($false))
        return $null
    }
    if (-not (Test-Path -LiteralPath $file)) { throw "Missing baseline $file; rerun with -Update" }
    $expected = (& $normalise (Get-Content -LiteralPath $file -Raw)).TrimEnd("`n")
    $actualText = (& $normalise $actual).TrimEnd("`n")
    if ($expected -ne $actualText) { throw "Publish baseline changed for '$name'.`n--- expected ---`n$expected`n--- actual ---`n$actualText" }
    return $null
}

function Install-Case([string]$name,[hashtable]$manifest) {
    Write-Manifest $name $manifest
    $run = Invoke-Coop $name @('--root',$root,'install',"test/$name",'--json')
    if ($run.exit -ne 0) { throw "install $name failed: $($run.error)$($run.output)" }
    $snapshot = Get-Snapshot $name
    Assert-Matches $name $snapshot
    Write-Output "  $name ok"
}

# The 7-Zip helper is provisioned the way Scoop gets it, by installing the package itself.
Install-Case '7zip' @{version='26.05';url=(File-Uri $msi);hash=(File-Hash $msi);extract_dir='Files\7-Zip';bin=@('7z.exe')}

# The innounp helper is a normal package in this root, never something Coop ships.
Add-Type -AssemblyName System.IO.Compression.FileSystem
New-Item -ItemType Directory -Path "$root/apps/innounp/current" -Force | Out-Null
[IO.Compression.ZipFile]::ExtractToDirectory($innounp,"$root/apps/innounp/current")

Install-Case 'tidy' @{version='5.8.0';url=(File-Uri $tidy);hash=(File-Hash $tidy);extract_dir='tidy-5.8.0-win64\bin';bin='tidy.exe'}
Install-Case 'ripgrep' @{version='15.2.0';url=(File-Uri $ripgrep);hash=(File-Hash $ripgrep);extract_dir='ripgrep-15.2.0-x86_64-pc-windows-msvc';bin='rg.exe'}
Install-Case 'curl' @{version='8.23.0_5';url=(File-Uri $curl);hash=(File-Hash $curl);extract_dir='curl-8.23.0_5-win64-mingw';bin='bin\curl.exe'}
Install-Case 'luajit' @{version='2.1.1791988261-1';url=(File-Uri $luajit);hash=(File-Hash $luajit);extract_dir='mingw64';bin='bin\luajit.exe'}
Install-Case 'air' @{version='1.67.3';url=(File-Uri $air);hash=(File-Hash $air);bin='air.exe'}
Install-Case 'units' @{version='2.26';url=(File-Uri $units);hash=(File-Hash $units);innosetup=$true;bin='units.exe'}
$preInstall = @'
'$PLUGINSDIR', 'Uninstall.exe' | ForEach-Object { Remove-Item "$dir\$_" -Recurse -Force }
'@
Install-Case 'apng' @{version='3.1.3';url=((File-Uri $apng)+'#/dl.7z');hash=(File-Hash $apng);pre_install=$preInstall;
    bin=@('bin\apngasm.exe',@('bin\apngasm.exe','apngasm-cli'))}

# --- Failure characterisation: both must fail and publish no `current`. --------------------------
function Assert-Failure([string]$name,[hashtable]$manifest) {
    Write-Manifest $name $manifest
    $run = Invoke-Coop $name @('--root',$root,'install',"test/$name",'--json')
    if ($run.exit -eq 0) { throw "install $name unexpectedly succeeded" }
    $current = "$root/apps/$name/current"
    if (Test-Path -LiteralPath $current) { throw "install $name published a current link despite failing" }
    # The failure has to be the one this case is about, not merely a failure: the message names it.
    $text = ($run.error + $run.output)
    $expectedReason = if ($name -eq 'missing-extract') { 'extract_dir' } else { 'archive|Cannot|read' }
    if ($text -notmatch $expectedReason) { throw "install $name failed for an unexpected reason: $text" }
    $snapshot = [ordered]@{ package = $name; exit = $run.exit; current = $null } | ConvertTo-Json -Depth 4
    Assert-Matches "failure-$name" $snapshot
    Write-Output "  failure-$name ok (exit $($run.exit))"
}

# A unique alias keeps the failure at the extraction contract instead of colliding with the shim the\n# earlier ripgrep install left behind.\nAssert-Failure 'missing-extract' @{version='1.0.0';url=(File-Uri $ripgrep);hash=(File-Hash $ripgrep);extract_dir='missing-dir';bin=@(,@('rg.exe','mex'))}

$corrupt = Join-Path $root 'corrupt.tar.zst'
[IO.File]::WriteAllBytes($corrupt,[byte[]](1..2048 | ForEach-Object { $_ % 251 }))
Assert-Failure 'corrupt' @{version='1.0.0';url=(File-Uri $corrupt);hash=(File-Hash $corrupt);extract_dir='mingw64';bin=@(,@('bin\luajit.exe','corrupt-bin'))}

Write-Output "publish baseline: $(@(Get-ChildItem -LiteralPath $baseline -Filter '*.json').Count) snapshots $(if ($Update) { 'written' } else { 'verified' })"

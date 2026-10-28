param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# #56: installing the version that is already current is a no-op, not a failure. Scoop warns, prints
# where to go instead, and exits 0; the root is left byte-identical. Installing a different version
# stays a normal install, so the refusal is tied to the version and not to "a package is installed".
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$tidy = Join-Path $archives 'tidy-5.8.0-win64.zip'
if (-not (Test-Path -LiteralPath $tidy)) { throw "Missing fixed test input: $tidy; run scripts/fetch-deps.ps1" }

$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null

function File-Hash([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
function Write-Manifest([string]$name,[string]$version) {
    $ordered = [ordered]@{ version=$version; url=(File-Uri $tidy); hash=(File-Hash $tidy)
        extract_dir='tidy-5.8.0-win64\bin'; bin='tidy.exe' }
    [IO.File]::WriteAllText("$root/buckets/test/bucket/$name.json",
        ($ordered | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
function Invoke-Coop([string[]]$arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($CoopExe)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $start.WorkingDirectory = $root
    foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
    $start.Environment['TEMP'] = "$root/temp"
    $start.Environment['TMP'] = "$root/temp"
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(300000)) { $process.Kill($true); throw 'coop timed out' }
    $result = [pscustomobject]@{ exit = $process.ExitCode
        output = $stdout.GetAwaiter().GetResult(); error = $stderr.GetAwaiter().GetResult() }
    $process.Dispose()
    return $result
}
# Every file under the root with its size and digest: a no-op install must leave this identical.
function Get-Fingerprint {
    $entries = [Collections.Generic.List[string]]::new()
    foreach ($item in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
        $relative = $item.FullName.Substring($root.Length).TrimStart('\').Replace('\','/')
        $entries.Add("$relative|$($item.Length)|$(File-Hash $item.FullName)")
    }
    return (($entries | Sort-Object) -join "`n")
}

Write-Manifest 'tidy' '5.8.0'
$first = Invoke-Coop @('--root',$root,'install','test/tidy','--json')
if ($first.exit -ne 0) { throw "the first install failed: $($first.error)" }
$before = Get-Fingerprint

# 1. Text mode: Scoop's two lines, exit 0, nothing written.
$again = Invoke-Coop @('--root',$root,'install','test/tidy')
if ($again.exit -ne 0) { throw "reinstalling the current version failed with exit $($again.exit): $($again.error)$($again.output)" }
$expectedLines = @("WARN  'tidy' (5.8.0) is already installed.","Use 'scoop update tidy' to install a new version.")
$actualLines = @($again.output -split "`r?`n" | Where-Object { $_ -ne '' })
if (($actualLines -join "`n") -ne ($expectedLines -join "`n")) {
    throw "the already-installed output does not match Scoop's:`n--- expected ---`n$($expectedLines -join "`n")`n--- actual ---`n$($actualLines -join "`n")"
}
if ($again.error -ne '') { throw "the already-installed path wrote to stderr: $($again.error)" }
$after = Get-Fingerprint
if ($before -ne $after) { throw 'reinstalling the current version changed the installation root' }

# 2. Machine mode: the same outcome, distinguishable without parsing prose.
$json = Invoke-Coop @('--root',$root,'install','test/tidy','--json')
if ($json.exit -ne 0) { throw "reinstalling in --json mode failed with exit $($json.exit)" }
$result = $json.output | ConvertFrom-Json
if ($result.status -ne 'already-installed') { throw "--json did not report already-installed: $($json.output)" }
if ($result.package -ne 'tidy' -or $result.version -ne '5.8.0') { throw "--json lost the package identity: $($json.output)" }
if ((Get-Fingerprint) -ne $before) { throw 'reinstalling in --json mode changed the installation root' }

# 3. The preview states the same verdict and plans no write.
$preview = Invoke-Coop @('--root',$root,'install','test/tidy','--dry-run','--json')
if ($preview.exit -ne 0) { throw "the preview of an installed package failed with exit $($preview.exit)" }
$previewResult = $preview.output | ConvertFrom-Json
if ($previewResult.status -ne 'already-installed' -or $previewResult.already_installed -ne $true) {
    throw "the preview did not report already-installed: $($preview.output)"
}
if ((Get-Fingerprint) -ne $before) { throw 'the preview changed the installation root' }
# 3. A different version is refused by name, not silently: `update` owns replacing entries and the
#    current link, and install must not duplicate that path. The refusal names the version and the
#    command, so the reason is legible without reading the code.
Write-Manifest 'tidy' '5.8.1'
$different = Invoke-Coop @('--root',$root,'install','test/tidy','--json')
if ($different.exit -eq 0) { throw "installing a different version changed the package: $($different.output)" }
if ($different.error -notmatch 'update') { throw "the refusal did not name the command that does the work: $($different.error)" }
if (Test-Path -LiteralPath "$root/apps/tidy/5.8.1") { throw 'the refused install still wrote a version directory' }
# 5. A reinstall must not resolve dependencies at all: the no-op verdict is decided before dependency
#    resolution, so a Manifest that names an absent dependency still installs nothing and warns.
$ordered = [ordered]@{ version='5.8.0'; url=(File-Uri $tidy); hash=(File-Hash $tidy)
    extract_dir='tidy-5.8.0-win64\bin'; bin='tidy.exe'; depends=@('ghost') }
[IO.File]::WriteAllText("$root/buckets/test/bucket/tidy.json",
    ($ordered | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$before = Get-Fingerprint
$reinstall = Invoke-Coop @('--root',$root,'install','test/tidy')
if ($reinstall.exit -ne 0) { throw "the reinstall resolved the dependency and failed: $($reinstall.error)$($reinstall.output)" }
$reinstallLines = @($reinstall.output -split "`r?`n" | Where-Object { $_ -ne '' })
if (($reinstallLines -join "`n") -ne ($expectedLines -join "`n")) {
    throw "the reinstall printed more than Scoop's two lines:`n$($reinstallLines -join "`n")"
}
if ((Get-Fingerprint) -ne $before) { throw 'the reinstall changed the installation root' }
Write-Output 'reinstall refusal: 5 cases verified'

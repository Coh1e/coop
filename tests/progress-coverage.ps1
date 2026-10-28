param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# #54: the stage reporting install and uninstall already had now covers the rest of the write commands
# and every package in a dependency install. Each package reports as it finishes, --json stays free of
# progress text, and cleanup names what it removed.
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not (($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase))) { throw 'Test root outside project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$tidy = Join-Path $archives 'tidy-5.8.0-win64.zip'
if (-not (Test-Path -LiteralPath $tidy)) { throw "Missing fixed test input: $tidy; run scripts/fetch-deps.ps1" }

$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/test/bucket","$root/.coop" -Force | Out-Null

function File-Hash([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
function Write-Manifest([string]$name,[hashtable]$manifest) {
    $ordered = [ordered]@{}
    foreach ($key in ($manifest.Keys | Sort-Object)) { $ordered[$key] = $manifest[$key] }
    [IO.File]::WriteAllText("$root/buckets/test/bucket/$name.json",
        ($ordered | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
function Invoke-Coop([string[]]$arguments,[hashtable]$environment = @{}) {
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
    foreach ($key in $environment.Keys) { $start.Environment[$key] = $environment[$key] }
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(300000)) { $process.Kill($true); throw 'coop timed out' }
    $result = [pscustomobject]@{ exit = $process.ExitCode
        output = $stdout.GetAwaiter().GetResult(); error = $stderr.GetAwaiter().GetResult() }
    $process.Dispose()
    return $result
}
function Assert-NoProgress([string]$label,[string]$text) {
    foreach ($marker in 'Installing ','Downloading ','Checking hash of ','Extracting ','Linking ','was installed successfully') {
        if ($text.Contains($marker)) { throw "$label carried progress text: $marker`n$text" }
    }
    if ($text.Contains([string][char]27)) { throw "$label carried ANSI escapes" }
}

$hash = File-Hash $tidy
Write-Manifest 'dep' @{ version='1.0.0'; url=(File-Uri $tidy); hash=$hash
    extract_dir='tidy-5.8.0-win64\bin'; bin=@(,@('tidy.exe','depbin')) }
Write-Manifest 'main' @{ version='1.0.0'; url=(File-Uri $tidy); hash=$hash
    extract_dir='tidy-5.8.0-win64\bin'; bin='tidy.exe'; depends=@('dep') }

# 1. Each package in a dependency install reports as it finishes, in Scoop's own wording.
$install = Invoke-Coop @('--root',$root,'install','test/main')
if ($install.exit -ne 0) { throw "the dependency install failed: $($install.error)$($install.output)" }
$lines = @($install.output -split "`r?`n")
$depResult = [Array]::IndexOf($lines,"'dep' (1.0.0) was installed successfully!")
$mainStart = -1
for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -like "Installing 'main'*") { $mainStart = $i; break } }
if ($depResult -lt 0) { throw "the dependency never reported its own result:`n$($install.output)" }
if ($mainStart -lt 0) { throw 'the requested package never printed its own start line' }
if ($depResult -gt $mainStart) { throw 'the dependency result was buffered until after the next package started' }

# 2. Machine output stays free of progress for every write command exercised here. A package that is
#    not installed yet is used: reinstalling test/main would be a no-op, so no progress code would run
#    and a leaked line could pass.
Write-Manifest 'fresh' @{ version='1.0.0'; url=(File-Uri $tidy); hash=$hash
    extract_dir='tidy-5.8.0-win64\bin'; bin=@(,@('tidy.exe','freshbin')) }
$jsonInstall = Invoke-Coop @('--root',$root,'install','test/fresh','--json')
if ($jsonInstall.exit -ne 0) { throw "the machine install failed: $($jsonInstall.error)" }
Assert-NoProgress '--json install' $jsonInstall.output
$jsonCleanup = Invoke-Coop @('--root',$root,'cleanup','--json')
Assert-NoProgress '--json cleanup' ($jsonCleanup.output + $jsonCleanup.error)

# 3. A pending transaction is reported action by action, and the machine form is still JSON only.
# A fresh package is used because reinstalling an installed one is a no-op and never reaches the fault.
Write-Manifest 'crashpkg' @{ version='1.0.0'; url=(File-Uri $tidy); hash=$hash
    extract_dir='tidy-5.8.0-win64\bin'; bin=@(,@('tidy.exe','crashbin')) }
'{"crash":["after-extract"]}' | Set-Content -LiteralPath "$root/.coop/test-faults.json" -Encoding utf8
$crash = Invoke-Coop @('--root',$root,'install','test/crashpkg','--json') @{ 'COOP_ALLOW_TEST_FAULTS' = '1' }
if ($crash.exit -eq 0) { throw 'the injected crash did not stop the install' }
Remove-Item -LiteralPath "$root/.coop/test-faults.json" -Force
# The crash has to have left a transaction behind, otherwise the recovery below proves nothing.
$pending = @(Get-ChildItem -LiteralPath "$root/.coop/transactions" -Directory -Force -ErrorAction SilentlyContinue)
if ($pending.Count -eq 0) { throw 'the injected crash left no pending transaction to recover' }
$recover = Invoke-Coop @('--root',$root,'recover')
if ($recover.exit -ne 0) { throw "recover failed: $($recover.error)$($recover.output)" }
if ($recover.output -notmatch 'recovered') { throw "recover did not report the recovered package: $($recover.output)" }
$jsonRecover = Invoke-Coop @('--root',$root,'recover','--json')
Assert-NoProgress '--json recover' $jsonRecover.output

# 4. Cleanup names what it removed; with nothing to remove it only closes with the fixed sentence.
# A second version is created by an update, so the first one becomes the removable scope.
Write-Manifest 'old' @{ version='2.0.0'; url=(File-Uri $tidy); hash=$hash
    extract_dir='tidy-5.8.0-win64\bin'; bin=@(,@('tidy.exe','oldbin')) }
$old = Invoke-Coop @('--root',$root,'install','test/old','--json')
if ($old.exit -ne 0) { throw "the first version failed to install: $($old.error)" }
Write-Manifest 'old' @{ version='2.1.0'; url=(File-Uri $tidy); hash=$hash
    extract_dir='tidy-5.8.0-win64\bin'; bin=@(,@('tidy.exe','oldbin')) }
$bump = Invoke-Coop @('--root',$root,'update','old','--json')
if ($bump.exit -ne 0) { throw "the version bump failed: $($bump.error)" }
$cleanup = Invoke-Coop @('--root',$root,'cleanup')
if ($cleanup.output -notmatch 'Removing old:' -or $cleanup.output -notmatch ' 2.0.0' -or $cleanup.output -notmatch 'Everything is shiny now!') {
    throw "cleanup did not name its removal scope: $($cleanup.output)"
}
$empty = Invoke-Coop @('--root',$root,'cleanup')
if (($empty.output.Trim()) -ne 'Everything is shiny now!') { throw "an empty cleanup printed more than the closing sentence: $($empty.output)" }

Write-Output 'progress coverage: dependency, recover and cleanup verified'

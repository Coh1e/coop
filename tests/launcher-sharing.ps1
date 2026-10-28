param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# #53: the launcher is a loader, so one copy per root serves every entry that can share it. Non-GUI
# entries become hard links to it; a GUI entry keeps its own copy because its subsystem byte differs.
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not (($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase))) { throw 'Test root outside project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$tidy = Join-Path $archives 'tidy-5.8.0-win64.zip'
if (-not (Test-Path -LiteralPath $tidy)) { throw "Missing fixed test input: $tidy; run scripts/fetch-deps.ps1" }

$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null
$manifest = [ordered]@{
    version='1.0.0'; url=([Uri][IO.Path]::GetFullPath($tidy)).AbsoluteUri
    hash=(Get-FileHash -LiteralPath $tidy -Algorithm SHA256).Hash.ToLower()
    extract_dir='tidy-5.8.0-win64\bin'
    bin=@(@('tidy.exe','alpha'),@('tidy.exe','beta'))
}
[IO.File]::WriteAllText("$root/buckets/test/bucket/two.json",
    ($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))

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
# The file id is the identity of the underlying object: hard links share it, copies do not.
function Get-FileId([string]$path) {
    $output = & fsutil.exe file queryfileid $path 2>&1
    if ($LASTEXITCODE -ne 0) { throw "fsutil could not read the file id of $path : $output" }
    return (($output -join ' ') -replace '\s+',' ').Trim()
}

$install = Invoke-Coop @('--root',$root,'install','test/two','--json')
if ($install.exit -ne 0) { throw "the install failed: $($install.error)$($install.output)" }

$alpha = "$root/shims/alpha.exe"
$beta = "$root/shims/beta.exe"
$shared = "$root/.coop/launcher.exe"
foreach ($path in @($alpha,$beta,$shared)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "missing $path" }
}
$alphaId = Get-FileId $alpha
$betaId = Get-FileId $beta
$sharedId = Get-FileId $shared
if ($alphaId -ne $betaId -or $alphaId -ne $sharedId) {
    throw "the entries do not share one launcher: alpha=$alphaId beta=$betaId shared=$sharedId"
}

# Sharing must not change what the entry runs.
$run = & $alpha --version 2>&1
if ($LASTEXITCODE -ne 0 -or ($run -join "`n") -notmatch '5\.8\.0') {
    throw "the shared launcher did not run the entry: $($run -join ' ')"
}

# Uninstalling removes the links, not the shared object the next install will use again.
$remove = Invoke-Coop @('--root',$root,'uninstall','two','--json')
if ($remove.exit -ne 0) { throw "the uninstall failed: $($remove.error)" }
if ((Test-Path -LiteralPath $alpha) -or (Test-Path -LiteralPath $beta)) { throw 'the uninstall left an entry link behind' }

Write-Output 'launcher sharing: two entries share one launcher'

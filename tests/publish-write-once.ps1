param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# #67: an archive artifact is written once. The claim is checked by interrupting the install at the
# after-extract fault point, which terminates the process without unwinding, and then reading the
# transaction the crash left behind: the staging directory must hold exactly the entries the
# committed baseline records, and no second copy of the tree may exist beside it.
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$baseline = Join-Path $PSScriptRoot 'baseline/publish'
$tidy = Join-Path $archives 'tidy-5.8.0-win64.zip'
$luajit = Join-Path $archives 'luajit-2.1.1791988261-1-any.pkg.tar.zst'
foreach ($path in @($tidy,$luajit)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing fixed test input: $path; run scripts/fetch-deps.ps1" }
}


function File-Hash([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
function Write-Manifest([string]$name,[hashtable]$manifest) {
    $ordered = [ordered]@{}
    foreach ($key in ($manifest.Keys | Sort-Object)) { $ordered[$key] = $manifest[$key] }
    [IO.File]::WriteAllText("$script:root/buckets/test/bucket/$name.json",
        ($ordered | ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
}
function Invoke-Coop([string[]]$arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($CoopExe)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $start.WorkingDirectory = $script:root
    foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
    $start.Environment['TEMP'] = "$script:root/temp"
    $start.Environment['TMP'] = "$script:root/temp"
    $start.Environment['COOP_PROGRAMS_DIR'] = "$script:root/programs"
    $start.Environment['COOP_ALLOW_TEST_FAULTS'] = '1'
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(300000)) { $process.Kill($true); throw 'coop timed out' }
    $result = [pscustomobject]@{ exit = $process.ExitCode
        output = $stdout.GetAwaiter().GetResult(); error = $stderr.GetAwaiter().GetResult() }
    $process.Dispose()
    return $result
}
function Get-RelativeEntries([string]$directory) {
    $entries = [Collections.Generic.List[string]]::new()
    foreach ($item in Get-ChildItem -LiteralPath $directory -Recurse -Force) {
        $relative = $item.FullName.Substring($directory.Length).TrimStart('\').Replace('\','/')
        if ($item.PSIsContainer) { $entries.Add("dir|$relative") }
        else { $entries.Add("file|$relative|" + (File-Hash $item.FullName)) }
    }
    $sorted = $entries | Sort-Object
    return ,$sorted
}

function Assert-WrittenOnce([string]$case,[hashtable]$manifest) {
    # Each case gets its own root: a terminated process leaves a pending transaction that blocks
    # every later write in that root.
    $script:root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path "$script:root/buckets/test/bucket","$script:root/temp","$script:root/programs" -Force | Out-Null
    Write-Manifest $case $manifest
    New-Item -ItemType Directory -Path "$script:root/.coop" -Force | Out-Null
    @{ crash = @('after-extract') } | ConvertTo-Json | Set-Content -LiteralPath "$script:root/.coop/test-faults.json" -Encoding utf8
    $run = Invoke-Coop @('--root',$script:root,'install',"test/$case",'--json')
    if ($run.exit -eq 0) { throw "the injected crash did not stop '$case'" }
    # The crash leaves exactly one transaction behind; its journal names it.
    $transactions = @(Get-ChildItem -LiteralPath "$script:root/.coop/transactions" -Directory -Force)
    if ($transactions.Count -ne 1) { throw "expected one left-behind transaction, found $($transactions.Count)" }
    $transaction = $transactions[0].FullName
    $payload = Join-Path $transaction 'payload'
    if (-not (Test-Path -LiteralPath $payload)) { throw "'$case' left no staging directory to inspect" }

    $second = @(Get-ChildItem -LiteralPath $transaction -Directory -Force | Where-Object { $_.Name -like 'extract-*' })
    if ($second.Count -ne 0) { throw "'$case' kept a second extraction tree: $($second.Name -join ', ')" }

    # The staging directory must equal the published tree the baseline records. The two install
    # records are written by the publication too, so they are part of the comparison.
    $expected = [Collections.Generic.List[string]]::new()
    $recorded = Get-Content -LiteralPath (Join-Path $baseline "$case.json") -Raw | ConvertFrom-Json
    foreach ($entry in $recorded.entries) {
        $expected.Add([string]$entry)
    }
    $expectedSorted = ($expected | Sort-Object) -join "`n"
    $actualSorted = ((Get-RelativeEntries $payload) | Sort-Object) -join "`n"
    if ($expectedSorted -ne $actualSorted) {
        throw "'$case' staging does not match the published tree exactly once.`n--- expected ---`n$expectedSorted`n--- actual ---`n$actualSorted"
    }
    Remove-Item -LiteralPath "$script:root/.coop/test-faults.json" -Force
    Write-Output "  $case written once"
}

Assert-WrittenOnce 'tidy' @{version='5.8.0';url=(File-Uri $tidy);hash=(File-Hash $tidy);extract_dir='tidy-5.8.0-win64\bin';bin='tidy.exe'}
Assert-WrittenOnce 'luajit' @{version='2.1.1791988261-1';url=(File-Uri $luajit);hash=(File-Hash $luajit);extract_dir='mingw64';bin='bin\luajit.exe'}

Write-Output 'publish write-once: 2 cases verified'

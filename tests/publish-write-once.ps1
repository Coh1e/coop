param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# #67: an archive artifact is written once. The claim is about what happens to the disk *while* the
# install runs, so the assertion watches the transaction directory instead of reading the tree
# afterwards: a second copy would have to appear there, and with a single write it never does.
# The watch is proved live by requiring that the staging directory itself was observed, so the
# assertion cannot pass by watching nothing.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
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

function Install-Watched([string]$case,[hashtable]$manifest) {
    $root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path "$root/buckets/test/bucket","$root/temp","$root/programs","$root/.coop/transactions" -Force | Out-Null
    $ordered = [ordered]@{}
    foreach ($key in ($manifest.Keys | Sort-Object)) { $ordered[$key] = $manifest[$key] }
    [IO.File]::WriteAllText("$root/buckets/test/bucket/$case.json",
        ($ordered | ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))

    # Every path the install creates under the transaction directory, captured while it runs.
    $seen = [Collections.Concurrent.ConcurrentQueue[string]]::new()
    $watcher = [IO.FileSystemWatcher]::new("$root/.coop/transactions")
    $watcher.IncludeSubdirectories = $true
    $watcher.InternalBufferSize = 65536
    $watcher.NotifyFilter = [IO.NotifyFilters]'FileName, DirectoryName'
    $watcher.EnableRaisingEvents = $true
    $subscription = Register-ObjectEvent -InputObject $watcher -EventName Created -MessageData $seen -Action {
        $Event.MessageData.Enqueue($Event.SourceEventArgs.FullPath)
    }
    try {
        $start = [Diagnostics.ProcessStartInfo]::new($CoopExe)
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $start.WorkingDirectory = $root
        foreach ($argument in @('--root',$root,'install',"test/$case",'--json')) { Add-ProcessArgument $start ($argument) }
        $start.EnvironmentVariables['TEMP'] = "$root/temp"
        $start.EnvironmentVariables['TMP'] = "$root/temp"
        $start.EnvironmentVariables['COOP_PROGRAMS_DIR'] = "$root/programs"
        $process = [Diagnostics.Process]::Start($start)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(300000)) { $process.Kill(); throw 'coop timed out' }
        $result = [pscustomobject]@{ exit = $process.ExitCode
            output = $stdout.GetAwaiter().GetResult(); error = $stderr.GetAwaiter().GetResult() }
        $process.Dispose()
        Start-Sleep -Milliseconds 250
    } finally {
        $watcher.EnableRaisingEvents = $false
        Unregister-Event -SubscriptionId $subscription.Id
        $watcher.Dispose()
    }
    if ($result.exit -ne 0) { throw "install $case failed: $($result.error)$($result.output)" }

    $paths = [Collections.Generic.List[string]]::new()
    $entry = [string]::Empty
    while ($seen.TryDequeue([ref]$entry)) { $paths.Add($entry) }
    if ($paths.Count -eq 0) { throw "the watcher observed nothing for '$case'; the assertion would be vacuous" }
    if (@($paths | Where-Object { $_ -match '[\\/]payload[\\/]' }).Count -eq 0) {
        throw "the watcher never saw the staging directory for '$case'; the assertion would be vacuous"
    }
    $secondTree = @($paths | Where-Object { $_ -match '[\\/]extract-\d+[\\/]' })
    if ($secondTree.Count -ne 0) {
        throw "'$case' created a second extraction tree: $($secondTree[0])"
    }
    Write-Output "  $case written once ($($paths.Count) created paths observed)"
}

Install-Watched 'tidy' @{version='5.8.0';url=(File-Uri $tidy);hash=(File-Hash $tidy);extract_dir='tidy-5.8.0-win64\bin';bin='tidy.exe'}
Install-Watched 'luajit' @{version='2.1.1791988261-1';url=(File-Uri $luajit);hash=(File-Hash $luajit);extract_dir='mingw64';bin='bin\luajit.exe'}

Write-Output 'publish write-once: 2 cases verified'

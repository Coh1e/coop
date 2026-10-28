param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# #60: Scoop hard-codes ANSI escapes into its own output, so a redirected run keeps them. coop has to
# write the same bytes, and --json has to stay free of them.
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
    extract_dir='tidy-5.8.0-win64\bin'; bin='tidy.exe'
    suggest=@{ vcredist='extras/vcredist2022' }
}
[IO.File]::WriteAllText("$root/buckets/test/bucket/coloured.json",
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
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(300000)) { $process.Kill($true); throw 'coop timed out' }
    $result = [pscustomobject]@{ exit = $process.ExitCode
        output = $stdout.GetAwaiter().GetResult(); error = $stderr.GetAwaiter().GetResult() }
    $process.Dispose()
    return $result
}

$esc = [string][char]27
$install = Invoke-Coop @('--root',$root,'install','test/coloured')
if ($install.exit -ne 0) { throw "the install failed: $($install.error)$($install.output)" }

# The filename in the hash and extract lines is wrapped in Scoop's cyan.
$cyan = "$esc[36mtidy-5.8.0-win64.zip$esc[0m"
if (-not $install.output.Contains("Checking hash of $cyan")) { throw "the hash line does not colour the filename" }
if (-not $install.output.Contains("Extracting $cyan")) { throw "the extract line does not colour the filename" }

# The suggestion line is the whole DarkYellow line.
$yellow = "$esc[33m'coloured' suggests installing 'extras/vcredist2022'.$esc[0m"
if (-not $install.output.Contains($yellow)) { throw "the suggestion line is not dark yellow: $($install.output)" }

# Machine output carries no escapes at all.
$json = Invoke-Coop @('--root',$root,'uninstall','coloured','--json')
if ($json.exit -ne 0) { throw "the uninstall failed: $($json.error)" }
$again = Invoke-Coop @('--root',$root,'install','test/coloured','--json')
if ($again.exit -ne 0) { throw "the second install failed: $($again.error)" }
if ($again.output.Contains($esc) -or $again.error.Contains($esc)) { throw '--json contained an ANSI escape' }

Write-Output 'ansi colours: 3 cases verified'

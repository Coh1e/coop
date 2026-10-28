param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# #58: the line shapes of reset, uninstall and cleanup, taken from the recorded Scoop output
# (docs/research/scoop-cli-output.md). Each command is asserted as a whole block, because the order
# of the lines is part of the contract.
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
function Write-Manifest([string]$version) {
    $ordered = [ordered]@{ version=$version; url=(File-Uri $tidy); hash=(File-Hash $tidy)
        extract_dir='tidy-5.8.0-win64\bin'; bin='tidy.exe' }
    [IO.File]::WriteAllText("$root/buckets/test/bucket/tidy.json",
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
    if ($result.exit -ne 0) { throw "coop $($arguments -join ' ') failed: $($result.error)$($result.output)" }
    return $result
}
function Get-Lines([string]$text) { return @($text -split "`r?`n") }
function Assert-Block([string]$label,[string[]]$expected,[string]$text) {
    $actual = Get-Lines $text
    # Trailing empty lines are transport, not content.
    while ($actual.Count -gt 0 -and $actual[-1] -eq '') { $actual = $actual[0..($actual.Count-2)] }
    $e = ($expected -join "`n")
    $a = ($actual -join "`n")
    if ($e -ne $a) { throw "$label block does not match Scoop's:`n--- expected ---`n$e`n--- actual ---`n$a" }
}

Write-Manifest '5.8.0'
Invoke-Coop @('--root',$root,'install','test/tidy','--json') | Out-Null
Write-Manifest '5.8.1'
Invoke-Coop @('--root',$root,'update','tidy','--json') | Out-Null

# reset: no quotes around the package name, and no closing line.
$reset = Invoke-Coop @('--root',$root,'reset','tidy@5.8.0')
Assert-Block 'reset' @(
    'Resetting tidy (5.8.0).'
    "Linking $root\apps\tidy\current => $root\apps\tidy\5.8.0"
    "Creating shim for 'tidy'."
) $reset.output

# cleanup: what it removed, a blank line, then the fixed closing sentence.
$cleanup = Invoke-Coop @('--root',$root,'cleanup')
Assert-Block 'cleanup' @(
    'Removing tidy:'
    ' 5.8.1'
    ''
    'Everything is shiny now!'
) $cleanup.output

# uninstall: entries before the link, and one closing line that names the package.
$uninstall = Invoke-Coop @('--root',$root,'uninstall','tidy')
Assert-Block 'uninstall' @(
    "Uninstalling 'tidy' (5.8.0)."
    "Removing shim 'tidy.shim'."
    "Removing shim 'tidy.exe'."
    "Unlinking $root\apps\tidy\current"
    "'tidy' was uninstalled."
) $uninstall.output

Write-Output 'command lines: reset, cleanup and uninstall verified'

param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
# #59: the Manifest's `suggest` and `notes` are reported after a successful install, the way Scoop
# reports them: one suggestion line per feature whose candidates are all missing, then `notes`
# verbatim under a fixed heading. Both also reach --json as structured fields.
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$tidy = Join-Path $archives 'tidy-5.8.0-win64.zip'
if (-not (Test-Path -LiteralPath $tidy)) { throw "Missing fixed test input: $tidy; run scripts/fetch-deps.ps1" }

$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
foreach ($bucket in 'test','extras') {
    New-Item -ItemType Directory -Path "$root/buckets/$bucket/bucket" -Force | Out-Null
}

function File-Hash([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
function Write-Manifest([string]$bucket,[string]$name,[hashtable]$manifest) {
    [IO.File]::WriteAllText("$root/buckets/$bucket/bucket/$name.json",
        ($manifest | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
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

$notes = "Run 'tidy --help' for options.`nSecond line stays."
$suggesting = @{
    version='1.0.0'; url=(File-Uri $tidy); hash=(File-Hash $tidy)
    extract_dir='tidy-5.8.0-win64\bin'; bin='tidy.exe'
    notes=$notes
    suggest=@{ vcredist='extras/vcredist2022' }
}
Write-Manifest 'test' 'sug' $suggesting

# 1. With the suggested package missing, all three blocks appear in Scoop's order.
$install = Invoke-Coop @('--root',$root,'install','test/sug')
if ($install.exit -ne 0) { throw "the install failed: $($install.error)$($install.output)" }
$lines = @($install.output -split "`r?`n")
$suggestLine = "'sug' suggests installing 'extras/vcredist2022'."
$notesIndex = [Array]::IndexOf($lines,'Notes')
if ($notesIndex -lt 0) { throw "the notes block is missing:`n$($install.output)" }
if ($lines[$notesIndex+1] -ne '-----') { throw "the notes heading is not followed by a rule: $($lines[$notesIndex+1])" }
if ($lines[$notesIndex+2] -ne "Run 'tidy --help' for options." -or $lines[$notesIndex+3] -ne 'Second line stays.') {
    throw "the notes text was not reported verbatim: $($lines[$notesIndex+2..($notesIndex+4)] -join ' | ')"
}
if ($lines[$notesIndex+4] -ne '-----') { throw 'the notes block is not closed by a rule' }
if (-not ($lines -contains $suggestLine)) { throw "the suggestion line is missing:`n$($install.output)" }
$successIndex = [Array]::IndexOf($lines,'sug: success')
if ($successIndex -lt 0 -or $successIndex -gt $notesIndex) { throw 'the notes block did not follow the success line' }
if ([Array]::IndexOf($lines,$suggestLine) -gt $notesIndex) { throw 'the suggestion line did not precede the notes block' }

# 2. The same facts are machine-readable.
$json = Invoke-Coop @('--root',$root,'install','test/sug','--dry-run','--json')
if ($json.exit -ne 0) { throw "the preview failed: $($json.error)" }
$preview = $json.output | ConvertFrom-Json
if ($preview.package.notes -ne "Run 'tidy --help' for options.`nSecond line stays.") { throw "the preview lost the notes: $($json.output)" }
$suggestion = @($preview.package.suggest) | Select-Object -First 1
if ($suggestion.feature -ne 'vcredist' -or @($suggestion.candidates)[0] -ne 'extras/vcredist2022') {
    throw "the preview lost the suggestion: $($json.output)"
}

# 3. A fulfilled suggestion is not printed.
Write-Manifest 'extras' 'vcredist2022' @{
    version='1.0.0'; url=(File-Uri $tidy); hash=(File-Hash $tidy)
    extract_dir='tidy-5.8.0-win64\bin'; bin=@(,@('tidy.exe','vcredist2022'))
}
$fulfil = Invoke-Coop @('--root',$root,'install','extras/vcredist2022','--json')
if ($fulfil.exit -ne 0) { throw "installing the suggested package failed: $($fulfil.error)" }
$again = Invoke-Coop @('--root',$root,'uninstall','sug','--json')
if ($again.exit -ne 0) { throw "uninstalling the suggesting package failed: $($again.error)" }
$second = Invoke-Coop @('--root',$root,'install','test/sug')
if ($second.exit -ne 0) { throw "the second install failed: $($second.error)" }
if (($second.output -split "`r?`n") -contains $suggestLine) {
    throw "the suggestion was printed although its candidate is installed:`n$($second.output)"
}
if (($second.output -split "`r?`n") -notcontains 'Notes') { throw 'the notes block disappeared with the suggestion' }

Write-Output 'suggest and notes: 3 cases verified'

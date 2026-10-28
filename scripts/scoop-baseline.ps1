param(
    [string]$ScoopShim = "$env:USERPROFILE\scoop\shims\scoop.ps1",
    [string]$Output = (Join-Path $PSScriptRoot '../.local/scoop-baseline')
)
# Reproduces the Scoop column of docs/acceptance-matrix.md: the same fixtures, run through a real Scoop
# in a project-local root, with the command, exit code and output recorded. Without this script the
# column can only be quoted as a historical capture; with it, a reader can regenerate it on their box.
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ScoopShim)) { throw "No Scoop installation at $ScoopShim; the Scoop column needs one." }
$Output = [IO.Path]::GetFullPath($Output)
Remove-Item $Output -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $Output -Force | Out-Null
$archives = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives'))
$tidy = Join-Path $archives 'tidy-5.8.0-win64.zip'
if (-not (Test-Path -LiteralPath $tidy)) { throw "Missing fixed test input: $tidy; run scripts/fetch-deps.ps1" }
$hash = (Get-FileHash -LiteralPath $tidy -Algorithm SHA256).Hash.ToLower()

$root = Join-Path $Output 'root'
foreach ($directory in 'buckets/test/bucket','shims','apps','cache') {
    New-Item -ItemType Directory -Path (Join-Path $root $directory) -Force | Out-Null
}
function Write-Manifest([string]$version) {
    $manifest = [ordered]@{ version=$version; url=([Uri][IO.Path]::GetFullPath($tidy)).AbsoluteUri
        hash=$hash; extract_dir='tidy-5.8.0-win64\bin'; bin='tidy.exe' }
    [IO.File]::WriteAllText("$root/buckets/test/bucket/tidy.json",
        ($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
Write-Manifest '5.8.0'

# Scoop appends its shims to the user PATH on first run; restore whatever was there afterwards.
$pathBefore = [Environment]::GetEnvironmentVariable('Path','User')
$transcript = [System.Collections.Generic.List[string]]::new()
function Invoke-Recorded([string]$label,[string[]]$arguments) {
    $start = [Diagnostics.Stopwatch]::StartNew()
    $out = & $ScoopShim @arguments 2>&1 | ForEach-Object { ($_ -replace "`e",'<ESC>') }
    $code = $LASTEXITCODE
    $start.Stop()
    $transcript.Add("[${label}] scoop $($arguments -join ' ')")
    $transcript.Add("exit=$code seconds=$([Math]::Round($start.Elapsed.TotalSeconds,3))")
    foreach ($line in $out) { $transcript.Add([string]$line) }
    $transcript.Add('')
    Write-Output ("{0}: exit {1} in {2:N1} s" -f $label,$code,$start.Elapsed.TotalSeconds)
}
try {
    $env:SCOOP = $root
    $env:SCOOP_GLOBAL = Join-Path $Output 'global'
    Invoke-Recorded 'install-cold' @('install','tidy')
    Invoke-Recorded 'uninstall' @('uninstall','tidy')
    Invoke-Recorded 'install-cache-hit' @('install','tidy')
    Write-Manifest '5.8.1'
    Invoke-Recorded 'update' @('update','tidy')
    Invoke-Recorded 'reset' @('reset','tidy','@5.8.0')
    Invoke-Recorded 'cleanup' @('cleanup','tidy')
    Invoke-Recorded 'uninstall-final' @('uninstall','tidy')
} finally {
    [Environment]::SetEnvironmentVariable('Path',$pathBefore,'User')
    [IO.File]::WriteAllLines((Join-Path $Output 'transcript.txt'),$transcript,[Text.UTF8Encoding]::new($false))
}
Write-Output "transcript: $(Join-Path $Output 'transcript.txt')"

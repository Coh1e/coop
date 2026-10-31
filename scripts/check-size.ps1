# Guards the bytes a user gets on disk, which is the size decision recorded in
# docs/adr/0005-binary-size-build-only.md. The download zip is printed when a caller passes one, but
# it has no threshold: it is a record, not a gate.
#
# The limit is the CI measurement taken after /O1 landed (4,597,280 B), times 1.1. The CI run is
# linked from docs/performance-support.md; do not replace it with an unrecorded local number.
param(
    [string]$BuildRoot = (Join-Path $PSScriptRoot '../.local/build'),
    [string]$ZipPath,
    [int]$LimitBytes = 5057008
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)

# The release layout from .github/workflows/release.yml. Every entry must exist, so a guard cannot
# pass on a half-populated build directory.
$components = [ordered]@{
    'coop.exe'       = Join-Path $BuildRoot 'coop.exe'
    'scoop-lib'      = Join-Path $BuildRoot 'scoop-lib'
    'licenses'       = Join-Path $BuildRoot 'licenses'
    'LICENSE'        = Join-Path $projectRoot 'LICENSE'
    'THIRD_PARTY.md' = Join-Path $projectRoot 'THIRD_PARTY.md'
}

$total = [long]0
$rows = foreach ($name in $components.Keys) {
    $path = $components[$name]
    if (-not (Test-Path -LiteralPath $path)) {
        throw "the release layout is missing $path"
    }
    $item = Get-Item -LiteralPath $path -Force
    $bytes = [long]0
    if ($item.PSIsContainer) {
        $measured = Get-ChildItem -LiteralPath $path -Recurse -File -Force |
            Measure-Object -Property Length -Sum
        if ($null -ne $measured.Sum) { $bytes = [long]$measured.Sum }
    } else {
        $bytes = [long]$item.Length
    }
    $total += $bytes
    [pscustomobject]@{ Component = $name; Bytes = $bytes }
}
$rows | Format-Table -AutoSize | Out-String | Write-Output
Write-Output ('installed footprint: {0:N0} B (limit {1:N0} B)' -f $total, $LimitBytes)

if ($PSBoundParameters.ContainsKey('ZipPath')) {
    if (-not (Test-Path -LiteralPath $ZipPath)) { throw "the zip is missing: $ZipPath" }
    Write-Output ('download zip: {0:N0} B (reported only, no threshold)' -f (Get-Item -LiteralPath $ZipPath).Length)
}

if ($total -gt $LimitBytes) {
    Write-Output ('check-size: installed footprint exceeds the limit by {0:N0} B' -f ($total - $LimitBytes))
    exit 1
}
Write-Output 'check-size: within the limit'
exit 0

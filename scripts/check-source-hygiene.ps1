param(
    [string]$Root = (Join-Path $PSScriptRoot '..'),
    [switch]$Staged
)
# Fast, deterministic source hygiene: a UTF-8 byte-order mark or mixed line endings inside one file
# shows up as an invisible rewrite (a three-line change becomes a whole-file diff) and is easy to
# produce by accident when a script writes a file back with the wrong encoding.
#
# Deliberate whole-file line-ending conversion is not detected here: it stays a review concern. The
# aim is to catch the invisible, accidental class that has actually happened.
$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($Root)
Push-Location $Root
try {
    $files = if ($Staged) {
        @(git diff --cached --name-only --diff-filter=ACM)
    } else {
        @(git ls-files)
    }
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { throw 'git could not list files' }

$violations = New-Object System.Collections.ArrayList
# Pre-existing exceptions, each with the reason it is tolerated. This is a burn-down list: shrink it,
# never grow it. A file listed here is not re-checked until it is removed from the list.
$allowed = @{
    'src/ir_plan.cpp' = 'pre-existing mixed line endings; normalising it is a separate change'
}
foreach ($relative in $files) {
    if (-not $relative) { continue }
    if ($allowed.ContainsKey($relative)) { continue }
    $path = Join-Path $Root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    $info = Get-Item -LiteralPath $path
    if ($info.Length -eq 0) { continue }
    $stream = [IO.File]::OpenRead($path)
    try {
        $head = New-Object byte[] ([Math]::Min(8192,$info.Length))
        $read = $stream.Read($head,0,$head.Length)
    } finally { $stream.Dispose() }

    # Binary files are out of scope; a NUL byte in the first block is the usual tell.
    $binary = $false
    for ($i = 0; $i -lt $read; $i++) { if ($head[$i] -eq 0) { $binary = $true; break } }
    if ($binary) { continue }

    if ($read -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) {
        [void]$violations.Add("$relative : starts with a UTF-8 byte-order mark")
        continue
    }

    $text = [IO.File]::ReadAllText($path)
    $crlf = ([regex]::Matches($text,"`r`n")).Count
    $loneLf = ([regex]::Matches($text,"(?<!`r)`n")).Count
    if ($crlf -gt 0 -and $loneLf -gt 0) {
        [void]$violations.Add("$relative : mixes CRLF ($crlf) and LF ($loneLf) line endings")
    }

    # Durability belongs to one counted seam. A raw FlushFileBuffers anywhere else is invisible to the
    # timing record and to sync_points, so the rule keeps "how many flushes does a run perform"
    # answerable instead of letting a regression hide behind an uncounted call.
    if ($relative -like '*.cpp' -and $relative -ne 'src/data.cpp' -and $text -match 'FlushFileBuffers') {
        [void]$violations.Add("$relative : calls FlushFileBuffers directly; use durable_flush() from data.hpp")
    }
}

if ($violations.Count -gt 0) {
    [Console]::Error.WriteLine('Source hygiene check failed:')
    foreach ($violation in $violations) { [Console]::Error.WriteLine("  $violation") }
    [Console]::Error.WriteLine('Rewrite the file without a byte-order mark, or with one consistent line ending.')
    exit 1
}
Write-Output "source hygiene: $($files.Count) files checked"
exit 0

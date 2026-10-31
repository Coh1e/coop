param(
    [string]$Root = (Join-Path $PSScriptRoot '..'),
    [switch]$Staged
)
# Every relative link in a tracked Markdown file must resolve to a real path. External URLs, anchors
# and mailto links are out of scope; fenced blocks and inline code are stripped first because they
# contain examples rather than links. There is no allowlist: a stale link is either fixed or removed.
$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($Root)
Push-Location $Root
try {
    $files = if ($Staged) {
        @(git diff --cached --name-only --diff-filter=ACM -- '*.md')
    } else {
        @(git ls-files '*.md')
    }
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) { throw 'git could not list Markdown files' }

$violations = New-Object System.Collections.ArrayList
$linked = 0
$skipped = 0
foreach ($relative in $files) {
    if (-not $relative) { continue }
    $path = Join-Path $Root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }

    # Remove fenced code blocks line by line; a fence may use backticks or tildes.
    $visible = New-Object System.Text.StringBuilder
    $fence = $null
    $text = [IO.File]::ReadAllText($path)
    foreach ($line in $text -split "`n") {
        $trimmed = $line.TrimStart()
        if ($trimmed.StartsWith('```') -or $trimmed.StartsWith('~~~')) {
            $marker = $trimmed.Substring(0,3)
            if ($null -eq $fence) { $fence = $marker }
            elseif ($marker -eq $fence) { $fence = $null }
            continue
        }
        if ($null -ne $fence) { continue }
        [void]$visible.AppendLine($line)
    }
    $body = [regex]::Replace($visible.ToString(),'`[^`\r\n]*`','')

    foreach ($match in [regex]::Matches($body,'!?\[[^\]]*\]\(\s*(<[^>]*>|[^)\s]+)(?:\s+(?:"[^"]*"|''[^'']*''))?\s*\)')) {
        $target = $match.Groups[1].Value
        if ($target.StartsWith('<') -and $target.EndsWith('>')) {
            $target = $target.Substring(1,$target.Length-2)
        }
        if ($target -match '^(?i)(https?:|mailto:|#|//|www\.)') { $skipped++; continue }
        $target = ($target -split '[#?]',2)[0]
        if ([string]::IsNullOrWhiteSpace($target)) { $skipped++; continue }
        try { $target = [Uri]::UnescapeDataString($target) } catch { } # Invalid escape: keep the literal text.
        # Absolute local paths are not repository links; leave them to the document that uses them.
        if ($target -match '^[A-Za-z]:[\\/]' -or $target.StartsWith('\\')) { $skipped++; continue }

        $linked++
        $resolved = if ($target.StartsWith('/')) {
            Join-Path $Root $target.TrimStart('/')
        } else {
            Join-Path (Split-Path -Path $path -Parent) $target
        }
        $resolved = [IO.Path]::GetFullPath($resolved)
        if (-not (Test-Path -LiteralPath $resolved)) {
            [void]$violations.Add("$relative -> $target")
        }
    }
}

if ($violations.Count -gt 0) {
    [Console]::Error.WriteLine('Documentation link check failed:')
    foreach ($violation in $violations) { [Console]::Error.WriteLine("  $violation") }
    exit 1
}
Write-Output "documentation links: $linked relative links in $($files.Count) Markdown files checked ($skipped external or anchor-only links skipped)"
exit 0

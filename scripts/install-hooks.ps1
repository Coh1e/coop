param([string]$Root = (Join-Path $PSScriptRoot '..'))
# Installs the repository's git hooks into .git/hooks, which is not versioned. Re-running is safe.
$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($Root)
$hooks = Join-Path $Root '.git/hooks'
if (-not (Test-Path -LiteralPath $hooks)) { throw "Not a git working tree: $Root" }

# The hook itself must stay LF-only and BOM-free: sh refuses a CRLF shebang line.
$hook = @"
#!/bin/sh
root=`$(git rev-parse --show-toplevel)
exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "`$root/scripts/pre-commit.ps1"
"@
$target = Join-Path $hooks 'pre-commit'
[IO.File]::WriteAllText($target, ($hook -replace "`r`n","`n"), [Text.UTF8Encoding]::new($false))
Write-Output "installed $target"

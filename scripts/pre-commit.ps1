$ErrorActionPreference = 'Stop'
# Pre-commit guardrail: only checks that finish in a second or two. The full CTest suite stays a
# deliberate step (scripts/build.ps1 -Action test), because a slow hook gets bypassed with
# --no-verify and then protects nothing.
& (Join-Path $PSScriptRoot 'check-source-hygiene.ps1') -Staged
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Push-Location $Root
try { git diff --cached --check } finally { Pop-Location }
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine('git diff --check reported whitespace errors in the staged changes.')
    exit 1
}
exit 0

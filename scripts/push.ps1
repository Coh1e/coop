# Pushes to GitHub with the credential path that works on this machine.
#
# A bare `git push` fails before any network work: the configured credential helper is Git Credential
# Manager, which cannot acquire a schannel credential non-interactively (SEC_E_NO_CREDENTIALS).
# Switching the helper to `gh auth git-credential` trades that for a different failure: the helper
# runs through sh.exe, which fails under the sandbox with "couldn't create signal pipe, Win32 error 5".
# Passing the token as an HTTP header skips the helper entirely.
#
# Usage: ./scripts/push.ps1 [<git push arguments>]
#   ./scripts/push.ps1                      # push the current branch to its upstream
#   ./scripts/push.ps1 origin main v0.3.0   # same arguments as git push
#
# $ErrorActionPreference stays at its default on purpose: git writes progress to stderr, and Stop
# would turn that into a terminating error before the exit code could be returned. The exit code is
# the only success signal here, as CODING_STANDARDS.md requires for native commands.
param(
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$PushArgs
)

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine('push: gh is not installed; install it before pushing')
    exit 1
}
$token = (& gh auth token 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $token) {
    [Console]::Error.WriteLine('push: `gh auth token` failed; run `gh auth login` first')
    exit 1
}
$header = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$token"))
$env:GIT_CONFIG_COUNT = '2'
$env:GIT_CONFIG_KEY_0 = 'http.sslBackend'; $env:GIT_CONFIG_VALUE_0 = 'openssl'
$env:GIT_CONFIG_KEY_1 = 'http.https://github.com/.extraheader'; $env:GIT_CONFIG_VALUE_1 = "AUTHORIZATION: basic $header"

Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    & git push @PushArgs 2>&1 | ForEach-Object { Write-Host "$_" }
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
}
exit $exitCode

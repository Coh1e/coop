# Red when: Coop's default private state stops living under
# %USERPROFILE%\.coop\roots\<root-name>-<sha256-prefix>, or an install writes <root>\.coop again.
param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null
$source = [IO.Path]::GetFullPath($CoopExe)
$manifest = @{version='1.0.0';url=([Uri]$source).AbsoluteUri+'#/fixture.exe';
    hash=(Get-FileHash $source -Algorithm SHA256).Hash.ToLower();bin='fixture.exe'} | ConvertTo-Json
[IO.File]::WriteAllText("$root/buckets/test/bucket/fixture.json",$manifest,[Text.UTF8Encoding]::new($false))

$profile = Join-Path $TestRoot 'profile'
New-Item -ItemType Directory -Path $profile -Force | Out-Null
$savedProfile = $env:USERPROFILE
$savedState = $env:COOP_STATE_DIR
try {
    # Exercise the machine-level default, not the CTest pin.
    $env:USERPROFILE = $profile
    Remove-Item Env:COOP_STATE_DIR -ErrorAction SilentlyContinue
    $install = Invoke-CoopNative $CoopExe --root $root install test/fixture --json
    if ($LASTEXITCODE -ne 0) { throw "default-location install failed: $($install -join [Environment]::NewLine)" }

    $digest = [BitConverter]::ToString(
        [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($root))).Replace('-','').ToLower().Substring(0,8)
    $state = Join-Path $profile ".coop\roots\$(Split-Path $root -Leaf)-$digest"
    if (-not (Test-Path -LiteralPath "$state/packages/fixture.json")) {
        throw "install did not write its package record under the default state directory: $state"
    }
    if (Test-Path -LiteralPath "$root/.coop") { throw 'install left a .coop directory inside the Scoop root' }

    $list = Invoke-CoopNative $CoopExe --root $root list --json
    if ($LASTEXITCODE -ne 0 -or ($list -join "`n") -notmatch '"management"\s*:\s*"managed"') {
        throw "the externalized record was not visible to list: $($list -join [Environment]::NewLine)"
    }
} finally {
    $env:USERPROFILE = $savedProfile
    if ($savedState) { $env:COOP_STATE_DIR = $savedState } else { Remove-Item Env:COOP_STATE_DIR -ErrorAction SilentlyContinue }
}
Write-Output "PASS default state location: $root"
exit 0

param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$fixture1 = Join-Path (Split-Path $CoopExe) 'fixture-1.exe'
$fixture2 = Join-Path (Split-Path $CoopExe) 'fixture-2.exe'
$persist1 = Join-Path (Split-Path $CoopExe) 'persist-fixture-1.exe'
$persist2 = Join-Path (Split-Path $CoopExe) 'persist-fixture-2.exe'
function Run-Json([string[]]$Arguments) {
    $text = Invoke-CoopNative $CoopExe  @Arguments
    $code = $LASTEXITCODE
    $value = $null
    $joined = $text -join "`n"
    if ($joined.Trim().StartsWith('[') -or $joined.Trim().StartsWith('{')) {
        try { $value = $joined | ConvertFrom-Json } catch { $value = $null }
    }
    [pscustomobject]@{code=$code; text=$joined; value=$value}
}
function Write-Manifest([string]$root,[string]$name,[string]$version,[string]$source,[object]$Extra = $null) {
    $value = @{version=$version;url=([Uri][IO.Path]::GetFullPath($source)).AbsoluteUri+"#/$name.exe";hash=(Get-FileHash $source -Algorithm SHA256).Hash.ToLower();bin="$name.exe"}
    if ($null -ne $Extra) { foreach ($key in $Extra.Keys) { $value[$key] = $Extra[$key] } }
    [IO.File]::WriteAllText((Join-Path $root "buckets/test/bucket/$name.json"),($value | ConvertTo-Json -Depth 8))
}
function Remove-Junction([string]$Path) {
    & $env:ComSpec /d /s /c "rmdir `"$Path`"" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "cannot remove junction $Path" }
}
function Last-Journal([string]$root,[string]$package,[string]$action) {
    $entries = @(Get-ChildItem "$root/.coop/transactions" -Directory | Sort-Object LastWriteTime)
    for ($index = $entries.Count-1; $index -ge 0; --$index) {
        $journal = Get-Content -LiteralPath (Join-Path $entries[$index].FullName 'journal.json') -Raw | ConvertFrom-Json
        if ($journal.package -eq $package -and $journal.action -eq $action) { return $journal }
    }
    throw "no $action journal for $package"
}

# Rollback uses only the local version directory: the bucket Manifest is removed before the reset,
# so a download or a guessed URL would fail instead of silently succeeding.
$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null
Write-Manifest $root 'rollback' '1' $fixture1
$install = Run-Json @('--root',$root,'install','test/rollback','--json')
if ($install.code -ne 0) { throw "rollback fixture install failed: $($install.text)" }
Write-Manifest $root 'rollback' '2' $fixture2
$update = Run-Json @('--root',$root,'update','rollback','--json')
if ($update.code -ne 0 -or (& "$root/shims/rollback.exe") -ne 'fixture 2') { throw "rollback fixture update failed: $($update.text)" }
Remove-Item -LiteralPath "$root/buckets/test/bucket/rollback.json" -Force
$preview = Run-Json @('--root',$root,'reset','rollback@1','--dry-run','--json')
if ($preview.code -ne 0) { throw "reset preview failed without a bucket Manifest: $($preview.text)" }
if ($preview.value.action -ne 'reset' -or $preview.value.package.version -ne '1' -or $preview.value.current_version -ne '2') {
    throw "reset preview did not identify the local target and current version: $($preview.text)"
}
if ($preview.value.execution_available -ne $true -or $preview.value.retained_versions -notcontains '2') {
    throw "reset preview was not executable or omitted the version it will retain: $($preview.text)"
}
if ($preview.value.local_version_reference.network -ne 'none' -or $preview.value.local_version_reference.download_url_guessed -ne $false -or
    $preview.value.local_version_reference.lifecycle_hooks -ne 'not-run') {
    throw "reset preview did not disclose its local-only, no-hook scope: $($preview.text)"
}
$planned = @($preview.value.ir_operations | ForEach-Object operation)
if ($planned -contains 'download' -or $planned -contains 'verify' -or $planned -contains 'extract' -or $planned -notcontains 'publish-current') {
    throw "reset plan did not describe a local republish: $($planned -join ',')"
}
if ((& "$root/shims/rollback.exe") -ne 'fixture 2' -or -not (Test-Path "$root/apps/rollback/1/rollback.exe")) {
    throw 'reset preview changed the current program or removed the retained version'
}
$reset = Run-Json @('--root',$root,'reset','rollback@1','--json')
if ($reset.code -ne 0) { throw "reset failed without a bucket Manifest: $($reset.text)" }
if ((& "$root/shims/rollback.exe") -ne 'fixture 1') { throw 'reset did not run the retained program' }
if ($reset.value.reset_from -ne '2' -or $reset.value.data_rollback -ne 'none' -or $reset.value.retained_versions -notcontains '2') {
    throw "reset result did not report program rollback separately from data: $($reset.text)"
}
if (-not (Test-Path "$root/apps/rollback/2/rollback.exe")) { throw 'reset deleted the replaced version' }
$journal = Last-Journal $root 'rollback' 'reset'
if ((@($journal.observed_steps) -join ',') -ne ($planned -join ',')) {
    throw "reset execution did not follow the displayed plan: planned=$($planned -join ',') observed=$($journal.observed_steps -join ',')"
}
$list = Run-Json @('--root',$root,'list','--json')
$item = @($list.value | Where-Object name -eq 'rollback')[0]
if ($item.version -ne '1' -or $item.older_versions -notcontains '2') { throw 'query did not report the rolled-back version and its retained replacement' }

# Cleanup preview and execution use the same verified scope; the current version is never a target.
$cleanupPreview = Run-Json @('--root',$root,'cleanup','rollback','--dry-run','--json')
if ($cleanupPreview.code -ne 0) { throw "cleanup preview failed: $($cleanupPreview.text)" }
$scope = @($cleanupPreview.value[0].delete_scope)
if ($scope.Count -ne 1 -or $scope[0].version -ne '2' -or
    [IO.Path]::GetFullPath($scope[0].directory) -ne [IO.Path]::GetFullPath("$root/apps/rollback/2")) {
    throw "cleanup preview did not list exactly the retained version: $($cleanupPreview.text)"
}
if (@($cleanupPreview.value[0].keep_scope | Where-Object version -eq '1').Count -ne 1) {
    throw 'cleanup preview did not explain why the current version is kept'
}
$cleanup = Run-Json @('--root',$root,'cleanup','rollback','--json')
if ($cleanup.code -ne 0 -or (Test-Path "$root/apps/rollback/2") -or -not (Test-Path "$root/apps/rollback/1/rollback.exe")) {
    throw "cleanup did not remove exactly the previewed version: $($cleanup.text)"
}
if ((@($cleanup.value[0].removed | ForEach-Object directory) | ForEach-Object { [IO.Path]::GetFullPath($_) }) -notcontains [IO.Path]::GetFullPath("$root/apps/rollback/2")) {
    throw 'cleanup result did not identify the removed path'
}
if ((& "$root/shims/rollback.exe") -ne 'fixture 1') { throw 'cleanup broke the current rollback version' }

# Unknown, missing and tampered local versions are refused; the current program stays untouched.
$root2 = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root2/buckets/test/bucket" -Force | Out-Null
Write-Manifest $root2 'refuse' '1' $fixture1
if ((Run-Json @('--root',$root2,'install','test/refuse','--json')).code -ne 0) { throw 'refuse fixture install failed' }
Write-Manifest $root2 'refuse' '2' $fixture2
if ((Run-Json @('--root',$root2,'update','refuse','--json')).code -ne 0) { throw 'refuse fixture update failed' }
$unknown = Run-Json @('--root',$root2,'reset','refuse@99','--json')
if ($unknown.code -eq 0 -or (& "$root2/shims/refuse.exe") -ne 'fixture 2') { throw "reset accepted a missing local version: $($unknown.text)" }
$current = Run-Json @('--root',$root2,'reset','refuse@2','--json')
if ($current.code -eq 0 -or (& "$root2/shims/refuse.exe") -ne 'fixture 2') { throw "reset accepted the already-current version: $($current.text)" }
Set-Content -LiteralPath "$root2/apps/refuse/1/later-user-file.txt" -Value 'changed' -NoNewline
$tampered = Run-Json @('--root',$root2,'reset','refuse@1','--json')
if ($tampered.code -eq 0 -or (& "$root2/shims/refuse.exe") -ne 'fixture 2' -or
    -not (Test-Path "$root2/apps/refuse/1/later-user-file.txt")) {
    throw "reset accepted a modified retained version: $($tampered.text)"
}
Remove-Item -LiteralPath "$root2/apps/refuse/1/later-user-file.txt" -Force
Remove-Item -LiteralPath "$root2/apps/refuse/1/scoop-manifest.json" -Force
$manifestMissing = Run-Json @('--root',$root2,'reset','refuse@1','--json')
if ($manifestMissing.code -eq 0 -or (& "$root2/shims/refuse.exe") -ne 'fixture 2') {
    throw "reset accepted a retained version without its saved Manifest: $($manifestMissing.text)"
}
New-Item -ItemType Directory -Path "$root2/outside" -Force | Out-Null
New-Item -ItemType Junction -Path "$root2/apps/refuse/0" -Target "$root2/outside" | Out-Null
$reparse = Run-Json @('--root',$root2,'reset','refuse@0','--json')
if ($reparse.code -eq 0 -or (& "$root2/shims/refuse.exe") -ne 'fixture 2') { throw "reset followed a reparse-point version: $($reparse.text)" }

# Persistence links are verified in place: store data and file identity are not moved or recreated.
$root3 = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root3/buckets/test/bucket","$root3/persist/persistroll/config","$root3/outside" -Force | Out-Null
Set-Content -LiteralPath "$root3/persist/persistroll/config/settings.ini" -Value 'owner-data' -NoNewline
$mapping = @('config')
Write-Manifest $root3 'persistroll' '1' $persist1 @{persist=$mapping}
if ((Run-Json @('--root',$root3,'install','test/persistroll','--json')).code -ne 0) { throw 'persistence fixture install failed' }
Write-Manifest $root3 'persistroll' '2' $persist2 @{persist=$mapping}
if ((Run-Json @('--root',$root3,'update','persistroll','--json')).code -ne 0) { throw 'persistence fixture update failed' }
$store = "$root3/persist/persistroll/config"
$storeHash = (Get-FileHash -LiteralPath "$store/settings.ini" -Algorithm SHA256).Hash
$persistReset = Run-Json @('--root',$root3,'reset','persistroll@1','--json')
if ($persistReset.code -ne 0) { throw "reset with persistence failed: $($persistReset.text)" }
if ((& "$root3/shims/persistroll.exe") -notmatch '^persist-fixture 1') { throw 'persistence reset ran the wrong version' }
if ((Get-FileHash -LiteralPath "$store/settings.ini" -Algorithm SHA256).Hash -ne $storeHash) { throw 'reset changed stored data' }
$link = Get-Item -LiteralPath "$root3/apps/persistroll/1/config" -Force
if ($link.LinkType -ne 'Junction' -or
    [IO.Path]::GetFullPath((@($link.Target)[0])) -ne [IO.Path]::GetFullPath($store)) { throw 'reset did not keep the declared persistence link' }
if (@($persistReset.value.persistence | Where-Object { $_.ownership -ne 'verified' -or $_.data_retained -ne $true }).Count -ne 0) {
    throw "reset did not verify the reused persistence mapping: $($persistReset.text)"
}
# A retargeted or missing retained link blocks rollback instead of deleting or recreating data.
Remove-Junction "$root3/apps/persistroll/2/config"
New-Item -ItemType Junction -Path "$root3/apps/persistroll/2/config" -Target "$root3/outside" | Out-Null
$retarget = Run-Json @('--root',$root3,'reset','persistroll@2','--json')
if ($retarget.code -eq 0 -or (& "$root3/shims/persistroll.exe") -notmatch '^persist-fixture 1' -or
    -not (Test-Path "$store/settings.ini") -or -not (Test-Path "$root3/outside")) {
    throw "reset accepted a retargeted retained persistence link: $($retarget.text)"
}
Remove-Junction "$root3/apps/persistroll/2/config"
New-Item -ItemType Junction -Path "$root3/apps/persistroll/2/config" -Target $store | Out-Null
Remove-Junction "$root3/apps/persistroll/1/config"
$missingLink = Run-Json @('--root',$root3,'reset','persistroll@1','--json')
if ($missingLink.code -eq 0 -or -not (Test-Path "$store/settings.ini")) {
    throw "reset silently recreated a missing persistence link: $($missingLink.text)"
}

# Scoop's reset does not run install hooks; a rollback must not replay arbitrary script effects.
$root4 = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root4/buckets/test/bucket" -Force | Out-Null
$hook = 'Add-Content -LiteralPath (Join-Path $dir ''hook-ran.txt'') -Value $version'
Write-Manifest $root4 'hookroll' '1' $fixture1 @{pre_install=$hook}
if ((Run-Json @('--root',$root4,'install','test/hookroll','--json')).code -ne 0) { throw 'hook fixture install failed' }
Write-Manifest $root4 'hookroll' '2' $fixture2 @{pre_install=$hook}
if ((Run-Json @('--root',$root4,'update','hookroll','--json')).code -ne 0) { throw 'hook fixture update failed' }
if ((Get-Content -LiteralPath "$root4/apps/hookroll/1/hook-ran.txt" -Raw).Trim() -ne '1') { throw 'pre_install did not run for the first version' }
if ((Get-Content -LiteralPath "$root4/apps/hookroll/2/hook-ran.txt" -Raw).Trim() -ne '2') { throw 'pre_install did not run for the second version' }
$hookReset = Run-Json @('--root',$root4,'reset','hookroll@1','--json')
if ($hookReset.code -ne 0) { throw "hook fixture reset failed: $($hookReset.text)" }
if ((Get-Content -LiteralPath "$root4/apps/hookroll/1/hook-ran.txt" -Raw).Trim() -ne '1') {
    throw 'reset re-ran the install hook instead of only republishing the retained version'
}
if ($hookReset.value.lifecycle_hooks -ne 'not-run') { throw 'reset did not state that lifecycle hooks were not run' }

# A local version without any Coop private version record is still usable when its saved
# Manifest, installation record and actual artifact agree. Rollback does not require adoption.
$root5 = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root5/buckets/test/bucket" -Force | Out-Null
Write-Manifest $root5 'localonly' '1' $fixture1
if ((Run-Json @('--root',$root5,'install','test/localonly','--json')).code -ne 0) { throw 'local-only fixture install failed' }
Write-Manifest $root5 'localonly' '2' $fixture2
if ((Run-Json @('--root',$root5,'update','localonly','--json')).code -ne 0) { throw 'local-only fixture update failed' }
Copy-Item -LiteralPath "$root5/apps/localonly/1" -Destination "$root5/apps/localonly/3" -Recurse
$savedManifest = Get-Content -LiteralPath "$root5/apps/localonly/3/scoop-manifest.json" -Raw | ConvertFrom-Json
$savedManifest.version = '3'
$savedManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$root5/apps/localonly/3/scoop-manifest.json" -Encoding utf8
# Remove Coop's private record: shared installation facts must be enough for a local rollback.
Remove-Item -LiteralPath "$root5/.coop/packages/localonly.json" -Force
$localOnly = Run-Json @('--root',$root5,'reset','localonly@3','--json')
if ($localOnly.code -ne 0 -or $localOnly.value.version -ne '3') {
    throw "reset did not accept a reliable unrecorded local version: $($localOnly.text)"
}
$currentHash = (Get-FileHash -LiteralPath "$root5/apps/localonly/3/localonly.exe" -Algorithm SHA256).Hash
if ($currentHash -ne (Get-FileHash -LiteralPath "$root5/apps/localonly/1/localonly.exe" -Algorithm SHA256).Hash) {
    throw 'reset changed the retained local version files'
}
$localCleanup = Run-Json @('--root',$root5,'cleanup','localonly','--dry-run','--json')
if (@($localCleanup.value[0].delete_scope | Where-Object version -eq '3').Count -ne 0 -or
    @($localCleanup.value[0].current | Where-Object version -eq '3').Count -ne 1) {
    throw "cleanup did not protect the unrecorded current version: $($localCleanup.text)"
}

# Environment declarations are reconciled in one step: rollback applies the retained version's
# values, while a value the user changed after Coop wrote it is preserved.
$root6 = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root6/buckets/test/bucket" -Force | Out-Null
$envName = 'COOP_R15_ENV_'+([guid]::NewGuid().ToString('N').Substring(0,8))
$envKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$true)
$envOriginal = $envKey.GetValue($envName,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
function Set-TestEnvironment([string]$value) { $envKey.SetValue($envName,$value,[Microsoft.Win32.RegistryValueKind]::String) }
function Get-TestEnvironment { return $envKey.GetValue($envName,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
try {
    Set-TestEnvironment 'pre-existing-user-value'
    Write-Manifest $root6 'envroll' '1' $fixture1 @{env_set=[ordered]@{$envName='old-value'}}
    if ((Run-Json @('--root',$root6,'install','test/envroll','--json')).code -ne 0) { throw 'environment fixture install failed' }
    if ((Get-TestEnvironment) -ne 'old-value') { throw 'install did not write the declared environment value' }
    Write-Manifest $root6 'envroll' '2' $fixture2 @{env_set=[ordered]@{$envName='new-value'}}
    if ((Run-Json @('--root',$root6,'update','envroll','--json')).code -ne 0) { throw 'environment fixture update failed' }
    if ((Get-TestEnvironment) -ne 'new-value') { throw 'update did not replace the declared environment value' }
    $envReset = Run-Json @('--root',$root6,'reset','envroll@1','--json')
    if ($envReset.code -ne 0 -or (Get-TestEnvironment) -ne 'old-value') {
        throw "reset did not apply the retained version's environment value: $($envReset.text)"
    }
    Set-TestEnvironment 'user-edited-value'
    $envKeep = Run-Json @('--root',$root6,'reset','envroll@2','--json')
    if ($envKeep.code -ne 0 -or (Get-TestEnvironment) -ne 'user-edited-value') {
        throw "reset overwrote a user-edited environment value: $($envKeep.text)"
    }
    $envKeepAgain = Run-Json @('--root',$root6,'reset','envroll@1','--json')
    if ($envKeepAgain.code -ne 0 -or (Get-TestEnvironment) -ne 'user-edited-value') {
        throw "a later reset overwrote the user-edited environment value: $($envKeepAgain.text)"
    }
} finally {
    if ($null -eq $envOriginal) { $envKey.DeleteValue($envName,$false) } else { Set-TestEnvironment ([string]$envOriginal) }
    $envKey.Dispose()
}

@{rollback_root=$root;refuse_root=$root2;persistence_root=$root3;hook_root=$root4;local_only_root=$root5;environment_root=$root6;coop=$CoopExe} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $TestRoot 'old-versions-evidence.json') -Encoding utf8
Write-Output "PASS local-version rollback, cleanup scope, persisted-link and no-hook behavior: $TestRoot"
exit 0

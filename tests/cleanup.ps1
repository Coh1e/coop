param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
function Manifest([string]$Root,[string]$Name,[string]$Version,[string]$Source,[object]$Persist = $null) {
    $value = @{version=$Version;url=([Uri][IO.Path]::GetFullPath($Source)).AbsoluteUri+"#/$Name.exe";hash=(Get-FileHash $Source -Algorithm SHA256).Hash.ToLower();bin="$Name.exe"}
    if ($null -ne $Persist) { $value.persist = $Persist }
    [IO.File]::WriteAllText((Join-Path $Root "buckets/test/bucket/$Name.json"),($value | ConvertTo-Json -Depth 6))
}
function Run-Json([string[]]$Arguments) {
    $text = & $CoopExe @Arguments 2>&1
    $code = $LASTEXITCODE
    $value = $null
    if (($text -join "`n").Trim().StartsWith('[') -or ($text -join "`n").Trim().StartsWith('{')) {
        try { $value = ($text -join "`n") | ConvertFrom-Json } catch { $value = $null }
    }
    [pscustomobject]@{code=$code; text=($text -join "`n"); value=$value}
}
function Remove-Junction([string]$Path) {
    & $env:ComSpec /d /s /c "rmdir `"$Path`"" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "cannot remove junction $Path" }
}

# Old-version query, cleanup, protection and explicit non-following behavior.
$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null
$fixture1 = Join-Path (Split-Path $CoopExe) 'fixture-1.exe'
$fixture2 = Join-Path (Split-Path $CoopExe) 'fixture-2.exe'
Manifest $root 'cleanupfixture' '1' $fixture1
$install = Run-Json @('--root',$root,'install','test/cleanupfixture','--json')
if ($install.code -ne 0) { throw "cleanup fixture install failed: $($install.text)" }
Manifest $root 'cleanupfixture' '2' $fixture2
$update = Run-Json @('--root',$root,'update','cleanupfixture','--json')
if ($update.code -ne 0 -or (& "$root/apps/cleanupfixture/1/cleanupfixture.exe") -ne 'fixture 1') { throw "cleanup fixture update failed: $($update.text)" }
$listed = Run-Json @('--root',$root,'list','--json')
if ($listed.code -ne 0) { throw 'list failed' }
$item = @($listed.value | Where-Object name -eq 'cleanupfixture')[0]
if ('1' -notin @($item.older_versions)) { throw 'list did not retain the old version name' }
$old = @($item.old_versions | Where-Object version -eq '1')[0]
if ($old.status -ne 'cleanable' -or $old.manifest_present -ne $true -or $old.recorded -ne $true) { throw "old version is not queryable as cleanable: $($old | ConvertTo-Json -Compress)" }
$preview = Run-Json @('--root',$root,'cleanup','cleanupfixture','--dry-run','--json')
if ($preview.code -ne 0 -or @($preview.value[0].removable).Count -ne 1 -or -not (Test-Path "$root/apps/cleanupfixture/1/cleanupfixture.exe")) { throw "cleanup preview was not a plan only: $($preview.text)" }
if (@($preview.value[0].delete_scope).Count -ne 1 -or $preview.value[0].delete_scope[0].version -ne '1' -or
    @($preview.value[0].keep_scope | Where-Object status -eq 'kept-current').Count -ne 1) {
    throw "cleanup preview did not list the exact delete and keep scope: $($preview.text)"
}

# A changed local file or manifest must stop deletion rather than trusting stale evidence.
Set-Content -LiteralPath "$root/apps/cleanupfixture/1/added-by-user.txt" -Value 'modified' -NoNewline
$changedContents = Run-Json @('--root',$root,'cleanup','cleanupfixture','--dry-run','--json')
if ($changedContents.code -eq 0 -or @($changedContents.value[0].unmanageable | Where-Object status -eq 'modified').Count -ne 1) { throw "changed old program was not protected: $($changedContents.text)" }
Remove-Item -LiteralPath "$root/apps/cleanupfixture/1/added-by-user.txt" -Force
$manifestPath = "$root/apps/cleanupfixture/1/scoop-manifest.json"
$manifestText = [IO.File]::ReadAllText($manifestPath)
$manifestTime = (Get-Item -LiteralPath $manifestPath).LastWriteTimeUtc
$changedManifest = $manifestText | ConvertFrom-Json
$changedManifest | Add-Member -NotePropertyName description -NotePropertyValue changed
$changedManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8
$changed = Run-Json @('--root',$root,'cleanup','cleanupfixture','--dry-run','--json')
if ($changed.code -eq 0 -or @($changed.value[0].unmanageable | Where-Object status -eq 'modified').Count -ne 1) { throw "changed old version was not protected: $($changed.text)" }
[IO.File]::WriteAllText($manifestPath,$manifestText)
(Get-Item -LiteralPath $manifestPath).LastWriteTimeUtc = $manifestTime

# A pending transaction blocks cleanup before any version directory is moved.
$pending = "$root/.coop/transactions/pending-cleanup-test"
New-Item -ItemType Directory -Path $pending -Force | Out-Null
'{"state":"pending","action":"update","package":"cleanupfixture"}' | Set-Content "$pending/journal.json" -Encoding utf8
$blocked = Run-Json @('--root',$root,'cleanup','cleanupfixture','--json')
if ($blocked.code -eq 0 -or -not (Test-Path "$root/apps/cleanupfixture/1/cleanupfixture.exe") -or
    @($blocked.value[0].delete_scope).Count -ne 0 -or $blocked.value[0].scope_summary.delete -ne 0) {
    throw "pending transaction did not protect old version or clear the delete scope: $($blocked.text)"
}
Remove-Item -LiteralPath $pending -Recurse -Force

# A running old program is not killed. Cleanup either moves it or leaves the whole version in place.
$lock = [IO.File]::Open("$root/apps/cleanupfixture/1/cleanupfixture.exe",[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try {
    $busy = Run-Json @('--root',$root,'cleanup','cleanupfixture','--json')
    if ($busy.code -eq 0) { throw 'cleanup claimed success while the old program was held' }
    foreach ($keptPath in @("$root/apps/cleanupfixture/1/cleanupfixture.exe",
            "$root/apps/cleanupfixture/1/scoop-manifest.json","$root/apps/cleanupfixture/1/scoop-install.json")) {
        if (-not (Test-Path -LiteralPath $keptPath)) { throw "cleanup partially deleted an in-use version: $keptPath" }
    }
} finally { $lock.Dispose() }
$clean = Run-Json @('--root',$root,'cleanup','cleanupfixture','--json')
if ($clean.code -ne 0 -or (Test-Path "$root/apps/cleanupfixture/1") -or (& "$root/shims/cleanupfixture.exe") -ne 'fixture 2') { throw "cleanup did not remove only the old version: $($clean.text)" }
$after = Run-Json @('--root',$root,'list','--json')
if (@($after.value[0].old_versions).Count -ne 0) { throw 'cleanup left stale old-version evidence' }
$again = Run-Json @('--root',$root,'cleanup','cleanupfixture','--json')
if ($again.code -ne 0 -or -not (Test-Path "$root/apps/cleanupfixture/2/cleanupfixture.exe")) { throw 'cleanup removed the current version or failed on an empty old-version set' }

# Unknown ownership and reparse points are reported and never followed.
New-Item -ItemType Directory -Path "$root/apps/cleanupfixture/9","$root/outside" -Force | Out-Null
Set-Content -LiteralPath "$root/apps/cleanupfixture/9/junk.txt" -Value 'not-owned' -NoNewline
Set-Content -LiteralPath "$root/outside/keep.txt" -Value 'outside' -NoNewline
New-Item -ItemType Junction -Path "$root/apps/cleanupfixture/8" -Target "$root/outside" | Out-Null
$unsafe = Run-Json @('--root',$root,'cleanup','cleanupfixture','--json')
if ($unsafe.code -eq 0) { throw 'cleanup claimed success for unowned local directories' }
if (-not (Test-Path "$root/apps/cleanupfixture/9/junk.txt") -or -not (Test-Path "$root/outside/keep.txt")) { throw 'cleanup followed or deleted unowned content' }
$unsafePreview = Run-Json @('--root',$root,'cleanup','cleanupfixture','--dry-run','--json')
if ($unsafePreview.code -eq 0 -or @($unsafePreview.value[0].unmanageable).Count -lt 2) { throw 'unowned or reparse old versions were not queryable as unmanageable' }

# Normal uninstall keeps old versions and retained evidence; cleanup can still remove them later.
$root3 = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root3/buckets/test/bucket" -Force | Out-Null
Manifest $root3 'retainedfixture' '1' $fixture1
$install3 = Run-Json @('--root',$root3,'install','test/retainedfixture','--json')
if ($install3.code -ne 0) { throw "retained fixture install failed: $($install3.text)" }
Manifest $root3 'retainedfixture' '2' $fixture2
$update3 = Run-Json @('--root',$root3,'update','retainedfixture','--json')
if ($update3.code -ne 0) { throw "retained fixture update failed: $($update3.text)" }
# Removing the current junction must not make the recorded current version look like an old
# version. Cleanup blocks before moving anything and leaves the management record unchanged.
$record3 = "$root3/.coop/packages/retainedfixture.json"
$record3Before = [IO.File]::ReadAllText($record3)
Remove-Junction "$root3/apps/retainedfixture/current"
$blockedCurrent = Run-Json @('--root',$root3,'cleanup','retainedfixture','--json')
$blockedCurrentPreview = Run-Json @('--root',$root3,'cleanup','retainedfixture','--dry-run','--json')
if ($blockedCurrent.code -eq 0 -or $blockedCurrent.value[0].status -ne 'blocked' -or
    $blockedCurrentPreview.code -eq 0 -or $blockedCurrentPreview.value[0].status -ne 'blocked' -or
    @($blockedCurrent.value[0].delete_scope).Count -ne 0 -or @($blockedCurrentPreview.value[0].delete_scope).Count -ne 0) {
    throw "cleanup accepted a missing current link with a recorded current version: $($blockedCurrent.text)"
}
if (-not (Test-Path "$root3/apps/retainedfixture/2/retainedfixture.exe") -or
    [IO.File]::ReadAllText($record3) -ne $record3Before) {
    throw 'cleanup deleted or changed the recorded current version while current was missing'
}
New-Item -ItemType Junction -Path "$root3/apps/retainedfixture/current" -Target "$root3/apps/retainedfixture/2" | Out-Null
$remove3 = Run-Json @('--root',$root3,'uninstall','retainedfixture','--json')
if ($remove3.code -ne 0 -or -not (Test-Path "$root3/apps/retainedfixture/1/retainedfixture.exe") -or (Test-Path "$root3/.coop/packages/retainedfixture.json")) { throw "normal uninstall did not retain old version/evidence: $($remove3.text)" }
if (-not (Test-Path "$root3/.coop/retained/retainedfixture.json")) { throw 'normal uninstall did not retain version ownership evidence' }
# An interrupted cleanup that already moved a candidate to its transaction trash is completed by
# the next cleanup invocation instead of leaving a permanently pending cleanup journal.
$interrupted = "$root3/.coop/transactions/interrupted-cleanup"
$interruptedTrash = "$interrupted/0-1"
New-Item -ItemType Directory -Path $interrupted -Force | Out-Null
Move-Item -LiteralPath "$root3/apps/retainedfixture/1" -Destination $interruptedTrash
@{state='pending';action='cleanup';package='retainedfixture';candidates=@(@{version='1';
    from="$root3/apps/retainedfixture/1";trash=$interruptedTrash;moved=$true;recovery=$false})} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$interrupted/journal.json" -Encoding utf8
$recovered = Run-Json @('--root',$root3,'cleanup','retainedfixture','--json')
if ($recovered.code -ne 0 -or (Test-Path "$root3/apps/retainedfixture/1") -or (Test-Path $interruptedTrash)) {
    throw "interrupted cleanup was not completed: $($recovered.text)"
}
$recoveredJournal = Get-Content -LiteralPath "$interrupted/journal.json" -Raw | ConvertFrom-Json
if ($recoveredJournal.state -ne 'committed') { throw 'interrupted cleanup journal was not marked committed' }
$later = Run-Json @('--root',$root3,'cleanup','retainedfixture','--json')
if ($later.code -ne 0 -or (Test-Path "$root3/apps/retainedfixture/1")) { throw "cleanup after normal uninstall failed: $($later.text)" }

# Explicit purge lists the declared store scope, rechecks ownership, and removes only that scope.
$root2 = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root2/buckets/test/bucket","$root2/persist/persistfixture/config","$root2/persist/persistfixture/unrelated","$root2/outside" -Force | Out-Null
$persist1 = Join-Path (Split-Path $CoopExe) 'persist-fixture-1.exe'
$persist2 = Join-Path (Split-Path $CoopExe) 'persist-fixture-2.exe'
Set-Content -LiteralPath "$root2/persist/persistfixture/config/settings.ini" -Value 'owner-data' -NoNewline
Set-Content -LiteralPath "$root2/persist/persistfixture/sample.ini" -Value 'file-data' -NoNewline
Set-Content -LiteralPath "$root2/persist/persistfixture/unrelated/keep.txt" -Value 'unrelated' -NoNewline
$mapping = @(@('config','config'),@('sample.ini','sample.ini'))
Manifest $root2 'persistfixture' '1' $persist1 $mapping
$install2 = Run-Json @('--root',$root2,'install','test/persistfixture','--json')
if ($install2.code -ne 0) { throw "persistence install failed: $($install2.text)" }
Manifest $root2 'persistfixture' '2' $persist2 $mapping
$update2 = Run-Json @('--root',$root2,'update','persistfixture','--json')
if ($update2.code -ne 0) { throw "persistence update failed: $($update2.text)" }
# Old-version cleanup unlinks persistence junctions instead of following into the store. Scoop
# marks persist junctions read-only on the link itself (attrib +R /L) and read-only files must not
# block the unlink either, so the retained version carries the same attributes Scoop creates.
& attrib.exe +R /L "$root2/apps/persistfixture/1/config" | Out-Null
& attrib.exe +R "$root2/apps/persistfixture/1/sample.ini" | Out-Null
if (-not ((Get-Item -LiteralPath "$root2/apps/persistfixture/1/config" -Force).Attributes -band [IO.FileAttributes]::ReadOnly)) { throw 'failed to mark the retained junction read-only' }
$cleanupPersist = Run-Json @('--root',$root2,'cleanup','persistfixture','--json')
if ($cleanupPersist.code -ne 0 -or (Test-Path "$root2/apps/persistfixture/1")) { throw "old-version cleanup with persist links failed: $($cleanupPersist.text)" }
if (-not (Test-Path "$root2/persist/persistfixture/config/settings.ini") -or -not (Test-Path "$root2/persist/persistfixture/sample.ini") -or -not (Test-Path "$root2/persist/persistfixture/unrelated/keep.txt")) { throw 'cleanup followed a persist link and deleted store data' }
$recordPath = "$root2/.coop/packages/persistfixture.json"
$recordBefore = [IO.File]::ReadAllText($recordPath)
$storeConfig = Join-Path $root2 'persist/persistfixture/config'
$storeFile = Join-Path $root2 'persist/persistfixture/sample.ini'
$purgePreview = Run-Json @('--root',$root2,'uninstall','persistfixture','--purge','--dry-run','--json')
if ($purgePreview.code -ne 0) { throw "purge preview failed: $($purgePreview.text)" }
$scope = @($purgePreview.value.purge.scope)
if ($purgePreview.value.purge.status -ne 'planned' -or $scope.Count -ne 2 -or
    @($scope | Where-Object { $_.store -eq $storeConfig }).Count -ne 1 -or
    @($scope | Where-Object { $_.store -eq $storeFile }).Count -ne 1) { throw "purge preview did not list the exact declared scope: $($purgePreview.text)" }
if ([IO.File]::ReadAllText($recordPath) -ne $recordBefore -or -not (Test-Path $storeConfig) -or -not (Test-Path $storeFile)) { throw 'purge preview changed state or data' }

# A retargeted persistence link must stop the dangerous deletion before uninstall.
Remove-Junction "$root2/apps/persistfixture/2/config"
New-Item -ItemType Junction -Path "$root2/apps/persistfixture/2/config" -Target "$root2/persist/persistfixture/unrelated" | Out-Null
$retarget = Run-Json @('--root',$root2,'uninstall','persistfixture','--purge','--json')
if ($retarget.code -eq 0 -or -not (Test-Path "$root2/apps/persistfixture/current/persistfixture.exe") -or -not (Test-Path "$storeConfig/settings.ini")) { throw "retargeted persistence link did not stop purge: $($retarget.text)" }
Remove-Junction "$root2/apps/persistfixture/2/config"
New-Item -ItemType Junction -Path "$root2/apps/persistfixture/2/config" -Target $storeConfig | Out-Null

# A junction inside the declared store is unlinked, never traversed to outside content.
New-Item -ItemType Junction -Path "$storeConfig/outside-link" -Target "$root2/outside" | Out-Null
Set-Content -LiteralPath "$root2/outside/keep.txt" -Value 'outside' -NoNewline
$purge = Run-Json @('--root',$root2,'uninstall','persistfixture','--purge','--json')
if ($purge.code -ne 0) { throw "explicit purge failed: $($purge.text)" }
if ($purge.value.data_retained -ne $false -or $purge.value.purge.status -ne 'deleted' -or @($purge.value.purge.deleted).Count -ne 2) { throw "purge result was not explicit: $($purge.text)" }
if ((Test-Path $storeConfig) -or (Test-Path $storeFile)) { throw 'purge left declared persistent data' }
if (-not (Test-Path "$root2/persist/persistfixture/unrelated/keep.txt") -or -not (Test-Path "$root2/outside/keep.txt")) { throw 'purge deleted content outside the declared scope or followed a junction' }
if (Test-Path $recordPath) { throw 'purge left the management record' }

@{cleanup_root=$root;retained_root=$root3;purge_root=$root2;coop=$CoopExe} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $TestRoot 'cleanup-evidence.json') -Encoding utf8
Write-Output "PASS old-version query/cleanup and explicit persistent-data purge: $TestRoot"
exit 0

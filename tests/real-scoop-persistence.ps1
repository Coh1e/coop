param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$EvidenceDir,
    [string]$ScoopRoot = 'C:\Users\Neo\scoop'
)
# Real persistent-data acceptance (#30). It works on the human-selected shared Scoop root and only
# touches installations that do not exist yet: the existing 7zip persist store is read only, and
# test-created stores for mediamtx, pocketbase and the temporary bucket package are removed again in
# the finally block. The retained persist store of an earlier uninstall (frp, spotbugs, uv) is never
# touched.
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
$allowed = [IO.Path]::GetFullPath((Join-Path $projectRoot '.local')).TrimEnd('\') + '\'
if (-not ($EvidenceDir.TrimEnd('\') + '\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence must stay inside the project .local directory' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$ScoopRoot = [IO.Path]::GetFullPath($ScoopRoot)
$scoop = (Get-Command scoop.ps1 -ErrorAction Stop).Source
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$artifacts = Join-Path $EvidenceDir 'artifacts'
New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
$commands = [System.Collections.Generic.List[object]]::new()
$installedByTest = [System.Collections.Generic.List[string]]::new()
$mediamtxStore = Join-Path $ScoopRoot 'persist/mediamtx'
$pocketbaseStore = Join-Path $ScoopRoot 'persist/pocketbase'
$temporaryStore = Join-Path $ScoopRoot 'persist/coop-r09-files'
$tempBucketName = 'coop-r09-persist'
$tempBucket = Join-Path $ScoopRoot "buckets/$tempBucketName"
$temporaryPackage = 'coop-r09-files'
$sevenStore = Join-Path $ScoopRoot 'persist/7zip'
$testPackages = @('mediamtx','pocketbase',$temporaryPackage)
$testEntries = @{
    mediamtx = @('mediamtx')
    pocketbase = @('pocketbase')
    'coop-r09-files' = @('coop-r09-mediamtx')
}
function Run([string]$name,[string]$exe,[string[]]$arguments,[string]$WorkingDirectory = '') {
    $log = Join-Path $EvidenceDir (($name -replace '[\\/:*?"<>|]','-')+'.log')
    $previous = (Get-Location).Path
    try {
        if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }
        $output = & $exe @arguments *>&1 | Out-String
        $exit = $LASTEXITCODE
    } finally { Set-Location -LiteralPath $previous }
    Set-Content -LiteralPath $log -Value $output -Encoding utf8
    $commands.Add([pscustomobject]@{name=$name;exe=$exe;arguments=$arguments;working_directory=$WorkingDirectory;exit=$exit;log=$log})
    return [pscustomobject]@{exit=$exit;output=$output;log=$log}
}
function Coop([string]$name,[string[]]$arguments) { return Run $name $CoopExe (@('--root',$ScoopRoot)+$arguments) }
function Scoop([string]$name,[string[]]$arguments) { return Run $name $scoop $arguments }
function Assert-True([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
function Read-Json([object]$output) {
    $text = ($output -join "`n")
    $start = $text.IndexOfAny([char[]]@('{','['))
    $end = $text.LastIndexOfAny([char[]]@('}',']'))
    if ($start -lt 0 -or $end -lt $start) { throw "No JSON document in output: $text" }
    return ($text.Substring($start,$end-$start+1) | ConvertFrom-Json)
}
function HashOf([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function File-Id([string]$path) {
    $output = (& fsutil.exe file queryfileid $path 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $output -notmatch '(0x[0-9a-fA-F]+)') { throw "Cannot read the file identity of $path`: $output" }
    return $Matches[1].ToLower()
}
function Link-Target([string]$path,[string]$type) {
    $item = Get-Item -LiteralPath $path -Force
    if ($item.LinkType -ne $type) { throw "$path is '$($item.LinkType)', expected $type" }
    return ([IO.Path]::GetFullPath([string](@($item.Target)[0])).TrimEnd('\'))
}
function Assert-Junction([string]$link,[string]$store) {
    $target = Link-Target $link 'Junction'
    Assert-True ($target -eq ([IO.Path]::GetFullPath($store).TrimEnd('\'))) "$link points to '$target' instead of '$store'"
}
function Assert-HardLink([string]$link,[string]$store) {
    Assert-True ((Get-Item -LiteralPath $link -Force).LinkType -eq 'HardLink') "$link is not a hardlink"
    Assert-True ((File-Id $link) -eq (File-Id $store)) "$link is a different file than the stored data $store"
}
function Store-Snapshot([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return '[]' }
    $entries = @(Get-ChildItem -LiteralPath $path -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($path.Length).TrimStart('\')
        if ($_.PSIsContainer) {
            [pscustomobject]@{relative=$relative;kind='directory';link_type=[string]$_.LinkType;
                target=((@($_.Target) | ForEach-Object { [string]$_ }) -join ';')}
        } else {
            [pscustomobject]@{relative=$relative;kind='file';length=$_.Length;sha256=(HashOf $_.FullName);file_id=(File-Id $_.FullName)}
        }
    })
    return ($entries | ConvertTo-Json -Depth 6 -Compress)
}
function InstalledEntry([string]$name) {
    $items = (Coop ($name+'-list') @('list','--json')).output | ConvertFrom-Json
    $entry = @($items | Where-Object { $_.name -eq $name -and ($_.status -eq 'installed' -or $_.status -eq 'ready') })
    if ($entry.Count -eq 0) { return $null }
    if ($entry.Count -ne 1) { throw "Duplicate installed entries for $name" }
    return $entry[0]
}
function Assert-PlanMatchesJournal($plan,$journal,[string]$name) {
    $planned = @($plan.ir_operations | ForEach-Object operation)
    $observed = @($journal.observed_steps)
    Assert-True (($planned -join ',') -eq ($observed -join ',')) "execution did not follow the displayed plan for $name`: planned=$($planned -join ',') observed=$($observed -join ',')"
    return [pscustomobject]@{planned=$planned;observed=$observed}
}
function LatestJournal {
    $entries = @(Get-ChildItem "$ScoopRoot/.coop/transactions" -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    if ($entries.Count -eq 0) { return $null }
    return (Get-Content -LiteralPath (Join-Path $entries[-1].FullName 'journal.json') -Raw | ConvertFrom-Json)
}
function LatestJournalPath {
    $entries = @(Get-ChildItem "$ScoopRoot/.coop/transactions" -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    if ($entries.Count -eq 0) { return $null }
    return (Join-Path $entries[-1].FullName 'journal.json')
}
function Save-Json([string]$name,$value) {
    $value | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $EvidenceDir $name) -Encoding utf8
}
function Write-PackageManifest([string]$file,[object]$manifest) {
    $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $tempBucket "bucket/$file.json") -Encoding utf8
}
function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
function Copy-Manifest([object]$manifest) { return (($manifest | ConvertTo-Json -Depth 12) | ConvertFrom-Json) }
function Remove-TestStore([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
    $expected = [IO.Path]::GetFullPath((Join-Path $ScoopRoot 'persist')).TrimEnd('\') + '\'
    if (-not ($full+'\').StartsWith($expected,[StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to remove a store outside the real persist root: $full" }
    $relative = $full.Substring($expected.Length)
    if ($relative -notin @('mediamtx','pocketbase','coop-r09-files')) { throw "Refusing to remove unexpected persist data: $full" }
    Write-Output "cleanup test-created persist store: $full"
    Remove-Item -LiteralPath $full -Recurse -Force
}

$scenarios = [ordered]@{}
$evidence = $null
try {
    $inventoryBefore = (Coop 'coop-list-before' @('list','--json')).output | ConvertFrom-Json
    $sevenEntries = @($inventoryBefore | Where-Object { $_.name -eq '7zip' -and ($_.status -eq 'installed' -or $_.status -eq 'ready') })
    Assert-True ($sevenEntries.Count -eq 1) 'The selected real Scoop root does not contain exactly one installed 7zip'
    foreach ($name in @('mediamtx','pocketbase')) {
        Assert-True ($null -eq (InstalledEntry $name)) "The real root already installs $name; refusing to change it"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $ScoopRoot "persist/$name"))) "A $name persist store already exists; refusing to change it"
    }
    Assert-True (-not (Test-Path -LiteralPath $temporaryStore)) "A test persist store already exists: $temporaryStore"
    Assert-True (-not (Test-Path -LiteralPath $tempBucket)) "A temporary bucket path already exists: $tempBucket"
    $scoopVersionOutput = (Scoop 'scoop-version' @('--version')).output
    $scoopVersion = (@(($scoopVersionOutput -split "`r?`n") | Where-Object { $_ -match '^v\d' })[0]).Trim()
    if ([string]::IsNullOrWhiteSpace($scoopVersion)) { $scoopVersion = $scoopVersionOutput.Trim() }
    $mainRevision = (& git -C "$ScoopRoot/buckets/main" rev-parse HEAD 2>&1 | Out-String).Trim()
    $coopVersion = (Run 'coop-version' $CoopExe @('--version')).output.Trim()

    # 1. Read-only: the existing Scoop installation of a real Main package already uses directory
    # junctions for its declared persistence. Coop must recognise them in place and change nothing.
    $sevenBefore = Store-Snapshot $sevenStore
    $sevenEntry = InstalledEntry '7zip'
    Assert-True (@($sevenEntry.persistence).Count -eq 2) 'Coop list omitted the existing 7zip persist mappings'
    foreach ($item in @($sevenEntry.persistence)) {
        Assert-True ($item.link_type -eq 'junction' -and $item.store_exists -eq $true -and $item.data_retained -eq $true) "Coop list did not report an existing 7zip store: $($item | ConvertTo-Json -Compress)"
        Assert-Junction $item.link $item.store
    }
    $sevenUpdate = Coop '7zip-update-preview' @('update','7zip','--dry-run','--json')
    $sevenPlan = Read-Json $sevenUpdate.output
    Save-Json '7zip-update-preview.json' $sevenPlan
    Assert-True (@($sevenPlan.persistence).Count -eq 2) 'update preview omitted the existing 7zip persist mappings'
    foreach ($item in @($sevenPlan.persistence)) {
        Assert-True ($item.data_retained -eq $true -and $item.store_exists -eq $true) "update preview did not retain the 7zip store: $($item | ConvertTo-Json -Compress)"
        Assert-Junction $item.link $item.store
    }
    Assert-True (-not (Test-Path -LiteralPath "$ScoopRoot/.coop/packages/7zip.json")) 'reading the 7zip persistence preview wrote management state'
    Assert-True ((Store-Snapshot $sevenStore) -eq $sevenBefore) 'reading the 7zip persistence changed its stored data'
    $scenarios['7zip_read_only'] = [ordered]@{
        store = $sevenStore
        mappings = @($sevenEntry.persistence)
        preview = [ordered]@{exit=$sevenUpdate.exit;execution_available=$sevenPlan.execution_available;persistence=@($sevenPlan.persistence)}
        store_snapshot = $sevenBefore
    }

    # 2. File persistence created by real Scoop. mediamtx reads mediamtx.yml from its own directory,
    # so a test value written to the store is observable through the version directory hardlink
    # before and after the Coop update, the Scoop reset, the Coop uninstall and the Scoop reinstall.
    $mediamtxInstall = Scoop 'mediamtx-install-1.21.2' @('install','mediamtx@1.21.2')
    Assert-True ($mediamtxInstall.exit -eq 0) "Scoop could not install mediamtx@1.21.2: $($mediamtxInstall.output)"
    $installedByTest.Add('mediamtx')
    $mtxVersionOld = "$ScoopRoot/apps/mediamtx/1.21.2"
    Assert-HardLink "$mtxVersionOld/mediamtx.yml" "$mediamtxStore/mediamtx.yml"
    Set-Content -LiteralPath "$mediamtxStore/mediamtx.yml" -Encoding utf8 -Value "logLevel: info`nrtspAddress: coop-r09-store"
    $mtxBefore = Store-Snapshot $mediamtxStore
    $mtxReadOld = Run 'mediamtx-read-old-store' "$mtxVersionOld/mediamtx.exe" @('mediamtx.yml') $mtxVersionOld
    Assert-True ($mtxReadOld.exit -ne 0 -and $mtxReadOld.output -match 'configuration loaded from.*mediamtx\.yml' -and $mtxReadOld.output -match 'coop-r09-store: missing port in address') "the Scoop-installed mediamtx did not read the store through its hardlink: $($mtxReadOld.output)"
    $mtxEntry = InstalledEntry 'mediamtx'
    Assert-True ($null -ne $mtxEntry -and $mtxEntry.version -eq '1.21.2') 'Coop did not identify the Scoop installation of mediamtx'
    Assert-True (-not (Test-Path -LiteralPath "$ScoopRoot/.coop/packages/mediamtx.json")) 'the Scoop mediamtx installation unexpectedly has a Coop record'
    $mtxPreview = Coop 'mediamtx-update-preview' @('update','mediamtx','--dry-run','--json')
    Assert-True ($mtxPreview.exit -eq 0) "Coop mediamtx update preview failed: $($mtxPreview.output)"
    $mtxPlan = Read-Json $mtxPreview.output
    Save-Json 'mediamtx-update-preview.json' $mtxPlan
    Assert-True ($mtxPlan.execution_available -eq $true) 'the mediamtx update preview was not executable'
    Assert-True (@($mtxPlan.persistence).Count -eq 1 -and @($mtxPlan.persistence)[0].store -like "$mediamtxStore*") 'the mediamtx update preview did not reuse the stored file'
    Assert-True ((Store-Snapshot $mediamtxStore) -eq $mtxBefore) 'the mediamtx update preview changed the stored data'
    $mtxUpdate = Coop 'mediamtx-update' @('update','mediamtx','--json')
    Assert-True ($mtxUpdate.exit -eq 0) "Coop could not update the Scoop mediamtx installation: $($mtxUpdate.output)"
    $mtxResult = Read-Json $mtxUpdate.output
    $mtxJournal = Get-Content -LiteralPath $mtxResult.journal -Raw | ConvertFrom-Json
    $mtxPlanMatch = Assert-PlanMatchesJournal $mtxPlan $mtxJournal 'mediamtx'
    Copy-Item -LiteralPath $mtxResult.journal -Destination (Join-Path $EvidenceDir 'mediamtx-update-journal.json')
    Save-Json 'mediamtx-update-result.json' $mtxResult
    Assert-True ($mtxResult.version -eq '1.21.3') "Coop updated mediamtx to an unexpected version: $($mtxResult.version)"
    Assert-True (@($mtxResult.persistence).Count -eq 1) 'the mediamtx update result omitted persistent data evidence'
    Assert-True ((@($mtxResult.retained_versions) -contains '1.21.2') -and $mtxResult.data_rollback -eq 'none') 'the mediamtx update did not separate old program retention from data rollback'
    Assert-True ((Store-Snapshot $mediamtxStore) -eq $mtxBefore) 'the mediamtx update moved or changed the stored data'
    $mtxVersionNew = "$ScoopRoot/apps/mediamtx/1.21.3"
    Assert-HardLink "$mtxVersionNew/mediamtx.yml" "$mediamtxStore/mediamtx.yml"
    $mtxReadNew = Run 'mediamtx-read-new-store' "$mtxVersionNew/mediamtx.exe" @('mediamtx.yml') $mtxVersionNew
    Assert-True ($mtxReadNew.exit -ne 0 -and $mtxReadNew.output -match 'configuration loaded from.*mediamtx\.yml' -and $mtxReadNew.output -match 'coop-r09-store: missing port in address') "the Coop-updated mediamtx did not read the store: $($mtxReadNew.output)"
    $mtxReadRetained = Run 'mediamtx-read-retained-version' "$mtxVersionOld/mediamtx.exe" @('mediamtx.yml') $mtxVersionOld
    Assert-True ($mtxReadRetained.exit -ne 0 -and $mtxReadRetained.output -match 'coop-r09-store: missing port in address') "the retained mediamtx version did not read the same store: $($mtxReadRetained.output)"
    $mtxReset = Scoop 'mediamtx-scoop-reset' @('reset','mediamtx')
    Assert-True ($mtxReset.exit -eq 0) "Scoop could not reset the Coop-updated mediamtx installation: $($mtxReset.output)"
    $mtxRunAfterReset = Run 'mediamtx-version-after-reset' "$ScoopRoot/shims/mediamtx.exe" @('--version')
    Assert-True ($mtxRunAfterReset.exit -eq 0 -and $mtxRunAfterReset.output.Trim() -eq 'v1.21.3') "the Scoop-reset mediamtx did not run: $($mtxRunAfterReset.output)"
    $mtxEntry = InstalledEntry 'mediamtx'
    Assert-True ($null -ne $mtxEntry -and $mtxEntry.version -eq '1.21.3') 'Coop did not re-identify the Scoop-reset mediamtx installation'
    Assert-True ((Store-Snapshot $mediamtxStore) -eq $mtxBefore) 'the Scoop reset changed the stored data'
    $mtxRemove = Coop 'mediamtx-uninstall' @('uninstall','mediamtx','--json')
    Assert-True ($mtxRemove.exit -eq 0) "Coop could not uninstall mediamtx: $($mtxRemove.output)"
    $mtxRemoved = Read-Json $mtxRemove.output
    Copy-Item -LiteralPath $mtxRemoved.journal -Destination (Join-Path $EvidenceDir 'mediamtx-uninstall-journal.json')
    Save-Json 'mediamtx-uninstall-result.json' $mtxRemoved
    Assert-True ($mtxRemoved.data_retained -eq $true -and @($mtxRemoved.persistence).Count -eq 1) 'the mediamtx uninstall did not report retained persistent data'
    Assert-True (-not (Test-Path -LiteralPath "$ScoopRoot/apps/mediamtx/current")) 'the mediamtx uninstall left current published'
    Assert-True (Test-Path -LiteralPath "$mtxVersionOld/mediamtx.yml") 'the mediamtx uninstall did not retain the documented old version'
    Assert-HardLink "$mtxVersionOld/mediamtx.yml" "$mediamtxStore/mediamtx.yml"
    Assert-True ((Store-Snapshot $mediamtxStore) -eq $mtxBefore) 'the mediamtx uninstall removed or changed the stored data'
    $mtxCleanup = Coop 'mediamtx-cleanup' @('cleanup','mediamtx','--json')
    Assert-True ($mtxCleanup.exit -eq 0) "Coop cleanup failed for the removed mediamtx versions: $($mtxCleanup.output)"
    Assert-True (-not (Test-Path -LiteralPath $mtxVersionOld)) 'the mediamtx cleanup did not remove the retained old version'
    Assert-True ((Store-Snapshot $mediamtxStore) -eq $mtxBefore) 'the mediamtx cleanup followed the persistence link into the stored data'
    $installedByTest.Remove('mediamtx') | Out-Null
    $mtxReinstall = Scoop 'mediamtx-reinstall-scoop' @('install','mediamtx@1.21.2')
    Assert-True ($mtxReinstall.exit -eq 0) "Scoop could not reinstall mediamtx@1.21.2: $($mtxReinstall.output)"
    $installedByTest.Add('mediamtx')
    Assert-HardLink "$mtxVersionOld/mediamtx.yml" "$mediamtxStore/mediamtx.yml"
    $mtxReadReinstalled = Run 'mediamtx-read-after-reinstall' "$mtxVersionOld/mediamtx.exe" @('mediamtx.yml') $mtxVersionOld
    Assert-True ($mtxReadReinstalled.exit -ne 0 -and $mtxReadReinstalled.output -match 'coop-r09-store: missing port in address') "the re-installed mediamtx did not reuse the retained store: $($mtxReadReinstalled.output)"
    $mtxScoopRemove = Scoop 'mediamtx-scoop-uninstall' @('uninstall','mediamtx')
    Assert-True ($mtxScoopRemove.exit -eq 0) "Scoop could not uninstall the re-installed mediamtx: $($mtxScoopRemove.output)"
    $installedByTest.Remove('mediamtx') | Out-Null
    Assert-True ((Store-Snapshot $mediamtxStore) -eq $mtxBefore) 'the Scoop uninstall moved or changed the retained mediamtx data'
    $scenarios['mediamtx_file_store'] = [ordered]@{
        store = $mediamtxStore
        store_snapshot = $mtxBefore
        old_version_read = $mtxReadOld.output.Trim()
        new_version_read = $mtxReadNew.output.Trim()
        retained_version_read = $mtxReadRetained.output.Trim()
        after_reset_version = $mtxRunAfterReset.output.Trim()
        after_reinstall_read = $mtxReadReinstalled.output.Trim()
        update = [ordered]@{version=$mtxResult.version;retained_versions=@($mtxResult.retained_versions);data_rollback=$mtxResult.data_rollback;persistence=@($mtxResult.persistence);plan=$mtxPlanMatch}
        uninstall = [ordered]@{data_retained=$mtxRemoved.data_retained;persistence=@($mtxRemoved.persistence);retained_versions=@($mtxRemoved.retained_versions)}
    }

    # 3. Directory persistence created by real Scoop. PocketBase writes its database through the
    # pb_data junction and applies a migration from pb_migrations; the Coop update and a later
    # Scoop installation must read the exact same stored database and migration.
    $pbInstall = Scoop 'pocketbase-install-0.40.5' @('install','pocketbase@0.40.5')
    Assert-True ($pbInstall.exit -eq 0) "Scoop could not install pocketbase@0.40.5: $($pbInstall.output)"
    $installedByTest.Add('pocketbase')
    $pbVersionOld = "$ScoopRoot/apps/pocketbase/0.40.5"
    Assert-Junction "$pbVersionOld/pb_data" "$pocketbaseStore/pb_data"
    Assert-Junction "$pbVersionOld/pb_migrations" "$pocketbaseStore/pb_migrations"
    $markerName = '1750000000_r09_marker.js'
    Set-Content -LiteralPath (Join-Path $pocketbaseStore "pb_migrations/$markerName") -NoNewline `
        -Value "migrate((app) => { console.log('coop-r09-marker-applied') }, (app) => {})"
    $markerHash = (HashOf (Join-Path $pocketbaseStore "pb_migrations/$markerName"))
    $markerId = File-Id (Join-Path $pocketbaseStore "pb_migrations/$markerName")
    $pbMigrateOld = Run 'pocketbase-migrate-old' "$pbVersionOld/pocketbase.exe" @('migrate','up') $pbVersionOld
    Assert-True ($pbMigrateOld.exit -eq 0 -and $pbMigrateOld.output -match 'coop-r09-marker-applied' -and $pbMigrateOld.output -match [regex]::Escape("Applied $markerName")) "the Scoop-installed pocketbase did not apply the stored migration: $($pbMigrateOld.output)"
    Assert-True (Test-Path -LiteralPath "$pocketbaseStore/pb_data/data.db") 'the migration did not create the database inside the persisted store'
    $databaseId = File-Id "$pocketbaseStore/pb_data/data.db"
    $pbEntry = InstalledEntry 'pocketbase'
    Assert-True ($null -ne $pbEntry -and $pbEntry.version -eq '0.40.5') 'Coop did not identify the Scoop installation of pocketbase'
    $pbPreview = Coop 'pocketbase-update-preview' @('update','pocketbase','--dry-run','--json')
    Assert-True ($pbPreview.exit -eq 0) "Coop pocketbase update preview failed: $($pbPreview.output)"
    $pbPlan = Read-Json $pbPreview.output
    Save-Json 'pocketbase-update-preview.json' $pbPlan
    Assert-True ($pbPlan.execution_available -eq $true) 'the pocketbase update preview was not executable'
    Assert-True (@($pbPlan.persistence).Count -eq 2) 'the pocketbase update preview omitted the persisted directories'
    $pbUpdate = Coop 'pocketbase-update' @('update','pocketbase','--json')
    Assert-True ($pbUpdate.exit -eq 0) "Coop could not update the Scoop pocketbase installation: $($pbUpdate.output)"
    $pbResult = Read-Json $pbUpdate.output
    $pbJournal = Get-Content -LiteralPath $pbResult.journal -Raw | ConvertFrom-Json
    $pbPlanMatch = Assert-PlanMatchesJournal $pbPlan $pbJournal 'pocketbase'
    Copy-Item -LiteralPath $pbResult.journal -Destination (Join-Path $EvidenceDir 'pocketbase-update-journal.json')
    Save-Json 'pocketbase-update-result.json' $pbResult
    Assert-True ($pbResult.version -eq '0.40.6') "Coop updated pocketbase to an unexpected version: $($pbResult.version)"
    Assert-True ((@($pbResult.retained_versions) -contains '0.40.5') -and $pbResult.data_rollback -eq 'none') 'the pocketbase update did not separate old program retention from data rollback'
    $pbVersionNew = "$ScoopRoot/apps/pocketbase/0.40.6"
    Assert-Junction "$pbVersionNew/pb_data" "$pocketbaseStore/pb_data"
    Assert-Junction "$pbVersionNew/pb_migrations" "$pocketbaseStore/pb_migrations"
    Assert-True ((File-Id (Join-Path $pocketbaseStore "pb_migrations/$markerName")) -eq $markerId) 'the pocketbase update recreated the stored migration file'
    Assert-True ((HashOf (Join-Path $pocketbaseStore "pb_migrations/$markerName")) -eq $markerHash) 'the pocketbase update changed the stored migration file'
    Assert-True ((File-Id "$pocketbaseStore/pb_data/data.db") -eq $databaseId) 'the pocketbase update recreated the stored database'
    $pbMigrateNew = Run 'pocketbase-migrate-new' "$pbVersionNew/pocketbase.exe" @('migrate','up') $pbVersionNew
    Assert-True ($pbMigrateNew.exit -eq 0 -and $pbMigrateNew.output -match 'No new migrations to apply') "the Coop-updated pocketbase did not read the stored database: $($pbMigrateNew.output)"
    Assert-True (Test-Path -LiteralPath "$pbVersionOld/pb_data/data.db") 'the pocketbase update removed the retained old version data link'
    $pbReset = Scoop 'pocketbase-scoop-reset' @('reset','pocketbase')
    Assert-True ($pbReset.exit -eq 0) "Scoop could not reset the Coop-updated pocketbase installation: $($pbReset.output)"
    $pbVersionRun = Run 'pocketbase-version-after-reset' "$ScoopRoot/shims/pocketbase.exe" @('--version')
    Assert-True ($pbVersionRun.exit -eq 0 -and $pbVersionRun.output -match '0\.40\.6') "the Scoop-reset pocketbase did not run: $($pbVersionRun.output)"
    $pbEntry = InstalledEntry 'pocketbase'
    Assert-True ($null -ne $pbEntry -and $pbEntry.version -eq '0.40.6') 'Coop did not re-identify the Scoop-reset pocketbase installation'
    $pbRemove = Coop 'pocketbase-uninstall' @('uninstall','pocketbase','--json')
    Assert-True ($pbRemove.exit -eq 0) "Coop could not uninstall pocketbase: $($pbRemove.output)"
    $pbRemoved = Read-Json $pbRemove.output
    Copy-Item -LiteralPath $pbRemoved.journal -Destination (Join-Path $EvidenceDir 'pocketbase-uninstall-journal.json')
    Save-Json 'pocketbase-uninstall-result.json' $pbRemoved
    Assert-True ($pbRemoved.data_retained -eq $true -and @($pbRemoved.persistence).Count -eq 2) 'the pocketbase uninstall did not report retained persistent data'
    Assert-True (-not (Test-Path -LiteralPath "$ScoopRoot/apps/pocketbase/current")) 'the pocketbase uninstall left current published'
    Assert-True ((Test-Path -LiteralPath "$pocketbaseStore/pb_migrations/$markerName") -and (Test-Path -LiteralPath "$pocketbaseStore/pb_data/data.db")) 'the pocketbase uninstall removed persisted data'
    Assert-True ((File-Id (Join-Path $pocketbaseStore "pb_migrations/$markerName")) -eq $markerId) 'the pocketbase uninstall recreated the stored migration file'
    Assert-True ((File-Id "$pocketbaseStore/pb_data/data.db") -eq $databaseId) 'the pocketbase uninstall recreated the stored database'
    $pbCleanup = Coop 'pocketbase-cleanup' @('cleanup','pocketbase','--json')
    Assert-True ($pbCleanup.exit -eq 0) "Coop cleanup failed for the removed pocketbase version: $($pbCleanup.output)"
    Assert-True (-not (Test-Path -LiteralPath $pbVersionOld)) 'the pocketbase cleanup did not remove the retained old version'
    Assert-True ((Test-Path -LiteralPath "$pocketbaseStore/pb_migrations/$markerName") -and (Test-Path -LiteralPath "$pocketbaseStore/pb_data/data.db")) 'the pocketbase old-version cleanup followed the junctions into persisted data'
    $installedByTest.Remove('pocketbase') | Out-Null
    $pbReinstall = Scoop 'pocketbase-reinstall-scoop' @('install','pocketbase@0.40.5')
    Assert-True ($pbReinstall.exit -eq 0) "Scoop could not reinstall pocketbase@0.40.5: $($pbReinstall.output)"
    $installedByTest.Add('pocketbase')
    Assert-Junction "$pbVersionOld/pb_data" "$pocketbaseStore/pb_data"
    $pbMigrateReused = Run 'pocketbase-migrate-after-reinstall' "$pbVersionOld/pocketbase.exe" @('migrate','up') $pbVersionOld
    Assert-True ($pbMigrateReused.exit -eq 0 -and $pbMigrateReused.output -match 'No new migrations to apply') "the re-installed pocketbase did not reuse the stored database: $($pbMigrateReused.output)"
    Assert-True ((File-Id "$pocketbaseStore/pb_data/data.db") -eq $databaseId) 'the re-installation replaced the stored database'
    $pbScoopRemove = Scoop 'pocketbase-scoop-uninstall' @('uninstall','pocketbase')
    Assert-True ($pbScoopRemove.exit -eq 0) "Scoop could not uninstall the re-installed pocketbase: $($pbScoopRemove.output)"
    $installedByTest.Remove('pocketbase') | Out-Null
    Assert-True ((Test-Path -LiteralPath "$pocketbaseStore/pb_migrations/$markerName") -and (Test-Path -LiteralPath "$pocketbaseStore/pb_data/data.db")) 'the Scoop uninstall removed the retained pocketbase data'
    $scenarios['pocketbase_directory_store'] = [ordered]@{
        store = $pocketbaseStore
        migration = @{name=$markerName;file_id=$markerId;sha256=$markerHash}
        database = @{path="$pocketbaseStore/pb_data/data.db";file_id=$databaseId}
        old_migrate = $pbMigrateOld.output.Trim()
        new_migrate = $pbMigrateNew.output.Trim()
        after_reset_version = $pbVersionRun.output.Trim()
        after_reinstall_migrate = $pbMigrateReused.output.Trim()
        update = [ordered]@{version=$pbResult.version;retained_versions=@($pbResult.retained_versions);data_rollback=$pbResult.data_rollback;persistence=@($pbResult.persistence);plan=$pbPlanMatch}
        uninstall = [ordered]@{data_retained=$pbRemoved.data_retained;persistence=@($pbRemoved.persistence);retained_versions=@($pbRemoved.retained_versions)}
    }

    # 4. A preparation failure in a temp bucket package must leave the current program, its
    # persistence link and the stored data untouched, and the journal must be rolled back. The
    # artifact is a project-local copy of the cached mediamtx archive, so this step is offline.
    New-Item -ItemType Directory -Path "$tempBucket/bucket" -Force | Out-Null
    $cachedMediamtx = @(Get-ChildItem "$ScoopRoot/cache" -Filter 'mediamtx#1.21.2#*.zip' -File)
    Assert-True ($cachedMediamtx.Count -eq 1) "The cached mediamtx@1.21.2 archive is missing: $($cachedMediamtx.Name -join ',')"
    $mediamtxArtifact = Join-Path $artifacts 'mediamtx-1.21.2.zip'
    Copy-Item -LiteralPath $cachedMediamtx[0].FullName -Destination $mediamtxArtifact
    $corruptArtifact = Join-Path $artifacts 'corrupt-1.21.3.zip'
    [IO.File]::WriteAllBytes($corruptArtifact,[byte[]](1..65536 | ForEach-Object { ($_ * 37) % 251 }))
    $baseManifest = Get-Content -LiteralPath "$ScoopRoot/buckets/main/bucket/mediamtx.json" -Raw | ConvertFrom-Json
    $v1 = Copy-Manifest $baseManifest
    $v1.version = '1.21.2'
    $v1.architecture.'64bit'.url = (File-Uri $mediamtxArtifact)
    $v1.architecture.'64bit'.hash = (HashOf $mediamtxArtifact)
    $v1.bin = @(,@('mediamtx.exe','coop-r09-mediamtx'))
    Write-PackageManifest $temporaryPackage $v1
    $tempPreview = Coop 'temporary-install-preview' @('install',"$tempBucketName/$temporaryPackage",'--dry-run','--json')
    Assert-True ($tempPreview.exit -eq 0) "temporary persist package preview failed: $($tempPreview.output)"
    $tempPlan = Read-Json $tempPreview.output
    Assert-True ($tempPlan.execution_available -eq $true) 'the temporary persist package preview was not executable'
    $tempInstall = Coop 'temporary-install' @('install',"$tempBucketName/$temporaryPackage",'--json')
    Assert-True ($tempInstall.exit -eq 0) "temporary persist package install failed: $($tempInstall.output)"
    $temporaryVersion = "$ScoopRoot/apps/$temporaryPackage/1.21.2"
    Assert-HardLink "$temporaryVersion/mediamtx.yml" "$temporaryStore/mediamtx.yml"
    Set-Content -LiteralPath "$temporaryStore/mediamtx.yml" -Encoding utf8 -Value "logLevel: info`nrtspAddress: coop-r09-temporary-store"
    $tempBefore = Store-Snapshot $temporaryStore
    $tempReadBefore = Run 'temporary-read-before-failure' "$temporaryVersion/mediamtx.exe" @('mediamtx.yml') $temporaryVersion
    Assert-True ($tempReadBefore.exit -ne 0 -and $tempReadBefore.output -match 'coop-r09-temporary-store: missing port in address') "the temporary package did not read its stored configuration: $($tempReadBefore.output)"
    $v2 = Copy-Manifest $baseManifest
    $v2.version = '1.21.3-corrupt-r09'
    $v2.architecture.'64bit'.url = (File-Uri $corruptArtifact)
    $v2.architecture.'64bit'.hash = (HashOf $corruptArtifact)
    $v2.bin = @(,@('mediamtx.exe','coop-r09-mediamtx'))
    Write-PackageManifest $temporaryPackage $v2
    $tempFailure = Coop 'temporary-update-failure' @('update',$temporaryPackage,'--json')
    Assert-True ($tempFailure.exit -ne 0) 'a corrupt archive update unexpectedly succeeded'
    Assert-True (-not (Test-Path -LiteralPath "$ScoopRoot/apps/$temporaryPackage/1.21.3-corrupt-r09")) 'the failed update published the corrupt version'
    Assert-True ((Store-Snapshot $temporaryStore) -eq $tempBefore) 'the failed update changed the stored data'
    Assert-HardLink "$temporaryVersion/mediamtx.yml" "$temporaryStore/mediamtx.yml"
    $tempReadAfter = Run 'temporary-read-after-failure' "$temporaryVersion/mediamtx.exe" @('mediamtx.yml') $temporaryVersion
    Assert-True ($tempReadAfter.exit -ne 0 -and $tempReadAfter.output -match 'coop-r09-temporary-store: missing port in address') "the current package stopped reading the stored data after the failure: $($tempReadAfter.output)"
    $tempEntry = InstalledEntry $temporaryPackage
    Assert-True ($null -ne $tempEntry -and $tempEntry.version -eq '1.21.2') 'the failed update changed the installed version'
    $failureJournal = LatestJournal
    Copy-Item -LiteralPath (LatestJournalPath) -Destination (Join-Path $EvidenceDir 'preparation-failure-journal.json')
    $failurePreparation = if ($failureJournal.PSObject.Properties.Name -contains 'preparation_steps') { @($failureJournal.preparation_steps | Where-Object { $null -ne $_ }) } else { @() }
    Assert-True ($failureJournal.state -eq 'rolled-back') "the failed update did not leave a rolled-back journal: $($failureJournal.state)"
    Assert-True (@($failureJournal.observed_steps | Where-Object { $_ -eq 'extract' }).Count -ge 1) 'the failed update has no extract evidence'
    $tempRemove = Coop 'temporary-uninstall' @('uninstall',$temporaryPackage,'--json')
    Assert-True ($tempRemove.exit -eq 0) "the temporary package uninstall failed: $($tempRemove.output)"
    $tempRemoved = Read-Json $tempRemove.output
    Assert-True ($tempRemoved.data_retained -eq $true) 'the temporary package uninstall did not retain its stored data'
    Assert-True ((Store-Snapshot $temporaryStore) -eq $tempBefore) 'the temporary package uninstall changed the stored data'
    $scenarios['preparation_failure'] = [ordered]@{
        store = $temporaryStore
        store_snapshot = $tempBefore
        read_before = $tempReadBefore.output.Trim()
        update_exit = $tempFailure.exit
        update_output = $tempFailure.output.Trim()
        journal = [ordered]@{state=$failureJournal.state;observed_steps=@($failureJournal.observed_steps);preparation_steps=@($failurePreparation)}
        read_after = $tempReadAfter.output.Trim()
        uninstall = [ordered]@{data_retained=$tempRemoved.data_retained;persistence=@($tempRemoved.persistence)}
    }

    $inventoryAfter = (Coop 'coop-list-after' @('list','--json')).output | ConvertFrom-Json
    $beforeNames = @($inventoryBefore | ForEach-Object { $_.name } | Sort-Object)
    $afterNames = @($inventoryAfter | ForEach-Object { $_.name } | Sort-Object)
    Assert-True (($beforeNames -join ',') -eq ($afterNames -join ',')) "The real installation inventory changed: before=$($beforeNames -join ',') after=$($afterNames -join ',')"
    $evidence = [ordered]@{
        platform = (Get-CimInstance Win32_OperatingSystem).Caption
        windows_version = [Environment]::OSVersion.Version.ToString()
        scoop_root = $ScoopRoot
        scoop_version = $scoopVersion
        main_bucket_revision = $mainRevision
        coop_exe = $CoopExe
        coop_version = $coopVersion
        coop_sha256 = (HashOf $CoopExe)
        pwsh_version = $PSVersionTable.PSVersion.ToString()
        scenarios = $scenarios
        inventory_before = @($inventoryBefore | ForEach-Object { [pscustomobject]@{name=$_.name;version=$_.version;bucket=$_.bucket} })
        inventory_after = @($inventoryAfter | ForEach-Object { [pscustomobject]@{name=$_.name;version=$_.version;bucket=$_.bucket} })
        commands = @($commands)
        timestamp = [DateTime]::UtcNow.ToString('o')
    }
    Save-Json 'real-scoop-persistence-evidence.json' $evidence
    Write-Output "PASS real in-place persistent data: $(Join-Path $EvidenceDir 'real-scoop-persistence-evidence.json')"
} finally {
    foreach ($name in @($installedByTest)) {
        foreach ($action in @('cleanup','uninstall')) {
            try { $result = Coop ($name+'-failure-'+$action) @($action,$name,'--json'); Write-Output "$action $name exit=$($result.exit)" }
            catch { Write-Output "$action $name failed: $_" }
        }
    }
    foreach ($name in $testPackages) {
        $directory = Join-Path $ScoopRoot "apps/$name"
        if ((Test-Path -LiteralPath $directory) -and -not (Test-Path -LiteralPath "$directory/current")) {
            try { & $scoop uninstall $name *>&1 | Out-Null; Write-Output "scoop uninstall $name exit=$LASTEXITCODE" } catch { Write-Output "scoop uninstall $name failed: $_" }
            if (Test-Path -LiteralPath $directory) {
                try { Remove-Item -LiteralPath $directory -Recurse -Force; Write-Output "cleanup test app directory $directory" }
                catch { Write-Output "cleanup test app directory failed: $directory $_" }
            }
        }
    }
    foreach ($name in $testPackages) {
        if (Test-Path -LiteralPath (Join-Path $ScoopRoot "apps/$name/current")) { continue }
        foreach ($entryName in @($testEntries[$name])) {
            foreach ($suffix in @('.exe','.shim','.coop-shim.json','.cmd','.ps1')) {
                $leftover = Join-Path $ScoopRoot "shims/$entryName$suffix"
                if (Test-Path -LiteralPath $leftover) {
                    try { Remove-Item -LiteralPath $leftover -Force; Write-Output "cleanup leftover entry $leftover" } catch { Write-Output "cleanup leftover entry failed: $leftover $_" }
                }
            }
        }
    }
    try { Remove-TestStore $mediamtxStore } catch { Write-Output "cleanup mediamtx store failed: $_" }
    try { Remove-TestStore $pocketbaseStore } catch { Write-Output "cleanup pocketbase store failed: $_" }
    try { Remove-TestStore $temporaryStore } catch { Write-Output "cleanup temporary store failed: $_" }
    if (Test-Path -LiteralPath $tempBucket) {
        try { Remove-Item -LiteralPath $tempBucket -Recurse -Force; Write-Output "cleanup temporary bucket $tempBucket" }
        catch { Write-Output "cleanup temporary bucket failed: $_" }
    }
    foreach ($name in $testPackages) {
        $retained = Join-Path $ScoopRoot ".coop/retained/$name.json"
        if (Test-Path -LiteralPath $retained) {
            try { Remove-Item -LiteralPath $retained -Force; Write-Output "cleanup retained evidence $retained" } catch { Write-Output "cleanup retained evidence failed: $_" }
        }
        $record = Join-Path $ScoopRoot ".coop/packages/$name.json"
        if ((Test-Path -LiteralPath $record) -and -not (Test-Path -LiteralPath (Join-Path $ScoopRoot "apps/$name/current"))) {
            try { Remove-Item -LiteralPath $record -Force; Write-Output "cleanup test package record $record" } catch { Write-Output "cleanup test package record failed: $_" }
        }
    }
}

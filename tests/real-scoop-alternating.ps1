param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$EvidenceDir,
    [string]$ScoopRoot = 'C:\Users\Neo\scoop',
    [string]$Package = 'jq',
    [string]$OldVersion = '1.7.1'
)
$ErrorActionPreference = 'Stop'
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$ScoopRoot = [IO.Path]::GetFullPath($ScoopRoot)
$scoop = (Get-Command scoop.ps1 -ErrorAction Stop).Source
$commands = [System.Collections.Generic.List[object]]::new()
function Run([string]$name,[string]$exe,[string[]]$arguments) {
    $log = Join-Path $EvidenceDir ($name+'.log')
    $output = & $exe @arguments 2>&1 | Out-String
    $exit = $LASTEXITCODE
    Set-Content -LiteralPath $log -Value $output -Encoding utf8
    $commands.Add([pscustomobject]@{name=$name;exe=$exe;arguments=$arguments;exit=$exit;log=$log})
    return [pscustomobject]@{exit=$exit;output=$output;log=$log}
}
function Coop([string]$name,[string[]]$arguments) {
    return Run $name $CoopExe (@('--root',$ScoopRoot)+$arguments)
}
function Scoop([string]$name,[string[]]$arguments) {
    return Run $name $scoop $arguments
}
function Snapshot([string]$name) {
    $lines = foreach ($path in @("$ScoopRoot/apps",$ScoopRoot+'/shims',"$ScoopRoot/.coop")) {
        if (Test-Path -LiteralPath $path) {
            Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $relative = $_.FullName.Substring($ScoopRoot.Length).TrimStart('\')
                $hash = if ($_.PSIsContainer) { 'directory' } else { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash }
                "$relative|$($_.Length)|$($_.LastWriteTimeUtc.ToString('o'))|$hash"
            }
        }
    }
    $lines | Sort-Object | Set-Content -LiteralPath (Join-Path $EvidenceDir ($name+'.snapshot.txt')) -Encoding utf8
}
function Assert-True([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
function InstalledVersion([string]$name,[string]$stage) {
    $list = (Coop ($name+'-list-'+$stage) @('list','--json')).output | ConvertFrom-Json
    # A shared Scoop installation has no Coop record and reports status=installed; after a Coop
    # write the published management record carries status=ready. Both describe an installed
    # package and neither is a retirement of the other.
    $entry = @($list | Where-Object { $_.name -eq $name -and $_.status -in @('installed','ready') })
    if ($entry.Count -eq 0) { return $null }
    return $entry[0]
}
Snapshot 'before'
$before = InstalledVersion $Package 'before'
Assert-True ($null -eq $before) "The selected real package is already installed; refusing to change an existing user installation: $Package"
$inventoryBefore = (Coop 'coop-list-before' @('list','--json')).output | ConvertFrom-Json
$scoopVersion = (Scoop 'scoop-version' @('--version')).output
$bucketHead = (& git -C "$ScoopRoot/buckets/main" rev-parse HEAD 2>&1 | Out-String).Trim()
# 1. Scoop creates the installation from a real local bucket history manifest.
$install = Scoop 'scoop-install-old' @('install',"$Package@$OldVersion")
Assert-True ($install.exit -eq 0) "Scoop install $Package@$OldVersion failed: $($install.output)"
$scoopRun = Run 'scoop-run-old' "$ScoopRoot/shims/$Package.exe" @('--version')
Assert-True ($scoopRun.exit -eq 0 -and $scoopRun.output.Trim() -eq "jq-$OldVersion") "Scoop-installed program did not run as $OldVersion`: $($scoopRun.output)"
$observed = InstalledVersion $Package 'after-scoop-install'
Assert-True ($null -ne $observed -and $observed.version -eq $OldVersion) "Coop did not identify the Scoop installation: $($observed | ConvertTo-Json -Compress)"
$privateRecordBefore = Test-Path -LiteralPath "$ScoopRoot/.coop/packages/$Package.json"
Assert-True (-not $privateRecordBefore) "A Coop private record already existed before the shared update: $ScoopRoot/.coop/packages/$Package.json"
$scoopInstallManagement = $observed.management
$preview = Coop 'coop-update-preview' @('update',$Package,'--dry-run','--json')
Assert-True ($preview.exit -eq 0) "Coop update preview failed: $($preview.output)"
$previewJson = $preview.output | ConvertFrom-Json
Assert-True ($previewJson.execution_available -eq $true) "Coop update preview was not executable: $($preview.output)"
$planned = @($previewJson.ir_operations | ForEach-Object operation)
# 2. Coop performs the update against the same shared installation and records the plan it consumed.
$update = Coop 'coop-update' @('update',$Package,'--json')
Assert-True ($update.exit -eq 0) "Coop update failed: $($update.output)"
$updateJson = $update.output | ConvertFrom-Json
$journal = Get-Content -LiteralPath $updateJson.journal -Raw | ConvertFrom-Json
Assert-True ((($journal.observed_steps) -join ',') -eq ($planned -join ',')) "Coop execution did not follow its displayed plan: planned=$planned observed=$($journal.observed_steps)"
$coopRun = Run 'coop-run' "$ScoopRoot/shims/$Package.exe" @('--version')
Assert-True ($coopRun.exit -eq 0 -and $coopRun.output.Trim() -eq 'jq-1.8.2') "Coop-updated program did not run: $($coopRun.output)"
$afterUpdate = InstalledVersion $Package 'after-coop-update'
Assert-True ($null -ne $afterUpdate -and $afterUpdate.version -eq '1.8.2') "Coop did not report the updated version: $($afterUpdate | ConvertTo-Json -Compress)"
$scoopList = Scoop 'scoop-list-after-coop-update' @('list',$Package)
Assert-True ($scoopList.exit -eq 0 -and $scoopList.output -match '1\.8\.2') "Scoop did not recognize the Coop-updated installation: $($scoopList.output)"
$scoopUpdate = Scoop 'scoop-update-after-coop' @('update',$Package)
Assert-True ($scoopUpdate.exit -eq 0) "Scoop could not continue managing the Coop-updated package: $($scoopUpdate.output)"
$standardManifest = if (Test-Path "$ScoopRoot/apps/$Package/current/scoop-manifest.json") { "$ScoopRoot/apps/$Package/current/scoop-manifest.json" } else { "$ScoopRoot/apps/$Package/current/manifest.json" }
$standardVersion = (Get-Content -LiteralPath $standardManifest -Raw | ConvertFrom-Json).version
Assert-True ($standardVersion -eq '1.8.2') "Standard Scoop install record did not carry the updated version: $standardVersion"
$retainedOld = Test-Path -LiteralPath "$ScoopRoot/apps/$Package/$OldVersion"
Assert-True $retainedOld 'The previous version was not retained after the Coop update'
# Remove only the old version through real Scoop before testing a clean Coop uninstall.
$cleanup = Scoop 'scoop-cleanup' @('cleanup',$Package)
Assert-True ($cleanup.exit -eq 0) "Scoop cleanup failed: $($cleanup.output)"
$remove = Coop 'coop-uninstall' @('uninstall',$Package,'--json')
Assert-True ($remove.exit -eq 0) "Coop uninstall failed: $($remove.output)"
Assert-True (-not (Test-Path "$ScoopRoot/apps/$Package/current") -and -not (Test-Path "$ScoopRoot/shims/$Package.exe")) 'Coop uninstall left the shared package visible'
$gone = InstalledVersion $Package 'after-coop-uninstall'
Assert-True ($null -eq $gone) 'Coop still listed the uninstalled package'
$scoopListGone = Scoop 'scoop-list-after-coop-uninstall' @('list',$Package)
Assert-True ($scoopListGone.output -notmatch [regex]::Escape($Package)) "Scoop still listed the Coop-uninstalled package: $($scoopListGone.output)"
# 3. Reverse flow: Coop creates the standard installation; Scoop resets its entry and runs it.
$installCoop = Coop 'coop-install' @('install',$Package,'--json')
Assert-True ($installCoop.exit -eq 0) "Coop install failed: $($installCoop.output)"
$coopInstallRun = Run 'coop-install-run' "$ScoopRoot/shims/$Package.exe" @('--version')
Assert-True ($coopInstallRun.exit -eq 0 -and $coopInstallRun.output.Trim() -eq 'jq-1.8.2') "Coop-installed program did not run: $($coopInstallRun.output)"
$scoopListCoop = Scoop 'scoop-list-coop-install' @('list',$Package)
Assert-True ($scoopListCoop.exit -eq 0 -and $scoopListCoop.output -match '1\.8\.2') "Scoop did not recognize the Coop installation: $($scoopListCoop.output)"
$reset = Scoop 'scoop-reset' @('reset',$Package)
Assert-True ($reset.exit -eq 0) "Scoop reset failed: $($reset.output)"
$resetRun = Run 'scoop-run-after-reset' "$ScoopRoot/shims/$Package.exe" @('--version')
Assert-True ($resetRun.exit -eq 0 -and $resetRun.output.Trim() -eq 'jq-1.8.2') "Scoop-reset entry did not run: $($resetRun.output)"
$afterReset = InstalledVersion $Package 'after-scoop-reset'
Assert-True ($null -ne $afterReset -and $afterReset.version -eq '1.8.2') "Coop did not re-identify the Scoop-reset installation: $($afterReset | ConvertTo-Json -Compress)"
$removeAfterReset = Coop 'coop-uninstall-after-reset' @('uninstall',$Package,'--json')
Assert-True ($removeAfterReset.exit -eq 0) "Coop uninstall after Scoop reset failed: $($removeAfterReset.output)"
Assert-True (-not (Test-Path "$ScoopRoot/apps/$Package/current") -and -not (Test-Path "$ScoopRoot/shims/$Package.exe") -and -not (Test-Path "$ScoopRoot/shims/$Package.shim")) 'Coop uninstall after Scoop reset left published state'
$finalGone = InstalledVersion $Package 'after-reverse-uninstall'
Assert-True ($null -eq $finalGone) 'Coop still listed the package after the reverse flow'
Snapshot 'after'
$inventoryAfter = (Coop 'coop-list-after' @('list','--json')).output | ConvertFrom-Json
$evidence = [ordered]@{
    platform = (Get-CimInstance Win32_OperatingSystem).Caption
    scoop_root = $ScoopRoot
    package = $Package
    old_version = $OldVersion
    scoop_version = $scoopVersion.Trim()
    bucket_head = $bucketHead
    coop_exe = $CoopExe
    coop_sha256 = (Get-FileHash -LiteralPath $CoopExe -Algorithm SHA256).Hash.ToLower()
    inventory_before = @($inventoryBefore | ForEach-Object { [pscustomobject]@{name=$_.name;version=$_.version;bucket=$_.bucket;management=$_.management} })
    inventory_after = @($inventoryAfter | ForEach-Object { [pscustomobject]@{name=$_.name;version=$_.version;bucket=$_.bucket;management=$_.management} })
    scoop_install_management = $scoopInstallManagement
    private_record_before_update = $privateRecordBefore
    planned_ir_operations = $planned
    observed_ir_operations = @($journal.observed_steps)
    previous_version_retained = $retainedOld
    standard_manifest = $standardManifest
    standard_version = $standardVersion
    commands = @($commands)
    timestamp = [DateTime]::UtcNow.ToString('o')
}
$evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceDir 'real-scoop-alternating-evidence.json') -Encoding utf8
Write-Output "PASS real Scoop/Coop single-file alternating management: $(Join-Path $EvidenceDir 'real-scoop-alternating-evidence.json')"

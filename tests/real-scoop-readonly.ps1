param(
    [Parameter(Mandatory)][string]$CoopExe,
    [string]$ScoopRoot = (Join-Path $env:USERPROFILE 'scoop'),
    [Parameter(Mandatory)][string]$EvidenceDir)
# Read-only verification against the human-selected real Scoop installation. This script performs no
# package operations: it only queries and previews, and proves that no shared state was written.
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
$allowed = [IO.Path]::GetFullPath((Join-Path $projectRoot '.local')).TrimEnd('\') + '\'
if (-not ($EvidenceDir.TrimEnd('\') + '\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence must stay inside the project .local directory' }
if (-not (Test-Path -LiteralPath $ScoopRoot)) { throw "Real Scoop root not found: $ScoopRoot" }
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
function Get-RootSnapshot([string]$Path) {
    @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($Path.Length) + ':' + $_.Length + ':' + $_.LastWriteTimeUtc.Ticks
    })
}
function Invoke-Coop([string[]]$Arguments) {
    $output = & $CoopExe @Arguments 2>&1
    [pscustomobject]@{ code = $LASTEXITCODE; text = ($output -join "`n") }
}
$started = [DateTime]::UtcNow.ToString('o')
$stateBefore = Test-Path (Join-Path $ScoopRoot '.coop')
$before = Get-RootSnapshot $ScoopRoot
$list = Invoke-Coop @('--root',$ScoopRoot,'list','--json')
$list.text | Set-Content (Join-Path $EvidenceDir 'real-scoop-list.json') -Encoding utf8
if ($list.code -ne 0) { throw "list failed against the real root: $($list.text)" }
$installed = @($list.text | ConvertFrom-Json)
if ($installed.Count -eq 0) { throw 'No installed packages were read from the real root' }
$names = @($installed | ForEach-Object { $_.name } | Sort-Object)
$target = $names[0]
$targetListed = @($installed | Where-Object name -eq $target)[0]
$bucket = if ($targetListed.bucket) { $targetListed.bucket } else { 'main' }
$info = Invoke-Coop @('--root',$ScoopRoot,'info',"$bucket/$target",'--json')
$info.text | Set-Content (Join-Path $EvidenceDir "real-scoop-info-$target.json") -Encoding utf8
if ($info.code -ne 0) { throw "info failed for ${bucket}/${target}: $($info.text)" }
$update = Invoke-Coop @('--root',$ScoopRoot,'update',$target,'--dry-run','--json')
$update.text | Set-Content (Join-Path $EvidenceDir "real-scoop-update-$target.json") -Encoding utf8
if ($update.code -notin 0,1) { throw "update preview failed for ${target}: $($update.text)" }
$uninstall = Invoke-Coop @('--root',$ScoopRoot,'uninstall',$target,'--dry-run','--json')
$uninstall.text | Set-Content (Join-Path $EvidenceDir "real-scoop-uninstall-$target.json") -Encoding utf8
if ($uninstall.code -notin 0,1) { throw "uninstall preview failed for ${target}: $($uninstall.text)" }
$guard = Join-Path (Split-Path $CoopExe) 'process_guard.exe'
$guarded = & $guard $CoopExe --root $ScoopRoot list --json
if ($LASTEXITCODE -ne 0) { throw 'a real query started a helper process' }
$guarded | Set-Content (Join-Path $EvidenceDir 'real-scoop-process-evidence.txt') -Encoding utf8
$after = Get-RootSnapshot $ScoopRoot
$changed = @(Compare-Object $before $after)
$state = Test-Path (Join-Path $ScoopRoot '.coop')
$stateCreated = -not $stateBefore -and $state
$updatePlan = $null
if ($update.code -in 0,1 -and $update.text.Trim().StartsWith('{')) { $updatePlan = $update.text | ConvertFrom-Json }
$evidence = [ordered]@{
    generated_at = [DateTime]::UtcNow.ToString('o')
    scoop_root = $ScoopRoot
    coop = (& $CoopExe --version)
    scoop_version = (@(scoop --version 2>&1 | Select-Object -First 2) -join ' ')
    installed_count = $installed.Count
    installed = @($installed | ForEach-Object { [ordered]@{ name = $_.name; version = $_.version; bucket = $_.bucket; architecture = $_.architecture; source = $_.source } })
    preview_target = $target
    preview_operations = if ($updatePlan) { @($updatePlan.ir_operations | ForEach-Object { $_.operation }) } else { @() }
    preview_ir_operations = if ($updatePlan) { @($updatePlan.ir_operations | ForEach-Object { $_.operation }) } else { @() }
    preview_execution_available = if ($updatePlan) { $updatePlan.execution_available } else { $null }
    preview_diagnostic_codes = if ($updatePlan) { @($updatePlan.diagnostics | ForEach-Object { $_.code }) } else { @() }
    coop_state_directory_was_present = $stateBefore
    coop_state_directory_created = $stateCreated
    shared_files_changed = $changed.Count
    snapshot_method = 'recursive file path + length + LastWriteTimeUtc before and after; content hashes are compared in the project-local IR test'
    started_at = $started
}
$evidence | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $EvidenceDir 'real-scoop-readonly-evidence.json') -Encoding utf8
if ($stateCreated) { throw 'A read-only query created a Coop state directory inside the real Scoop root' }
if ($changed.Count) { throw "Read-only query or preview modified $($changed.Count) files under the real Scoop root" }
$installed | Format-Table name,version,bucket,architecture,source -AutoSize | Out-String -Width 160 | Write-Output
Write-Output ("PASS real Scoop read-only inventory ({0} packages), query, info and previews with no state writes" -f $installed.Count)



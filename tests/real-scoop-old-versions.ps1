param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$EvidenceDir,
    [string]$ScoopRoot = 'C:\Users\Neo\scoop'
)
# Real shared-root acceptance for old versions (R15). It creates one test package in a temporary
# bucket inside the human-selected Scoop root, alternates Coop and Scoop on it, and removes every
# object it created in the finally block. No existing installation, bucket, configuration or store
# is modified or deleted.
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
$allowed = [IO.Path]::GetFullPath((Join-Path $projectRoot '.local')).TrimEnd('\') + '\'
if (-not ($EvidenceDir.TrimEnd('\') + '\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Evidence must stay inside the project .local directory' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$ScoopRoot = [IO.Path]::GetFullPath($ScoopRoot)
$scoop = (Get-Command scoop.ps1 -ErrorAction Stop).Source
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$commands = [System.Collections.Generic.List[object]]::new()
$package = 'coop-r15-fixture'
$bucketName = 'coop-r15-old'
$bucket = Join-Path $ScoopRoot "buckets/$bucketName"
$app = Join-Path $ScoopRoot "apps/$package"
$store = Join-Path $ScoopRoot "persist/$package"
$fixture1 = Join-Path (Split-Path $CoopExe) 'fixture-1.exe'
$fixture2 = Join-Path (Split-Path $CoopExe) 'fixture-2.exe'
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
function Save-Json([string]$name,$value) {
    $value | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $EvidenceDir $name) -Encoding utf8
}
function Write-Manifest([string]$version,[string]$source) {
    $value = @{version=$version;url=([Uri][IO.Path]::GetFullPath($source)).AbsoluteUri+"#/$package.exe";
        hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLower();bin="$package.exe";persist=@('config')}
    [IO.File]::WriteAllText((Join-Path $bucket "bucket/$package.json"),($value | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
function CoopEntry([string]$name) {
    $items = (Coop ($name+'-list') @('list','--json')).output | ConvertFrom-Json
    $found = @($items | Where-Object { $_.name -eq $package -and ($_.status -eq 'installed' -or $_.status -eq 'ready') })
    if ($found.Count -eq 0) { return $null }
    if ($found.Count -ne 1) { throw "Duplicate installed entries for $package" }
    return $found[0]
}
function Last-Journal([string]$action) {
    $entries = @(Get-ChildItem "$ScoopRoot/.coop/transactions" -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    for ($index = $entries.Count-1; $index -ge 0; --$index) {
        $journal = Get-Content -LiteralPath (Join-Path $entries[$index].FullName 'journal.json') -Raw | ConvertFrom-Json
        if ($journal.package -eq $package -and $journal.action -eq $action) { return $journal }
    }
    throw "no $action journal for $package"
}

$summary = [ordered]@{scoop_root=$ScoopRoot;package=$package;bucket=$bucket;coop=$CoopExe;coop_version=(& $CoopExe --version);coop_sha256=(Get-FileHash -LiteralPath $CoopExe -Algorithm SHA256).Hash.ToLower();scoop_source=$scoop;scenarios=[ordered]@{}}
$installedBefore = $null
$created = $false
try {
    Assert-True ((Test-Path -LiteralPath $scoop)) "Scoop was not found at $scoop"
    Assert-True (-not (Test-Path -LiteralPath $bucket)) "Temporary bucket already exists: $bucket"
    Assert-True (-not (Test-Path -LiteralPath $app)) "Test package already exists: $app"
    Assert-True (-not (Test-Path -LiteralPath $store)) "Test persist store already exists: $store"
    $installedBefore = (Coop 'list-before' @('list','--json')).output | ConvertFrom-Json
    Save-Json 'installed-before.json' $installedBefore
    New-Item -ItemType Directory -Path (Join-Path $bucket 'bucket') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $store 'config') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $store 'config/settings.ini') -Value 'coop-r15-user-data' -NoNewline
    Write-Manifest '1' $fixture1
    $created = $true

    # Coop installs v1; Scoop must see the same installation and republish it.
    $install = Coop 'install-v1' @('install',"$bucketName/$package",'--json')
    Assert-True ($install.exit -eq 0) "Coop install failed: $($install.output)"
    Assert-True ((& (Join-Path $ScoopRoot "shims/$package.exe")) -eq 'fixture 1') 'Coop v1 program did not run'
    $scoopList = Scoop 'scoop-list-v1' @('list')
    Assert-True ($scoopList.exit -eq 0 -and $scoopList.output -match [regex]::Escape($package)) 'Scoop did not list the Coop-installed package'
    $scoopReset1 = Scoop 'scoop-reset-v1' @('reset',$package)
    Assert-True ($scoopReset1.exit -eq 0) "Scoop reset v1 failed: $($scoopReset1.output)"
    Assert-True ((& (Join-Path $ScoopRoot "shims/$package.exe")) -eq 'fixture 1') 'Scoop reset v1 did not keep the Coop version runnable'
    $summary.scenarios.scoop_after_coop_install = @{version='1';program='fixture 1';scoop_list_exit=$scoopList.exit;scoop_reset_exit=$scoopReset1.exit}

    # Coop updates to v2, then Scoop manages the updated installation.
    Write-Manifest '2' $fixture2
    $update = Coop 'update-v2' @('update',$package,'--json')
    Assert-True ($update.exit -eq 0) "Coop update failed: $($update.output)"
    $updateResult = Read-Json $update.output
    Assert-True ($updateResult.retained_versions -contains '1') 'Coop update did not retain v1'
    Assert-True ((& (Join-Path $ScoopRoot "shims/$package.exe")) -eq 'fixture 2') 'Coop v2 program did not run'
    $scoopReset2 = Scoop 'scoop-reset-v2' @('reset',$package)
    Assert-True ($scoopReset2.exit -eq 0) "Scoop reset v2 failed: $($scoopReset2.output)"
    Assert-True ((& (Join-Path $ScoopRoot "shims/$package.exe")) -eq 'fixture 2') 'Scoop reset v2 did not keep the updated program runnable'
    $storeHashBefore = (Get-FileHash -LiteralPath (Join-Path $store 'config/settings.ini') -Algorithm SHA256).Hash
    $summary.scenarios.coop_update_then_scoop = @{version='2';retained=@($updateResult.retained_versions);scoop_reset_exit=$scoopReset2.exit;store_hash=$storeHashBefore}

    # Remove the bucket Manifest: rollback must use only the local version directory.
    Remove-Item -LiteralPath (Join-Path $bucket "bucket/$package.json") -Force
    $preview = Coop 'reset-preview-v1' @('reset',"$package@1",'--dry-run','--json')
    Assert-True ($preview.exit -eq 0) "Coop reset preview failed: $($preview.output)"
    $previewResult = Read-Json $preview.output
    $planned = @($previewResult.ir_operations | ForEach-Object operation)
    Assert-True ($previewResult.execution_available -eq $true) 'Reset preview was not executable'
    Assert-True ($previewResult.local_version_reference.network -eq 'none' -and $previewResult.local_version_reference.download_url_guessed -eq $false) 'Reset preview did not declare the local-only source'
    Assert-True (($planned -contains 'publish-current') -and ($planned -notcontains 'download') -and ($planned -notcontains 'extract')) 'Reset plan was not a local republish'
    $reset = Coop 'reset-v1' @('reset',"$package@1",'--json')
    Assert-True ($reset.exit -eq 0) "Coop reset to v1 failed without a bucket Manifest: $($reset.output)"
    $resetResult = Read-Json $reset.output
    Assert-True ((& (Join-Path $ScoopRoot "shims/$package.exe")) -eq 'fixture 1') 'Coop reset did not run v1'
    Assert-True (Test-Path -LiteralPath (Join-Path $app '2')) 'Coop reset deleted the replaced version'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $store 'config/settings.ini') -Algorithm SHA256).Hash -eq $storeHashBefore) 'Coop reset changed stored data'
    $journal = Last-Journal 'reset'
    Assert-True ((@($journal.observed_steps) -join ',') -eq ($planned -join ',')) 'Coop reset execution did not follow the previewed plan'
    $scoopResetBack = Scoop 'scoop-reset-rollback' @('reset',$package)
    Assert-True ($scoopResetBack.exit -eq 0) "Scoop reset after Coop rollback failed: $($scoopResetBack.output)"
    Assert-True ((& (Join-Path $ScoopRoot "shims/$package.exe")) -eq 'fixture 1') 'Scoop could not continue after the Coop rollback'
    $summary.scenarios.coop_rollback_then_scoop = @{version='1';reset_from=$resetResult.reset_from;retained=@($resetResult.retained_versions);
        planned=$planned;observed=@($journal.observed_steps);data_rollback=$resetResult.data_rollback;scoop_reset_exit=$scoopResetBack.exit}

    # Cleanup removes only the retained v2; the current v1 and the store stay usable.
    $cleanupPreview = Coop 'cleanup-preview' @('cleanup',$package,'--dry-run','--json')
    Assert-True ($cleanupPreview.exit -eq 0) "Cleanup preview failed: $($cleanupPreview.output)"
    $cleanupPreviewResult = Read-Json $cleanupPreview.output
    $scope = @($cleanupPreviewResult[0].delete_scope)
    Assert-True ($scope.Count -eq 1 -and $scope[0].version -eq '2') "Cleanup preview scope was not exactly v2: $($cleanupPreview.output)"
    Save-Json 'cleanup-preview.json' $cleanupPreviewResult
    $cleanup = Coop 'cleanup-run' @('cleanup',$package,'--json')
    Assert-True ($cleanup.exit -eq 0) "Cleanup failed: $($cleanup.output)"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $app '2'))) 'Cleanup did not remove the retained v2'
    Assert-True (Test-Path -LiteralPath (Join-Path $app '1')) 'Cleanup removed the current v1'
    Assert-True ((& (Join-Path $ScoopRoot "shims/$package.exe")) -eq 'fixture 1') 'Cleanup broke the current program'
    Assert-True (Test-Path -LiteralPath (Join-Path $store 'config/settings.ini')) 'Cleanup followed the persistence link and removed stored data'
    $summary.scenarios.cleanup = @{delete_scope=$scope;removed=@($cleanup.output);store_retained=$true}

    # Explicit purge deletes only the declared store after a clear preview.
    $purgePreview = Coop 'purge-preview' @('uninstall',$package,'--purge','--dry-run','--json')
    Assert-True ($purgePreview.exit -eq 0) "Purge preview failed: $($purgePreview.output)"
    $purgePreviewResult = Read-Json $purgePreview.output
    Assert-True (@($purgePreviewResult.purge.scope).Count -eq 1) "Purge preview did not list one declared store: $($purgePreview.output)"
    Assert-True (Test-Path -LiteralPath (Join-Path $store 'config/settings.ini')) 'Purge preview changed stored data'
    $uninstall = Coop 'uninstall-purge' @('uninstall',$package,'--purge','--json')
    Assert-True ($uninstall.exit -eq 0) "Purge uninstall failed: $($uninstall.output)"
    $uninstallResult = Read-Json $uninstall.output
    Assert-True ($uninstallResult.data_retained -eq $false) 'Purge did not report explicit data deletion'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $store 'config'))) 'Purge left the declared store'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $ScoopRoot "shims/$package.exe"))) 'Uninstall left the command entry'
    $summary.scenarios.purge = @{scope=@($purgePreviewResult.purge.scope);data_retained=$uninstallResult.data_retained;declared_store_exists=$false}

    $installedAfter = (Coop 'list-after' @('list','--json')).output | ConvertFrom-Json
    $beforeNames = @($installedBefore | ForEach-Object name | Sort-Object)
    $afterNames = @($installedAfter | ForEach-Object name | Sort-Object)
    Assert-True (($beforeNames -join ',') -eq ($afterNames -join ',')) "Real-root inventory changed: before=$($beforeNames -join ',') after=$($afterNames -join ',')"
    $summary.inventory_before = $beforeNames
    $summary.inventory_after = $afterNames
    $summary.status = 'pass'
} finally {
    if ($created) {
        try { Coop 'cleanup-uninstall' @('uninstall',$package,'--json') | Out-Null } catch { }
        foreach ($path in @($app,$store)) {
            if (Test-Path -LiteralPath $path) {
                $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
                $rootPrefix = [IO.Path]::GetFullPath($ScoopRoot).TrimEnd('\') + '\'
                if (-not ($full+'\').StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to remove a path outside the real root: $full" }
                Remove-Item -LiteralPath $full -Recurse -Force
            }
        }
        if (Test-Path -LiteralPath $bucket) { Remove-Item -LiteralPath $bucket -Recurse -Force }
        $record = Join-Path $ScoopRoot ".coop/packages/$package.json"
        $retained = Join-Path $ScoopRoot ".coop/retained/$package.json"
        foreach ($path in @($record,$retained)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
        foreach ($name in @($package)) {
            foreach ($extension in @('.exe','.shim','.coop-shim.json')) {
                $entry = Join-Path $ScoopRoot "shims/$name$extension"
                if (Test-Path -LiteralPath $entry) { Remove-Item -LiteralPath $entry -Force }
            }
        }
    }
    $summary.commands = $commands
    $summary.commands | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceDir 'commands.json') -Encoding utf8
    Save-Json 'summary.json' $summary
}
if ($summary.status -ne 'pass') { throw 'Real-root old-version acceptance did not complete' }
Write-Output "PASS real Scoop/Coop old-version retention, local rollback, cleanup and purge: $ScoopRoot"
exit 0

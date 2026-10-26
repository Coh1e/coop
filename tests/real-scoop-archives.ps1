param(
    [Parameter(Mandatory)][string]$CoopExe,
    [Parameter(Mandatory)][string]$EvidenceDir,
    [string]$ScoopRoot = 'C:\Users\Neo\scoop'
)
$ErrorActionPreference = 'Stop'
$EvidenceDir = [IO.Path]::GetFullPath($EvidenceDir)
New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$ScoopRoot = [IO.Path]::GetFullPath($ScoopRoot)
$scoop = (Get-Command scoop.ps1 -ErrorAction Stop).Source
$guard = Join-Path (Split-Path $CoopExe) 'process_guard.exe'
if (-not (Test-Path -LiteralPath $guard)) { throw "Missing process guard: $guard" }
$commands = [System.Collections.Generic.List[object]]::new()
$installedByTest = [System.Collections.Generic.List[string]]::new()
$previousGuardTimeout = $env:COOP_PROCESS_GUARD_TIMEOUT_MS
$env:COOP_PROCESS_GUARD_TIMEOUT_MS = '120000'
$temporaryPackages = @('coop-r05-zip','coop-r05-targz','coop-r05-7z','coop-r05-shared')
function Run([string]$name,[string]$exe,[string[]]$arguments) {
    $log = Join-Path $EvidenceDir (($name -replace '[\\/:*?"<>|]','-')+'.log')
    $output = & $exe @arguments 2>&1 | Out-String
    $exit = $LASTEXITCODE
    Set-Content -LiteralPath $log -Value $output -Encoding utf8
    $commands.Add([pscustomobject]@{name=$name;exe=$exe;arguments=$arguments;exit=$exit;log=$log})
    return [pscustomobject]@{exit=$exit;output=$output;log=$log}
}
function Coop([string]$name,[string[]]$arguments) { return Run $name $CoopExe (@('--root',$ScoopRoot)+$arguments) }
function Scoop([string]$name,[string[]]$arguments) { return Run $name $scoop $arguments }
function Assert-True([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
function HashOf([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower() }
function File-Uri([string]$Path) { return ([Uri][IO.Path]::GetFullPath($Path)).AbsoluteUri }
function InstalledEntry([string]$Name) {
    $items = (Coop ($Name+'-list') @('list','--json')).output | ConvertFrom-Json
    $entry = @($items | Where-Object { $_.name -eq $Name -and ($_.status -eq 'installed' -or $_.status -eq 'ready') })
    if ($entry.Count -eq 0) { return $null }
    if ($entry.Count -ne 1) { throw "Duplicate installed entries for $Name" }
    return $entry[0]
}
function Assert-PlanMatchesJournal($Plan,$Journal,[string]$Name) {
    $planned = @($Plan.ir_operations | ForEach-Object operation)
    $observed = @($Journal.observed_steps)
    Assert-True (($planned -join ',') -eq ($observed -join ',')) "execution did not follow the displayed plan for $Name`: planned=$($planned -join ',') observed=$($observed -join ',')"
    return [pscustomobject]@{planned=$planned;observed=$observed}
}
function LatestJournal {
    $entry = Get-ChildItem "$ScoopRoot/.coop/transactions" -Directory | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($null -eq $entry) { return $null }
    return (Get-Content -LiteralPath (Join-Path $entry.FullName 'journal.json') -Raw | ConvertFrom-Json)
}
function Write-PackageManifest([string]$Name,[object]$Manifest) {
    $Manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath "$tempBucket/bucket/$Name.json" -Encoding utf8
}
function Install-CoOp([string]$Name,[string[]]$Options = @()) {
    $preview = Coop ($Name+'-preview') (@('install',$Name)+$Options+@('--dry-run','--json'))
    Assert-True ($preview.exit -eq 0) "Coop install preview failed for $Name`: $($preview.output)"
    $plan = $preview.output | ConvertFrom-Json
    Assert-True ($plan.execution_available -eq $true) "Coop install preview was not executable for $Name`: $($preview.output)"
    $install = Coop ($Name+'-install') (@('install',$Name)+$Options+@('--json'))
    Assert-True ($install.exit -eq 0) "Coop install failed for $Name`: $($install.output)"
    $installedByTest.Add(($Name.Split('/')[-1]))
    $planMatch = Assert-PlanMatchesJournal $plan (Get-Content -LiteralPath (($install.output | ConvertFrom-Json).journal) -Raw | ConvertFrom-Json) $Name
    return [pscustomobject]@{plan=$plan;plan_match=$planMatch;install=$install.output}
}
function Update-CoOp([string]$Name) {
    $preview = Coop ($Name+'-update-preview') @('update',$Name,'--dry-run','--json')
    Assert-True ($preview.exit -eq 0) "Coop update preview failed for $Name`: $($preview.output)"
    $plan = $preview.output | ConvertFrom-Json
    Assert-True ($plan.execution_available -eq $true) "Coop update preview was not executable for $Name`: $($preview.output)"
    $update = Coop ($Name+'-update') @('update',$Name,'--json')
    Assert-True ($update.exit -eq 0) "Coop update failed for $Name`: $($update.output)"
    $planMatch = Assert-PlanMatchesJournal $plan (Get-Content -LiteralPath (($update.output | ConvertFrom-Json).journal) -Raw | ConvertFrom-Json) $Name
    return [pscustomobject]@{plan=$plan;plan_match=$planMatch;update=$update.output}
}
function Assert-Runs([string]$Name,[string]$Program,[string[]]$Arguments,[string]$Pattern) {
    $run = Run ($Name+'-run-temp') "$ScoopRoot/shims/$Program.exe" $Arguments
    Assert-True ($run.exit -eq 0 -and $run.output -match $Pattern) "program $Program did not run with $Pattern for $Name`: $($run.output)"
    return $run.output.Trim()
}
function Reset-And-Run([string]$Name,[string]$Package,[string]$Program,[string[]]$Arguments,[string]$Pattern) {
    $reset = Scoop ($Name+'-scoop-reset') @('reset',$Package)
    Assert-True ($reset.exit -eq 0) "Scoop reset failed for $Package`: $($reset.output)"
    $run = Run ($Name+'-run-after-reset') "$ScoopRoot/shims/$Program.exe" $Arguments
    Assert-True ($run.exit -eq 0 -and $run.output -match $Pattern) "Scoop-reset $Program did not run for $Package`: $($run.output)"
    $entry = InstalledEntry $Package
    Assert-True ($null -ne $entry) "Coop did not re-identify the Scoop-reset installation of $Package"
    return $run.output.Trim()
}
function Remove-TestInstall([string]$Name,[string]$Alias = $Name) {
    $aliases = @($Alias)
    $recordPath = "$ScoopRoot/.coop/packages/$Name.json"
    if (Test-Path -LiteralPath $recordPath) {
        $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
        $recordedAliases = @($record.commands | Where-Object { $_.name } | ForEach-Object { $_.name })
        if ($recordedAliases.Count -gt 0) { $aliases = $recordedAliases }
    }
    $entry = InstalledEntry $Name
    if ($null -ne $entry) {
        $cleanup = Coop ($Name+'-cleanup') @('cleanup',$Name,'--json')
        Assert-True ($cleanup.exit -eq 0) "Coop cleanup failed for $Name`: $($cleanup.output)"
        $remove = Coop ($Name+'-uninstall') @('uninstall',$Name,'--json')
        Assert-True ($remove.exit -eq 0) "Coop uninstall failed for $Name`: $($remove.output)"
    }
    $installedByTest.Remove($Name) | Out-Null
    Assert-True (-not (Test-Path "$ScoopRoot/apps/$Name/current")) "Coop uninstall left current for $Name"
    foreach ($entryAlias in $aliases) {
        Assert-True (-not (Test-Path "$ScoopRoot/shims/$entryAlias.exe") -and -not (Test-Path "$ScoopRoot/shims/$entryAlias.coop-shim.json")) "Coop uninstall left a command entry for $Name ($entryAlias)"
    }
    $scoopList = Scoop ($Name+'-scoop-list-after') @('list',$Name)
    Assert-True ($scoopList.output -notmatch [regex]::Escape($Name)) "Scoop still lists $Name after the Coop uninstall: $($scoopList.output)"
}
$tempBucket = $null
try {
    $inventoryBefore = (Coop 'coop-list-before' @('list','--json')).output | ConvertFrom-Json
    $scoopVersion = (Scoop 'scoop-version' @('--version')).output
    $bucketHead = (& git -C "$ScoopRoot/buckets/main" rev-parse HEAD 2>&1 | Out-String).Trim()
    foreach ($name in @('luajit','curl','unzip','tidy') + $temporaryPackages) {
        Assert-True ($null -eq (InstalledEntry $name)) "The selected real package is already installed; refusing to change it: $name"
    }
    $tempBucketName = 'coop-r05-archives'
    $tempBucket = "$ScoopRoot/buckets/$tempBucketName"
    Assert-True (-not (Test-Path $tempBucket)) "A temporary bucket path already exists: $tempBucket"
    New-Item -ItemType Directory -Path "$tempBucket/bucket" -Force | Out-Null
    $scenarios = @()

    # 1. ZIP with extract_dir, Coop install -> Scoop reset -> Coop update -> Scoop continue.
    Write-PackageManifest 'coop-r05-zip' @{
        version='14.1.1'; architecture=@{'64bit'=@{
            url='https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-x86_64-pc-windows-msvc.zip';
            hash='d0f534024c42afd6cb4d38907c25cd2b249b79bbe6cc1dbee8e3e37c2b6e25a1';
            extract_dir='ripgrep-14.1.1-x86_64-pc-windows-msvc'}};
        bin=@(,@('rg.exe','coop-r05-rg'))}
    $zipInstall = Install-CoOp "$tempBucketName/coop-r05-zip"
    $zipRunOld = Assert-Runs 'zip-old' 'coop-r05-rg' @('--version') 'ripgrep 14\.1\.1'
    $zipScoopList = Scoop 'zip-scoop-list' @('list','coop-r05-zip')
    Assert-True ($zipScoopList.exit -eq 0 -and $zipScoopList.output -match '14\.1\.1') "Scoop did not recognize the Coop ZIP install: $($zipScoopList.output)"
    $zipResetRun = Reset-And-Run 'zip' 'coop-r05-zip' 'coop-r05-rg' @('--version') 'ripgrep 14\.1\.1'
    Write-PackageManifest 'coop-r05-zip' @{
        version='15.2.0'; architecture=@{'64bit'=@{
            url='https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-x86_64-pc-windows-msvc.zip';
            hash='71b2fef860abe467217a538ff31de02f5258807c0129f771846f87bd029aafc5';
            extract_dir='ripgrep-15.2.0-x86_64-pc-windows-msvc'}};
        bin=@(,@('rg.exe','coop-r05-rg'))}
    $zipUpdate = Update-CoOp 'coop-r05-zip'
    $zipRunNew = Assert-Runs 'zip-new' 'coop-r05-rg' @('--version') 'ripgrep 15\.2\.0'
    Assert-True (Test-Path "$ScoopRoot/apps/coop-r05-zip/14.1.1/rg.exe") 'ZIP update did not retain the previous version'
    $zipScoopListNew = Scoop 'zip-scoop-list-new' @('list','coop-r05-zip')
    Assert-True ($zipScoopListNew.output -match '15\.2\.0') "Scoop did not recognize the Coop ZIP update: $($zipScoopListNew.output)"
    $zipScoopUpdate = Scoop 'zip-scoop-update' @('update','coop-r05-zip')
    Assert-True ($zipScoopUpdate.exit -eq 0) "Scoop could not continue managing the Coop ZIP update: $($zipScoopUpdate.output)"
    $zipResetNew = Reset-And-Run 'zip-new' 'coop-r05-zip' 'coop-r05-rg' @('--version') 'ripgrep 15\.2\.0'
    Remove-TestInstall 'coop-r05-zip' 'coop-r05-rg'
    Assert-True (-not (Test-Path "$ScoopRoot/apps/coop-r05-zip/14.1.1")) 'ZIP cleanup did not remove the old version'
    $scenarios += [pscustomobject]@{name='zip';install=$zipInstall.plan_match;update=$zipUpdate.plan_match;old_output=$zipRunOld;new_output=$zipRunNew;after_reset=$zipResetRun;after_reset_new=$zipResetNew;scoop_list=$zipScoopListNew.output.Trim()}

    # 2. tar.gz with Coop install, update and Scoop reset.
    Write-PackageManifest 'coop-r05-targz' @{
        version='1.67.3';
        url='https://github.com/air-verse/air/releases/download/v1.67.3/air_1.67.3_windows_amd64.tar.gz';
        hash='150ab78cf4a48f46ca845660b41a913b0bae94572c061ea5dbe75cd745849a5a';
        bin=@(,@('air.exe','coop-r05-air'))}
    $tarInstall = Install-CoOp "$tempBucketName/coop-r05-targz"
    $tarOld = Assert-Runs 'targz-old' 'coop-r05-air' @('-v') '1\.67\.3'
    Write-PackageManifest 'coop-r05-targz' @{
        version='1.67.4';
        url='https://github.com/air-verse/air/releases/download/v1.67.4/air_1.67.4_windows_amd64.tar.gz';
        hash='c35dbd568cff98055cc382d003bfda06bcdae82389568fb5e60ce5da278fa79d';
        bin=@(,@('air.exe','coop-r05-air'))}
    $tarUpdate = Update-CoOp 'coop-r05-targz'
    $tarNew = Assert-Runs 'targz-new' 'coop-r05-air' @('-v') '1\.67\.4'
    Assert-True (Test-Path "$ScoopRoot/apps/coop-r05-targz/1.67.3/air.exe") 'tar.gz update did not retain the previous version'
    $tarScoopList = Scoop 'targz-scoop-list' @('list','coop-r05-targz')
    Assert-True ($tarScoopList.output -match '1\.67\.4') "Scoop did not recognize the Coop tar.gz update: $($tarScoopList.output)"
    $tarReset = Reset-And-Run 'targz-new' 'coop-r05-targz' 'coop-r05-air' @('-v') '1\.67\.4'
    Remove-TestInstall 'coop-r05-targz' 'coop-r05-air'
    $scenarios += [pscustomobject]@{name='targz';install=$tarInstall.plan_match;update=$tarUpdate.plan_match;old_output=$tarOld;new_output=$tarNew;after_reset=$tarReset;scoop_list=$tarScoopList.output.Trim()}

    # 3. 7z with a real old version from this machine and the current Main manifest.
    $fastOldPath = "$ScoopRoot/apps/fastfetch/2.68.1/manifest.json"
    $fastNewPath = "$ScoopRoot/buckets/main/bucket/fastfetch.json"
    Assert-True (Test-Path $fastOldPath) "The real fastfetch 2.68.1 manifest is missing: $fastOldPath"
    $fastOld = Get-Content -LiteralPath $fastOldPath -Raw | ConvertFrom-Json
    $fastOld.bin = @(,@('fastfetch.exe','coop-r05-ff'))
    Write-PackageManifest 'coop-r05-7z' $fastOld
    $sevenInstall = Install-CoOp "$tempBucketName/coop-r05-7z"
    $sevenOld = Assert-Runs '7z-old' 'coop-r05-ff' @('--version') 'fastfetch 2\.68\.1'
    $fastNew = Get-Content -LiteralPath $fastNewPath -Raw | ConvertFrom-Json
    $fastNew.bin = @(,@('fastfetch.exe','coop-r05-ff'))
    Write-PackageManifest 'coop-r05-7z' $fastNew
    $sevenUpdate = Update-CoOp 'coop-r05-7z'
    $sevenNew = Assert-Runs '7z-new' 'coop-r05-ff' @('--version') 'fastfetch 2\.70\.0'
    Assert-True (Test-Path "$ScoopRoot/apps/coop-r05-7z/2.68.1/fastfetch.exe") '7z update did not retain the previous version'
    $sevenScoopList = Scoop '7z-scoop-list' @('list','coop-r05-7z')
    Assert-True ($sevenScoopList.output -match '2\.70\.0') "Scoop did not recognize the Coop 7z update: $($sevenScoopList.output)"
    $sevenReset = Reset-And-Run '7z-new' 'coop-r05-7z' 'coop-r05-ff' @('--version') 'fastfetch 2\.70\.0'
    Remove-TestInstall 'coop-r05-7z' 'coop-r05-ff'
    $scenarios += [pscustomobject]@{name='7z';install=$sevenInstall.plan_match;update=$sevenUpdate.plan_match;old_output=$sevenOld;new_output=$sevenNew;after_reset=$sevenReset;scoop_list=$sevenScoopList.output.Trim()}

    # 4. Scoop installs an archive package, Coop updates it without a private record, then
    #    Scoop resets the entry and Coop removes it. A corrupt v3 archive must leave v2 running.
    Write-PackageManifest 'coop-r05-shared' @{
        version='1.67.3';
        url='https://github.com/air-verse/air/releases/download/v1.67.3/air_1.67.3_windows_amd64.tar.gz';
        hash='150ab78cf4a48f46ca845660b41a913b0bae94572c061ea5dbe75cd745849a5a';
        bin=@(,@('air.exe','coop-r05-shared'))}
    $scoopInstall = Scoop 'shared-scoop-install' @('install',"$tempBucketName/coop-r05-shared")
    Assert-True ($scoopInstall.exit -eq 0) "Scoop could not install the shared archive fixture: $($scoopInstall.output)"
    $installedByTest.Add('coop-r05-shared')
    Assert-True (Test-Path "$ScoopRoot/apps/coop-r05-shared/1.67.3/air.exe") 'Scoop did not create the expected archive layout'
    Assert-True (-not (Test-Path "$ScoopRoot/.coop/packages/coop-r05-shared.json")) 'The Scoop archive installation unexpectedly has a Coop private record'
    $sharedOld = Assert-Runs 'shared-old' 'coop-r05-shared' @('-v') '1\.67\.3'
    $sharedList = InstalledEntry 'coop-r05-shared'
    Assert-True ($null -ne $sharedList -and $sharedList.version -eq '1.67.3') 'Coop did not identify the Scoop archive installation'
    Write-PackageManifest 'coop-r05-shared' @{
        version='1.67.4';
        url='https://github.com/air-verse/air/releases/download/v1.67.4/air_1.67.4_windows_amd64.tar.gz';
        hash='c35dbd568cff98055cc382d003bfda06bcdae82389568fb5e60ce5da278fa79d';
        bin=@(,@('air.exe','coop-r05-shared'))}
    $sharedUpdate = Update-CoOp 'coop-r05-shared'
    $sharedNew = Assert-Runs 'shared-new' 'coop-r05-shared' @('-v') '1\.67\.4'
    Assert-True (Test-Path "$ScoopRoot/apps/coop-r05-shared/1.67.3/air.exe") 'shared archive update did not retain the previous version'
    $sharedScoopList = Scoop 'shared-scoop-list' @('list','coop-r05-shared')
    Assert-True ($sharedScoopList.output -match '1\.67\.4') "Scoop did not recognize the Coop-updated shared archive: $($sharedScoopList.output)"
    $sharedScoopUpdate = Scoop 'shared-scoop-update' @('update','coop-r05-shared')
    Assert-True ($sharedScoopUpdate.exit -eq 0) "Scoop could not continue managing the Coop-updated shared archive: $($sharedScoopUpdate.output)"
    $sharedReset = Reset-And-Run 'shared-new' 'coop-r05-shared' 'coop-r05-shared' @('-v') '1\.67\.4'
    $corrupt = Join-Path $EvidenceDir 'corrupt-archive.tar.gz'
    [IO.File]::WriteAllBytes($corrupt,[byte[]](1..1024 | ForEach-Object { $_ % 251 }))
    Write-PackageManifest 'coop-r05-shared' @{
        version='1.67.5';
        url=(File-Uri $corrupt);
        hash=(HashOf $corrupt);
        bin=@(,@('air.exe','coop-r05-shared'))}
    $failedUpdate = Coop 'shared-corrupt-update' @('update','coop-r05-shared','--json')
    Assert-True ($failedUpdate.exit -ne 0) 'A corrupt shared archive update unexpectedly succeeded'
    $afterFailure = Assert-Runs 'shared-after-failure' 'coop-r05-shared' @('-v') '1\.67\.4'
    Assert-True (-not (Test-Path "$ScoopRoot/apps/coop-r05-shared/1.67.5")) 'A corrupt shared archive update published the target version'
    $failedJournal = LatestJournal
    Assert-True ($failedJournal.state -eq 'rolled-back' -and @($failedJournal.observed_steps | Where-Object { $_ -eq 'extract' }).Count -ge 1) 'The corrupt shared archive update left no rolled-back extract evidence'
    Remove-TestInstall 'coop-r05-shared' 'coop-r05-shared'
    $scenarios += [pscustomobject]@{name='shared-archive';scoop_install=$scoopInstall.output.Trim();old_output=$sharedOld;update=$sharedUpdate.plan_match;new_output=$sharedNew;after_reset=$sharedReset;
        corrupt_update=@{exit=$failedUpdate.exit;observed_steps=@($failedJournal.observed_steps);current_after=$afterFailure}}

    # 5. Real Main packages: tar.zst/nested, tar.xz, 7z SFX and nested ZIP. Each Coop install is
    #    observed with process_guard, so an external 7z.exe/tar.exe extractor would fail the test.
    foreach ($case in @(
        @{name='luajit'; program='luajit'; args=@('-v'); pattern='LuaJIT 2\.1'; tree='bin/luajit.exe'},
        @{name='curl'; program='curl'; args=@('--version'); pattern='8\.23\.0'; tree='bin/curl.exe'},
        @{name='unzip'; program='unzip'; args=@('-v'); pattern='UnZip 6\.00'; tree='unzip.exe'},
        @{name='tidy'; program='tidy'; args=@('--version'); pattern='5\.8\.0'; tree='tidy.exe'}
    )) {
        $preview = Coop ($case.name+'-main-preview') @('install',$case.name,'--dry-run','--json')
        Assert-True ($preview.exit -eq 0) "Coop install preview failed for $($case.name): $($preview.output)"
        $plan = $preview.output | ConvertFrom-Json
        Assert-True ($plan.execution_available -eq $true) "Coop install preview was not executable for $($case.name): $($preview.output)"
        $guarded = Run ($case.name+'-guarded-install') $guard @($CoopExe,'--root',$ScoopRoot,'install',$case.name,'--json')
        Assert-True ($guarded.exit -eq 0) "Guarded Coop install failed or started an external extractor for $($case.name): $($guarded.output)"
        $installedByTest.Add($case.name)
        $guardStart = $guarded.output.IndexOf('{')
        $guardEnd = $guarded.output.LastIndexOf('}')
        $guardedJson = $guarded.output.Substring($guardStart,$guardEnd-$guardStart+1) | ConvertFrom-Json
        $journal = Get-Content -LiteralPath $guardedJson.journal -Raw | ConvertFrom-Json
        $planMatch = Assert-PlanMatchesJournal $plan $journal $case.name
        $programRun = Assert-Runs ($case.name+'-main') $case.program $case.args $case.pattern
        Assert-True (Test-Path "$ScoopRoot/apps/$($case.name)/current/$($case.tree)") "The extracted tree is missing $($case.tree) for $($case.name)"
        $scoopList = Scoop ($case.name+'-main-scoop-list') @('list',$case.name)
        Assert-True ($scoopList.exit -eq 0 -and $scoopList.output -match [regex]::Escape($plan.package.version)) "Scoop did not recognize the Coop install of $($case.name): $($scoopList.output)"
        $resetRun = Reset-And-Run ($case.name+'-main') $case.name $case.program $case.args $case.pattern
        Remove-TestInstall $case.name $case.program
        $scenarios += [pscustomobject]@{name=$case.name;version=$plan.package.version;install=$planMatch;output=$programRun;after_reset=$resetRun;scoop_list=$scoopList.output.Trim()}
    }

    Remove-Item -LiteralPath $tempBucket -Recurse -Force
    Assert-True (-not (Test-Path $tempBucket)) 'The temporary real-root bucket was not removed'
    $inventoryAfter = (Coop 'coop-list-after' @('list','--json')).output | ConvertFrom-Json
    $beforeNames = @($inventoryBefore | ForEach-Object { $_.name } | Sort-Object)
    $afterNames = @($inventoryAfter | ForEach-Object { $_.name } | Sort-Object)
    Assert-True (($beforeNames -join ',') -eq ($afterNames -join ',')) "The real installation inventory changed: before=$($beforeNames -join ',') after=$($afterNames -join ',')"
    $evidence = [ordered]@{
        platform = (Get-CimInstance Win32_OperatingSystem).Caption
        scoop_root = $ScoopRoot
        scoop_version = $scoopVersion.Trim()
        bucket_head = $bucketHead
        coop_exe = $CoopExe
        coop_sha256 = (Get-FileHash -LiteralPath $CoopExe -Algorithm SHA256).Hash.ToLower()
        process_guard = $guard
        scenarios = $scenarios
        inventory_before = @($inventoryBefore | ForEach-Object { [pscustomobject]@{name=$_.name;version=$_.version;bucket=$_.bucket;management=$_.management} })
        inventory_after = @($inventoryAfter | ForEach-Object { [pscustomobject]@{name=$_.name;version=$_.version;bucket=$_.bucket;management=$_.management} })
        commands = @($commands)
        timestamp = [DateTime]::UtcNow.ToString('o')
    }
    $evidence | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $EvidenceDir 'real-scoop-archives-evidence.json') -Encoding utf8
    Write-Output "PASS real Scoop/Coop ZIP, 7z, tar series and nested archive management: $(Join-Path $EvidenceDir 'real-scoop-archives-evidence.json')"
} finally {
    foreach ($name in @($installedByTest)) {
        try { $cleanup = Coop ($name+'-failure-cleanup') @('cleanup',$name,'--json'); Write-Output "cleanup $name exit=$($cleanup.exit)" }
        catch { Write-Output "cleanup $name failed: $_" }
        try { $remove = Coop ($name+'-failure-uninstall') @('uninstall',$name,'--json'); Write-Output "uninstall $name exit=$($remove.exit)" }
        catch { Write-Output "uninstall $name failed: $_" }
    }
    foreach ($name in $temporaryPackages) {
        $directory = Join-Path $ScoopRoot "apps/$name"
        if ((Test-Path -LiteralPath $directory) -and -not (Test-Path -LiteralPath "$directory/current")) {
            try { Remove-Item -LiteralPath $directory -Recurse -Force; Write-Output "cleanup temporary app directory $directory" }
            catch { Write-Output "cleanup temporary app directory failed: $directory $_" }
        }
    }
    if ($tempBucket -and (Test-Path -LiteralPath $tempBucket)) {
        try { Remove-Item -LiteralPath $tempBucket -Recurse -Force; Write-Output "cleanup temporary bucket $tempBucket" }
        catch { Write-Output "cleanup temporary bucket failed: $_" }
    }
    if ($null -eq $previousGuardTimeout) { Remove-Item Env:COOP_PROCESS_GUARD_TIMEOUT_MS -ErrorAction SilentlyContinue }
    else { $env:COOP_PROCESS_GUARD_TIMEOUT_MS = $previousGuardTimeout }
}

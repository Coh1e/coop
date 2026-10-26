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
$commands = [System.Collections.Generic.List[object]]::new()
$installedByTest = [System.Collections.Generic.List[string]]::new()
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
function Assert-True([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
function HashOf([string]$Path,[string]$Algorithm) {
    (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash.ToLower()
}
function Get-PeMachine([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $offset = [BitConverter]::ToInt32($bytes,0x3c)
    if ([BitConverter]::ToUInt32($bytes,$offset) -ne 0x00004550) { throw "Not a PE file: $Path" }
    return [BitConverter]::ToUInt16($bytes,$offset+4)
}
function InstalledEntry([string]$Name) {
    $items = (Coop ($Name+'-list') @('list','--json')).output | ConvertFrom-Json
    $entry = @($items | Where-Object { $_.name -eq $Name -and ($_.status -eq 'installed' -or $_.status -eq 'ready') })
    if ($entry.Count -eq 0) { return $null }
    if ($entry.Count -ne 1) { throw "Duplicate installed entries for $Name" }
    return $entry[0]
}
function Assert-PlanMatchesJournal($Plan,$Journal) {
    $planned = @($Plan.ir_operations | ForEach-Object operation)
    $observed = @($Journal.observed_steps)
    Assert-True (($planned -join ',') -eq ($observed -join ',')) "execution did not follow the displayed plan: planned=$($planned -join ',') observed=$($observed -join ',')"
    Assert-True ($Plan.artifacts.Count -eq $Journal.artifacts.Count) 'the journal did not preserve every artifact source'
    for ($index = 0; $index -lt $Plan.artifacts.Count; $index++) {
        $declared = $Plan.artifacts[$index]
        $source = $Journal.artifacts[$index]
        Assert-True ($declared.url -eq $source.url -and $declared.filename -eq $source.filename -and
            $declared.algorithm -eq $source.algorithm -and $declared.digest -eq $source.digest -and
            $declared.renamed -eq $source.renamed) "artifact $index source evidence differs between preview and journal"
        Assert-True ($Journal.downloads[$index].observed_digest -eq $declared.digest -and
            $Journal.downloads[$index].verified -eq $true -and $Journal.downloads[$index].bytes -gt 0) "artifact $index has no verified download evidence"
    }
}
function LatestJournal {
    $entry = Get-ChildItem "$ScoopRoot/.coop/transactions" -Directory | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($null -eq $entry) { return $null }
    return (Get-Content -LiteralPath (Join-Path $entry.FullName 'journal.json') -Raw | ConvertFrom-Json)
}
function InstallAndCheck([string]$Name,[string[]]$InstallOptions,[string]$Program,[string[]]$ProgramArguments,
                          [string]$ExpectedProgramPattern,[int]$ExpectedPe,[int]$ExpectedArtifacts,
                          [string[]]$ExpectedAlgorithms,[bool]$RequireZeroExit = $true) {
    $before = InstalledEntry $Name
    Assert-True ($null -eq $before) "The selected real package is already installed; refusing to change it: $Name"
    $preview = Coop ($Name+'-preview') (@('install',$Name)+$InstallOptions+@('--dry-run','--json'))
    Assert-True ($preview.exit -eq 0) "Coop install preview failed for $Name`: $($preview.output)"
    $plan = $preview.output | ConvertFrom-Json
    Assert-True ($plan.execution_available -eq $true) "Coop install preview was not executable for $Name`: $($preview.output)"
    Assert-True ($plan.artifacts.Count -eq $ExpectedArtifacts) "The preview did not report $ExpectedArtifacts artifacts for $Name"
    for ($index = 0; $index -lt $ExpectedArtifacts; $index++) {
        Assert-True ($plan.artifacts[$index].algorithm -eq $ExpectedAlgorithms[$index]) "Artifact $index did not preserve the declared $($ExpectedAlgorithms[$index]) algorithm for $Name"
    }
    $install = Coop ($Name+'-install') (@('install',$Name)+$InstallOptions+@('--json'))
    Assert-True ($install.exit -eq 0) "Coop install failed for $Name`: $($install.output)"
    $installedByTest.Add($Name)
    $result = $install.output | ConvertFrom-Json
    $journal = Get-Content -LiteralPath $result.journal -Raw | ConvertFrom-Json
    Assert-PlanMatchesJournal $plan $journal
    $programRun = Run ($Name+'-run') "$ScoopRoot/shims/$Program" $ProgramArguments
    $effectiveExit = (-not $RequireZeroExit -or $programRun.exit -eq 0) -and $programRun.output -match $ExpectedProgramPattern
    Assert-True ($effectiveExit) "The installed program did not run with the expected output for $Name`: $($programRun.output)"
    $record = Get-Content -LiteralPath "$ScoopRoot/.coop/packages/$Name.json" -Raw | ConvertFrom-Json
    Assert-True ($record.version -eq $plan.package.version) "The Coop record lost the installed version for $Name"
    $standardManifest = if (Test-Path "$ScoopRoot/apps/$Name/current/scoop-manifest.json") { "$ScoopRoot/apps/$Name/current/scoop-manifest.json" } else { "$ScoopRoot/apps/$Name/current/manifest.json" }
    $standardRecord = Get-Content -LiteralPath $standardManifest -Raw | ConvertFrom-Json
    Assert-True ($standardRecord.version -eq $plan.package.version) "The standard Scoop install record lost the version for $Name"
    $scoopList = Scoop ($Name+'-scoop-list') @('list',$Name)
    Assert-True ($scoopList.exit -eq 0 -and $scoopList.output -match [regex]::Escape($plan.package.version)) "Scoop did not recognize the Coop installation of $Name`: $($scoopList.output)"
    $pe = $null
    if ($ExpectedPe -gt 0) {
        $pe = Get-PeMachine "$ScoopRoot/apps/$Name/current/$Program"
        Assert-True ($pe -eq $ExpectedPe) ("The installed $Name program has PE machine 0x{0:x4}, expected 0x{1:x4}" -f $pe,$ExpectedPe)
        Assert-True ($record.architecture -eq '32bit') "The Coop record did not keep the selected 32bit architecture for $Name"
        $installRecord = Get-Content -LiteralPath "$ScoopRoot/apps/$Name/current/scoop-install.json" -Raw | ConvertFrom-Json
        Assert-True ($installRecord.architecture -eq '32bit') "The standard Scoop install record did not keep the selected 32bit architecture for $Name"
    }
    $artifactEvidence = @()
    for ($index = 0; $index -lt $plan.artifacts.Count; $index++) {
        $declared = $plan.artifacts[$index]
        $path = "$ScoopRoot/apps/$Name/current/$($declared.filename)"
        if (Test-Path -LiteralPath $path) {
            $actual = HashOf $path $declared.algorithm.ToUpper()
            Assert-True ($actual -eq $declared.digest) "Installed $($declared.filename) does not match its declared $($declared.algorithm) digest for $Name"
            $artifactEvidence += [pscustomobject]@{filename=$declared.filename;algorithm=$declared.algorithm;digest=$declared.digest;verified=$true;renamed=$declared.renamed;url=$declared.url}
        } else {
            $artifactEvidence += [pscustomobject]@{filename=$declared.filename;algorithm=$declared.algorithm;digest=$declared.digest;verified='extracted-archive';renamed=$declared.renamed;url=$declared.url}
        }
    }
    return [pscustomobject]@{name=$Name;version=$plan.package.version;architecture=$plan.package.architecture;
        artifacts=$artifactEvidence;planned=$plan.ir_operations;observed=$journal.observed_steps;
        program_pattern=$ExpectedProgramPattern;program_output=$programRun.output.Trim();pe_machine=$pe;
        scoop_list=$scoopList.output.Trim();journal=$result.journal}
}
function UninstallAndCheck([string]$Name) {
    if (-not (Test-Path "$ScoopRoot/apps/$Name/current")) { return }
    $remove = Coop ($Name+'-uninstall') @('uninstall',$Name,'--json')
    Assert-True ($remove.exit -eq 0) "Coop uninstall failed for $Name`: $($remove.output)"
    Assert-True (-not (Test-Path "$ScoopRoot/apps/$Name/current")) "Coop uninstall left the current link for $Name"
    $gone = InstalledEntry $Name
    Assert-True ($null -eq $gone) "Coop still lists $Name after uninstall"
    $scoopList = Scoop ($Name+'-scoop-list-after') @('list',$Name)
    Assert-True ($scoopList.output -notmatch [regex]::Escape($Name)) "Scoop still lists $Name after the Coop uninstall"
    $installedByTest.Remove($Name) | Out-Null
}
$tempBucket = $null
try {
    $inventoryBefore = (Coop 'coop-list-before' @('list','--json')).output | ConvertFrom-Json
    $scoopVersion = (Scoop 'scoop-version' @('--version')).output
    $bucketHead = (& git -C "$ScoopRoot/buckets/main" rev-parse HEAD 2>&1 | Out-String).Trim()
    $scenarios = @()
    # Multiple downloads, fragment renames and SHA512, with JAR command entries.
    $scenarios += InstallAndCheck 'pdfbox' @() 'pdfbox.exe' @('version') '3\.0\.8' 0 2 @('sha512','sha512')
    UninstallAndCheck 'pdfbox'
    # Architecture-specific 32bit artifact selected through --arch, plus a fragment rename and SHA512.
    $scenarios += InstallAndCheck 'tcping' @('--arch','32bit') 'tcping.exe' @() 'tcping' 0x014c 1 @('sha512') $false
    # Scoop takes over the command entry, then Coop still recognizes and removes the installation.
    $reset = Scoop 'tcping-scoop-reset' @('reset','tcping')
    Assert-True ($reset.exit -eq 0) "Scoop reset failed for the Coop-installed tcping: $($reset.output)"
    $afterReset = InstalledEntry 'tcping'
    Assert-True ($null -ne $afterReset -and $afterReset.version -eq '0.39') 'Coop did not re-identify the Scoop-reset tcping installation'
    $resetRun = Run 'tcping-run-after-reset' "$ScoopRoot/shims/tcping.exe" @()
    Assert-True ($resetRun.output -match 'tcping') 'The Scoop-reset tcping entry did not run'
    UninstallAndCheck 'tcping'
    # Architecture-specific 32bit ZIP with extract_dir and SHA1.
    $scenarios += InstallAndCheck 'astyle' @('--arch','32bit') 'astyle.exe' @('--version') '3\.6\.20' 0x014c 1 @('sha1')
    UninstallAndCheck 'astyle'
    # MD5 digest with a fragment rename.
    $scenarios += InstallAndCheck 'thrift' @() 'thrift.exe' @('--version') '0\.25\.0' 0 1 @('md5')
    UninstallAndCheck 'thrift'
    # Real download and verification failures must keep the current version. A temporary
    # unmanaged bucket in the shared root points the real PDFBox artifact at a deliberately
    # wrong digest or a missing local file; it is removed again in the finally block.
    $tempBucketName = 'coop-r04-failure'
    $tempBucket = "$ScoopRoot/buckets/$tempBucketName"
    Assert-True (-not (Test-Path $tempBucket)) "A temporary bucket path already exists: $tempBucket"
    New-Item -ItemType Directory -Path "$tempBucket/bucket" -Force | Out-Null
    $pdfboxManifest = Get-Content -LiteralPath "$ScoopRoot/buckets/main/bucket/pdfbox.json" -Raw | ConvertFrom-Json
    $copyManifest = $pdfboxManifest | ConvertTo-Json -Depth 10
    $copyManifest | Set-Content "$tempBucket/bucket/pdfboxcopy.json" -Encoding utf8
    $copyPreview = Coop 'pdfboxcopy-preview' @('install',"$tempBucketName/pdfboxcopy",'--dry-run','--json')
    Assert-True ($copyPreview.exit -eq 0) "Preview of the real multi-artifact copy failed: $($copyPreview.output)"
    $copyPlan = $copyPreview.output | ConvertFrom-Json
    $copyInstall = Coop 'pdfboxcopy-install' @('install',"$tempBucketName/pdfboxcopy",'--json')
    Assert-True ($copyInstall.exit -eq 0) "Install of the real multi-artifact copy failed: $($copyInstall.output)"
    $installedByTest.Add('pdfboxcopy')
    $copyResult = $copyInstall.output | ConvertFrom-Json
    Assert-PlanMatchesJournal $copyPlan (Get-Content -LiteralPath $copyResult.journal -Raw | ConvertFrom-Json)
    $copyRun = Run 'pdfboxcopy-run' "$ScoopRoot/shims/pdfbox.exe" @('version')
    Assert-True ($copyRun.exit -eq 0 -and $copyRun.output -match '3\.0\.8') "The real multi-artifact copy did not run: $($copyRun.output)"
    $failedManifest = Get-Content -LiteralPath "$tempBucket/bucket/pdfboxcopy.json" -Raw | ConvertFrom-Json
    $failedManifest.version = '3.0.9'
    $failedManifest.hash[0] = 'sha512:'+('0'*128)
    $failedManifest | ConvertTo-Json -Depth 10 | Set-Content "$tempBucket/bucket/pdfboxcopy.json" -Encoding utf8
    $failedUpdate = Coop 'pdfboxcopy-verify-failure' @('update','pdfboxcopy','--json')
    Assert-True ($failedUpdate.exit -ne 0 -and $failedUpdate.output -match 'sha512 mismatch') "A real wrong SHA512 digest did not fail verification: $($failedUpdate.output)"
    $failedRun = Run 'pdfboxcopy-run-after-verify-failure' "$ScoopRoot/shims/pdfbox.exe" @('version')
    Assert-True ($failedRun.exit -eq 0 -and $failedRun.output -match '3\.0\.8') "Verification failure replaced the current version: $($failedRun.output)"
    Assert-True ((Get-Content "$ScoopRoot/.coop/packages/pdfboxcopy.json" -Raw | ConvertFrom-Json).version -eq '3.0.8') 'Verification failure changed the Coop record version'
    Assert-True (-not (Test-Path "$ScoopRoot/apps/pdfboxcopy/3.0.9")) 'Verification failure published the target version'
    $verifyJournal = LatestJournal
    Assert-True ($verifyJournal.state -eq 'rolled-back' -and @($verifyJournal.observed_steps | Where-Object { $_ -eq 'verify' }).Count -ge 1) 'Verification failure left no rolled-back transaction evidence'
    $missingManifest = Get-Content -LiteralPath "$tempBucket/bucket/pdfboxcopy.json" -Raw | ConvertFrom-Json
    $missingManifest.version = '3.1.0'
    $missingManifest.hash[0] = 'sha512:'+('0'*128)
    $missingManifest.url[0] = ([Uri][IO.Path]::GetFullPath((Join-Path $EvidenceDir 'missing-artifact.jar'))).AbsoluteUri
    $missingManifest | ConvertTo-Json -Depth 10 | Set-Content "$tempBucket/bucket/pdfboxcopy.json" -Encoding utf8
    $downloadFailure = Coop 'pdfboxcopy-download-failure' @('update','pdfboxcopy','--json')
    Assert-True ($downloadFailure.exit -ne 0) 'A missing real artifact download unexpectedly succeeded'
    $failedDownloadRun = Run 'pdfboxcopy-run-after-download-failure' "$ScoopRoot/shims/pdfbox.exe" @('version')
    Assert-True ($failedDownloadRun.exit -eq 0 -and $failedDownloadRun.output -match '3\.0\.8') "Download failure replaced the current version: $($failedDownloadRun.output)"
    Assert-True (-not (Test-Path "$ScoopRoot/apps/pdfboxcopy/3.1.0")) 'Download failure published the target version'
    UninstallAndCheck 'pdfboxcopy'
    Remove-Item -LiteralPath $tempBucket -Recurse -Force
    Assert-True (-not (Test-Path $tempBucket)) 'The temporary real-root bucket was not removed'
    $scenarios += [pscustomobject]@{name='pdfboxcopy-failure-protection';multi_artifact_copy=$true;
        verify_failure=@{exit=$failedUpdate.exit;observed_steps=@($verifyJournal.observed_steps);current_after='3.0.8'};
        download_failure=@{exit=$downloadFailure.exit;current_after=$failedDownloadRun.output.Trim()}}
    $inventoryAfter = (Coop 'coop-list-after' @('list','--json')).output | ConvertFrom-Json
    $evidence = [ordered]@{
        platform = (Get-CimInstance Win32_OperatingSystem).Caption
        scoop_root = $ScoopRoot
        scoop_version = $scoopVersion.Trim()
        bucket_head = $bucketHead
        coop_exe = $CoopExe
        coop_sha256 = (Get-FileHash -LiteralPath $CoopExe -Algorithm SHA256).Hash.ToLower()
        scenarios = $scenarios
        inventory_before = @($inventoryBefore | ForEach-Object { [pscustomobject]@{name=$_.name;version=$_.version;bucket=$_.bucket;management=$_.management} })
        inventory_after = @($inventoryAfter | ForEach-Object { [pscustomobject]@{name=$_.name;version=$_.version;bucket=$_.bucket;management=$_.management} })
        commands = @($commands)
        timestamp = [DateTime]::UtcNow.ToString('o')
    }
    $evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $EvidenceDir 'real-scoop-multi-evidence.json') -Encoding utf8
    Write-Output "PASS real Scoop/Coop multi-artifact, architecture and digest-algorithm management: $(Join-Path $EvidenceDir 'real-scoop-multi-evidence.json')"
} finally {
    foreach ($name in @($installedByTest)) {
        try { $cleanup = Coop ($name+'-failure-cleanup') @('uninstall',$name,'--json'); Write-Output "cleanup $name exit=$($cleanup.exit)" }
        catch { Write-Output "cleanup $name failed: $_" }
    }
    if ($tempBucket -and (Test-Path -LiteralPath $tempBucket)) {
        try { Remove-Item -LiteralPath $tempBucket -Recurse -Force; Write-Output "cleanup temporary bucket $tempBucket" }
        catch { Write-Output "cleanup temporary bucket failed: $_" }
    }
}

param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
$bucket = "$root/buckets/test/bucket"
$payloads = Join-Path $TestRoot 'payloads'
New-Item -ItemType Directory -Path $bucket,$payloads -Force | Out-Null
$source1 = Join-Path (Split-Path $CoopExe) 'fixture-1.exe'
$source2 = Join-Path (Split-Path $CoopExe) 'fixture-2.exe'
$extra1 = Join-Path $payloads 'extra-one.bin'
$extra2 = Join-Path $payloads 'extra-two.bin'
Copy-Item -LiteralPath $source1 -Destination $extra1
Copy-Item -LiteralPath $source2 -Destination $extra2

function HashOf([string]$Path,[string]$Algorithm) {
    (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm).Hash.ToLower()
}
function FileUri([string]$Path) {
    ([Uri][IO.Path]::GetFullPath($Path)).AbsoluteUri
}
function Invoke-Coop([string[]]$Arguments) {
    $output = Invoke-CoopNative $CoopExe  @Arguments
    [pscustomobject]@{ code = $LASTEXITCODE; text = ($output -join "`n") }
}
function Read-CoopJson([string[]]$Arguments) {
    $result = Invoke-Coop $Arguments
    if ($result.code -ne 0) { throw "coop $($Arguments -join ' ') failed ($($result.code)): $($result.text)" }
    return ($result.text | ConvertFrom-Json)
}
# The 32bit and 64bit sections intentionally select different payloads, so an ignored --arch
# would be visible in both the digest and the program output.
function Write-Manifest([string]$Version,[string]$Alpha,[string]$Beta,[string]$Extra) {
    $manifest = @{
        version = $Version
        bin = @('alpha.exe','beta.exe')
        architecture = @{
            '64bit' = @{
                url = @(((FileUri $source1)+'#/alpha.exe'),((FileUri $source2)+'#/beta.exe'),((FileUri $extra1)+'#/extra.bin'))
                hash = @(('sha512:'+(HashOf $source1 'SHA512')),('sha1:'+(HashOf $source2 'SHA1')),('md5:'+(HashOf $extra1 'MD5')))
            }
            '32bit' = @{
                url = @(((FileUri $Alpha)+'#/alpha.exe'),((FileUri $Beta)+'#/beta.exe'),((FileUri $Extra)+'#/extra.bin'))
                hash = @(('sha512:'+(HashOf $Alpha 'SHA512')),('sha1:'+(HashOf $Beta 'SHA1')),('md5:'+(HashOf $Extra 'MD5')))
            }
        }
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content "$bucket/multi.json" -Encoding utf8
}
function Current-Journals {
    @(Get-ChildItem "$root/.coop/transactions" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $journalPath = Join-Path $_.FullName 'journal.json'
        if (Test-Path $journalPath) {
            $journal = Get-Content $journalPath -Raw | ConvertFrom-Json
            [pscustomobject]@{ path = $journalPath; value = $journal }
        }
    })
}
function Assert-PlanMatchesJournal($Plan,$Journal) {
    $planned = @($Plan.ir_operations | ForEach-Object { $_.operation })
    $observed = @($Journal.observed_steps)
    if ($planned.Count -ne $observed.Count -or @(Compare-Object $planned $observed -SyncWindow 0).Count -ne 0) {
        throw "preview and journal operations differ: planned=$($planned -join ',') observed=$($observed -join ',')"
    }
    if ($Plan.artifacts.Count -ne $Journal.artifacts.Count) { throw 'journal did not preserve every declared artifact source' }
    for ($index = 0; $index -lt $Plan.artifacts.Count; $index++) {
        $plannedArtifact = $Plan.artifacts[$index]
        $source = $Journal.artifacts[$index]
        if ($plannedArtifact.url -ne $source.url -or $plannedArtifact.filename -ne $source.filename -or
            $plannedArtifact.algorithm -ne $source.algorithm -or $plannedArtifact.digest -ne $source.digest -or
            $plannedArtifact.renamed -ne $source.renamed) {
            throw "journal artifact $index differs from the preview"
        }
        if ($Journal.downloads[$index].observed_digest -ne $plannedArtifact.digest -or
            $Journal.downloads[$index].verified -ne $true -or $Journal.downloads[$index].bytes -le 0) {
            throw "journal download $index does not record the verified declared digest"
        }
    }
}

Write-Manifest '1.0.0' $source2 $source1 $extra2
$preview = Read-CoopJson @('--root',$root,'install','test/multi','--arch','32bit','--dry-run','--json')
if ($preview.action -ne 'install' -or $preview.package.architecture -ne '32bit' -or $preview.execution_available -ne $true) { throw '32bit multi-artifact preview is not executable' }
if ($preview.artifacts.Count -ne 3) { throw 'the preview did not report all three downloads' }
$expected = @(
    @{ filename='alpha.exe'; algorithm='sha512'; digest=(HashOf $source2 'SHA512') },
    @{ filename='beta.exe'; algorithm='sha1'; digest=(HashOf $source1 'SHA1') },
    @{ filename='extra.bin'; algorithm='md5'; digest=(HashOf $extra2 'MD5') })
for ($index = 0; $index -lt $expected.Count; $index++) {
    $artifact = $preview.artifacts[$index]
    if ($artifact.filename -ne $expected[$index].filename -or $artifact.algorithm -ne $expected[$index].algorithm -or
        $artifact.digest -ne $expected[$index].digest -or $artifact.renamed -ne $true -or $artifact.sha256) {
        throw "artifact $index did not preserve the declared rename and algorithm: $($artifact | ConvertTo-Json -Compress)"
    }
}
$kinds = @($preview.ir_operations | ForEach-Object { $_.operation })
if (@($kinds | Where-Object { $_ -eq 'verify' }).Count -ne 3) { throw 'the preview did not plan one verification per download' }
if (@($preview.ir_operations | Where-Object { $_.operation -eq 'verify' -and $_.effect -notmatch 'sha512|sha1|md5' }).Count) { throw 'a verify operation lost its declared algorithm' }

$install = Invoke-Coop @('--root',$root,'install','test/multi','--arch','32bit','--json')
if ($install.code -ne 0) { throw "multi-artifact install failed: $($install.text)" }
if ((& "$root/shims/alpha.exe") -ne 'fixture 2' -or (& "$root/shims/beta.exe") -ne 'fixture 1') { throw 'the 32bit artifact selection did not reach the installed programs' }
if (-not (Test-Path "$root/apps/multi/1.0.0/extra.bin")) { throw 'the additional artifact was not installed' }
$record = Get-Content "$root/.coop/packages/multi.json" -Raw | ConvertFrom-Json
if ($record.architecture -ne '32bit' -or $record.version -ne '1.0.0' -or @($record.commands).Count -ne 2) { throw 'the install record lost architecture or entries' }
$journal = @(Current-Journals | Where-Object { $_.value.state -eq 'committed' -and $_.value.action -eq 'install' -and $_.value.package -eq 'multi' })[0]
if ($null -eq $journal) { throw 'the committed install journal is missing' }
Assert-PlanMatchesJournal $preview $journal.value

# --- Update keeps the old version and consumes the same plan it displayed --------------
Write-Manifest '2.0.0' $source2 $source1 $extra2
$updatePreview = Read-CoopJson @('--root',$root,'update','multi','--dry-run','--json')
if ($updatePreview.action -ne 'update' -or $updatePreview.package.architecture -ne '32bit' -or $updatePreview.previous_package.version -ne '1.0.0') { throw 'update preview lost the installed architecture or previous version' }
$update = Invoke-Coop @('--root',$root,'update','multi','--json')
if ($update.code -ne 0) { throw "multi-artifact update failed: $($update.text)" }
if ((& "$root/shims/alpha.exe") -ne 'fixture 2' -or (& "$root/apps/multi/1.0.0/alpha.exe") -ne 'fixture 2') { throw 'update changed the selected payload or removed the old version' }
if (-not (Test-Path "$root/apps/multi/1.0.0") -or (Get-Content "$root/.coop/packages/multi.json" -Raw | ConvertFrom-Json).version -ne '2.0.0') { throw 'update did not retain the old version' }
$updateJournal = @(Current-Journals | Where-Object { $_.value.state -eq 'committed' -and $_.value.action -eq 'update' -and $_.value.package -eq 'multi' })[0]
if ($null -eq $updateJournal) { throw 'the committed update journal is missing' }
Assert-PlanMatchesJournal $updatePreview $updateJournal.value

# --- A verification failure must not replace the current version ----------------------
Write-Manifest '3.0.0' $source1 $source2 $extra2
$broken = Get-Content "$bucket/multi.json" -Raw | ConvertFrom-Json
$broken.architecture.'32bit'.hash[1] = 'sha1:'+('0'*40)
$brokenText = $broken | ConvertTo-Json -Depth 8
$brokenText | Set-Content "$bucket/multi.json" -Encoding utf8
$verifyFailure = Invoke-Coop @('--root',$root,'update','multi','--json')
if ($verifyFailure.code -eq 0 -or $verifyFailure.text -notmatch 'sha1.*mismatch') { throw "a wrong SHA1 digest did not fail verification: $($verifyFailure.text)" }
if ((& "$root/shims/alpha.exe") -ne 'fixture 2' -or (Get-Content "$root/.coop/packages/multi.json" -Raw | ConvertFrom-Json).version -ne '2.0.0') { throw 'verification failure replaced the current version' }
if (Test-Path "$root/apps/multi/3.0.0") { throw 'verification failure published the target version' }
$rolledBack = @(Current-Journals | Where-Object { $_.value.state -eq 'rolled-back' -and $_.value.action -eq 'update' })
if ($rolledBack.Count -lt 1) { throw 'verification failure left no rolled-back transaction evidence' }
$failedJournal = $rolledBack[0].value
if (@($failedJournal.observed_steps | Where-Object { $_ -eq 'verify' }).Count -lt 2) { throw 'verification failure did not reach verification before stopping' }

# --- A download failure must also keep the current version ---------------------------
Write-Manifest '3.0.0' $source1 $source2 $extra2
$missing = Get-Content "$bucket/multi.json" -Raw | ConvertFrom-Json
$missing.architecture.'32bit'.url[1] = (FileUri (Join-Path $payloads 'missing.exe'))+'#/beta.exe'
$missing | ConvertTo-Json -Depth 8 | Set-Content "$bucket/multi.json" -Encoding utf8
$downloadFailure = Invoke-Coop @('--root',$root,'update','multi','--json')
if ($downloadFailure.code -eq 0) { throw 'a missing download unexpectedly succeeded' }
if ((& "$root/shims/alpha.exe") -ne 'fixture 2' -or (Get-Content "$root/.coop/packages/multi.json" -Raw | ConvertFrom-Json).version -ne '2.0.0') { throw 'download failure replaced the current version' }
if (Test-Path "$root/apps/multi/3.0.0") { throw 'download failure published the target version' }

# --- Restoring the declaration still updates, so the failure did not corrupt state ----
Write-Manifest '3.0.0' $source1 $source2 $extra2
$goodPreview = Read-CoopJson @('--root',$root,'update','multi','--dry-run','--json')
$good = Invoke-Coop @('--root',$root,'update','multi','--json')
if ($good.code -ne 0) { throw "update after failure did not recover: $($good.text)" }
if ((& "$root/shims/alpha.exe") -ne 'fixture 1' -or (Get-Content "$root/.coop/packages/multi.json" -Raw | ConvertFrom-Json).version -ne '3.0.0') { throw 'recovered update did not switch the selected payload' }
$goodJournal = @(Current-Journals | Where-Object { $_.value.state -eq 'committed' -and $_.value.action -eq 'update' -and $_.value.package -eq 'multi' } | Sort-Object { (Get-Item $_.path).LastWriteTime })[-1]
if ($null -eq $goodJournal) { throw 'the recovered update journal is missing' }
Assert-PlanMatchesJournal $goodPreview $goodJournal.value

@{ root = $root; artifacts = 3; algorithms = 'sha512,sha1,md5'; architecture = '32bit'; failure_protection = 'verification and download failure kept 2.0.0' } |
    ConvertTo-Json | Set-Content (Join-Path $TestRoot 'multi-artifact-evidence.json') -Encoding utf8
Write-Output 'PASS multi-artifact, rename, architecture and digest-algorithm execution with failure protection'

param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/main/bucket", "$root/apps/jq/1.8.2" -Force | Out-Null
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$root/buckets/main/bucket/jq.json"
Copy-Item "$PSScriptRoot/corpus/main/rclone.json" "$root/buckets/main/bucket/rclone.json"
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$root/apps/jq/1.8.2/scoop-manifest.json"
'{"bucket":"main","architecture":"64bit"}' | Set-Content "$root/apps/jq/1.8.2/scoop-install.json" -Encoding utf8
New-Item -ItemType Junction -Path "$root/apps/jq/current" -Target "$root/apps/jq/1.8.2" | Out-Null

function Get-Snapshot([string]$Path) {
    @(Get-ChildItem -LiteralPath $Path -Recurse -File | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($Path.Length) + ':' + $_.Length + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    })
}
function Invoke-Coop([string[]]$Arguments) {
    $output = & $CoopExe @Arguments 2>&1
    [pscustomobject]@{ code = $LASTEXITCODE; text = ($output -join "`n") }
}
function Read-CoopJson([string[]]$Arguments) {
    $result = Invoke-Coop $Arguments
    if ($result.code -ne 0) { throw "coop $($Arguments -join ' ') failed ($($result.code)): $($result.text)" }
    return ($result.text | ConvertFrom-Json)
}

# --- Shared installation facts need no Coop-owned record -------------------------------
$items = @(Read-CoopJson @('--root',$root,'list','--json'))
if ($items.Count -ne 1 -or $items[0].name -ne 'jq' -or $items[0].version -ne '1.8.2') { throw "installed facts missing: $($items | ConvertTo-Json -Depth 4)" }
if ($items[0].management -ne 'unadopted') { throw 'an installed package without a private record was not reported as shared/unadopted' }
if (Test-Path "$root/.coop") { throw 'a read-only query created Coop management state' }

# --- Stale and corrupt private records cannot hide or block the installation -----------
New-Item -ItemType Directory -Path "$root/.coop/packages" -Force | Out-Null
'{"name":"jq","origin":"coop","status":"uninstalled","version":"0.0.0"}' | Set-Content "$root/.coop/packages/jq.json" -Encoding utf8
$stale = @(Read-CoopJson @('--root',$root,'list','--json'))
if ($stale[0].version -ne '1.8.2') { throw 'a stale Coop record overrode the shared installation facts' }
$stalePreview = Read-CoopJson @('--root',$root,'update','jq','--dry-run','--json')
if ($stalePreview.package.version -ne '1.8.2' -or $stalePreview.action -ne 'update') { throw 'stale private record changed the update target' }
'not JSON' | Set-Content "$root/.coop/packages/jq.json" -Encoding utf8
$corrupt = @(Read-CoopJson @('--root',$root,'list','--json'))
if ($corrupt[0].version -ne '1.8.2' -or @($corrupt[0].diagnostics).Count -eq 0) { throw 'a corrupt private record hid the installation or its diagnostics' }
if (@($corrupt[0].diagnostic_details | Where-Object code -eq 'coop-record-unreadable').Count -ne 1) { throw 'corrupt private record was not reported as a management-record diagnostic' }
$corruptPreview = Invoke-Coop @('--root',$root,'update','jq','--dry-run','--json')
if ($corruptPreview.code -ne 0) { throw "a corrupt private record blocked the preview: $($corruptPreview.text)" }
Remove-Item -LiteralPath "$root/.coop" -Recurse -Force

# --- Query and preview run through the IR pipeline without side effects ----------------
$before = Get-Snapshot $root
$list = Invoke-Coop @('--root',$root,'list','--json')
$info = Invoke-Coop @('--root',$root,'info','main/jq','--json')
$preview = Invoke-Coop @('--root',$root,'update','jq','--dry-run','--json')
if ($list.code -ne 0 -or $info.code -ne 0 -or $preview.code -ne 0) { throw "read-only pipeline failed: $($list.text) $($info.text) $($preview.text)" }
$after = Get-Snapshot $root
if (@(Compare-Object $before $after).Count) { throw 'query or preview changed shared state' }
if (Test-Path "$root/.coop") { throw 'query or preview wrote management state' }

$plan = ($preview.text | ConvertFrom-Json)
if ($plan.action -ne 'update' -or $plan.package.version -ne '1.8.2') { throw 'update preview lost the installed target' }
$kinds = @($plan.operations | ForEach-Object { $_.kind })
if ('download' -notin $kinds -or 'verify' -notin $kinds -or 'publish-current' -notin $kinds -or 'commit-state' -notin $kinds) { throw "preview operations are incomplete: $kinds" }
$verifyOperations = @($plan.operations | Where-Object kind -eq 'verify')
if ($verifyOperations.Count -ne 1 -or $verifyOperations[0].detail -notmatch 'sha256') { throw 'the verify operation lost its declared algorithm' }
if ('remove-version' -in $kinds) { throw 'update preview planned to delete the retained previous version' }
$irKinds = @($plan.ir_operations | ForEach-Object { $_.operation })
if ($irKinds.Count -ne $kinds.Count) { throw "IR plan and legacy operation list disagree: $($irKinds.Count) vs $($kinds.Count)" }
if (@($plan.ir_operations | Where-Object { [string]::IsNullOrWhiteSpace($_.effect) }).Count) { throw 'an IR operation has no stated effect' }
$firstPublish = [array]::IndexOf($irKinds,'publish-current')
$verify = [array]::IndexOf($irKinds,'verify')
if ($verify -ge $firstPublish) { throw 'verification is not planned before publishing' }
$capability = @($plan.capabilities | Where-Object id -eq 'native-download')
if ($capability.Count -ne 1 -or $capability[0].supported -ne $true) { throw 'the IR capabilities of a native download package are missing' }

$uninstall = Read-CoopJson @('--root',$root,'uninstall','jq','--dry-run','--json')
$removeKinds = @($uninstall.operations | ForEach-Object { $_.kind })
if ('unlink-current' -notin $removeKinds -or 'remove-version' -notin $removeKinds) { throw "uninstall preview is incomplete: $removeKinds" }
if (@($uninstall.ir_operations | Where-Object operation -eq 'remove-version').Count -ne 1) { throw 'uninstall IR plan omitted the version removal it reports' }

$validation = @(($info.text | ConvertFrom-Json))[0].validation
if ($null -eq $validation) { throw 'info did not report IR validation' }
if ($validation.manifest_digest -ne (Get-FileHash "$root/buckets/main/bucket/jq.json" -Algorithm SHA256).Hash.ToLower()) { throw 'info validation is not bound to the manifest bytes' }
if (@($validation.diagnostics).Count -ne 0) { throw "a readable package was reported invalid: $($validation.diagnostics | ConvertTo-Json -Compress)" }

# --- info validates against the installed architecture, not a literal 64bit -----------------
$archRoot = Join-Path $TestRoot ('arch-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$archRoot/buckets/main/bucket","$archRoot/apps/jq/1.8.2" -Force | Out-Null
$only64 = @{version='1.8.2';bin='jq.exe';architecture=@{'64bit'=@{url='https://invalid.example/jq.exe';hash=('a'*64)}}} | ConvertTo-Json -Depth 8
$only64 | Set-Content "$archRoot/buckets/main/bucket/jq.json" -Encoding utf8
$only64 | Set-Content "$archRoot/apps/jq/1.8.2/scoop-manifest.json" -Encoding utf8
'{"bucket":"main","architecture":"32bit"}' | Set-Content "$archRoot/apps/jq/1.8.2/scoop-install.json" -Encoding utf8
New-Item -ItemType Junction -Path "$archRoot/apps/jq/current" -Target "$archRoot/apps/jq/1.8.2" | Out-Null
$archInfo = Read-CoopJson @('--root',$archRoot,'info','main/jq','--json')
$archValidation = @($archInfo)[0].validation
if ($archValidation.architecture -ne '32bit') { throw "info did not use the installed architecture: $($archValidation.architecture)" }
if ($archValidation.downloads -ne 0) { throw 'a 32bit installation resolved a 64bit-only manifest' }
if (@($archValidation.diagnostics | Where-Object code -eq 'missing-artifact').Count -ne 1) { throw "info did not report the missing 32bit artifact: $($archValidation.diagnostics | ConvertTo-Json -Compress)" }

# --- The validator reports algorithm and mechanism gaps instead of hiding them --------
$sha512 = '0' * 128
$sha512Manifest = @{version='1.0.0';url='https://invalid.example/tool.zip#/renamed.zip';hash="sha512:$sha512"} | ConvertTo-Json -Compress
$sha512Manifest | Set-Content "$root/buckets/main/bucket/algo.json" -Encoding utf8
$algoPreview = Invoke-Coop @('--root',$root,'install','algo','--dry-run','--json')
$algoPlan = ($algoPreview.text | ConvertFrom-Json)
if ($algoPreview.code -ne 0 -or $algoPlan.execution_available -ne $true) { throw "a declared SHA512 digest was not honoured: $($algoPreview.text)" }
if (@($algoPlan.artifacts).Count -ne 1 -or @($algoPlan.artifacts | Where-Object { $_.algorithm -ne 'sha512' -or $_.digest -ne $sha512 -or $_.filename -ne 'renamed.zip' -or $_.renamed -ne $true }).Count -ne 0) { throw 'the SHA512 artifact declaration or rename was not preserved' }
if (@($algoPlan.diagnostics | Where-Object { $_.code -eq 'unsupported-hash' }).Count -ne 0) { throw 'a supported SHA512 digest was reported as unsupported' }
$algoInfoResult = Invoke-Coop @('--root',$root,'info','main/algo','--json')
if ($algoInfoResult.code -ne 0) { throw "info failed for a supported digest package: $($algoInfoResult.text)" }
$algoInfo = @($algoInfoResult.text | ConvertFrom-Json)
if (@($algoInfo[0].validation.diagnostics | Where-Object { $_.code -eq 'unsupported-hash' }).Count -ne 0) { throw 'info reported a supported digest as a gap' }
if ($algoInfo[0].validation.artifacts[0].algorithm -ne 'sha512' -or $algoInfo[0].validation.artifacts[0].renamed -ne $true) { throw 'info did not preserve the declared digest algorithm and rename' }
$sha3Manifest = @{version='1.0.0';url='https://invalid.example/tool.zip';hash=('sha3:'+('0'*128))} | ConvertTo-Json -Compress
$sha3Manifest | Set-Content "$root/buckets/main/bucket/algo3.json" -Encoding utf8
$sha3Preview = Invoke-Coop @('--root',$root,'install','algo3','--dry-run','--json')
$sha3Plan = ($sha3Preview.text | ConvertFrom-Json)
if ($sha3Preview.code -eq 0 -or 'unsupported-hash' -notin @($sha3Plan.diagnostics | ForEach-Object { $_.code })) { throw 'an unknown digest algorithm was silently accepted' }

$msiManifest = @{version='1.0.0';url='https://invalid.example/setup.msi';hash=('a' * 64)} | ConvertTo-Json -Compress
$msiManifest | Set-Content "$root/buckets/main/bucket/msipkg.json" -Encoding utf8
$msiPreview = Invoke-Coop @('--root',$root,'install','msipkg','--dry-run','--json')
$msiPlan = ($msiPreview.text | ConvertFrom-Json)
if ($msiPlan.execution_available -ne $true) { throw "an MSI package preview stayed blocked: $(@($msiPlan.diagnostics) | ConvertTo-Json -Compress)" }
if ($msiPlan.package.msi_extraction.msiexec_started -ne $false -or $msiPlan.package.msi_extraction.administrative_install -ne $false) {
    throw 'the MSI preview does not state that no msiexec process or administrative install is used'
}
$msiCapability = @($msiPlan.capabilities | Where-Object id -eq 'windows-installer')
if ($msiCapability.Count -ne 1 -or $msiCapability[0].supported -ne $true) { throw 'the Windows Installer capability is missing or reported as a gap' }
if ($msiPreview.code -ne 0) { throw 'a readable package preview did not report a plan' }
if (Test-Path "$root/apps/msipkg") { throw 'a preview installed an MSI package' }

# --- Read-only pipeline starts no helper process --------------------------------------
$guard = Join-Path (Split-Path $CoopExe) 'process_guard.exe'
$guarded = & $guard $CoopExe --root $root update jq --dry-run --json
if ($LASTEXITCODE -ne 0) { throw 'the read-only preview started a script or helper process' }
$guarded | Set-Content "$TestRoot/ir-pipeline-process-evidence.txt" -Encoding utf8
$guardedList = & $guard $CoopExe --root $root list --json
if ($LASTEXITCODE -ne 0) { throw 'the query started a helper process' }
$guardedList | Set-Content "$TestRoot/ir-pipeline-list-process-evidence.txt" -Encoding utf8

@{ root = $root; iterations = 'facts, stale record, corrupt record, preview, uninstall preview, digest gap, mechanism gap' } |
    ConvertTo-Json | Set-Content (Join-Path $TestRoot 'ir-pipeline-evidence.json') -Encoding utf8
Write-Output 'PASS shared installation facts, IR query/preview plans, layered diagnostics and no side effects'

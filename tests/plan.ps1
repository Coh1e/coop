param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/buckets/main/bucket", "$root/apps/jq/current" -Force | Out-Null
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$root/buckets/main/bucket/jq.json"
Copy-Item "$PSScriptRoot/corpus/main/rclone.json" "$root/buckets/main/bucket/rclone.json"
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$root/apps/jq/current/scoop-manifest.json"
'{"bucket":"main","architecture":"64bit"}' | Set-Content "$root/apps/jq/current/scoop-install.json" -Encoding utf8
$before = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { $_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash })
$text = & $CoopExe --root $root install main/jq --arch 64bit --dry-run --json
if ($LASTEXITCODE -ne 0) { throw 'install preview failed' }
$plan = ($text -join "`n") | ConvertFrom-Json
if ($plan.action -ne 'install' -or $plan.package.name -ne 'jq' -or $plan.package.version -ne '1.8.2' -or $plan.package.architecture -ne '64bit') { throw 'wrong target identity' }
if ($plan.artifacts.Count -ne 1 -or $plan.artifacts[0].filename -ne 'jq.exe' -or $plan.artifacts[0].sha256 -ne 'a6fc67fedaf9128a3309a1e2ebb8b986aeccf70122ee46d2cb4849e423f0c627') { throw 'artifact mapping wrong' }
if ($plan.manifest_sha256 -ne (Get-FileHash "$root/buckets/main/bucket/jq.json" -Algorithm SHA256).Hash.ToLower()) { throw 'manifest precondition not bound to bytes' }
if ('download' -notin $plan.operations.kind -or 'verify' -notin $plan.operations.kind -or 'commit-state' -notin $plan.operations.kind) { throw 'incomplete operation plan' }
$verifyOperation = @($plan.operations | Where-Object kind -eq 'verify')[0]
if ($verifyOperation.detail -notmatch 'sha256') { throw 'the operation detail lost the declared digest algorithm' }
$after = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object { $_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash })
if (@(Compare-Object $before $after).Count -or (Test-Path "$root/.coop")) { throw 'preview changed state' }
$text = & $CoopExe --root $root adopt jq --dry-run --json
if ($LASTEXITCODE -eq 0 -or (($text -join "`n") | ConvertFrom-Json).eligibility -ne 'inconsistent') { throw 'incomplete installed fixture incorrectly eligible for adoption' }
$adopt = ($text -join "`n") | ConvertFrom-Json
if ($adopt.lifecycle_checks.update -ne 'unverified' -or $adopt.lifecycle_checks.uninstall -ne 'unverified') { throw 'adoption did not cover future lifecycle' }
if ($adopt.preconditions.Count -lt 3 -or $adopt.local_facts.current_directory -ne [IO.Path]::GetFullPath("$root/apps/jq/current")) { throw 'installation facts not bound' }
$text = & $CoopExe --root $root uninstall jq --dry-run --json
$remove = ($text -join "`n") | ConvertFrom-Json
if ('unlink-current' -notin $remove.operations.kind -or 'remove-commands' -notin $remove.operations.kind -or 'remove-version' -notin $remove.operations.kind) { throw 'uninstall operations incomplete' }
$text = & $CoopExe --root $root update jq --dry-run --json
if ($LASTEXITCODE -ne 0) { throw 'update preview failed' }
$update = ($text -join "`n") | ConvertFrom-Json
if ($update.previous_package.version -ne '1.8.2' -or 'remove-version' -in $update.operations.kind) { throw 'update must retain previous version' }
$text = & $CoopExe --root $root install rclone --dry-run --json
if ($LASTEXITCODE -ne 0) { throw 'script preview failed' }
$script = ($text -join "`n") | ConvertFrom-Json
if ($script.package.persistence[0].source -ne 'rclone.conf' -or $script.package.scripts.Count -lt 2 -or -not $script.package.scripts[0].side_effects) { throw 'script/persist disclosure missing' }
if (Test-Path "$root/persist") { throw 'preview ran rclone script' }
$text = & $CoopExe --root $root install jq@0.0.0 --dry-run --json
if ($LASTEXITCODE -eq 0 -or 'version-unavailable' -notin (($text -join "`n") | ConvertFrom-Json).diagnostics.code) { throw 'missing version was guessed' }
'{"version":"1","url":"https://invalid.example/test.exe","hash":"bad","unsupported_option":true}' | Set-Content "$root/buckets/main/bucket/bad.json" -Encoding utf8
$text = & $CoopExe --root $root install bad --dry-run --json
$bad = ($text -join "`n") | ConvertFrom-Json
if ($LASTEXITCODE -eq 0 -or 'unsupported-field' -notin $bad.diagnostics.code -or 'unsupported-hash' -notin $bad.diagnostics.code) { throw 'validation did not distinguish known unsupported and invalid IR' }
'{' | Set-Content "$root/buckets/main/bucket/syntax.json" -Encoding utf8
$text = & $CoopExe --root $root install syntax --dry-run --json
if ($LASTEXITCODE -eq 0 -or 'syntax' -notin (($text -join "`n") | ConvertFrom-Json).diagnostics.category) { throw 'missing syntax diagnostic' }
$query = & $CoopExe --root $root info bad --json
if ($LASTEXITCODE -ne 0 -or ($query | ConvertFrom-Json)[0].name -ne 'bad') { throw 'execution validation hid query result' }
if (Test-Path "$root/.coop") { throw 'preview wrote management state' }
'{"bucket":"main","architecture":"32bit"}' | Set-Content "$root/apps/jq/current/scoop-install.json" -Encoding utf8
New-Item -ItemType Directory -Path "$root/buckets/other/bucket" | Out-Null
Copy-Item "$root/buckets/main/bucket/jq.json" "$root/buckets/other/bucket/jq.json"
$text = & $CoopExe --root $root update jq --dry-run --json
if ($LASTEXITCODE -ne 0) { throw 'update failed to inherit installed source' }
$update32 = ($text -join "`n") | ConvertFrom-Json
if ($update32.package.architecture -ne '32bit' -or $update32.package.bucket -ne 'main' -or $update32.artifacts[0].url -notlike '*i386*') { throw 'update changed installed architecture or source' }
$processManifest = @{version='1';url='https://invalid.example/test.exe';hash=('0'*64);depends='main/jq';installer=@{file='setup.exe';args=@('/silent','value with spaces');keep=$true};uninstaller=@{file='remove.exe';args='/quiet'}} | ConvertTo-Json -Depth 5
$processManifest | Set-Content "$root/buckets/main/bucket/process.json" -Encoding utf8
$text = & $CoopExe --root $root install main/process --dry-run --json
$processPlan = ($text -join "`n") | ConvertFrom-Json
if ($processPlan.package.installer.file -ne 'setup.exe' -or $processPlan.package.installer.arguments[1] -ne 'value with spaces' -or $processPlan.package.uninstaller.file -ne 'remove.exe' -or 'main/jq' -notin $processPlan.package.dependencies) { throw 'missing installer/ dependency disclosure' }
$guard = Join-Path (Split-Path $CoopExe) 'process_guard.exe'
$guardOutput = & $guard $CoopExe --root $root install rclone --dry-run --json
if ($LASTEXITCODE -ne 0) { throw 'preview launched a script or helper process' }
$guardOutput | Set-Content "$root/preview-process-evidence.txt" -Encoding utf8
Write-Output 'PASS read-only package IR, artifact selection, plan and input digest'

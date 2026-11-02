#requires -Version 5.1
# Red when: bucket validation rejects formatting-only changes, accepts field drift, loses either raw digest, or other evidence assertions miss state changes.
param([Parameter(Mandatory = $true)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/four-sample-evidence.ps1')
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
if (-not $TestRoot.StartsWith($project + '\.local\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture must remain project local' }
$root = Join-Path $TestRoot ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/apps/pdd/1.0", "$root/persist/pdd", "$root/shims", "$root/modules/other" -Force | Out-Null
function MustReject([scriptblock]$Body) {
    $rejected = $false
    try { & $Body } catch { $rejected = $true }
    if (-not $rejected) { throw 'A deliberately wrong result was accepted' }
}
# Load the actual entry point's function, not the top-level lifecycle runner. Only its Git read is
# stubbed; the source files, comparison, drift rejection and evidence files remain real.
$runnerPath = Join-Path $PSScriptRoot '../scripts/verify-four-samples.ps1'
$parseTokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Acceptance runner does not parse' }
$definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'CurrentManifest' }, $true)
. ([scriptblock]::Create($definition.Extent.Text))
function Tool([string]$Name, [string]$Exe, [string[]]$Arguments) { $script:revisionReads++; return ('a' * 40) }
function SaveReport { }
$script:revisionReads = 0
$ScoopRoot = Join-Path $root 'manifest-root'
$run = Join-Path $root 'manifest-evidence'
New-Item -ItemType Directory -Path "$ScoopRoot/buckets/main/bucket", $run -Force | Out-Null
$reviewed = Join-Path $root 'manifest-reviewed.json'
$checkout = Join-Path $ScoopRoot 'buckets/main/bucket/jq.json'
$json = "{`n  `"version`": `"1.0`",`n  `"architecture`": {`"64bit`": {`"url`": `"https://example.invalid/a`", `"hash`": `"abc`"}},`n  `"bin`": [`"one`", `"two`"],`n  `"pre_install`": `"echo original`",`n  `"optional`": null,`n  `"enabled`": true`n}`n"
$encoding = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($reviewed, $json, $encoding)
$byId = @{ jq = [pscustomobject]@{ bucket = 'main'; manifest = $reviewed; manifest_sha256 = (Get-FileHash $reviewed -Algorithm SHA256).Hash } }
$commands = New-Object 'System.Collections.Generic.List[object]'
$script:active = [pscustomobject]@{ evidence = @() }
[IO.File]::WriteAllText($checkout, $json.Replace("`n", "`r`n"), $encoding)
CurrentManifest 'jq'
if ($script:active.evidence.Count -ne 1) { throw 'Manifest comparison evidence was not linked to its scene' }
$evidence = Get-Content -LiteralPath (Join-Path $run $script:active.evidence[-1]) -Encoding UTF8 -Raw | ConvertFrom-Json
if (-not $evidence.content_equal -or $evidence.byte_equal -or $evidence.source_sha256 -ne (Get-FileHash $reviewed).Hash -or $evidence.current_sha256 -ne (Get-FileHash $checkout).Hash) { throw 'LF/CRLF equivalence or raw digests not preserved' }
$reordered = Get-FourSampleCanonicalJson ($json | ConvertFrom-Json)
[IO.File]::WriteAllText($checkout, $reordered, $encoding)
CurrentManifest 'jq'
foreach ($changed in @(
    $json.Replace('"1.0"', '"2.0"'),
    $json.Replace('https://example.invalid/a', 'https://example.invalid/b'),
    $json.Replace('"abc"', '"def"'),
    $json.Replace('echo original', 'echo changed'),
    $json.Replace('["one", "two"]', '["two", "one"]'),
    $json.Replace('["one", "two"]', '["one", null, "two"]'),
    $json.Replace('"optional": null', '"optional": []'),
    $json.Replace('"optional": null', '"optional": [null]'),
    $json.Replace('"optional": null', '"optional": {}'),
    $json.Replace('"enabled": true', '"enabled": "true"'),
    $json.Replace('"version"', '"Version"'),
    $json.Replace('"enabled": true', '"enabled": true, "new_field": 1'),
    $json.Replace('  "optional": null,' + "`n", '')
)) {
    [IO.File]::WriteAllText($checkout, $changed, $encoding)
    $reads = $script:revisionReads
    MustReject { CurrentManifest 'jq' }
    if ($script:revisionReads -ne $reads) { throw 'Manifest drift was accepted before a downstream Git read' }
    $evidence = Get-Content -LiteralPath (Join-Path $run $script:active.evidence[-1]) -Encoding UTF8 -Raw | ConvertFrom-Json
    if ($evidence.content_equal) { throw 'Rejected field drift was not recorded as a difference' }
}
[IO.File]::WriteAllText($checkout, '{bad-json', $encoding)
MustReject { CurrentManifest 'jq' }
$evidence = Get-Content -LiteralPath (Join-Path $run $script:active.evidence[-1]) -Encoding UTF8 -Raw | ConvertFrom-Json
if (-not $evidence.parse_error -or -not $evidence.current_sha256) { throw 'Malformed manifest lost error or digest evidence' }
[IO.File]::WriteAllText($checkout, '[' + $json + ']', $encoding)
MustReject { CurrentManifest 'jq' }
$evidence = Get-Content -LiteralPath (Join-Path $run $script:active.evidence[-1]) -Encoding UTF8 -Raw | ConvertFrom-Json
if ($evidence.content_equal -or -not $evidence.parse_error) { throw 'A root array was accepted as a Manifest object' }
[IO.File]::WriteAllBytes($checkout, [byte[]]@(123, 34, 255, 34, 58, 49, 125))
MustReject { CurrentManifest 'jq' }
$evidence = Get-Content -LiteralPath (Join-Path $run $script:active.evidence[-1]) -Encoding UTF8 -Raw | ConvertFrom-Json
if (-not $evidence.parse_error -or -not $evidence.current_sha256) { throw 'Invalid UTF-8 lost error or digest evidence' }
# The reviewed source digest remains a strict trust anchor even if both files are changed alike.
[IO.File]::WriteAllText($reviewed, $json.Replace('"1.0"', '"2.0"'), $encoding)
[IO.File]::WriteAllText($checkout, $json.Replace('"1.0"', '"2.0"'), $encoding)
MustReject { CurrentManifest 'jq' }
$evidence = Get-Content -LiteralPath (Join-Path $run $script:active.evidence[-1]) -Encoding UTF8 -Raw | ConvertFrom-Json
if ($evidence.source_digest_matches_expected) { throw 'Changed reviewed source was trusted' }
# Differences below the old serializer's depth limit must remain observable.
$deep = '"leaf-original"'
foreach ($level in 1..35) { $deep = '{"nested":' + $deep + '}' }
[IO.File]::WriteAllText($reviewed, $deep, $encoding)
$byId.jq.manifest_sha256 = (Get-FileHash $reviewed -Algorithm SHA256).Hash
[IO.File]::WriteAllText($checkout, $deep, $encoding)
CurrentManifest 'jq'
[IO.File]::WriteAllText($checkout, $deep.Replace('leaf-original', 'leaf-changed'), $encoding)
MustReject { CurrentManifest 'jq' }
$file = "$root/apps/pdd/1.0/program.py"
[IO.File]::WriteAllText($file, 'one')
$before = Get-FourSampleSnapshot $root 'pdd'
if (-not (Compare-FourSampleSnapshot $before (Get-FourSampleSnapshot $root 'pdd'))) { throw 'Stable snapshot differs' }
[IO.File]::WriteAllText($file, 'two')
if (Compare-FourSampleSnapshot $before (Get-FourSampleSnapshot $root 'pdd')) { throw 'Same-length content mutation was missed' }
[IO.File]::WriteAllText($file, 'one')
[IO.File]::WriteAllText("$root/shims/pdd.cmd", 'changed entry')
if (Compare-FourSampleSnapshot $before (Get-FourSampleSnapshot $root 'pdd')) { throw 'New entry was missed' }
[IO.File]::WriteAllText("$root/modules/other/module.psm1", 'module content')
$modules = Get-FourSampleSnapshot $root 'pdd'
[IO.File]::WriteAllText("$root/modules/other/module.psm1", 'module changed')
if (Compare-FourSampleSnapshot $modules (Get-FourSampleSnapshot $root 'pdd')) { throw 'Other module content mutation was missed' }
New-Item -ItemType Directory -Path "$root/module-target", "$root/apps/pdd/2.0" -Force | Out-Null
[IO.File]::WriteAllText("$root/module-target/linked.psm1", 'one')
New-Item -ItemType Junction -Path "$root/module-current" -Target "$root/module-target" | Out-Null
New-Item -ItemType Junction -Path "$root/modules/linked" -Target "$root/module-current" | Out-Null
$linkedModules = Get-FourSampleSnapshot $root 'pdd'
[IO.File]::WriteAllText("$root/module-target/linked.psm1", 'two')
if (Compare-FourSampleSnapshot $linkedModules (Get-FourSampleSnapshot $root 'pdd')) { throw 'Linked module content mutation was missed' }
New-Item -ItemType Junction -Path "$root/apps/pdd/current" -Target "$root/apps/pdd/1.0" | Out-Null
$linkedApp = Get-FourSampleSnapshot $root 'pdd'
# Remove only this fixture junction, never recursively delete its target.
[IO.Directory]::Delete("$root/apps/pdd/current", $false)
New-Item -ItemType Junction -Path "$root/apps/pdd/current" -Target "$root/apps/pdd/2.0" | Out-Null
if (Compare-FourSampleSnapshot $linkedApp (Get-FourSampleSnapshot $root 'pdd')) { throw 'Current junction retarget was missed' }
$copy = ConvertTo-Json -InputObject $before -Depth 30 | ConvertFrom-Json
$copy.user_environment += [pscustomobject]@{ name = 'fixture-only'; value = 'changed' }
if (Compare-FourSampleSnapshot $before $copy) { throw 'Environment mutation was missed' }
Assert-FourSampleDate "0y 0m 10d`r`n10d`r`n"
MustReject { Assert-FourSampleDate '110d' }
MustReject { Assert-FourSampleDate "0y 0m 11d`n10d" }
Assert-FourSampleModule ([pscustomobject]@{ Version = '1.1.0'; ModuleBase = "$root/modules/posh-git" }) '1.1.0' "$root/modules/posh-git"
MustReject { Assert-FourSampleModule ([pscustomobject]@{ Version = '1.1.0'; ModuleBase = "$root/modules/wrong" }) '1.1.0' "$root/modules/posh-git" }
$hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
if (-not (Test-FourSampleHash $file $hash)) { throw 'Valid digest rejected' }
if (Test-FourSampleHash $file ('0' * 64)) { throw 'Wrong digest accepted' }
Write-FourSampleJson "$root/roundtrip.json" $before
if (-not (Compare-FourSampleSnapshot $before (Get-Content -Encoding UTF8 "$root/roundtrip.json" -Raw | ConvertFrom-Json))) { throw 'Evidence JSON roundtrip changed snapshot' }
$sourceManifest = Join-Path $root 'reviewed.json'
[IO.File]::WriteAllText($sourceManifest, '{"version":"1.0","hash":"abc","bin":["one","two"]}')
[IO.File]::WriteAllText("$root/apps/pdd/1.0/scoop-manifest.json", '{"bin":["one","two"], "hash":"abc", "version":"1.0"}')
Write-FourSampleJson "$root/apps/pdd/1.0/scoop-install.json" @{ architecture = '64bit'; bucket = 'extras' }
$record = Get-FourSampleInstallRecords "$root/apps/pdd/1.0" $sourceManifest
if ($record.install.architecture -ne '64bit') { throw 'Current Scoop record names were not read' }
[IO.File]::WriteAllText("$root/apps/pdd/1.0/scoop-manifest.json", '{"bin":["two","one"], "hash":"abc", "version":"1.0"}')
MustReject { Get-FourSampleInstallRecords "$root/apps/pdd/1.0" $sourceManifest | Out-Null }
# Exercise the default entry point with inert files. An accidental attempt to run this binary fails.
$artifact = Join-Path $root 'inert.exe'
[IO.File]::WriteAllText($artifact, 'not an executable')
$artifactHash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash
$sources = @()
foreach ($id in @('jq-old', 'jq', 'wgcf', 'pdd', 'posh-git', 'python', 'python-dateutil', 'six')) {
    $version = '1.0'
    if ($id -eq 'jq-old') { $version = '0.9' }
    $entry = [ordered]@{ id = $id; version = $version; source_url = 'https://example.invalid/reviewed'; artifact_url = 'https://example.invalid/artifact'; artifact = $artifact; artifact_sha256 = $artifactHash }
    if ($id -in @('jq-old', 'jq', 'wgcf', 'pdd', 'posh-git')) {
        $dir = Join-Path $root $id
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $manifest = Join-Path $dir 'jq.json'
        Write-FourSampleJson $manifest @{ version = $version; url = $entry.artifact_url; hash = $artifactHash }
        $entry['bucket'] = 'main'
        if ($id -in @('pdd', 'posh-git')) { $entry.bucket = 'extras' }
        $entry['revision'] = 'a' * 40
        $entry['manifest'] = $manifest
        $entry['manifest_sha256'] = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
    }
    $sources += [pscustomobject]$entry
}
New-Item -ItemType Directory -Path "$root/python-modules/dateutil" -Force | Out-Null
[IO.File]::WriteAllText("$root/python-modules/dateutil/__init__.py", '# inert fixture')
$inputFile = Join-Path $root 'sources.json'
$inputData = @{ sources = $sources; python_exe = $artifact; python_exe_sha256 = $artifactHash; python_modules = "$root/python-modules" }
Write-FourSampleJson $inputFile $inputData
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$runner = Join-Path $PSScriptRoot '../scripts/verify-four-samples.ps1'
$out = Invoke-CoopNative 'powershell.exe' @('-NoProfile', '-File', $runner, '-SourceFile', $inputFile, '-CoopExe', $artifact, '-EvidenceDir', "$root/must-not-exist") | Out-String
if ($LASTEXITCODE -ne 0 -or $out -notmatch 'No Scoop commands' -or (Test-Path "$root/must-not-exist")) { throw "Default mode was not inert: $out" }
$sources[0].artifact_sha256 = '0' * 64
Write-FourSampleJson $inputFile $inputData
$out = Invoke-CoopNative 'powershell.exe' @('-NoProfile', '-File', $runner, '-SourceFile', $inputFile, '-CoopExe', $artifact) | Out-String
if ($LASTEXITCODE -eq 0 -or $out -notmatch 'Artifact digest mismatch') { throw "Tampered-source rejection missing (exit $LASTEXITCODE): $out" }
# Scoop's command parameter is scalar: an array expression passed as one argument is not splatting.
# Exercise the runner's actual S wrapper against a project-local command with that same contract.
$definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'S' }, $true)
. ([scriptblock]::Create($definition.Extent.Text))
$scoop = Join-Path $root 'scoop-fixture.ps1'
$fixture = 'param([string]$command,[Parameter(ValueFromRemainingArguments=$true)][string[]]$remaining); ConvertTo-Json -InputObject @{command=$command;remaining=@($remaining)}'
[IO.File]::WriteAllText($scoop, $fixture, $encoding)
function Tool([string]$Name, [string]$Exe, [string[]]$Arguments) {
    $text = Invoke-CoopNative $Exe @Arguments | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Argument fixture exited $LASTEXITCODE : $text" }
    return $text
}
$manifestArgument = "$root/space and 'quote'/jq.json"
$forwarded = S 'scoop-argument-fixture' @('install', $manifestArgument, '--flag') | ConvertFrom-Json
if ($forwarded.command -cne 'install' -or @($forwarded.remaining).Count -ne 2 -or $forwarded.remaining[0] -cne $manifestArgument -or $forwarded.remaining[1] -cne '--flag') { throw 'Scoop command/path arguments were combined or changed' }
# Replay the real Installed function with multiple Coop list entries on Windows PowerShell 5.1.
$definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Installed' }, $true)
. ([scriptblock]::Create($definition.Extent.Text))
$ScoopRoot = Join-Path $root 'list-root'
$versionDir = Join-Path $ScoopRoot 'apps/jq/1.7.1'
New-Item -ItemType Directory -Path $versionDir -Force | Out-Null
Write-FourSampleJson "$versionDir/scoop-manifest.json" @{ version = '1.7.1'; bin = 'jq.exe' }
Write-FourSampleJson "$versionDir/scoop-install.json" @{ architecture = '64bit'; bucket = 'main' }
New-Item -ItemType Junction -Path "$ScoopRoot/apps/jq/current" -Target $versionDir | Out-Null
$byId = @{ 'jq-old' = [pscustomobject]@{ version = '1.7.1'; manifest = "$versionDir/scoop-manifest.json"; manifest_sha256 = (Get-FileHash "$versionDir/scoop-manifest.json").Hash } }
$fixture = 'param([string]$command,[Parameter(ValueFromRemainingArguments=$true)][string[]]$remaining); Write-Host "Installed apps matching jq:"; [pscustomobject]@{Name="jq";Version="1.7.1";Source="main"}'
[IO.File]::WriteAllText($scoop, $fixture, $encoding)
function C([string]$Name, [string[]]$Arguments) { return '[{"name":"other","version":"9"},{"name":"jq","version":"1.7.1"}]' }
Installed 'jq' '1.7.1'
$installationEvidence = Get-Content (Join-Path $run "jq-installation-$($commands.Count).json") -Encoding UTF8 -Raw | ConvertFrom-Json
if (@($installationEvidence.coop).Count -ne 1 -or $installationEvidence.coop.name -ne 'jq') { throw 'Wrong package selected from Coop list' }
function C([string]$Name, [string[]]$Arguments) { return '[{"name":"jq","version":"2.0"}]' }
MustReject { Installed 'jq' '1.7.1' }
function C([string]$Name, [string[]]$Arguments) { return '[{"name":"other","version":"9"}]' }
MustReject { Installed 'jq' '1.7.1' }
$definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'OldJqManifest' }, $true)
. ([scriptblock]::Create($definition.Extent.Text))
New-Item -ItemType Directory -Path "$ScoopRoot/workspace" -Force | Out-Null
$cache = Join-Path $ScoopRoot 'workspace/jq.json'
Copy-Item -LiteralPath "$versionDir/scoop-manifest.json" -Destination $cache
$cacheHash = (Get-FileHash $cache).Hash
if ((OldJqManifest) -ne $cache -or (Get-FileHash $cache).Hash -ne $cacheHash) { throw 'Historical cache was changed or not selected' }
[IO.File]::WriteAllText($cache, '{"version":"wrong"}', $encoding)
MustReject { OldJqManifest | Out-Null }
Write-Host 'PASS: project-local evidence assertions; no lifecycle commands or user environment writes'

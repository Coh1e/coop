param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test data must stay within the project test directory'
}
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$session = Join-Path $TestRoot 'init'
if (Test-Path -LiteralPath $session) { Remove-Item -LiteralPath $session -Recurse -Force }
New-Item -ItemType Directory -Path $session -Force | Out-Null
$standard = @('apps', 'buckets', 'cache', 'persist', 'shims')
function Invoke-Coop([string[]]$arguments) {
    $output = & $CoopExe @arguments 2>&1 | Out-String
    return [pscustomobject]@{ exit = $LASTEXITCODE; output = $output }
}
function Assert-True([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
function Get-Children([string]$path) {
    return @(Get-ChildItem -LiteralPath $path -Force | Sort-Object Name | ForEach-Object { $_.Name })
}
function Get-Fingerprint([string]$path) {
    $lines = Get-ChildItem -LiteralPath $path -Recurse -Force | ForEach-Object {
        $relative = $_.FullName.Substring($path.Length).TrimStart('\')
        if ($_.PSIsContainer) { "d|$relative" } else { "f|$relative|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }
    }
    return @($lines | Sort-Object)
}

# 1. Preview reports the planned layout without creating the root or any directory.
$root = Join-Path $session 'fresh 中文 root'
$preview = Invoke-Coop @('--root', $root, 'init', '--dry-run', '--json')
Assert-True ($preview.exit -eq 0) "init preview failed: $($preview.output)"
$previewJson = $preview.output | ConvertFrom-Json
Assert-True ($previewJson.dry_run -eq $true) "preview did not report dry_run: $($preview.output)"
Assert-True ((@($previewJson.created) -join ',') -eq ($standard -join ',')) "preview listed the wrong layout: $($preview.output)"
Assert-True (@($previewJson.existing).Count -eq 0) "preview reported existing directories: $($preview.output)"
Assert-True (-not (Test-Path -LiteralPath $root)) 'init preview created the installation root'
$previewText = Invoke-Coop @('--root', $root, 'init', '--dry-run')
Assert-True ($previewText.exit -eq 0 -and $previewText.output -match 'would create' -and $previewText.output -match 'Scoop installation: none') "text preview was not informative: $($previewText.output)"
Assert-True (-not (Test-Path -LiteralPath $root)) 'text init preview created the installation root'

# 2. Initialization creates exactly the standard Scoop directories and no private state.
$created = Invoke-Coop @('--root', $root, 'init', '--json')
Assert-True ($created.exit -eq 0) "init failed: $($created.output)"
$createdJson = $created.output | ConvertFrom-Json
Assert-True ((@($createdJson.created) -join ',') -eq ($standard -join ',')) "init created the wrong layout: $($created.output)"
Assert-True (@($createdJson.existing).Count -eq 0) "init reported pre-existing directories: $($created.output)"
Assert-True ($createdJson.scoop_installation.present -eq $false) "a fresh root reported a Scoop installation: $($created.output)"
foreach ($name in $standard) { Assert-True (Test-Path -LiteralPath (Join-Path $root $name) -PathType Container) "init did not create $name" }
$children = Get-Children $root
Assert-True (($children -join ',') -eq ($standard -join ',')) "init created non-standard entries: $($children -join ',')"
Assert-True (-not (Test-Path -LiteralPath (Join-Path $root '.coop'))) 'init created Coop private state'

# 3. Re-running init is idempotent and never rewrites existing content.
$sentinel = Join-Path $root 'apps/keep.txt'
Set-Content -LiteralPath $sentinel -Value 'user content' -Encoding utf8
$before = Get-Fingerprint $root
$again = Invoke-Coop @('--root', $root, 'init', '--json')
Assert-True ($again.exit -eq 0) "repeated init failed: $($again.output)"
$againJson = $again.output | ConvertFrom-Json
Assert-True (@($againJson.created).Count -eq 0) "repeated init created directories: $($again.output)"
Assert-True ((@($againJson.existing) -join ',') -eq ($standard -join ',')) "repeated init did not report the existing layout: $($again.output)"
$after = Get-Fingerprint $root
Assert-True (($before -join "`n") -eq ($after -join "`n")) 'repeated init changed existing content'
Assert-True ((Get-Content -LiteralPath $sentinel -Raw).Trim() -eq 'user content') 'sentinel content changed'

# 4. A conflicting file blocks initialization before any directory is written.
$conflict = Join-Path $session 'conflict root'
New-Item -ItemType Directory -Path $conflict -Force | Out-Null
Set-Content -LiteralPath (Join-Path $conflict 'buckets') -Value 'not a directory' -Encoding utf8
$conflictResult = Invoke-Coop @('--root', $conflict, 'init')
Assert-True ($conflictResult.exit -ne 0) "init accepted a file where a standard directory belongs: $($conflictResult.output)"
Assert-True ($conflictResult.output -match 'not a directory') "conflict diagnostic was not specific: $($conflictResult.output)"
Assert-True (-not (Test-Path -LiteralPath (Join-Path $conflict 'apps'))) 'conflicting init wrote directories before failing'
Assert-True ((Get-Content -LiteralPath (Join-Path $conflict 'buckets') -Raw).Trim() -eq 'not a directory') 'conflicting init changed the existing file'

# 5. An installation root that is a regular file is refused.
$fileRoot = Join-Path $session 'root-file'
Set-Content -LiteralPath $fileRoot -Value 'not a root' -Encoding utf8
$fileResult = Invoke-Coop @('--root', $fileRoot, 'init')
Assert-True ($fileResult.exit -ne 0 -and $fileResult.output -match 'not a directory') "a file installation root was accepted: $($fileResult.output)"
Assert-True ((Get-Content -LiteralPath $fileRoot -Raw).Trim() -eq 'not a root') 'the file installation root was modified'

# 6. Unknown arguments are rejected instead of being ignored.
$extra = Invoke-Coop @('--root', $root, 'init', 'extra')
Assert-True ($extra.exit -ne 0 -and $extra.output -match 'init accepts only') "init ignored an unknown argument: $($extra.output)"

# 7. An existing partial Scoop root is completed without touching its content.
$existing = Join-Path $session 'existing scoop'
New-Item -ItemType Directory -Path (Join-Path $existing 'apps/scoop/current'), (Join-Path $existing 'shims') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $existing 'apps/scoop/current/manifest.json') -Value '{"version":"0.6.0"}' -Encoding utf8
$completed = Invoke-Coop @('--root', $existing, 'init', '--json')
Assert-True ($completed.exit -eq 0) "init on an existing Scoop root failed: $($completed.output)"
$completedJson = $completed.output | ConvertFrom-Json
Assert-True ((@($completedJson.created) -join ',') -eq 'buckets,cache,persist') "init completed the wrong layout: $($completed.output)"
Assert-True ((@($completedJson.existing) -join ',') -eq 'apps,shims') "init reported the wrong existing layout: $($completed.output)"
Assert-True ($completedJson.scoop_installation.present -eq $true) "existing Scoop installation was not reported: $($completed.output)"
Assert-True ((Get-Content -LiteralPath (Join-Path $existing 'apps/scoop/current/manifest.json') -Raw).Trim() -eq '{"version":"0.6.0"}') 'init changed the existing Scoop installation'

# 8. The standard layout order is stable in JSON output.
Assert-True ((@($completedJson.directories) -join ',') -eq ($standard -join ',')) "init reported an unexpected layout order: $($completed.output)"
Write-Output 'PASS initialization: preview, creation, idempotence, conflict refusal and partial-root completion'

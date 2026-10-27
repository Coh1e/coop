param(
    [Parameter(Mandatory)][string]$ScoopLibDir,
    [Parameter(Mandatory)][string]$ScratchRoot,
    [Parameter(Mandatory)][string]$ManifestPath,
    [Parameter(Mandatory)][string]$PackageName,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$ScoopAppDir,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$Architecture = '64bit',
    [string]$ExecutableFixture = ''
)
# Runs the pinned Scoop v0.6.0 library functions themselves in a disposable scratch root, so a
# comparison does not depend on a PowerShell reimplementation of Scoop's rules. The only stubs are
# the two side effects that would touch the real user environment: Add-Path (user PATH) and
# startmenu_shortcut (real Start Menu). Everything else is Scoop's own shim_def/create_shims/
# create_startmenu_shortcuts/env_add_path code and its own shim file writer.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ScoopLibDir = [IO.Path]::GetFullPath($ScoopLibDir)
$ScratchRoot = [IO.Path]::GetFullPath($ScratchRoot)
$ManifestPath = [IO.Path]::GetFullPath($ManifestPath)
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$ScoopAppDir = [IO.Path]::GetFullPath($ScoopAppDir)
if (Test-Path -LiteralPath $ScratchRoot) { Remove-Item -LiteralPath $ScratchRoot -Recurse -Force }
$scoopRoot = Join-Path $ScratchRoot 'root'
$versionDir = Join-Path $scoopRoot "apps/$PackageName/$Version"
$currentDir = Join-Path $scoopRoot "apps/$PackageName/current"
New-Item -ItemType Directory -Path (Join-Path $scoopRoot 'shims'),$versionDir,(Join-Path $scoopRoot 'apps/scoop') -Force | Out-Null
New-Item -ItemType Junction -Path $currentDir -Target $versionDir | Out-Null
New-Item -ItemType Junction -Path (Join-Path $scoopRoot 'apps/scoop/current') -Target $ScoopAppDir | Out-Null
$env:SCOOP = $scoopRoot
foreach ($library in @('core.ps1','manifest.ps1','system.ps1','install.ps1','shortcuts.ps1')) {
    . (Join-Path $ScoopLibDir $library)
}
# These two functions are the only environment side effects in Scoop's shim path. Replace them after
# dot-sourcing so the real shim()/create_startmenu_shortcuts code still runs unchanged.
function Add-Path {
    param([string[]]$Path,[string]$TargetEnvVar = 'PATH',[switch]$Global,[switch]$Force,[switch]$Quiet)
}
$script:shortcutCalls = [System.Collections.Generic.List[object]]::new()
function startmenu_shortcut([System.IO.FileInfo]$target,$shortcutName,$arguments,[System.IO.FileInfo]$icon,$global) {
    $script:shortcutCalls.Add([pscustomobject]@{
        name = $shortcutName; target = $target.FullName; arguments = $arguments
        icon = $(if ($null -ne $icon) { $icon.FullName } else { '' })
    })
}
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
# @(arch_specific ...) is how Scoop's own create_shims captures a bin declaration that is a single
# tuple list; the array subexpression preserves the nested tuple that plain assignment would unroll.
$bin = @(arch_specific 'bin' $manifest $Architecture)
$targets = [System.Collections.Generic.List[object]]::new()
$binEntries = [System.Collections.Generic.List[object]]::new()
foreach ($item in $bin) {
    if ($null -eq $item) { continue }
    $parts = @(shim_def $item)
    $target = [string]$parts[0]
    $name = if ($parts.Count -gt 1 -and $parts[1]) { [string]$parts[1] } else { strip_ext (fname $target) }
    $arguments = if ($parts.Count -gt 2) { (@($parts[2..($parts.Count-1)]) | Where-Object { $null -ne $_ }) -join ' ' } else { '' }
    $targets.Add([pscustomobject]@{ target = $target; name = $name })
    $binEntries.Add([pscustomobject]@{ target = $target; name = $name; arguments = $arguments;
        family = $(if ($target -match '\.(exe|com)$') { 'direct' } else { 'script' }) })
}
$fixtureBytes = if ($ExecutableFixture -and (Test-Path -LiteralPath $ExecutableFixture)) { [IO.File]::ReadAllBytes($ExecutableFixture) } else { $null }
foreach ($entry in $targets) {
    $path = Join-Path $versionDir $entry.target
    New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
    if ([IO.Path]::GetExtension($path).ToLowerInvariant() -in @('.exe','.com') -and $null -ne $fixtureBytes) {
        [IO.File]::WriteAllBytes($path,$fixtureBytes)
    } else {
        [IO.File]::WriteAllText($path,"scoop probe payload for $($entry.target)`n")
    }
}
$global = $false
$dir = $currentDir
$original_dir = $currentDir
$persist_dir = Join-Path $scoopRoot "persist/$PackageName"
New-Item -ItemType Directory -Path $persist_dir -Force | Out-Null
create_shims $manifest $dir $false $Architecture | Out-Null
create_startmenu_shortcuts $manifest $dir $false $Architecture | Out-Null
$envPaths = [System.Collections.Generic.List[string]]::new()
$envAddPath = @(arch_specific 'env_add_path' $manifest $Architecture)
foreach ($value in $envAddPath) {
    if (-not $value) { continue }
    $resolved = Join-Path $dir $value | Get-AbsolutePath
    if (is_in_dir $dir $resolved) { $envPaths.Add($resolved) }
}
$shims = [System.Collections.Generic.List[object]]::new()
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $scoopRoot 'shims') -File | Sort-Object Name)) {
    $text = $null
    if ($file.Extension -in @('.shim','.cmd','.ps1') -or $file.Extension -eq '') {
        $text = [IO.File]::ReadAllText($file.FullName)
    }
    $shims.Add([pscustomobject]@{ name = $file.Name; length = $file.Length; text = $text;
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLower() })
}
$result = [ordered]@{
    package = $PackageName; version = $Version; architecture = $Architecture
    scoop_root = $scoopRoot; shims = $shims; shortcuts = $script:shortcutCalls; env_paths = $envPaths
    bin_entries = $binEntries
}
[IO.File]::WriteAllText($OutputPath,(ConvertTo-Json -InputObject $result -Depth 10),[Text.UTF8Encoding]::new($false))
Write-Output "Scoop probe wrote $OutputPath"

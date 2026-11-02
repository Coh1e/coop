# Shared evidence helpers; loading this file performs no filesystem or environment writes.
function Write-FourSampleJson {
    param([string]$Path, $Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 30
    [IO.File]::WriteAllText($Path, $json + "`r`n", (New-Object Text.UTF8Encoding($false)))
}

function Get-FourSampleTree {
    param([string]$Path, [string]$Label = '')
    try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
    catch {
        if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw }
        return [pscustomobject]@{ path = $Label; kind = 'absent'; value = '' }
    }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        # Do not follow links while recursively scanning a root (cycles and external user data).
        return [pscustomobject]@{ path = $Label; kind = 'link'; value = ($item.Target -join ';') }
    }
    if (-not $item.PSIsContainer) {
        return [pscustomobject]@{ path = $Label; kind = 'file'; value = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    }
    [pscustomobject]@{ path = $Label; kind = 'directory'; value = '' }
    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force | Sort-Object Name)) {
        Get-FourSampleTree $child.FullName ($Label + '/' + $child.Name)
    }
}

function Get-FourSampleSnapshot {
    param([string]$Root, [string]$Package)
    $files = @()
    foreach ($area in @('apps', 'persist')) {
        $files += @(Get-FourSampleTree (Join-Path $Root "$area/$Package") "$area/$Package")
        # Other applications' top-level identity, not a claim about all installed file contents.
        foreach ($item in @(Get-ChildItem -LiteralPath (Join-Path $Root $area) -Force -ErrorAction SilentlyContinue | Where-Object Name -ne $Package)) {
            $files += [pscustomobject]@{ path = "$area/$($item.Name)"; kind = 'other-object'; value = "$($item.CreationTimeUtc.Ticks)|$($item.Target -join ';')" }
        }
    }
    foreach ($area in @('shims', 'modules')) {
        $files += @(Get-FourSampleTree (Join-Path $Root $area) $area)
    }
    # Module links alone cannot establish that another module's contents survived uninstall.
    foreach ($module in @(Get-ChildItem -LiteralPath (Join-Path $Root 'modules') -Force -ErrorAction SilentlyContinue)) {
        if ($module.Name -ne $Package -and ($module.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            foreach ($target in @($module.Target)) {
                $seen = @()
                $resolved = $target
                while ($true) {
                    $resolved = [IO.Path]::GetFullPath($resolved)
                    if ($seen -contains $resolved -or $seen.Count -ge 32) { throw 'Module link cycle or excessive indirection' }
                    $seen += $resolved
                    $node = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
                    if (-not ($node.Attributes -band [IO.FileAttributes]::ReparsePoint)) { break }
                    if (@($node.Target).Count -ne 1) { throw 'Cannot resolve module link target' }
                    $next = @($node.Target)[0]
                    if (-not [IO.Path]::IsPathRooted($next)) { $next = Join-Path (Split-Path $resolved -Parent) $next }
                    $resolved = $next
                }
                $files += [pscustomobject]@{ path = ("module-chain/" + $module.Name); kind = 'resolved-links'; value = ($seen -join ';') }
                $files += @(Get-FourSampleTree $resolved ("module-content/" + $module.Name))
            }
        }
    }
    $environment = @()
    $userEnvironment = [Environment]::GetEnvironmentVariables('User')
    foreach ($key in @($userEnvironment.Keys | Sort-Object)) {
        $environment += [pscustomobject]@{ name = $key; value = $userEnvironment[$key] }
    }
    [pscustomobject]@{ files = @($files | Sort-Object path); user_environment = $environment }
}

function Compare-FourSampleSnapshot {
    param($Before, $After)
    $left = ConvertTo-Json -InputObject $Before -Depth 30 -Compress
    $right = ConvertTo-Json -InputObject $After -Depth 30 -Compress
    return $left -ceq $right
}

function Test-FourSampleHash {
    param([string]$Path, [string]$Expected)
    if ($Expected -notmatch '^[0-9a-fA-F]{64}$' -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Expected
}

function Assert-FourSampleDate {
    param([string]$Output)
    if ($Output.Trim() -cnotmatch '^0y 0m 10d\r?\n10d$') { throw "Expected the fixed ten-day date result, received: $Output" }
}

function Assert-FourSampleModule {
    param($Probe, [string]$Version, [string]$ModuleBase)
    if ($Probe.Version -ne $Version -or [IO.Path]::GetFullPath($Probe.ModuleBase).TrimEnd('\') -ine [IO.Path]::GetFullPath($ModuleBase).TrimEnd('\')) {
        throw 'Module version or directory differs from the expected published module'
    }
}

function Get-FourSampleCanonicalJson {
    param($Value)
    function OrderedValue($Item) {
        if ($null -eq $Item) { return $null }
        if ($Item -is [System.Management.Automation.PSCustomObject]) {
            $map = [ordered]@{}
            foreach ($property in @($Item.PSObject.Properties | Sort-Object Name)) { $map[$property.Name] = OrderedValue $property.Value }
            return $map
        }
        if ($Item -is [array]) {
            $items = New-Object 'System.Collections.Generic.List[object]'
            foreach ($element in $Item) { $items.Add((OrderedValue $element)) }
            return ,$items.ToArray()
        }
        return $Item
    }
    ConvertTo-Json -InputObject (OrderedValue $Value) -Depth 30 -Compress
}

function Get-FourSampleInstallRecords {
    param([string]$Directory, [string]$SourceManifest)
    $manifestPath = Join-Path $Directory 'scoop-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { $manifestPath = Join-Path $Directory 'manifest.json' }
    $installPath = Join-Path $Directory 'scoop-install.json'
    if (-not (Test-Path -LiteralPath $installPath)) { $installPath = Join-Path $Directory 'install.json' }
    $manifest = Get-Content -Encoding UTF8 -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $source = Get-Content -Encoding UTF8 -LiteralPath $SourceManifest -Raw | ConvertFrom-Json
    # Scoop may re-encode a URL manifest. Preserve both byte digests, compare all JSON content.
    if ((Get-FourSampleCanonicalJson $manifest) -cne (Get-FourSampleCanonicalJson $source)) { throw 'Installed manifest content differs from the reviewed source' }
    [pscustomobject]@{
        manifest = $manifest
        manifest_path = $manifestPath
        manifest_sha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
        install_path = $installPath
        install_sha256 = (Get-FileHash -LiteralPath $installPath -Algorithm SHA256).Hash
        install = (Get-Content -Encoding UTF8 -LiteralPath $installPath -Raw | ConvertFrom-Json)
    }
}

function Test-FourSampleJsonValueEqual {
    param($Left, $Right)
    if ($null -eq $Left -or $null -eq $Right) { return ($null -eq $Left -and $null -eq $Right) }
    if ($Left.GetType() -ne $Right.GetType()) { return $false }
    if ($Left -is [System.Management.Automation.PSCustomObject]) {
        if (@($Left.PSObject.Properties).Count -ne @($Right.PSObject.Properties).Count) { return $false }
        foreach ($property in $Left.PSObject.Properties) {
            $other = $Right.PSObject.Properties[$property.Name]
            if ($null -eq $other -or $property.Name -cne $other.Name) { return $false }
            if (-not (Test-FourSampleJsonValueEqual $property.Value $other.Value)) { return $false }
        }
        return $true
    }
    if ($Left -is [array]) {
        if ($Left.Count -ne $Right.Count) { return $false }
        for ($index = 0; $index -lt $Left.Count; $index++) {
            if (-not (Test-FourSampleJsonValueEqual $Left[$index] $Right[$index])) { return $false }
        }
        return $true
    }
    return $Left -ceq $Right
}

function Get-FourSampleManifestComparison {
    param([string]$SourceManifest, [string]$CurrentManifest, [string]$ExpectedSourceHash)
    # Read each file once: the hashes and parsed content must describe the same bytes.
    $sourceBytes = [IO.File]::ReadAllBytes($SourceManifest)
    $currentBytes = [IO.File]::ReadAllBytes($CurrentManifest)
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $sourceHash = [BitConverter]::ToString($hash.ComputeHash($sourceBytes)).Replace('-', '').ToLowerInvariant()
        $currentHash = [BitConverter]::ToString($hash.ComputeHash($currentBytes)).Replace('-', '').ToLowerInvariant()
    } finally { $hash.Dispose() }
    $comparison = [pscustomobject]@{
        source_path = $SourceManifest
        current_path = $CurrentManifest
        expected_source_sha256 = $ExpectedSourceHash
        source_sha256 = $sourceHash
        current_sha256 = $currentHash
        source_digest_matches_expected = ($sourceHash -eq $ExpectedSourceHash)
        byte_equal = ($sourceHash -eq $currentHash)
        content_equal = $false
        parse_error = $null
    }
    try {
        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        $sourceText = $utf8.GetString($sourceBytes).TrimStart([char]0xFEFF).Trim()
        $currentText = $utf8.GetString($currentBytes).TrimStart([char]0xFEFF).Trim()
        # PowerShell enumerates a root JSON array; a single object in an array would otherwise
        # be indistinguishable from an object after assignment.
        if (-not $sourceText.StartsWith('{') -or -not $currentText.StartsWith('{')) { throw 'Manifest root must be a JSON object' }
        $sourceValue = ConvertFrom-Json -InputObject $sourceText -ErrorAction Stop
        $currentValue = ConvertFrom-Json -InputObject $currentText -ErrorAction Stop
        if ($sourceValue -isnot [System.Management.Automation.PSCustomObject] -or $currentValue -isnot [System.Management.Automation.PSCustomObject]) { throw 'Manifest root must be a JSON object' }
        # Compare recursively rather than through a depth-limited JSON serialization.
        $comparison.content_equal = Test-FourSampleJsonValueEqual $sourceValue $currentValue
    } catch { $comparison.parse_error = $_.Exception.Message }
    return $comparison
}

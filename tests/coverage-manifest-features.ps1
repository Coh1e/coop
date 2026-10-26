# Manifest feature scan and file hashing shared by tests/real-scoop-coverage.ps1.
# Dot-source this file both in the main inventory process and inside its parallel
# runspaces, because functions defined by the caller are not visible in those runspaces.

function Get-Sha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path)))).Replace('-','').ToLower() }
    finally { $sha.Dispose() }
}

# Feature names describe what a Manifest declares across its root object and every
# architecture section. checkver/autoupdate are deliberately excluded: they are not part
# of installing or managing an installed package.
function Read-ManifestFeatures([System.Collections.IDictionary]$Manifest) {
    $features = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $views = @($Manifest)
    if ($Manifest.architecture -is [System.Collections.IDictionary]) {
        foreach ($name in $Manifest.architecture.Keys) {
            $section = $Manifest.architecture[$name]
            if ($section -is [System.Collections.IDictionary]) {
                $views += $section
                [void]$features.Add('architecture.'+$name)
            }
        }
    }
    $fieldFeatures = [ordered]@{
        bin = 'field.bin'; shortcuts = 'field.shortcuts'; env_add_path = 'field.env_add_path'
        env_set = 'field.env_set'; persist = 'field.persist'; depends = 'field.depends'
        extract_dir = 'field.extract_dir'; extract_to = 'field.extract_to'
        innosetup = 'field.innosetup'; psmodule = 'field.psmodule'
        pre_install = 'script.pre_install'; post_install = 'script.post_install'
        pre_uninstall = 'script.pre_uninstall'; post_uninstall = 'script.post_uninstall'
        installer = 'field.installer'; uninstaller = 'field.uninstaller'
    }
    foreach ($view in $views) {
        foreach ($field in $fieldFeatures.Keys) {
            if ($view.Contains($field)) { [void]$features.Add($fieldFeatures[$field]) }
        }
        foreach ($kind in @('installer','uninstaller')) {
            $operation = $view[$kind]
            if ($operation -is [System.Collections.IDictionary]) {
                foreach ($part in @('script','file','args')) {
                    if ($operation.Contains($part)) { [void]$features.Add("$kind.$part") }
                }
            }
        }
        if ($view.Contains('bin')) {
            foreach ($entry in @($view.bin)) {
                if ($null -eq $entry) { continue }
                # A bin entry is a target path, or a list whose first element is the path
                # (the remaining elements are arguments). Keep the whole path: targets can
                # contain spaces, and splitting on whitespace invents fake host types.
                $target = if ($entry -is [System.Collections.IDictionary]) { [string]$entry.path }
                          elseif ($entry -is [System.Collections.IEnumerable] -and $entry -isnot [string]) { [string]@($entry)[0] }
                          else { [string]$entry }
                $target = $target.Trim()
                if ($target.Length -ge 2 -and (($target[0] -eq '"' -and $target[-1] -eq '"') -or ($target[0] -eq "'" -and $target[-1] -eq "'"))) {
                    $target = $target.Substring(1,$target.Length-2).Trim()
                }
                $extension = [IO.Path]::GetExtension($target).TrimStart('.').ToLower()
                if (-not $extension) { $extension = 'no-extension' }
                [void]$features.Add('command.'+$extension)
            }
        }
        $urls = @($view.url)
        if ($urls.Count -gt 1) { [void]$features.Add('download.multiple') }
        foreach ($url in $urls) {
            if ($null -eq $url) { continue }
            $text = [string]$url
            if ($text -match '#/') { [void]$features.Add('download.renamed') }
            $name = (($text -split '#')[0] -split '\?')[0]
            $extension = if ($name -match '\.tar\.(gz|xz|bz2|zst)$') { 'tar.'+$Matches[1] }
                         elseif ($name -match '\.(zip|7z|msi|exe|tgz|tar)$') { $Matches[1] }
                         else { 'other' }
            [void]$features.Add('download.'+$extension)
            $localName = if ($text -match '#/(.+)$') { $Matches[1] } else { $name }
            $localExtension = if ($localName -match '\.tar\.(gz|xz|bz2|zst)$') { 'tar.'+$Matches[1] }
                              elseif ($localName -match '\.(zip|7z|msi|exe|tgz|tar)$') { $Matches[1] }
                              else { 'other' }
            [void]$features.Add('local.'+$localExtension)
        }
        $hash = [string]$view.hash
        if ($hash) {
            $algorithm = if ($hash -match ':') { ($hash -split ':')[0].ToLower() } else { 'sha256' }
            [void]$features.Add('hash.'+$algorithm)
        }
    }
    if ($features.Contains('script.pre_install') -or $features.Contains('script.post_install') -or
        $features.Contains('script.pre_uninstall') -or $features.Contains('script.post_uninstall') -or
        $features.Contains('installer.script') -or $features.Contains('uninstaller.script')) {
        [void]$features.Add('script.any')
    }
    return @($features | Sort-Object)
}

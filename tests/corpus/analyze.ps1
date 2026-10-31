param(
    [string]$SourceRoot = (Join-Path $PSScriptRoot '../../.local/research/t01'),
    [string]$OutputRoot = $PSScriptRoot
)
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')).TrimEnd('\') + '\'
foreach ($location in @($SourceRoot, $OutputRoot)) {
    $resolved = [IO.Path]::GetFullPath($location).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($project, [StringComparison]::OrdinalIgnoreCase)) { throw 'Corpus inputs and outputs must stay within this project' }
}
$revisions = [ordered]@{
    Scoop = 'e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f'
    Main = '9f7439bdb2a361f4ee6eb19a51c62136a3823ca7'
    Extras = '8b42c8c3140ca34ed718704189d97e1da7b3c315'
}
$fields = @('architecture','bin','shortcuts','env_add_path','env_set','persist','depends','extract_dir','extract_to','pre_install','post_install','pre_uninstall','post_uninstall','installer','uninstaller','innosetup','psmodule')
function Get-InstallViews([System.Collections.IDictionary]$Manifest) {
    $views = @($Manifest)
    if ($Manifest.architecture -is [System.Collections.IDictionary]) {
        foreach ($arch in $Manifest.architecture.Values) {
            if ($arch -is [System.Collections.IDictionary]) { $views += $arch }
        }
    }
    return ,$views
}
function Get-Features([System.Collections.IDictionary]$Manifest) {
    $views = Get-InstallViews $Manifest
    $features = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($view in $views) {
        foreach ($field in $fields) { if ($view.Contains($field)) { [void]$features.Add($field) } }
        foreach ($kind in @('installer','uninstaller')) {
            $op = $view[$kind]
            if ($op -is [System.Collections.IDictionary]) {
                foreach ($part in @('script','file','args')) {
                    if ($op.Contains($part)) { [void]$features.Add("$kind.$part") }
                }
            }
        }
        if ($view.url -is [array] -and $view.url.Count -gt 1) { [void]$features.Add('multiple_downloads') }
        foreach ($url in @($view.url)) {
            if ($null -eq $url) { continue }
            $name = (([string]$url -split '#')[0] -split '\?')[0]
            $extension = if ($name -match '\.tar\.(gz|xz|bz2|zst)(?:#.*)?$') { 'tar.' + $Matches[1] }
                         elseif ($name -match '\.(zip|7z|msi|exe|tgz|tar)(?:#.*)?$') { $Matches[1] }
                         else { 'other' }
            [void]$features.Add("url_format.$extension")
            $localName = if ([string]$url -match '#/(.+)$') { $Matches[1] } else { $name }
            $localExtension = if ($localName -match '\.tar\.(gz|xz|bz2|zst)$') { 'tar.' + $Matches[1] }
                              elseif ($localName -match '\.(zip|7z|msi|exe|tgz|tar)$') { $Matches[1] }
                              else { 'other' }
            [void]$features.Add("local_format.$localExtension")
        }
    }
    $scriptKeys = @('pre_install','post_install','pre_uninstall','post_uninstall','installer.script','uninstaller.script')
    if (@($scriptKeys | Where-Object { $features.Contains($_) }).Count) { [void]$features.Add('any_install_script') }
    else { [void]$features.Add('no_install_script_field') }
    return ,@($features | Sort-Object)
}
$stats = [ordered]@{ schema = 1; scope = 'Manifest root plus architecture objects; exclude checkver/autoupdate script and URLs'; revisions = $revisions; buckets = [ordered]@{} }
$all = @{}
foreach ($bucket in @('Main','Extras')) {
    $dir = Join-Path $SourceRoot ($bucket+'-'+$revisions[$bucket]+'/bucket')
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | Sort-Object Name)
    if (-not $files.Count) { throw "No manifests: $dir" }
    $counts = [ordered]@{}
    foreach ($file in $files) {
        $manifest = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
        $features = Get-Features $manifest
        foreach ($feature in $features) {
            if (-not $counts.Contains($feature)) { $counts[$feature] = 0 }
            $counts[$feature]++
        }
        $all[$bucket+'/'+$file.BaseName] = @{ file = $file.FullName; manifest = $manifest; features = $features }
    }
    $stats.buckets[$bucket] = @{ manifests = $files.Count; parse_errors = 0; counts = $counts }
}
$selection = [ordered]@{
    'Main/jq' = '无脚本单 EXE，三架构，URL fragment 重命名；首条原生生命周期候选'
    'Main/ripgrep' = 'ZIP、extract_dir、普通命令入口'
    'Main/neovim' = 'ZIP 解压目录与普通入口，devkit 实际工具'
    'Main/cmake' = '解压目录、多个命令与快捷方式'
    'Main/git' = '7z 自解压产物，环境、命令、快捷方式、安装卸载脚本'
    'Main/7zip' = 'MSI/EXE 架构差异、脚本、persist、快捷方式及卸载脚本'
    'Main/python' = 'installer.script 与卸载脚本、环境路径、持久化'
    'Main/nodejs' = '7z 产物、persist、env_add_path、post_install'
    'Main/wget' = '显式依赖和 post_install'
    'Main/rclone' = '配置持久化、pre_install、uninstaller.script'
    'Main/android-clt' = 'extract_to 映射、环境和复杂持久化'
    'Main/azure-cli' = 'ZIP、环境及 pre/post_uninstall'
    'Extras/notepadplusplus' = '复杂 pre/post_install、uninstaller、persist、快捷方式'
    'Extras/vscode' = '本地命名 dl.7z、配置持久化、PATH、快捷方式与卸载脚本'
    'Extras/everything' = 'GUI、命令入口、快捷方式及 pre_uninstall'
    'Extras/firefox' = '不同架构、extract_dir、persist、post_install'
    'Main/air' = 'tar.gz、三架构、无安装 Hook 的命令行工具'
    'Extras/adventuregamestudio' = 'InnoSetup 声明及特殊安装器提取'
    'Extras/aider-desk' = '架构专属 pre_install、嵌套 7z/NSIS 提取与 post_uninstall'
    'Main/oh-my-posh' = 'ZIP+EXE 多下载项、extract_to 与环境变量'
}
$index = [ordered]@{ schema = 1; revisions = $revisions; samples = @() }
foreach ($key in $selection.Keys) {
    if (-not $all.ContainsKey($key)) { throw "Missing selected sample: $key" }
    $parts = $key -split '/'
    $entry = $all[$key]
    $dest = Join-Path $OutputRoot ($parts[0].ToLower()+'/'+$parts[1]+'.json')
    New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
    Copy-Item -LiteralPath $entry.file -Destination $dest
    $index.samples += [ordered]@{
        id = $key; version = $entry.manifest.version; revision = $revisions[$parts[0]]
        source = 'https://github.com/ScoopInstaller/'+$parts[0]+'/blob/'+$revisions[$parts[0]]+'/bucket/'+$parts[1]+'.json'
        sha256 = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLower()
        reason = $selection[$key]; features = $entry.features
        parse = 'parsed-by-PowerShell-ConvertFrom-Json'; plan = 'not-run'; lifecycle = 'not-run'
    }
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$stats | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputRoot 'statistics.json') -Encoding utf8
$index | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputRoot 'index.json') -Encoding utf8
Write-Output ('Parsed Main={0}, Extras={1}; copied {2} unchanged samples' -f $stats.buckets.Main.manifests,$stats.buckets.Extras.manifests,$index.samples.Count)

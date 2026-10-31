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
    'Main/jq' = '三架构单 EXE（#/jq.exe 改名），bin=jq.exe，无安装 Hook'
    'Main/ripgrep' = '三架构 ZIP + extract_dir，bin=rg.exe；ZIP 安装/更新/卸载样本'
    'Main/neovim' = '64bit/arm64 ZIP + 架构专属 extract_dir，bin 为 bin\nvim.exe 与 bin\xxd.exe'
    'Main/cmake' = '三架构 ZIP + extract_dir，5 个 bin 与 cmake-gui 快捷方式'
    'Main/git' = 'PortableGit 7z 自解压（#/dl.7z），bin 覆盖 sh/git/gitk/scalar/gpg，env_set GIT_INSTALL_ROOT，三个快捷方式与安装/卸载脚本'
    'Main/7zip' = '64/32bit MSI 与 arm64 EXE 的架构差异；extract_dir=Files\7-Zip，persist Codecs/Formats，两个快捷方式、post_install 注册表与 uninstaller.script'
    'Main/python' = 'EXE 经 #/setup.exe 下载，installer.script 展开 Dark/MSI；env_add_path Scripts 与 .，persist Scripts/Lib\site-packages，pre/post_install 与卸载脚本'
    'Main/nodejs' = '7z + extract_dir，env_add_path bin 与 .，persist bin/cache，post_install 写 npm prefix/cache'
    'Main/wget' = '64/32bit ZIP，depends=cacert，post_install 用 cacert 当前路径写 wget.ini'
    'Main/rclone' = '三架构 ZIP + extract_dir，persist rclone.conf，pre_install 初始化配置，uninstaller.script 回拷配置'
    'Main/android-clt' = '单 ZIP + extract_to=cmdline-tools，env_add_path 两条，env_set ANDROID_HOME，persist 11 个目录，pre/post_install 与 pre_uninstall 维护 latest'
    'Main/azure-cli' = '64bit ZIP，bin=bin\az.cmd，env_set AZURE_CLI_PATH 与 AzureCLIPath，pre/post_uninstall 处理 --purge'
    'Extras/notepadplusplus' = '三架构 ZIP，persist 11 个文件/目录，pre_install 清错误目录、post_install 导入上下文注册表，uninstaller.script 与快捷方式'
    'Extras/vscode' = '64bit/arm64 的 #/dl.7z，env_add_path bin，persist data，post_install 写注册表，uninstaller.script 清三类注册表，快捷方式'
    'Extras/everything' = '三架构 ZIP，bin=Everything.exe，pre_install 处理 arm64 改名与 persist ini，post_install 导入上下文注册表，pre_uninstall 停进程/服务，快捷方式'
    'Extras/firefox' = '三架构 Setup EXE 改名 dl.7z，extract_dir=core，persist distribution/profile，post_install 建 profile，两个快捷方式'
    'Main/air' = '三架构 tar.gz，单 bin air.exe，无安装 Hook；tar.gz 生命周期样本'
    'Extras/adventuregamestudio' = 'InnoSetup 声明，单 EXE 产物，两个快捷方式；由 innounp helper 提取'
    'Extras/aider-desk' = '64bit NSIS 自解压 setup 改名 dl.7z，pre_install 再解嵌套 $PLUGINSDIR\app-64.7z，env_set AIDER_DESK_DATA_DIR，post_uninstall 清 %APPDATA%\aider-desk，快捷方式'
    'Main/oh-my-posh' = '64bit/arm64 各有 themes.zip + EXE 两个下载项，EXE 改名 oh-my-posh.exe，extract_to=themes，env_set POSH_THEMES_PATH，bin=oh-my-posh.exe'
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

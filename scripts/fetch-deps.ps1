$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$sources = Join-Path $projectRoot '.local/deps/sources'
$fixtures = Join-Path $projectRoot '.local/deps/test-fixtures'
$archives = Join-Path $projectRoot '.local/deps/test-archives'
New-Item -ItemType Directory -Path $sources,$fixtures,$archives -Force | Out-Null

function Get-PinnedFile([string]$Name, [string]$Url, [string]$Hash, [string]$Directory) {
    $target = Join-Path $Directory $Name
    if (-not (Test-Path -LiteralPath $target)) {
        $temporary = "$target.download"
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        & curl.exe -fL --retry 2 $Url -o $temporary
        if ($LASTEXITCODE -ne 0) { throw "Dependency download failed: $Name" }
        if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLower() -ne $Hash) { throw "Dependency hash mismatch: $Name" }
        Move-Item -LiteralPath $temporary -Destination $target
    }
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLower() -ne $Hash) { throw "Existing dependency hash mismatch: $Name" }
    return $target
}

$json = Join-Path $projectRoot '.local/deps/include/nlohmann'
New-Item -ItemType Directory -Path $json -Force | Out-Null
foreach ($file in @(
    @{Name='json.hpp'; Source='single_include/nlohmann/json.hpp'; Hash='aaf127c04cb31c406e5b04a63f1ae89369fccde6d8fa7cdda1ed4f32dfc5de63'},
    @{Name='LICENSE.MIT'; Source='LICENSE.MIT'; Hash='46a65cffd1ea955132d95a8dd921640714a8d6b537d2e4e482d31145ae95b603'}
)) {
    Get-PinnedFile $file.Name ('https://raw.githubusercontent.com/nlohmann/json/v3.12.0/'+$file.Source) $file.Hash $json | Out-Null
}
Write-Output 'Verified nlohmann/json v3.12.0'

$gitArchive = Get-PinnedFile 'libgit2-1.9.7.tar.gz' 'https://codeload.github.com/libgit2/libgit2/tar.gz/refs/tags/v1.9.7' '1a4fbe7589e814777ae76b64734ad80f4ecad22cd33a22682a2aaea4ae5375e7' $sources
if (-not (Test-Path -LiteralPath (Join-Path $sources 'libgit2-1.9.7/CMakeLists.txt'))) {
    & tar.exe -xf $gitArchive -C $sources 'libgit2-1.9.7/CMakeLists.txt' 'libgit2-1.9.7/cmake/*' 'libgit2-1.9.7/include/*' 'libgit2-1.9.7/src/*' 'libgit2-1.9.7/deps/*' 'libgit2-1.9.7/COPYING'
    if ($LASTEXITCODE -ne 0) { throw 'Git library source extraction failed' }
}
Write-Output 'Verified libgit2 v1.9.7 sources'

$archiveDependencies = @(
    @{Name='libarchive-3.7.7.tar.gz'; Url='https://codeload.github.com/libarchive/libarchive/tar.gz/refs/tags/v3.7.7'; Hash='fa62384995e8aa4f5a901c184fb5c91e56a29e24c05b6881a7f8fd5bbea694d2'; Directory='libarchive-3.7.7'},
    @{Name='zlib-1.3.1.tar.gz'; Url='https://codeload.github.com/madler/zlib/tar.gz/refs/tags/v1.3.1'; Hash='17e88863f3600672ab49182f217281b6fc4d3c762bde361935e436a95214d05c'; Directory='zlib-1.3.1'},
    @{Name='xz-5.6.4.tar.gz'; Url='https://codeload.github.com/tukaani-project/xz/tar.gz/refs/tags/v5.6.4'; Hash='f6820629a1f7304b4c7364b5f5dae04fa8b799e41224e96cae1a8d94cf7d0b55'; Directory='xz-5.6.4'},
    @{Name='zstd-1.5.7.tar.gz'; Url='https://codeload.github.com/facebook/zstd/tar.gz/refs/tags/v1.5.7'; Hash='37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3'; Directory='zstd-1.5.7'; Exclude='*/tests/*'},
    @{Name='bzip2-1.0.8.tar.gz'; Url='https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz'; Hash='ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269'; Directory='bzip2-1.0.8'}
)
foreach ($dependency in $archiveDependencies) {
    $archive = Get-PinnedFile $dependency.Name $dependency.Url $dependency.Hash $sources
    $marker = if ($dependency.Directory -eq 'zstd-1.5.7') { 'build/cmake/CMakeLists.txt' } elseif ($dependency.Directory -eq 'bzip2-1.0.8') { 'bzlib.c' } else { 'CMakeLists.txt' }
    if (-not (Test-Path -LiteralPath (Join-Path $sources ($dependency.Directory+'/'+$marker)))) {
        $extractArguments = @('-xf',$archive,'-C',$sources)
        if ($dependency.Exclude) { $extractArguments += ('--exclude='+$dependency.Exclude) }
        & tar.exe @extractArguments
        if ($LASTEXITCODE -ne 0) { throw "Archive dependency extraction failed: $($dependency.Name)" }
    }
    if ($dependency.Directory -eq 'xz-5.6.4') {
        # Only liblzma is compiled; xz's upstream CTest registration is not part of this project.
        $xzTests = Join-Path $sources 'xz-5.6.4/tests'
        if (Test-Path -LiteralPath $xzTests) { Remove-Item -LiteralPath $xzTests -Recurse -Force }
    }
    Write-Output ('Verified '+$dependency.Directory+' sources')
}

foreach ($file in @(
    @{Name='scoop-shim-kiennq.exe';Source='supporting/shims/kiennq/shim.exe';Hash='140e3801d8adeda639a21b14e62b93a4c7d26b7a758421f43c82be59753be49b'},
    @{Name='Scoop-LICENSE';Source='LICENSE';Hash='92c2b8f7e3b344a307889ff5f55dc3d7fa048f846845549df0e33e44e5939476'}
)) {
    Get-PinnedFile $file.Name ('https://raw.githubusercontent.com/ScoopInstaller/Scoop/e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f/'+$file.Source) $file.Hash $fixtures | Out-Null
}
Write-Output 'Verified Scoop 0.6.0 test-only native shim and license'

$testArchives = @(
    @{Name='jq-1.7.1-windows-amd64.exe'; Url='https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-windows-amd64.exe'; Hash='7451fbbf37feffb9bf262bd97c54f0da558c63f0748e64152dd87b0a07b6d6ab'},
    @{Name='jq-1.8.2-windows-amd64.exe'; Url='https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-windows-amd64.exe'; Hash='a6fc67fedaf9128a3309a1e2ebb8b986aeccf70122ee46d2cb4849e423f0c627'},
    @{Name='ripgrep-14.1.1-x86_64-pc-windows-msvc.zip'; Url='https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-x86_64-pc-windows-msvc.zip'; Hash='d0f534024c42afd6cb4d38907c25cd2b249b79bbe6cc1dbee8e3e37c2b6e25a1'},
    @{Name='ripgrep-15.2.0-x86_64-pc-windows-msvc.zip'; Url='https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-x86_64-pc-windows-msvc.zip'; Hash='71b2fef860abe467217a538ff31de02f5258807c0129f771846f87bd029aafc5'},
    @{Name='air_1.67.3_windows_amd64.tar.gz'; Url='https://github.com/air-verse/air/releases/download/v1.67.3/air_1.67.3_windows_amd64.tar.gz'; Hash='150ab78cf4a48f46ca845660b41a913b0bae94572c061ea5dbe75cd745849a5a'},
    @{Name='air_1.67.4_windows_amd64.tar.gz'; Url='https://github.com/air-verse/air/releases/download/v1.67.4/air_1.67.4_windows_amd64.tar.gz'; Hash='c35dbd568cff98055cc382d003bfda06bcdae82389568fb5e60ce5da278fa79d'},
    @{Name='air_1.67.4_windows_386.tar.gz'; Url='https://github.com/air-verse/air/releases/download/v1.67.4/air_1.67.4_windows_386.tar.gz'; Hash='91df7ef7f35da4a23129e172675137e1b8cd6835392736d817bb443c0dc424c8'},
    @{Name='7z2605-x64.msi'; Url='https://github.com/ip7z/7zip/releases/download/26.05/7z2605-x64.msi'; Hash='3fe4ab99fa15629c652944309a2b2bc6e41fc933fc6b63f5df1ebcf3aea68263'},
    @{Name='node-v26.12.1-win-x64.7z'; Url='https://nodejs.org/dist/v26.12.1/node-v26.12.1-win-x64.7z'; Hash='4deef78146a60555c9518438cae38da8df71722ca856920b90078f5cdeb642a6'},
    @{Name='luajit-2.1.1791988261-1-any.pkg.tar.zst'; Url='https://mirror.msys2.org/mingw/mingw64/mingw-w64-x86_64-luajit-2.1.1791988261-1-any.pkg.tar.zst'; Hash='d559881bffc105af4482eab52a34fa57963047cf45e735a5c0f8daca605c68a1'},
    @{Name='tidy-5.8.0-win64.zip'; Url='https://github.com/htacg/tidy-html5/releases/download/5.8.0/tidy-5.8.0-win64.zip'; Hash='ffb2f86484c66e70e6a6da369cb8f0f459ad2ffec7c7ca80d09a13445ee51a40'},
    @{Name='unz600xn.exe'; Url='https://raw.githubusercontent.com/ScoopInstaller/Binary/master/unzip/unz600xn.exe'; Hash='7869ee36346b47701ef01efd0bc2889f970266b66c80b30f74303d50bf7fa33d'},
    @{Name='curl-8.23.0_5-win64-mingw.tar.xz'; Url='https://curl.se/windows/dl-8.23.0_5/curl-8.23.0_5-win64-mingw.tar.xz'; Hash='b6ad235d1907d96615334532eab1db0040860e6b5adc3b8749a4331924449c3b'}
)
foreach ($file in $testArchives) { Get-PinnedFile $file.Name $file.Url $file.Hash $archives | Out-Null }
Write-Output 'Verified fixed real ZIP, tar.gz/tar.xz/tar.zst, 7z, 7z SFX and MSI test archives'

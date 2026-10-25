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
    @{Name='xz-5.6.4.tar.gz'; Url='https://codeload.github.com/tukaani-project/xz/tar.gz/refs/tags/v5.6.4'; Hash='f6820629a1f7304b4c7364b5f5dae04fa8b799e41224e96cae1a8d94cf7d0b55'; Directory='xz-5.6.4'}
)
foreach ($dependency in $archiveDependencies) {
    $archive = Get-PinnedFile $dependency.Name $dependency.Url $dependency.Hash $sources
    if (-not (Test-Path -LiteralPath (Join-Path $sources ($dependency.Directory+'/CMakeLists.txt')))) {
        & tar.exe -xf $archive -C $sources
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
    @{Name='ripgrep-14.1.1-x86_64-pc-windows-msvc.zip'; Url='https://github.com/BurntSushi/ripgrep/releases/download/14.1.1/ripgrep-14.1.1-x86_64-pc-windows-msvc.zip'; Hash='d0f534024c42afd6cb4d38907c25cd2b249b79bbe6cc1dbee8e3e37c2b6e25a1'},
    @{Name='ripgrep-15.2.0-x86_64-pc-windows-msvc.zip'; Url='https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-x86_64-pc-windows-msvc.zip'; Hash='71b2fef860abe467217a538ff31de02f5258807c0129f771846f87bd029aafc5'},
    @{Name='air_1.67.3_windows_amd64.tar.gz'; Url='https://github.com/air-verse/air/releases/download/v1.67.3/air_1.67.3_windows_amd64.tar.gz'; Hash='150ab78cf4a48f46ca845660b41a913b0bae94572c061ea5dbe75cd745849a5a'},
    @{Name='air_1.67.4_windows_amd64.tar.gz'; Url='https://github.com/air-verse/air/releases/download/v1.67.4/air_1.67.4_windows_amd64.tar.gz'; Hash='c35dbd568cff98055cc382d003bfda06bcdae82389568fb5e60ce5da278fa79d'},
    @{Name='air_1.67.4_windows_386.tar.gz'; Url='https://github.com/air-verse/air/releases/download/v1.67.4/air_1.67.4_windows_386.tar.gz'; Hash='91df7ef7f35da4a23129e172675137e1b8cd6835392736d817bb443c0dc424c8'}
)
foreach ($file in $testArchives) { Get-PinnedFile $file.Name $file.Url $file.Hash $archives | Out-Null }
Write-Output 'Verified fixed real ZIP and tar.gz test archives'

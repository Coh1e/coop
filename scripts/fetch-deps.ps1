$ErrorActionPreference = 'Stop'
$destination = Join-Path (Split-Path $PSScriptRoot -Parent) '.local/deps/include/nlohmann'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$files = @(
    @{ Name='json.hpp'; Source='single_include/nlohmann/json.hpp'; Hash='aaf127c04cb31c406e5b04a63f1ae89369fccde6d8fa7cdda1ed4f32dfc5de63' },
    @{ Name='LICENSE.MIT'; Source='LICENSE.MIT'; Hash='46a65cffd1ea955132d95a8dd921640714a8d6b537d2e4e482d31145ae95b603' }
)
foreach ($file in $files) {
    $target = Join-Path $destination $file.Name
    if (-not (Test-Path -LiteralPath $target)) {
        $temporary = "$target.download"
        & curl.exe -fL --retry 2 ('https://raw.githubusercontent.com/nlohmann/json/v3.12.0/'+$file.Source) -o $temporary
        if ($LASTEXITCODE -ne 0) { throw 'Dependency download failed' }
        if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLower() -ne $file.Hash) { throw 'Dependency hash mismatch' }
        Move-Item -LiteralPath $temporary -Destination $target
    }
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLower() -ne $file.Hash) { throw 'Existing dependency hash mismatch' }
    Write-Output ('Verified nlohmann/json v3.12.0 '+$file.Name)
}
$sources = Join-Path (Split-Path $PSScriptRoot -Parent) '.local/deps/sources'
New-Item -ItemType Directory -Path $sources -Force | Out-Null
$archive = Join-Path $sources 'libgit2-1.9.7.tar.gz'
if (-not (Test-Path -LiteralPath $archive)) {
    & curl.exe -fL --retry 2 https://codeload.github.com/libgit2/libgit2/tar.gz/refs/tags/v1.9.7 -o "$archive.download"
    if ($LASTEXITCODE -ne 0) { throw 'Git library download failed' }
    if ((Get-FileHash -LiteralPath "$archive.download" -Algorithm SHA256).Hash.ToLower() -ne '1a4fbe7589e814777ae76b64734ad80f4ecad22cd33a22682a2aaea4ae5375e7') { throw 'Git library archive hash mismatch' }
    Move-Item -LiteralPath "$archive.download" -Destination $archive
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower() -ne '1a4fbe7589e814777ae76b64734ad80f4ecad22cd33a22682a2aaea4ae5375e7') { throw 'Existing Git library archive hash mismatch' }
if (-not (Test-Path -LiteralPath (Join-Path $sources 'libgit2-1.9.7/CMakeLists.txt'))) {
    & tar.exe -xf $archive -C $sources 'libgit2-1.9.7/CMakeLists.txt' 'libgit2-1.9.7/cmake/*' 'libgit2-1.9.7/include/*' 'libgit2-1.9.7/src/*' 'libgit2-1.9.7/deps/*' 'libgit2-1.9.7/COPYING'
    if ($LASTEXITCODE -ne 0) { throw 'Git library source extraction failed' }
}
Write-Output 'Verified libgit2 v1.9.7 sources'

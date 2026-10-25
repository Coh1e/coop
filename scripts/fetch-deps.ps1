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

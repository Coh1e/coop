param([string]$Destination = (Join-Path $PSScriptRoot '../../.local/research/t01'))
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')).TrimEnd('\') + '\'
$target = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
if (-not $target.StartsWith($project, [StringComparison]::OrdinalIgnoreCase)) { throw 'Research downloads must stay within this project' }
New-Item -ItemType Directory -Path $target -Force | Out-Null
$revisions = [ordered]@{
    Scoop = 'e6aa3b366bdee8ed138c1e0f7b85192ebdd35d0f'
    Main = '9f7439bdb2a361f4ee6eb19a51c62136a3823ca7'
    Extras = '8b42c8c3140ca34ed718704189d97e1da7b3c315'
}
$sourceRecords = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'sources.json') -Raw | ConvertFrom-Json).archives
foreach ($repo in $revisions.Keys) {
    $archive = Join-Path $target ($repo.ToLower()+'.zip')
    if (-not (Test-Path -LiteralPath $archive)) {
        & curl.exe -fL --retry 2 ('https://codeload.github.com/ScoopInstaller/'+$repo+'/zip/'+$revisions[$repo]) -o $archive
        if ($LASTEXITCODE -ne 0) { throw "Download failed: $repo" }
    }
    $expected = $sourceRecords | Where-Object { $_.repository -eq ('ScoopInstaller/'+$repo) }
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower()
    if ($expected.revision -ne $revisions[$repo] -or $actual -ne $expected.sha256) { throw "Source archive identity mismatch: $repo" }
    $source = Join-Path $target ($repo+'-'+$revisions[$repo])
    if (-not (Test-Path -LiteralPath $source)) {
        & tar.exe -xf $archive -C $target
        if ($LASTEXITCODE -ne 0) { throw "Source extraction failed: $repo" }
    }
    Write-Output ($repo+' '+$revisions[$repo]+' archive SHA256 '+$actual)
}

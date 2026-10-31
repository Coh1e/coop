# Red when: `create` stops guessing the version from the URL or stops printing a manifest skeleton,
# `virustotal` stops refusing to run without an API key, or stops reporting the engine counts it read
# from the service response.
param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test data must stay within the project test directory'
}
$archive = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-archives/ripgrep-15.2.0-x86_64-pc-windows-msvc.zip'))
if (-not (Test-Path -LiteralPath $archive)) { throw "Missing test archive: $archive" }
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower()
$url = 'file:///' + ($archive -replace '\\', '/')
$root = Join-Path $TestRoot 'tools'
if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
New-Item -ItemType Directory -Path "$root/buckets/main/bucket", "$root/vt" -Force | Out-Null
@"
{
  "version": "1.0",
  "url": "$url",
  "hash": "$hash",
  "extract_dir": "ripgrep-15.2.0-x86_64-pc-windows-msvc",
  "bin": "rg.exe"
}
"@ | Set-Content "$root/buckets/main/bucket/demo.json" -Encoding utf8 -NoNewline
'{ "data": { "attributes": { "last_analysis_stats": { "malicious": 2, "suspicious": 1, "harmless": 58, "undetected": 4, "timeout": 0 } } } }' |
    Set-Content "$root/vt/$hash.json" -Encoding utf8

$previousConfigHome = $env:XDG_CONFIG_HOME
$previousApi = $env:COOP_VIRUSTOTAL_API
try {
    $env:XDG_CONFIG_HOME = Join-Path $root 'xdg'
    $env:COOP_VIRUSTOTAL_API = 'file:///' + (($root -replace '\\', '/') + '/vt')

    # create: a manifest skeleton on stdout, version guessed from the file name.
    $lines = @(& $CoopExe create 'https://example.com/tool-1.2.3-win64.zip')
    if ($LASTEXITCODE -cne 0) { throw "create failed: $($lines -join ' | ')" }
    $manifest = ($lines -join "`n") | ConvertFrom-Json
    if ($manifest.version -cne '1.2.3') { throw "create guessed version '$($manifest.version)'" }
    if ($manifest.url -cne 'https://example.com/tool-1.2.3-win64.zip') { throw 'create lost the URL' }
    if ($manifest.hash -cne '') { throw 'create invented a hash' }
    Invoke-CoopNative $CoopExe  create | Out-Null
    if ($LASTEXITCODE -cne 2) { throw "create without a URL exited $LASTEXITCODE" }
    Invoke-CoopNative $CoopExe  create 'not-a-url' | Out-Null
    if ($LASTEXITCODE -cne 1) { throw "create with a bad URL exited $LASTEXITCODE" }

    # virustotal: refuses to run without a key, then reports the counts from the service.
    $refusal = Invoke-CoopNative $CoopExe  --root $root virustotal demo
    if ($LASTEXITCODE -cne 1 -or ($refusal -join '|') -cnotmatch 'API key is not configured') {
        throw "an unconfigured lookup said '$($refusal -join ' | ')'"
    }
    & $CoopExe config virustotal_api_key test-key | Out-Null
    if ($LASTEXITCODE -cne 0) { throw 'config refused the VirusTotal key' }
    $lines = @(& $CoopExe --root $root virustotal demo)
    if ($LASTEXITCODE -cne 0 -or ($lines -join '|') -cnotmatch 'demo: 2 malicious, 1 suspicious out of 65 engines') {
        throw "the lookup said '$($lines -join ' | ')'"
    }
    $lines = @(& $CoopExe --root $root virustotal demo -p)
    $report = ($lines -join "`n") | ConvertFrom-Json
    if ($report[0].engines -cne 65 -or $report[0].malicious -cne 2) { throw 'passthru did not carry the counts' }

    # A package whose manifest publishes no SHA256 cannot be looked up.
    @'
{ "version": "1.0", "url": "https://example.com/plain.exe", "hash": "md5:00000000000000000000000000000000" }
'@ | Set-Content "$root/buckets/main/bucket/plain.json" -Encoding utf8 -NoNewline
    $refusal = Invoke-CoopNative $CoopExe  --root $root virustotal plain
    if ($LASTEXITCODE -cne 1 -or ($refusal -join '|') -cnotmatch 'no SHA256 digest') { throw "a hashless package said '$($refusal -join ' | ')'" }

    # The key may come from the environment for a one-off run, without writing it to the shared config.
    $env:XDG_CONFIG_HOME = Join-Path $root 'xdg-env'
    $env:COOP_VIRUSTOTAL_KEY = 'environment-key'
    $lines = @(& $CoopExe --root $root virustotal demo)
    if ($LASTEXITCODE -cne 0 -or ($lines -join '|') -cnotmatch 'out of 65 engines') {
        throw "an environment key said '$($lines -join ' | ')'"
    }
} finally {
    if ($null -eq $previousConfigHome) { Remove-Item Env:\XDG_CONFIG_HOME -ErrorAction SilentlyContinue }
    else { $env:XDG_CONFIG_HOME = $previousConfigHome }
    if ($null -eq $previousApi) { Remove-Item Env:\COOP_VIRUSTOTAL_API -ErrorAction SilentlyContinue }
    else { $env:COOP_VIRUSTOTAL_API = $previousApi }
}
Write-Output 'PASS: create manifest skeleton and virustotal report parsing'

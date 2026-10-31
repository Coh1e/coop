# Red when: `import` stops registering a missing bucket, stops installing the declared apps through the
# batch path, or stops reporting a `Global install` entry as a refused system-level write.
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
$root = Join-Path $TestRoot 'import'
$source = Join-Path $TestRoot 'import-source'
foreach ($path in $root, $source) { if (Test-Path $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
New-Item -ItemType Directory -Path $root, "$source/bucket" -Force | Out-Null
@"
{
  "version": "1.0",
  "url": "$url",
  "hash": "$hash",
  "extract_dir": "ripgrep-15.2.0-x86_64-pc-windows-msvc",
  "bin": "rg.exe"
}
"@ | Set-Content "$source/bucket/probe.json" -Encoding utf8 -NoNewline
$scoopfile = Join-Path $root 'scoopfile.json'
@{
    buckets = @(@{ Name = 'probe'; Source = $source })
    apps    = @(
        @{ Name = 'probe'; Version = '1.0'; Source = 'probe'; Info = '' },
        @{ Name = 'globalthing'; Version = '1.0'; Source = 'probe'; Info = 'Global install' }
    )
} | ConvertTo-Json -Depth 5 | Set-Content $scoopfile -Encoding utf8

$imported = Invoke-CoopNative $CoopExe  --root $root import $scoopfile
if ($LASTEXITCODE -cne 0) { throw "import failed: $($imported -join ' | ')" }
if ($imported -join "`n" -cnotmatch "was installed successfully") { throw "import did not install the app: $($imported -join ' | ')" }
if ($imported -join "`n" -cnotmatch 'global-scope-readonly') { throw 'import did not refuse the global entry' }

$lines = @(& $CoopExe --root $root list)
if ($lines -join "`n" -cnotmatch 'probe\s+1\.0') { throw "the imported app is missing: $($lines -join ' | ')" }
$buckets = (& $CoopExe --root $root bucket list --json) | ConvertFrom-Json
if (@($buckets | Where-Object name -CEQ 'probe').Count -cne 1) { throw 'import did not register the bucket' }

# Re-importing the same Scoopfile is a no-op for the installed app, not a failure.
$again = Invoke-CoopNative $CoopExe  --root $root import $scoopfile
if ($LASTEXITCODE -cne 0) { throw "a second import failed: $($again -join ' | ')" }
if ($again -join "`n" -cnotmatch 'already installed') { throw "a second import said: $($again -join ' | ')" }
Write-Output 'PASS: import registers buckets, installs apps and refuses global entries'

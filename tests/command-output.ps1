# Red when: bare cache fails, summaries follow tables, missing arguments omit Usage, bucket text
# becomes JSON, detailed help loses examples, or checkup omits helper advice or miscounts warnings.
param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/cache","$root/buckets/main/bucket" -Force | Out-Null
[IO.File]::WriteAllBytes("$root/cache/demo#1.0#1234567.exe",[byte[]]@(1,2,3))
[IO.File]::WriteAllText("$root/buckets/main/bucket/demo.json",'{"version":"1.0"}')
$output = @(& $CoopExe --root $root cache)
if ($LASTEXITCODE -ne 0 -or $output[0] -ne 'Total: 1 file, 3 B' -or $output[1] -notmatch '^Name\s+Version\s+Length') { throw "Bare cache: $output" }
foreach ($command in 'alias','bucket','cat','depends','download','import','install','reset','shim','uninstall','which') {
    $output = Invoke-CoopNative $CoopExe --root $root $command
    $expectedExit = if ($command -eq 'bucket') { 1 } else { 2 }
    if ($LASTEXITCODE -ne $expectedExit -or ($output -join "`n") -notmatch "Usage: coop $command " -or ($output -join "`n") -notmatch 'ERROR ') {
        throw "Missing arguments for ${command}: $output"
    }
}
$output = @(& $CoopExe --root $root bucket list)
if ($LASTEXITCODE -ne 0 -or $output[0] -notmatch '^Name\s+Source\s+Updated\s+Manifests' -or ($output -join "`n") -notmatch 'main\s+.*\s+1\s*$') { throw "Bucket text: $output" }
$json = (& $CoopExe --root $root bucket list --json) -join "`n" | ConvertFrom-Json
if (@($json).Count -ne 1 -or $json[0].name -ne 'main' -or $json[0].kind -ne 'unmanaged') { throw 'Bucket JSON contract changed' }
$help = (& $CoopExe help cache) -join "`n"
if ($help -notmatch 'coop cache rm \*' -or $help -notmatch 'coop cache show') { throw "Cache examples missing: $help" }
$statusHelp = (& $CoopExe help status) -join "`n"
foreach ($pattern in @('installation bucket','official stable release','configured upstream',
    'without fetching or refreshing','--json=2\s+Report clients, buckets and software',
    '--json\s+Return the legacy array of local software findings only',
    '(?m)^  0  Checks completed','(?m)^  1  A check could not be completed','(?m)^  2  Invalid usage')) {
    if ($statusHelp -notmatch $pattern) { throw "Status help missing: $pattern" }
}
if (((& $CoopExe status --help) -join "`n") -cne $statusHelp) { throw 'Status help aliases disagree' }
$help = (& $CoopExe help alias) -join "`n"
if ($help -notmatch 'Available subcommands: add, rm, list' -or $help -notmatch 'coop alias add') { throw 'Alias examples missing' }
function Check-Warnings {
    $lines = @(& $CoopExe --root $root --global-root "$root/global" checkup)
    if ($LASTEXITCODE -ne 0) { throw 'Checkup failed' }
    $warnings = @($lines | Where-Object { $_ -match '^WARN  ' -and $_ -notmatch '^WARN  Found ' })
    $summary = if ($warnings.Count -eq 0) { 'No problems identified!' } elseif ($warnings.Count -eq 1) {
        'WARN  Found 1 potential problem.'
    } else { "WARN  Found $($warnings.Count) potential problems." }
    if ($lines[-1] -ne $summary) { throw "Checkup count: $lines" }
    return $lines -join "`n"
}
$checkup = Check-Warnings
foreach ($advice in "coop install 7zip","coop install innounp","coop install dark","coop install wixtoolset") {
    if (-not $checkup.Contains($advice)) { throw "Missing helper advice: $advice" }
}
# Installed helpers must suppress their own warnings; placeholders are inspected, never executed.
foreach ($path in '7zip/current/7z.exe','innounp/current/innounp.exe','wixtoolset/current/bin/dark.exe') {
    $target = Join-Path "$root/apps" $path
    New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
    [IO.File]::WriteAllBytes($target,[byte[]]@(0))
}
$checkup = Check-Warnings
if ($checkup -match 'coop install (7zip|innounp|dark|wixtoolset)') { throw 'Installed helpers still warned' }
Write-Output 'PASS command output: defaults, usage, help, bucket text/JSON and diagnostic advice'

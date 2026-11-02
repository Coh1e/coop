param(
    [string]$CoopExe = (Join-Path $PSScriptRoot '../.local/build/coop.exe'),
    [string]$ScoopSource = (Join-Path $PSScriptRoot '../.local/scoop-baseline/root/apps/scoop/current'),
    [string]$Output = (Join-Path $PSScriptRoot '../.local/command-output')
)
# Capture both real CLIs, including host/table output, with all writable state in a new local root.
$ErrorActionPreference = 'Stop'
$env:PSModulePath = @([Environment]::GetEnvironmentVariable('PSModulePath','Machine'),[Environment]::GetEnvironmentVariable('PSModulePath','User')) -join ';'
. (Join-Path $PSScriptRoot '../tests/invoke-coop.ps1')
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$Output = [IO.Path]::GetFullPath($Output)
if (-not ($Output.TrimEnd('\')+'\').StartsWith($project+'\.local\',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Output must be below the project .local directory'
}
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$ScoopSource = [IO.Path]::GetFullPath($ScoopSource)
if (-not (Test-Path "$ScoopSource/bin/scoop.ps1")) { throw 'Scoop source with bin/scoop.ps1 is required' }
$run = Join-Path $Output ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run -Force | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
$metadata = [ordered]@{
    coop_sha256 = (Get-FileHash -LiteralPath $CoopExe -Algorithm SHA256).Hash.ToLowerInvariant()
    scoop_source = $ScoopSource
    scoop_core_sha256 = (Get-FileHash -LiteralPath "$ScoopSource/lib/core.ps1" -Algorithm SHA256).Hash.ToLowerInvariant()
    operating_system = [Environment]::OSVersion.VersionString
    runner = $PSVersionTable.PSVersion.ToString()
    environment_boundary = 'Scoop Get-EnvVar/Set-EnvVar persist only to child process in reference copy'
}
[IO.File]::WriteAllText("$run/environment.json",($metadata | ConvertTo-Json -Depth 4),$utf8)
# Keep Scoop's command code intact, but redirect its environment persistence boundary to the
# child process. Scoop Add-Path checks HKCU, not merely the child PATH; an isolated root alone
# does not prevent it from changing the real user's registry. No fixture declares env changes.
$reference = Join-Path $run 'reference'
Copy-Item -LiteralPath $ScoopSource -Destination $reference -Recurse
$systemFile = Join-Path $reference 'lib/system.ps1'
$systemText = [IO.File]::ReadAllText($systemFile)
$systemText = [regex]::Replace($systemText,'(?ms)^function Get-EnvVar \{.*?^}',@'
function Get-EnvVar {
    param([string]$Name,[switch]$Global)
    [Environment]::GetEnvironmentVariable($Name,'Process')
}
'@)
$systemText = [regex]::Replace($systemText,'(?ms)^function Set-EnvVar \{.*?^}',@'
function Set-EnvVar {
    param([string]$Name,[string]$Value,[switch]$Global)
    [Environment]::SetEnvironmentVariable($Name,$Value,'Process')
}
'@)
[IO.File]::WriteAllText($systemFile,$systemText,$utf8)
$wrapper = Join-Path $run 'scoop-entry.ps1'
[IO.File]::WriteAllText($wrapper, @'
param([string]$Source)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
if ($args[0] -eq 'bucket' -and $args[1] -eq 'list') {
    & "$Source/bin/scoop.ps1" @args | Format-Table -AutoSize | Out-String -Width 320 | Write-Host
} else {
    & "$Source/bin/scoop.ps1" @args | Out-Host
}
exit $LASTEXITCODE
'@, $utf8)
$commands = @([regex]::Matches([IO.File]::ReadAllText("$project/src/commands.cpp"), '\{"([a-z]+)",[^\r\n]+,true,true\}') | ForEach-Object { $_.Groups[1].Value })
$results = [Collections.Generic.List[object]]::new()
$pathBefore = [Environment]::GetEnvironmentVariable('Path','User')
$referenceTime = [DateTime]::Now.ToString('o')
function Capture([string]$client,[string]$label,[string[]]$arguments) {
    $root = Join-Path $run "$client-root"
    $arguments = @($arguments | ForEach-Object { $_.Replace('{ROOT}', $root) })
    foreach ($directory in 'apps','cache','shims','buckets/main/bucket','global','xdg/scoop','temp') {
        New-Item -ItemType Directory -Path (Join-Path $root $directory) -Force | Out-Null
    }
    # Register the known buckets locally so Scoop search never falls back to GitHub.
    foreach ($bucket in 'extras','versions','nirsoft','sysinternals','php','nerd-fonts','nonportable','java','games') {
        New-Item -ItemType Directory -Path "$root/buckets/$bucket/bucket" -Force | Out-Null
    }
    $config = "$root/xdg/scoop/config.json"
    if (-not (Test-Path $config)) { [IO.File]::WriteAllText($config,('{"last_update":"'+$referenceTime+'"}'),$utf8) }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $utf8
    $info.StandardErrorEncoding = $utf8
    $info.WorkingDirectory = $root
    # Scoop must see shims on PATH already, otherwise install persists it to the user's PATH.
    $info.EnvironmentVariables['PATH'] = [IO.Path]::GetFullPath("$root/shims") + ';' + $env:PATH
    $info.EnvironmentVariables['PSModulePath'] = @([Environment]::GetEnvironmentVariable('PSModulePath','Machine'),[Environment]::GetEnvironmentVariable('PSModulePath','User')) -join ';'
    foreach ($key in @('SCOOP','SCOOP_GLOBAL','SCOOP_CACHE','XDG_CONFIG_HOME','COOP_STATE_DIR','TEMP','TMP')) {
        $value = switch ($key) {
            'SCOOP' { $root }
            'SCOOP_GLOBAL' { "$root/global" }
            'SCOOP_CACHE' { "$root/cache" }
            'XDG_CONFIG_HOME' { "$root/xdg" }
            'COOP_STATE_DIR' { "$root/state" }
            default { "$root/temp" }
        }
        $info.EnvironmentVariables[$key] = $value
    }
    if ($client -eq 'coop') {
        $info.FileName = $CoopExe
        foreach ($argument in @('--root',$root,'--global-root',"$root/global") + $arguments) { Add-ProcessArgument $info $argument }
    } else {
        $info.FileName = "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe"
        foreach ($argument in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$wrapper,$reference) + $arguments) { Add-ProcessArgument $info $argument }
    }
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(20000)) { $process.Kill(); throw "$client $label timed out" }
    $record = [pscustomobject]@{ client=$client; case=$label; arguments=$arguments; exit=$process.ExitCode
        stdout=$stdout.GetAwaiter().GetResult(); stderr=$stderr.GetAwaiter().GetResult() }
    $process.Dispose()
    [IO.File]::WriteAllText("$run/$label-$client.json",($record | ConvertTo-Json -Depth 6),$utf8)
    $results.Add($record)
}
foreach ($command in $commands) {
    foreach ($client in 'scoop','coop') { Capture $client "$command-help" @('help',$command) }
    # Bare update refreshes buckets; exercise its missing-package path instead of touching a remote.
    $arguments = if ($command -eq 'update') { @('update','coop-output-missing') } elseif ($command -eq 'status') { @('status','-l') } else { @($command) }
    foreach ($client in 'scoop','coop') { Capture $client "$command-bare" $arguments }
    Write-Host "Captured $command"
}
# Seed the same offline package in each root. Neither client needs a live server or helper.
$artifact = "$project/.local/deps/test-archives/jq-1.7.1-windows-amd64.exe"
if (-not (Test-Path $artifact)) { throw "Missing fixture $artifact" }
$hash = (Get-FileHash $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
function Seed([string]$version) {
    $url = "https://example.invalid/coop-output-$version.exe"
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $suffix = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($url)))).Replace('-','').ToLowerInvariant().Substring(0,7) } finally { $sha.Dispose() }
    foreach ($client in 'scoop','coop') {
        $root = Join-Path $run "$client-root"
        $shimDirectory = "$root/apps/scoop/current/supporting/shims/kiennq"
        New-Item -ItemType Directory -Path $shimDirectory -Force | Out-Null
        Copy-Item -LiteralPath "$project/.local/deps/test-fixtures/scoop-shim-kiennq.exe" -Destination "$shimDirectory/shim.exe" -Force
        New-Item -ItemType Directory -Path "$root/tools" -Force | Out-Null
        Copy-Item -LiteralPath $artifact -Destination "$root/tools/output.exe" -Force
        $manifest = [ordered]@{version=$version;description='Command output fixture';homepage='https://example.invalid';license='MIT';url=$url;hash=$hash;bin=@(,@("coop-output-$version.exe",'coop-output'))}
        [IO.File]::WriteAllText("$root/buckets/main/bucket/coop-output.json",($manifest | ConvertTo-Json -Depth 6),$utf8)
        [IO.File]::WriteAllText("$root/buckets/main/bucket/no-home.json",'{"version":"1.0"}',$utf8)
        Copy-Item -LiteralPath $artifact -Destination "$root/cache/coop-output#$version#$suffix.exe"
    }
}
function Pair([string]$label,[string[]]$arguments) {
    foreach ($client in 'scoop','coop') { Capture $client $label $arguments }
    Write-Host "Captured $label"
}
Seed '1.0'
Pair 'cache-populated' @('cache')
Pair 'cache-filter' @('cache','coop-output')
Pair 'bucket-list' @('bucket','list')
Pair 'bucket-known' @('bucket','known')
Pair 'alias-empty' @('alias','list')
Pair 'shim-empty' @('shim','list')
Pair 'shim-add' @('shim','add','custom-output','{ROOT}/tools/output.exe')
Pair 'shim-info' @('shim','info','custom-output')
Pair 'shim-list' @('shim','list')
Pair 'shim-rm' @('shim','rm','custom-output')
Pair 'shim-missing' @('shim','info','custom-output')
Pair 'search-found' @('search','coop-output')
Pair 'search-empty' @('search','^nothing-matches$')
Pair 'cat-found' @('cat','coop-output')
Pair 'info-found' @('info','coop-output')
Pair 'depends-found' @('depends','coop-output')
Pair 'create-invalid' @('create','not-a-url')
Pair 'download-cached' @('download','coop-output','-u')
Pair 'install-cached' @('install','coop-output','-u')
Pair 'install-existing' @('install','coop-output','-u')
Pair 'list-installed' @('list')
Pair 'list-filter-empty' @('list','nothing-matches')
Pair 'prefix-found' @('prefix','coop-output')
Pair 'which-found' @('which','coop-output')
Pair 'status-current' @('status','-l')
Pair 'reset-found' @('reset','coop-output')
Pair 'reset-version' @('reset','coop-output@1.0')
Seed '1.1'
Pair 'status-outdated' @('status','-l')
Pair 'update-cached' @('update','coop-output')
Pair 'cleanup-found' @('cleanup','coop-output')
Pair 'hold-found' @('hold','coop-output')
Pair 'hold-again' @('hold','coop-output')
Pair 'unhold-found' @('unhold','coop-output')
Pair 'export-installed' @('export')
Pair 'uninstall-found' @('uninstall','coop-output')
Pair 'uninstall-missing' @('uninstall','coop-output')
Pair 'cache-remove' @('cache','rm','coop-output')
Pair 'alias-add' @('alias','add','output-test','Write-Output output-test','Output test')
Pair 'alias-list' @('alias','list','-v')
Pair 'alias-rm' @('alias','rm','output-test')
Pair 'config-set' @('config','virustotal_api_key','output-test')
Pair 'config-get' @('config','virustotal_api_key')
Pair 'config-rm' @('config','rm','virustotal_api_key')
foreach ($command in 'cat','depends','info','prefix','which','home','hold','unhold') { Pair "$command-missing" @($command,'coop-output-missing') }
# Import an empty file in each client's working directory; do not launch a browser or call VT.
foreach ($client in 'scoop','coop') {
    [IO.File]::WriteAllText("$run/$client-root/empty.json",'{"buckets":[],"apps":[]}', $utf8)
}
Pair 'import-empty' @('import','empty.json')
Pair 'import-missing' @('import','absent.json')
Pair 'virustotal-no-key' @('virustotal','coop-output')
Pair 'home-no-homepage' @('home','no-home')
# Bucket lifecycle against a local Git repository, never the live user's buckets or network.
$repository = Join-Path $run 'fixture-bucket'
New-Item -ItemType Directory -Path "$repository/bucket" -Force | Out-Null
[IO.File]::WriteAllText("$repository/bucket/output.json",'{"version":"1.0"}',$utf8)
$git = (Get-Command git.exe -ErrorAction Stop).Source
Invoke-CoopNative $git init --initial-branch=master $repository | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize bucket fixture' }
Invoke-CoopNative $git -C $repository add bucket | Out-Null
Invoke-CoopNative $git -C $repository -c user.name=OutputTest -c user.email=output@example.invalid -c core.hooksPath=$run commit -m fixture | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot commit bucket fixture' }
$url = ([uri]($repository.Replace('\','/')+'/')).AbsoluteUri
Pair 'bucket-add' @('bucket','add','output-test',$url)
Pair 'bucket-update' @('bucket','update','output-test')
Pair 'bucket-rm' @('bucket','rm','output-test')
[IO.File]::WriteAllText("$run/results.json",(ConvertTo-Json -InputObject @($results.ToArray()) -Depth 8),$utf8)
if ([Environment]::GetEnvironmentVariable('Path','User') -cne $pathBefore) { throw 'The acceptance run changed user PATH' }
Write-Output "Evidence: $run"
& (Join-Path $PSScriptRoot 'check-command-output.ps1') -Evidence $run

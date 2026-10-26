param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$GuardExe,
      [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$projectTests = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($projectTests,[StringComparison]::OrdinalIgnoreCase)) { throw 'Live tests must stay in project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$GuardExe = [IO.Path]::GetFullPath($GuardExe)
$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$script:childNumber = 0
function Invoke-Child([string]$File, [string[]]$Arguments, [hashtable]$EnvironmentOverrides = @{}) {
    $start = [Diagnostics.ProcessStartInfo]::new($File)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    foreach ($key in $EnvironmentOverrides.Keys) { $start.Environment[$key] = $EnvironmentOverrides[$key] }
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(120000)) { $process.Kill($true); throw 'Live test process timed out' }
    $result = @{ exit=$process.ExitCode; output=$stdout.GetAwaiter().GetResult(); error=$stderr.GetAwaiter().GetResult() }
    ++$script:childNumber
    $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root ('child-{0:d2}.json' -f $script:childNumber)) -Encoding utf8
    return $result
}
# PATH is changed only for these test children: the CLI cannot find git.exe.
$isolatedPath = @{ PATH=(Join-Path $env:SystemRoot 'System32'); COOP_PROCESS_GUARD_TIMEOUT_MS='90000' }
$clone = Invoke-Child $GuardExe @($CoopExe,'--root',$root,'bucket','add','main','https://github.com/ScoopInstaller/Main','--branch','master','--json') $isolatedPath
if ($clone.exit -ne 0 -or $clone.error -notmatch 'Observed workload processes: 1') { throw ('No-Git HTTPS clone failed: '+$clone.error) }
$main = (Get-Content -LiteralPath "$root/.coop/buckets.json" -Raw | ConvertFrom-Json)[0]
if ($main.branch -ne 'master' -or $main.refresh_kind -ne 'first' -or $main.path -ne (Join-Path $root 'buckets/main') -or -not (Test-Path -LiteralPath (Join-Path $main.path '.git'))) { throw 'Branch or shared working tree missing' }
$firstRevision = $main.revision
$query = Invoke-Child $CoopExe @('--root',$root,'info','main/jq','--json') $isolatedPath
if ($query.exit -ne 0) { throw 'Downloaded Main cannot be queried' }
$update = Invoke-Child $GuardExe @($CoopExe,'--root',$root,'bucket','update','main','--json') $isolatedPath
if ($update.exit -ne 0 -or $update.error -notmatch 'Observed workload processes: 1') { throw ('No-Git HTTPS refresh failed: '+$update.error+' '+$update.output) }
$second = (Get-Content -LiteralPath "$root/.coop/buckets.json" -Raw | ConvertFrom-Json)[0]
if ($second.revision -ne $firstRevision -or $second.path -ne $main.path -or $second.changed -ne $false -or $second.refresh_kind -ne 'unchanged') { throw 'Unchanged shared revision was republished' }
$gitlab = Invoke-Child $CoopExe @('--root',$root,'bucket','add','gitlab','https://gitlab.com/gitlab-examples/cpp-example.git','--json') $isolatedPath
if ($gitlab.exit -ne 0) { throw ('Non-GitHub HTTPS clone failed: '+$gitlab.error) }
$gitlabRecord = ($gitlab.output | ConvertFrom-Json)
$registryHash = (Get-FileHash -LiteralPath "$root/.coop/buckets.json").Hash
$proxyEnvironment = @{ PATH=$isolatedPath.PATH; HTTPS_PROXY='http://127.0.0.1:9'; NO_PROXY='' }
$failed = Invoke-Child $CoopExe @('--root',$root,'bucket','update','main','--json') $proxyEnvironment
if ($failed.exit -eq 0) { throw 'Unreachable proxy was ignored' }
if ((Get-FileHash -LiteralPath "$root/.coop/buckets.json").Hash -ne $registryHash) { throw 'Failed proxy refresh changed published state' }
$query = Invoke-Child $CoopExe @('--root',$root,'info','main/jq','--json') $isolatedPath
if ($query.exit -ne 0) { throw 'Shared bucket unavailable after failed proxy' }
$tls = Invoke-Child $CoopExe @('--root',$root,'bucket','add','untrusted','https://self-signed.badssl.com/','--json') $isolatedPath
if ($tls.exit -eq 0 -or $tls.error -notmatch 'certificate|证书') { throw ('Certificate rejection was not verified: '+$tls.error) }
$report = [ordered]@{
    timestamp=[DateTime]::UtcNow.ToString('o'); root=$root
    github_revision=$main.revision; github_object_payload_bytes=$main.received_bytes
    refresh_revision=$second.revision; refresh_object_payload_bytes=$second.received_bytes
    refresh_changed=$second.changed; refresh_kind=$second.refresh_kind; gitlab_revision=$gitlabRecord.revision
    gitlab_object_payload_bytes=$gitlabRecord.received_bytes; gitlab_shared_path=$gitlabRecord.path
    no_git_processes=$true; proxy_failure_exit=$failed.exit; invalid_certificate_exit=$tls.exit
    executable_sha256=(Get-FileHash -LiteralPath $CoopExe -Algorithm SHA256).Hash.ToLower()
}
$report | ConvertTo-Json | Set-Content -LiteralPath "$root/evidence.json" -Encoding utf8
Write-Output ('PASS live HTTPS + process observation + proxy + invalid certificate; evidence: '+$root+'/evidence.json')

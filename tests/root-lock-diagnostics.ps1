# Red when: a failed root lock omits the Windows error code or the actual lock path.
param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$projectTests = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($projectTests,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
# Every run owns fresh fixtures. Leave them intact; never delete an existing lock.
$run = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
$root = Join-Path $run 'root'
$savedState = $env:COOP_STATE_DIR
$savedProfile = $env:USERPROFILE
try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    foreach ($case in @('sharing','directory')) {
        $env:COOP_STATE_DIR = Join-Path $run ("state space-"+$case)
        New-Item -ItemType Directory -Path $env:COOP_STATE_DIR -Force | Out-Null
        $lockPath = Join-Path $env:COOP_STATE_DIR 'write.lock'
        $held = $null
        try {
            if ($case -eq 'sharing') {
                $held = [IO.File]::Open($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
                $expectedCode = 32
            } else {
                New-Item -ItemType Directory -Path $lockPath | Out-Null
                $expectedCode = 5
            }
            $result = Invoke-CoopNativeRaw $CoopExe --root $root bucket update diagnostic-fixture
            if ($result.code -eq 0 -or $result.err -notmatch "Windows error $expectedCode" -or
                -not $result.err.Contains($lockPath)) {
                throw "Missing lock diagnostics ($case): $($result.err)"
            }
            if (-not (Test-Path -LiteralPath $lockPath)) { throw 'Failed acquisition removed the lock fixture' }
            Write-Output ("PASS "+$case+": "+$result.err.Trim())
        } finally {
            if ($null -ne $held) { $held.Dispose() }
        }
    }
    $env:COOP_STATE_DIR = $null
    $env:USERPROFILE = $run
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($root))
        $suffix = [BitConverter]::ToString($bytes).Replace('-','').Substring(0,8).ToLowerInvariant()
    } finally {
        $hash.Dispose()
    }
    $legacy = Join-Path $run ".coop/roots/root-$suffix"
    New-Item -ItemType Directory -Path $legacy | Out-Null
    $held = [IO.File]::Open((Join-Path $legacy 'write.lock'),'CreateNew','ReadWrite','None')
    try {
        $result = Invoke-CoopNativeRaw $CoopExe --root $root.ToUpperInvariant() bucket update diagnostic-fixture
        if ($result.code -eq 0 -or $result.err -notmatch 'Windows error 32') {
            throw "Root spelling bypassed the existing lock: $($result.err)"
        }
    } finally {
        $held.Dispose()
    }
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToUpperInvariant()))
        $suffix = [BitConverter]::ToString($bytes).Replace('-','').Substring(0,8).ToLowerInvariant()
    } finally {
        $hash.Dispose()
    }
    $split = Join-Path $run ".coop/roots/ROOT-$suffix"
    New-Item -ItemType Directory -Path $split | Out-Null
    foreach ($spelling in $root,$root.ToUpperInvariant()) {
        $result = Invoke-CoopNativeRaw $CoopExe --root $spelling bucket update diagnostic-fixture
        if ($result.code -eq 0 -or $result.err -notmatch 'Conflicting Coop state directories') {
            throw "Split historical state did not block the write: $($result.err)"
        }
    }
} finally {
    $env:USERPROFILE = $savedProfile
    $env:COOP_STATE_DIR = $savedState
}

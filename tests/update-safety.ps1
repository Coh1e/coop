# Red when: update previews or rejected arguments refresh a bucket, migrate legacy state,
# write a run/transaction record, or silently discard options in bare/wildcard dispatch.
param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test data must stay within the project test directory'
}
$session = Join-Path $TestRoot ([Guid]::NewGuid().ToString('N'))
$source = Join-Path $session 'source'
New-Item -ItemType Directory -Force -Path "$source/bucket" | Out-Null
'{"version":"1"}' | Set-Content "$source/bucket/demo.json" -Encoding ascii
& git init -q -b main $source
& git -C $source add .
& git -C $source -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m initial
if ($LASTEXITCODE -ne 0) { throw 'Cannot create local Git source' }
$initial = & git -C $source rev-parse HEAD
'{"version":"2"}' | Set-Content "$source/bucket/demo.json" -Encoding ascii
& git -C $source add .
& git -C $source -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m newer
if ($LASTEXITCODE -ne 0) { throw 'Cannot advance local Git source' }
function Snapshot([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '<absent>' }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $rows = foreach ($item in Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object FullName) {
            $name = $item.FullName.Substring($Path.Length)
            if ($item.PSIsContainer) { 'D ' + $name; continue }
            $stream = [IO.File]::OpenRead($item.FullName)
            try { $hash = [BitConverter]::ToString($hasher.ComputeHash($stream)) } finally { $stream.Dispose() }
            'F ' + $name + ' ' + $hash + ' ' + $item.LastWriteTimeUtc.Ticks
        }
        return $rows -join "`n"
    } finally { $hasher.Dispose() }
}
$cases = @(
    @{name='minimal-preview'; args=@('--dry-run'); code=1; noBucket=$true},
    @{name='bare-preview'; args=@('--dry-run'); code=1},
    @{name='bare-unknown'; args=@('--bogus'); code=2},
    @{name='named-unknown'; args=@('demo','--bogus'); code=2},
    @{name='empty-all-unknown'; args=@('*','--bogus'); code=2},
    @{name='named-preview'; args=@('missing','--dry-run'); code=1},
    @{name='bare-global'; args=@('--global'); code=1},
    @{name='named-global'; args=@('demo','-g'); code=1},
    @{name='bare-purge'; args=@('--purge'); code=2},
    @{name='named-purge'; args=@('demo','--purge'); code=2},
    @{name='duplicate-preview'; args=@('--dry-run','--dry-run'); code=2},
    @{name='preview-without-legacy'; args=@('missing','--dry-run'); code=1; noLegacy=$true},
    @{name='unknown-without-legacy'; args=@('demo','--bogus'); code=2; noLegacy=$true}
)
$cases += @(
    @{name='bare-short-unknown'; args=@('-z'); code=2},
    @{name='named-short-unknown'; args=@('demo','-z'); code=2},
    @{name='bare-package-option'; args=@('--force'); code=2},
    @{name='empty-package'; args=@(''); code=2},
    @{name='mixed-all'; args=@('demo','*'); code=2},
    @{name='manifest-url-preview'; args=@(('file:///' + ("$source/bucket/demo.json" -replace '\\','/')),'--dry-run'); code=1; noLegacy=$true},
    @{name='invalid-before-run-record'; args=@('demo','--bogus'); code=2; noLegacy=$true; stateFile=$true},
    @{name='missing-root'; args=@('--root'); code=2},
    @{name='missing-architecture'; args=@('demo','--arch'); code=2},
    @{name='installed-preview'; args=@('demo','--dry-run'); code=0; installed=$true},
    @{name='installed-json-preview'; args=@('demo','--dry-run','--json'); code=0; installed=$true},
    @{name='empty-all-preview'; args=@('*','--dry-run'); code=0},
    @{name='missing-version'; args=@('demo@'); code=2; noBucket=$true},
    @{name='missing-source-name'; args=@('main/'); code=2; noBucket=$true},
    @{name='unsafe-selector'; args=@('../demo'); code=2; noBucket=$true},
    @{name='root-value-is-preview'; args=@('--root','--dry-run','--root','{root}'); code=2},
    @{name='global-root-value-is-preview'; args=@('--global-root','--dry-run','--global-root','{root}'); code=2},
    @{name='literal-root-value'; args=@('--root=--dry-run','--root','{root}','--dry-run'); code=1},
    @{name='installed-preview-before-run-record'; args=@('demo','--dry-run'); code=0; installed=$true; stateFile=$true; noLegacy=$true}
)
$savedState = $env:COOP_STATE_DIR
$failures = @()
try {
    foreach ($case in $cases) {
        $caseDirectory = Join-Path $session $case.name
        $root = Join-Path $caseDirectory 'root'
        $state = Join-Path $caseDirectory 'state'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        if ($case.stateFile) { 'state-path-is-a-file' | Set-Content $state -Encoding ascii }
        if (-not $case.noLegacy) {
            New-Item -ItemType Directory -Force -Path "$root/.coop" | Out-Null
            'legacy-state-must-stay' | Set-Content "$root/.coop/sentinel" -Encoding ascii
        }
        if (-not $case.noBucket -and -not $case.installed) {
            New-Item -ItemType Directory -Force -Path "$root/buckets" | Out-Null
            & git clone -q $source "$root/buckets/main"
            & git -C "$root/buckets/main" reset -q --hard $initial
            if ($LASTEXITCODE -ne 0) { throw 'Cannot prepare local bucket' }
        }
        if ($case.installed) {
            New-Item -ItemType Directory -Force -Path "$root/buckets/main/bucket" | Out-Null
            Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$root/buckets/main/bucket/demo.json"
            New-Item -ItemType Directory -Force -Path "$root/apps/demo/1.7.1" | Out-Null
            $savedManifest = [IO.File]::ReadAllText("$PSScriptRoot/corpus/main/jq.json").Replace('"version": "1.8.2"','"version": "1.7.1"')
            [IO.File]::WriteAllText("$root/apps/demo/1.7.1/scoop-manifest.json",$savedManifest)
            '{"bucket":"main","architecture":"64bit"}' | Set-Content "$root/apps/demo/1.7.1/scoop-install.json" -Encoding ascii
            New-Item -ItemType Junction -Path "$root/apps/demo/current" -Target "$root/apps/demo/1.7.1" | Out-Null
        }
        $env:COOP_STATE_DIR = $state
        $beforeRoot = Snapshot $root
        $beforeState = Snapshot $state
        $caseArguments = @($case.args | ForEach-Object { if ($_ -ceq '{root}') { $root } else { $_ } })
        $invocation = @('--root',$root,'update') + $caseArguments
        $result = Invoke-CoopNativeRaw -Exe $CoopExe -Arguments $invocation
        $afterRoot = Snapshot $root
        $afterState = Snapshot $state
        $changed = $beforeRoot -cne $afterRoot -or $beforeState -cne $afterState
        if ($case.installed -and $result.code -eq 0 -and $result.out -notmatch 'demo') { throw 'Installed preview did not describe the requested package' }
        if ($case.name -eq 'installed-json-preview' -and $result.code -eq 0) { $null = $result.out | ConvertFrom-Json }
        if ($result.code -ne $case.code -or $changed) {
            $message = '{0}: exit {1} (expected {2}), state_changed={3}; {4} {5}' -f $case.name,$result.code,$case.code,$changed,$result.out.Trim(),$result.err.Trim()
            $failures += $message
            Write-Output ('FAIL ' + $message)
        } else { Write-Output ('PASS ' + $case.name) }
    }
} finally { $env:COOP_STATE_DIR = $savedState }
if ($failures.Count) { throw "$($failures.Count) unsafe update cases; evidence: $session" }
Write-Output 'PASS update preview/argument safety with unchanged shared Git, installation and external state'

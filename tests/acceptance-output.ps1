param([Parameter(Mandatory)][string]$TestRoot)
# Red when: an acceptance script overwrites or accepts an existing output directory.
$ErrorActionPreference = 'Stop'
$testDirectory = Join-Path $TestRoot ([Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $testDirectory -Force | Out-Null
try {
    $shim = Join-Path $testDirectory 'scoop.ps1'
    Set-Content -LiteralPath $shim -Value 'throw "Unexpected Scoop invocation"'
    $scripts = Join-Path $PSScriptRoot '../scripts'
    foreach ($name in 'scoop-baseline', 'perf-compare', 'acceptance-matrix') {
        $output = Join-Path $testDirectory "$name output"
        New-Item -ItemType Directory -Path $output | Out-Null
        $sentinel = Join-Path $output 'keep.txt'
        Set-Content -LiteralPath $sentinel -Value 'caller data'
        $arguments = @{ Output = $output }
        if ($name -ne 'acceptance-matrix') { $arguments.ScoopShim = $shim }
        if ($name -ne 'scoop-baseline') { $arguments.CoopExe = $shim }
        $failure = $null
        try {
            & (Join-Path $scripts "$name.ps1") @arguments
        } catch {
            $failure = $_
        }
        if (!(Test-Path -LiteralPath $sentinel -PathType Leaf) -or
            (Get-Content -LiteralPath $sentinel) -cne 'caller data') {
            throw "$name changed or removed caller data"
        }
        if (!$failure -or $failure.Exception.Message -notlike 'Output path already exists:*') {
            throw "$name did not reject the existing output path: $failure"
        }
    }
} finally {
    Remove-Item -LiteralPath $testDirectory -Recurse -Force
}

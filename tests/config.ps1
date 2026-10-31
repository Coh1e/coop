# Red when: `config` stops refusing keys Coop does not manage, `alias add` stops writing Scoop's
# `scoop-<name>.ps1` and the ALIAS entry, `coop <alias>` stops running that script, or `alias rm`
# stops removing both the entry and the script.
param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test data must stay within the project test directory'
}
$root = Join-Path $TestRoot 'config'
if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
New-Item -ItemType Directory -Path "$root/shims" -Force | Out-Null
$previousConfigHome = $env:XDG_CONFIG_HOME
try {
    $env:XDG_CONFIG_HOME = Join-Path $root 'xdg'

    $lines = @(& $CoopExe config)
    if ($LASTEXITCODE -cne 0 -or ($lines -join "`n") -cnotmatch 'The Scoop configuration is empty') {
        throw "an empty config said '$($lines -join ' | ')'"
    }

    $lines = @(& $CoopExe --root $root alias add greet 'Write-Output hello-from-alias' 'greets the user')
    if ($LASTEXITCODE -cne 0 -or ($lines -join "`n") -cnotmatch "Alias 'greet' added") { throw "alias add said '$($lines -join ' | ')'" }
    $scriptPath = Join-Path $root 'shims/scoop-greet.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) { throw 'alias add did not write the Scoop subcommand script' }
    $script = Get-Content -LiteralPath $scriptPath -Raw
    if ($script -cnotmatch '@Summary: greets the user' -and $script -cnotmatch '# Summary: greets the user') {
        throw "the alias script has no summary line: $script"
    }

    $lines = @(& $CoopExe --root $root alias list)
    if ($lines[0] -cnotmatch '^Name\s+Command\s*$') { throw "alias list header is '$($lines[0])'" }
    if (($lines -join "`n") -cnotmatch 'greet\s+Write-Output hello-from-alias') { throw "alias list rows are '$($lines -join ' | ')'" }
    $lines = @(& $CoopExe --root $root alias list -v)
    if ($lines[0] -cnotmatch '^Name\s+Command\s+Summary\s*$') { throw "alias list -v header is '$($lines[0])'" }

    # The alias is a real subcommand: `coop greet` runs the generated script.
    $lines = @(& $CoopExe --root $root greet)
    if ($LASTEXITCODE -cne 0 -or ($lines -join '|') -cnotmatch 'hello-from-alias') { throw "running the alias said '$($lines -join ' | ')'" }

    # config sees the shared ALIAS entry and refuses to write a key it does not implement.
    $lines = @(& $CoopExe config)
    if (($lines -join "`n") -cnotmatch 'ALIAS') { throw "config did not show the ALIAS entry: $($lines -join ' | ')" }
    $refusal = Invoke-CoopNative $CoopExe  config root_path 'D:\elsewhere'
    if ($LASTEXITCODE -cne 1 -or ($refusal -join '|') -cnotmatch 'not managed by Coop') { throw "config refused with '$($refusal -join ' | ')'" }

    $lines = @(& $CoopExe --root $root alias rm greet)
    if ($LASTEXITCODE -cne 0 -or ($lines -join "`n") -cnotmatch "Removing alias 'greet'") { throw "alias rm said '$($lines -join ' | ')'" }
    if (Test-Path -LiteralPath $scriptPath) { throw 'alias rm left the script behind' }
    $lines = @(& $CoopExe --root $root alias list)
    if (($lines -join "`n") -cnotmatch 'No alias found') { throw "alias list after rm said '$($lines -join ' | ')'" }
} finally {
    if ($null -eq $previousConfigHome) { Remove-Item Env:\XDG_CONFIG_HOME -ErrorAction SilentlyContinue }
    else { $env:XDG_CONFIG_HOME = $previousConfigHome }
}
Write-Output 'PASS: config ownership, alias add/list/run/rm and the generated subcommand'

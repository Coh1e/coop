param(
    [Parameter(Mandatory)][ValidateSet('snapshot','compare')][string]$Mode,
    [Parameter(Mandatory)][string]$Path
)
# Companion for tests that temporarily change the real current-user environment. It only reads
# HKCU\Environment; it never writes or broadcasts. Use snapshot before a full suite and compare
# afterwards to prove that every test restored Path and all variable values/kinds.
$ErrorActionPreference = 'Stop'
$Path = [IO.Path]::GetFullPath($Path)
function Read-UserEnvironment {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    if ($null -eq $key) { throw 'HKCU\Environment is missing' }
    try {
        $pathValue = [string]$key.GetValue('Path',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $pathKind = $key.GetValueKind('Path').ToString()
        $variables = @()
        foreach ($name in @($key.GetValueNames() | Where-Object { -not [string]::Equals($_,'Path',[StringComparison]::OrdinalIgnoreCase) } | Sort-Object)) {
            $variables += [pscustomobject]@{
                name = [string]$name
                kind = $key.GetValueKind($name).ToString()
                value = [string]$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
        }
        return [pscustomobject]@{path=$pathValue;path_kind=$pathKind;variables=@($variables)}
    } finally { $key.Dispose() }
}
if ($Mode -eq 'snapshot') {
    $snapshot = Read-UserEnvironment
    $snapshot | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding utf8
    Write-Output "snapshot variables=$(@($snapshot.variables).Count) path_kind=$($snapshot.path_kind)"
    exit 0
}
$baseline = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
$current = Read-UserEnvironment
$differences = [System.Collections.Generic.List[string]]::new()
if ($current.path -cne $baseline.path) { $differences.Add('Path value changed') }
if ($current.path_kind -ne $baseline.path_kind) { $differences.Add('Path kind changed') }
$before = @{}
foreach ($item in @($baseline.variables)) { $before[$item.name.ToLowerInvariant()] = $item }
$after = @{}
foreach ($item in @($current.variables)) { $after[$item.name.ToLowerInvariant()] = $item }
foreach ($name in @($before.Keys | Sort-Object)) {
    if (-not $after.ContainsKey($name)) { $differences.Add("$name removed"); continue }
    if ($before[$name].value -cne $after[$name].value) { $differences.Add("$name value changed") }
    if ($before[$name].kind -ne $after[$name].kind) { $differences.Add("$name kind changed") }
}
foreach ($name in @($after.Keys | Sort-Object)) {
    if (-not $before.ContainsKey($name)) { $differences.Add("$name added") }
}
$result = [pscustomobject]@{
    path_unchanged = ($current.path -ceq $baseline.path -and $current.path_kind -eq $baseline.path_kind)
    path_kind = $current.path_kind
    variable_count = @($current.variables).Count
    differences = @($differences)
    coop_test_path_entries = @((($current.path -split ';') | Where-Object { $_ -match 'coop-r08|envapp|exposure|coop-r08v' }))
}
$result | ConvertTo-Json -Depth 5
if ($differences.Count -gt 0) { exit 1 }
exit 0

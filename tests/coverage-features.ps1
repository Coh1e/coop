$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-coop.ps1')
. (Join-Path $PSScriptRoot 'coverage-manifest-features.ps1')

# Command entries may contain spaces and quoted paths. The structural census must keep the
# whole target; treating whitespace as an argument separator invented unsupported host types.
# Parse the fixtures from JSON so nested bin tuples keep the shape a Manifest file has.
$cases = @(
    @{ name = 'space-exe'; json = '{"bin":"Plex Media Server.exe"}'; expected = 'command.exe'; forbidden = 'command.no-extension' },
    @{ name = 'space-bat'; json = '{"bin":"Puppet Labs\\Puppet\\bin\\facter.bat"}'; expected = 'command.bat'; forbidden = 'command.no-extension' },
    @{ name = 'bare-script'; json = '{"bin":"git-filter-repo"}'; expected = 'command.no-extension'; forbidden = $null },
    @{ name = 'python-script'; json = '{"bin":"vsrepo.py"}'; expected = 'command.py'; forbidden = 'command.no-extension' },
    @{ name = 'config-script'; json = '{"bin":[["bin\\tool.config","tool"]]}'; expected = 'command.config'; forbidden = 'command.no-extension' },
    @{ name = 'quoted-exe'; json = '{"bin":"\"C:\\Program Files\\Tool\\app.exe\""}'; expected = 'command.exe'; forbidden = 'command.no-extension' },
    @{ name = 'tuple-path'; json = '{"bin":[["C:\\Program Files\\Tool\\run.bat","--quiet"]]}'; expected = 'command.bat'; forbidden = 'command.no-extension' },
    @{ name = 'architecture-ps1'; json = '{"architecture":{"64bit":{"bin":"scripts/tool.ps1"}}}'; expected = 'command.ps1'; forbidden = 'command.no-extension' }
)
$failures = [System.Collections.Generic.List[string]]::new()
foreach ($case in $cases) {
    $manifest = ConvertTo-Hashtable ($case.json | ConvertFrom-Json)
    $features = @(Read-ManifestFeatures $manifest)
    if ($features -notcontains $case.expected) { $failures.Add("$($case.name): missing $($case.expected) in $($features -join ',')") }
    if ($case.forbidden -and $features -contains $case.forbidden) { $failures.Add("$($case.name): unexpected $($case.forbidden)") }
}
if ($failures.Count) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}
Write-Output ("PASS coverage feature census: {0} command-host cases" -f $cases.Count)

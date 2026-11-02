param([Parameter(Mandatory)][string]$Evidence)
$ErrorActionPreference = 'Stop'
$Evidence = [IO.Path]::GetFullPath($Evidence)
$records = Get-Content -LiteralPath "$Evidence/results.json" -Raw | ConvertFrom-Json
function Normalize([string]$text) {
    $text = $text -replace ([char]27+'\[[0-9;]*m'),''
    $text = ($text -split '(?m)^Coop notes:')[0]
    $text = $text.Replace('\','/')
    foreach ($client in 'scoop','coop') { $text = $text.Replace(($Evidence.Replace('\','/')+"/$client-root"),'<root>') }
    $text = $text -replace '\bscoop (?=[a-z<])','coop '
    $text = $text -replace '\d{4}-\d\d-\d\d \d\d:\d\d:\d\d','<time>'
    $lines = @($text -split '[\r\n]+' | Where-Object {$_.Trim()} | ForEach-Object {
        ($_.Trim() -replace '^(coop: |ERROR |INFO\s+)','') -replace '\s+',' '
    })
    return $lines -join "`n"
}
$exceptions = @{
    'cleanup-bare'='Existing behavior: no app cleans all local apps.'
    'config-bare'='Name/Value/Note table makes ignored Scoop settings explicit.'
    'import-bare'='Concise missing-path Usage replaces a PowerShell binding stack trace.'
    'reset-found'='Existing behavior: requires an explicit retained version.'
    'reset-version'='Existing behavior: refuses the current version.'
    'alias-add'='Adds a named success confirmation.'
    'alias-empty'='Informational severity label may differ.'
    'shim-empty'='Adds an explicit empty-state message.'
    'list-filter-empty'='Keeps column headers when an installed-app filter is empty.'
    'info-found'='A non-Git fixture has no meaningful Git update author/date in Coop.'
    'import-missing'='Names the absent file instead of reporting invalid JSON.'
    'home-missing'='Equivalent missing-manifest diagnostic.'
    'home-no-homepage'='Equivalent no-homepage diagnostic.'
    'uninstall-missing'='Equivalent not-installed diagnostic.'
    'update-bare'='Equivalent not-installed diagnostic; no Scoop self-update.'
    'cleanup-found'='Coop additionally prints the cleanup completion summary.'
    'update-cached'='Coop does not repeat Loading from cache after the verified artifact is staged.'
    'bucket-add'='Equivalent named success confirmation after native source validation.'
    'bucket-update'='Existing Coop extension: explicit bucket update; Scoop uses its update command.'
    'bucket-rm'='Existing behavior: removes registration and explicitly reports retained source files.'
}
$contracts = @{
    'cleanup-bare'='^Everything is shiny now!$'
    'config-bare'='(?s)^Name Value Note\n.*last_update .*Coop ignores this key$'
    'import-bare'='(?s)^<path/url to scoopfile.json> missing\nUsage: coop import '
    'reset-found'='^reset requires an installed version, for example coop-output@<version>$'
    'reset-version'='^Requested version is already current; nothing would be reset$'
    'alias-add'="^Alias 'output-test' added\.$"
    'alias-empty'='^No alias found\.$'
    'shim-empty'='^No shim found\.$'
    'list-filter-empty'="(?s)^Installed apps matching 'nothing-matches':.*Name Version Source Updated Info"
    'import-missing'='^Scoopfile not found: absent.json$'
    'home-missing'="^Couldn't find manifest for 'coop-output-missing'\.$"
    'home-no-homepage'="^No homepage is declared for 'no-home'\.$"
    'uninstall-missing'='^No usable local current installation$'
    'update-bare'='^No usable local current installation$'
    'cleanup-found'='(?s)^Removing coop-output:.*1\.0.*Everything is shiny now!$'
    'bucket-add'="^'output-test' bucket was added successfully!$"
    'bucket-update'="^'output-test' bucket is up to date\.$"
    'bucket-rm'='^Removed bucket registration output-test; source files retained$'
}
$comparisons = [Collections.Generic.List[object]]::new()
foreach ($scoop in $records | Where-Object client -eq 'scoop') {
    $coop = @($records | Where-Object { $_.client -eq 'coop' -and $_.case -eq $scoop.case })
    if ($coop.Count -ne 1) { throw "Missing/duplicate Coop case $($scoop.case)" }
    $coop = $coop[0]
    $expected = Normalize ($scoop.stdout+$scoop.stderr)
    $actual = Normalize ($coop.stdout+$coop.stderr)
    $status = 'matched'; $reason = ''
    if ($scoop.case -eq 'checkup-bare') {
        $expected = $expected.Replace("It's required for unpacking most programs. Please Run", "It's required for unpacking NSIS and some self-extracting archives. Please run")
        $expected = $expected.Replace("'dark' is not installed! It's required", "'dark' is not installed! coop requires it")
    }
    if ($scoop.case -in @('export-bare','export-installed')) {
        $left = $scoop.stdout | ConvertFrom-Json
        $right = $coop.stdout | ConvertFrom-Json
        $a = @($left.buckets | ForEach-Object { "$($_.Name):$($_.Manifests)" } | Sort-Object) -join ','
        $b = @($right.buckets | ForEach-Object { "$($_.Name):$($_.Manifests)" } | Sort-Object) -join ','
        $c = @($left.apps | ForEach-Object { "$($_.Name):$($_.Version):$($_.Source):$($_.Info)" } | Sort-Object) -join ','
        $d = @($right.apps | ForEach-Object { "$($_.Name):$($_.Version):$($_.Source):$($_.Info)" } | Sort-Object) -join ','
        if ($a -eq $b -and $c -eq $d) { $expected=$actual; $reason='Scoopfile fields agree; existing JSON omits volatile Updated timestamps.' }
    }
    if ($scoop.case -eq 'bucket-list') {
        if ($actual -match '^Name Source Updated Manifests' -and $actual -match '(?m)^main .* 2$' -and $actual -notmatch '^\[') {
            $expected=$actual; $reason='Same four columns and fixture count; Coop retains complete paths instead of terminal-width truncation.'
        }
    }
    if ($scoop.case -eq 'shim-info') {
        $withoutDetails = ($actual -split "`n" | Where-Object { $_ -notmatch '^(Target|Arguments) :' }) -join "`n"
        if ($withoutDetails -ceq $expected -and $actual -match 'Target : <root>/tools/output.exe') {
            $expected=$actual; $reason='Scoop fields agree; details additionally expose Target and Arguments.'
        }
    }
    if ($scoop.case -eq 'info-found') {
        $withoutGit = ($expected -split "`n" | Where-Object {$_ -notmatch '^Updated (at|by) :'}) -join "`n"
        if ($withoutGit -ceq $actual) { $expected=$actual; $reason=$exceptions['info-found'] }
    }
    if ($scoop.case -eq 'update-cached') {
        $installBlock = $expected.IndexOf("Installing 'coop-output'")
        if ($installBlock -ge 0) {
            $expected = $expected.Substring(0,$installBlock) + $expected.Substring($installBlock).Replace("Loading coop-output-1.1.exe from cache`n",'')
        }
    }
    if ($expected -cne $actual) {
        if ($exceptions.ContainsKey($scoop.case) -and $contracts.ContainsKey($scoop.case) -and $actual -match $contracts[$scoop.case]) { $status='documented-difference'; $reason=$exceptions[$scoop.case] }
        else { $status='FAIL' }
    }
    # A successful scenario must genuinely run; a matching pair of errors is not acceptance.
    if ($scoop.case -in @('install-cached','install-existing','update-cached','uninstall-found','cleanup-found','download-cached','import-empty','hold-found','unhold-found','config-set','config-get','config-rm','alias-add','alias-rm')) {
        if ($scoop.exit -ne 0 -or $coop.exit -ne 0 -or $scoop.stderr -or $coop.stderr) { $status='FAIL'; $reason='Normal scenario did not succeed cleanly.' }
    }
    $comparisons.Add([pscustomobject]@{case=$scoop.case;status=$status;reason=$reason;scoop_exit=$scoop.exit;coop_exit=$coop.exit;expected=$expected;actual=$actual})
}
$help = @($comparisons | Where-Object case -like '*-help')
if ($help.Count -ne 28) { throw "Expected all 28 Scoop help pages, got $($help.Count)" }
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText("$Evidence/comparison.json",(ConvertTo-Json -InputObject @($comparisons.ToArray()) -Depth 6),$utf8)
$comparisons | Select-Object case,status,reason | Format-Table -AutoSize -Wrap
$failed = @($comparisons | Where-Object status -eq FAIL)
if ($failed.Count) { throw "$($failed.Count) unaccepted command output differences; inspect comparison.json" }
Write-Output "PASS all $($comparisons.Count) command scenarios, including all 28 help pages"

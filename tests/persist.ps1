param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$name = 'persistfixture'
$guard = Join-Path (Split-Path $CoopExe) 'process_guard.exe'
function New-Manifest([string]$Version,[string]$Source,[object]$Persist) {
    $hash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLower()
    @{version=$Version;url=([Uri][IO.Path]::GetFullPath($Source)).AbsoluteUri+'#/persist-fixture.exe';hash=$hash;bin='persist-fixture.exe';persist=$Persist} | ConvertTo-Json -Depth 6
}
function Assert-Text([string]$Path,[string]$Expected) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "missing file $Path" }
    $actual = [IO.File]::ReadAllText($Path).Trim()
    if ($actual -ne $Expected) { throw "unexpected content in $Path`: '$actual' (wanted '$Expected')" }
}
function Assert-Link([string]$Path,[string]$Target,[string]$Type) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.LinkType -ne $Type) { throw "$Path is not a $Type link (found '$($item.LinkType)')" }
    if (-not (Test-Path -LiteralPath $Target)) { throw "link target $Target is missing" }
    if ($Type -eq 'Junction') {
        $actual = @($item.Target)[0]
        if ([IO.Path]::GetFullPath([string]$actual).TrimEnd('\') -ne [IO.Path]::GetFullPath($Target).TrimEnd('\')) {
            throw "$Path points to '$actual' instead of '$Target'"
        }
    }
}
function Assert-Runs([string]$Path,[string]$Expected) {
    $output = ((& $Path) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or $output -ne $Expected) { throw "program $Path printed '$output' (wanted '$Expected')" }
}
function Remove-Junction([string]$Path) {
    & $env:ComSpec /d /s /c "rmdir `"$Path`"" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "cannot remove junction $Path" }
}
function Persist-Hashes([string]$Base) {
    @(Get-ChildItem -LiteralPath $Base -Recurse -File -Force | ForEach-Object { "$($_.FullName):$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" })
}

# In-place adoption, update and normal uninstall of a no-script sample with a directory
# junction and a file hardlink. The sample program reads the persisted data from its own directory.
$root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
$app = "$root/apps/$name"
$store = "$root/persist/$name"
New-Item -ItemType Directory -Path "$root/buckets/test/bucket","$app/1","$root/shims","$store/config","$store/unrelated" -Force | Out-Null
$fixture1 = Join-Path (Split-Path $CoopExe) 'persist-fixture-1.exe'
$fixture2 = Join-Path (Split-Path $CoopExe) 'persist-fixture-2.exe'
Copy-Item -LiteralPath $fixture1 -Destination "$app/1/persist-fixture.exe"
Set-Content -LiteralPath "$store/config/settings.ini" -Value 'owner-data-1' -NoNewline
Set-Content -LiteralPath "$store/sample.ini" -Value 'file-data-1' -NoNewline
Set-Content -LiteralPath "$store/unrelated/keep.txt" -Value 'unowned' -NoNewline
New-Item -ItemType Junction -Path "$app/1/config" -Target "$store/config" | Out-Null
New-Item -ItemType HardLink -Path "$app/1/sample.ini" -Target "$store/sample.ini" | Out-Null
$mapping = @(@('config','config'),@('sample.ini','sample.ini'))
[IO.File]::WriteAllText("$app/1/scoop-manifest.json",(New-Manifest '1' $fixture1 $mapping))
'{"bucket":"test","architecture":"64bit"}' | Set-Content -LiteralPath "$app/1/scoop-install.json" -Encoding utf8
New-Item -ItemType Junction -Path "$app/current" -Target "$app/1" | Out-Null
$scoopShim = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-fixtures/scoop-shim-kiennq.exe'))
if ((Get-FileHash -LiteralPath $scoopShim -Algorithm SHA256).Hash.ToLower() -ne '140e3801d8adeda639a21b14e62b93a4c7d26b7a758421f43c82be59753be49b') { throw 'unverified original Scoop test shim' }
Copy-Item -LiteralPath $scoopShim -Destination "$root/shims/persist-fixture.exe"
[IO.File]::WriteAllText("$root/shims/persist-fixture.shim",'path = "'+[IO.Path]::GetFullPath("$app/1/persist-fixture.exe")+'"'+"`r`n")
[IO.File]::WriteAllText("$root/buckets/test/bucket/$name.json",(New-Manifest '2' $fixture2 $mapping))
Assert-Runs "$root/shims/persist-fixture.exe" 'persist-fixture 1 config=owner-data-1 file=file-data-1'
Assert-Link "$app/1/config" "$store/config" 'Junction'
Assert-Link "$app/1/sample.ini" "$store/sample.ini" 'HardLink'
$unchanged = Persist-Hashes "$root/persist"

$preview = & $CoopExe --root $root adopt $name --dry-run --json
if ($LASTEXITCODE -ne 0) { throw 'persist adoption preview failed' }
$plan = ($preview -join "`n") | ConvertFrom-Json
if ($plan.eligibility -ne 'eligible') { throw "persist sample is not adoption eligible: $($plan.eligibility)" }
if (@($plan.persistence).Count -ne 2) { throw 'preview omitted declared persistence' }
$configPlan = @($plan.persistence | Where-Object source -eq 'config')[0]
$filePlan = @($plan.persistence | Where-Object source -eq 'sample.ini')[0]
if ($configPlan.link_type -ne 'junction' -or $filePlan.link_type -ne 'hardlink') { throw 'preview reported wrong persisted link types' }
if ($configPlan.link -notlike "*$($name)\1\config" -or $filePlan.store -notlike "*$($name)\sample.ini") { throw 'preview reported wrong persistence paths' }
if (Test-Path -LiteralPath "$root/.coop") { throw 'adoption preview wrote management state' }
if (@(Compare-Object $unchanged (Persist-Hashes "$root/persist")).Count) { throw 'adoption preview changed persisted data' }

$adoptionOutput = & $guard $CoopExe --root $root adopt $name --json
if ($LASTEXITCODE -ne 0) { throw "in-place adoption of persisted sample failed: $($adoptionOutput -join "`n")" }
$adoption = ($adoptionOutput -join "`n") | ConvertFrom-Json
if (@($adoption.persistence).Count -ne 2) { throw 'adoption result omitted persistence evidence' }
$record = Get-Content -LiteralPath "$root/.coop/packages/$name.json" -Raw | ConvertFrom-Json
if (@($record.persistence).Count -ne 2) { throw 'management record omitted persistence ownership' }
if (@(Compare-Object $unchanged (Persist-Hashes "$root/persist")).Count) { throw 'adoption moved or changed original persisted data' }
Assert-Link "$app/1/config" "$store/config" 'Junction'
Assert-Link "$app/1/sample.ini" "$store/sample.ini" 'HardLink'
Assert-Runs "$root/shims/persist-fixture.exe" 'persist-fixture 1 config=owner-data-1 file=file-data-1'

# User data changes after adoption must be what the next version reads.
Set-Content -LiteralPath "$store/config/settings.ini" -Value 'owner-data-2' -NoNewline
Set-Content -LiteralPath "$store/sample.ini" -Value 'file-data-2' -NoNewline
Assert-Runs "$root/shims/persist-fixture.exe" 'persist-fixture 1 config=owner-data-2 file=file-data-2'

# A publication failure must roll back program/entry changes without touching persisted data.
$lock = [IO.File]::Open("$root/.coop/packages/$name.json",[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try {
    $failed = & $CoopExe --root $root update $name --json 2>&1
    if ($LASTEXITCODE -eq 0) { throw 'occupied management record unexpectedly allowed update publication' }
} finally { $lock.Dispose() }
if (Test-Path -LiteralPath "$app/2") { throw 'failed persist update left the new version published' }
Assert-Runs "$root/shims/persist-fixture.exe" 'persist-fixture 1 config=owner-data-2 file=file-data-2'
Assert-Link "$app/1/config" "$store/config" 'Junction'
Assert-Link "$app/1/sample.ini" "$store/sample.ini" 'HardLink'
Assert-Text "$store/config/settings.ini" 'owner-data-2'
Assert-Text "$store/sample.ini" 'file-data-2'
Assert-Text "$store/unrelated/keep.txt" 'unowned'

$updateOutput = & $CoopExe --root $root update $name --json
if ($LASTEXITCODE -ne 0) { throw "persist update failed: $($updateOutput -join "`n")" }
$updated = ($updateOutput -join "`n") | ConvertFrom-Json
if ($updated.status -ne 'success' -or @($updated.persistence).Count -ne 2) { throw 'update result omitted persistence evidence' }
if (@($updated.persistence | Where-Object { $_.link -like "*$name\2\*" }).Count -ne 2) { throw 'update reported staging paths instead of published persistence links' }
if ('1' -notin @($updated.retained_versions) -or $updated.data_rollback -ne 'none') { throw 'update mixed old-program retention with data rollback reporting' }
Assert-Runs "$root/shims/persist-fixture.exe" 'persist-fixture 2 config=owner-data-2 file=file-data-2'
Assert-Runs "$app/1/persist-fixture.exe" 'persist-fixture 1 config=owner-data-2 file=file-data-2'
Assert-Link "$app/2/config" "$store/config" 'Junction'
Assert-Link "$app/2/sample.ini" "$store/sample.ini" 'HardLink'
Assert-Text "$store/config/settings.ini" 'owner-data-2'
Assert-Text "$store/sample.ini" 'file-data-2'
Assert-Text "$store/unrelated/keep.txt" 'unowned'
$items = & $CoopExe --root $root list --json | ConvertFrom-Json
$item = @($items | Where-Object name -eq $name)[0]
if ($item.version -ne '2' -or '1' -notin @($item.older_versions) -or @($item.persistence).Count -ne 2) { throw 'list did not separate current version, old program and persisted data' }

# A changed persist mapping is an explicit unverified operation, not a silent migration.
[IO.File]::WriteAllText("$root/buckets/test/bucket/$name.json",(New-Manifest '3' $fixture1 'renamed'))
$blocked = & $CoopExe --root $root update $name --json 2>&1
if ($LASTEXITCODE -eq 0 -or ($blocked -join "`n") -notmatch 'Persistence mapping changes are not verified') { throw 'changed persist mapping was not explicitly refused' }
if (Test-Path -LiteralPath "$app/3") { throw 'refused mapping change published a version' }
Assert-Runs "$root/shims/persist-fixture.exe" 'persist-fixture 2 config=owner-data-2 file=file-data-2'
[IO.File]::WriteAllText("$root/buckets/test/bucket/$name.json",(New-Manifest '2' $fixture2 $mapping))

# Link ownership changes must stop uninstall before any deletion.
Remove-Junction "$app/2/config"
New-Item -ItemType Junction -Path "$app/2/config" -Target "$store/unrelated" | Out-Null
$failed = & $CoopExe --root $root uninstall $name --json 2>&1
if ($LASTEXITCODE -eq 0) { throw 'uninstall accepted a retargeted persistence junction' }
if (-not (Test-Path -LiteralPath "$app/current/persist-fixture.exe") -or -not (Test-Path -LiteralPath "$store/unrelated/keep.txt")) { throw 'failed ownership check deleted the program or unrelated data' }
Remove-Junction "$app/2/config"
New-Item -ItemType Junction -Path "$app/2/config" -Target "$store/config" | Out-Null

Remove-Item -LiteralPath "$app/2/sample.ini" -Force
Set-Content -LiteralPath "$app/2/sample.ini" -Value 'tampered' -NoNewline
$failed = & $CoopExe --root $root uninstall $name --json 2>&1
if ($LASTEXITCODE -eq 0) { throw 'uninstall accepted a replaced persistence hardlink' }
Assert-Text "$store/sample.ini" 'file-data-2'
if (-not (Test-Path -LiteralPath "$app/current/persist-fixture.exe")) { throw 'failed hardlink ownership check removed the current program' }
Remove-Item -LiteralPath "$app/2/sample.ini" -Force
New-Item -ItemType HardLink -Path "$app/2/sample.ini" -Target "$store/sample.ini" | Out-Null

# Real Scoop marks persist junctions read-only on the link itself (attrib +R /L) and a persisted
# file can be read-only too; uninstall must clear that before unlinking and keep the store.
& attrib.exe +R /L "$app/2/config" | Out-Null
& attrib.exe +R "$app/2/sample.ini" | Out-Null
if (-not ((Get-Item -LiteralPath "$app/2/config" -Force).Attributes -band [IO.FileAttributes]::ReadOnly)) { throw 'failed to mark the version junction read-only' }
$uninstallOutput = & $CoopExe --root $root uninstall $name --json
if ($LASTEXITCODE -ne 0) { throw "persist uninstall failed: $($uninstallOutput -join "`n")" }
$removed = ($uninstallOutput -join "`n") | ConvertFrom-Json
if ($removed.data_retained -ne $true -or @($removed.persistence).Count -ne 2) { throw 'uninstall result omitted retained data evidence' }
if (Test-Path -LiteralPath "$app/current") { throw 'uninstall left current published' }
if (Test-Path -LiteralPath "$app/2") { throw 'uninstall left the current version directory' }
if (Test-Path -LiteralPath "$root/shims/persist-fixture.exe") { throw 'uninstall left the command entry' }
if (Test-Path -LiteralPath "$root/.coop/packages/$name.json") { throw 'uninstall left the management record' }
if (-not (Test-Path -LiteralPath "$app/1/persist-fixture.exe")) { throw 'documented old release retention was lost' }
Assert-Link "$app/1/config" "$store/config" 'Junction'
Assert-Runs "$app/1/persist-fixture.exe" 'persist-fixture 1 config=owner-data-2 file=file-data-2'
Assert-Text "$store/config/settings.ini" 'owner-data-2'
Assert-Text "$store/sample.ini" 'file-data-2'
Assert-Text "$store/unrelated/keep.txt" 'unowned'

# A fresh native install creates the default store directory, then update reuses it.
$root2 = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
$app2 = "$root2/apps/persistnew"
$store2 = "$root2/persist/persistnew"
New-Item -ItemType Directory -Path "$root2/buckets/test/bucket","$store2" -Force | Out-Null
Set-Content -LiteralPath "$store2/sample.ini" -Value 'file-fresh' -NoNewline
[IO.File]::WriteAllText("$root2/buckets/test/bucket/persistnew.json",(New-Manifest '1' $fixture1 @('config','sample.ini')))
$install = & $CoopExe --root $root2 install test/persistnew --json
if ($LASTEXITCODE -ne 0) { throw "fresh persist install failed: $($install -join "`n")" }
if (-not (Test-Path -LiteralPath "$store2/config")) { throw 'fresh install did not create declared persist store' }
Assert-Link "$app2/current/config" "$store2/config" 'Junction'
Assert-Link "$app2/current/sample.ini" "$store2/sample.ini" 'HardLink'
Assert-Runs "$root2/shims/persist-fixture.exe" 'persist-fixture 1 config=<missing> file=file-fresh'
Set-Content -LiteralPath "$store2/config/settings.ini" -Value 'fresh-data' -NoNewline
[IO.File]::WriteAllText("$root2/buckets/test/bucket/persistnew.json",(New-Manifest '2' $fixture2 @('config','sample.ini')))
$freshUpdate = & $CoopExe --root $root2 update persistnew --json
if ($LASTEXITCODE -ne 0) { throw "fresh persist update failed: $($freshUpdate -join "`n")" }
Assert-Runs "$root2/shims/persist-fixture.exe" 'persist-fixture 2 config=fresh-data file=file-fresh'
$freshRemove = & $CoopExe --root $root2 uninstall persistnew --json
if ($LASTEXITCODE -ne 0) { throw 'fresh persist uninstall failed' }
Assert-Text "$store2/config/settings.ini" 'fresh-data'
Assert-Text "$store2/sample.ini" 'file-fresh'

# A reparse point inside the declared store path is refused before publication.
$root3 = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root3/buckets/test/bucket","$root3/persist/persistlink","$root3/outside" -Force | Out-Null
New-Item -ItemType Junction -Path "$root3/persist/persistlink/bad" -Target "$root3/outside" | Out-Null
$badPair = [Collections.Generic.List[object]]::new()
$badPair.Add([string[]]@('config','bad/config'))
[IO.File]::WriteAllText("$root3/buckets/test/bucket/persistlink.json",(New-Manifest '1' $fixture1 $badPair))
$failed = & $CoopExe --root $root3 install test/persistlink --json 2>&1
if ($LASTEXITCODE -eq 0 -or (Test-Path -LiteralPath "$root3/apps/persistlink/current") -or (Test-Path -LiteralPath "$root3/outside/config")) { throw 'reparse persist target was not refused before publication' }
if (Test-Path -LiteralPath "$root3/.coop/packages/persistlink.json") { throw 'refused reparse persist install left a management record' }
$journals = @(Get-ChildItem "$root3/.coop/transactions" -Recurse -Filter journal.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
if ('rolled-back' -notin $journals.state) { throw 'refused persist install did not record rollback' }
# A regular file where a persist store directory is required must also fail before publication.
New-Item -ItemType Directory -Path "$root3/persist/persistfile" -Force | Out-Null
Set-Content -LiteralPath "$root3/persist/persistfile/blocked" -Value 'not-a-directory' -NoNewline
$filePair = [Collections.Generic.List[object]]::new()
$filePair.Add([string[]]@('config','blocked/config'))
[IO.File]::WriteAllText("$root3/buckets/test/bucket/persistfile.json",(New-Manifest '1' $fixture1 $filePair))
$failed = & $CoopExe --root $root3 install test/persistfile --json 2>&1
if ($LASTEXITCODE -eq 0 -or (Test-Path -LiteralPath "$root3/apps/persistfile/current")) { throw 'file where persist directory is required did not fail before publication' }
Assert-Text "$root3/persist/persistfile/blocked" 'not-a-directory'
if (Test-Path -LiteralPath "$root3/.coop/packages/persistfile.json") { throw 'refused file-parent persist install left a management record' }

@{adopted_root=$root;fresh_root=$root2;reparse_root=$root3;coop=$CoopExe} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $TestRoot 'persist-evidence.json') -Encoding utf8
Write-Output "PASS persisted data across adoption, update, uninstall, rollback and ownership conflicts: $TestRoot"
exit 0

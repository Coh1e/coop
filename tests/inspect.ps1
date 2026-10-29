# Red when: `status` stops reporting an outdated package or stops saying `Everything is ok!`,
# `prefix` stops printing the current path Scoop prints, `cat` stops echoing the stored manifest,
# `which` stops resolving a shim's target, `home` stops failing on a manifest without a homepage,
# `depends` stops listing the declared dependency before the app itself, `export` stops listing
# buckets/apps, `checkup` stops reporting a broken shim, or `help` stops marking what is missing.
param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test data must stay within the project test directory'
}
$root = Join-Path $TestRoot 'inspect'
if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
New-Item -ItemType Directory -Path "$root/buckets/main/bucket", "$root/apps/demo/1.7.1", "$root/shims" -Force | Out-Null
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$root/buckets/main/bucket/demo.json" -Force
# The installed version comes from the saved Manifest, so the fixture's saved copy must say 1.7.1.
((Get-Content "$PSScriptRoot/corpus/main/jq.json" -Raw) -replace '"version": "1\.8\.2"', '"version": "1.7.1"') |
    Set-Content "$root/apps/demo/1.7.1/scoop-manifest.json" -Encoding utf8
'{"bucket":"main","architecture":"64bit"}' | Set-Content "$root/apps/demo/1.7.1/scoop-install.json" -Encoding utf8
New-Item -ItemType Junction -Path "$root/apps/demo/current" -Target "$root/apps/demo/1.7.1" | Out-Null
$target = "$root\apps\demo\current\demo.exe"
New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
Set-Content -LiteralPath $target -Value 'stub' -Encoding ascii
"path = `"$target`"" | Set-Content "$root/shims/demo.shim" -Encoding utf8

# status reports the outdated package with both versions.
$lines = @(& $CoopExe --root $root status)
if ($LASTEXITCODE -cne 0) { throw "status failed: $($lines -join ' | ')" }
if ($lines[0] -cne 'Name Installed Version Latest Version Missing Dependencies Info') { throw "status header is '$($lines[0])'" }
if ($lines[2] -cnotmatch '^demo\s+1\.7\.1\s+1\.8\.2\s') { throw "status row is '$($lines[2])'" }
# `-l` is Scoop's "do not fetch" switch and Coop never fetches, so it must be accepted.
$lines = @(& $CoopExe --root $root status -l)
if ($LASTEXITCODE -cne 0) { throw "status -l failed: $($lines -join ' | ')" }

# prefix prints the same `current` path Scoop prints.
$lines = @(& $CoopExe --root $root prefix demo)
if ($LASTEXITCODE -cne 0 -or $lines[0] -cne "$root\apps\demo\current") { throw "prefix printed '$($lines -join ' | ')'" }

# which resolves the shim's target instead of the shim file.
$lines = @(& $CoopExe --root $root which demo)
if ($LASTEXITCODE -cne 0 -or $lines[0] -cne $target) { throw "which printed '$($lines -join ' | ')'" }
$lines = @(& $CoopExe --root $root which zzznope)
if ($LASTEXITCODE -cne 1 -or ($lines -join '|') -cne "WARN  'zzznope' not found, not a scoop shim, or a broken shim.") {
    throw "which on a missing name said '$($lines -join ' | ')'"
}

# cat echoes the stored manifest, declaration order intact.
$lines = @(& $CoopExe --root $root cat demo)
if ($LASTEXITCODE -cne 0 -or ($lines -join "`n") -cnotmatch '"version": "1\.8\.2"') { throw 'cat did not print the manifest' }
if ($lines[0] -cne '{') { throw "cat first line is '$($lines[0])'" }

# A manifest without a homepage makes `home` fail instead of opening anything.
'{"version":"1.0","url":"https://example.invalid/x.zip","hash":"0000000000000000000000000000000000000000000000000000000000000000"}' |
    Set-Content "$root/buckets/main/bucket/nohome.json" -Encoding utf8
$lines = & $CoopExe --root $root home nohome 2>&1
if ($LASTEXITCODE -cne 1 -or ($lines -join '|') -cnotmatch 'No homepage is declared') { throw "home on a manifest without homepage said '$($lines -join ' | ')'" }

# Once the installed version matches the manifest, status reports the clean state.
New-Item -ItemType Directory -Path "$root/apps/demo/1.8.2" -Force | Out-Null
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$root/apps/demo/1.8.2/scoop-manifest.json" -Force
'{"bucket":"main","architecture":"64bit"}' | Set-Content "$root/apps/demo/1.8.2/scoop-install.json" -Encoding utf8
(Get-Item "$root/apps/demo/current").Delete()
New-Item -ItemType Junction -Path "$root/apps/demo/current" -Target "$root/apps/demo/1.8.2" | Out-Null
$lines = @(& $CoopExe --root $root status)
if ($LASTEXITCODE -cne 0 -or ($lines -join '|') -cne 'Everything is ok!') { throw "clean status said '$($lines -join ' | ')'" }

# depends lists the declared dependency first and the app itself last, like Scoop.
'{"version":"2.0","url":"https://example.invalid/dep.zip","hash":"1111111111111111111111111111111111111111111111111111111111111111","depends":"demo"}' |
    Set-Content "$root/buckets/main/bucket/dep.json" -Encoding utf8
$lines = @(& $CoopExe --root $root depends dep)
if ($LASTEXITCODE -cne 0) { throw "depends failed: $($lines -join ' | ')" }
if (($lines -join "`n") -cnotmatch '(?s)^Source\s+Name\s+------\s+----\s+main\s+demo\s+main\s+dep\s*$') {
    throw "depends printed '`n$($lines -join "`n")'"
}

# export is a Scoopfile: buckets and apps with Scoop's field names.
$export = (& $CoopExe --root $root export) -join "`n"
if ($LASTEXITCODE -cne 0) { throw 'export failed' }
$file = $export | ConvertFrom-Json
if (@($file.buckets | Where-Object Name -CEQ 'main').Count -cne 1) { throw 'export omitted the bucket' }
if (@($file.apps | Where-Object Name -CEQ 'demo').Count -cne 1) { throw 'export omitted the installed app' }

# checkup reports a shim whose target disappeared, and still exits 0.
"path = `"$root\apps\demo\current\gone.exe`"" | Set-Content "$root/shims/broken.shim" -Encoding utf8
$lines = @(& $CoopExe --root $root checkup)
if ($LASTEXITCODE -cne 0) { throw "checkup exited $LASTEXITCODE" }
if (($lines -join "`n") -cnotmatch "Shim 'broken' points to a missing target") { throw "checkup said '`n$($lines -join "`n")'" }

# help: the command list, a per-command usage, and an honest marker for what Coop does not have.
$lines = @(& $CoopExe help)
if ($LASTEXITCODE -cne 0 -or ($lines -join "`n") -cnotmatch 'Command\s+Summary') { throw 'help printed no command list' }
if (($lines -join "`n") -cnotmatch 'cache\s+.* \(not implemented yet\)') { throw 'help did not mark an unimplemented command' }
$lines = @(& $CoopExe --root $root list --help)
if ($LASTEXITCODE -cne 0 -or $lines[0] -cne 'Usage: coop list [query]') { throw "list --help printed '$($lines -join ' | ')'" }
$lines = & $CoopExe help cache 2>&1
if ($LASTEXITCODE -cne 1 -or ($lines -join '|') -cnotmatch 'not implemented in Coop yet') { throw "help cache said '$($lines -join ' | ')'" }
Write-Output 'PASS: status, prefix, cat, which, home, depends, export, checkup and help'

# Red when: bare `coop update` stops refreshing every bucket, `update *` / `-a` stops expanding to the
# installed apps, `-g`/`--global` stops reporting the system-level boundary as a stable marker, or
# `bucket rm` stops acting as `remove`.
param([Parameter(Mandatory)][string]$CoopExe, [Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
$allowedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\') + '\'
if (-not ($TestRoot.TrimEnd('\') + '\').StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test data must stay within the project test directory'
}
$root = Join-Path $TestRoot 'bare'
if (Test-Path $root) { Remove-Item -LiteralPath $root -Recurse -Force }
New-Item -ItemType Directory -Path "$root/buckets/main/bucket", "$root/apps/demo/1.7.1" -Force | Out-Null
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$root/buckets/main/bucket/demo.json" -Force
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$root/apps/demo/1.7.1/scoop-manifest.json" -Force
'{"bucket":"main","architecture":"64bit"}' | Set-Content "$root/apps/demo/1.7.1/scoop-install.json" -Encoding utf8
New-Item -ItemType Junction -Path "$root/apps/demo/current" -Target "$root/apps/demo/1.7.1" | Out-Null

# `scoop update` with no app refreshes the buckets and prints Scoop's heading.
$out = @(& $CoopExe --root $root update)
if ($LASTEXITCODE -cne 0) { throw "bare update failed: $($out -join ' | ')" }
if ($out.Count -lt 1 -or $out[0] -cne 'Updating Buckets...') { throw "bare update first line is '$($out -join ' | ')'" }

# `*` and `-a` expand to every installed app instead of refreshing buckets.
foreach ($wildcard in '*', '-a') {
    $out = @(& $CoopExe --root $root update $wildcard --dry-run)
    if ($LASTEXITCODE -cne 0) { throw "update $wildcard failed: $($out -join ' | ')" }
    if (($out -join "`n") -cnotmatch 'demo') { throw "update $wildcard did not reach the installed app" }
}

# A system-level write is refused with the product's own marker, not as an unknown switch.
$refusal = & $CoopExe --root $root uninstall -g demo 2>&1
if ($LASTEXITCODE -cne 1) { throw "uninstall -g exited $LASTEXITCODE" }
if (($refusal -join "`n") -cnotmatch 'global-scope-readonly') { throw "uninstall -g said: $($refusal -join ' | ')" }

# `rm` is Scoop's own spelling for removing a bucket registration.
$source = Join-Path $TestRoot 'bare-source'
New-Item -ItemType Directory -Path "$source/bucket" -Force | Out-Null
Copy-Item "$PSScriptRoot/corpus/main/jq.json" "$source/bucket/extra.json" -Force
& $CoopExe --root $root bucket add extra "$source" | Out-Null
if ($LASTEXITCODE -cne 0) { throw 'bucket add failed' }
$out = @(& $CoopExe --root $root bucket rm extra)
if ($LASTEXITCODE -cne 0 -or ($out -join "`n") -cnotmatch 'Removed bucket registration extra') {
    throw "bucket rm failed: $($out -join ' | ')"
}

# `bucket known` answers from Scoop's own list, or from the snapshot when Scoop is not beside the root.
$out = @(& $CoopExe --root $root bucket known)
if ($LASTEXITCODE -cne 0 -or $out -cnotcontains 'main' -or $out -cnotcontains 'extras') {
    throw "bucket known printed '$($out -join ' | ')'"
}

# The switches a Scoop user arrives with are accepted: `-p` for purge, `-a` for every app,
# `-u` for "do not update Scoop first" and `-q` for quiet.
$out = @(& $CoopExe --root $root uninstall -p demo --dry-run)
if ($LASTEXITCODE -cne 0) { throw "uninstall -p failed: $($out -join ' | ')" }
$out = @(& $CoopExe --root $root cleanup -a --dry-run)
if ($LASTEXITCODE -cne 0) { throw "cleanup -a failed: $($out -join ' | ')" }
$out = @(& $CoopExe --root $root update demo -u -q --dry-run)
if ($LASTEXITCODE -cne 0) { throw "update -u -q failed: $($out -join ' | ')" }
Write-Output 'PASS: bare update, wildcard expansion, system-level boundary, bucket rm/known and Scoop switches'

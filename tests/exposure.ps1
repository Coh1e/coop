param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$build = Split-Path $CoopExe
$fixture1 = Join-Path $build 'fixture-1.exe'
$fixture2 = Join-Path $build 'fixture-2.exe'
$fixtureGui = Join-Path $build 'fixture-gui.exe'
$fixtureEnv = Join-Path $build 'fixture-env.exe'
$scoopShim = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/deps/test-fixtures/scoop-shim-kiennq.exe'))
foreach ($path in @($fixture1,$fixture2,$fixtureGui,$fixtureEnv,$scoopShim)) { if (-not (Test-Path -LiteralPath $path)) { throw "Missing fixed test input: $path" } }
if ((Get-FileHash -LiteralPath $scoopShim -Algorithm SHA256).Hash.ToLower() -ne '140e3801d8adeda639a21b14e62b93a4c7d26b7a758421f43c82be59753be49b') { throw 'unverified original Scoop test shim' }
function Assert-Exit([string]$message) { if ($LASTEXITCODE -ne 0) { throw $message } }
function Read-Json([object]$output) { return (($output -join "`n") | ConvertFrom-Json) }
function File-Uri([string]$path) { return ([Uri][IO.Path]::GetFullPath($path)).AbsoluteUri }
function New-TestRoot {
    $root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path "$root/buckets/test/bucket" -Force | Out-Null
    return $root
}
function New-ZipPackage([string]$path,[System.Collections.IDictionary]$entries) {
    $stream = [IO.File]::Create($path)
    $zip = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
    try {
        foreach ($name in $entries.Keys) {
            $entry = $zip.CreateEntry([string]$name)
            $target = $entry.Open()
            try {
                $item = $entries[$name]
                if ($item -is [byte[]]) { $target.Write($item,0,$item.Length) }
                else {
                    $bytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$item)
                    $target.Write($bytes,0,$bytes.Length)
                }
            } finally { $target.Dispose() }
        }
    } finally { $zip.Dispose(); $stream.Dispose() }
}
function Write-Manifest([string]$root,[string]$name,[object]$manifest) {
    [IO.File]::WriteAllText("$root/buckets/test/bucket/$name.json",($manifest | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}
function Get-PeSubsystem([string]$path) {
    $stream = [IO.File]::OpenRead($path)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        $stream.Position = 0x3c
        $lfanew = $reader.ReadInt32()
        $stream.Position = $lfanew+4+20+68
        return $reader.ReadUInt16()
    } finally { $stream.Dispose() }
}
function Assert-Shortcut([string]$link,[string]$target,[string]$arguments,[string]$icon = '') {
    if (-not (Test-Path -LiteralPath $link)) { throw "missing shortcut $link" }
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($link)
    if ([IO.Path]::GetFullPath($shortcut.TargetPath) -ne [IO.Path]::GetFullPath($target)) { throw "shortcut $link points to $($shortcut.TargetPath)" }
    if ($shortcut.Arguments -ne $arguments) { throw "shortcut $link arguments are '$($shortcut.Arguments)'" }
    if ($icon) {
        $iconPath = $shortcut.IconLocation -replace ',\d+$',''
        if ([IO.Path]::GetFullPath($iconPath) -ne [IO.Path]::GetFullPath($icon)) { throw "shortcut $link icon is '$($shortcut.IconLocation)'" }
    }
}
function Build-EnvironmentPackage([string]$root,[string]$version,[string]$jarFile,[string]$envValue,[object]$shortcuts,[object]$bin) {
    $fixtures = Join-Path $root 'fixtures'
    New-Item -ItemType Directory -Path $fixtures -Force | Out-Null
    $folder = Join-Path $fixtures "envapp-$version"
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $cmdTool = @('@echo off',"echo cmd-args:%*","echo cmd-$version",'exit /b 0') -join "`r`n"
    $cmdFail = @('@echo off','echo fail-args:%*','exit /b 7') -join "`r`n"
    $cmdShow = @('@echo off','echo env=%FIXTURE_ENV%','echo data=%TOOL_DATA%','echo version=%TOOL_VERSION%','echo path=%PATH%','exit /b 0') -join "`r`n"
    $ps1 = @('[IO.File]::WriteAllText($env:PS1_MARKER, ($args -join "|"))','exit 3') -join "`r`n"
    $archive = Join-Path $folder 'app.zip'
    New-ZipPackage $archive ([ordered]@{
        'bin/tool.cmd' = $cmdTool
        'bin/fail.cmd' = $cmdFail
        'bin/show.cmd' = $cmdShow
        'ps1/hello.ps1' = $ps1
        'gui/gui.exe' = [IO.File]::ReadAllBytes($fixtureGui)
        'tool.exe' = [IO.File]::ReadAllBytes($fixture1)
        'java/app.jar' = [IO.File]::ReadAllBytes($jarFile)
    })
    $manifest = @{version=$version;url=(File-Uri $archive);hash=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower();
        bin=$bin;shortcuts=$shortcuts;env_add_path=@('bin','.');
        env_set=@{FIXTURE_ENV=$envValue;TOOL_DATA='$persist_dir\data';TOOL_VERSION='$version';
            PS1_MARKER='$dir\ps1-marker.txt';GUI_FIXTURE_MARKER='$dir\gui-marker.txt'};
        persist='data'}
    Write-Manifest $root 'envapp' $manifest
}
# The JAR entry is verified with a real Java runtime when a JDK is available; otherwise the
# launcher must fail with an explicit missing-runtime error instead of pretending to run.
$jarPath = Join-Path $TestRoot ('coop-t12-'+[guid]::NewGuid().ToString('N')+'.jar')
$jarAvailable = $false
$javac = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin/javac.exe' } else { $null }
$jarTool = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin/jar.exe' } else { $null }
if ($javac -and $jarTool -and (Test-Path -LiteralPath $javac) -and (Test-Path -LiteralPath $jarTool)) {
    $source = Join-Path $TestRoot ('coop-t12-src-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $source -Force | Out-Null
    $code = @('public class App {','  public static void main(String[] args) throws Exception {',
        '    System.out.println("jar-args=" + String.join("|", args));',
        '    System.out.println("jar-cwd=" + new java.io.File(".").getCanonicalPath());',
        '    System.exit(4);','  }','}') -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $source 'App.java'),$code,[Text.UTF8Encoding]::new($false))
    & $javac -d (Join-Path $source 'classes') (Join-Path $source 'App.java') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'javac failed to build the JAR fixture' }
    & $jarTool --create --file $jarPath --main-class App -C (Join-Path $source 'classes') . | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'jar failed to build the JAR fixture' }
    $jarAvailable = $true
} else {
    [IO.File]::WriteAllBytes($jarPath,[byte[]](0x50,0x4b,0x03,0x04))
}

$root = New-TestRoot
$programs = Join-Path $root 'programs'
$env:COOP_PROGRAMS_DIR = $programs
$tag = 'T12'+([guid]::NewGuid().ToString('N').Substring(0,8))
$mainShortcut = "Coop $tag\工具 应用"
$failShortcut = "Fail-$tag"
$bin = @(
    @('bin/tool.cmd','cmd-tool','--default'),
    @('bin/fail.cmd','fail-tool','--boom'),
    @('bin/show.cmd','show-tool'),
    @('ps1/hello.ps1','ps-tool','--flag'),
    @('gui/gui.exe','gui-tool'),
    @('tool.exe','plain-tool'),
    @('tool.exe','工具'),
    @('java/app.jar','jar-tool','--jar-default')
)
$shortcuts = @(@('tool.exe',$mainShortcut,'','tool.exe'),@('bin/fail.cmd',$failShortcut,'--from-shortcut'))
Build-EnvironmentPackage $root '1' $jarPath 'declared-value' $shortcuts $bin

# Preview exposes the forwarded launcher types, shortcut destination and expanded environment
# without creating state, shortcuts or an isolated Start Menu folder.
$preview = Read-Json (& $CoopExe --root $root install test/envapp --dry-run --json)
Assert-Exit 'complex command preview failed'
if (-not $preview.execution_available) { throw "complex command preview is blocked: $($preview.diagnostics | ConvertTo-Json -Compress)" }
if ($preview.exposure.shortcut_directory -ne $programs -or $preview.exposure.shortcut_directory_source -ne 'isolated-override') { throw 'preview did not disclose the isolated shortcut directory' }
foreach ($launcher in @('direct','cmd','powershell','java')) { if ($launcher -notin @($preview.package.commands | ForEach-Object launcher)) { throw "preview omitted launcher type $launcher" } }
$environment = @($preview.exposure.environment)
if (($environment | Where-Object name -eq 'FIXTURE_ENV').value -ne 'declared-value') { throw 'preview environment value is wrong' }
if (($environment | Where-Object name -eq 'TOOL_DATA').value -ne (Join-Path $root 'persist/envapp/data')) { throw 'preview did not expand $persist_dir' }
if (($environment | Where-Object name -eq 'TOOL_VERSION').value -ne '1') { throw 'preview did not expand $version' }
$pathEntries = @($preview.exposure.path_entries)
if ((Join-Path $root 'apps/envapp/current/bin') -notin $pathEntries -or (Join-Path $root 'apps/envapp/current') -notin $pathEntries) { throw 'preview path entries are wrong' }
if (@($preview.exposure.shortcuts).Count -ne 2 -or @($preview.exposure.shortcuts | Where-Object name -eq $mainShortcut).Count -ne 1) { throw 'preview shortcut disclosure is incomplete' }
if ((Test-Path $programs) -or (Test-Path "$root/apps") -or (Test-Path "$root/shims") -or (Test-Path "$root/.coop")) { throw 'command preview changed product state' }

$install = & $CoopExe --root $root install test/envapp --json
Assert-Exit "complex command install failed: $($install -join "`n")"
$record = Get-Content -LiteralPath "$root/.coop/packages/envapp.json" -Raw | ConvertFrom-Json
if (@($record.commands).Count -ne 8) { throw 'management record omitted command entries' }
if (@($record.shortcuts).Count -ne 2) { throw 'management record omitted shortcuts' }
if (@($record.environment | Where-Object name -eq 'FIXTURE_ENV').value -ne 'declared-value') { throw 'management record omitted environment ownership' }

$cmdOutput = ((& "$root/shims/cmd-tool.exe" hello 'two words') -join "`n")
if ($LASTEXITCODE -ne 0 -or $cmdOutput -notmatch 'cmd-args:' -or $cmdOutput -notmatch '--default' -or $cmdOutput -notmatch 'two words' -or $cmdOutput -notmatch 'cmd-1') { throw "CMD entry did not forward arguments: $cmdOutput" }
$failOutput = ((& "$root/shims/fail-tool.exe") 2>&1) -join "`n"
if ($LASTEXITCODE -ne 7 -or $failOutput -notmatch '--boom') { throw "CMD entry did not propagate the exit code: $failOutput" }
$plainOutput = ((& "$root/shims/plain-tool.exe") -join "`n")
if ($LASTEXITCODE -ne 0 -or $plainOutput -notmatch 'fixture 1') { throw 'direct EXE entry did not run' }
$unicodeOutput = ((& "$root/shims/工具.exe") -join "`n")
if ($LASTEXITCODE -ne 0 -or $unicodeOutput -notmatch 'fixture 1') { throw 'Unicode command alias did not run' }
$showOutput = ((& "$root/shims/show-tool.exe") -join "`n")
if ($LASTEXITCODE -ne 0 -or $showOutput -notmatch 'env=declared-value' -or $showOutput -notmatch ('data='+[regex]::Escape((Join-Path $root 'persist/envapp/data'))) -or $showOutput -notmatch 'version=1') { throw "declared environment was not applied: $showOutput" }
if ($showOutput -notmatch [regex]::Escape((Join-Path $root 'apps/envapp/current/bin')) -or $showOutput -notmatch [regex]::Escape("$env:SystemRoot\System32")) { throw 'PATH exposure did not prepend package entries nor keep the existing PATH' }
$psOutput = ((& "$root/shims/ps-tool.exe" one 'two words') 2>&1) -join "`n"
if ($LASTEXITCODE -ne 3) { throw "PS1 entry did not propagate the exit code: $psOutput" }
$psMarker = Get-Content -LiteralPath "$root/apps/envapp/current/ps1-marker.txt" -Raw
if ($psMarker -notmatch '--flag' -or $psMarker -notmatch 'one' -or $psMarker -notmatch 'two words') { throw "PS1 entry did not forward arguments: $psMarker" }
if ((Get-PeSubsystem "$root/shims/gui-tool.exe") -ne 2 -or (Get-PeSubsystem "$root/shims/plain-tool.exe") -ne 3) { throw 'GUI/CLI launcher subsystem selection is wrong' }
$gui = Start-Process -FilePath "$root/shims/gui-tool.exe" -PassThru
if (-not $gui.WaitForExit(30000)) { throw 'GUI launcher did not finish' }
if ($gui.ExitCode -ne 5) { throw "GUI launcher did not propagate the exit code: $($gui.ExitCode)" }
if (-not (Test-Path -LiteralPath "$root/apps/envapp/current/gui-marker.txt")) { throw 'GUI target did not run' }
if ($jarAvailable) {
    $jarOutput = ((& "$root/shims/jar-tool.exe" x 'y z') 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 4) { throw "JAR entry did not propagate the exit code: $jarOutput" }
    if ($jarOutput -notmatch 'jar-args=--jar-default\|x\|y z') { throw "JAR entry did not forward arguments: $jarOutput" }
    if ($jarOutput -notmatch 'jar-cwd=.*\\java$') { throw "JAR entry did not use the package directory: $jarOutput" }
} else {
    $savedPath = $env:PATH
    $savedJava = $env:JAVA_HOME
    try {
        $env:JAVA_HOME = $null
        $env:PATH = "$env:SystemRoot\System32"
        $jarOutput = ((& "$root/shims/jar-tool.exe") 2>&1) -join "`n"
        $jarCode = $LASTEXITCODE
    } finally { $env:PATH = $savedPath; $env:JAVA_HOME = $savedJava }
    if ($jarCode -eq 0 -or $jarOutput -notmatch 'Java runtime') { throw "JAR entry without a runtime did not fail explicitly: $jarOutput" }
}
Assert-Shortcut (Join-Path $programs "$mainShortcut.lnk") "$root/apps/envapp/current/tool.exe" '' (Join-Path $root 'apps/envapp/current/tool.exe')
Assert-Shortcut (Join-Path $programs "$failShortcut.lnk") "$root/apps/envapp/current/bin/fail.cmd" '--from-shortcut'
$foreignLink = Join-Path $programs "Unrelated-$tag.lnk"
[IO.File]::WriteAllText($foreignLink,'foreign shortcut')
if (Test-Path -LiteralPath (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Scoop Apps\Coop $tag")) { throw 'isolated test wrote into the real Start Menu' }
if ([Environment]::GetEnvironmentVariable('FIXTURE_ENV','User') -eq 'declared-value') { throw 'test wrote a persistent user environment variable' }

# Update replaces entries and removes only shortcuts Coop created for the previous version.
$bin = @($bin | Where-Object { $_[1] -ne 'fail-tool' })
$shortcuts = ,@('tool.exe',$mainShortcut)
Build-EnvironmentPackage $root '2' $jarPath 'declared-v2' $shortcuts $bin
$update = & $CoopExe --root $root update envapp --json
Assert-Exit "complex command update failed: $($update -join "`n")"
$cmdOutput = ((& "$root/shims/cmd-tool.exe" hello) -join "`n")
if ($LASTEXITCODE -ne 0 -or $cmdOutput -notmatch 'cmd-2') { throw 'updated CMD entry did not run the new version' }
$showOutput = ((& "$root/shims/show-tool.exe") -join "`n")
if ($showOutput -notmatch 'env=declared-v2' -or $showOutput -notmatch 'version=2') { throw 'updated environment exposure is wrong' }
if (Test-Path -LiteralPath (Join-Path $programs "$failShortcut.lnk")) { throw 'update left the removed shortcut behind' }
Assert-Shortcut (Join-Path $programs "$mainShortcut.lnk") "$root/apps/envapp/current/tool.exe" ''
$record = Get-Content -LiteralPath "$root/.coop/packages/envapp.json" -Raw | ConvertFrom-Json
if (@($record.shortcuts).Count -ne 1) { throw 'updated management record kept the removed shortcut' }

# A locked shortcut is left in place; the uninstall fails and rolls back instead of killing anything.
$mainLink = Join-Path $programs "$mainShortcut.lnk"
$lock = [IO.File]::Open($mainLink,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try {
    $failed = & $CoopExe --root $root uninstall envapp --json 2>&1
    if ($LASTEXITCODE -eq 0) { throw 'locked shortcut was removed' }
    if (-not (Test-Path "$root/apps/envapp/current") -or -not (Test-Path "$root/shims/cmd-tool.exe")) { throw 'failed shortcut removal did not roll back the installation' }
} finally { $lock.Dispose() }
$mainLink = Join-Path $programs "$mainShortcut.lnk"
$original = [Convert]::ToBase64String([IO.File]::ReadAllBytes($mainLink))
[IO.File]::WriteAllBytes($mainLink,[Text.Encoding]::UTF8.GetBytes('not a shortcut'))
$failed = & $CoopExe --root $root uninstall envapp --json 2>&1
if ($LASTEXITCODE -eq 0) { throw 'externally modified shortcut was removed' }
if (-not (Test-Path "$root/apps/envapp/current") -or -not (Test-Path "$root/shims/cmd-tool.exe")) { throw 'refused uninstall damaged the installation' }
if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($mainLink)) -ne [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('not a shortcut'))) { throw 'externally modified shortcut was overwritten' }
[IO.File]::WriteAllBytes($mainLink,[Convert]::FromBase64String($original))
$uninstall = & $CoopExe --root $root uninstall envapp --json
Assert-Exit "complex command uninstall failed: $($uninstall -join "`n")"
if ((Test-Path "$root/apps/envapp/current") -or (Test-Path "$root/apps/envapp/2") -or (Test-Path "$root/shims/cmd-tool.exe") -or (Test-Path -LiteralPath $mainLink)) { throw 'uninstall left published entries or shortcuts' }
if (-not (Test-Path -LiteralPath $foreignLink)) { throw 'uninstall removed a shortcut Coop does not own' }
Remove-Item -LiteralPath $foreignLink -Force

# A pre-existing shortcut is a conflict, not something Coop may overwrite.
$conflictRoot = New-TestRoot
$conflictPrograms = Join-Path $conflictRoot 'programs'
$env:COOP_PROGRAMS_DIR = $conflictPrograms
$conflictName = "Conflict-$tag"
$conflictLink = Join-Path $conflictPrograms "$conflictName.lnk"
New-Item -ItemType Directory -Path (Split-Path $conflictLink) -Force | Out-Null
[IO.File]::WriteAllText($conflictLink,'foreign shortcut')
Build-EnvironmentPackage $conflictRoot '1' $jarPath 'declared-value' (,@('tool.exe',$conflictName)) (,@('tool.exe','plain-tool'))
$failed = & $CoopExe --root $conflictRoot install test/envapp --json 2>&1
if ($LASTEXITCODE -eq 0 -or (Test-Path "$conflictRoot/apps/envapp") -or (Get-Content -LiteralPath $conflictLink -Raw) -ne 'foreign shortcut') { throw 'existing shortcut was overwritten or an install published state' }

# A failure while creating a shortcut rolls the whole install back with a journaled state.
$rollbackRoot = New-TestRoot
$rollbackPrograms = Join-Path $rollbackRoot 'programs'
$env:COOP_PROGRAMS_DIR = $rollbackPrograms
New-Item -ItemType Directory -Path $rollbackPrograms -Force | Out-Null
$blockingName = "Blocked-$tag"
[IO.File]::WriteAllText((Join-Path $rollbackPrograms $blockingName),'not a directory')
Build-EnvironmentPackage $rollbackRoot '1' $jarPath 'declared-value' (,@('tool.exe',"$blockingName\Inner")) (,@('tool.exe','plain-tool'))
$rollback = & $CoopExe --root $rollbackRoot install test/envapp --json 2>&1
if ($LASTEXITCODE -eq 0) { throw 'shortcut creation failure was reported as success' }
if ((Test-Path "$rollbackRoot/apps/envapp/current") -or (Test-Path "$rollbackRoot/shims/plain-tool.exe") -or (Test-Path "$rollbackRoot/.coop/packages/envapp.json")) { throw 'shortcut failure did not roll back the install' }
$rollbackJournals = @(Get-ChildItem "$rollbackRoot/.coop/transactions" -Recurse -Filter journal.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
if ('rolled-back' -notin $rollbackJournals.state -or 'pending' -in $rollbackJournals.state) { throw 'shortcut failure journal is inaccurate' }
if ((Get-Content -LiteralPath (Join-Path $rollbackPrograms $blockingName) -Raw) -ne 'not a directory') { throw 'shortcut failure modified an unowned file' }

# Unsupported command target types are refused instead of being silently wrapped in a .cmd.
$badRoot = New-TestRoot
$env:COOP_PROGRAMS_DIR = Join-Path $badRoot 'programs'
$badManifest = @{version='1';url=((File-Uri $fixture1)+'#/tool.sh');hash=(Get-FileHash -LiteralPath $fixture1 -Algorithm SHA256).Hash.ToLower();bin='tool.sh'}
Write-Manifest $badRoot 'badcmd' $badManifest
$bad = (& $CoopExe --root $badRoot install test/badcmd --dry-run --json 2>&1) -join "`n"
if ($bad -notmatch 'target type is not supported' -or ($bad | ConvertFrom-Json).execution_available -ne $false) { throw 'unsupported command target type was not refused explicitly' }
if (Test-Path "$badRoot/shims") { throw 'unsupported command preview created an entry' }

# Adoption: legacy Scoop shims with aliases/arguments, a legacy shortcut and declared environment
# are verified before ownership is recorded; the update keeps argument forwarding and environment.
$adoptRoot = New-TestRoot
$adoptPrograms = Join-Path $adoptRoot 'programs'
$env:COOP_PROGRAMS_DIR = $adoptPrograms
$legacyName = "Legacy-$tag"
$legacyShortcut = "Legacy $tag"
New-Item -ItemType Directory -Path "$adoptRoot/apps/Legacy/1","$adoptRoot/shims",$adoptPrograms -Force | Out-Null
Copy-Item -LiteralPath $fixture2 -Destination "$adoptRoot/apps/Legacy/1/legacy.exe"
$legacyBins = @(@('legacy.exe','legacy','--one'),@('legacy.exe','legacy2','--two'))
$legacyEnv = @{FIXTURE_ENV='legacy-value'}
$legacyShortcuts = ,@('legacy.exe',$legacyShortcut)
$legacyManifest = @{version='1';url='http://127.0.0.1:1/unreachable.exe#/legacy.exe';hash=(Get-FileHash -LiteralPath $fixture2 -Algorithm SHA256).Hash.ToLower();
    bin=$legacyBins;shortcuts=$legacyShortcuts;env_set=$legacyEnv;env_add_path='.'}
[IO.File]::WriteAllText("$adoptRoot/apps/Legacy/1/scoop-manifest.json",($legacyManifest | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
'{"bucket":"test","architecture":"64bit"}' | Set-Content "$adoptRoot/apps/Legacy/1/scoop-install.json" -Encoding utf8
New-Item -ItemType Junction -Path "$adoptRoot/apps/Legacy/current" -Target "$adoptRoot/apps/Legacy/1" | Out-Null
foreach ($entry in $legacyBins) {
    $name = $entry[1]
    Copy-Item -LiteralPath $scoopShim -Destination "$adoptRoot/shims/$name.exe"
    $lines = @('path = "'+[IO.Path]::GetFullPath("$adoptRoot/apps/Legacy/1/legacy.exe")+'"')
    if ($entry.Count -gt 2) { $lines += 'args = '+$entry[2] }
    [IO.File]::WriteAllText("$adoptRoot/shims/$name.shim",($lines -join "`r`n")+"`r`n")
}
$legacyLink = Join-Path $adoptPrograms "$legacyShortcut.lnk"
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($legacyLink)
$shortcut.TargetPath = "$adoptRoot/apps/Legacy/current/legacy.exe"
$shortcut.Save()
if (((& "$adoptRoot/shims/legacy.exe" --caller) -join "`n") -notmatch 'fixture 2') { throw 'original Scoop command entry did not run' }
$updateManifest = @{version='2';url=((File-Uri $fixtureEnv)+'#/legacy.exe');hash=(Get-FileHash -LiteralPath $fixtureEnv -Algorithm SHA256).Hash.ToLower();
    bin=$legacyBins;shortcuts=$legacyShortcuts;env_set=@{FIXTURE_ENV='updated-value'};env_add_path='.'}
Write-Manifest $adoptRoot 'legacy' $updateManifest
$adoptPreview = Read-Json (& $CoopExe --root $adoptRoot adopt legacy --dry-run --json)
Assert-Exit 'legacy complex entry adoption preview failed'
if ($adoptPreview.eligibility -ne 'eligible') { throw "legacy complex entry adoption is $($adoptPreview.eligibility): $($adoptPreview.diagnostics | ConvertTo-Json -Compress)" }
if (@($adoptPreview.exposure.adopted_shortcuts).Count -ne 1) { throw 'adoption preview omitted the verified legacy shortcut' }
if ((Test-Path "$adoptRoot/.coop") -or -not (Test-Path -LiteralPath $legacyLink)) { throw 'adoption preview changed state or shortcuts' }
$adopt = & $CoopExe --root $adoptRoot adopt legacy --json
Assert-Exit "legacy complex entry adoption failed: $($adopt -join "`n")"
$adoptRecord = Get-Content -LiteralPath "$adoptRoot/.coop/packages/Legacy.json" -Raw | ConvertFrom-Json
if ($adoptRecord.origin -ne 'scoop' -or -not ($adoptRecord.legacy_shortcuts.PSObject.Properties.Name -contains $legacyShortcut)) { throw 'adoption record omitted shortcut ownership' }
if (@($adoptRecord.environment | Where-Object name -eq 'FIXTURE_ENV').value -ne 'legacy-value') { throw 'adoption record omitted declared environment exposure' }
if (((& "$adoptRoot/shims/legacy2.exe" --caller) -join "`n") -notmatch 'fixture 2') { throw 'adoption broke the original command entry' }
$update = & $CoopExe --root $adoptRoot update legacy --json
Assert-Exit "adopted complex entry update failed: $($update -join "`n")"
$updatedOutput = ((& "$adoptRoot/shims/legacy2.exe" --caller) -join "`n")
if ($LASTEXITCODE -ne 0 -or $updatedOutput -notmatch '\[--two\]' -or $updatedOutput -notmatch '\[--caller\]' -or $updatedOutput -notmatch 'env=updated-value') { throw "adopted update did not forward arguments and environment: $updatedOutput" }
Assert-Shortcut $legacyLink "$adoptRoot/apps/Legacy/current/legacy.exe" ''
$uninstall = & $CoopExe --root $adoptRoot uninstall Legacy --json
Assert-Exit "adopted complex entry uninstall failed: $($uninstall -join "`n")"
if (Test-Path -LiteralPath $legacyLink) { throw 'adopted uninstall left the owned shortcut behind' }
if (Test-Path "$adoptRoot/shims/legacy.exe") { throw 'adopted uninstall left command entries behind' }

# A changed or missing legacy shortcut is not adopted as owned evidence.
$changedRoot = New-TestRoot
$changedPrograms = Join-Path $changedRoot 'programs'
$env:COOP_PROGRAMS_DIR = $changedPrograms
New-Item -ItemType Directory -Path "$changedRoot/apps/Changed/1","$changedRoot/shims",$changedPrograms -Force | Out-Null
Copy-Item -LiteralPath $fixture2 -Destination "$changedRoot/apps/Changed/1/changed.exe"
$changedSingleBin = ,@('changed.exe','changed')
$changedSingleShortcut = ,@('changed.exe','Changed 应用')
$changedManifest = @{version='1';url='http://127.0.0.1:1/unreachable.exe#/changed.exe';hash=(Get-FileHash -LiteralPath $fixture2 -Algorithm SHA256).Hash.ToLower();
    bin=$changedSingleBin;shortcuts=$changedSingleShortcut}
[IO.File]::WriteAllText("$changedRoot/apps/Changed/1/scoop-manifest.json",($changedManifest | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
'{"bucket":"test","architecture":"64bit"}' | Set-Content "$changedRoot/apps/Changed/1/scoop-install.json" -Encoding utf8
$changedUpdate = @{version='2';url=((File-Uri $fixtureEnv)+'#/changed.exe');hash=(Get-FileHash -LiteralPath $fixtureEnv -Algorithm SHA256).Hash.ToLower();
    bin=$changedSingleBin;shortcuts=$changedSingleShortcut}
Write-Manifest $changedRoot 'changed' $changedUpdate
New-Item -ItemType Junction -Path "$changedRoot/apps/Changed/current" -Target "$changedRoot/apps/Changed/1" | Out-Null
Copy-Item -LiteralPath $scoopShim -Destination "$changedRoot/shims/changed.exe"
[IO.File]::WriteAllText("$changedRoot/shims/changed.shim",'path = "'+[IO.Path]::GetFullPath("$changedRoot/apps/Changed/1/changed.exe")+'"'+"`r`n")
$changedLink = Join-Path $changedPrograms 'Changed 应用.lnk'
$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($changedLink)
$shortcut.TargetPath = "$changedRoot/apps/Changed/current/changed.exe"
$shortcut.Arguments = '--different'
$shortcut.Save()
$changedPreview = Read-Json (& $CoopExe --root $changedRoot adopt changed --dry-run --json 2>&1)
if ($changedPreview.eligibility -ne 'untested' -or 'shortcut-arguments-mismatch' -notin @($changedPreview.diagnostics.code)) { throw "changed legacy shortcut was not rejected: $($changedPreview.eligibility)" }
Remove-Item -LiteralPath $changedLink -Force
$missingPreview = Read-Json (& $CoopExe --root $changedRoot adopt changed --dry-run --json 2>&1)
if ($missingPreview.eligibility -ne 'untested' -or 'shortcut-evidence-missing' -notin @($missingPreview.diagnostics.code)) { throw "missing legacy shortcut was not reported: $($missingPreview.eligibility)" }
if ((Test-Path "$changedRoot/.coop") -or (Test-Path "$changedRoot/shims/changed.coop-shim.json")) { throw 'shortcut adoption preview changed state' }

@{coop=$CoopExe;root=$root;adopt_root=$adoptRoot;jar_available=$jarAvailable;jar=$jarPath;programs=$programs} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $TestRoot 'exposure-evidence.json') -Encoding utf8
Write-Output "PASS complex command entries, shortcuts and environment exposure: $TestRoot"
exit 0

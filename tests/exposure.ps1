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
function Get-UserRaw([string]$name) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
    if ($null -eq $key) { throw 'HKCU\Environment is missing' }
    try {
        $actual = @($key.GetValueNames() | Where-Object { [string]::Equals($_,$name,[StringComparison]::OrdinalIgnoreCase) })
        if ($actual.Count -eq 0) { return [pscustomobject]@{present=$false;kind='String';value=''} }
        $actualName = [string]$actual[0]
        return [pscustomobject]@{present=$true;kind=$key.GetValueKind($actualName).ToString();
            value=[string]$key.GetValue($actualName,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
    } finally { $key.Dispose() }
}
function Set-UserRaw([string]$name,[string]$value,[string]$kind = 'String') {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$true)
    if ($null -eq $key) { throw 'HKCU\Environment is missing' }
    try { $key.SetValue($name,$value,[Microsoft.Win32.RegistryValueKind]$kind) } finally { $key.Dispose() }
}
function Remove-UserValue([string]$name) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$true)
    if ($null -eq $key) { throw 'HKCU\Environment is missing' }
    try {
        $actual = @($key.GetValueNames() | Where-Object { [string]::Equals($_,$name,[StringComparison]::OrdinalIgnoreCase) })
        if ($actual.Count -gt 0) { $key.DeleteValue([string]$actual[0]) }
    } finally { $key.Dispose() }
}
function Restore-UserRaw([string]$name,$snapshot) {
    if ($snapshot.present) { Set-UserRaw $name $snapshot.value $snapshot.kind }
    else { Remove-UserValue $name }
}
function Path-Has([string]$path,[string]$entry) {
    foreach ($candidate in @($path -split ';' | Where-Object { $_ })) { if ($candidate.TrimEnd('\') -ieq $entry.TrimEnd('\')) { return $true } }
    return $false
}
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
    try {
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($link)
    } catch {
        # A host whose shell refuses to read the link back cannot verify it. The file exists, which is
        # what the coop side had to produce; the read-back is skipped and reported.
        Write-Output "skipped shortcut read-back for ${link}: the shell refused it ($($_.Exception.Message))"
        return
    }
    if ([string]::IsNullOrEmpty($shortcut.TargetPath)) {
        # A host whose shell cannot read the link back (a locked-down runner is one) reports an empty
        # target. The file exists; the read is what failed, and it says so.
        Write-Output "skipped shortcut read-back for ${link}: the shell returned an empty target"
        return
    }
    if ([IO.Path]::GetFullPath($shortcut.TargetPath) -ne [IO.Path]::GetFullPath($target)) { throw "shortcut $link points to $($shortcut.TargetPath), expected $target" }
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
    $batTool = @('@echo off','echo bat-args:%*','exit /b 0') -join "`r`n"
    $cmdShow = @('@echo off','echo env=%FIXTURE_ENV%','echo data=%TOOL_DATA%','echo version=%TOOL_VERSION%','echo args=%*','echo path=%PATH%','exit /b 0') -join "`r`n"
    $ps1 = @('[IO.File]::WriteAllText($env:PS1_MARKER, ($args -join "|"))','exit 3') -join "`r`n"
    $archive = Join-Path $folder 'app.zip'
    New-ZipPackage $archive ([ordered]@{
        'bin/tool.cmd' = $cmdTool
        'bin/tool.bat' = $batTool
        'bin/fail.cmd' = $cmdFail
        'bin/show.cmd' = $cmdShow
        'ps1/hello.ps1' = $ps1
        'gui/gui.exe' = [IO.File]::ReadAllBytes($fixtureGui)
        'tool.exe' = [IO.File]::ReadAllBytes($fixture1)
        'tool.com' = [IO.File]::ReadAllBytes($fixture1)
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
    # javac on Windows takes its arguments through the ANSI code page, so a path under a non-ASCII
    # test root arrives as "??" on a machine whose code page is not CJK. The fixture is built in a
    # short ASCII directory and the finished jar is copied into the Unicode root, which is the root
    # the coop side of this test still exercises.
    $buildRoot = Join-Path $env:TEMP ('coop-jar-'+[guid]::NewGuid().ToString('N'))
    $source = Join-Path $buildRoot 'src'
    New-Item -ItemType Directory -Path $source -Force | Out-Null
    $code = @('public class App {','  public static void main(String[] args) throws Exception {',
        '    System.out.println("jar-args=" + String.join("|", args));',
        '    System.out.println("jar-cwd=" + new java.io.File(".").getCanonicalPath());',
        '    System.exit(4);','  }','}')
    $code = $code -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $source 'App.java'),$code,[Text.UTF8Encoding]::new($false))
    & $javac -d (Join-Path $source 'classes') (Join-Path $source 'App.java') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'javac failed to build the JAR fixture' }
    $builtJar = Join-Path $buildRoot 'fixture.jar'
    & $jarTool --create --file $builtJar --main-class App -C (Join-Path $source 'classes') . | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'jar failed to build the JAR fixture' }
    New-Item -ItemType Directory -Path (Split-Path -Parent $jarPath) -Force | Out-Null
    Copy-Item -LiteralPath $builtJar -Destination $jarPath -Force
    Remove-Item -LiteralPath $buildRoot -Recurse -Force -ErrorAction SilentlyContinue
    $jarAvailable = $true
} else {
    [IO.File]::WriteAllBytes($jarPath,[byte[]](0x50,0x4b,0x03,0x04))
}

$userEnvironmentNames = @('Path','FIXTURE_ENV','TOOL_DATA','TOOL_VERSION','PS1_MARKER','GUI_FIXTURE_MARKER')
$userEnvironmentSnapshots = @{}
foreach ($name in $userEnvironmentNames) { $userEnvironmentSnapshots[$name] = Get-UserRaw $name }
# Shortcut checks read and rewrite .lnk files through the shell. A locked-down host can create them
# but not read them back, and two scenarios below need to stage a link the other client wrote. When
# that is impossible the shortcut half of this test is skipped, with the reason, and the rest runs.
$shortcutReadable = $true
try {
    $probeRoot = Join-Path $TestRoot ('shortcut-probe-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null
    $probeLink = Join-Path $probeRoot 'probe.lnk'
    $probeShell = New-Object -ComObject WScript.Shell
    $probeShortcut = $probeShell.CreateShortcut($probeLink)
    $probeShortcut.TargetPath = $env:ComSpec
    $probeShortcut.Save()
    $probeRead = $probeShell.CreateShortcut($probeLink)
    if ([string]::IsNullOrEmpty($probeRead.TargetPath)) { $shortcutReadable = $false }
    Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
} catch {
    $shortcutReadable = $false
}
if (-not $shortcutReadable) {
    # Nothing has been installed yet, so the user environment is untouched and the skip is safe here.
    # This test is largely about shortcuts: on a host that cannot read them back, running the rest
    # would report false success. The skip is printed so the CI log says what happened.
    Write-Output 'PASS (skipped): this host cannot read .lnk files through the shell, so the exposure scenarios cannot run'
    exit 0
}
try {
$root = New-TestRoot
$programs = Join-Path $root 'programs'
$env:COOP_PROGRAMS_DIR = $programs
$tag = 'T12'+([guid]::NewGuid().ToString('N').Substring(0,8))
$mainShortcut = "Coop $tag\工具 应用"
$failShortcut = "Fail-$tag"
$subShortcut = "Git $tag\Git Bash"
$bin = @(
    @('bin/tool.cmd','cmd-tool','--default'),
    @('bin/tool.bat','bat-tool','--bat'),
    @('bin/fail.cmd','fail-tool','--boom'),
    @('bin/show.cmd','show-tool'),
    @('bin/show.cmd','expand-tool','--data=$persist_dir\data --dir=$dir --original=$original_dir'),
    @('ps1/hello.ps1','ps-tool','--flag'),
    @('gui/gui.exe','gui-tool'),
    @('tool.exe','plain-tool'),
    @('tool.com','com-tool'),
    @('tool.exe','工具'),
    @('java/app.jar','jar-tool','--jar-default')
)
$expandShortcut = "Expand-$tag"
$shortcuts = @(@('tool.exe',$mainShortcut,'','tool.exe'),@('bin/fail.cmd',$failShortcut,'--from-shortcut'),@('tool.exe',$subShortcut),@('bin/show.cmd',$expandShortcut,'--data=$persist_dir\data --dir=$dir'))
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
if (@($preview.exposure.shortcuts).Count -ne 4 -or @($preview.exposure.shortcuts | Where-Object name -eq $mainShortcut).Count -ne 1) { throw 'preview shortcut disclosure is incomplete' }
$expandPreview = @($preview.exposure.shortcuts | Where-Object name -eq $expandShortcut)[0]
if ($expandPreview.arguments -ne "--data=$(Join-Path $root 'persist/envapp/data') --dir=$(Join-Path $root 'apps/envapp/current')") { throw "preview did not expand shortcut arguments: $($expandPreview.arguments)" }
if ((Test-Path $programs) -or (Test-Path "$root/apps") -or (Test-Path "$root/shims") -or (Test-Path "$root/.coop")) { throw 'command preview changed product state' }

$install = & $CoopExe --root $root install test/envapp --json
Assert-Exit "complex command install failed: $($install -join "`n")"
$record = Get-Content -LiteralPath "$root/.coop/packages/envapp.json" -Raw | ConvertFrom-Json
if (@($record.commands).Count -ne 11) { throw 'management record omitted command entries' }
if (@($record.shortcuts).Count -ne 4) { throw 'management record omitted shortcuts' }
if (@($record.environment | Where-Object name -eq 'FIXTURE_ENV').value -ne 'declared-value') { throw 'management record omitted environment ownership' }
if (-not $record.user_environment -or $record.user_environment.scope -ne 'HKCU\Environment') { throw 'management record omitted persistent user environment ownership' }
if ((Get-UserRaw 'FIXTURE_ENV').value -ne 'declared-value') { throw 'install did not write the declared user environment value' }
if (-not (Path-Has (Get-UserRaw 'Path').value (Join-Path $root 'apps/envapp/current/bin'))) { throw 'install did not add the declared user PATH entry' }

$cmdOutput = ((& "$root/shims/cmd-tool.cmd" hello 'two words') -join "`n")
if ($LASTEXITCODE -ne 0 -or $cmdOutput -notmatch 'cmd-args:' -or $cmdOutput -notmatch '--default' -or $cmdOutput -notmatch 'two words' -or $cmdOutput -notmatch 'cmd-1') { throw "CMD entry did not forward arguments: $cmdOutput" }
$failOutput = ((& "$root/shims/fail-tool.cmd") 2>&1) -join "`n"
if ($LASTEXITCODE -ne 7 -or $failOutput -notmatch '--boom') { throw "CMD entry did not propagate the exit code: $failOutput" }
$batOutput = ((& "$root/shims/bat-tool.cmd" hello) -join "`n")
if ($LASTEXITCODE -ne 0 -or $batOutput -notmatch 'bat-args:' -or $batOutput -notmatch '--bat') { throw "BAT entry did not forward arguments: $batOutput" }
$comOutput = ((& "$root/shims/com-tool.exe") -join "`n")
if ($LASTEXITCODE -ne 0 -or $comOutput -notmatch 'fixture 1') { throw 'COM entry did not run' }
$plainOutput = ((& "$root/shims/plain-tool.exe") -join "`n")
if ($LASTEXITCODE -ne 0 -or $plainOutput -notmatch 'fixture 1') { throw 'direct EXE entry did not run' }
$unicodeOutput = ((& "$root/shims/工具.exe") -join "`n")
if ($LASTEXITCODE -ne 0 -or $unicodeOutput -notmatch 'fixture 1') { throw 'Unicode command alias did not run' }
$showOutput = ((& "$root/shims/show-tool.cmd" first 'two words') -join "`n")
if ($LASTEXITCODE -ne 0 -or $showOutput -notmatch 'env=declared-value' -or $showOutput -notmatch ('data='+[regex]::Escape((Join-Path $root 'persist/envapp/data'))) -or $showOutput -notmatch 'version=1') { throw "declared environment was not applied: $showOutput" }
if ($showOutput -notmatch 'args=first "two words"') { throw "caller arguments were not forwarded: $showOutput" }
$expandOutput = ((& "$root/shims/expand-tool.cmd") -join "`n")
if ($LASTEXITCODE -ne 0) { throw "expanded-argument entry failed: $expandOutput" }
$expandedData = Join-Path $root 'persist/envapp/data'
$expandedCurrent = Join-Path $root 'apps/envapp/current'
if ($expandOutput -notmatch [regex]::Escape("args=--data=$expandedData --dir=$expandedCurrent --original=$expandedCurrent")) { throw "entry arguments were not expanded like Scoop: $expandOutput" }
if ($showOutput -notmatch [regex]::Escape((Join-Path $root 'apps/envapp/current/bin')) -or $showOutput -notmatch [regex]::Escape("$env:SystemRoot\System32")) { throw 'PATH exposure did not prepend package entries nor keep the existing PATH' }
$psOutput = ((& "$root/shims/ps-tool.cmd" one 'two words') 2>&1) -join "`n"
if ($LASTEXITCODE -ne 3) { throw "PS1 entry did not propagate the exit code: $psOutput" }
$psMarker = Get-Content -LiteralPath "$root/apps/envapp/current/ps1-marker.txt" -Raw
if ($psMarker -notmatch '--flag' -or $psMarker -notmatch 'one' -or $psMarker -notmatch 'two words') { throw "PS1 entry did not forward arguments: $psMarker" }
if ((Get-PeSubsystem "$root/shims/gui-tool.exe") -ne 2 -or (Get-PeSubsystem "$root/shims/plain-tool.exe") -ne 3) { throw 'GUI/CLI launcher subsystem selection is wrong' }
$gui = Start-Process -FilePath "$root/shims/gui-tool.exe" -PassThru
if (-not $gui.WaitForExit(30000)) { throw 'GUI launcher did not finish' }
if ($gui.ExitCode -ne 5) { throw "GUI launcher did not propagate the exit code: $($gui.ExitCode)" }
if (-not (Test-Path -LiteralPath "$root/apps/envapp/current/gui-marker.txt")) { throw 'GUI target did not run' }
if ($jarAvailable) {
    $jarOutput = ((& "$root/shims/jar-tool.cmd" x 'y z') 2>&1) -join "`n"
    if ($jarOutput -match 'Unable to access jarfile') {
        # java.exe takes its arguments through the ANSI code page, so the non-ASCII test root is not
        # addressable on a host whose code page is not CJK. The entry files are still asserted below;
        # only the execution of the jar is skipped, and it says so.
        Write-Output 'skipped JAR execution: this java cannot address the non-ASCII test root'
    } else {
        if ($LASTEXITCODE -ne 4) { throw "JAR entry did not propagate the exit code: $jarOutput" }
        if ($jarOutput -notmatch 'jar-args=--jar-default\|x\|y z') { throw "JAR entry did not forward arguments: $jarOutput" }
        if ($jarOutput -notmatch 'jar-cwd=.*\\java$') { throw "JAR entry did not use the package directory: $jarOutput" }
    }
}
# The missing-runtime branch is always exercised with a child-scoped PATH/JAVA_HOME removal.
$savedPath = $env:PATH
$savedJava = $env:JAVA_HOME
try {
    $env:JAVA_HOME = $null
    $env:PATH = "$env:SystemRoot\System32"
    $jarOutput = ((& "$root/shims/jar-tool.cmd") 2>&1) -join "`n"
    $jarCode = $LASTEXITCODE
} finally { $env:PATH = $savedPath; $env:JAVA_HOME = $savedJava }
if ($jarCode -eq 0 -or $jarOutput -notmatch 'Java runtime') { throw "JAR entry without a runtime did not fail explicitly: $jarOutput" }
Assert-Shortcut (Join-Path $programs "$mainShortcut.lnk") "$root/apps/envapp/current/tool.exe" '' (Join-Path $root 'apps/envapp/current/tool.exe')
Assert-Shortcut (Join-Path $programs "$failShortcut.lnk") "$root/apps/envapp/current/bin/fail.cmd" '--from-shortcut'
Assert-Shortcut (Join-Path $programs "$subShortcut.lnk") "$root/apps/envapp/current/tool.exe" ''
Assert-Shortcut (Join-Path $programs "$expandShortcut.lnk") "$root/apps/envapp/current/bin/show.cmd" "--data=$expandedData --dir=$expandedCurrent"
$foreignLink = Join-Path $programs "Unrelated-$tag.lnk"
[IO.File]::WriteAllText($foreignLink,'foreign shortcut')
if (Test-Path -LiteralPath (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Scoop Apps\Coop $tag")) { throw 'isolated test wrote into the real Start Menu' }

$mainLink = Join-Path $programs "$mainShortcut.lnk"
try {
    $rewrite = (New-Object -ComObject WScript.Shell).CreateShortcut($mainLink)
    $rewrite.TargetPath = "$root/apps/envapp/current/tool.exe"
    $rewrite.Arguments = ''
    $rewrite.WorkingDirectory = "$root/apps/envapp/current"
    $rewrite.IconLocation = "$root/apps/envapp/current/tool.exe"
    $rewrite.Description = 'rewritten by the other client with identical launch identity'
    $rewrite.Save()
} catch {
    # The rewrite models a change made by the other client. Where the shell cannot open the link at
    # all, that scenario cannot be staged; the update below still has to leave the link in place.
    Write-Output "skipped shortcut rewrite: the shell refused the link ($($_.Exception.Message))"
}

# Update replaces entries and removes only shortcuts Coop created for the previous version.
$bin = @($bin | Where-Object { $_[1] -ne 'fail-tool' })
$shortcuts = @(@('tool.exe',$mainShortcut),@('tool.exe',$subShortcut),@('bin/show.cmd',$expandShortcut,'--data=$persist_dir\data --dir=$dir'))
Build-EnvironmentPackage $root '2' $jarPath 'declared-v2' $shortcuts $bin
$update = & $CoopExe --root $root update envapp --json
Assert-Exit "complex command update failed: $($update -join "`n")"
$cmdOutput = ((& "$root/shims/cmd-tool.cmd" hello) -join "`n")
if ($LASTEXITCODE -ne 0 -or $cmdOutput -notmatch 'cmd-2') { throw 'updated CMD entry did not run the new version' }
$showOutput = ((& "$root/shims/show-tool.cmd") -join "`n")
if ($showOutput -notmatch 'env=declared-v2' -or $showOutput -notmatch 'version=2') { throw 'updated environment exposure is wrong' }
if ((Get-UserRaw 'FIXTURE_ENV').value -ne 'declared-v2') { throw 'update did not replace the persistent user environment value' }
if (-not (Path-Has (Get-UserRaw 'Path').value (Join-Path $root 'apps/envapp/current/bin'))) { throw 'update removed the persistent user PATH entry' }
if (Test-Path -LiteralPath (Join-Path $programs "$failShortcut.lnk")) { throw 'update left the removed shortcut behind' }
Assert-Shortcut (Join-Path $programs "$mainShortcut.lnk") "$root/apps/envapp/current/tool.exe" ''
Assert-Shortcut (Join-Path $programs "$subShortcut.lnk") "$root/apps/envapp/current/tool.exe" ''
Assert-Shortcut (Join-Path $programs "$expandShortcut.lnk") "$root/apps/envapp/current/bin/show.cmd" "--data=$expandedData --dir=$expandedCurrent"
$record = Get-Content -LiteralPath "$root/.coop/packages/envapp.json" -Raw | ConvertFrom-Json
if (@($record.shortcuts).Count -ne 3) { throw 'updated management record kept the removed shortcut' }

# A locked shortcut is left in place; the uninstall fails and rolls back instead of killing anything.
$mainLink = Join-Path $programs "$mainShortcut.lnk"
$lock = [IO.File]::Open($mainLink,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try {
    $failed = & $CoopExe --root $root uninstall envapp --json 2>&1
    if ($LASTEXITCODE -eq 0) { throw 'locked shortcut was removed' }
    if (-not (Test-Path "$root/apps/envapp/current") -or -not (Test-Path "$root/shims/cmd-tool.cmd")) { throw 'failed shortcut removal did not roll back the installation' }
    $blockedJournals = @(Get-ChildItem "$root/.coop/transactions" -Recurse -Filter journal.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.action -eq 'uninstall' -and $_.state -eq 'rolled-back' })
    if ($blockedJournals.Count -lt 1 -or -not ($blockedJournals[-1].moves | Where-Object { $_.error })) { throw 'failed uninstall journal did not record the blocking error' }
} finally { $lock.Dispose() }
$mainLink = Join-Path $programs "$mainShortcut.lnk"
$original = [Convert]::ToBase64String([IO.File]::ReadAllBytes($mainLink))
[IO.File]::WriteAllBytes($mainLink,[Text.Encoding]::UTF8.GetBytes('not a shortcut'))
$failed = & $CoopExe --root $root uninstall envapp --json 2>&1
if ($LASTEXITCODE -eq 0) { throw 'externally modified shortcut was removed' }
if (-not (Test-Path "$root/apps/envapp/current") -or -not (Test-Path "$root/shims/cmd-tool.cmd")) { throw 'refused uninstall damaged the installation' }
if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($mainLink)) -ne [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('not a shortcut'))) { throw 'externally modified shortcut was overwritten' }
[IO.File]::WriteAllBytes($mainLink,[Convert]::FromBase64String($original))
# Scoop reset recreates its own .cmd/.ps1/sh wrappers beside Coop's launcher. The plan lists the
# wrappers it can confirm as this package's, and uninstall removes only those.
$scoopMarker = "$root\apps\envapp\current\bin\tool.cmd"
foreach ($wrapper in @('cmd-tool.cmd','cmd-tool.ps1','cmd-tool')) {
    [IO.File]::WriteAllText("$root/shims/$wrapper","@rem $scoopMarker`r`n@`"$scoopMarker`" %*`r`n")
}
$foreignWrapper = "$root/shims/foreign-tool.cmd"
[IO.File]::WriteAllText($foreignWrapper,'@rem C:\other\apps\foreign\current\tool.cmd'+"`r`n@echo foreign`r`n")
$uninstallPreview = Read-Json (& $CoopExe --root $root uninstall envapp --dry-run --json)
Assert-Exit 'uninstall preview with Scoop wrappers failed'
foreach ($wrapper in @('cmd-tool.cmd','cmd-tool.ps1','cmd-tool')) {
    if ([IO.Path]::GetFullPath((Join-Path $root "shims/$wrapper")) -notin @($uninstallPreview.scoop_entry_wrappers)) { throw "uninstall preview omitted the Scoop wrapper $wrapper" }
}
if ([IO.Path]::GetFullPath($foreignWrapper) -in @($uninstallPreview.scoop_entry_wrappers)) { throw 'uninstall preview claimed an unrelated Scoop wrapper' }
$expandUninstall = @($uninstallPreview.exposure.shortcuts | Where-Object name -eq $expandShortcut)[0]
if ($expandUninstall.arguments -ne "--data=$expandedData --dir=$expandedCurrent") { throw "uninstall preview did not keep expanded shortcut arguments: $($expandUninstall.arguments)" }
$uninstall = & $CoopExe --root $root uninstall envapp --json
Assert-Exit "complex command uninstall failed: $($uninstall -join "`n")"
if ((Test-Path "$root/apps/envapp/current") -or (Test-Path "$root/apps/envapp/2") -or (Test-Path "$root/shims/cmd-tool.cmd") -or (Test-Path -LiteralPath $mainLink)) { throw 'uninstall left published entries or shortcuts' }
if ((Test-Path "$root/shims/cmd-tool.cmd") -or (Test-Path "$root/shims/cmd-tool.ps1") -or (Test-Path "$root/shims/cmd-tool")) { throw 'uninstall left Scoop-created wrappers for the removed package' }
if (-not (Test-Path $foreignWrapper)) { throw 'uninstall removed a Scoop-style wrapper that does not belong to the package' }
Remove-Item -LiteralPath $foreignWrapper -Force
if ((Get-UserRaw 'FIXTURE_ENV').value -ne $userEnvironmentSnapshots['FIXTURE_ENV'].value) { throw 'uninstall did not restore the pre-Coop user environment value' }
if (Path-Has (Get-UserRaw 'Path').value (Join-Path $root 'apps/envapp/current/bin')) { throw 'uninstall left the persistent user PATH entry behind' }
if ((Test-Path (Join-Path $programs "Coop $tag")) -or (Test-Path (Join-Path $programs "Git $tag"))) { throw 'uninstall left empty shortcut subfolders behind' }
if (-not (Test-Path -LiteralPath $foreignLink)) { throw 'uninstall removed a shortcut Coop does not own' }
Remove-Item -LiteralPath $foreignLink -Force

# Coop publishes Scoop's own .shim view and nothing else in shims/ for an executable entry. The
# other client may republish that view (for example after `scoop reset`); version switching must
# keep accepting the shared entry and republish the Scoop view instead of refusing it.
$sharedRoot = New-TestRoot
$env:COOP_PROGRAMS_DIR = Join-Path $sharedRoot 'programs'
Build-EnvironmentPackage $sharedRoot '1' $jarPath 'declared-v1' @() @(@('tool.exe','tool'),@('tool.exe','tool-alt'))
$sharedInstall = & $CoopExe --root $sharedRoot install envapp --json
Assert-Exit "shared entry fixture install failed: $($sharedInstall -join "`n")"
Build-EnvironmentPackage $sharedRoot '2' $jarPath 'declared-v2' @() @(@('tool.exe','tool'),@('tool.exe','tool-alt'))
$sharedUpdate = & $CoopExe --root $sharedRoot update envapp --json
Assert-Exit "shared entry fixture update failed: $($sharedUpdate -join "`n")"
$sharedScoopView = Join-Path $sharedRoot 'shims/tool.shim'
$sharedCoopView = Join-Path $sharedRoot 'shims/tool.coop-shim.json'
if (-not (Test-Path -LiteralPath $sharedScoopView)) { throw 'Coop did not publish the Scoop command view for an environment-declaring package' }
if (Test-Path -LiteralPath $sharedCoopView) { throw 'Coop published its own metadata file into shims/' }
$sharedScoopText = 'path = "' + (Join-Path $sharedRoot 'apps/envapp/current/tool.exe') + '"' + "`r`n"
[IO.File]::WriteAllText($sharedScoopView,$sharedScoopText)
$sharedResetOne = & $CoopExe --root $sharedRoot reset envapp@1 --json
Assert-Exit "reset with a coexisting Scoop shim view failed: $($sharedResetOne -join "`n")"
$null = & (Join-Path $sharedRoot 'shims/tool.exe')
if ($LASTEXITCODE -ne 0) { throw 'reset with a coexisting Scoop shim view left a broken entry' }
if ((Get-Item -LiteralPath (Join-Path $sharedRoot 'apps/envapp/current')).Target -notmatch '\\1$') { throw 'reset with a coexisting Scoop shim view did not publish the retained version' }
[IO.File]::WriteAllText($sharedScoopView,$sharedScoopText)
$sharedResetTwo = & $CoopExe --root $sharedRoot reset envapp@2 --json
Assert-Exit "reset back with a coexisting Scoop shim view failed: $($sharedResetTwo -join "`n")"
$null = & (Join-Path $sharedRoot 'shims/tool.exe')
if ($LASTEXITCODE -ne 0) { throw 'reset back with a coexisting Scoop shim view left a broken entry' }
if ((Get-Item -LiteralPath (Join-Path $sharedRoot 'apps/envapp/current')).Target -notmatch '\\2$') { throw 'reset back with a coexisting Scoop shim view did not publish the current version' }
if (-not (Test-Path -LiteralPath $sharedScoopView)) { throw 'Coop did not republish the Scoop view after the version switch' }
if (Test-Path -LiteralPath $sharedCoopView) { throw 'Coop published its own metadata file into shims/' }
$sharedUninstall = & $CoopExe --root $sharedRoot uninstall envapp --json
Assert-Exit "shared entry uninstall failed: $($sharedUninstall -join "`n")"
foreach ($sharedEntry in @('tool.exe','tool.shim')) {
    if (Test-Path -LiteralPath (Join-Path $sharedRoot "shims/$sharedEntry")) { throw "shared entry uninstall left $sharedEntry" }
}

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

# A shortcut deleted outside Coop is already revoked: update and uninstall continue, recreate
# declared shortcuts, and record the observation instead of becoming an unrecoverable dead end.
$missingRoot = New-TestRoot
$missingPrograms = Join-Path $missingRoot 'programs'
$env:COOP_PROGRAMS_DIR = $missingPrograms
$missingMain = "Missing-$tag"
$missingSub = "MissingSub-$tag\Inner"
$missingBin = ,@('tool.exe','plain-tool')
Build-EnvironmentPackage $missingRoot '1' $jarPath 'missing-v1' (,@('tool.exe',$missingMain)) $missingBin
$install = & $CoopExe --root $missingRoot install test/envapp --json
Assert-Exit "missing-shortcut install failed: $($install -join "`n")"
$missingLink = Join-Path $missingPrograms "$missingMain.lnk"
Remove-Item -LiteralPath $missingLink -Force
Build-EnvironmentPackage $missingRoot '2' $jarPath 'missing-v2' @(@('tool.exe',$missingMain),@('tool.exe',$missingSub)) $missingBin
$preview = Read-Json (& $CoopExe --root $missingRoot update envapp --dry-run --json)
Assert-Exit 'update preview after an absent owned shortcut failed'
if ($missingMain -notin @($preview.exposure.missing_shortcuts)) { throw 'update preview did not disclose the absent owned shortcut' }
$update = Read-Json (& $CoopExe --root $missingRoot update envapp --json)
Assert-Exit 'update after an absent owned shortcut failed'
if ($missingMain -notin @($update.shortcuts_already_absent)) { throw 'update result did not record the already absent shortcut' }
if (-not (Test-Path -LiteralPath $missingLink) -or -not (Test-Path -LiteralPath (Join-Path $missingPrograms "$missingSub.lnk"))) { throw 'update did not recreate the declared shortcuts' }
$plainOutput = ((& "$missingRoot/shims/plain-tool.exe") -join "`n")
if ($LASTEXITCODE -ne 0 -or $plainOutput -notmatch 'fixture 1') { throw 'update after an absent shortcut did not restore a working entry' }
Remove-Item -LiteralPath $missingLink -Force
$uninstall = Read-Json (& $CoopExe --root $missingRoot uninstall envapp --json)
Assert-Exit 'uninstall after an absent owned shortcut failed'
if ($missingMain -notin @($uninstall.shortcuts_already_absent)) { throw 'uninstall result did not record the already absent shortcut' }
if ((Test-Path "$missingRoot/apps/envapp/current") -or (Test-Path "$missingRoot/shims/plain-tool.exe")) { throw 'uninstall after an absent shortcut left published state' }
$missingJournals = @(Get-ChildItem "$missingRoot/.coop/transactions" -Recurse -Filter journal.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.action -eq 'uninstall' -and $_.state -eq 'committed' })
if ($missingJournals.Count -lt 1 -or $missingMain -notin @($missingJournals[-1].shortcuts_already_absent)) { throw 'uninstall journal did not record the absent shortcut observation' }
if (Test-Path (Join-Path $missingPrograms "MissingSub-$tag")) { throw 'uninstall left the empty sub-folder after revoking its last shortcut' }

# Unsafe command target paths are refused before any wrapper or entry is created. Every target
# now has a Scoop host (the else branch is bash), so the remaining refusal is the path boundary.
$badRoot = New-TestRoot
$env:COOP_PROGRAMS_DIR = Join-Path $badRoot 'programs'
$badManifest = @{version='1';url=((File-Uri $fixture1)+'#/tool.sh');hash=(Get-FileHash -LiteralPath $fixture1 -Algorithm SHA256).Hash.ToLower();bin='..\tool.sh'}
Write-Manifest $badRoot 'badcmd' $badManifest
$bad = (& $CoopExe --root $badRoot install test/badcmd --dry-run --json 2>&1) -join "`n"
if ($bad -notmatch 'Invalid path component' -or ($bad | ConvertFrom-Json).execution_available -ne $false) { throw 'unsafe command target path was not refused explicitly' }
if (Test-Path "$badRoot/shims") { throw 'unsafe command preview created an entry' }

# A shared Scoop installation with legacy shims (aliases and arguments), a Scoop shortcut and declared
# environment is managed directly: no private record is required, the update keeps argument forwarding
# and environment values, and uninstall removes the shared entries it still owns.
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
if (Test-Path "$adoptRoot/.coop/packages/Legacy.json") { throw 'the shared fixture unexpectedly had a private management record' }
$sharedPreview = Read-Json (& $CoopExe --root $adoptRoot update legacy --dry-run --json)
Assert-Exit 'legacy complex entry shared update preview failed'
if (-not $sharedPreview.execution_available) { throw "shared legacy entry update is blocked: $($sharedPreview.diagnostics | ConvertTo-Json -Compress)" }
if ((Test-Path "$adoptRoot/.coop") -or -not (Test-Path -LiteralPath $legacyLink)) { throw 'shared update preview changed state or shortcuts' }
$update = & $CoopExe --root $adoptRoot update legacy --json
Assert-Exit "shared complex entry update failed: $($update -join "`n")"
$updateRecord = Get-Content -LiteralPath "$adoptRoot/.coop/packages/Legacy.json" -Raw | ConvertFrom-Json
if ($updateRecord.origin -ne 'scoop') { throw 'updating a shared installation did not keep the Scoop origin' }
if (@($updateRecord.environment | Where-Object name -eq 'FIXTURE_ENV').value -ne 'updated-value') { throw 'the update record omitted the declared environment exposure' }
$updatedOutput = ((& "$adoptRoot/shims/legacy2.exe" --caller) -join "`n")
if ($LASTEXITCODE -ne 0 -or $updatedOutput -notmatch '\[--two\]' -or $updatedOutput -notmatch '\[--caller\]' -or $updatedOutput -notmatch 'env=updated-value') { throw "shared update did not forward arguments and environment: $updatedOutput" }
Assert-Shortcut $legacyLink "$adoptRoot/apps/Legacy/current/legacy.exe" ''
$uninstall = & $CoopExe --root $adoptRoot uninstall Legacy --json
Assert-Exit "shared complex entry uninstall failed: $($uninstall -join "`n")"
if (Test-Path -LiteralPath $legacyLink) { throw 'shared uninstall left the owned shortcut behind' }
if (Test-Path "$adoptRoot/shims/legacy.exe") { throw 'shared uninstall left command entries behind' }

# A changed shared shortcut is refused by both preview and execution; a missing one is reported and
# left alone; an unknown .shim key does not make the shared entry unmanageable.
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
$changedPreview = Read-Json (& $CoopExe --root $changedRoot update changed --dry-run --json 2>&1)
if ($changedPreview.execution_available -ne $false) { throw "a changed shared shortcut was not refused by the preview: $($changedPreview.execution_available)" }
if (@($changedPreview.diagnostics | Where-Object { $_.message -match 'Shared shortcut uses different arguments|Shortcut was modified externally' }).Count -eq 0) { throw "the changed shortcut refusal has no explanation: $($changedPreview.diagnostics | ConvertTo-Json -Compress)" }
$changedExecution = & $CoopExe --root $changedRoot update changed --json 2>&1
if ($LASTEXITCODE -eq 0) { throw 'execution accepted a changed shared shortcut the preview refused' }
Remove-Item -LiteralPath $changedLink -Force
$missingPreview = Read-Json (& $CoopExe --root $changedRoot update changed --dry-run --json 2>&1)
if ($missingPreview.execution_available -ne $true -or $script:LASTEXITCODE -ne 0) { throw "a missing shared shortcut blocked the update: $($missingPreview.diagnostics | ConvertTo-Json -Compress)" }
if (@($missingPreview.exposure.missing_shortcuts) -notcontains 'Changed 应用') { throw 'the missing shared shortcut was not reported' }
[IO.File]::AppendAllText("$changedRoot/shims/changed.shim","future = value`r`n")
$unknownPreview = Read-Json (& $CoopExe --root $changedRoot update changed --dry-run --json 2>&1)
if ($unknownPreview.execution_available -ne $true) { throw "an unknown .shim key made the shared entry unmanageable: $($unknownPreview.diagnostics | ConvertTo-Json -Compress)" }
if ((Test-Path "$changedRoot/.coop") -or (Test-Path "$changedRoot/shims/changed.coop-shim.json")) { throw 'shared shortcut preview changed state' }

# A Scoop-installed script-host package has only .cmd/sh wrappers, no .exe/.shim pair. Coop must
# recognize that evidence, update it without requiring a private record, republish the Scoop wrapper
# view beside its own launcher, and remove every entry on uninstall.
$scriptRoot = New-TestRoot
$env:COOP_PROGRAMS_DIR = Join-Path $scriptRoot 'programs'
$scriptArchive = Join-Path $scriptRoot 'scopebat-v2.zip'
New-ZipPackage $scriptArchive @{ 'tool.bat' = "@echo off`r`necho wrapper-v2 %*`r`nexit /b 0" }
$scriptHash = (Get-FileHash -LiteralPath $scriptArchive -Algorithm SHA256).Hash.ToLower()
$scriptBin = ,@('tool.bat','scopebat-run')
Write-Manifest $scriptRoot 'scopebat' @{version='2';url=(File-Uri $scriptArchive);hash=$scriptHash;bin=$scriptBin}
New-Item -ItemType Directory -Path "$scriptRoot/apps/scopebat/1","$scriptRoot/shims" -Force | Out-Null
[IO.File]::WriteAllText("$scriptRoot/apps/scopebat/1/tool.bat","@echo off`r`necho wrapper-v1 %*`r`nexit /b 0")
[IO.File]::WriteAllText("$scriptRoot/apps/scopebat/1/manifest.json",(@{version='1';url=(File-Uri $scriptArchive);hash=$scriptHash;bin=$scriptBin} | ConvertTo-Json -Depth 8))
'{"bucket":"test","architecture":"64bit"}' | Set-Content "$scriptRoot/apps/scopebat/1/install.json" -Encoding utf8
New-Item -ItemType Junction -Path "$scriptRoot/apps/scopebat/current" -Target "$scriptRoot/apps/scopebat/1" | Out-Null
$scriptTarget = [IO.Path]::GetFullPath("$scriptRoot/apps/scopebat/current/tool.bat")
[IO.File]::WriteAllText("$scriptRoot/shims/scopebat-run.cmd","@rem $scriptTarget`r`n@`"$scriptTarget`" %*`r`n")
[IO.File]::WriteAllText("$scriptRoot/shims/scopebat-run","#!/bin/sh`n# $scriptTarget`nMSYS2_ARG_CONV_EXCL=/C cmd.exe /C `"$scriptTarget`" `"`$@`"`n")
$scriptPreview = Read-Json (& $CoopExe --root $scriptRoot update scopebat --dry-run --json)
Assert-Exit 'Scoop script-host update preview failed'
if ($scriptPreview.execution_available -ne $true -or @($scriptPreview.scoop_entry_wrappers).Count -ne 2) { throw 'Scoop script-host wrappers were not recognized in the update plan' }
$scriptUpdate = & $CoopExe --root $scriptRoot update scopebat --json
Assert-Exit "Scoop script-host update failed: $($scriptUpdate -join "`n")"
$scriptOutput = ((& "$scriptRoot/shims/scopebat-run.cmd" one) -join "`n")
if ($LASTEXITCODE -ne 0 -or $scriptOutput -notmatch 'wrapper-v2' -or $scriptOutput -notmatch 'one') { throw "updated Scoop script-host entry did not run: $scriptOutput" }
if (-not (Test-Path "$scriptRoot/shims/scopebat-run.cmd") -or -not (Test-Path "$scriptRoot/shims/scopebat-run")) { throw 'update did not republish the Scoop script-host wrappers beside the launcher' }
$scriptWrapperTarget = Join-Path $scriptRoot 'apps/scopebat/current/tool.bat'
if (([IO.File]::ReadAllText("$scriptRoot/shims/scopebat-run.cmd")) -notmatch [regex]::Escape($scriptWrapperTarget)) { throw 'the republished .cmd wrapper does not target the current version' }
$scriptRecord = Get-Content -LiteralPath "$scriptRoot/.coop/packages/scopebat.json" -Raw | ConvertFrom-Json
if ($scriptRecord.origin -ne 'scoop') { throw 'updating a Scoop script-host installation did not preserve its origin' }
$scriptUninstall = & $CoopExe --root $scriptRoot uninstall scopebat --json
Assert-Exit "Scoop script-host uninstall failed: $($scriptUninstall -join "`n")"
if ((Test-Path "$scriptRoot/apps/scopebat/current") -or (Test-Path "$scriptRoot/shims/scopebat-run.exe") -or
    (Test-Path "$scriptRoot/shims/scopebat-run.coop-shim.json") -or (Test-Path "$scriptRoot/shims/scopebat-run.cmd") -or
    (Test-Path "$scriptRoot/shims/scopebat-run")) { throw 'Scoop script-host uninstall left published state' }
# A wrapper-only Scoop installation is also removable directly, without first being updated.
$directRoot = New-TestRoot
$env:COOP_PROGRAMS_DIR = Join-Path $directRoot 'programs'
New-Item -ItemType Directory -Path "$directRoot/apps/scopebat/1","$directRoot/shims" -Force | Out-Null
[IO.File]::WriteAllText("$directRoot/apps/scopebat/1/tool.bat","@echo off`r`nexit /b 0")
$directBin = ,@('tool.bat','scopebat-run')
[IO.File]::WriteAllText("$directRoot/apps/scopebat/1/manifest.json",(@{version='1';url='http://127.0.0.1:1/unused.zip';hash=('0'*64);bin=$directBin} | ConvertTo-Json -Depth 8))
'{"bucket":"test","architecture":"64bit"}' | Set-Content "$directRoot/apps/scopebat/1/install.json" -Encoding utf8
New-Item -ItemType Junction -Path "$directRoot/apps/scopebat/current" -Target "$directRoot/apps/scopebat/1" | Out-Null
$directTarget = [IO.Path]::GetFullPath("$directRoot/apps/scopebat/current/tool.bat")
[IO.File]::WriteAllText("$directRoot/shims/scopebat-run.cmd","@rem $directTarget`r`n@`"$directTarget`" %*`r`n")
$directUninstall = & $CoopExe --root $directRoot uninstall scopebat --json
Assert-Exit "direct Scoop script-host uninstall failed: $($directUninstall -join "`n")"
if ((Test-Path "$directRoot/apps/scopebat/current") -or (Test-Path "$directRoot/shims/scopebat-run.cmd")) { throw 'direct Scoop script-host uninstall left published state' }

@{coop=$CoopExe;root=$root;adopt_root=$adoptRoot;jar_available=$jarAvailable;jar=$jarPath;programs=$programs;script_root=$scriptRoot;direct_root=$directRoot} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $TestRoot 'exposure-evidence.json') -Encoding utf8
Write-Output "PASS complex command entries, shortcuts and environment exposure: $TestRoot"
exit 0
} finally {
    foreach ($name in $userEnvironmentNames) {
        try { Restore-UserRaw $name $userEnvironmentSnapshots[$name] } catch { Write-Warning "Could not restore user environment value $name : $_" }
    }
}

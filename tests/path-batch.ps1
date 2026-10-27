param([Parameter(Mandatory)][string]$CoopExe,[Parameter(Mandatory)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
# Coop keeps stdout/stderr UTF-8; state that explicitly instead of relying on the ANSI code page
# that Windows PowerShell/PowerShell may inherit when the output is redirected.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$allowed = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.local/tests')).TrimEnd('\')+'\'
$TestRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not ($TestRoot.TrimEnd('\')+'\').StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test root outside project' }
$CoopExe = [IO.Path]::GetFullPath($CoopExe)
$session = Join-Path $TestRoot 'boundaries'
if (Test-Path -LiteralPath $session) { Remove-Item -LiteralPath $session -Recurse -Force }
New-Item -ItemType Directory -Path $session -Force | Out-Null

function Assert([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
function Invoke-Coop([string[]]$arguments) {
    $output = & $CoopExe @arguments 2>&1
    return [pscustomobject]@{ code = $LASTEXITCODE; text = ($output -join "`n") }
}
# Separate streams so a usage error can be checked for an empty stdout and a diagnostic stderr.
function Invoke-CoopRaw([string[]]$arguments) {
    $errorFile = Join-Path $session ('stderr-'+[guid]::NewGuid().ToString('N')+'.txt')
    try {
        $output = & $CoopExe @arguments 2>$errorFile
        return [pscustomobject]@{ code = $LASTEXITCODE; out = ($output -join "`n"); err = [IO.File]::ReadAllText($errorFile) }
    } finally { Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue }
}
function Read-CoopJson([string[]]$arguments) {
    $result = Invoke-Coop $arguments
    if ($result.code -ne 0) { throw "coop $($arguments -join ' ') failed ($($result.code)): $($result.text)" }
    return ($result.text | ConvertFrom-Json)
}
function New-FileManifest([string]$name) {
    $uri = ([Uri]$CoopExe).AbsoluteUri
    return @{version='0.1.0';url=$uri+'#/'+$name+'.exe';hash=(Get-FileHash $CoopExe -Algorithm SHA256).Hash.ToLower();bin="$name.exe"}
}
function Write-BucketManifest([string]$root,[string]$bucket,[string]$name,[hashtable]$manifest) {
    $directory = Join-Path $root "buckets/$bucket/bucket"
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $directory "$name.json"),($manifest | ConvertTo-Json -Depth 8))
}
function New-InstalledFilePackage([string]$root,[string]$name) {
    $directory = Join-Path $root "apps/$name/1"
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    Copy-Item -LiteralPath $CoopExe -Destination (Join-Path $directory "$name.exe")
    $manifest = New-FileManifest $name
    [IO.File]::WriteAllText((Join-Path $directory 'scoop-manifest.json'),($manifest | ConvertTo-Json -Depth 8))
    [IO.File]::WriteAllText((Join-Path $directory 'scoop-install.json'),'{"bucket":"test","architecture":"64bit"}')
    New-Item -ItemType Junction -Path (Join-Path $root "apps/$name/current") -Target $directory | Out-Null
}
function Get-TreeSnapshot([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-ChildItem -LiteralPath $path -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($path.Length)
        if (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { "l|$relative" }
        elseif ($_.PSIsContainer) { "d|$relative" }
        else { "f|$relative|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }
    })
}
function Get-ShortSHA256([string]$path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($path))).Replace('-','').ToLowerInvariant()) }
    finally { $sha.Dispose() }
}

# --- 1. Exit codes and stream separation ------------------------------------------------
$version = Invoke-CoopRaw @('--version')
Assert ($version.code -eq 0 -and $version.out.Trim() -eq 'coop 0.1.0' -and $version.err -eq '') "version contract changed: $($version.out) $($version.err)"
$unknown = Invoke-CoopRaw @('unsupported-command')
Assert ($unknown.code -eq 2 -and $unknown.out -eq '' -and $unknown.err -match 'unknown command') "unknown command did not exit 2 on stderr: $($unknown.code) $($unknown.out) $($unknown.err)"
$missingRoot = Invoke-CoopRaw @('--root')
Assert ($missingRoot.code -eq 2 -and $missingRoot.err -match 'requires a value') "a root option without a value was not a usage error: $($missingRoot.code) $($missingRoot.err)"
$emptyRoot = Invoke-CoopRaw @('--root=','list')
Assert ($emptyRoot.code -eq 2 -and $emptyRoot.err -match 'Root path must not be empty') "an empty root was not rejected: $($emptyRoot.code) $($emptyRoot.err)"
$badArch = Invoke-CoopRaw @('--arch','x86','--root','.', 'list')
Assert ($badArch.code -eq 2 -and $badArch.err -match '--arch must be') "an invalid architecture was not a usage error: $($badArch.code) $($badArch.err)"
$extraList = Invoke-CoopRaw @('--root=','list','extra')
Assert ($extraList.code -eq 2) "list with an extra argument was not a usage error: $($extraList.code) $($extraList.text)"
$noPackage = Invoke-CoopRaw @('--root',(Join-Path $session 'empty'),'install')
Assert ($noPackage.code -eq 2 -and $noPackage.err -match 'one or more packages') "install without a package was not a usage error: $($noPackage.code) $($noPackage.err)"
$badOption = Invoke-CoopRaw @('--root',(Join-Path $session 'empty'),'install','pkg','--bogus')
Assert ($badOption.code -eq 2 -and $badOption.err -match 'Unknown package option') "an unknown package option was not a usage error: $($badOption.code) $($badOption.err)"
$badInstall = Invoke-CoopRaw @('--root',(Join-Path $session 'empty'),'install','does-not-exist')
Assert ($badInstall.code -eq 1 -and $badInstall.err -match 'not found') "an operational failure did not exit 1: $($badInstall.code) $($badInstall.err)"
Assert (-not (Test-Path -LiteralPath (Join-Path $session 'empty'))) 'a failed install created the installation root'

# --- 2. Complex but valid Windows path forms ---------------------------------------------
# Spaces, Chinese, '#', '&', '%', brackets and parentheses are all ordinary path characters.
$complex = Join-Path $session 'root #1 [x] & 100% (复杂)'
$complexInit = Read-CoopJson @(('--root='+$complex),'init','--json')
Assert ($complexInit.root -eq $complex -and @($complexInit.created).Count -eq 5) "the --root=<path> form did not initialize the complex path: root='$($complexInit.root)' expected='$complex' created=$(@($complexInit.created).Count)"
$trailing = Read-CoopJson @('--root',($complex+'\'),'init','--json')
Assert ($trailing.root -eq $complex -and @($trailing.created).Count -eq 0) "a trailing separator changed the root identity: $($trailing | ConvertTo-Json -Compress)"
$dots = Read-CoopJson @('--root',($complex+'\.\apps\..'),'list','--json')
Assert (@($dots).Count -eq 0) "dot segments were not normalized: $($dots | ConvertTo-Json -Compress)"
$slashes = Read-CoopJson @('--root',($complex -replace '\\','/'),'list','--json')
Assert (@($slashes).Count -eq 0) "forward slashes were not accepted: $($slashes | ConvertTo-Json -Compress)"
$explicitExtended = Read-CoopJson @('--root',('\\?\'+$complex),'init','--json')
Assert ($explicitExtended.root -eq ('\\?\'+$complex) -and @($explicitExtended.existing).Count -eq 5) "an explicit extended-length root was not accepted: $($explicitExtended | ConvertTo-Json -Compress)"
Push-Location $session
try {
    $relative = Read-CoopJson @('--root','relative 中文 root','init','--dry-run','--json')
    Assert ($relative.root -eq (Join-Path $session 'relative 中文 root')) "a relative root was not resolved against the current directory: $($relative.root)"
} finally { Pop-Location }

# Unicode bucket, package, executable and alias names survive the whole lifecycle.
$unicodeManifest = @{version='0.1.0';url=([Uri]$CoopExe).AbsoluteUri+'#/工具.exe';
    hash=(Get-FileHash $CoopExe -Algorithm SHA256).Hash.ToLower();bin=@(,@('工具.exe','工具 包'))}
Write-BucketManifest $complex '测试源' '工具包' $unicodeManifest
$unicodeInstall = Read-CoopJson @('--root',$complex,'install','测试源/工具包','--json')
Assert ($unicodeInstall.status -eq 'success') "the Unicode package did not install: $($unicodeInstall | ConvertTo-Json -Compress)"
$unicodeVersion = & (Join-Path $complex 'shims/工具 包.exe') --version
Assert ($LASTEXITCODE -eq 0 -and $unicodeVersion -eq 'coop 0.1.0') "the Unicode command entry did not run: $unicodeVersion"
$unicodeList = Read-CoopJson @('--root',$complex,'list','--json')
Assert (@($unicodeList | Where-Object { $_.name -eq '工具包' -and $_.version -eq '0.1.0' }).Count -eq 1) "the Unicode package is missing from list: $($unicodeList | ConvertTo-Json -Compress)"
$unicodeRemove = Read-CoopJson @('--root',$complex,'uninstall','工具包','--json')
Assert ($unicodeRemove.status -eq 'success' -and -not (Test-Path -LiteralPath (Join-Path $complex 'shims/工具 包.exe'))) 'the Unicode package did not uninstall cleanly'

# --- 3. A root whose derived tree exceeds MAX_PATH ---------------------------------------
$longRoot = Join-Path $session 'long'
1..12 | ForEach-Object { $longRoot = Join-Path $longRoot ('深'*20) }
[IO.Directory]::CreateDirectory("\\?\$longRoot") | Out-Null
$longInit = Read-CoopJson @('--root',$longRoot,'init','--json')
Assert ($longInit.root -eq ('\\?\'+$longRoot)) "a long root was not converted to an extended-length path: $($longInit.root)"
$deepManifest = @{version='0.1.0';url=([Uri]$CoopExe).AbsoluteUri+'#/deep.exe';
    hash=(Get-FileHash $CoopExe -Algorithm SHA256).Hash.ToLower();bin='deep.exe'}
[IO.Directory]::CreateDirectory("\\?\$longRoot\buckets\main\bucket") | Out-Null
[IO.File]::WriteAllText("\\?\$longRoot\buckets\main\bucket\deep.json",($deepManifest | ConvertTo-Json -Depth 8))
$longInstall = Read-CoopJson @('--root',$longRoot,'install','deep','--json')
Assert ($longInstall.status -eq 'success') "a package did not install under a long root: $($longInstall | ConvertTo-Json -Compress)"
$longArtifact = "\\?\$longRoot\apps\deep\current\deep.exe"
Assert ([IO.File]::Exists($longArtifact)) 'the long-path installation artifact is missing'
Assert ((Get-ShortSHA256 $longArtifact) -eq (Get-FileHash $CoopExe -Algorithm SHA256).Hash.ToLowerInvariant()) 'the long-path artifact bytes changed'
$longList = Read-CoopJson @('--root',$longRoot,'list','--json')
Assert (@($longList | Where-Object { $_.name -eq 'deep' -and $_.version -eq '0.1.0' }).Count -eq 1) "the long-path installation is missing from list: $($longList | ConvertTo-Json -Compress)"

# .NET refuses to start an executable whose plain path exceeds MAX_PATH, so the actual Windows
# API is used with the extended path the installed shim now has.
$runner = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
public static class LongPathRunner {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct STARTUPINFO { public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
    public int dwX; public int dwY; public int dwXSize; public int dwYSize; public int dwXCountChars; public int dwYCountChars;
    public int dwFillAttribute; public int dwFlags; public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2;
    public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError; }
  [StructLayout(LayoutKind.Sequential)]
  public struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId; }
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern bool CreateProcessW(string app, StringBuilder command, IntPtr pa, IntPtr ta, bool inherit,
    uint flags, IntPtr environment, string directory, ref STARTUPINFO info, out PROCESS_INFORMATION process);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool WaitForSingleObject(IntPtr handle, uint milliseconds);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr handle, out uint code);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  [StructLayout(LayoutKind.Sequential)] public struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr descriptor; public bool inherit; }
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern IntPtr CreateFileW(string name, uint access, uint share, ref SECURITY_ATTRIBUTES security, uint disposition, uint attributes, IntPtr template);
  public static int Run(string application, string arguments, string directory, string output, out string problem) {
    var security = new SECURITY_ATTRIBUTES();
    security.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)); security.inherit = true;
    IntPtr file = CreateFileW(output, 0x40000000, 3, ref security, 2, 0x80, IntPtr.Zero);
    if (file == new IntPtr(-1)) { problem = "output handle " + Marshal.GetLastWin32Error(); return -1; }
    var info = new STARTUPINFO(); info.cb = Marshal.SizeOf(info);
    info.dwFlags = 0x100; info.hStdOutput = file; info.hStdError = file;
    var command = new StringBuilder("\"" + application + "\" " + arguments);
    PROCESS_INFORMATION process;
    try {
      if (!CreateProcessW(application, command, IntPtr.Zero, IntPtr.Zero, true, 0, IntPtr.Zero, directory, ref info, out process)) {
        problem = "CreateProcess " + Marshal.GetLastWin32Error(); return -1;
      }
      WaitForSingleObject(process.hProcess, 30000);
      uint code; GetExitCodeProcess(process.hProcess, out code);
      CloseHandle(process.hThread); CloseHandle(process.hProcess);
      problem = ""; return (int)code;
    } finally { CloseHandle(file); }
  }
}
'@
Add-Type -TypeDefinition $runner
$longOutput = Join-Path $session 'long-output.txt'
$problem = ''
$longExit = [LongPathRunner]::Run("\\?\$longRoot\shims\deep.exe",'--version',(Get-Location).Path,$longOutput,[ref]$problem)
Assert ($longExit -eq 0 -and $problem -eq '') "the long-path command entry did not run: exit $longExit $problem"
Assert (([IO.File]::ReadAllText($longOutput)).Trim() -eq 'coop 0.1.0') 'the long-path command entry printed the wrong output'
$longRemove = Read-CoopJson @('--root',($longRoot+'\'),'uninstall','deep','--json')
Assert ($longRemove.status -eq 'success' -and -not [IO.Directory]::Exists("\\?\$longRoot\apps\deep")) "the long-path package did not uninstall: $($longRemove | ConvertTo-Json -Compress)"

# --- 4. Per-package batch outcomes and a read-only global scope --------------------------
$userRoot = Join-Path $session 'user'
$globalRoot = Join-Path $session 'global'
New-InstalledFilePackage $globalRoot 'globaltool'
$globalBefore = Get-TreeSnapshot $globalRoot
$globalList = Read-CoopJson @('--root',$userRoot,'--global-root',$globalRoot,'list','--json')
Assert (@($globalList).Count -eq 1 -and $globalList[0].scope -eq 'global' -and $globalList[0].read_only -eq $true) "the global installation is not identified as read-only: $($globalList | ConvertTo-Json -Compress)"

# update/uninstall/reset may not be reinterpreted as user-scope writes.
foreach ($arguments in @(
    @('uninstall','globaltool'),
    @('update','globaltool','--dry-run'),
    @('reset','globaltool@0.0.0','--dry-run'))) {
    $refused = Invoke-CoopRaw (@('--root',$userRoot,'--global-root',$globalRoot)+$arguments)
    Assert ($refused.code -eq 1 -and ($refused.err+$refused.out) -match 'global-scope-readonly') "a global-only package was not refused for $($arguments -join ' '): $($refused.code) $($refused.err)$($refused.out)"
    Assert (@(Get-TreeSnapshot $globalRoot) -join "`n" -eq ($globalBefore -join "`n")) "a refused global operation changed the global root: $($arguments -join ' ')"
}
Assert (-not (Test-Path -LiteralPath $userRoot)) 'a refused global operation created user-scope state'
Assert (-not (Test-Path -LiteralPath (Join-Path $globalRoot '.coop'))) 'a refused global operation created Coop state in the global root'

# A new user-scope installation may be planned and executed while the global copy stays untouched;
# the plan and result identify the read-only global installation instead of silently replacing it.
Write-BucketManifest $userRoot 'test' 'globaltool' (New-FileManifest 'globaltool')
$globalPreview = Read-CoopJson @('--root',$userRoot,'--global-root',$globalRoot,'install','globaltool','--dry-run','--json')
Assert ($globalPreview.global_installation.scope -eq 'global' -and $globalPreview.global_installation.read_only -eq $true) 'the user-scope plan did not identify the read-only global installation'
$globalUserInstall = Read-CoopJson @('--root',$userRoot,'--global-root',$globalRoot,'install','globaltool','--json')
Assert ($globalUserInstall.status -eq 'success' -and $globalUserInstall.global_installation.read_only -eq $true) 'the user-scope install did not report the read-only global installation'
$globalUserVersion = & (Join-Path $userRoot 'shims/globaltool.exe') --version
Assert ($LASTEXITCODE -eq 0 -and $globalUserVersion -eq 'coop 0.1.0') 'the user-scope installation is not runnable'
Assert (@(Get-TreeSnapshot $globalRoot) -join "`n" -eq ($globalBefore -join "`n")) 'a user-scope install changed the global root'
$globalUserRemove = Read-CoopJson @('--root',$userRoot,'--global-root',$globalRoot,'uninstall','globaltool','--json')
Assert ($globalUserRemove.status -eq 'success' -and -not (Test-Path -LiteralPath (Join-Path $userRoot 'shims/globaltool.exe'))) 'the user-scope uninstall failed'
Assert (@(Get-TreeSnapshot $globalRoot) -join "`n" -eq ($globalBefore -join "`n")) 'the user-scope uninstall changed the global root'

# A wholly successful batch reports every package and exits zero.
Write-BucketManifest $userRoot 'test' 'alpha' (New-FileManifest 'alpha')
Write-BucketManifest $userRoot 'test' 'beta' (New-FileManifest 'beta')
$successBatch = Invoke-Coop @('--root',$userRoot,'install','alpha','beta','--json')
$successItems = @($successBatch.text | ConvertFrom-Json)
Assert ($successBatch.code -eq 0 -and $successItems.Count -eq 2 -and
    $successItems[0].package -eq 'alpha' -and $successItems[0].status -eq 'success' -and
    $successItems[1].package -eq 'beta' -and $successItems[1].status -eq 'success') "a successful batch did not report both packages: $($successBatch.text)"
foreach ($name in @('alpha','beta')) {
    $runnable = & (Join-Path $userRoot "shims/$name.exe") --version
    Assert ($LASTEXITCODE -eq 0 -and $runnable -eq 'coop 0.1.0') "batch-installed $name is not runnable"
}
Assert (@(Get-TreeSnapshot $globalRoot) -join "`n" -eq ($globalBefore -join "`n")) 'a user batch changed the global root'

# A partially failing batch keeps the successful package, reports both items and exits non-zero.
Write-BucketManifest $userRoot 'test' 'gamma' (New-FileManifest 'gamma')
$partialBatch = Invoke-Coop @('--root',$userRoot,'install','gamma','ghostpkg','--json')
$partialItems = @($partialBatch.text | ConvertFrom-Json)
Assert ($partialBatch.code -eq 1 -and $partialItems.Count -eq 2 -and
    $partialItems[0].package -eq 'gamma' -and $partialItems[0].status -eq 'success' -and
    $partialItems[1].package -eq 'ghostpkg' -and $partialItems[1].status -eq 'failed') "a partial batch did not report success and failure: $($partialBatch.text)"
Assert ((& (Join-Path $userRoot 'shims/gamma.exe') --version) -eq 'coop 0.1.0') 'the successful item of a partial batch is not runnable'
Assert (-not (Test-Path -LiteralPath (Join-Path $userRoot 'shims/ghostpkg.exe'))) 'a failed batch item published an entry'

# Text mode keeps per-package lines and adds an accurate overall summary.
Assert ((Read-CoopJson @('--root',$userRoot,'uninstall','gamma','--json')).status -eq 'success') 'could not reset gamma before the text batch'
$textPartial = Invoke-CoopRaw @('--root',$userRoot,'install','gamma','ghosttwo')
Assert ($textPartial.code -eq 1 -and $textPartial.out -match 'gamma: success' -and
    $textPartial.out -match '2 package\(s\): 1 succeeded, 0 skipped, 1 failed' -and
    $textPartial.err -match 'Package not found') "text batch output or summary is wrong: $($textPartial.out) $($textPartial.err)"

# Dry-run batches report a blocked item without writing the requested package.
Write-BucketManifest $userRoot 'test' 'delta' (New-FileManifest 'delta')
$dryBatch = Invoke-Coop @('--root',$userRoot,'install','delta','ghostpkg','--dry-run','--json')
$dryItems = @($dryBatch.text | ConvertFrom-Json)
Assert ($dryBatch.code -eq 1 -and $dryItems.Count -eq 2 -and $dryItems[0].status -eq 'planned' -and $dryItems[1].status -eq 'blocked') "a dry-run batch did not report planned and blocked items: $($dryBatch.text)"
Assert (-not (Test-Path -LiteralPath (Join-Path $userRoot 'apps/delta'))) 'a dry-run batch installed a package'

# A batch targeting a read-only global-only package and a user package reports both outcomes and
# still removes only the user package.
$mixedRemove = Invoke-Coop @('--root',$userRoot,'--global-root',$globalRoot,'uninstall','alpha','globaltool','--json')
$mixedItems = @($mixedRemove.text | ConvertFrom-Json)
Assert ($mixedRemove.code -eq 1 -and $mixedItems.Count -eq 2 -and
    $mixedItems[0].package -eq 'alpha' -and $mixedItems[0].status -eq 'success' -and
    $mixedItems[1].package -eq 'globaltool' -and $mixedItems[1].status -eq 'failed' -and
    $mixedItems[1].reason -match 'global-scope-readonly') "a mixed batch did not report per-package outcomes: $($mixedRemove.text)"
Assert (-not (Test-Path -LiteralPath (Join-Path $userRoot 'shims/alpha.exe'))) 'the successful item of a mixed batch was not removed'
Assert (@(Get-TreeSnapshot $globalRoot) -join "`n" -eq ($globalBefore -join "`n")) 'a mixed batch changed the global root'

# A wholly successful multi-package uninstall exits zero.
$successRemove = Invoke-Coop @('--root',$userRoot,'uninstall','beta','gamma','--json')
$successRemoveItems = @($successRemove.text | ConvertFrom-Json)
Assert ($successRemove.code -eq 0 -and $successRemoveItems.Count -eq 2 -and
    $successRemoveItems[0].status -eq 'success' -and $successRemoveItems[1].status -eq 'success') "a successful batch uninstall failed: $($successRemove.text)"
foreach ($name in @('beta','gamma')) {
    Assert (-not (Test-Path -LiteralPath (Join-Path $userRoot "shims/$name.exe"))) "batch uninstall left $name behind"
}

Write-Output "PASS CLI path boundaries, exit codes, long roots and per-package batch outcomes: $session"

# Red when: a capture helper stops returning the child's stdout, stderr or exit code on either runner,
# or the quoting/encoding defaults it applies stop matching what Windows parses.
# Portability helpers for the test suite: the same scripts run under Windows PowerShell 5.1 (shipped
# with Windows) and PowerShell 7.
#
# Two PowerShell-7-only things appear all over tests/*.ps1 and break on 5.1:
#   * `& exe ... 2>&1` throws a terminating NativeCommandError as soon as the child writes to stderr,
#     because every test sets $ErrorActionPreference = 'Stop'. Measured: `2>file` throws too.
#   * `ProcessStartInfo.ArgumentList` and `ProcessStartInfo.Environment` are .NET Core additions;
#     .NET Framework 4.8 has `Arguments` (a string) and `EnvironmentVariables` (an IDictionary).
#   * `Process.Kill($true)` has no bool overload on .NET Framework.
#
# Tests keep their own `Invoke-Coop` wrappers; these helpers are the portable primitives underneath.

# Quotes one argument the way CommandLineToArgvW parses it: wrap in quotes when it is empty or contains
# whitespace/a quote, double the backslashes that precede a quote, and double a trailing run of them.
function ConvertTo-ArgumentString {
    param([string[]]$Arguments)
    $parts = foreach ($argument in $Arguments) {
        $value = if ($null -eq $argument) { '' } else { [string]$argument }
        if ($value -eq '') { '""'; continue }
        if ($value -notmatch '[\s"]') { $value; continue }
        $escaped = [regex]::Replace($value, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        '"' + $escaped + '"'
    }
    return ($parts -join ' ')
}

# Drop-in replacement for $startInfo.ArgumentList.Add($x), which 5.1 does not have.
function Add-ProcessArgument {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.ProcessStartInfo]$Info,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Value
    )
    $text = ConvertTo-ArgumentString @($Value)
    if ([string]::IsNullOrEmpty($Info.Arguments)) { $Info.Arguments = $text } else { $Info.Arguments = $Info.Arguments + ' ' + $text }
}

# Runs an executable and returns its stdout and stderr as text lines, on both PowerShell versions.
# stdout lines come first, then stderr lines; $LASTEXITCODE is set like a direct call.
# Runs an executable and returns its stdout and stderr as text lines, on both PowerShell versions.
# stdout lines come first, then stderr lines; $LASTEXITCODE is set like a direct call.
function Invoke-CoopNative {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments
    )
    if ($Arguments.Count -eq 1 -and $Arguments[0] -is [array]) { $Arguments = @($Arguments[0]) }
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $Exe @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    $global:LASTEXITCODE = $code
    $lines = @()
    foreach ($item in @($raw)) {
        if ($null -eq $item) { continue }
        if ($item -is [System.Management.Automation.ErrorRecord]) {
            $lines += @($item.ToString().TrimEnd("`r", "`n"))
        } else {
            $lines += @(([string]$item).TrimEnd("`r"))
        }
    }
    return $lines
}

function Invoke-CoopNativeRaw {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments
    )
    if ($Arguments.Count -eq 1 -and $Arguments[0] -is [array]) { $Arguments = @($Arguments[0]) }
    $start = [Diagnostics.ProcessStartInfo]::new($Exe)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    # Keep the caller's current directory: tests exercise relative roots against it.
    $start.WorkingDirectory = (Get-Location).ProviderPath
    $start.Arguments = ConvertTo-ArgumentString @($Arguments)
    $process = [Diagnostics.Process]::Start($start)
    try {
        # Both streams asynchronously, then wait: reading one to the end first deadlocks when the
        # child fills the other pipe's buffer (this hung update_bare in a full-suite run).
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        return [pscustomobject]@{ code = $process.ExitCode; out = $stdout; err = $stderr }
    } finally {
        $process.Dispose()
    }
}

# Redirect a child's stderr to a file and swallow stdout, the way `& exe ... 2> file | Out-Null` reads.
# That form throws on 5.1 for the same reason 2>&1 does, so the file capture happens here instead.
function Invoke-CoopNativeToFile {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$ErrorFile,
        [Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments
    )
    $result = Invoke-CoopNativeRaw $Exe @Arguments
    [IO.File]::WriteAllText($ErrorFile, $result.err)
    $global:LASTEXITCODE = $result.code
    return $result.out
}

# ConvertFrom-Json -AsHashtable is PowerShell 6+; this walks the object graph instead so the callers
# that use .ContainsKey() keep working on 5.1.
function ConvertTo-Hashtable {
    param([Parameter(ValueFromPipeline = $true)]$InputObject)
    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $copy = @{}
            foreach ($key in $InputObject.Keys) { $copy[$key] = ConvertTo-Hashtable $InputObject[$key] }
            return $copy
        }
        if ($InputObject -is [pscustomobject]) {
            $map = @{}
            foreach ($property in $InputObject.PSObject.Properties) { $map[$property.Name] = ConvertTo-Hashtable $property.Value }
            return $map
        }
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            # Assigning element by element and returning `,$result` keeps nested arrays nested; a
            # foreach-based collection flattens `[["path","alias"]]` into two strings.
            $source = [object[]]($InputObject)
            $result = [object[]]::new($source.Length)
            for ($index = 0; $index -lt $source.Length; $index++) { $result[$index] = ConvertTo-Hashtable $source[$index] }
            return ,$result
        }
        return $InputObject
    }
}

# 5.1/.NET Framework have no FileSystemInfo.LinkTarget (PowerShell 6+/ .NET 6+); read the reparse point
# through fsutil, which is present on every supported Windows.
function Get-LinkTarget {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSObject.Properties['LinkTarget'] -and $item.LinkTarget) { return [string]$item.LinkTarget }
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
    # fsutil writes its label to stderr on some systems; the tolerant capture keeps 5.1 from throwing.
    $lines = Invoke-CoopNative fsutil.exe reparsepoint query $Path
    foreach ($line in $lines) {
        if ($line -match '^\s*Print Name:\s*(?<target>.+?)\s*$') { return $Matches['target'] }
    }
    foreach ($line in $lines) {
        if ($line -match '^\s*\S[^:]*:\s*(?<target>[A-Za-z]:\\.*)$') { return $Matches['target'] }
    }
    return $null
}

# Windows PowerShell 5.1 reads and writes text files as ANSI by default, while every fixture, manifest and
# journal in this suite is UTF-8 (and some of them contain Chinese paths). Dot-sourcing this file sets the
# defaults for the calling test, so `Get-Content -Raw | ConvertFrom-Json` stays correct on 5.1 too.
$PSDefaultParameterValues['Get-Content:Encoding'] = 'utf8'
$PSDefaultParameterValues['Set-Content:Encoding'] = 'utf8'
$PSDefaultParameterValues['Add-Content:Encoding'] = 'utf8'
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
# ConvertFrom-Json in Windows PowerShell 5.1 returns a JSON array as one object, so `@($text | ConvertFrom-Json)`
# counts 1 there and N on PowerShell 7. This returns the array's elements either way.
function ConvertFrom-JsonText {
    param([Parameter(Mandatory = $true)][string]$Text)
    $value = ConvertFrom-Json $Text
    if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) { return ,([object[]]$value) }
    return ,$value
}

# Returns the elements of a JSON document as a flat array, on both PowerShell versions.
# 5.1's ConvertFrom-Json hands back a JSON array as ONE object (and '[]' as an empty array object), so
# `@($text | ConvertFrom-Json).Count` reads 1 there and the real count on 7; piping through ForEach-Object
# expands the array either way.
function Get-JsonItems {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Text)
    $json = (($Text | ForEach-Object { [string]$_ }) -join "`n")
    if ([string]::IsNullOrWhiteSpace($json)) { return }
    $value = ConvertFrom-Json $json
    if ($null -eq $value) { return }
    if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) { $value | ForEach-Object { $_ }; return }
    $value
}
# stdout only (stderr is dropped): for calls whose output is parsed as JSON, so a diagnostic line from a
# successful-but-noisy child does not turn into "Invalid JSON primitive".
function Invoke-CoopStdout {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments
    )
    $result = Invoke-CoopNativeRaw $Exe @Arguments
    $global:LASTEXITCODE = $result.code
    $lines = @()
    foreach ($line in ($result.out -split "`n")) { $lines += @($line.TrimEnd("`r")) }
    while ($lines.Count -gt 0 -and $lines[$lines.Count-1] -eq '') { $lines = $lines[0..($lines.Count-2)] }
    return $lines
}
# Runs the child and parses its stdout as JSON, returning the document's elements (arrays expanded).
# Raw stdout is parsed as one string: rebuilding lines and re-joining them changed the text enough that
# 5.1's ConvertFrom-Json returned no objects for `list --json`.
function Invoke-CoopJson {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments
    )
    $result = Invoke-CoopNativeRaw $Exe @Arguments
    $global:LASTEXITCODE = $result.code
    if ([string]::IsNullOrWhiteSpace($result.out)) { return }
    $value = ConvertFrom-Json $result.out
    if ($null -eq $value) { return }
    if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) { $value | ForEach-Object { $_ }; return }
    $value
}
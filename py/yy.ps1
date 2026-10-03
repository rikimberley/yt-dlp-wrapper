#!/usr/bin/env pwsh
# ---------------------------------------------------------------------------
# Thin launcher for yy.py. All behaviour lives in yy.py; this file only finds
# a usable Python interpreter and hands off, so there is nothing here that has
# to stay in sync with yy.zsh.
#
# Must run on Windows PowerShell 5.1, so: no backtick-e escapes, no bare
# $IsWindows, and nothing that needs pwsh 6+.
#
# Keep this script trivial. Anything added here is a divergence again. The one
# exception is --no-py below, which has to live here: it exists to recover a
# directory whose yy.py or Python interpreter is the thing that is broken, so
# it cannot be implemented in yy.py.
# ---------------------------------------------------------------------------

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$target = Join-Path $PSScriptRoot 'yy.py'
$minMajor = 3
$minMinor = 9
$scriptRawBase = 'https://raw.githubusercontent.com/rikimberley/yt-dlp-wrapper/master'

# Launcher errors go to stderr, matching yy.zsh. Write-Error is deliberately
# not used: with $ErrorActionPreference = 'Stop' it throws, printing a source
# excerpt and squiggles around a message the user cannot act on any better
# for having seen the line number.
function Write-LauncherError {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

# --no-py: replace this launcher with the shell build from the head of master,
# the inverse of the shell build's --py. Handled before yy.py and the
# interpreter are looked for, for the reason given in the header.
#
# Both wrappers are replaced, not just this one: a shell-build yy.ps1 sitting
# next to a yy.zsh launcher is two different builds sharing one state
# directory, and whichever wrapper the next run picks would decide which build
# it got.
function Invoke-NoPyFetch {
    param([string]$Name, [string]$Sentinel)

    $body = $null
    try {
        $request = [Net.HttpWebRequest]::Create("$scriptRawBase/$Name")
        $request.Method = 'GET'
        $request.Timeout = 60000
        $request.AutomaticDecompression =
            [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
        $response = $request.GetResponse()
        try {
            $reader = New-Object IO.StreamReader(
                $response.GetResponseStream(), [Text.Encoding]::UTF8)
            try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        finally { $response.Dispose() }
    }
    catch {
        Write-LauncherError "Error: could not fetch $Name from master: $($_.Exception.Message)"
        return $false
    }

    # Same sentinel rule as -U: a captive portal or a 404 page written here
    # would leave the directory with no working wrapper and no way back.
    if ($null -eq $body -or -not $body.StartsWith($Sentinel)) {
        Write-LauncherError "Error: refusing to overwrite ${Name}: fetched body does not start with $Sentinel"
        return $false
    }

    $destination = Join-Path $PSScriptRoot $Name
    $tempDir = Join-Path $PSScriptRoot '.tmp'
    $temp = Join-Path $PSScriptRoot ($Name + '.new.' + $PID)
    try {
        if (-not (Test-Path -LiteralPath $tempDir)) {
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        }
        # UTF-8 without a BOM and LF endings, or the file stops matching the
        # repo byte for byte and every -U afterwards sees a difference.
        $normalized = $body.Replace("`r`n", "`n").TrimEnd("`n") + "`n"
        [IO.File]::WriteAllText(
            $temp, $normalized, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $destination) {
            Copy-Item -LiteralPath $destination `
                -Destination (Join-Path $tempDir ($Name + '.bak')) -Force
        }
        Move-Item -LiteralPath $temp -Destination $destination -Force
        # A .zsh wrapper must stay runnable. No-op on Windows, but --no-py
        # under pwsh on macOS can create a yy.zsh that never existed here.
        if ($Name.EndsWith('.zsh') -and (Get-Command chmod -ErrorAction SilentlyContinue)) {
            & chmod +x $destination 2>$null | Out-Null
        }
    }
    catch {
        Write-LauncherError "Error: could not write ${Name}: $($_.Exception.Message)"
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
    return $true
}

$wantsShellBuild = $false
foreach ($a in $args) { if ([string]$a -ceq '--no-py') { $wantsShellBuild = $true } }

if ($wantsShellBuild) {
    # 5.1 defaults to TLS 1.0, which raw.githubusercontent.com refuses, and its
    # Invoke-WebRequest never advertises gzip. Both are fixed the same way the
    # shell build fixes them.
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
    }
    catch { }

    # The *other* wrapper goes first and this one last, so a failure leaves the
    # launcher the user just invoked still able to understand --no-py and retry.
    if (-not (Invoke-NoPyFetch 'yy.zsh' '#!/bin/zsh')) { exit 1 }
    if (-not (Invoke-NoPyFetch 'yy.ps1' '#!/usr/bin/env pwsh')) {
        Write-LauncherError 'Error: ./yy.zsh is now the shell build but ./yy.ps1 is still a'
        Write-LauncherError '       launcher. Re-run --no-py; what already landed is kept.'
        exit 1
    }
    Write-Host 'Switched to the shell build. Previous copies are in .tmp.'
    if (Test-Path -LiteralPath $target) {
        Write-Host 'yy.py is left in place but unused; the shell build never reads it.'
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $target)) {
    Write-LauncherError "Error: $target not found"
    exit 1
}

# A candidate has to actually run and meet the version floor. This matters
# more on Windows than anywhere else: Windows ships a python.exe App Execution
# Alias that exists on PATH, produces no output, and silently redirects to the
# Microsoft Store. Testing for a real sentinel value rejects it.
function Test-PythonCandidate {
    param([string]$Exe, [string[]]$Prefix = @())

    try {
        $probe = "import sys; sys.stdout.write('yy-ok' if sys.version_info >= ($minMajor, $minMinor) else 'yy-old')"
        $output = & $Exe @Prefix '-c' $probe 2>$null
        if ($LASTEXITCODE -eq 0 -and $output -eq 'yy-ok') { return $true }
    } catch {
    }
    return $false
}

$pythonExe = $null
$pythonPrefix = @()

$override = $null
if (Test-Path Env:\YY_PYTHON) { $override = $env:YY_PYTHON }

$candidates = @()
if ($override) { $candidates += , @($override, @()) }
$candidates += , @('py', @('-3'))
$candidates += , @('python3', @())
$candidates += , @('python', @())

foreach ($candidate in $candidates) {
    if (Test-PythonCandidate -Exe $candidate[0] -Prefix $candidate[1]) {
        $pythonExe = $candidate[0]
        $pythonPrefix = $candidate[1]
        break
    }
}

if (-not $pythonExe) {
    Write-LauncherError "Error: no Python $minMajor.$minMinor+ interpreter found."
    Write-LauncherError 'Install one, or set YY_PYTHON to its full path:'
    Write-LauncherError '  winget install Python.Python.3.12'
    Write-LauncherError '  or download from https://www.python.org/downloads/'
    Write-LauncherError 'Note: a bare "python" on PATH may be the Microsoft Store stub,'
    Write-LauncherError 'which is why it is probed rather than trusted.'
    exit 1
}

& $pythonExe @pythonPrefix $target @args
exit $LASTEXITCODE

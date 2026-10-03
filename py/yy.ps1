#!/usr/bin/env pwsh
# ---------------------------------------------------------------------------
# Thin launcher for yy.py. All behaviour lives in yy.py; this file only finds
# a usable Python interpreter and hands off, so there is nothing here that has
# to stay in sync with yy.zsh.
#
# Must run on Windows PowerShell 5.1, so: no backtick-e escapes, no bare
# $IsWindows, and nothing that needs pwsh 6+.
#
# Keep this script trivial. Anything added here is a divergence again.
# ---------------------------------------------------------------------------

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$target = Join-Path $PSScriptRoot 'yy.py'
$minMajor = 3
$minMinor = 9

# Launcher errors go to stderr, matching yy.zsh. Write-Error is deliberately
# not used: with $ErrorActionPreference = 'Stop' it throws, printing a source
# excerpt and squiggles around a message the user cannot act on any better
# for having seen the line number.
function Write-LauncherError {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
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

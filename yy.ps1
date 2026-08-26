#!/usr/bin/env pwsh

# yy.ps1 - convenience wrapper around ./yt-dlp
#
# Description:
# - stores a positional URL into ./current_url.txt and downloads it
# - uses -t <temp_url> to download a one-off URL without persisting it
# - uses -p <path> to override the default ./t download directory
# - uses -U to update ./yt-dlp and refresh this script from the head of master
#   on GitHub, then skip any download
# - uses -o to open the channels in ./channel-ids.txt that published a public
#   video after the epoch timestamp in ./checkpoint.txt, and skip any download
#   (exits 1 if any channel could not be checked)
# - uses -O to open every channel in ./channel-ids.txt unconditionally, and
#   skip any download
# - uses --html to generate a local 6-column video grid with y1/y2 selections
# - uses -c to overwrite ./checkpoint.txt with the current epoch-ms timestamp,
#   and skip any download (runs after -o/-O, so `-o -c` means "open the new
#   ones, then mark everything as seen")
#
# Examples:
#   ./yy.ps1 'https://example.com/video'
#   ./yy.ps1 -t 'https://example.com/one-off'
#   ./yy.ps1 -p ./my-videos -t 'https://example.com/one-off'
#   ./yy.ps1 'https://saved.example.com/video' -t 'https://example.com/one-off'
#   ./yy.ps1 -U
#   ./yy.ps1 -o
#   ./yy.ps1 -O
#   ./yy.ps1 --html
#   ./yy.ps1 -c
#   ./yy.ps1 -o -c
#
# Note: arguments are parsed by hand from $args rather than via param(), because
# PowerShell binds parameter names case-insensitively and so cannot tell -o from
# -O. Hand-parsing keeps the flag set identical to yy.zsh.
#
# Note: this script must also run under Windows PowerShell 5.1, which has no
# `e escape sequence and no $IsMacOS/$IsLinux variables, defaults TLS to 1.0,
# and returns Invoke-WebRequest bodies as [byte[]] for non-text/* responses.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Windows PowerShell 5.1 defaults SecurityProtocol to Ssl3/Tls1.0, which
# youtube.com refuses; every Invoke-WebRequest then threw and each channel was
# reported as having no public videos. Opt into TLS 1.2 (plus 1.3 when the enum
# knows it) before any web request is made.
try {
    $tls = [Net.SecurityProtocolType]::Tls12
    if ([Enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
        $tls = $tls -bor [Net.SecurityProtocolType]::Tls13
    }
    [Net.ServicePointManager]::SecurityProtocol = $tls
}
catch { }

# Invoke-WebRequest redraws its progress bar per chunk in 5.1, which turns the
# ~1 MB channel page into a multi-minute fetch.
$ProgressPreference = 'SilentlyContinue'

# cd to the script's directory
Set-Location -LiteralPath $PSScriptRoot

$urlFile = './current_url.txt'
$channelsFile = './channel-ids.txt'
$channelIdCacheFile = './channel-id-cache.txt'
$checkpointFile = './checkpoint.txt'
$channelStatusFile = './channel-check-status.json'
$userAgent = 'Mozilla/5.0'
$acceptLanguage = 'en-US,en;q=0.9'
# Pre-accepted consent cookies: without them YouTube can answer a channel page
# with a consent interstitial that carries no channel_id, which looked exactly
# like "channel has no public videos". No account cookies are ever sent.
$consentCookie = 'SOCS=CAI; CONSENT=YES+cb'
$requestHeaders = @{
    'Accept-Language' = $acceptLanguage
    'Cookie'          = $consentCookie
}
$fetchTimeoutSec = 45
$fetchAttempts = 3
$ytDlpTimeoutSec = 30
$ytDlpAttempts = 1
$ytDlpDeadlineSec = 30
$feedFailureLimit = 3
$feedFetchFailures = 0
$skipFeedFetches = $false
$feedFetchFailed = $false
$feedFailureCountedForChannel = $false
# Head of master in the wrapper's own repo, used by -U to refresh this script.
$scriptRawBase = 'https://raw.githubusercontent.com/rikimberley/yt-dlp-wrapper/master'

$Url = ''
$TempUrl = ''
$OutputPath = './t'
$Update = $false
$OpenMode = ''
$HtmlMode = $false
$SetCheckpoint = $false
$htmlFailureCount = 0

for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -ceq '-t') {
        $i++
        if ($i -ge $args.Count) {
            [Console]::Error.WriteLine('Error: -t requires a URL argument')
            exit 1
        }
        $TempUrl = [string]$args[$i]
    }
    elseif ($a -ceq '-p') {
        $i++
        if ($i -ge $args.Count -or [string]::IsNullOrWhiteSpace([string]$args[$i])) {
            [Console]::Error.WriteLine('Error: -p requires a non-empty path argument')
            exit 1
        }
        $OutputPath = [string]$args[$i]
    }
    elseif ($a -ceq '-U') {
        $Update = $true
    }
    elseif ($a -ceq '-o' -or $a -ceq '-O') {
        if ($OpenMode -ne '' -or $HtmlMode) {
            [Console]::Error.WriteLine('Error: -o and -O cannot be combined')
            exit 1
        }
        $OpenMode = if ($a -ceq '-o') { 'check' } else { 'open' }
    }
    elseif ($a -ceq '--html') {
        if ($OpenMode -ne '') {
            [Console]::Error.WriteLine('Error: --html cannot be combined with -o or -O')
            exit 1
        }
        $OpenMode = 'html'
        $HtmlMode = $true
    }
    elseif ($a -ceq '-c') {
        $SetCheckpoint = $true
    }
    elseif ($a.StartsWith('-')) {
        [Console]::Error.WriteLine("Error: unsupported flag: $a")
        exit 1
    }
    else {
        if ($Url -ne '') {
            [Console]::Error.WriteLine('Error: expected at most one URL argument')
            exit 1
        }
        $Url = $a
    }
}

# Windows PowerShell 5.1 does not understand the `e escape, and printed the raw
# "e[34m" sequence, so no colour is applied here.
function Write-RunLine {
    param([string[]]$Cmd)

    $rendered = ($Cmd | ForEach-Object {
        if ($_ -match '[\s"'']') { "'" + ($_ -replace "'", "''") + "'" } else { $_ }
    }) -join ' '
    Write-Host "Running: $rendered"
}

# $IsMacOS/$IsLinux only exist in PowerShell 6+, and reading them under
# Set-StrictMode throws on Windows PowerShell 5.1 — so probe them defensively
# and fall back to Windows.
function Get-PlatformName {
    $mac = Get-Variable -Name 'IsMacOS' -ErrorAction SilentlyContinue
    if ($null -ne $mac -and $mac.Value) { return 'macos' }
    $linux = Get-Variable -Name 'IsLinux' -ErrorAction SilentlyContinue
    if ($null -ne $linux -and $linux.Value) { return 'linux' }
    return 'windows'
}

# Takes its arguments from $args rather than a [Parameter()] block on purpose:
# a [Parameter()] attribute makes this an advanced function, which gains the
# common parameters, and PowerShell then prefix-matches short flags against
# them. That silently ate "-P ./t" as -PipelineVariable. With $args nothing is
# bound, so every token reaches the child process verbatim.
function Invoke-YCommand {
    $cmd = @($args)
    if ($cmd.Count -eq 0) { return }

    Write-RunLine $cmd

    if ($cmd.Count -gt 1) {
        & $cmd[0] @($cmd[1..($cmd.Count - 1)])
    }
    else {
        & $cmd[0]
    }
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

# Locate the vendored yt-dlp binary. On Windows the file needs its .exe
# extension to be executable, so prefer that when it is present.
function Get-YtDlpPath {
    foreach ($candidate in @('./yt-dlp.exe', './yt-dlp')) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return ''
}

# Build the /videos URL for a channel-ids.txt entry. A raw UC… id is used as a
# channel id directly, anything else is treated as a handle.
#
# The handle is percent-encoded: Windows PowerShell 5.1 has unreliable IRI
# handling, and a non-ASCII handle could be sent with the wrong bytes and 404.
# Browsers send the same encoded form, so opening it is unaffected.
function Get-ChannelUrl {
    param([string]$Channel)

    if ($Channel -match '^UC[A-Za-z0-9_-]+$') {
        return "https://www.youtube.com/channel/$Channel/videos"
    }
    return 'https://www.youtube.com/@' + [uri]::EscapeDataString($Channel) + '/videos'
}

# Open a URL in the default browser.
function Open-Url {
    param([string]$TargetUrl)

    switch (Get-PlatformName) {
        'macos' {
            Write-RunLine @('open', '--', $TargetUrl)
            & open -- $TargetUrl
        }
        'linux' {
            Write-RunLine @('xdg-open', $TargetUrl)
            & xdg-open $TargetUrl
        }
        default {
            Write-RunLine @('Start-Process', $TargetUrl)
            Start-Process $TargetUrl | Out-Null
        }
    }
}

# Convert an ISO-8601 timestamp (e.g. 2026-08-01T16:30:12+00:00) to epoch ms.
#
# DateTimeStyles::RoundtripKind is meaningless for DateTimeOffset and is
# rejected outright by some framework versions, which made every timestamp fail
# to parse and every channel look like it had no public videos. Parse with None
# and fall back to a fixed round-trip format.
function ConvertTo-EpochMs {
    param([string]$Timestamp)

    $ts = ([string]$Timestamp).Trim()
    if ($ts -eq '') { return $null }

    try {
        $dto = [System.DateTimeOffset]::Parse(
            $ts,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None)
        return $dto.ToUnixTimeMilliseconds()
    }
    catch { }

    try {
        $dto = [System.DateTimeOffset]::ParseExact(
            $ts,
            @("yyyy-MM-ddTHH:mm:ssK", "yyyy-MM-ddTHH:mm:ss.FFFFFFFK"),
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal)
        return $dto.ToUnixTimeMilliseconds()
    }
    catch { return $null }
}

# Read ./checkpoint.txt and normalise it to epoch milliseconds.
function Read-CheckpointMs {
    if (-not (Test-Path -LiteralPath $checkpointFile)) {
        [Console]::Error.WriteLine("Error: $checkpointFile does not exist")
        exit 1
    }
    $raw = Get-Content -LiteralPath $checkpointFile -TotalCount 1
    if ($null -eq $raw) { $raw = '' }
    $digits = ($raw -replace '[^0-9]', '')
    if ($digits -eq '') {
        [Console]::Error.WriteLine("Error: $checkpointFile does not contain an epoch timestamp")
        exit 1
    }
    # 12+ digits means the value is already in milliseconds; else it is seconds.
    if ($digits.Length -ge 12) {
        return [long]$digits
    }
    return ([long]$digits) * 1000
}

# Fetch $Uri once and return its body as a string, or throw.
#
# Uses HttpWebRequest rather than Invoke-WebRequest because Windows PowerShell
# 5.1's Invoke-WebRequest never advertises gzip, so a channel page arrives as
# ~1.2 MB instead of ~270 KB and regularly blew the timeout — reported as
# "no public videos found". This path sets AutomaticDecompression, an explicit
# read timeout, and decodes the stream as UTF-8 (5.1 hands .Content back as
# [byte[]] for non-text/* bodies such as the application/atom+xml feed, which
# stringified to "1 2 3 ..." and matched no <published> entries).
function Get-WebContentOnce {
    param([string]$Uri)

    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = 'GET'
    $request.UserAgent = $userAgent
    $request.Timeout = $fetchTimeoutSec * 1000
    $request.ReadWriteTimeout = $fetchTimeoutSec * 1000
    $request.AutomaticDecompression = ([System.Net.DecompressionMethods]::GZip -bor
                                       [System.Net.DecompressionMethods]::Deflate)
    $request.Accept = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    $request.Headers['Accept-Language'] = $acceptLanguage
    $request.Headers['Cookie'] = $consentCookie

    $response = $request.GetResponse()
    try {
        $reader = New-Object System.IO.StreamReader(
            $response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $response.Close() }
}

# True when an error record carries a client-side HTTP status that will not
# change on retry (anything 4xx except 408/429).
function Test-PermanentWebError {
    param($ErrorRecord)

    try {
        $webException = $ErrorRecord.Exception
        while ($null -ne $webException -and -not ($webException -is [System.Net.WebException])) {
            $webException = $webException.InnerException
        }
        if ($null -eq $webException) { return $false }
        $response = $webException.Response
        if ($null -eq $response) { return $false }
        $status = [int]$response.StatusCode
        return ($status -ge 400 -and $status -lt 500 -and $status -ne 408 -and $status -ne 429)
    }
    catch { return $false }
}

# Fetch $Uri and return its body as a string, or $null on failure.
#
# Retries with a linear backoff: a single transient hiccup used to be
# indistinguishable from an empty channel. Invoke-WebRequest is kept as a
# last-ditch independent code path in case HttpWebRequest is unusable (proxy
# policy, mocked types).
function Get-WebContent {
    param([string]$Uri, [string]$What)

    $lastError = ''
    for ($attempt = 1; $attempt -le $fetchAttempts; $attempt++) {
        if ($attempt -gt 1) { Start-Sleep -Seconds ($attempt - 1) }
        try { return Get-WebContentOnce $Uri }
        catch {
            $lastError = $_.Exception.Message
            [Console]::Error.WriteLine(
                "Warning: fetch of $What failed (attempt $attempt/$fetchAttempts): $lastError")
            # A 404/403 is a settled answer, not a hiccup: retrying only delays
            # the (correct) failure report.
            if (Test-PermanentWebError $_) { break }
        }
    }

    try {
        $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing `
            -UserAgent $userAgent -Headers $requestHeaders -TimeoutSec $fetchTimeoutSec
        $content = $response.Content
        if ($null -eq $content) { throw 'empty response body' }
        if ($content -is [byte[]]) {
            $content = [System.Text.Encoding]::UTF8.GetString($content)
        }
        return ([string]$content).TrimStart([char]0xFEFF)
    }
    catch {
        $lastError = $_.Exception.Message
    }

    [Console]::Error.WriteLine("Warning: giving up on $What ($Uri): $lastError")
    return $null
}

# Refresh this wrapper in place from the head of master on GitHub, so a copy
# living outside a git clone (this is the Windows box) still tracks the repo.
# $Sentinel is the first line the payload must start with; anything else is
# assumed to be an error page or a captive-portal interstitial and is refused,
# because writing it would leave the machine with no working wrapper at all.
# Returns $true on success (including "already up to date").
function Update-Self {
    param([string]$Name, [string]$Sentinel)

    $uri = "$scriptRawBase/$Name"
    $body = Get-WebContent $uri "$Name from master"
    if ($null -eq $body -or $body -eq '') {
        [Console]::Error.WriteLine("Warning: could not refresh $Name from master")
        return $false
    }
    if (-not $body.StartsWith($Sentinel)) {
        [Console]::Error.WriteLine(
            "Warning: refusing to overwrite ${Name}: fetched body does not start with $Sentinel")
        return $false
    }

    $target = Join-Path $PSScriptRoot $Name
    $normalized = $body.TrimEnd("`r", "`n") + "`n"
    if (Test-Path -LiteralPath $target) {
        $existing = [System.IO.File]::ReadAllText($target)
        if ($existing.TrimEnd("`r", "`n") -ceq $normalized.TrimEnd("`r", "`n")) {
            Write-Host "$Name is already up to date"
            return $true
        }
    }

    # Write to a same-directory temp file and rename, so an interrupted write can
    # never truncate the running script. UTF-8 *without* a BOM: Set-Content
    # -Encoding UTF8 on 5.1 would prepend one and the file would stop matching
    # the repo byte for byte. The .bak is the escape hatch for a clone that had
    # uncommitted local edits.
    $temp = "$target.new.$PID"
    try {
        [System.IO.File]::WriteAllText(
            $temp, $normalized, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $target) {
            Copy-Item -LiteralPath $target -Destination "$target.bak" -Force
        }
        Move-Item -LiteralPath $temp -Destination $target -Force
    }
    catch {
        [Console]::Error.WriteLine("Warning: could not write ${Name}: $($_.Exception.Message)")
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
        return $false
    }

    Write-Host "Updated $Name from master (previous copy saved as $Name.bak)"
    return $true
}

# Extract the UC… channel id from a channel page, trying each known shape.
function Get-ChannelId {
    param([string]$Html)

    foreach ($pattern in @('channel_id=(UC[A-Za-z0-9_-]*)',
                           '"externalId":"(UC[A-Za-z0-9_-]*)',
                           '/channel/(UC[A-Za-z0-9_-]*)')) {
        $m = [regex]::Match($Html, $pattern)
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return ''
}

# Read the handle -> UC id map from ./channel-id-cache.txt (TAB separated).
# The file is a pure cache: deleting it only costs one page fetch per channel.
function Read-ChannelIdCache {
    $map = @{}
    if (-not (Test-Path -LiteralPath $channelIdCacheFile)) { return $map }
    try {
        # @() guards against Get-Content returning $null for an empty file, and
        # the BOM trim against Set-Content -Encoding UTF8 writing one in 5.1.
        foreach ($line in @(Get-Content -LiteralPath $channelIdCacheFile -Encoding UTF8)) {
            $parts = ([string]$line).TrimStart([char]0xFEFF).Trim() -split "`t", 2
            if ($parts.Count -eq 2 -and $parts[0] -ne '' -and $parts[1] -match '^UC[A-Za-z0-9_-]+$') {
                $map[$parts[0]] = $parts[1]
            }
        }
    }
    catch {
        [Console]::Error.WriteLine("Warning: could not read ${channelIdCacheFile}: $($_.Exception.Message)")
    }
    return $map
}

# Persist the handle -> UC id map. A cache write failure must never fail a run.
function Write-ChannelIdCache {
    param([hashtable]$Map)

    try {
        $lines = @()
        foreach ($key in ($Map.Keys | Sort-Object)) {
            $lines += ($key + "`t" + $Map[$key])
        }
        Set-Content -LiteralPath $channelIdCacheFile -Value $lines -Encoding UTF8
    }
    catch {
        [Console]::Error.WriteLine("Warning: could not write ${channelIdCacheFile}: $($_.Exception.Message)")
    }
}

# Last-resort channel id resolution using the vendored yt-dlp binary, which
# tracks YouTube's page layout far more closely than the regexes above. Stays
# logged-out (no --cookies) so the feed remains public-by-construction.
function Get-ChannelIdViaYtDlp {
    param([string]$ChannelUrl)

    $exe = Get-YtDlpPath
    if ($exe -eq '') { return '' }

    $result = Invoke-YtDlpMetadata -What "channel id for $ChannelUrl" -Arguments @(
        '--ignore-config', '--no-warnings', '--socket-timeout', $ytDlpTimeoutSec,
        '--retries', $ytDlpAttempts, '--extractor-retries', $ytDlpAttempts,
        '--flat-playlist', '--playlist-items', '0', '--print', 'playlist:%(channel_id)s', $ChannelUrl)
    $output = $result.Output

    foreach ($line in @($output)) {
        $candidate = ([string]$line).Trim()
        if ($candidate -match '^UC[A-Za-z0-9_-]+$') { return $candidate }
    }
    return ''
}

# Resolve a channel handle to its UC id. Returns a hashtable with Id and
# Source ('cache', 'page', 'yt-dlp') so the caller can retry a stale cache hit.
# Id is '' when every method failed.
function Resolve-ChannelId {
    param([string]$Handle, [string]$ChannelUrl, [hashtable]$Cache, [switch]$SkipCache)

    if (-not $SkipCache -and $Cache.ContainsKey($Handle)) {
        return @{ Id = $Cache[$Handle]; Source = 'cache' }
    }

    $html = Get-WebContent $ChannelUrl "channel page for @$Handle"
    if ($null -ne $html) {
        $channelId = Get-ChannelId $html
        if ($channelId -ne '') {
            $Cache[$Handle] = $channelId
            Write-ChannelIdCache $Cache
            return @{ Id = $channelId; Source = 'page' }
        }
        [Console]::Error.WriteLine("Warning: no channel_id found on $ChannelUrl")
    }

    $channelId = Get-ChannelIdViaYtDlp $ChannelUrl
    if ($channelId -ne '') {
        $Cache[$Handle] = $channelId
        Write-ChannelIdCache $Cache
        return @{ Id = $channelId; Source = 'yt-dlp' }
    }

    [Console]::Error.WriteLine("Warning: could not resolve a channel id for @$Handle")
    return @{ Id = ''; Source = 'none' }
}

# Newest <published> in a channel's Atom feed, in epoch ms.
# Returns -1 when the feed could not be read and 0 when it holds no entries —
# the two must stay distinguishable, or a network failure reads as an empty
# channel. That feed omits members-only videos, so it is public-by-construction.
function Get-FeedNewestMs {
    param([string]$ChannelId)

    $script:feedFetchFailed = $false
    $feedUrl = 'https://www.youtube.com/feeds/videos.xml?channel_id=' + $ChannelId
    $feed = Get-WebContent $feedUrl "video feed for $ChannelId"
    if ($null -eq $feed) {
        $script:feedFetchFailed = $true
        return [long](-1)
    }

    # Entries are not guaranteed to be date-sorted, so scan them all.
    $newest = [long]0
    $seen = 0
    foreach ($m in [regex]::Matches($feed, '<published>([^<]*)</published>')) {
        $seen++
        $epoch = ConvertTo-EpochMs $m.Groups[1].Value
        if ($null -eq $epoch) {
            [Console]::Error.WriteLine("Warning: unparsable <published> value '$($m.Groups[1].Value)' in $feedUrl")
        }
        elseif ($epoch -gt $newest) { $newest = $epoch }
    }
    if ($seen -gt 0 -and $newest -eq 0) { return [long](-1) }
    return $newest
}

function Format-RelativeVideoTime {
    param([string]$Timestamp)
    [long]$milliseconds = 0
    if (-not [long]::TryParse($Timestamp, [ref]$milliseconds) -or $milliseconds -le 0) { return '' }
    if ($milliseconds -lt 100000000000) { $milliseconds *= 1000 }
    $seconds = [Math]::Max(0, [Math]::Floor(([System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $milliseconds) / 1000))
    foreach ($unit in @(@('year',31536000),@('month',2592000),@('week',604800),@('day',86400),@('hour',3600),@('minute',60))) {
        $count = [Math]::Floor($seconds / [long]$unit[1])
        if ($count -ge 1) { return "$count $($unit[0])$(if ($count -ne 1) { 's' }) ago" }
    }
    return 'just now'
}

# Metadata probes must not outlive the wrapper indefinitely. yt-dlp's own
# socket timeout does not cover every extractor subprocess on Windows.
function Stop-ProcessTree {
    param([int]$ProcessId)

    foreach ($child in @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue)) {
        Stop-ProcessTree -ProcessId $child.ProcessId
    }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function ConvertTo-ProcessArgument {
    param([string]$Value)

    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + (($Value -replace '(\\*)"', '$1$1\\"') -replace '(\\*)$', '$1$1') + '"'
}

# Run a logged-out yt-dlp metadata command. The default wall-clock deadline can
# be disabled for callers that intentionally traverse a complete playlist.
function Invoke-YtDlpMetadata {
    param(
        [string[]]$Arguments,
        [string]$What,
        [int]$DeadlineSec = $ytDlpDeadlineSec,
        [string]$ProgressLabel = ''
    )

    $exe = Get-YtDlpPath
    if ($exe -eq '') { return @{ Output = @(); ExitCode = 1 } }
    $token = [guid]::NewGuid().ToString('N')
    $stdout = Join-Path $PSScriptRoot "yt-dlp.$token.stdout"
    $stderr = Join-Path $PSScriptRoot "yt-dlp.$token.stderr"
    try {
        $argumentLine = (($Arguments | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }) -join ' ')
        $process = Start-Process -FilePath $exe -ArgumentList $argumentLine -NoNewWindow `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
        # Windows PowerShell 5.1 loses ExitCode if the process exits before its
        # handle has been cached. Prime it immediately, before waiting.
        [void]$process.Handle
        $started = [System.DateTime]::UtcNow
        $lastHeartbeat = $started
        $stderrCount = 0
        while (-not $process.WaitForExit(1000)) {
            if ($ProgressLabel -ne '' -and (Test-Path -LiteralPath $stderr)) {
                $lines = @(Get-Content -LiteralPath $stderr -ErrorAction SilentlyContinue)
                for ($i = $stderrCount; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match '^(\[[^]]+\]|ERROR:|WARNING:|Aborting )' -and
                        $lines[$i] -notmatch '^\[debug\]') {
                        Write-Host "[$ProgressLabel] $($lines[$i])"
                    }
                }
                $stderrCount = $lines.Count
                if (([System.DateTime]::UtcNow - $lastHeartbeat).TotalSeconds -ge 15) {
                    $elapsed = [Math]::Floor(([System.DateTime]::UtcNow - $started).TotalSeconds)
                    Write-Host "[$ProgressLabel] Still running yt-dlp... $elapsed seconds elapsed"
                    $lastHeartbeat = [System.DateTime]::UtcNow
                }
            }
            if ($DeadlineSec -gt 0 -and
                ([System.DateTime]::UtcNow - $started).TotalSeconds -ge $DeadlineSec) {
                Stop-ProcessTree -ProcessId $process.Id
                [Console]::Error.WriteLine("Warning: yt-dlp metadata probe timed out after $DeadlineSec seconds for $What")
                return @{ Output = @(); ExitCode = 124 }
            }
        }
        if ($ProgressLabel -ne '' -and (Test-Path -LiteralPath $stderr)) {
            $lines = @(Get-Content -LiteralPath $stderr -ErrorAction SilentlyContinue)
            for ($i = $stderrCount; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^(\[[^]]+\]|ERROR:|WARNING:|Aborting )' -and
                    $lines[$i] -notmatch '^\[debug\]') {
                    Write-Host "[$ProgressLabel] $($lines[$i])"
                }
            }
        }
        $process.Refresh()
        return @{ Output = @(Get-Content -LiteralPath $stdout -ErrorAction SilentlyContinue); ExitCode = $process.ExitCode }
    }
    finally {
        Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue
    }
}

# Fall back to the newest few entries in the channel's uploads playlist when
# the legacy Atom feed is unavailable or unusable. Resolve the entries so
# yt-dlp can provide exact timestamps and public availability. No cookies are
# sent. Returns -1 when the fallback failed and 0 when no public entry was seen.
function Get-YtDlpNewestPublicMs {
    param([string]$ChannelId)

    $exe = Get-YtDlpPath
    if ($exe -eq '') {
        [Console]::Error.WriteLine(
            "Warning: yt-dlp binary not found for uploads fallback for $ChannelId")
        return [long](-1)
    }

    $uploadsId = 'UU' + $ChannelId.Substring(2)
    $uploadsUrl = 'https://www.youtube.com/playlist?list=' + $uploadsId
    $result = Invoke-YtDlpMetadata -What "uploads fallback for $ChannelId" -Arguments @(
        '--ignore-config', '--no-warnings', '--socket-timeout', $ytDlpTimeoutSec,
        '--retries', $ytDlpAttempts, '--extractor-retries', $ytDlpAttempts,
        '--skip-download', '--playlist-items', '1:5', '--print',
        'fallback:%(timestamp)s:%(availability)s', $uploadsUrl)
    $output = $result.Output
    $status = $result.ExitCode

    $newest = [long]0
    foreach ($line in @($output)) {
        $text = ([string]$line).Trim()
        if ($text -match '^fallback:([0-9]+):public$') {
            $epochMs = [long]$Matches[1] * 1000
            if ($epochMs -gt $newest) { $newest = $epochMs }
        }
    }
    if ($newest -gt 0) { return $newest }
    if ($status -ne 0) {
        [Console]::Error.WriteLine(
            "Warning: yt-dlp uploads fallback failed for $ChannelId ($uploadsUrl)")
        return [long](-1)
    }
    return [long]0
}

# Try the cheap Atom feed first, then the logged-out uploads-playlist fallback.
function Get-PublicNewestMsForChannelId {
    param([string]$ChannelId)

    if ($script:skipFeedFetches) {
        [Console]::Error.WriteLine(
            "Warning: skipping unreliable video feed for $ChannelId; using yt-dlp uploads fallback")
        return Get-YtDlpNewestPublicMs $ChannelId
    }

    $newest = Get-FeedNewestMs $ChannelId
    if ($script:feedFetchFailed -and -not $script:feedFailureCountedForChannel) {
        $script:feedFailureCountedForChannel = $true
        $script:feedFetchFailures++
        if ($script:feedFetchFailures -ge $script:feedFailureLimit) {
            $script:skipFeedFetches = $true
            [Console]::Error.WriteLine(
                "Warning: $($script:feedFetchFailures) video feeds failed; skipping feed fetches for remaining channels")
        }
    }
    if ($newest -gt 0) { return $newest }
    [Console]::Error.WriteLine(
        "Warning: using yt-dlp uploads fallback for $ChannelId")
    return Get-YtDlpNewestPublicMs $ChannelId
}

# Return the epoch-ms publish time of the newest public video on a channel,
# 0 when the channel genuinely has none, or -1 when the check could not be
# completed.
function Get-NewestPublicMs {
    param([string]$Handle, [string]$ChannelUrl, [hashtable]$Cache)

    $script:feedFailureCountedForChannel = $false
    $resolved = Resolve-ChannelId -Handle $Handle -ChannelUrl $ChannelUrl -Cache $Cache
    if ($resolved.Id -eq '') { return [long](-1) }

    $newest = Get-PublicNewestMsForChannelId $resolved.Id

    # If neither source can check a cached id, the handle may now point at a
    # different channel. Drop the stale entry and resolve once more.
    if ($newest -lt 0 -and $resolved.Source -eq 'cache') {
        [void]$Cache.Remove($Handle)
        Write-ChannelIdCache $Cache
        $resolved = Resolve-ChannelId -Handle $Handle -ChannelUrl $ChannelUrl -Cache $Cache -SkipCache
        if ($resolved.Id -eq '') { return [long](-1) }
        $newest = Get-PublicNewestMsForChannelId $resolved.Id
    }

    if ($newest -eq 0) {
        [Console]::Error.WriteLine(
            "Warning: no public videos found via the feed or uploads fallback for $($resolved.Id) (@$Handle)")
    }
    return $newest
}

# Overwrite ./checkpoint.txt with the current time in epoch milliseconds.
function Set-CheckpointNow {
    $now = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Set-CheckpointAt $now
}

function Set-CheckpointAt {
    param([long]$TimestampMs)

    Set-Content -LiteralPath $checkpointFile -Value ([string]$TimestampMs) -Encoding ASCII
    Write-Host "Checkpoint updated: $TimestampMs"
}

function Read-ChannelCheckStatus {
    if (-not (Test-Path -LiteralPath $channelStatusFile)) { return @{} }
    try {
        $value = Get-Content -Raw -LiteralPath $channelStatusFile | ConvertFrom-Json
        $result = @{}
        foreach ($property in $value.PSObject.Properties) { $result[$property.Name] = $property.Value }
        return $result
    }
    catch { [Console]::Error.WriteLine("Warning: could not read $channelStatusFile"); return @{} }
}

function Save-ChannelCheckStatus {
    param([hashtable]$Status)
    [System.IO.File]::WriteAllText($channelStatusFile, ($Status | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
}

function Record-ChannelCheck {
    param([hashtable]$Status, [string]$Channel, [long]$LatestVideoMs, [long]$CheckedMs)
    $prior = $Status[$Channel]
    $thumbnail = if ($null -ne $prior -and $null -ne $prior.PSObject.Properties['thumbnail']) { [string]$prior.thumbnail } else { '' }
    $Status[$Channel] = [pscustomobject]@{ checked_ms = $CheckedMs; latest_video_ms = $LatestVideoMs; thumbnail = $thumbnail }
}

function Get-ChannelThumbnail {
    param([string]$ChannelUrl)
    $page = Get-WebContent $ChannelUrl "channel profile for $ChannelUrl"
    if ($null -eq $page) { return '' }
    return [System.Net.WebUtility]::HtmlDecode([regex]::Match($page, '<meta property="og:image" content="([^"]+)"').Groups[1].Value)
}

# Protect a checkpoint from advancing past too many channels that were not
# successfully checked. "All" only applies when at least one channel was listed.
function Test-ShouldSkipCheckpoint {
    param([int]$Failures, [int]$ChannelCount)
    return $Failures -ge 3 -or ($ChannelCount -gt 0 -and $Failures -eq $ChannelCount)
}

# Build a local page from every qualifying public entry on each /videos tab.
# Its token-protected
# loopback callback starts the selected yy1/yy2 local PowerShell hooks.
function New-VideoHtml {
    param([string]$CallbackUrl, [hashtable]$ChannelStatus)
    $exe = Get-YtDlpPath
    if ($exe -eq '') { [Console]::Error.WriteLine('Error: yt-dlp binary not found next to this script'); return $false }
    if (-not (Test-Path -LiteralPath $channelsFile)) { [Console]::Error.WriteLine("Error: $channelsFile does not exist"); return $false }
    $checkpointMs = Read-CheckpointMs
    $checkpointSec = [Math]::Floor($checkpointMs / 1000)
    $checkpointDayStartSec = $checkpointSec - ($checkpointSec % 86400)
    $scanCutoffSec = [Math]::Max(0, $checkpointDayStartSec - 86400)
    $checkpointAge = Format-RelativeVideoTime $checkpointMs
    $failures = 0
    $checkBatchMs = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Write-Host "Generating HTML from /videos tabs newer than checkpoint $checkpointMs ($checkpointAge)..."
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>YouTube Video Download</title>')
    [void]$sb.AppendLine('<style>:root{--bg:#0d1117;--card:#161b22;--bd:#30363d;--fg:#e6edf3;--mut:#8b949e;--acc:#58a6ff;--ok:#3fb950}*{box-sizing:border-box}body{margin:0;padding:16px 60px;background:var(--bg);color:var(--fg);font:14px/1.55 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif}h1{font-size:32px;margin:0 0 6px;color:var(--fg);border-bottom:3px solid var(--acc);padding-bottom:8px}h2{font-size:22px;margin:0;color:var(--acc)}p{color:var(--mut);font-size:12.5px;margin:0 0 16px}button{background:#21262d;color:var(--fg);border:1px solid var(--bd);border-radius:6px;padding:5px 10px;cursor:pointer;font:inherit}button:hover{border-color:var(--acc);background:#1c2230}.grid{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:12px;margin:12px 0 28px}.card{background:var(--card);border:1px solid var(--bd);padding:10px;border-radius:10px}.video-link{display:block;color:var(--fg);text-decoration:none}.video-link:hover{color:var(--acc)}.preview{position:relative;aspect-ratio:16/9;background:#0b0f14;overflow:hidden;border-radius:6px}.preview img{width:100%;height:100%;object-fit:cover;transition:transform .2s ease,filter .2s ease}.card:hover .preview img{transform:scale(1.04);filter:brightness(.82)}.video-title{font-size:12px;line-height:1.4;margin-top:7px}.checks,.controls,.channel-title{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.checks{margin-top:8px;color:var(--mut)}.channel{margin-top:28px}.channel-title{padding-bottom:6px;border-bottom:1px solid var(--bd)}.controls button{padding:4px 9px}.job-log{max-height:190px;overflow:auto;background:#010409;border:1px solid var(--bd);border-radius:6px;padding:8px;color:var(--mut);white-space:pre-wrap;font:12px/1.4 Consolas,monospace}.back-to-top{position:fixed;bottom:24px;right:24px;width:48px;height:48px;border-radius:50%;background:var(--acc);color:var(--bg);border:none;cursor:pointer;box-shadow:0 2px 8px rgba(0,0,0,.45);display:none;font-size:34px;font-weight:700;line-height:1}.back-to-top.visible{display:flex;align-items:center;justify-content:center}.back-to-top:hover{background:#79c0ff}@media(max-width:1100px){body{padding:16px}.grid{grid-template-columns:repeat(3,minmax(0,1fr))}}@media(max-width:650px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}}</style></head><body>')
    [void]$sb.AppendLine('<style>.video-age{font-size:11px;color:var(--mut);margin-top:3px}.channel-bar{height:8px;background:var(--acc);margin:42px 0 12px}.channel-table{width:100%;border-collapse:collapse;margin-top:12px}.channel-table th,.channel-table td{padding:8px;border-bottom:1px solid var(--bd);text-align:left}.channel-table th{color:var(--mut)}.channel-table a{color:var(--acc)}#channel-add{width:27em}</style>')
    [void]$sb.AppendLine('<h1>YouTube Video Download</h1><p>Select y1 and/or y2, then click DOWNLOAD SELECTED to run the matching local yy hook. <span id="checkpoint-value">Checkpoint: ' + $checkpointMs + '</span></p><div class="controls"><button id="download" type="button">DOWNLOAD SELECTED</button><button id="checkpoint" type="button">CHECKPOINT</button><button id="refresh" type="button">REFRESH</button><button id="stop" type="button">STOP SERVER</button><button data-action="y1" type="button">y1</button><button data-action="y2" type="button">y2</button><button data-action="none" type="button">none</button></div><p id="status"></p><pre id="job-log" class="job-log"></pre><main>')
    foreach ($rawLine in @(Get-Content -LiteralPath $channelsFile -Encoding UTF8)) {
        $channel = ([string]$rawLine).TrimStart([char]0xFEFF).Trim()
        if ($channel -eq '' -or $channel.StartsWith('#')) { continue }
        if ($channel.StartsWith('@')) { $channel = $channel.Substring(1) }
        $channelUrl = Get-ChannelUrl $channel
        Write-Host "Checking @$channel..."
        # Approximate tab dates can precede the exact publication time. Start at
        # midnight UTC on the day before the checkpoint date and keep the overlap
        # rather than resolving watch pages; this favors coverage over precision.
        $scan = Invoke-YtDlpMetadata -What "videos tab scan for @$channel" -DeadlineSec 0 `
            -ProgressLabel "@$channel scan" -Arguments @(
            '--ignore-config', '--verbose', '--cookies', './cookies.txt',
            '--flat-playlist', '--lazy-playlist', '--extractor-args', 'youtubetab:approximate_date',
            '--socket-timeout', $ytDlpTimeoutSec,
            '--retries', $ytDlpAttempts, '--extractor-retries', $ytDlpAttempts,
            '--skip-download', '--break-match-filters', "timestamp >= $scanCutoffSec", '--print',
            ("scan:%(id)s`t%(webpage_url)s`t%(title)s`t%(timestamp)s`t%(availability)s"), $channelUrl)
        if ($scan.ExitCode -notin @(0, 101)) { [Console]::Error.WriteLine("Warning: could not scan the videos tab for @$channel"); $failures++; continue }
        $rows = New-Object System.Collections.ArrayList
        foreach ($scanRow in @($scan.Output)) {
            $scanParts = [regex]::Split([string]$scanRow, "`t", 5)
            if ($scanParts.Count -lt 5 -or -not $scanParts[0].StartsWith('scan:')) { continue }
            if ($scanParts[4] -in @('subscriber_only', 'private', 'premium_only')) { continue }
            [long]$approximateMs = 0
            if (-not [long]::TryParse($scanParts[3], [ref]$approximateMs)) { continue }
            if ($approximateMs -lt 100000000000) { $approximateMs *= 1000 }
            $scanId = $scanParts[0].Substring(5)
            $scanThumbnail = "https://i.ytimg.com/vi/$scanId/hqdefault.jpg"
            [void]$rows.Add("row:$scanId`t$($scanParts[1])`t$scanThumbnail`t$($scanParts[2])`t$approximateMs")
        }
        $cards = New-Object System.Text.StringBuilder
        $newest = [long]0
        $qualifiedCount = 0
        foreach ($row in @($rows)) {
            $parts = [regex]::Split([string]$row, "`t", 5)
            if ($parts.Count -lt 5 -or -not $parts[0].StartsWith('row:')) { continue }
            [long]$videoMs = 0
            if (-not [long]::TryParse($parts[4], [ref]$videoMs)) { continue }
            if ($videoMs -lt 100000000000) { $videoMs *= 1000 }
            if ($videoMs -gt $newest) { $newest = $videoMs }
            $id = $parts[0].Substring(4); $url = $parts[1]; $thumb = $parts[2]; $title = $parts[3]; $age = Format-RelativeVideoTime $videoMs
            if ($id -eq '' -or $url -eq '') { continue }
            $eUrl = [System.Net.WebUtility]::HtmlEncode($url); $eThumb = [System.Net.WebUtility]::HtmlEncode($thumb); $eTitle = [System.Net.WebUtility]::HtmlEncode($title)
            $downloadPath = [System.Net.WebUtility]::HtmlEncode('./' + $channel)
            $card = '<article class="card"><a class="video-link" href="{2}" target="_blank" rel="noopener noreferrer"><div class="preview"><img src="{0}" alt=""></div><div class="video-title">{1}</div></a><div class="video-age">{3}</div><div class="checks"><label><input class="y1" data-url="{2}" data-path="{4}" type="checkbox"> y1</label><label><input class="y2" data-url="{2}" data-path="{4}" type="checkbox"> y2</label></div></article>' -f $eThumb, $eTitle, $eUrl, ([System.Net.WebUtility]::HtmlEncode($age)), $downloadPath
            [void]$cards.AppendLine($card)
            $qualifiedCount++
        }
        Write-Host "@${channel}: $qualifiedCount visible video(s) in the checkpoint overlap"
        Record-ChannelCheck $ChannelStatus $channel $newest $checkBatchMs
        if ($cards.Length -gt 0) {
            [void]$sb.AppendLine('<section class="channel"><div class="channel-title"><h2>' + [System.Net.WebUtility]::HtmlEncode($channel) + '</h2><div class="controls"><button data-action="y1" type="button">y1</button><button data-action="y2" type="button">y2</button><button data-action="none" type="button">none</button></div></div><div class="grid">')
            [void]$sb.Append($cards.ToString())
            [void]$sb.AppendLine('</div></section>')
        }
    }
    [void]$sb.AppendLine('<section class="channel"><div class="channel-bar"></div><div class="channel-title"><h2>Channel IDs</h2></div><div class="controls"><input id="channel-add" placeholder="@channel or UC channel id"><button id="channel-add-button" type="button">add</button></div><table class="channel-table"><thead><tr><th>Profile</th><th>Channel</th><th>Last checked</th><th>Latest video</th><th></th></tr></thead><tbody>')
    $managedChannels = @()
    foreach ($rawLine in @(Get-Content -LiteralPath $channelsFile -Encoding UTF8)) {
        $channel = ([string]$rawLine).TrimStart([char]0xFEFF).Trim()
        if ($channel -eq '' -or $channel.StartsWith('#')) { continue }
        $key = $channel.TrimStart('@'); $record = $ChannelStatus[$key]; $managedChannels += [pscustomobject]@{ Channel=$channel; Key=$key; Checked=if($null -ne $record){[long]$record.checked_ms}else{0}; Latest=if($null -ne $record){[long]$record.latest_video_ms}else{0}; Thumbnail=if($null -ne $record -and $null -ne $record.PSObject.Properties['thumbnail']){[string]$record.thumbnail}else{''} }
    }
    foreach ($entry in @($managedChannels | Sort-Object @{Expression={[long]$_.Checked};Descending=$true}, @{Expression={[long]$_.Latest};Descending=$true})) {
        $checkedText = if ($entry.Checked) { Format-RelativeVideoTime $entry.Checked } else { 'never' }
        $latestText = if ($entry.Latest) { Format-RelativeVideoTime $entry.Latest } else { 'unknown' }
        $channelUrl = Get-ChannelUrl $entry.Key
        if ($entry.Thumbnail -eq '') {
            $entry.Thumbnail = Get-ChannelThumbnail $channelUrl
            if ($entry.Thumbnail -ne '') {
                if ($null -eq $ChannelStatus[$entry.Key]) {
                    $ChannelStatus[$entry.Key] = [pscustomobject]@{
                        checked_ms = [long]0
                        latest_video_ms = [long]0
                        thumbnail = $entry.Thumbnail
                    }
                }
                elseif ($null -eq $ChannelStatus[$entry.Key].PSObject.Properties['thumbnail']) {
                    $ChannelStatus[$entry.Key] | Add-Member -NotePropertyName thumbnail -NotePropertyValue $entry.Thumbnail
                }
                else {
                    $ChannelStatus[$entry.Key].thumbnail = $entry.Thumbnail
                }
            }
        }
        $avatar = if ($entry.Thumbnail) { '<img src="' + [System.Net.WebUtility]::HtmlEncode($entry.Thumbnail) + '" alt="" width="42" height="42" style="border-radius:50%;object-fit:cover">' } else { '' }
        [void]$sb.AppendLine('<tr><td>' + $avatar + '</td><td><a href="' + [System.Net.WebUtility]::HtmlEncode($channelUrl) + '" target="_blank" rel="noopener noreferrer">' + [System.Net.WebUtility]::HtmlEncode($entry.Channel) + '</a></td><td>' + [System.Net.WebUtility]::HtmlEncode($checkedText) + '</td><td>' + [System.Net.WebUtility]::HtmlEncode($latestText) + '</td><td><button class="channel-delete" data-channel="' + [System.Net.WebUtility]::HtmlEncode($entry.Channel) + '" type="button">delete</button></td></tr>')
    }
    Save-ChannelCheckStatus $ChannelStatus
    [void]$sb.AppendLine('</tbody></table></section>')
    [void]$sb.AppendLine('<button id="back-to-top" class="back-to-top" type="button" onclick="window.scrollTo({top:0,behavior:''smooth''})" aria-label="Back to top" title="Back to top">&uarr;</button><script>const callback="' + $CallbackUrl + '",statusUrl="' + ($CallbackUrl -replace '/download/', '/status/') + '",stopUrl="' + ($CallbackUrl -replace '/download/', '/stop/') + '";const status=document.querySelector("#status"),jobLog=document.querySelector("#job-log"),setChecks=(root,action)=>root.querySelectorAll("input.y1,input.y2").forEach(x=>{if(action==="none")x.checked=false;else if(x.className===action)x.checked=true}),showJobs=async()=>{try{const r=await fetch(statusUrl),b=await r.json(),p=[];if(b.running)p.push(b.running+" running");if(b.queued)p.push(b.queued+" queued");if(b.completed)p.push(b.completed+" completed");if(b.failed)p.push(b.failed+" failed");status.textContent=p.length?p.join(", ")+"." : "No download jobs yet.";jobLog.textContent=(b.logs||[]).join("\n");if(b.running||b.queued)setTimeout(showJobs,1000)}catch(e){status.textContent="Status unavailable: "+e.message}};document.addEventListener("click",e=>{const b=e.target.closest("button[data-action]");if(b)setChecks(b.closest(".channel")||document,b.dataset.action)});document.querySelector("#download").onclick=async()=>{const items=[...document.querySelectorAll("input:checked")].map(x=>({target:x.className,url:x.dataset.url,path:x.dataset.path}));if(!items.length){status.textContent="Select at least one video";return}status.textContent="Starting local downloads...";try{const r=await fetch(callback,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({items})}),b=await r.json();status.textContent=b.message||"Started";showJobs()}catch(e){status.textContent="Callback failed: "+e.message}};document.querySelector("#stop").onclick=async()=>{try{const r=await fetch(stopUrl,{method:"POST"}),b=await r.json();status.textContent=b.message||"Server stopped"}catch(e){status.textContent="Server stopped"}window.close();setTimeout(()=>location.replace("about:blank"),150)};showJobs();const backToTop=document.querySelector("#back-to-top"),toggleTop=()=>backToTop.classList.toggle("visible",window.scrollY>200);window.addEventListener("scroll",toggleTop,{passive:true});toggleTop();</script></main></body></html>')
    $pageText = $sb.ToString().Replace('if(b.running||b.queued)setTimeout(showJobs,1000)}catch(e){status.textContent="Status unavailable: "+e.message}', 'setTimeout(showJobs,1000)}catch(e){status.textContent="Status unavailable: "+e.message}')
    $pageText = $pageText.Replace('jobLog.textContent=(b.logs||[]).join("\n");', 'jobLog.textContent=(b.logs||[]).join("\n");jobLog.scrollTop=jobLog.scrollHeight;')
    $heartbeatUrl = $CallbackUrl -replace '/download/', '/heartbeat/'
    $pageText = $pageText.Replace('showJobs();const backToTop', 'setInterval(()=>fetch("' + $heartbeatUrl + '",{method:"POST",keepalive:true}),2000);showJobs();const backToTop')
    $pageText = $pageText.Replace('setInterval(()=>fetch("' + $heartbeatUrl + '",{method:"POST",keepalive:true}),2000);showJobs();const backToTop', 'setInterval(()=>fetch("' + $heartbeatUrl + '",{method:"POST",keepalive:true}),2000);showJobs();const backToTop')
    $channelUrl = $CallbackUrl -replace '/download/', '/channel/'; $checkpointUrl = $CallbackUrl -replace '/download/', '/checkpoint/'; $refreshUrl = $CallbackUrl -replace '/download/', '/refresh/'
    $pageText = $pageText.Replace('</script></main>', '</script><script>const postJson=(u,x)=>fetch(u,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(x)}),refreshPage=async()=>{status.textContent="Refreshing channels...";try{const b=await (await fetch("' + $refreshUrl + '",{method:"POST"})).json();status.textContent=b.message;if(!b.message||b.message==="Refreshing page.")location.reload()}catch(e){status.textContent="Refresh failed: "+e.message}};document.querySelector("#checkpoint").onclick=async()=>{const b=await (await fetch("' + $checkpointUrl + '",{method:"POST"})).json();status.textContent=b.message;if(b.checkpoint_ms)document.querySelector("#checkpoint-value").textContent="Checkpoint: "+b.checkpoint_ms};document.querySelector("#refresh").onclick=refreshPage;document.querySelector("#channel-add-button").onclick=async()=>{const x=document.querySelector("#channel-add").value.trim();if(x){await postJson("' + $channelUrl + '",{action:"add",channel:x});refreshPage()}};document.querySelectorAll(".channel-delete").forEach(b=>b.onclick=async()=>{await postJson("' + $channelUrl + '",{action:"delete",channel:b.dataset.channel});refreshPage()});</script></main>')
    $sb.Clear() | Out-Null
    [void]$sb.Append($pageText)
    $path = Join-Path $PSScriptRoot 'yy.html'
    [System.IO.File]::WriteAllText($path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    Save-ChannelCheckStatus $ChannelStatus
    $script:htmlFailureCount = $failures
    Write-Host "Generated ./yy.html"
    return $true
}

# The browser submits structured selections to this one-shot, loopback-only
# listener. It never accepts shell text: each item must name yy1/yy2 and a
# YouTube URL before the corresponding local PowerShell hook is started.
function Test-VideoSelection {
    param($Item)

    if ($null -eq $Item -or $Item.target -notin @('y1', 'y2')) { return $false }
    if ([string]$Item.path -notmatch '^\./[^\\/:*?"<>|]+$' -or [string]$Item.path -match '^\./\.{1,2}$') { return $false }
    try { $uri = [uri]$Item.url } catch { return $false }
    if ($uri.Scheme -notin @('http', 'https')) { return $false }
    return $uri.Host -eq 'youtu.be' -or $uri.Host -eq 'youtube.com' -or $uri.Host.EndsWith('.youtube.com')
}

function Start-SelectedVideoHooks {
    param($Items, [hashtable]$Jobs)

    $selected = @($Items)
    if ($selected.Count -eq 0) { throw 'No video selections received' }
    $started = 0
    # yy2 must drain before yy1, while preserving the page's order within each
    # destination. Only the scheduler below starts processes.
    foreach ($item in @($selected | Sort-Object @{ Expression = { if ($_.target -eq 'y2') { 0 } else { 1 } }; Ascending = $true })) {
        if (-not (Test-VideoSelection $item)) { throw 'Invalid video selection received' }
        $hookName = 'y' + $item.target + '.ps1'
        $hook = Get-Command $hookName -CommandType ExternalScript -ErrorAction SilentlyContinue
        if ($null -eq $hook) { throw "Local $hookName hook was not found" }
        $Jobs[[guid]::NewGuid().ToString('N')] = [pscustomobject]@{
            Target = [string]$item.target; Url = [string]$item.url; DownloadPath = [string]$item.path; Hook = [string]$hook.Source; Order = $started; Process = $null; State = 'queued'; ExitCode = $null; OutputPath = ''; ErrorPath = ''; OutputLines = 0; ErrorLines = 0; Logs = @(); Succeeded = $false
        }
        Write-Host "Queued: $($hook.Source) -p $($item.path) -t $($item.url)"
        $started++
    }
    return $started
}

function Start-NextDownloadJob {
    param([hashtable]$Jobs)

    $job = @($Jobs.Values | Where-Object { $_.State -eq 'queued' } | Sort-Object Order) | Select-Object -First 1
    if ($null -eq $job) { return $false }
    $safeHook = ([string]$job.Hook).Replace("'", "''")
    $safePath = ([string]$job.DownloadPath).Replace("'", "''")
    $safeUrl = ([string]$job.Url).Replace("'", "''")
    $command = "`$ProgressPreference = 'SilentlyContinue'; & '$safeHook' '-p' '$safePath' '-t' '$safeUrl'; exit `$LASTEXITCODE"
    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
    $logBase = Join-Path $env:TEMP ('yy-html-job-' + [guid]::NewGuid().ToString('N'))
    Write-Host "Running: $($job.Hook) -p $($job.DownloadPath) -t $($job.Url)"
    $job.Process = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-OutputFormat', 'Text', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand) -RedirectStandardOutput ($logBase + '.out') -RedirectStandardError ($logBase + '.err') -PassThru
    $job.OutputPath = $logBase + '.out'; $job.ErrorPath = $logBase + '.err'; $job.State = 'running'
    return $true
}

function Get-DownloadJobStatus {
    param([hashtable]$Jobs, [System.Collections.ArrayList]$ServerLogs)

    $running = 0; $queued = 0; $completed = 0; $failed = 0
    foreach ($job in @($Jobs.Values)) {
        foreach ($logSource in @(@{ Path = $job.OutputPath; Count = 'OutputLines' }, @{ Path = $job.ErrorPath; Count = 'ErrorLines' })) {
            if ($logSource.Path -eq '') { continue }
            if (-not (Test-Path -LiteralPath $logSource.Path)) { continue }
            $lines = @(Get-Content -LiteralPath $logSource.Path -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '^(#< CLIXML|<Objs Version=)' })
            $oldCount = [int]$job.PSObject.Properties[$logSource.Count].Value
            if ($lines.Count -gt $oldCount) {
                foreach ($line in @($lines[$oldCount..($lines.Count - 1)])) {
                    $entry = "[$($job.Target)] $line"
                    Write-Host $entry
                    [void]$ServerLogs.Add($entry)
                    if ($line -match '^\[download\].*(has already been downloaded|100%)') { $job.Succeeded = $true }
                }
                $job.PSObject.Properties[$logSource.Count].Value = $lines.Count
            }
        }
        if ($job.State -eq 'running') {
            try {
                if ($job.Process.HasExited) {
                    $job.ExitCode = $job.Process.ExitCode
                    $job.State = if ($job.ExitCode -eq 0 -or $job.Succeeded) { 'completed' } else { 'failed' }
                }
            }
            catch { $job.State = 'failed' }
        }
        if ($job.State -eq 'running') { $running++ }
        elseif ($job.State -eq 'queued') { $queued++ }
        elseif ($job.State -eq 'completed') { $completed++ }
        else { $failed++ }
    }
    if ($running -eq 0 -and $queued -gt 0) {
        [void](Start-NextDownloadJob $Jobs)
        $running = 1; $queued--
    }
    return @{ running = $running; queued = $queued; completed = $completed; failed = $failed; logs = @($ServerLogs | Select-Object -Last 80) }
}

function Send-CallbackJson {
    param($Context, [int]$StatusCode, $Value)

    $body = [System.Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Compress))
    try {
        $Context.Response.StatusCode = $StatusCode
        $Context.Response.Headers['Access-Control-Allow-Origin'] = '*'
        $Context.Response.Headers['Access-Control-Allow-Methods'] = 'POST, OPTIONS'
        $Context.Response.Headers['Access-Control-Allow-Headers'] = 'Content-Type'
        $Context.Response.ContentType = 'application/json; charset=utf-8'
        $Context.Response.ContentLength64 = $body.Length
        $Context.Response.OutputStream.Write($body, 0, $body.Length)
    }
    catch {
        # The browser can abandon heartbeat/status requests while a refresh is
        # rebuilding the page. PowerShell may wrap the underlying listener or
        # I/O exception, so any failure to reply must not stop the server.
    }
    finally {
        try { $Context.Response.Close() } catch { }
    }
}

function Send-CallbackResponse {
    param($Context, [int]$StatusCode, [string]$Message)

    Send-CallbackJson $Context $StatusCode @{ message = $Message }
}

function Invoke-HtmlCallbackServer {
    param([string]$Token, [string]$CallbackUrl, [hashtable]$ChannelStatus)

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add('http://127.0.0.1:8080/')
    $jobs = @{}
    $serverLogs = New-Object System.Collections.ArrayList
    $lastHeartbeat = [System.DateTime]::UtcNow
    $script:htmlStopRequested = $false
    $script:htmlListener = $listener
    $cancelHandler = [ConsoleCancelEventHandler]{
        param($sender, $event)
        $event.Cancel = $true
        $script:htmlStopRequested = $true
        if ($script:htmlListener.IsListening) { $script:htmlListener.Stop() }
    }
    try { $listener.Start() }
    catch {
        [Console]::Error.WriteLine("Error: http://127.0.0.1:8080 is unavailable: $($_.Exception.Message)")
        return $false
    }
    try {
        [Console]::add_CancelKeyPress($cancelHandler)
        Open-Url 'http://127.0.0.1:8080/'
        Write-Host 'Waiting for DOWNLOAD SELECTED on http://127.0.0.1:8080/ (Ctrl+C or STOP SERVER exits)'
        while ($listener.IsListening -and -not $script:htmlStopRequested) {
            $pending = $listener.BeginGetContext($null, $null)
            try {
                while (-not $pending.AsyncWaitHandle.WaitOne(1000)) {
                    if ($script:htmlStopRequested -or -not $listener.IsListening) { break }
                    if (([System.DateTime]::UtcNow - $lastHeartbeat).TotalSeconds -ge 30) {
                        Write-Host 'HTML page closed or disconnected; stopping server.'
                        $script:htmlStopRequested = $true
                        $listener.Stop()
                        break
                    }
                }
                if ($script:htmlStopRequested -or -not $listener.IsListening) { break }
                $context = $listener.EndGetContext($pending)
            }
            catch {
                if ($script:htmlStopRequested -or -not $listener.IsListening) { break }
                throw
            }
            if ($context.Request.HttpMethod -eq 'GET' -and $context.Request.Url.AbsolutePath -eq '/') {
                $body = [System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'yy.html'))
                $context.Response.ContentType = 'text/html; charset=utf-8'
                $context.Response.ContentLength64 = $body.Length
                $context.Response.OutputStream.Write($body, 0, $body.Length)
                $context.Response.Close()
                continue
            }
            if ($context.Request.HttpMethod -eq 'GET' -and $context.Request.Url.AbsolutePath -eq "/status/$Token") {
                Send-CallbackJson $context 200 (Get-DownloadJobStatus $jobs $serverLogs)
                continue
            }
            if ($context.Request.HttpMethod -eq 'OPTIONS' -and $context.Request.Url.AbsolutePath -in @("/download/$Token", "/stop/$Token")) {
                $context.Response.StatusCode = 204
                $context.Response.Headers['Access-Control-Allow-Origin'] = '*'
                $context.Response.Headers['Access-Control-Allow-Methods'] = 'POST, OPTIONS'
                $context.Response.Headers['Access-Control-Allow-Headers'] = 'Content-Type'
                $context.Response.Close()
                continue
            }
            if ($context.Request.HttpMethod -eq 'POST' -and $context.Request.Url.AbsolutePath -eq "/heartbeat/$Token") {
                $lastHeartbeat = [System.DateTime]::UtcNow
                Send-CallbackResponse $context 200 ''
                continue
            }
            if ($context.Request.HttpMethod -eq 'POST' -and $context.Request.Url.AbsolutePath -eq "/stop/$Token") {
                Send-CallbackResponse $context 200 'Server stopped.'
                break
            }
            if ($context.Request.HttpMethod -eq 'POST' -and $context.Request.Url.AbsolutePath -eq "/checkpoint/$Token") {
                $checkpointMs = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                Set-CheckpointAt $checkpointMs
                Send-CallbackJson $context 200 @{ message = 'Checkpoint updated.'; checkpoint_ms = $checkpointMs }
                continue
            }
            if ($context.Request.HttpMethod -eq 'POST' -and $context.Request.Url.AbsolutePath -eq "/refresh/$Token") {
                Write-Host 'Refreshing HTML page from channel-ids.txt...'
                # Reply before the potentially long channel scan. The browser
                # immediately queues a reload, which this single-threaded server
                # answers after yy.html has been regenerated.
                Send-CallbackResponse $context 202 'Refreshing page.'
                if (-not (New-VideoHtml -CallbackUrl $CallbackUrl -ChannelStatus $ChannelStatus)) {
                    [Console]::Error.WriteLine('Warning: could not refresh the page; keeping the previous page.')
                }
                # Heartbeats cannot be accepted while the single-threaded server
                # is regenerating the page. Do not mistake that expected pause
                # for the browser having closed as soon as generation finishes.
                $lastHeartbeat = [System.DateTime]::UtcNow
                continue
            }
            if ($context.Request.HttpMethod -eq 'POST' -and $context.Request.Url.AbsolutePath -eq "/channel/$Token") {
                $reader = New-Object System.IO.StreamReader($context.Request.InputStream, [System.Text.Encoding]::UTF8)
                try { $change = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
                $channel = ([string]$change.channel).Trim()
                if ($channel -eq '' -or $channel -match '[\r\n#]') { Send-CallbackResponse $context 400 'Invalid channel id.'; continue }
                $lines = @(Get-Content -LiteralPath $channelsFile -Encoding UTF8)
                if ($change.action -eq 'delete') { $lines = @($lines | Where-Object { $_.Trim() -ne $channel }) }
                elseif ($change.action -eq 'add' -and -not (@($lines | Where-Object { $_.Trim() -eq $channel }).Count)) { $lines += $channel }
                else { Send-CallbackResponse $context 400 'Invalid channel action.'; continue }
                [System.IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'channel-ids.txt'), [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
                Send-CallbackResponse $context 200 'Channel IDs updated. Refreshing page.'
                continue
            }
            if ($context.Request.HttpMethod -ne 'POST' -or $context.Request.Url.AbsolutePath -ne "/download/$Token") {
                Send-CallbackResponse $context 404 'Not found'
                continue
            }
            $reader = New-Object System.IO.StreamReader($context.Request.InputStream, [System.Text.Encoding]::UTF8)
            try { $payload = $reader.ReadToEnd() | ConvertFrom-Json }
            finally { $reader.Dispose() }
            try {
                $started = Start-SelectedVideoHooks $payload.items $jobs
                Send-CallbackResponse $context 200 "Started $started local download job(s)."
                continue
            }
            catch {
                Send-CallbackResponse $context 400 $_.Exception.Message
                continue
            }
        }
    }
    finally {
        [Console]::remove_CancelKeyPress($cancelHandler)
        $script:htmlListener = $null
        if ($listener.IsListening) { $listener.Stop() }
        $listener.Close()
    }
}

# Implement -o (check against the checkpoint) and -O (open everything).
# Returns the number of listed channels and the number whose check failed.
function Invoke-OpenMode {
    param([string]$Mode, [hashtable]$ChannelStatus)

    if (-not (Test-Path -LiteralPath $channelsFile)) {
        [Console]::Error.WriteLine("Error: $channelsFile does not exist")
        exit 1
    }
    $checkpointMs = [long]0
    if ($Mode -eq 'check') {
        $script:feedFetchFailures = 0
        $script:skipFeedFetches = $false
        $checkpointMs = Read-CheckpointMs
        Write-Host "Checkpoint: $checkpointMs"
    }
    $cache = Read-ChannelIdCache
    $failures = 0
    $checkBatchMs = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $channelCount = 0
    # -Encoding UTF8 matters: Windows PowerShell 5.1 otherwise reads the file as
    # ANSI and mangles non-ASCII channel handles.
    foreach ($line in @(Get-Content -LiteralPath $channelsFile -Encoding UTF8)) {
        $channel = ([string]$line).TrimStart([char]0xFEFF).Trim()
        if ($channel -eq '' -or $channel.StartsWith('#')) { continue }
        $channelCount++
        if ($channel.StartsWith('@')) { $channel = $channel.Substring(1) }
        $channelUrl = Get-ChannelUrl $channel

        if ($Mode -eq 'open') {
            Open-Url $channelUrl
            continue
        }

        $newest = Get-NewestPublicMs -Handle $channel -ChannelUrl $channelUrl -Cache $cache
        if ($newest -lt 0) {
            $failures++
            Write-Host "${channel}: CHECK FAILED (see warnings above; not opened)"
        }
        else {
            Record-ChannelCheck $ChannelStatus $channel $newest $checkBatchMs
            if ($newest -eq 0) {
            Write-Host "${channel}: no public videos found (skipped)"
            }
            elseif ($newest -gt $checkpointMs) {
            Write-Host "${channel}: new public video ($newest > $checkpointMs)"
            Open-Url $channelUrl
            }
            else {
            Write-Host "${channel}: up to date ($newest <= $checkpointMs)"
            }
        }
    }
    if ($failures -gt 0) {
        [Console]::Error.WriteLine("Error: $failures channel check(s) failed")
    }
    Save-ChannelCheckStatus $ChannelStatus
    return @{ Failures = $failures; ChannelCount = $channelCount }
}

$currentUrl = ''

if (-not [string]::IsNullOrEmpty($Url)) {
    $currentUrl = $Url
    Set-Content -LiteralPath $urlFile -Value $currentUrl -NoNewline:$false
}
elseif (Test-Path -LiteralPath $urlFile) {
    $currentUrl = (Get-Content -LiteralPath $urlFile -TotalCount 1)
    if ($null -eq $currentUrl) { $currentUrl = '' }
}

$runUrl = $currentUrl
if (-not [string]::IsNullOrEmpty($TempUrl)) {
    $runUrl = $TempUrl
}

if ($Update) {
    $exe = Get-YtDlpPath
    if ($exe -eq '') {
        [Console]::Error.WriteLine('Error: yt-dlp binary not found next to this script')
        exit 1
    }
    Invoke-YCommand $exe -U
    if (Update-Self 'yy.ps1' '#!/usr/bin/env pwsh') { exit 0 }
    exit 1
}

$openFailures = 0
$openChannelCount = 0
$checkpointAfterChecksMs = [long]0
$channelCheckStatus = Read-ChannelCheckStatus
if ($OpenMode -ne '') {
    if ($OpenMode -eq 'html') {
        $token = [guid]::NewGuid().ToString('N')
        $callbackUrl = 'http://127.0.0.1:8080/download/' + $token
        if (-not (New-VideoHtml -CallbackUrl $callbackUrl -ChannelStatus $channelCheckStatus)) { $openFailures = 1 }
        if ($openFailures -eq 0) { $checkpointAfterChecksMs = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
        if ($openFailures -eq 0 -and -not (Invoke-HtmlCallbackServer -Token $token -CallbackUrl $callbackUrl -ChannelStatus $channelCheckStatus)) { $openFailures = 1 }
        if ($htmlFailureCount -gt 0) { $openFailures = 1 }
    }
    else {
        $openResult = Invoke-OpenMode $OpenMode $channelCheckStatus
        $openFailures = $openResult.Failures
        $openChannelCount = $openResult.ChannelCount
        if ($OpenMode -eq 'check') { $checkpointAfterChecksMs = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    }
}

if ($SetCheckpoint) {
    $tooManyCheckFailures = $OpenMode -eq 'check' -and
        (Test-ShouldSkipCheckpoint $openFailures $openChannelCount)
    if ($tooManyCheckFailures) {
        [Console]::Error.WriteLine(
            "Checkpoint not updated: $openFailures of $openChannelCount channel check(s) failed")
    }
    else {
        if ($checkpointAfterChecksMs -gt 0) { Set-CheckpointAt $checkpointAfterChecksMs }
        else { Set-CheckpointNow }
    }
}

if ($OpenMode -ne '' -or $SetCheckpoint) {
    if ($openFailures -gt 0) { exit 1 }
    exit 0
}

if (-not [string]::IsNullOrEmpty($runUrl)) {
    $exe = Get-YtDlpPath
    if ($exe -eq '') {
        [Console]::Error.WriteLine('Error: yt-dlp binary not found next to this script')
        exit 1
    }
    Invoke-YCommand $exe --cookies ./cookies.txt --paths $OutputPath $runUrl
}
else {
    [Console]::Error.WriteLine("Error: no URL provided, and $urlFile does not exist or is empty")
    exit 1
}

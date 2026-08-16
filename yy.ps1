#!/usr/bin/env pwsh

# yy.ps1 - convenience wrapper around ./yt-dlp
#
# Description:
# - stores a positional URL into ./current_url.txt and downloads it
# - uses -t <temp_url> to download a one-off URL without persisting it
# - uses -U to run only the updater and skip any download
# - uses -o to open the channels in ./channel-ids.txt that published a public
#   video after the epoch timestamp in ./checkpoint.txt, and skip any download
#   (exits 1 if any channel could not be checked)
# - uses -O to open every channel in ./channel-ids.txt unconditionally, and
#   skip any download
# - uses -c to overwrite ./checkpoint.txt with the current epoch-ms timestamp,
#   and skip any download (runs after -o/-O, so `-o -c` means "open the new
#   ones, then mark everything as seen")
#
# Examples:
#   ./yy.ps1 'https://example.com/video'
#   ./yy.ps1 -t 'https://example.com/one-off'
#   ./yy.ps1 'https://saved.example.com/video' -t 'https://example.com/one-off'
#   ./yy.ps1 -U
#   ./yy.ps1 -o
#   ./yy.ps1 -O
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

$Url = ''
$TempUrl = ''
$Update = $false
$OpenMode = ''
$SetCheckpoint = $false

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
    elseif ($a -ceq '-U') {
        $Update = $true
    }
    elseif ($a -ceq '-o' -or $a -ceq '-O') {
        if ($OpenMode -ne '') {
            [Console]::Error.WriteLine('Error: -o and -O cannot be combined')
            exit 1
        }
        $OpenMode = if ($a -ceq '-o') { 'check' } else { 'open' }
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

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $exe --ignore-config --no-warnings --flat-playlist `
            --playlist-items 0 --print 'playlist:%(channel_id)s' $ChannelUrl 2>$null
    }
    catch {
        $output = $null
    }
    finally { $ErrorActionPreference = $previous }
    $global:LASTEXITCODE = 0

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

    $feedUrl = 'https://www.youtube.com/feeds/videos.xml?channel_id=' + $ChannelId
    $feed = Get-WebContent $feedUrl "video feed for $ChannelId"
    if ($null -eq $feed) { return [long](-1) }

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

# Return the epoch-ms publish time of the newest public video on a channel,
# 0 when the channel genuinely has none, or -1 when the check could not be
# completed.
function Get-NewestPublicMs {
    param([string]$Handle, [string]$ChannelUrl, [hashtable]$Cache)

    $resolved = Resolve-ChannelId -Handle $Handle -ChannelUrl $ChannelUrl -Cache $Cache
    if ($resolved.Id -eq '') { return [long](-1) }

    $newest = Get-FeedNewestMs $resolved.Id

    # An empty feed for a cached id usually means the handle now points at a
    # different channel, so drop the stale entry and resolve once more.
    if ($newest -le 0 -and $resolved.Source -eq 'cache') {
        [void]$Cache.Remove($Handle)
        Write-ChannelIdCache $Cache
        $resolved = Resolve-ChannelId -Handle $Handle -ChannelUrl $ChannelUrl -Cache $Cache -SkipCache
        if ($resolved.Id -eq '') { return [long](-1) }
        $newest = Get-FeedNewestMs $resolved.Id
    }

    if ($newest -eq 0) {
        [Console]::Error.WriteLine(
            "Warning: no <published> entries in the feed for $($resolved.Id) (@$Handle)")
    }
    return $newest
}

# Overwrite ./checkpoint.txt with the current time in epoch milliseconds.
function Set-CheckpointNow {
    $now = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Set-Content -LiteralPath $checkpointFile -Value ([string]$now) -Encoding ASCII
    Write-Host "Checkpoint updated: $now"
}

# Implement -o (check against the checkpoint) and -O (open everything).
# Returns the number of channels whose check could not be completed.
function Invoke-OpenMode {
    param([string]$Mode)

    if (-not (Test-Path -LiteralPath $channelsFile)) {
        [Console]::Error.WriteLine("Error: $channelsFile does not exist")
        exit 1
    }
    $checkpointMs = [long]0
    if ($Mode -eq 'check') {
        $checkpointMs = Read-CheckpointMs
        Write-Host "Checkpoint: $checkpointMs"
    }
    $cache = Read-ChannelIdCache
    $failures = 0
    # -Encoding UTF8 matters: Windows PowerShell 5.1 otherwise reads the file as
    # ANSI and mangles non-ASCII channel handles.
    foreach ($line in @(Get-Content -LiteralPath $channelsFile -Encoding UTF8)) {
        $channel = ([string]$line).TrimStart([char]0xFEFF).Trim()
        if ($channel -eq '' -or $channel.StartsWith('#')) { continue }
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
        elseif ($newest -eq 0) {
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
    if ($failures -gt 0) {
        [Console]::Error.WriteLine("Error: $failures channel check(s) failed")
    }
    return $failures
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
    exit 0
}

$openFailures = 0
if ($OpenMode -ne '') {
    $openFailures = Invoke-OpenMode $OpenMode
}

if ($SetCheckpoint) {
    Set-CheckpointNow
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
    Invoke-YCommand $exe --cookies ./cookies.txt --paths ./t $runUrl
}
else {
    [Console]::Error.WriteLine("Error: no URL provided, and $urlFile does not exist or is empty")
    exit 1
}

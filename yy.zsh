#!/bin/zsh

# yy.zsh - convenience wrapper around ./yt-dlp
#
# Description:
# - stores a positional URL into ./current_url.txt and downloads it
# - uses -t <temp_url> to download a one-off URL without persisting it
# - uses -p <path> to override the default download directory; without -p, a
#   youtube.com/@<channel-id> URL downloads to ./<channel-id>, otherwise ./t
# - uses -U to update ./yt-dlp and refresh this script from the head of master
#   on GitHub, then skip any download
# - uses -o to open the channels in ./channel-ids.txt that published a public
#   video after the epoch timestamp in ./checkpoint.txt, and skip any download
#   (exits 1 if any channel could not be checked)
# - uses -O to open every channel in ./channel-ids.txt unconditionally, and
#   skip any download
# - uses --html to generate a local 6-column video grid with y1/y2 selections
# - uses --html2 for the same page with persistent incremental scan caching
# - uses --html3 to open an independent loading shell and stream channel
#   fragments from a worker
# - uses --html3-incognito with --html3 to open that shell in a Chrome
#   Incognito window
# - uses -c to overwrite ./checkpoint.txt with the current epoch-ms timestamp,
#   and skip any download (runs after -o/-O, so `-o -c` means "open the new
#   ones, then mark everything as seen")
# - uses -h/--help to print the full usage summary and exit
#
# Examples:
#   ./yy.zsh 'https://example.com/video'
#   ./yy.zsh -t 'https://example.com/one-off'
#   ./yy.zsh -p ./my-videos -t 'https://example.com/one-off'
#   ./yy.zsh 'https://saved.example.com/video' -t 'https://example.com/one-off'
#   ./yy.zsh -U
#   ./yy.zsh -o
#   ./yy.zsh -O
#   ./yy.zsh --html
#   ./yy.zsh --html2
#   ./yy.zsh --html3
#   ./yy.zsh --html3 --html3-incognito
#   ./yy.zsh -c
#   ./yy.zsh --help
#   ./yy.zsh -o -c
#
# This is the macOS/Linux port of yy.ps1 and must stay behaviorally identical
# to it.
#
# Note: errexit is deliberately NOT set. This script runs a long-lived HTTP
# event loop, and zsh's `(( x++ ))` returns non-zero whenever the pre-increment
# value was 0, so errexit would abort the server on ordinary counters. Every
# failure path below is therefore checked explicitly.

set -uo pipefail

zmodload zsh/net/tcp 2>/dev/null || {
  printf 'Error: the zsh/net/tcp module is required for the HTML callback server\n' >&2
}
zmodload zsh/zselect 2>/dev/null || true
zmodload zsh/system 2>/dev/null || true
zmodload zsh/datetime 2>/dev/null || true

cd -- "${0:A:h}" || exit 1

script_dir=${0:A:h}
script_self=${0:A}
temporary_directory="$script_dir/.tmp"
mkdir -p -- "$temporary_directory" || exit 1
url_file="./current_url.txt"
channels_file="./channel-ids.txt"
channel_id_cache_file="./channel-id-cache.txt"
checkpoint_file="./checkpoint.txt"
cookies_file="./cookies.txt"
channel_status_file="./channel-check-status.json"
downloaded_videos_file="./downloaded-videos.json"
html_video_cache_file="./html-video-cache.json"
html_file="$temporary_directory/yy.html"
html3_file="$temporary_directory/yy-html3.html"
user_agent="Mozilla/5.0"
accept_language="en-US,en;q=0.9"
# Pre-accepted consent cookies: without them YouTube can answer a channel page
# with a consent interstitial that carries no channel_id, which looked exactly
# like "channel has no public videos". No account cookies are ever sent.
consent_cookie="SOCS=CAI; CONSENT=YES+cb"
fetch_timeout_sec=45
fetch_attempts=3
ytdlp_timeout_sec=30
ytdlp_attempts=1
ytdlp_deadline_sec=30
MAX_THREADS=16
html_heartbeat_timeout_sec=$(( 30 * 60 ))
download_progress_step_percent=10
feed_failure_limit=3
html_full_scan_interval_ms=$(( 24 * 60 * 60 * 1000 ))
html_listen_host="127.0.0.1"
html_listen_port=8080
downloaded_video_ttl_sec=$(( 45 * 86400 ))
stale_channel_ttl_ms=$(( 45 * 86400 * 1000 ))
feed_fetch_failures=0
skip_feed_fetches=0
feed_fetch_failed=0
feed_failure_counted_for_channel=0
# Head of master in the wrapper's own repo, used by -U to refresh this script.
script_raw_base="https://raw.githubusercontent.com/rikimberley/yt-dlp-wrapper/master"

current_url=""
temp_url=""
output_path="./t"
output_path_passed=0
do_update=0
switch_to_py=0
open_mode=""
html_mode=0
html_incremental=0
# zsh does not expand $'\t' inside an array subscript; use this when building keys.
tab_char=$'\t'
html3_mode=0
html3_incognito=0
html3_worker_token=""
html3_worker_refresh_all=0
set_checkpoint=0
html_failure_count=0
show_help=0

print_usage() {
  cat <<'USAGE'
yy.zsh - convenience wrapper around ./yt-dlp

Usage:
  ./yy.zsh [<url>] [-t <temp_url>] [-p <path>] [-U] [--py]
           [-o | -O | --html | --html2 | --html3] [--html3-incognito] [-c]
  ./yy.zsh -h | --help

Arguments:
  <url>               Persist this URL to ./current_url.txt, then download it.
                      With no arguments, the stored URL is re-downloaded.

Options:
  -t <temp_url>       Download this URL once, without persisting it.
  -p <path>           Download into <path>. Without -p, a youtube.com/@<id>
                      URL downloads to ./<id>, otherwise to ./t.
  -U                  Update ./yt-dlp and refresh this script from the head of
                      master on GitHub, then exit without downloading.
                      Exits non-zero if the refresh failed.
  --py                Switch this directory to the Python build: fetch
                      py/yy.py, py/yy.zsh and py/yy.ps1 from master, back up
                      the current copies into .tmp, and replace ./yy.py,
                      ./yy.zsh and ./yy.ps1. Both wrappers are switched, not
                      just this one, so the directory is never half of each
                      build. Exits without downloading. Takes precedence over
                      -U, which would otherwise refresh the script this
                      replaces.
  -o                  Open each channel in ./channel-ids.txt that published a
                      public video after ./checkpoint.txt, then exit without
                      downloading. Exits non-zero if a channel check failed.
  -O                  Open every channel in ./channel-ids.txt unconditionally,
                      then exit without downloading.
  --html              Generate a local 6-column video grid with y1/y2
                      selections and serve it on http://127.0.0.1:8080.
  --html2             As --html, with a persistent incremental scan cache, so
                      later runs scan only a one-day overlap per channel.
  --html3             As --html2, but open a loading shell immediately and
                      stream one fragment per channel from a background worker.
                      Already-downloaded video cards are dropped.
  --html3-incognito   With --html3, open the page in a Chrome/Chromium
                      incognito window instead of the default browser.
  -c                  Overwrite ./checkpoint.txt with the current epoch-ms
                      timestamp, then exit without downloading. Runs after
                      -o/-O, so "-o -c" means "open the new ones, then mark
                      everything as seen".
  -h, --help          Show this help and exit.

-o, -O, --html, --html2 and --html3 are mutually exclusive.
Flag precedence: -h, then --py, then -U, then -o/-O/--html*, then -c, then
download.

Examples:
  ./yy.zsh 'https://example.com/video'
  ./yy.zsh -t 'https://example.com/one-off'
  ./yy.zsh -p ./my-videos -t 'https://example.com/one-off'
  ./yy.zsh -U
  ./yy.zsh -o -c
  ./yy.zsh --html2
  ./yy.zsh --html3 --html3-incognito
USAGE
}

while (( $# > 0 )); do
  case "$1" in
    -h|--help)
      show_help=1
      ;;
    -t)
      shift
      if (( $# == 0 )); then
        printf 'Error: -t requires a URL argument\n' >&2
        exit 1
      fi
      temp_url=$1
      ;;
    -p)
      shift
      if (( $# == 0 )) || [[ -z "${1// /}" ]]; then
        printf 'Error: -p requires a non-empty path argument\n' >&2
        exit 1
      fi
      output_path=$1
      output_path_passed=1
      ;;
    -U)
      do_update=1
      ;;
    --py)
      switch_to_py=1
      ;;
    -o|-O)
      if [[ -n "$open_mode" ]]; then
        printf 'Error: -o, -O, --html, --html2, and --html3 cannot be combined\n' >&2
        exit 1
      fi
      if [[ "$1" == "-o" ]]; then open_mode="check"; else open_mode="open"; fi
      ;;
    --html|--html2|--html3)
      if [[ -n "$open_mode" ]]; then
        printf 'Error: -o, -O, --html, --html2, and --html3 cannot be combined\n' >&2
        exit 1
      fi
      open_mode="html"
      html_mode=1
      if [[ "$1" == "--html2" ]]; then html_incremental=1; fi
      if [[ "$1" == "--html3" ]]; then
        html_incremental=1
        html3_mode=1
      fi
      ;;
    --html3-incognito)
      html3_incognito=1
      ;;
    --html3-worker)
      shift
      if (( $# == 0 )) || [[ -z "${1// /}" ]]; then
        printf 'Error: --html3-worker requires a token argument\n' >&2
        exit 1
      fi
      if [[ -n "$open_mode" ]]; then
        printf 'Error: -o, -O, --html, --html2, and --html3 cannot be combined\n' >&2
        exit 1
      fi
      open_mode="html3-worker"
      html_mode=1
      html_incremental=1
      html3_mode=1
      html3_worker_token=$1
      if (( $# > 1 )) && [[ "$2" == "--refresh-all" ]]; then
        html3_worker_refresh_all=1
        shift
      fi
      ;;
    -c)
      set_checkpoint=1
      ;;
    -*)
      printf 'Error: unsupported flag: %s\n' "$1" >&2
      exit 1
      ;;
    *)
      if [[ -n "$current_url" ]]; then
        printf 'Error: expected at most one URL argument\n' >&2
        exit 1
      fi
      current_url=$1
      ;;
  esac
  shift
done

if (( show_help )); then
  print_usage
  exit 0
fi

if (( html3_incognito )) && { (( html3_mode == 0 )) || [[ "$open_mode" != "html" ]]; }; then
  printf 'Error: --html3-incognito requires --html3\n' >&2
  exit 1
fi

run_cmd() {
  local -a cmd
  cmd=("$@")
  printf '\033[34mRunning:'
  printf ' %q' "${cmd[@]}"
  printf '\033[0m\n'
  "${cmd[@]}"
}

# Open a URL in the default browser.
open_url() {
  if (( ${+commands[open]} )); then
    run_cmd open -- "$1"
  elif (( ${+commands[xdg-open]} )); then
    run_cmd xdg-open "$1"
  else
    printf 'Error: no browser opener found (need open or xdg-open)\n' >&2
    return 1
  fi
}

# Open the --html3 shell, in a Chrome Incognito window when asked.
#
# yy.ps1 restricts Incognito to Windows because that is the only platform it
# knows how to locate chrome.exe on; here the equivalent lookup is the macOS
# app bundle or a Chrome/Chromium binary on PATH. Anything unfound degrades to
# the default browser with a warning rather than failing the run.
open_html3_url() {
  local target_url=$1 incognito=$2
  local chrome_app="/Applications/Google Chrome.app"
  local candidate

  if (( ! incognito )); then
    open_url "$target_url"
    return
  fi

  if [[ -d "$chrome_app" ]] && (( ${+commands[open]} )); then
    run_cmd open -na "Google Chrome" --args --incognito "$target_url"
    return
  fi

  for candidate in google-chrome google-chrome-stable chromium chromium-browser; do
    if (( ${+commands[$candidate]} )); then
      run_cmd "$candidate" --incognito "$target_url" &
      disown 2>/dev/null || true
      return
    fi
  done

  printf 'Warning: Google Chrome was not found; opening HTML3 in the default browser.\n' >&2
  open_url "$target_url"
}

now_ms() {
  print -r -- $(( $(date +%s) * 1000 ))
}

now_sec() {
  date +%s
}

# Trim leading/trailing whitespace, any trailing CR, and a leading UTF-8 BOM.
trim() {
  local s=${1%$'\r'}
  s=${s#$'\ufeff'}
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  print -r -- "$s"
}

# Convert an ISO-8601 timestamp (e.g. 2026-08-01T16:30:12+00:00) to epoch ms.
iso_to_epoch_ms() {
  local ts=$1 base secs
  base=${ts%[+-]??:??}
  base=${base%Z}
  base=${base%%.*}
  secs=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "$base" '+%s' 2>/dev/null) \
    || secs=$(date -u -d "$ts" '+%s' 2>/dev/null) \
    || return 1
  [[ -n "$secs" ]] || return 1
  print -r -- $(( secs * 1000 ))
}

# Read ./checkpoint.txt and normalise it to epoch milliseconds.
# A missing or empty checkpoint file is not an error: it means "nothing has
# been seen yet", so it reads as 0 and every video counts as new. Only a file
# that exists and holds something unusable is treated as corruption.
read_checkpoint_ms() {
  local raw digits
  if [[ ! -f "$checkpoint_file" ]]; then
    printf 'Warning: %s does not exist; continuing with no checkpoint (0)\n' "$checkpoint_file" >&2
    print -r -- 0
    return 0
  fi
  IFS= read -r raw < "$checkpoint_file" || raw=""
  digits=${raw//[^0-9]/}
  if [[ -z "$digits" ]]; then
    if [[ -z "${raw//[[:space:]]/}" ]]; then
      printf 'Warning: %s is empty; continuing with no checkpoint (0)\n' "$checkpoint_file" >&2
      print -r -- 0
      return 0
    fi
    printf 'Error: %s does not contain an epoch timestamp\n' "$checkpoint_file" >&2
    return 1
  fi
  # 12+ digits means the value is already in milliseconds; else it is seconds.
  if (( ${#digits} >= 12 )); then
    print -r -- "$digits"
  else
    print -r -- $(( digits * 1000 ))
  fi
}

# Overwrite ./checkpoint.txt with a time in epoch milliseconds.
set_checkpoint_at() {
  local timestamp_ms=$1
  print -r -- "$timestamp_ms" >| "$checkpoint_file"
  printf 'Checkpoint updated: %s\n' "$timestamp_ms"
}

set_checkpoint_now() {
  set_checkpoint_at "$(now_ms)"
}

# Protect a checkpoint from advancing past too many channels that were not
# successfully checked. "All" only applies when at least one channel was listed.
should_skip_checkpoint() {
  local failures=$1 channel_count=$2
  (( failures >= 3 || (channel_count > 0 && failures == channel_count) ))
}

# Percent-encode $1 so a non-ASCII channel handle always travels as UTF-8.
url_escape() {
  local s=$1 out="" c i
  for (( i = 1; i <= ${#s}; i++ )); do
    c=$s[i]
    if [[ "$c" == [A-Za-z0-9._~-] ]]; then
      out+=$c
    else
      out+=$(printf '%s' "$c" | LC_ALL=C od -An -tx1 | tr -d ' \n' | tr 'a-f' 'A-F' | sed 's/../%&/g')
    fi
  done
  print -r -- "$out"
}

# Build the /videos URL for a channel-ids.txt entry. A raw UC… id is used as a
# channel id directly, anything else is treated as a handle.
channel_url_for() {
  local channel=$1
  if [[ "$channel" =~ ^UC[A-Za-z0-9_-]+$ ]]; then
    print -r -- "https://www.youtube.com/channel/${channel}/videos"
  else
    print -r -- "https://www.youtube.com/@$(url_escape "$channel")/videos"
  fi
}

# Locate the vendored yt-dlp binary. On Windows the file needs its .exe
# extension to be executable, so accept that name too.
ytdlp_path() {
  local candidate
  for candidate in ./yt-dlp.exe ./yt-dlp; do
    if [[ -f "$candidate" ]]; then
      print -r -- "$candidate"
      return 0
    fi
  done
  return 1
}

# Escape text inserted into the generated HTML document.
html_escape() {
  local s=$1
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  s=${s//\"/&quot;}
  s=${s//\'/&#39;}
  print -r -- "$s"
}

# Render an epoch timestamp as a compact age. Accepts seconds or milliseconds
# and prints nothing for a non-positive value, matching Format-RelativeVideoTime.
format_relative_ms() {
  local raw=${1:-0} ms seconds count unit i
  local -a units divisors
  units=(year month week day hour minute)
  divisors=(31536000 2592000 604800 86400 3600 60)
  [[ "$raw" == <-> ]] || { print -r -- ''; return 0 }
  ms=$raw
  (( ms <= 0 )) && { print -r -- ''; return 0 }
  (( ms < 100000000000 )) && (( ms *= 1000 ))
  seconds=$(( $(now_sec) - ms / 1000 ))
  (( seconds < 0 )) && seconds=0
  for i in {1..6}; do
    unit=${units[$i]}
    count=$(( seconds / divisors[$i] ))
    if (( count >= 1 )); then
      if (( count == 1 )); then
        print -r -- "$count $unit ago"
      else
        print -r -- "$count ${unit}s ago"
      fi
      return 0
    fi
  done
  print -r -- 'just now'
}

# ---------------------------------------------------------------------------
# JSON
#
# yy.ps1 persists its channel status, download history and --html2 scan cache
# as JSON, so this port reads and writes the same shapes. zsh has no JSON
# support, and a per-character parser written in zsh is far too slow for a
# cache holding thousands of video entries, so the read path goes through awk
# (already a hard dependency of nothing here, but as ubiquitous as curl/sed).
#
# json_flatten emits one "path<TAB>value" line per scalar. Path components are
# separated by \x01 because a channel handle may legitimately contain a dot.
# Values are re-escaped (backslash, tab, newline, CR) so a line is always
# splittable, and any \uXXXX the parser could not fold into a byte is passed
# through as a single-backslash escape; the two can never collide because a
# real backslash is always doubled. zsh then decodes the whole value in one
# step with ${(g::)value}, which understands exactly that escape set.
# ---------------------------------------------------------------------------

json_flatten_awk='
function repl(v, from, to,   out, p) {
  out = ""
  while ((p = index(v, from)) > 0) { out = out substr(v, 1, p - 1) to; v = substr(v, p + 1) }
  return out v
}
function esc(v) {
  v = repl(v, BS, BS BS)
  v = repl(v, TAB, BS "t")
  v = repl(v, NL, BS "n")
  v = repl(v, CR, BS "r")
  return v
}
function hexval(c) {
  c = tolower(c)
  return index("0123456789abcdef", c) - 1
}
function hex4(h,   k, d, v) {
  v = 0
  for (k = 1; k <= 4; k++) {
    d = hexval(substr(h, k, 1))
    if (d < 0) return -1
    v = v * 16 + d
  }
  return v
}
# Windows PowerShell 5.1 ConvertTo-Json escapes every non-ASCII character, so a
# JSON file written by yy.ps1 carries \uXXXX where yy.zsh writes raw UTF-8.
# Decode back to UTF-8 bytes (awk runs under LC_ALL=C, so %c emits one byte).
function utf8(cp) {
  if (cp <= 0) return ""
  if (cp < 128) return sprintf("%c", cp)
  if (cp < 2048) return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
  if (cp < 65536) return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64)
  return sprintf("%c%c%c%c", 240 + int(cp / 262144), 128 + int(cp / 4096) % 64, 128 + int(cp / 64) % 64, 128 + cp % 64)
}
function emit(path, value) { printf "%s\t%s\n", esc(path), esc(value) }
function skipws(   c) {
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == " " || c == "\t" || c == "\n" || c == "\r") i++
    else return
  }
}
function parseString(   out, c, e, cp, lo) {
  i++
  out = ""
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == BS) {
      i++
      e = substr(s, i, 1)
      i++
      if (e == "n") out = out NL
      else if (e == "t") out = out TAB
      else if (e == "r") out = out CR
      else if (e == "b") out = out sprintf("%c", 8)
      else if (e == "f") out = out sprintf("%c", 12)
      else if (e == "u") {
        cp = hex4(substr(s, i, 4))
        i += 4
        if (cp < 0) { out = out "u"; continue }
        # Non-BMP code points arrive as a UTF-16 surrogate pair.
        if (cp >= 55296 && cp <= 56319 && substr(s, i, 2) == BS "u") {
          lo = hex4(substr(s, i + 2, 4))
          if (lo >= 56320 && lo <= 57343) {
            cp = 65536 + (cp - 55296) * 1024 + (lo - 56320)
            i += 6
          }
        }
        out = out utf8(cp)
      }
      else out = out e
      continue
    }
    if (c == "\"") { i++; return out }
    out = out c
    i++
  }
  return out
}
function parseValue(path,   c, key, idx, start) {
  skipws()
  c = substr(s, i, 1)
  if (c == "{") {
    i++
    skipws()
    if (substr(s, i, 1) == "}") { i++; return }
    while (i <= n) {
      skipws()
      if (substr(s, i, 1) != "\"") return
      key = parseString()
      skipws()
      if (substr(s, i, 1) == ":") i++
      parseValue(path == "" ? key : path SEP key)
      skipws()
      c = substr(s, i, 1)
      if (c == ",") { i++; continue }
      if (c == "}") i++
      return
    }
    return
  }
  if (c == "[") {
    i++
    idx = 0
    skipws()
    if (substr(s, i, 1) == "]") { i++; return }
    while (i <= n) {
      parseValue(path == "" ? idx "" : path SEP idx)
      idx++
      skipws()
      c = substr(s, i, 1)
      if (c == ",") { i++; continue }
      if (c == "]") i++
      return
    }
    return
  }
  if (c == "\"") { emit(path, parseString()); return }
  start = i
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "," || c == "}" || c == "]" || c == " " || c == "\t" || c == "\r" || c == "\n") break
    i++
  }
  if (i > start) emit(path, substr(s, start, i - start))
}
BEGIN {
  BS = sprintf("%c", 92); TAB = sprintf("%c", 9); NL = sprintf("%c", 10)
  CR = sprintf("%c", 13); SEP = sprintf("%c", 1)
  BOM = sprintf("%c%c%c", 239, 187, 191)
  s = ""
}
{ s = s $0 NL }
END {
  n = length(s)
  i = 1
  # A BOM would stop parseValue before it ever sees the opening brace.
  if (substr(s, 1, 3) == BOM) i = 4
  parseValue("")
}
'

# Flatten the JSON in file $1. A missing or unreadable file yields no output,
# which every caller treats as "empty state", never as an error.
json_flatten_file() {
  [[ -f "$1" ]] || return 0
  # LC_ALL=C keeps substr/length byte-oriented and makes sprintf("%c", N) emit a
  # single raw byte, which is what utf8() above needs to rebuild \uXXXX escapes.
  LC_ALL=C awk "$json_flatten_awk" "$1" 2>/dev/null || true
}

json_flatten_string() {
  print -r -- "$1" | awk "$json_flatten_awk" 2>/dev/null || true
}

# Escape a zsh string for use as a JSON string body (without the quotes).
typeset -gA json_ctrl_escapes=(
  1 '\u0001' 2 '\u0002' 3 '\u0003' 4 '\u0004' 5 '\u0005' 6 '\u0006' 7 '\u0007'
  11 '\u000b' 14 '\u000e' 15 '\u000f' 16 '\u0010' 17 '\u0011' 18 '\u0012'
  19 '\u0013' 20 '\u0014' 21 '\u0015' 22 '\u0016' 23 '\u0017' 24 '\u0018'
  25 '\u0019' 26 '\u001a' 27 '\u001b' 28 '\u001c' 29 '\u001d' 30 '\u001e' 31 '\u001f'
)

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=${s//$'\b'/\\b}
  s=${s//$'\f'/\\f}
  # Every other C0 control is illegal raw inside a JSON string and makes the
  # page's JSON.parse throw, which used to kill status polling for good.
  if [[ $s == *[$'\x01'-$'\x1f']* ]]; then
    local code
    for code in ${(k)json_ctrl_escapes}; do
      [[ $s == *${(#)code}* ]] || continue
      s=${s//${(#)code}/${json_ctrl_escapes[$code]}}
    done
  fi
  print -r -- "$s"
}

# yt-dlp emits ANSI colour and cursor sequences even when its output is a file.
# They are pure noise in the page's job log, so drop them (and any stray C0
# control) before the line is ever shown or serialised.
strip_control_chars() {
  setopt localoptions extendedglob
  local s=$1
  s=${s//$'\e'\[[0-9;?]#[a-zA-Z]/}
  s=${s//$'\e'\][^$'\a']#$'\a'/}
  s=${s//$'\e'[\(\)][A-Za-z0-9]/}
  s=${s//[$'\x01'-$'\x08'$'\x0b'$'\x0c'$'\x0e'-$'\x1f'$'\x7f']/}
  print -r -- "$s"
}

# Strip anything that would need escaping out of a value that is only ever
# displayed, so a pathological title cannot corrupt a TAB-delimited scan row.
sanitize_field() {
  local s=$1
  s=${s//$'\t'/ }
  s=${s//$'\r'/ }
  s=${s//$'\n'/ }
  print -r -- "$s"
}

# ---------------------------------------------------------------------------
# ./channel-check-status.json  ->  channel -> { checked_ms, latest_video_ms, thumbnail }
# ---------------------------------------------------------------------------

typeset -gA status_checked_ms status_latest_video_ms status_thumbnail
typeset -ga status_channels

read_channel_check_status() {
  status_checked_ms=(); status_latest_video_ms=(); status_thumbnail=(); status_channels=()
  local jpath value channel field
  local -a parts
  while IFS=$'\t' read -r jpath value; do
    parts=(${(ps:\x01:)jpath})
    (( ${#parts} == 2 )) || continue
    channel=${(g::)parts[1]}
    field=${(g::)parts[2]}
    value=${(g::)value}
    [[ -n "$channel" ]] || continue
    if (( ! ${+status_checked_ms[$channel]} )); then
      status_checked_ms[$channel]=0
      status_latest_video_ms[$channel]=0
      status_thumbnail[$channel]=""
      status_channels+=("$channel")
    fi
    case "$field" in
      checked_ms) [[ "$value" == <-> ]] && status_checked_ms[$channel]=$value ;;
      latest_video_ms) [[ "$value" == <-> ]] && status_latest_video_ms[$channel]=$value ;;
      thumbnail) [[ "$value" == null ]] || status_thumbnail[$channel]=$value ;;
    esac
  done < <(json_flatten_file "$channel_status_file")
  return 0
}

save_channel_check_status() {
  local tmp="$temporary_directory/channel-check-status.json.new.$$" channel first=1
  : >| "$tmp" || { printf 'Warning: could not write %s\n' "$channel_status_file" >&2; return 0; }
  print -rn -- '{' >> "$tmp"
  for channel in "${status_channels[@]}"; do
    (( first )) || print -rn -- ',' >> "$tmp"
    first=0
    printf '\n  "%s": {"checked_ms": %s, "latest_video_ms": %s, "thumbnail": "%s"}' \
      "$(json_escape "$channel")" "${status_checked_ms[$channel]:-0}" \
      "${status_latest_video_ms[$channel]:-0}" \
      "$(json_escape "${status_thumbnail[$channel]:-}")" >> "$tmp"
  done
  print -r -- $'\n}' >> "$tmp"
  mv -f -- "$tmp" "$channel_status_file" 2>/dev/null \
    || { printf 'Warning: could not write %s\n' "$channel_status_file" >&2; rm -f -- "$tmp"; }
  return 0
}

# Drop channel status records that have not been checked in 45 days, so a
# removed or renamed handle does not linger in the file forever.
remove_stale_channel_check_status() {
  local cutoff_ms=$(( $(now_ms) - stale_channel_ttl_ms )) channel checked removed=0
  local -a kept
  kept=()
  for channel in "${status_channels[@]}"; do
    checked=${status_checked_ms[$channel]:-0}
    [[ "$checked" == <-> ]] || checked=0
    if (( checked > 0 && checked < cutoff_ms )); then
      unset "status_checked_ms[$channel]" "status_latest_video_ms[$channel]" "status_thumbnail[$channel]"
      (( removed++ ))
      continue
    fi
    kept+=("$channel")
  done
  status_channels=("${kept[@]}")
  (( removed > 0 )) && save_channel_check_status
  return 0
}

status_touch_channel() {
  local channel=$1
  if (( ! ${+status_checked_ms[$channel]} )); then
    status_checked_ms[$channel]=0
    status_latest_video_ms[$channel]=0
    status_thumbnail[$channel]=""
    status_channels+=("$channel")
  fi
}

# Record one channel check. With preserve=1 an unknown (0) newest timestamp
# keeps whatever was already stored, which is how the HTML page avoids
# forgetting a channel's age just because this scan found no cards.
record_channel_check() {
  local channel=$1 latest_video_ms=$2 checked_ms=$3 preserve=${4:-0}
  status_touch_channel "$channel"
  if (( preserve && latest_video_ms == 0 )); then
    latest_video_ms=${status_latest_video_ms[$channel]:-0}
  fi
  status_checked_ms[$channel]=$checked_ms
  status_latest_video_ms[$channel]=$latest_video_ms
}

# Routine HTML scans avoid spending time on channels whose stored newest video
# is unknown or already at least 1.5 displayed months (45 days) old. REFRESH
# ALL bypasses this filter so those records can be repaired or reconsidered.
should_scan_html_channel() {
  local channel=$1 refresh_all=$2 latest cutoff
  (( refresh_all )) && return 0
  (( ${+status_latest_video_ms[$channel]} )) || return 1
  latest=${status_latest_video_ms[$channel]}
  [[ "$latest" == <-> ]] || return 1
  (( latest > 0 )) || return 1
  cutoff=$(( $(now_ms) - stale_channel_ttl_ms ))
  (( latest > cutoff ))
}

# ---------------------------------------------------------------------------
# ./downloaded-videos.json  ->  [ { channel_id, video_id, target, download_epoch } ]
#
# Completed HTML downloads are remembered for 45 days (1.5 displayed months).
# An existing tuple is deliberately not re-stamped.
# ---------------------------------------------------------------------------

typeset -ga downloaded_keys
typeset -gA downloaded_epoch

read_downloaded_videos() {
  downloaded_keys=(); downloaded_epoch=()
  local jpath value idx field cutoff changed=0 expired=0 invalid=0 unwrapped=0 key
  local -a parts order
  local -A rec_channel rec_video rec_target rec_epoch
  cutoff=$(( $(now_sec) - downloaded_video_ttl_sec ))
  if [[ ! -f "$downloaded_videos_file" ]]; then
    printf 'Downloaded-video history not found; starting empty.\n'
    return 0
  fi
  while IFS=$'\t' read -r jpath value; do
    parts=(${(ps:\x01:)jpath})
    if (( ${#parts} == 1 )); then
      # A one-element array can be serialized as a bare object (Windows
      # PowerShell's ConvertTo-Json has historically unwrapped single-element
      # arrays). PowerShell's own reader tolerates that shape, so zsh must too
      # or it silently loads zero records. Read it as record 0 and rewrite the
      # file in array form.
      idx=0
      field=${(g::)parts[1]}
      unwrapped=1
    elif (( ${#parts} == 2 )); then
      idx=${(g::)parts[1]}
      field=${(g::)parts[2]}
    else
      continue
    fi
    value=${(g::)value}
    [[ "$idx" == <-> ]] || continue
    if (( ! ${+rec_channel[$idx]} )); then
      rec_channel[$idx]=""; rec_video[$idx]=""; rec_target[$idx]=""; rec_epoch[$idx]=""
      order+=("$idx")
    fi
    case "$field" in
      channel_id) rec_channel[$idx]=$value ;;
      video_id) rec_video[$idx]=$value ;;
      target) rec_target[$idx]=$value ;;
      download_epoch) rec_epoch[$idx]=$value ;;
    esac
  done < <(json_flatten_file "$downloaded_videos_file")
  for idx in "${order[@]}"; do
    if [[ ! "${rec_channel[$idx]}" =~ ^UC[A-Za-z0-9_-]+$ ]] ||
       [[ ! "${rec_video[$idx]}" =~ ^[A-Za-z0-9_-]+$ ]] ||
       [[ "${rec_target[$idx]}" != y1 && "${rec_target[$idx]}" != y2 ]] ||
       [[ "${rec_epoch[$idx]}" != <-> ]]; then
      changed=1; (( ++invalid )); continue
    fi
    if (( rec_epoch[$idx] < cutoff )); then
      changed=1; (( ++expired )); continue
    fi
    key="${rec_channel[$idx]}"$'\t'"${rec_video[$idx]}"$'\t'"${rec_target[$idx]}"
    if (( ${+downloaded_epoch[$key]} )); then
      changed=1; continue
    fi
    downloaded_keys+=("$key")
    downloaded_epoch[$key]=${rec_epoch[$idx]}
  done
  printf 'Loaded %s downloaded-video record(s).\n' "${#downloaded_keys}"
  (( expired > 0 )) && printf 'Pruned %s downloaded-video record(s) older than 45 days.\n' "$expired"
  (( invalid > 0 )) && printf 'Pruned %s invalid downloaded-video record(s).\n' "$invalid"
  (( changed || unwrapped )) && save_downloaded_videos
  return 0
}

save_downloaded_videos() {
  local tmp="$temporary_directory/downloaded-videos.json.new.$$" key first=1
  local -a fields
  : >| "$tmp" || { printf 'Warning: could not write %s\n' "$downloaded_videos_file" >&2; return 0; }
  print -rn -- '[' >> "$tmp"
  for key in "${downloaded_keys[@]}"; do
    fields=("${(@s:	:)key}")
    (( ${#fields} == 3 )) || continue
    (( first )) || print -rn -- ',' >> "$tmp"
    first=0
    printf '\n  {"channel_id": "%s", "video_id": "%s", "target": "%s", "download_epoch": %s}' \
      "$(json_escape "${fields[1]}")" "$(json_escape "${fields[2]}")" \
      "$(json_escape "${fields[3]}")" "${downloaded_epoch[$key]:-0}" >> "$tmp"
  done
  print -r -- $'\n]' >> "$tmp"
  if mv -f -- "$tmp" "$downloaded_videos_file" 2>/dev/null; then
    printf 'Saved %s downloaded-video record(s).\n' "${#downloaded_keys}"
  else
    printf 'Warning: could not write %s\n' "$downloaded_videos_file" >&2
    rm -f -- "$tmp"
  fi
  return 0
}

add_downloaded_video() {
  local channel_id=$1 video_id=$2 target=$3 key
  key="${channel_id}"$'\t'"${video_id}"$'\t'"${target}"
  read_downloaded_videos >/dev/null
  if (( ${+downloaded_epoch[$key]} )); then
    printf 'Downloaded-video record already exists; keeping original timestamp: %s / %s / %s\n' \
      "$channel_id" "$video_id" "$target"
    return 0
  fi
  printf 'Recording completed download: %s / %s / %s\n' "$channel_id" "$video_id" "$target"
  downloaded_keys+=("$key")
  downloaded_epoch[$key]=$(now_sec)
  save_downloaded_videos >/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# ./html-video-cache.json  ->  channel -> { channel_id, checked_ms,
#     last_full_scan_ms, feed_newest_ms, entries: [ { id, url, title,
#     timestamp_ms, availability } ] }
#
# entries are held in zsh as newline-separated TAB rows, which is exactly the
# shape the scan output and the card renderer already speak.
# ---------------------------------------------------------------------------

typeset -gA cache_channel_id cache_checked_ms cache_last_full_ms cache_feed_newest_ms cache_entries
typeset -ga cache_channels

read_html_video_cache() {
  cache_channel_id=(); cache_checked_ms=(); cache_last_full_ms=()
  cache_feed_newest_ms=(); cache_entries=(); cache_channels=()
  local jpath value channel field idx entry_key
  local -a parts
  local -A entry_id entry_url entry_title entry_ts entry_avail entry_seen
  local -a entry_order
  while IFS=$'\t' read -r jpath value; do
    parts=(${(ps:\x01:)jpath})
    channel=${(g::)parts[1]}
    [[ -n "$channel" ]] || continue
    if (( ! ${+cache_checked_ms[$channel]} )); then
      cache_channel_id[$channel]=""
      cache_checked_ms[$channel]=0
      cache_last_full_ms[$channel]=0
      cache_feed_newest_ms[$channel]=0
      cache_entries[$channel]=""
      cache_channels+=("$channel")
    fi
    value=${(g::)value}
    if (( ${#parts} == 2 )); then
      field=${(g::)parts[2]}
      case "$field" in
        channel_id) [[ "$value" == null ]] || cache_channel_id[$channel]=$value ;;
        checked_ms) [[ "$value" == <-> ]] && cache_checked_ms[$channel]=$value ;;
        last_full_scan_ms) [[ "$value" == <-> ]] && cache_last_full_ms[$channel]=$value ;;
        feed_newest_ms) [[ "$value" == <-> ]] && cache_feed_newest_ms[$channel]=$value ;;
      esac
      continue
    fi
    (( ${#parts} == 4 )) || continue
    [[ "${(g::)parts[2]}" == entries ]] || continue
    idx=${(g::)parts[3]}
    field=${(g::)parts[4]}
    entry_key="${channel}"$'\x01'"${idx}"
    if (( ! ${+entry_seen[$entry_key]} )); then
      entry_seen[$entry_key]=1
      entry_id[$entry_key]=""; entry_url[$entry_key]=""; entry_title[$entry_key]=""
      entry_ts[$entry_key]=0; entry_avail[$entry_key]=""
      entry_order+=("$entry_key")
    fi
    case "$field" in
      id) entry_id[$entry_key]=$value ;;
      url) entry_url[$entry_key]=$value ;;
      title) entry_title[$entry_key]=$value ;;
      timestamp_ms) [[ "$value" == <-> ]] && entry_ts[$entry_key]=$value ;;
      availability) [[ "$value" == null ]] || entry_avail[$entry_key]=$value ;;
    esac
  done < <(json_flatten_file "$html_video_cache_file")
  for entry_key in "${entry_order[@]}"; do
    channel=${entry_key%%$'\x01'*}
    [[ -n "${entry_id[$entry_key]}" ]] || continue
    cache_entries[$channel]+="${entry_id[$entry_key]}"$'\t'"${entry_url[$entry_key]}"$'\t'"$(sanitize_field "${entry_title[$entry_key]}")"$'\t'"${entry_ts[$entry_key]}"$'\t'"${entry_avail[$entry_key]}"$'\n'
  done
  prune_stale_html_video_cache
  return 0
}

# Drop cache records that have not been checked in 45 days. Done on read so a
# long-dormant channel cannot keep growing the file indefinitely.
prune_stale_html_video_cache() {
  local cutoff_ms=$(( $(now_ms) - stale_channel_ttl_ms )) channel checked changed=0
  local -a kept
  kept=()
  for channel in "${cache_channels[@]}"; do
    checked=${cache_checked_ms[$channel]:-0}
    [[ "$checked" == <-> ]] || checked=0
    if (( checked > 0 && checked < cutoff_ms )); then
      unset "cache_channel_id[$channel]" "cache_checked_ms[$channel]" \
        "cache_last_full_ms[$channel]" "cache_feed_newest_ms[$channel]" "cache_entries[$channel]"
      changed=1
      continue
    fi
    kept+=("$channel")
  done
  cache_channels=("${kept[@]}")
  (( changed )) && save_html_video_cache
  return 0
}

save_html_video_cache() {
  local tmp="$temporary_directory/html-video-cache.json.new.$$" channel row first=1 entry_first
  local -a fields
  : >| "$tmp" || { printf 'Warning: could not write %s\n' "$html_video_cache_file" >&2; return 0; }
  print -rn -- '{' >> "$tmp"
  for channel in "${cache_channels[@]}"; do
    (( first )) || print -rn -- ',' >> "$tmp"
    first=0
    printf '\n  "%s": {"channel_id": "%s", "checked_ms": %s, "last_full_scan_ms": %s, "feed_newest_ms": %s, "entries": [' \
      "$(json_escape "$channel")" "$(json_escape "${cache_channel_id[$channel]:-}")" \
      "${cache_checked_ms[$channel]:-0}" "${cache_last_full_ms[$channel]:-0}" \
      "${cache_feed_newest_ms[$channel]:-0}" >> "$tmp"
    entry_first=1
    for row in ${(f)"${cache_entries[$channel]:-}"}; do
      [[ -n "$row" ]] || continue
      fields=("${(@s:	:)row}")
      (( ${#fields} >= 4 )) || continue
      (( entry_first )) || print -rn -- ',' >> "$tmp"
      entry_first=0
      printf '\n    {"id": "%s", "url": "%s", "title": "%s", "timestamp_ms": %s, "availability": "%s"}' \
        "$(json_escape "${fields[1]}")" "$(json_escape "${fields[2]}")" \
        "$(json_escape "${fields[3]}")" "${fields[4]}" \
        "$(json_escape "${fields[5]:-}")" >> "$tmp"
    done
    print -rn -- ']}' >> "$tmp"
  done
  print -r -- $'\n}' >> "$tmp"
  mv -f -- "$tmp" "$html_video_cache_file" 2>/dev/null \
    || { printf 'Warning: could not write %s\n' "$html_video_cache_file" >&2; rm -f -- "$tmp"; }
  return 0
}

cache_touch_channel() {
  local channel=$1
  if (( ! ${+cache_checked_ms[$channel]} )); then
    cache_channel_id[$channel]=""
    cache_checked_ms[$channel]=0
    cache_last_full_ms[$channel]=0
    cache_feed_newest_ms[$channel]=0
    cache_entries[$channel]=""
    cache_channels+=("$channel")
  fi
}

# ---------------------------------------------------------------------------
# HTTP fetching
# ---------------------------------------------------------------------------

fetch_body=""
fetch_error=""
fetch_status=0
# One attempt at $1. Sends the anonymous consent cookies unless $2 is
# 'no-consent' (the Atom feed does not need them and must stay minimal).
fetch_url_once() {
  local url=$1 mode=${2:-consent} errfile raw code
  local rc=0
  local -a extra
  fetch_body=""; fetch_error=""; fetch_status=0
  [[ "$mode" == "no-consent" ]] || extra=(-H "Cookie: ${consent_cookie}")
  errfile=$(mktemp "$temporary_directory/yy-fetch-error.XXXXXX") || return 1
  raw=$(curl -sS --compressed --location --max-time "$fetch_timeout_sec" \
    -A "$user_agent" \
    -H "Accept-Language: ${accept_language}" \
    "${extra[@]}" \
    -w '\n%{http_code}' \
    -- "$url" 2>"$errfile") || rc=$?
  fetch_error=$(<"$errfile")
  rm -f -- "$errfile"
  if (( rc != 0 )); then
    [[ -n "$fetch_error" ]] || fetch_error="curl exited $rc"
    return 1
  fi
  code=${raw##*$'\n'}
  fetch_body=${raw%$'\n'*}
  fetch_status=$code
  if [[ "$code" != 2* ]]; then
    fetch_error="HTTP $code"
    return 1
  fi
  return 0
}

# Fetch a URL with retries and print its body, or return non-zero.
# Retrying matters: a single transient hiccup used to be indistinguishable from
# an empty channel.
fetch_url() {
  local url=$1 what=$2 mode=${3:-consent}
  local attempt=1
  while (( attempt <= fetch_attempts )); do
    (( attempt > 1 )) && sleep $(( attempt - 1 ))
    if fetch_url_once "$url" "$mode"; then
      print -r -- "$fetch_body"
      return 0
    fi
    printf 'Warning: fetch of %s failed (attempt %s/%s): %s\n' \
      "$what" "$attempt" "$fetch_attempts" "$fetch_error" >&2
    # A 404/403 is a settled answer, not a hiccup: retrying only delays the
    # (correct) failure report.
    if [[ "$fetch_status" == 4* && "$fetch_status" != 408 && "$fetch_status" != 429 ]]; then
      break
    fi
    (( ++attempt ))
  done
  printf 'Warning: giving up on %s (%s): %s\n' "$what" "$url" "$fetch_error" >&2
  return 1
}

# Fetch many URLs at once by running one curl per URL in the background, which
# is the zsh equivalent of yy.ps1's HttpClient task fan-out. $1 names an
# associative array of key -> URL; bodies land in $concurrent_body[key] and
# only successfully fetched keys are present.
typeset -gA concurrent_body
fetch_urls_concurrent() {
  local map_name=$1 what=$2 mode=${3:-consent} attempt key dir rc
  local -a pids keys
  concurrent_body=()
  local -A pending
  pending=("${(@Pkv)map_name}")
  (( ${#pending} )) || return 0
  for (( attempt = 1; attempt <= fetch_attempts; attempt++ )); do
    (( ${#pending} )) || break
    (( attempt > 1 )) && sleep $(( attempt - 1 ))
    dir=$(mktemp -d "$temporary_directory/yy-fetch.XXXXXX") || return 0
    pids=(); keys=()
    local -a curl_extra
    curl_extra=()
    [[ "$mode" == "no-consent" ]] || curl_extra=(-H "Cookie: ${consent_cookie}")
    local i=0
    for key in "${(@k)pending}"; do
      (( ++i ))
      keys+=("$key")
      {
        curl -sS --compressed --location --max-time "$fetch_timeout_sec" \
          -A "$user_agent" -H "Accept-Language: ${accept_language}" \
          "${curl_extra[@]}" -o "$dir/$i.body" -w '%{http_code}' \
          -- "${pending[$key]}" >| "$dir/$i.code" 2>| "$dir/$i.err"
        print -r -- $? >| "$dir/$i.rc"
      } &
      pids+=($!)
      # Keep the fan-out bounded; a subscription list can be long.
      if (( ${#pids} >= MAX_THREADS )); then
        wait "${pids[@]}" 2>/dev/null || true
        pids=()
      fi
    done
    (( ${#pids} )) && { wait "${pids[@]}" 2>/dev/null || true }
    i=0
    for key in "${keys[@]}"; do
      (( ++i ))
      rc=$(<"$dir/$i.rc" 2>/dev/null) || rc=1
      local code="" body=""
      [[ -f "$dir/$i.code" ]] && code=$(<"$dir/$i.code")
      if [[ "$rc" == 0 && "$code" == 2* ]]; then
        [[ -f "$dir/$i.body" ]] && body=$(<"$dir/$i.body")
        concurrent_body[$key]=$body
        unset "pending[$key]"
        continue
      fi
      # A settled 4xx is an answer; do not keep retrying it.
      if [[ "$rc" == 0 && "$code" == 4* && "$code" != 408 && "$code" != 429 ]]; then
        printf 'Warning: %s for @%s returned HTTP %s\n' "$what" "$key" "$code" >&2
        unset "pending[$key]"
        continue
      fi
      printf 'Warning: %s for @%s failed (attempt %s/%s)\n' \
        "$what" "$key" "$attempt" "$fetch_attempts" >&2
    done
    rm -rf -- "$dir"
  done
  for key in "${(@k)pending}"; do
    printf 'Warning: giving up on %s for @%s (%s)\n' "$what" "$key" "${pending[$key]}" >&2
  done
  return 0
}

# Refresh this wrapper in place from the head of master on GitHub, so a copy
# living outside a git clone (the Windows box) still tracks the repo. $2 is the
# first line the payload must start with; anything else is assumed to be an
# error page or a captive-portal interstitial and is refused, because writing it
# would leave the machine with no working wrapper at all. $3 is the path under
# master to fetch, which defaults to $1 and differs only for --py, where the
# payload for ./yy.zsh comes from py/yy.zsh.
update_self() {
  local name=$1 sentinel=$2 remote=${3:-$1} url body tmp
  url="${script_raw_base}/${remote}"
  body=$(fetch_url "$url" "${remote} from master") || {
    printf 'Warning: could not refresh %s from master\n' "$name" >&2
    return 1
  }
  if [[ "$body" != "${sentinel}"* ]]; then
    printf 'Warning: refusing to overwrite %s: fetched body does not start with %s\n' \
      "$name" "$sentinel" >&2
    return 1
  fi
  if [[ -f "./$name" && "$(<"./$name")" == "$body" ]]; then
    printf '%s is already up to date\n' "$name"
    return 0
  fi
  # Keep update scratch files and the recoverable previous copy under ./.tmp.
  tmp="$temporary_directory/${name}.new.$$"
  print -r -- "$body" > "$tmp" || return 1
  # A .zsh wrapper is always made executable: --py and --no-py can create one
  # in a directory that never had it, and -x on the absent target would leave
  # the new file unrunnable.
  if [[ -x "./$name" || "$name" == *.zsh ]]; then chmod +x "$tmp" || true; fi
  [[ -f "./$name" ]] && { cp -p -- "./$name" "$temporary_directory/${name}.bak" || true }
  mv -f -- "$tmp" "./$name" || return 1
  printf 'Updated %s from master (previous copy saved in .tmp)\n' "$name"
}

# ---------------------------------------------------------------------------
# Channel id resolution
# ---------------------------------------------------------------------------

cached_channel_id() {
  local handle=$1 h id
  [[ -f "$channel_id_cache_file" ]] || return 1
  while IFS=$'\t' read -r h id || [[ -n "$h" ]]; do
    # yy.ps1 on Windows PowerShell 5.1 writes this file with a BOM and CRLF,
    # so every field is trimmed before it is compared.
    h=$(trim "$h"); id=$(trim "$id")
    if [[ "$h" == "$handle" && "$id" =~ ^UC[A-Za-z0-9_-]+$ ]]; then
      print -r -- "$id"
      return 0
    fi
  done < "$channel_id_cache_file"
  return 1
}

# Upsert (or, with an empty id, drop) a handle in the cache. Written through on
# every change so an interrupted run still keeps what it learned. A cache write
# failure must never fail a run.
store_channel_id() {
  local handle=$1 id=$2 tmp h existing
  tmp=$(mktemp "$temporary_directory/channel-id-cache.txt.new.XXXXXX") || return 0
  if [[ -f "$channel_id_cache_file" ]]; then
    while IFS=$'\t' read -r h existing || [[ -n "$h" ]]; do
      # Normalize away any BOM/CRLF left by yy.ps1, so rewriting heals the file.
      h=$(trim "$h"); existing=$(trim "$existing")
      [[ -z "$h" || "$h" == "$handle" ]] && continue
      printf '%s\t%s\n' "$h" "$existing" >> "$tmp"
    done < "$channel_id_cache_file"
  fi
  [[ -n "$id" ]] && printf '%s\t%s\n' "$handle" "$id" >> "$tmp"
  LC_ALL=C sort -o "$tmp" "$tmp" 2>/dev/null || true
  if ! mv -f -- "$tmp" "$channel_id_cache_file" 2>/dev/null; then
    printf 'Warning: could not write %s\n' "$channel_id_cache_file" >&2
    rm -f -- "$tmp"
  fi
  return 0
}

# Extract the UC… channel id from a channel page, trying each known shape.
scrape_channel_id() {
  local html=$1 id pattern token
  for pattern in 'channel_id=UC[A-Za-z0-9_-]*' '"externalId":"UC[A-Za-z0-9_-]*' '/channel/UC[A-Za-z0-9_-]*'; do
    token=$(printf '%s' "$html" | grep -o "$pattern" | head -1) || token=""
    [[ -n "$token" ]] || continue
    # Strip the prefix rather than re-matching UC… inside the token. A
    # second match with a leading .* is greedy, so it backtracks to the
    # *last* UC in the token: UCLr9zotVorE1-hH48UZpUCw yielded "UCw", which
    # still looks like a valid id and so was cached and used, and every feed
    # fetch for that channel then 404'd. A UC id contains no = / or ", so
    # trimming to the last one of those is exact for all three prefixes.
    id=${token##*[=/\"]}
    if [[ "$id" =~ ^UC[A-Za-z0-9_-]+$ ]]; then
      print -r -- "$id"
      return 0
    fi
  done
  return 1
}

# Run yt-dlp and capture stdout in $ytdlp_output. --no-deadline waits forever
# (channel scans legitimately take minutes); --show-progress <label> mirrors
# yt-dlp's own progress lines to the console the way yy.ps1 does.
ytdlp_output=""
run_ytdlp_metadata() {
  local tmp pid waited=0 rc=0 deadline=$ytdlp_deadline_sec show_progress=0 progress_label="yt-dlp"
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --no-deadline) deadline=0; shift ;;
      --show-progress) show_progress=1; progress_label=$2; shift 2 ;;
      *) break ;;
    esac
  done
  ytdlp_output=""
  tmp=$(mktemp "$temporary_directory/yt-dlp-metadata.XXXXXX") || return 1
  if (( show_progress )); then
    "$@" >"$tmp" 2> >(
      while IFS= read -r line; do
        if [[ "$line" != '[debug]'* && \
              ( "$line" == \[* || "$line" == ERROR:* || "$line" == WARNING:* || "$line" == 'Aborting '* ) ]]; then
          printf '[%s] %s\n' "$progress_label" "$line" >&2
        fi
      done
    ) & pid=$!
  else
    "$@" >"$tmp" 2>/dev/null & pid=$!
  fi
  while kill -0 "$pid" 2>/dev/null; do
    if (( deadline > 0 && waited >= deadline )); then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f -- "$tmp"
      printf 'Warning: yt-dlp metadata probe timed out after %s seconds\n' "$deadline" >&2
      return 124
    fi
    sleep 1
    (( ++waited ))
    if (( show_progress && waited % 15 == 0 )); then
      printf '[%s] Still running yt-dlp... %s seconds elapsed\n' "$progress_label" "$waited"
    fi
  done
  wait "$pid" || rc=$?
  ytdlp_output=$(<"$tmp")
  rm -f -- "$tmp"
  return "$rc"
}

# Last-resort channel id resolution using the vendored yt-dlp binary, which
# tracks YouTube's page layout far more closely than the regexes above. Stays
# logged-out (no --cookies) so the feed remains public-by-construction.
channel_id_via_ytdlp() {
  local url=$1 exe id
  exe=$(ytdlp_path) || return 1
  run_ytdlp_metadata "$exe" --ignore-config --no-warnings --socket-timeout "$ytdlp_timeout_sec" \
    --retries "$ytdlp_attempts" --extractor-retries "$ytdlp_attempts" --flat-playlist \
    --playlist-items 0 --print 'playlist:%(channel_id)s' "$url" || return 1
  id=$(printf '%s\n' "$ytdlp_output" | grep -o '^UC[A-Za-z0-9_-]*$' | head -n 1) || id=""
  [[ -n "$id" ]] || return 1
  print -r -- "$id"
}

# Resolve a channel handle to its UC id, leaving the id in $resolved_channel_id
# and its origin ('cache', 'page' or 'yt-dlp') in $resolved_source. Pass a
# non-empty $3 to bypass the cache. Returns non-zero when every method failed.
resolved_channel_id=""
resolved_source=""
resolve_channel_id() {
  local handle=$1 channel_url=$2 skip_cache=${3:-} html id
  resolved_channel_id=""
  resolved_source=""

  if [[ -z "$skip_cache" ]]; then
    if id=$(cached_channel_id "$handle"); then
      resolved_channel_id=$id
      resolved_source="cache"
      return 0
    fi
  fi

  if html=$(fetch_url "$channel_url" "channel page for @${handle}"); then
    if id=$(scrape_channel_id "$html"); then
      resolved_channel_id=$id
      resolved_source="page"
      store_channel_id "$handle" "$id"
      return 0
    fi
    printf 'Warning: no channel_id found on %s\n' "$channel_url" >&2
  fi

  if id=$(channel_id_via_ytdlp "$channel_url"); then
    resolved_channel_id=$id
    resolved_source="yt-dlp"
    store_channel_id "$handle" "$id"
    return 0
  fi

  printf 'Warning: could not resolve a channel id for @%s\n' "$handle" >&2
  return 1
}

# Newest <published> in an Atom feed body, in epoch ms, or 0 when the body
# holds no usable entry.
feed_newest_ms_from_body() {
  local feed=$1 what=$2 ts epoch newest=0 seen=0
  if [[ "$feed" != *'<feed'* || "$feed" != *'</feed>'* ]]; then
    printf 'Warning: malformed video feed for %s\n' "$what" >&2
    print -r -- 0
    return 0
  fi
  # Entries are not guaranteed to be date-sorted, so scan them all.
  for ts in ${(f)"$(printf '%s' "$feed" | grep -o '<published>[^<]*</published>' | sed 's/<[^>]*>//g')"}; do
    [[ -n "$ts" ]] || continue
    (( ++seen ))
    if ! epoch=$(iso_to_epoch_ms "$ts"); then
      printf "Warning: unparsable <published> value '%s' for %s\n" "$ts" "$what" >&2
      continue
    fi
    (( epoch > newest )) && newest=$epoch
  done
  print -r -- "$newest"
}

# Print the newest <published> in a channel's Atom feed, in epoch ms.
# Prints "-1 fetch" when the feed could not be read, otherwise "<ms> ok"; 0
# milliseconds means it holds no entries. Those cases must stay distinguishable,
# or a network failure reads as an empty channel. The feed omits members-only
# videos, so it is public-by-construction.
feed_newest_ms() {
  local channel_id=$1 feed feed_url newest
  feed_url="https://www.youtube.com/feeds/videos.xml?channel_id=${channel_id}"
  if ! feed=$(fetch_url "$feed_url" "video feed for ${channel_id}" no-consent); then
    print -r -- '-1 fetch'
    return 0
  fi
  newest=$(feed_newest_ms_from_body "$feed" "$channel_id")
  if (( newest <= 0 )); then
    print -r -- '-1 ok'
    return 0
  fi
  print -r -- "$newest ok"
}

# Fetch the Atom feeds for cached --html2 channels concurrently. A result is
# recorded only for a usable feed with at least one parseable <published>
# value; anything else is deliberately absent so the caller falls back to the
# cookie-backed yt-dlp scan.
typeset -gA html_feed_newest
html_feed_newest_concurrent() {
  local map_name=$1 key newest
  local -A ids urls
  html_feed_newest=()
  ids=("${(@Pkv)map_name}")
  (( ${#ids} )) || return 0
  for key in "${(@k)ids}"; do
    urls[$key]="https://www.youtube.com/feeds/videos.xml?channel_id=${ids[$key]}"
  done
  fetch_urls_concurrent urls "video feed" no-consent
  for key in "${(@k)ids}"; do
    if (( ! ${+concurrent_body[$key]} )); then
      printf 'Warning: giving up on video feed for @%s; using yt-dlp\n' "$key" >&2
      continue
    fi
    newest=$(feed_newest_ms_from_body "${concurrent_body[$key]}" "@$key")
    if (( newest > 0 )); then
      html_feed_newest[$key]=$newest
    else
      printf 'Warning: unusable video feed for @%s; using yt-dlp\n' "$key" >&2
    fi
  done
  return 0
}

# Fetch og:image avatars for the given channel keys concurrently.
typeset -gA channel_thumbnails
channel_thumbnails_concurrent() {
  local key thumb
  local -A urls
  channel_thumbnails=()
  (( $# )) || return 0
  for key in "$@"; do
    urls[$key]=$(channel_url_for "$key")
  done
  fetch_urls_concurrent urls "avatar"
  for key in "$@"; do
    (( ${+concurrent_body[$key]} )) || continue
    thumb=$(printf '%s' "${concurrent_body[$key]}" \
      | grep -o '<meta property="og:image" content="[^"]*"' \
      | sed -n '1s/.*content="\([^"]*\)".*/\1/p') || thumb=""
    thumb=${thumb//&amp;/&}
    [[ -n "$thumb" ]] && channel_thumbnails[$key]=$thumb
  done
  return 0
}

# Fall back to the newest few entries in the channel's uploads playlist when
# the legacy Atom feed is unavailable or unusable. Resolve the entries so
# yt-dlp can provide exact timestamps and public availability. No cookies are
# sent. Prints -1 when the fallback failed and 0 when no public entry was seen.
ytdlp_newest_public_ms() {
  local channel_id=$1 exe uploads_id uploads_url out rc=0 line timestamp newest=0
  exe=$(ytdlp_path) || {
    printf 'Warning: yt-dlp binary not found for uploads fallback for %s\n' "$channel_id" >&2
    print -r -- -1
    return 0
  }
  uploads_id="UU${channel_id#UC}"
  uploads_url="https://www.youtube.com/playlist?list=${uploads_id}"
  run_ytdlp_metadata "$exe" --ignore-config --no-warnings --socket-timeout "$ytdlp_timeout_sec" \
    --retries "$ytdlp_attempts" --extractor-retries "$ytdlp_attempts" --skip-download \
    --playlist-items '1:5' --print 'fallback:%(timestamp)s:%(availability)s' \
    "$uploads_url" || rc=$?
  out=$ytdlp_output
  for line in ${(f)out}; do
    if [[ "$line" =~ '^fallback:([0-9]+):public$' ]]; then
      timestamp=${match[1]}
      (( timestamp *= 1000 ))
      (( timestamp > newest )) && newest=$timestamp
    fi
  done
  if (( newest > 0 )); then
    print -r -- "$newest"
  elif (( rc != 0 )); then
    printf 'Warning: yt-dlp uploads fallback failed for %s (%s)\n' \
      "$channel_id" "$uploads_url" >&2
    print -r -- -1
  else
    print -r -- 0
  fi
}

# Try the cheap Atom feed first, then the logged-out uploads-playlist fallback.
# Leave the timestamp in $public_newest_ms_result so feed-failure state survives
# in the caller rather than being lost in a command-substitution subshell.
public_newest_ms_result=-1
public_newest_ms_for_channel_id() {
  local channel_id=$1 newest state
  public_newest_ms_result=-1
  if (( skip_feed_fetches )); then
    printf 'Warning: skipping unreliable video feed for %s; using yt-dlp uploads fallback\n' \
      "$channel_id" >&2
    public_newest_ms_result=$(ytdlp_newest_public_ms "$channel_id")
    return 0
  fi
  read -r newest state <<< "$(feed_newest_ms "$channel_id")"
  if [[ "$state" == "fetch" ]] && (( ! feed_failure_counted_for_channel )); then
    feed_failure_counted_for_channel=1
    (( ++feed_fetch_failures ))
    if (( feed_fetch_failures >= feed_failure_limit )); then
      skip_feed_fetches=1
      printf 'Warning: %s video feeds failed; skipping feed fetches for remaining channels\n' \
        "$feed_fetch_failures" >&2
    fi
  fi
  if (( newest > 0 )); then
    public_newest_ms_result=$newest
    return 0
  fi
  printf 'Warning: using yt-dlp uploads fallback for %s\n' "$channel_id" >&2
  public_newest_ms_result=$(ytdlp_newest_public_ms "$channel_id")
}

# Leave the epoch-ms publish time of the newest public video in
# $newest_public_ms_result: 0 when the channel genuinely has none, or -1 when
# the check could not be completed.
newest_public_ms_result=-1
newest_public_ms() {
  local handle=$1 channel_url=$2 newest channel_id source
  newest_public_ms_result=-1
  feed_failure_counted_for_channel=0
  resolve_channel_id "$handle" "$channel_url" || return 0
  channel_id=$resolved_channel_id
  source=$resolved_source
  public_newest_ms_for_channel_id "$channel_id"
  newest=$public_newest_ms_result

  # If neither source can check a cached id, the handle may now point at a
  # different channel. Drop the stale entry and resolve once more.
  if (( newest < 0 )) && [[ "$source" == "cache" ]]; then
    store_channel_id "$handle" ""
    resolve_channel_id "$handle" "$channel_url" "skip-cache" || return 0
    channel_id=$resolved_channel_id
    public_newest_ms_for_channel_id "$channel_id"
    newest=$public_newest_ms_result
  fi

  if (( newest == 0 )); then
    printf 'Warning: no public videos found via the feed or uploads fallback for %s (@%s)\n' \
      "$channel_id" "$handle" >&2
  fi
  newest_public_ms_result=$newest
}

# Implement -o (check against the checkpoint) and -O (open everything).
# Records the listed-channel and failed-check counts in globals, and returns
# non-zero when any channel's check could not be completed.
open_failure_count=0
open_channel_count=0
run_open_mode() {
  local mode=$1 checkpoint_ms=0 line channel channel_url newest failures=0 check_batch_ms
  open_failure_count=0
  open_channel_count=0
  if [[ ! -f "$channels_file" ]]; then
    printf 'Error: %s does not exist\n' "$channels_file" >&2
    return 1
  fi
  if [[ "$mode" == "check" ]]; then
    feed_fetch_failures=0
    skip_feed_fetches=0
    checkpoint_ms=$(read_checkpoint_ms) || return 1
    printf 'Checkpoint: %s\n' "$checkpoint_ms"
  fi
  check_batch_ms=$(now_ms)
  while IFS= read -r line || [[ -n "$line" ]]; do
    channel=$(trim "$line")
    [[ -n "$channel" && "$channel" != '#'* ]] || continue
    (( ++open_channel_count ))
    channel=${channel#@}
    channel_url=$(channel_url_for "$channel")
    if [[ "$mode" == "open" ]]; then
      open_url "$channel_url"
      continue
    fi
    newest_public_ms "$channel" "$channel_url"
    newest=$newest_public_ms_result
    if (( newest < 0 )); then
      (( ++failures ))
      printf '%s: CHECK FAILED (see warnings above; not opened)\n' "$channel"
      continue
    fi
    record_channel_check "$channel" "$newest" "$check_batch_ms"
    if (( newest == 0 )); then
      printf '%s: no public videos found (skipped)\n' "$channel"
    elif (( newest > checkpoint_ms )); then
      printf '%s: new public video (%s > %s)\n' "$channel" "$newest" "$checkpoint_ms"
      open_url "$channel_url"
    else
      printf '%s: up to date (%s <= %s)\n' "$channel" "$newest" "$checkpoint_ms"
    fi
  done < "$channels_file"
  open_failure_count=$failures
  save_channel_check_status
  if (( failures > 0 )); then
    printf 'Error: %s channel check(s) failed\n' "$failures" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# --html / --html2 page generation
# ---------------------------------------------------------------------------

# Scan one channel in an isolated subshell. Each worker owns one channel and
# writes to index-specific files, so concurrent scans never share mutable state.
html_scan_channel() {
  local index=$1 channel=$2 channel_url=$3 exe=$4 scan_cutoff_sec=$5 result_dir=$6 cookie_file=$7 rc=0
  run_ytdlp_metadata --no-deadline --show-progress "@$channel scan" "$exe" --ignore-config --verbose \
    --cookies "$cookie_file" --flat-playlist --lazy-playlist \
    --extractor-args 'youtubetab:approximate_date' \
    --socket-timeout "$ytdlp_timeout_sec" --retries "$ytdlp_attempts" \
    --extractor-retries "$ytdlp_attempts" --skip-download \
    --break-match-filters "timestamp >= ${scan_cutoff_sec}" \
    --print $'scan:%(id)s\t%(webpage_url)s\t%(title)s\t%(timestamp)s\t%(availability)s' \
    "$channel_url" || rc=$?
  print -rn -- "$ytdlp_output" >| "$result_dir/$index.out"
  print -r -- "$rc" >| "$result_dir/$index.status"
}

html_page_css='<style>:root{--bg:#0d1117;--card:#161b22;--bd:#30363d;--fg:#e6edf3;--mut:#8b949e;--acc:#58a6ff;--ok:#3fb950}*{box-sizing:border-box}body{margin:0;padding:16px 60px;background:var(--bg);color:var(--fg);font:14px/1.55 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif}h1{font-size:32px;margin:0 0 6px;color:var(--fg);border-bottom:3px solid var(--acc);padding-bottom:8px}h2{font-size:22px;margin:0;color:var(--acc)}.channel-title h2 a{color:var(--acc);text-decoration:underline;text-underline-offset:3px}p{color:var(--mut);font-size:12.5px;margin:0 0 16px}button{background:#21262d;color:var(--fg);border:1px solid var(--bd);border-radius:6px;padding:5px 10px;cursor:pointer;font:inherit}button:hover{border-color:var(--acc);background:#1c2230}.grid{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:12px;margin:12px 0 28px}.card{background:var(--card);border:1px solid var(--bd);padding:10px;border-radius:10px}.video-link{display:block;color:var(--fg);text-decoration:none}.video-link:hover{color:var(--acc)}.preview{position:relative;aspect-ratio:16/9;background:#0b0f14;overflow:hidden;border-radius:6px}.preview img{width:100%;height:100%;object-fit:cover;transition:transform .2s ease,filter .2s ease}.card:hover .preview img{transform:scale(1.04);filter:brightness(.82)}.video-title{font-size:12px;line-height:1.4;margin-top:7px}.checks,.controls,.channel-title{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.checks{margin-top:8px;color:var(--mut)}.channel{margin-top:28px}.channel-title{padding-bottom:6px;border-bottom:1px solid var(--bd)}.controls button{padding:4px 9px}.job-log{max-height:190px;overflow:auto;background:#010409;border:1px solid var(--bd);border-radius:6px;padding:8px;color:var(--mut);white-space:pre-wrap;font:12px/1.4 Consolas,monospace}.back-to-top{position:fixed;bottom:24px;right:24px;width:48px;height:48px;border-radius:50%;background:var(--acc);color:var(--bg);border:none;cursor:pointer;box-shadow:0 2px 8px rgba(0,0,0,.45);display:none;font-size:34px;font-weight:700;line-height:1}.back-to-top.visible{display:flex;align-items:center;justify-content:center}.back-to-top:hover{background:#79c0ff}@media(max-width:1100px){body{padding:16px}.grid{grid-template-columns:repeat(3,minmax(0,1fr))}}@media(max-width:650px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}}</style></head><body>
<style>.video-age{font-size:11px;color:var(--mut);margin-top:3px}.channel-bar{height:8px;background:var(--acc);margin:42px 0 12px}.channel-table{width:100%;border-collapse:collapse;margin-top:12px}.channel-table th,.channel-table td{padding:8px;border-bottom:1px solid var(--bd);text-align:left}.channel-table th{color:var(--mut)}.channel-table a{color:var(--acc)}#channel-add{width:27em}</style>'

# The page script, with the callback endpoints substituted in. This is the
# already-post-processed form of yy.ps1's New-VideoHtml script block: status
# polling is unconditional (so a job started from another tab still shows up),
# the job log auto-scrolls, and a heartbeat keeps the server alive.
html_page_script() {
  local base=$1 js
  js=$(cat <<'HTMLJS'
<script>const callback="@@DOWNLOAD@@",statusUrl="@@STATUS@@",stopUrl="@@STOP@@";const status=document.querySelector("#status"),jobLog=document.querySelector("#job-log"),setChecks=(root,action)=>root.querySelectorAll("input.y1,input.y2").forEach(x=>{if(action==="none")x.checked=false;else if(x.className===action)x.checked=true}),showJobs=async()=>{try{const r=await fetch(statusUrl),b=await r.json(),p=[];if(b.running)p.push(b.running+" running");if(b.queued)p.push(b.queued+" queued");if(b.completed)p.push(b.completed+" completed");if(b.failed)p.push(b.failed+" failed");status.textContent=p.length?p.join(", ")+"." : "No download jobs yet.";jobLog.textContent=(b.logs||[]).join("\n");jobLog.scrollTop=jobLog.scrollHeight}catch(e){status.textContent="Status unavailable: "+e.message}finally{setTimeout(showJobs,1000)}};document.addEventListener("click",e=>{const b=e.target.closest("button[data-action]");if(b)setChecks(b.closest(".channel")||document,b.dataset.action)});document.querySelector("#download").onclick=async()=>{const items=[...document.querySelectorAll("input:checked")].map(x=>({target:x.className,url:x.dataset.url,path:x.dataset.path,channel_id:x.dataset.channelId,video_id:x.dataset.videoId}));if(!items.length){status.textContent="Select at least one video";return}status.textContent="Starting local downloads...";try{const r=await fetch(callback,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({items})}),b=await r.json();status.textContent=b.message||"Started";showJobs()}catch(e){status.textContent="Callback failed: "+e.message}};document.querySelector("#stop").onclick=async()=>{try{const r=await fetch(stopUrl,{method:"POST"}),b=await r.json();status.textContent=b.message||"Server stopped"}catch(e){status.textContent="Server stopped"}window.close();setTimeout(()=>location.replace("about:blank"),150)};setInterval(()=>fetch("@@HEARTBEAT@@",{method:"POST",keepalive:true}),2000);showJobs();const backToTop=document.querySelector("#back-to-top"),toggleTop=()=>backToTop.classList.toggle("visible",window.scrollY>200);window.addEventListener("scroll",toggleTop,{passive:true});toggleTop();</script><script>const postJson=(u,x)=>fetch(u,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(x)}),refreshPage=async(all=false)=>{status.textContent=all?"Refreshing all channels...":"Refreshing channels...";try{const b=await (await fetch(all?"@@REFRESHALL@@":"@@REFRESH@@",{method:"POST"})).json();status.textContent=b.message;if(!b.message||b.message==="Refreshing page.")location.reload()}catch(e){status.textContent="Refresh failed: "+e.message}};document.querySelector("#checkpoint").onclick=async()=>{const b=await (await fetch("@@CHECKPOINT@@",{method:"POST"})).json();status.textContent=b.message;if(b.checkpoint_ms)document.querySelector("#checkpoint-value").textContent="Checkpoint: "+b.checkpoint_ms};document.querySelector("#refresh").onclick=()=>refreshPage(false);document.querySelector("#refresh-all").onclick=()=>refreshPage(true);document.querySelector("#channel-add-button").onclick=async()=>{const x=document.querySelector("#channel-add").value.trim();if(x){await postJson("@@CHANNEL@@",{action:"add",channel:x});refreshPage()}};document.querySelectorAll(".channel-delete").forEach(b=>b.onclick=async()=>{await postJson("@@CHANNEL@@",{action:"delete",channel:b.dataset.channel});refreshPage()});</script>
HTMLJS
  )
  js=${js//@@DOWNLOAD@@/${base}/download/${html_token}}
  js=${js//@@STATUS@@/${base}/status/${html_token}}
  js=${js//@@STOP@@/${base}/stop/${html_token}}
  js=${js//@@HEARTBEAT@@/${base}/heartbeat/${html_token}}
  js=${js//@@CHECKPOINT@@/${base}/checkpoint/${html_token}}
  js=${js//@@REFRESHALL@@/${base}/refresh-all/${html_token}}
  js=${js//@@REFRESH@@/${base}/refresh/${html_token}}
  js=${js//@@CHANNEL@@/${base}/channel/${html_token}}
  print -r -- "$js"
}


# ---------------------------------------------------------------------------
# --html3
#
# --html3 has its own shell, state document, and channel fragments. It never
# reads or writes yy.html, which remains exclusively owned by --html/--html2:
# the parent writes a loading page immediately, then a worker process
# (`yy.zsh --html3-worker <token>`) performs the scan and streams one HTML
# fragment per channel back through the callback server.
# ---------------------------------------------------------------------------

typeset -ga html3_failed_channels html3_progress_updates
typeset -g html3_fragment_text=""
typeset -g html3_progress_completed=0 html3_progress_total=0

html3_progress_file() { print -r -- "$temporary_directory/yy-html3-$1.json"; }
html3_fragments_dir() { print -r -- "$temporary_directory/yy-html3-$1"; }
html3_worker_log()    { print -r -- "$temporary_directory/yy-html3-worker-$1.out"; }

# "Checkpoint: MM/dd/yyyy, HH:mm:ss Pacific Time (<age>)", empty when unset.
format_html3_checkpoint_text() {
  local ms=${1:-0} stamp
  [[ "$ms" == <-> ]] || { print -r -- ''; return 0 }
  (( ms <= 0 )) && { print -r -- ''; return 0 }
  stamp=$(TZ=America/Los_Angeles date -r $(( ms / 1000 )) '+%m/%d/%Y, %H:%M:%S' 2>/dev/null) \
    || stamp=$(TZ=America/Los_Angeles date -d "@$(( ms / 1000 ))" '+%m/%d/%Y, %H:%M:%S' 2>/dev/null) \
    || { print -r -- ''; return 0 }
  print -r -- "Checkpoint: ${stamp} Pacific Time ($(format_relative_ms "$ms"))"
}

# Build one channel's card section. Unlike --html/--html2, a video that was
# already submitted for download loses its whole card instead of coming back
# with a restored checkbox. Publishes through a global: a command substitution
# would fork, and the progress log lines below would be swallowed with it.
html3_channel_fragment() {
  local channel=$1 channel_id=$2 scan_out=$3 prior_rows=$4 cutoff_ms=$5
  local row key cards="" restored_targets=0 visible=0 entry_ms entry_id
  local -a fields parts order sortable
  local -A entry_row
  html3_fragment_text=""

  for row in ${(f)prior_rows}; do
    [[ -n "$row" ]] || continue
    fields=("${(@s:	:)row}")
    [[ -n "${fields[1]:-}" ]] || continue
    (( ${+entry_row[${fields[1]}]} )) || order+=("${fields[1]}")
    entry_row[${fields[1]}]=$row
  done
  for row in ${(f)scan_out}; do
    [[ "$row" == scan:* ]] || continue
    fields=("${(@s:	:)row}")
    (( ${#fields} >= 5 )) || continue
    case "${fields[5]}" in
      subscriber_only|private|premium_only) continue ;;
    esac
    [[ "${fields[4]}" == <-> ]] || continue
    entry_ms=${fields[4]}
    (( entry_ms < 100000000000 )) && (( entry_ms *= 1000 ))
    entry_id=${fields[1]#scan:}
    [[ -n "$entry_id" ]] || continue
    (( ${+entry_row[$entry_id]} )) || order+=("$entry_id")
    entry_row[$entry_id]="${entry_id}"$'\t'"${fields[2]}"$'\t'"$(sanitize_field "${fields[3]}")"$'\t'"${entry_ms}"$'\t'"${fields[5]}"
  done

  for key in "${order[@]}"; do
    row=${entry_row[$key]}
    fields=("${(@s:	:)row}")
    (( ${#fields} >= 4 )) || continue
    case "${fields[5]:-}" in
      subscriber_only|private|premium_only) continue ;;
    esac
    [[ "${fields[4]}" == <-> ]] || continue
    (( fields[4] >= cutoff_ms )) || continue
    sortable+=("${fields[4]}"$'\t'"$row")
  done
  (( ${#sortable} )) || sortable=()

  local vid vurl vtitle video_ms thumb age
  if (( ${#sortable} )); then
    for row in ${(f)"$(printf '%s\n' "${sortable[@]}" | LC_ALL=C sort -t $'\t' -k1,1nr)"}; do
      [[ -n "$row" ]] || continue
      row=${row#*$'\t'}
      parts=("${(@s:	:)row}")
      vid=${parts[1]}; vurl=${parts[2]}; vtitle=${parts[3]}; video_ms=${parts[4]}
      [[ -n "$vid" && -n "$vurl" ]] || continue
      # A restored target means this video was already submitted for download.
      # Remove the whole card rather than offering either target again.
      local dropped=0
      # zsh does not expand $'\t' inside an array subscript, so build the key first.
      local dl_key_y1="${channel_id}${tab_char}${vid}${tab_char}y1"
      local dl_key_y2="${channel_id}${tab_char}${vid}${tab_char}y2"
      if (( ${+downloaded_set[$dl_key_y1]} )); then
        (( ++restored_targets )); dropped=1
      fi
      if (( ${+downloaded_set[$dl_key_y2]} )); then
        (( ++restored_targets )); dropped=1
      fi
      (( dropped )) && continue
      thumb="https://i.ytimg.com/vi/${vid}/hqdefault.jpg"
      age=$(format_relative_ms "$video_ms")
      cards+='<article class="card"><a class="video-link" href="'$(html_escape "$vurl")'" target="_blank" rel="noopener noreferrer"><div class="preview"><img src="'$(html_escape "$thumb")'" alt=""></div><div class="video-title">'$(html_escape "$vtitle")'</div></a><div class="video-age">'$(html_escape "$age")'</div><div class="checks"><label><input class="y1" data-url="'$(html_escape "$vurl")'" data-path="'$(html_escape "./${channel}")'" data-channel-id="'$(html_escape "$channel_id")'" data-video-id="'$(html_escape "$vid")'" type="checkbox"> y1</label><label><input class="y2" data-url="'$(html_escape "$vurl")'" data-path="'$(html_escape "./${channel}")'" data-channel-id="'$(html_escape "$channel_id")'" data-video-id="'$(html_escape "$vid")'" type="checkbox"> y2</label></div></article>'$'\n'
      (( ++visible ))
    done
  fi

  if (( restored_targets > 0 )); then
    if (( visible == 0 )); then
      printf 'Remove @%s from preview section: no visible cards after %s downloaded target selection(s) loaded.\n' "$channel" "$restored_targets"
    else
      printf 'Update @%s to show %s visible card(s) after %s downloaded target selection(s) loaded.\n' "$channel" "$visible" "$restored_targets"
    fi
  fi
  [[ -n "$cards" ]] || return 0
  html3_fragment_text='<section class="channel" data-html3-channel="'$(html_escape "$channel")'"><div class="channel-title"><h2><a href="'$(html_escape "$(channel_url_for "$channel")")'" target="_blank" rel="noopener noreferrer">'$(html_escape "$channel")'</a></h2><div class="controls"><button data-action="y1" type="button">y1</button><button data-action="y2" type="button">y2</button><button data-action="none" type="button">none</button></div></div><div class="grid">'"$cards"'</div></section>'
  return 0
}

# Render and publish one channel's fragment, then record it as a page update.
# Called from inside generate_html, so html_channel_ids and downloaded_set are
# visible through zsh's dynamic scoping.
html3_emit_fragment() {
  local index=$1 channel=$2 scan_out=$3 fragments_path=$4 cutoff_sec=$5
  html3_channel_fragment "$channel" "${html_channel_ids[$channel]:-}" "$scan_out" \
    "${cache_entries[$channel]:-}" $(( cutoff_sec * 1000 ))
  print -rn -- "$html3_fragment_text" >| "$fragments_path/$index.html" 2>/dev/null || true
  html3_progress_updates+=("${channel}"$'\t'"${index}")
  return 0
}

html3_updates_json() {
  local u first=1 out='['
  local -a fields
  for u in "${html3_progress_updates[@]}"; do
    fields=("${(@s:	:)u}")
    (( first )) || out+=','
    first=0
    out+='{"channel":"'$(json_escape "${fields[1]}")'","fragment":'"${fields[2]}"'}'
  done
  print -r -- "${out}]"
}

# Both state writers stage into <path>.new.<pid> and then *copy* over the
# target. A rename would briefly unlink the file the page is polling.
html3_write_state_file() {
  local jpath=$1 body=$2 tmp="${1}.new.$$"
  print -rn -- "$body" >| "$tmp" 2>/dev/null || return 0
  cp -f -- "$tmp" "$jpath" 2>/dev/null || true
  rm -f -- "$tmp" 2>/dev/null || true
  return 0
}

write_html3_progress() {
  local jpath=$1 completed=$2 total=$3
  html3_progress_completed=$completed
  html3_progress_total=$total
  html3_write_state_file "$jpath" \
    '{"status":"running","success":false,"message":"Loading channels: '"${completed} / ${total}"'","completed":'"$completed"',"total":'"$total"',"updates":'"$(html3_updates_json)"'}'
}

set_html3_worker_state() {
  local jpath=$1 state=$2 message=$3 err=${4:-} success=false
  local failures='[' first=1 entry
  local -a fields
  [[ "$state" == success ]] && success=true
  for entry in "${html3_failed_channels[@]}"; do
    fields=("${(@s:	:)entry}")
    (( first )) || failures+=','
    first=0
    failures+='{"channel":"'$(json_escape "${fields[1]}")'","stage":"'$(json_escape "${fields[2]:-}")'"}'
  done
  failures+=']'
  html3_write_state_file "$jpath" \
    '{"status":"'$(json_escape "$state")'","success":'"$success"',"message":"'$(json_escape "$message")'","error":"'$(json_escape "$err")'","failed_channels":'"$failures"',"completed":'"$html3_progress_completed"',"total":'"$html3_progress_total"',"updates":'"$(html3_updates_json)"'}'
}

# Prune .tmp entries that --html3 and yt-dlp leave behind. Self-update backups
# and anything unrelated are deliberately untouched.
remove_stale_temporary_artifacts() {
  local entry name removed=0
  local -a stale
  stale=()
  for entry in "$temporary_directory"/*(ND); do
    name=${entry:t}
    case "$name" in
      yy-html*|yy-fetch*|yt-dlp-metadata.*) ;;
      *) continue ;;
    esac
    [[ -n $(find "$entry" -maxdepth 0 -mtime +45 2>/dev/null) ]] || continue
    stale+=("$entry")
  done
  for entry in "${stale[@]}"; do
    rm -rf -- "$entry" 2>/dev/null || true
    (( ++removed ))
  done
  (( removed > 0 )) && printf 'Pruned %s temporary HTML/yt-dlp artifact(s) older than 45 days.\n' "$removed"
  return 0
}

# The --html3 loading shell. This is the already-post-processed form of
# yy.ps1's Write-Html3LoadingPage here-string plus its replacement chain, the
# same convention html_page_script follows.
write_html3_loading_page() {
  local token=$1 message=$2 page tmp="${html3_file}.new.$$"
  page=$(cat <<'HTML3PAGE'

<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>YouTube Video Download</title><style>:root{--bg:#0d1117;--card:#161b22;--bd:#30363d;--fg:#e6edf3;--mut:#8b949e;--acc:#58a6ff}*{box-sizing:border-box}body{margin:0;padding:16px 60px;background:var(--bg);color:var(--fg);font:14px/1.55 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif}h1{font-size:32px;margin:0 0 6px;padding-bottom:0}h2{font-size:22px;margin:0}.channel-title h2 a{color:var(--acc)}p{color:var(--mut);font-size:12.5px;margin:0 0 16px}button{background:#21262d;color:var(--fg);border:1px solid var(--bd);border-radius:6px;padding:5px 10px;cursor:pointer;font:inherit}button:disabled,input:disabled{opacity:.55;cursor:wait}.controls,.checks,.channel-title{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.controls button{padding:4px 9px}.channel{margin-top:28px}.channel-title{padding-bottom:6px;border-bottom:1px solid var(--bd)}.grid{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:12px;margin:12px 0 28px}.card{background:var(--card);border:1px solid var(--bd);padding:10px;border-radius:10px}.video-link{display:block;color:var(--fg);text-decoration:none}.preview{aspect-ratio:16/9;background:#0b0f14;overflow:hidden;border-radius:6px}.preview img{width:100%;height:100%;object-fit:cover}.video-title{font-size:12px;line-height:1.4;margin-top:7px}.checks{margin-top:8px;color:var(--mut)}.video-age{font-size:11px;color:var(--mut);margin-top:3px}.job-log{max-height:190px;overflow:auto;background:#010409;border:1px solid var(--bd);border-radius:6px;padding:8px;color:var(--mut);white-space:pre-wrap;font:12px/1.4 Consolas,monospace}.back-to-top{position:fixed;bottom:24px;right:24px;width:48px;height:48px;border-radius:50%;background:var(--acc);color:var(--bg);border:0;display:none;font-size:34px;font-weight:700}.back-to-top.visible{display:flex;align-items:center;justify-content:center}#html3-progress{margin:0 0 16px}.html3-progress-track{height:8px;overflow:hidden;border-radius:4px;background:#30363d}.html3-progress-bar{height:100%;width:0;background:#58a6ff;transition:width .25s ease}@media(max-width:1100px){body{padding:16px}.grid{grid-template-columns:repeat(3,minmax(0,1fr))}}@media(max-width:650px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}}<style>.video-age{font-size:11px;color:var(--mut);margin-top:3px}.channel-bar{height:8px;background:var(--acc);margin:42px 0 12px}.channel-table{width:100%;border-collapse:collapse;margin-top:12px}.channel-table th,.channel-table td{padding:8px;border-bottom:1px solid var(--bd);text-align:left}.channel-table th{color:var(--mut)}.channel-table a{color:var(--acc)}.channel-table tr.html3-channel-error td{background:#3C050F;border-bottom-color:#7a1828;color:#fff}.channel-table tr.html3-channel-error a{color:#fff}#channel-add{width:27em}h2{color:var(--acc)}.channel-title h2 a{text-decoration:underline;text-underline-offset:3px}button:hover{border-color:var(--acc);background:#1c2230}.video-link:hover{color:var(--acc)}.preview{position:relative}.preview img{transition:transform .2s ease,filter .2s ease}.card:hover .preview img{transform:scale(1.04);filter:brightness(.82)}.back-to-top{border:none;box-shadow:0 2px 8px rgba(0,0,0,.45)}.back-to-top:hover{background:#79c0ff}#html3-error-panel{position:fixed;z-index:10;top:18px;left:50%;transform:translateX(-50%);max-width:min(720px,calc(100vw - 32px));padding:16px 20px;border:2px solid #ff7b72;border-radius:8px;background:#1b1114;box-shadow:0 8px 28px rgba(0,0,0,.55);color:#ff7b72;font-size:18px}#html3-error-panel[hidden]{display:none}</style><style>.html3-progress-bar{position:relative;overflow:hidden}.html3-progress-bar.loading::after{content:"";position:absolute;inset:0;transform:translateX(-100%);background:linear-gradient(90deg,transparent,rgba(255,255,255,.42),transparent);animation:html3-progress-shimmer 1.2s linear infinite}@keyframes html3-progress-shimmer{to{transform:translateX(100%)}}</style></head><body><h1>YouTube Video Download</h1><div id="html3-progress" role="status" aria-live="polite"><div class="html3-progress-track"><div class="html3-progress-bar"></div></div><p id="html3-progress-status">__MESSAGE__</p></div><p>Select y1 and/or y2, then click DOWNLOAD SELECTED to run the matching local yy hook. <span id="checkpoint-value">__CHECKPOINT__</span></p><div class="controls"><button id="download" type="button">DOWNLOAD SELECTED</button><button id="checkpoint" type="button">CHECKPOINT</button><button id="refresh" type="button">REFRESH</button><button id="refresh-all" type="button">REFRESH ALL</button><button id="stop" type="button">STOP SERVER</button><button data-action="y1" type="button">y1</button><button data-action="y2" type="button">y2</button><button data-action="none" type="button">none</button></div><p id="status"></p><div id="html3-error-panel" role="alert" aria-live="assertive" hidden><div id="html3-errors"></div></div><pre id="job-log" class="job-log"></pre><main><section id="channel-ids" class="channel"><div class="channel-bar"></div><div class="channel-title"><h2>Channel IDs</h2></div><p>Loading Channel IDs...</p></section></main><button id="back-to-top" class="back-to-top" type="button" aria-label="Back to top" title="Back to top">&uarr;</button><script>(()=>{const token="__TOKEN__",base="/html3/"+token,stateUrl=base+"/state",fragmentUrl=i=>base+"/fragment/"+i,channelsUrl=base+"/channels",api=n=>"/"+n+"/"+token,controls=[...document.querySelectorAll("button,input")],top=document.querySelector("#back-to-top"),status=document.querySelector("#status"),errors=document.querySelector("#html3-errors"),errorPanel=document.querySelector("#html3-error-panel"),log=document.querySelector("#job-log"),applied=new Set(),saved=new Set();let html3Failures=[];const html3FailureSummary=()=>html3Failures.length?"Completed with channel errors: "+html3Failures.map(x=>"@"+x.channel+" ("+x.stage+")").join(", "):"";const compactLogs=logs=>{const buckets=new Map(),percents=new Map();return logs.filter(line=>{if(/^\[y[12]\]\s*$/.test(line))return false;const m=line.match(/^(\[[^\]]+\])\s+\[download\]\s+([0-9]+(?:\.[0-9]+)?)%/);if(!m)return true;const target=m[1],percent=Number(m[2]),previous=percents.get(target);if(previous!==undefined&&percent<previous-1)buckets.set(target,-1);percents.set(target,percent);const bucket=Math.floor(percent/10),last=buckets.has(target)?buckets.get(target):-1,emit=bucket>last||percent>=100;if(emit)buckets.set(target,bucket);return emit})};const showJobs=async()=>{let again=false;try{const b=await (await fetch(api("status"),{cache:"no-store"})).json(),p=[];if(b.running)p.push(b.running+" running");if(b.queued)p.push(b.queued+" queued");if(b.completed)p.push(b.completed+" completed");if(b.failed)p.push(b.failed+" failed");status.textContent=p.length?p.join(", ")+"." : "No download jobs yet.";log.textContent=compactLogs(b.logs||[]).join("\n");log.scrollTop=log.scrollHeight;if(b.running||b.queued)again=true}catch(e){status.textContent="Status unavailable: "+e.message;again=true}finally{if(again)setTimeout(showJobs,1000)}};const relativeCheckpoint=ms=>{const s=Math.max(0,Math.floor((Date.now()-Number(ms))/1000)),u=[[31536000,"year"],[2592000,"month"],[604800,"week"],[86400,"day"],[3600,"hour"],[60,"minute"]];if(s<60)return "just now";for(const[d,n]of u)if(s>=d){const x=Math.floor(s/d);return x+" "+n+(x===1?"":"s")+" ago"}},checkpointText=ms=>{if(!ms)return "";const d=new Intl.DateTimeFormat("en-US",{timeZone:"America/Los_Angeles",year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",second:"2-digit",hourCycle:"h23"}).format(new Date(Number(ms)));return "Checkpoint: "+d+" Pacific Time ("+relativeCheckpoint(ms)+")"};const key=x=>x.dataset.channelId+"|"+x.dataset.videoId+"|"+x.className,remember=()=>document.querySelectorAll("input.y1:checked,input.y2:checked").forEach(x=>saved.add(key(x))),setBusy=b=>document.querySelectorAll("button,input").forEach(x=>{if(x!==top)x.disabled=b});const apply=async u=>{if(!u||applied.has(u.channel))return;const r=await fetch(fragmentUrl(u.fragment),{cache:"no-store"});if(!r.ok)return;const text=await r.text(),old=[...document.querySelectorAll("section.channel")].find(x=>x.dataset.html3Channel===u.channel);applied.add(u.channel);if(!text){if(old)old.remove();return}remember();const t=document.createElement("template");t.innerHTML=text;const fresh=t.content.firstElementChild;if(old)old.replaceWith(fresh);else document.querySelector("main").insertBefore(fresh,document.querySelector("#channel-ids"));fresh.querySelectorAll("input.y1,input.y2").forEach(x=>{if(saved.has(key(x)))x.checked=true});fresh.querySelectorAll("button,input").forEach(x=>x.disabled=false)};const applyChannelIds=async()=>{const r=await fetch(channelsUrl,{cache:"no-store"});if(!r.ok)return;const t=document.createElement("template");t.innerHTML=await r.text();const fresh=t.content.firstElementChild,old=document.querySelector("#channel-ids");if(fresh&&old)old.replaceWith(fresh)};const poll=async()=>{try{const s=await (await fetch(stateUrl,{cache:"no-store"})).json(),bar=document.querySelector(".html3-progress-bar");bar.classList.toggle("loading",s.status==="running");if(s.status==="running")document.querySelector("#html3-progress-status").textContent=s.message||"Loading channels...";if(s.total){const partial=s.status==="running"?.5:0;bar.style.width=Math.min(100,100*((s.completed||0)+partial)/s.total)+"%";}for(const u of (Array.isArray(s.updates)?s.updates:(s.updates?[s.updates]:[])))await apply(u);if(s.status==="success"){await applyChannelIds();setBusy(false);document.querySelector("#html3-progress-status").textContent="";html3Failures=Array.isArray(s.failed_channels)?s.failed_channels:(s.failed_channels?[s.failed_channels]:[]);errors.textContent=html3FailureSummary();errorPanel.hidden=!html3Failures.length;return}if(s.status==="error"){status.textContent=s.error||"Page generation failed.";return}}catch(e){status.textContent="Progress unavailable: "+e.message}setTimeout(poll,500)};document.addEventListener("click",e=>{const b=e.target.closest("button[data-action]");if(!b)return;(b.closest(".channel")||document).querySelectorAll("input.y1,input.y2").forEach(x=>{if(b.dataset.action==="none")x.checked=false;else if(x.className===b.dataset.action)x.checked=true})});document.addEventListener("click",async e=>{const add=e.target.closest("#channel-add-button"),remove=e.target.closest(".channel-delete");if(!add&&!remove)return;const payload=add?{action:"add",channel:document.querySelector("#channel-add").value.trim()}:{action:"delete",channel:remove.dataset.channel};if(!payload.channel)return;const b=await (await fetch(api("channel"),{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)})).json();status.textContent=b.message||"Channel IDs updated.";if(b.message)setTimeout(()=>refresh(false),0)});document.querySelector("#download").onclick=async()=>{const items=[...document.querySelectorAll("input:checked")].map(x=>({target:x.className,url:x.dataset.url,path:x.dataset.path,channel_id:x.dataset.channelId,video_id:x.dataset.videoId}));if(!items.length){status.textContent="Select at least one video";return}status.textContent="Starting local downloads...";try{const b=await (await fetch(api("download"),{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({items})})).json();status.textContent=b.message||"Started";showJobs()}catch(e){status.textContent="Callback failed: "+e.message}};document.querySelector("#checkpoint").onclick=async()=>{const b=await (await fetch(api("checkpoint"),{method:"POST"})).json();status.textContent=b.message;document.querySelector("#checkpoint-value").textContent=b.checkpoint_ms?checkpointText(b.checkpoint_ms):""};const refresh=async all=>{remember();html3Failures=[];errors.textContent="";errorPanel.hidden=true;setBusy(true);const b=await (await fetch(api(all?"refresh-all":"refresh"),{method:"POST"})).json();status.textContent=b.message||"Refreshing";applied.clear();poll()};document.querySelector("#refresh").onclick=()=>refresh(false);document.querySelector("#refresh-all").onclick=()=>refresh(true);document.querySelector("#stop").onclick=async()=>{if(!window.confirm("Stop the local server? Active downloads will continue."))return;try{const b=await (await fetch(api("stop"),{method:"POST"})).json();status.textContent=b.message||"Server stopped"}catch(e){status.textContent="Server stopped"}window.close();setTimeout(()=>location.replace("about:blank"),150)};top.onclick=()=>window.scrollTo({top:0,behavior:"smooth"});const toggle=()=>top.classList.toggle("visible",scrollY>200);addEventListener("scroll",toggle,{passive:true});top.disabled=false;document.addEventListener("click",e=>{if(!errorPanel.hidden&&!errorPanel.contains(e.target))errorPanel.hidden=true});setInterval(()=>fetch(api("heartbeat"),{method:"POST",keepalive:true}),2000);showJobs();setBusy(true);poll()})()</script></body></html>
HTML3PAGE
  )
  page=${page//__TOKEN__/$token}
  page=${page//__MESSAGE__/$(html_escape "$message")}
  page=${page//__CHECKPOINT__/$(html_escape "$(format_html3_checkpoint_text "$(read_checkpoint_ms 2>/dev/null || print -r -- 0)")")}
  print -r -- "$page" >| "$tmp" || { printf 'Error: could not write %s\n' "$html3_file" >&2; return 1; }
  mv -f -- "$tmp" "$html3_file" || { printf 'Error: could not write %s\n' "$html3_file" >&2; return 1; }
  return 0
}

# Run this very script as the scanning worker. zsh needs no encoded-command
# dance: stdout and stderr are merged into one log the server tails.
typeset -g html3_worker_pid=0 html3_worker_lines=0

start_html3_worker() {
  local token=$1 refresh_all=${2:-0} log
  log=$(html3_worker_log "$token")
  # Reset the state before the child starts so a refresh cannot expose the
  # previous run's explicit success result during process startup.
  html3_progress_updates=()
  write_html3_progress "$(html3_progress_file "$token")" 0 0
  : >| "$log" 2>/dev/null || true
  html3_worker_lines=0
  if (( refresh_all )); then
    "$script_self" --html3-worker "$token" --refresh-all >"$log" 2>&1 &
  else
    "$script_self" --html3-worker "$token" >"$log" 2>&1 &
  fi
  html3_worker_pid=$!
  return 0
}

html3_worker_running() {
  (( html3_worker_pid > 0 )) || return 1
  kill -0 "$html3_worker_pid" 2>/dev/null
}

# Relay whatever the worker has printed since the last call, so the server
# console still shows the scan it delegated.
write_html3_worker_logs() {
  local token=$1 log total line i=0
  log=$(html3_worker_log "$token")
  [[ -f "$log" ]] || return 0
  total=$(wc -l < "$log" 2>/dev/null) || return 0
  total=${total// /}
  [[ "$total" == <-> ]] || return 0
  (( total > html3_worker_lines )) || return 0
  while IFS= read -r line; do
    (( ++i ))
    (( i > html3_worker_lines )) && print -r -- "$line"
  done < "$log"
  html3_worker_lines=$total
  return 0
}

# Build ./.tmp/yy.html from qualifying account-visible entries on each /videos tab.
# $1 is the callback base URL, $2 enables REFRESH ALL (scan even stale
# channels), $3 enables --html2's incremental cache. $4 and $5 switch on
# --html3: with a progress path set the main page is never written, and each
# channel is published as a fragment under $5 as soon as its scan settles.
# Leaves the number of channels that could not be scanned in $html_failure_count.
generate_html() {
  local callback_base=$1 refresh_all=${2:-0} incremental=${3:-0}
  local progress_path=${4:-} fragments_path=${5:-}
  local html3=0 completed_scans=0
  [[ -n "$progress_path" ]] && html3=1
  local exe checkpoint_ms checkpoint_sec checkpoint_day_start_sec scan_cutoff_sec checkpoint_age
  local failures=0 check_batch_ms restored=0 line channel channel_url resolved
  local index slot next_index completed row cards newest qualified
  # Loop scratch, declared once: a repeated bare `local name` prints the
  # variable instead of resetting it.
  local channel_cutoff last_full_ms last_full_sec candidate
  local result_dir tmp_page rc scan_out scan_rc
  local -a channels scan_cutoffs
  local -A seen_channels html_channel_ids skip_ytdlp observed_feed_newest last_full_scans downloaded_set
  html_failure_count=0
  if (( html3 )); then
    html3_failed_channels=()
    html3_progress_updates=()
  fi

  exe=$(ytdlp_path) || {
    printf 'Error: yt-dlp binary not found next to this script\n' >&2
    return 1
  }
  if [[ ! -f "$channels_file" ]]; then
    printf 'Error: %s does not exist\n' "$channels_file" >&2
    return 1
  fi
  if [[ ! -f "$cookies_file" ]]; then
    printf 'Error: %s does not exist; export YouTube cookies from a browser first\n' "$cookies_file" >&2
    return 1
  fi

  checkpoint_ms=$(read_checkpoint_ms) || return 1
  checkpoint_sec=$(( checkpoint_ms / 1000 ))
  checkpoint_day_start_sec=$(( checkpoint_sec - checkpoint_sec % 86400 ))
  scan_cutoff_sec=$(( checkpoint_day_start_sec - 86400 ))
  (( scan_cutoff_sec < 0 )) && scan_cutoff_sec=0
  checkpoint_age=$(format_relative_ms "$checkpoint_ms")
  check_batch_ms=$(now_ms)

  read_downloaded_videos >/dev/null
  local key
  for key in "${downloaded_keys[@]}"; do downloaded_set[$key]=1; done
  if (( incremental )); then
    read_html_video_cache
  else
    cache_channel_id=(); cache_checked_ms=(); cache_last_full_ms=()
    cache_feed_newest_ms=(); cache_entries=(); cache_channels=()
  fi

  printf 'Generating HTML from /videos tabs newer than checkpoint %s (%s)...\n' \
    "$checkpoint_ms" "$checkpoint_age"

  while IFS= read -r line || [[ -n "$line" ]]; do
    channel=$(trim "$line")
    [[ -n "$channel" && "$channel" != '#'* ]] || continue
    channel=${channel#@}
    (( ${+seen_channels[$channel]} )) && continue
    seen_channels[$channel]=1
    # In incremental mode a channel with no cache record is always scanned, so
    # a newly added handle cannot be skipped for being "stale".
    if ! { (( incremental )) && (( ! ${+cache_checked_ms[$channel]} )); }; then
      if ! should_scan_html_channel "$channel" "$refresh_all"; then
        printf 'Skipping @%s (latest video is 1.5 months old or older, or unknown)\n' "$channel"
        continue
      fi
    fi
    if [[ "$channel" =~ ^UC[A-Za-z0-9_-]+$ ]]; then
      html_channel_ids[$channel]=$channel
    else
      if ! resolve_channel_id "$channel" "$(channel_url_for "$channel")"; then
        (( ++failures ))
        (( html3 )) && html3_failed_channels+=("${channel}"$'\t'"could not resolve channel id")
        continue
      fi
      html_channel_ids[$channel]=$resolved_channel_id
    fi
    channel_cutoff=$scan_cutoff_sec
    last_full_ms=0
    last_full_sec=0
    if (( incremental )) && (( ${+cache_checked_ms[$channel]} )); then
      last_full_ms=${cache_last_full_ms[$channel]:-0}
      (( last_full_ms <= 0 )) && last_full_ms=${cache_checked_ms[$channel]:-0}
      last_full_scans[$channel]=$last_full_ms
      if (( last_full_ms > 0 )); then
        last_full_sec=$(( last_full_ms / 1000 ))
        candidate=$(( last_full_sec - last_full_sec % 86400 - 86400 ))
        (( candidate > channel_cutoff )) && channel_cutoff=$candidate
      fi
    fi
    channels+=("$channel")
    scan_cutoffs+=("$channel_cutoff")
  done < "$channels_file"

  # Incremental preflight: a cached channel whose public feed shows nothing
  # newer than what is already cached does not need a yt-dlp scan at all. A
  # full scan is still forced at least once every htmlFullScanInterval.
  if (( incremental )) && (( ${#channels} )); then
    local -A feed_candidates
    for index in {1..${#channels}}; do
      channel=${channels[$index]}
      (( ${+cache_checked_ms[$channel]} )) || continue
      last_full_ms=${last_full_scans[$channel]:-0}
      (( last_full_ms > 0 )) || continue
      (( check_batch_ms - last_full_ms < html_full_scan_interval_ms )) || continue
      feed_candidates[$channel]=${html_channel_ids[$channel]}
    done
    if (( ${#feed_candidates} )); then
      html_feed_newest_concurrent feed_candidates
      for channel in "${(@k)feed_candidates}"; do
        (( ${+html_feed_newest[$channel]} )) || continue
        local newest_feed_ms=${html_feed_newest[$channel]}
        observed_feed_newest[$channel]=$newest_feed_ms
        local known_newest_ms=$(( scan_cutoff_sec * 1000 ))
        local prior_feed_ms=${cache_feed_newest_ms[$channel]:-0}
        (( prior_feed_ms > known_newest_ms )) && known_newest_ms=$prior_feed_ms
        local -a entry_fields
        for row in ${(f)"${cache_entries[$channel]:-}"}; do
          [[ -n "$row" ]] || continue
          entry_fields=("${(@s:	:)row}")
          (( ${#entry_fields} >= 4 )) || continue
          [[ "${entry_fields[4]}" == <-> ]] || continue
          (( entry_fields[4] > known_newest_ms )) && known_newest_ms=${entry_fields[4]}
        done
        if (( newest_feed_ms <= known_newest_ms )); then
          skip_ytdlp[$channel]=1
          printf '@%s: public feed unchanged; reusing cached cards\n' "$channel"
        fi
      done
    fi
  fi

  # Scan pool. Each slot owns an ephemeral copy of the cookie jar so concurrent
  # yt-dlp processes never rewrite the same file; the copies are removed on the
  # way out, including on interruption.
  result_dir=$(mktemp -d "$temporary_directory/yy-html-scan.XXXXXX") || return 1
  local -a scan_cookie_files free_slots worker_pid worker_slot worker_index
  # Declared here, not inside the pool loop: a bare `local name` for a variable
  # that already exists in the same scope makes zsh *print* it (`w=0`).
  local w done_any=0
  local -a cleanup_paths
  for (( slot = 0; slot < MAX_THREADS; slot++ )); do
    cp -f -- "$cookies_file" "$temporary_directory/cookies${slot}.txt" 2>/dev/null || continue
    scan_cookie_files+=("$temporary_directory/cookies${slot}.txt")
    free_slots+=("$slot")
  done
  html_scan_cleanup() {
    local p
    for p in "${scan_cookie_files[@]}"; do rm -f -- "$p" 2>/dev/null || true; done
    rm -rf -- "$result_dir" 2>/dev/null || true
  }
  trap 'html_scan_cleanup' EXIT INT TERM

  next_index=1
  (( html3 )) && write_html3_progress "$progress_path" 0 ${#channels}
  while (( next_index <= ${#channels} || ${#worker_pid} > 0 )); do
    while (( next_index <= ${#channels} && ${#free_slots} > 0 )); do
      channel=${channels[$next_index]}
      if (( ${+skip_ytdlp[$channel]} )); then
        print -rn -- "" >| "$result_dir/$next_index.out"
        print -r -- 0 >| "$result_dir/$next_index.status"
        print -r -- 1 >| "$result_dir/$next_index.feedonly"
        if (( html3 )); then
          html3_emit_fragment "$next_index" "$channel" "" "$fragments_path" "$scan_cutoff_sec"
          (( ++completed_scans ))
          write_html3_progress "$progress_path" "$completed_scans" ${#channels}
        fi
        (( ++next_index ))
        continue
      fi
      slot=${free_slots[1]}
      free_slots=("${free_slots[@]:1}")
      printf 'Checking @%s...\n' "$channel"
      html_scan_channel "$next_index" "$channel" "$(channel_url_for "$channel")" "$exe" \
        "${scan_cutoffs[$next_index]}" "$result_dir" "./cookies${slot}.txt" &
      worker_pid+=($!)
      worker_slot+=("$slot")
      worker_index+=("$next_index")
      (( ++next_index ))
    done
    if (( ${#worker_pid} > 0 )); then
      done_any=0
      while (( ! done_any )); do
        for (( w = ${#worker_pid}; w >= 1; w-- )); do
          if ! kill -0 "${worker_pid[$w]}" 2>/dev/null; then
            wait "${worker_pid[$w]}" 2>/dev/null || true
            if (( html3 )); then
              local reaped_index=${worker_index[$w]} reaped_out=""
              [[ -f "$result_dir/$reaped_index.out" ]] && reaped_out=$(<"$result_dir/$reaped_index.out")
              html3_emit_fragment "$reaped_index" "${channels[$reaped_index]}" "$reaped_out" \
                "$fragments_path" "$scan_cutoff_sec"
              (( ++completed_scans ))
            fi
            free_slots+=("${worker_slot[$w]}")
            worker_pid[$w]=()
            worker_slot[$w]=()
            worker_index[$w]=()
            done_any=1
          fi
        done
        (( done_any )) || sleep 1
      done
      (( html3 )) && write_html3_progress "$progress_path" "$completed_scans" ${#channels}
    fi
  done

  # Render. Approximate tab dates can precede the exact publication time, so
  # the scan starts at midnight UTC on the day before the checkpoint date and
  # keeps the overlap rather than resolving watch pages: coverage over
  # precision.
  local -a page_sections
  # Per-channel scratch, declared once: repeating `local -A merged_row` inside
  # the loop does NOT reset it in zsh, so every channel inherited the previous
  # channels' rows and kept_rows re-appended them, duplicating cards.
  local -A merged_row
  local -a merged_ids fields kept_rows
  for index in {1..${#channels}}; do
    merged_row=()
    merged_ids=()
    kept_rows=()
    channel=${channels[$index]}
    scan_out=""
    [[ -f "$result_dir/$index.out" ]] && scan_out=$(<"$result_dir/$index.out")
    scan_rc=1
    [[ -f "$result_dir/$index.status" ]] && scan_rc=$(<"$result_dir/$index.status")
    local feed_only=0
    [[ -f "$result_dir/$index.feedonly" ]] && feed_only=1
    local scan_ok=0
    [[ "$scan_rc" == 0 || "$scan_rc" == 101 ]] && scan_ok=1
    local full_scan_ok=$(( scan_ok && ! feed_only ))

    if (( incremental )); then
      for row in ${(f)"${cache_entries[$channel]:-}"}; do
        [[ -n "$row" ]] || continue
        fields=("${(@s:	:)row}")
        [[ -n "${fields[1]:-}" ]] || continue
        (( ${+merged_row[${fields[1]}]} )) || merged_ids+=("${fields[1]}")
        merged_row[${fields[1]}]=$row
      done
      if (( scan_ok )); then
        for row in ${(f)scan_out}; do
          [[ "$row" == scan:* ]] || continue
          fields=("${(@s:	:)row}")
          (( ${#fields} >= 5 )) || continue
          [[ "${fields[4]}" == <-> ]] || continue
          local entry_ms=${fields[4]}
          (( entry_ms < 100000000000 )) && (( entry_ms *= 1000 ))
          local entry_id=${fields[1]#scan:}
          [[ -n "$entry_id" ]] || continue
          (( ${+merged_row[$entry_id]} )) || merged_ids+=("$entry_id")
          merged_row[$entry_id]="${entry_id}"$'\t'"${fields[2]}"$'\t'"$(sanitize_field "${fields[3]}")"$'\t'"${entry_ms}"$'\t'"${fields[5]}"
        done
      else
        printf 'Warning: could not incrementally scan the videos tab for @%s; using cached entries\n' "$channel" >&2
        (( ++failures ))
        (( html3 )) && html3_failed_channels+=("${channel}"$'\t'"could not scan videos tab; using cached entries")
      fi
      local cache_checked=0 cache_full=0 cache_feed=0
      if (( scan_ok )); then cache_checked=$check_batch_ms
      else cache_checked=${cache_checked_ms[$channel]:-0}; fi
      if (( full_scan_ok )); then cache_full=$check_batch_ms
      else cache_full=${last_full_scans[$channel]:-0}; fi
      if (( scan_ok )) && (( ${+observed_feed_newest[$channel]} )); then
        cache_feed=${observed_feed_newest[$channel]}
      else
        cache_feed=${cache_feed_newest_ms[$channel]:-0}
      fi
      local kept="" keep_cutoff_ms=$(( scan_cutoff_sec * 1000 ))
      for key in "${merged_ids[@]}"; do
        row=${merged_row[$key]}
        fields=("${(@s:	:)row}")
        [[ "${fields[4]:-}" == <-> ]] || continue
        (( fields[4] >= keep_cutoff_ms )) || continue
        kept_rows+=("${fields[4]}"$'\t'"$row")
      done
      cache_touch_channel "$channel"
      cache_channel_id[$channel]=${html_channel_ids[$channel]}
      cache_checked_ms[$channel]=$cache_checked
      cache_last_full_ms[$channel]=$cache_full
      cache_feed_newest_ms[$channel]=$cache_feed
      cache_entries[$channel]=""
      scan_out=""
      for row in ${(f)"$(printf '%s\n' "${kept_rows[@]}" | LC_ALL=C sort -t $'\t' -k1,1nr)"}; do
        [[ -n "$row" ]] || continue
        row=${row#*$'\t'}
        cache_entries[$channel]+="${row}"$'\n'
        scan_out+="scan:${row}"$'\n'
      done
      scan_rc=0
      scan_ok=1
    fi

    if (( ! scan_ok )); then
      printf 'Warning: could not scan the videos tab for @%s\n' "$channel" >&2
      (( ++failures ))
      (( html3 )) && html3_failed_channels+=("${channel}"$'\t'"could not scan videos tab")
      continue
    fi

    cards=""
    newest=0
    qualified=0
    local channel_id=${html_channel_ids[$channel]}
    local download_path="./${channel}"
    for row in ${(f)scan_out}; do
      [[ "$row" == scan:* ]] || continue
      local -a parts
      parts=("${(@s:	:)row}")
      (( ${#parts} >= 5 )) || continue
      case "${parts[5]}" in
        subscriber_only|private|premium_only) continue ;;
      esac
      [[ "${parts[4]}" == <-> ]] || continue
      local video_ms=${parts[4]}
      (( video_ms < 100000000000 )) && (( video_ms *= 1000 ))
      (( video_ms > newest )) && newest=$video_ms
      local vid=${parts[1]#scan:} vurl=${parts[2]} vtitle=${parts[3]}
      [[ -n "$vid" && -n "$vurl" ]] || continue
      local thumb="https://i.ytimg.com/vi/${vid}/hqdefault.jpg"
      local age=$(format_relative_ms "$video_ms")
      local checked_y1="" checked_y2=""
      # zsh does not expand $'\t' inside an array subscript, so build the key first.
      local dl_key_y1="${channel_id}${tab_char}${vid}${tab_char}y1"
      local dl_key_y2="${channel_id}${tab_char}${vid}${tab_char}y2"
      if (( ${+downloaded_set[$dl_key_y1]} )); then
        checked_y1=" checked"; (( ++restored ))
      fi
      if (( ${+downloaded_set[$dl_key_y2]} )); then
        checked_y2=" checked"; (( ++restored ))
      fi
      cards+='<article class="card"><a class="video-link" href="'$(html_escape "$vurl")'" target="_blank" rel="noopener noreferrer"><div class="preview"><img src="'$(html_escape "$thumb")'" alt=""></div><div class="video-title">'$(html_escape "$vtitle")'</div></a><div class="video-age">'$(html_escape "$age")'</div><div class="checks"><label><input class="y1" data-url="'$(html_escape "$vurl")'" data-path="'$(html_escape "$download_path")'" data-channel-id="'$(html_escape "$channel_id")'" data-video-id="'$(html_escape "$vid")'" type="checkbox"'"$checked_y1"'> y1</label><label><input class="y2" data-url="'$(html_escape "$vurl")'" data-path="'$(html_escape "$download_path")'" data-channel-id="'$(html_escape "$channel_id")'" data-video-id="'$(html_escape "$vid")'" type="checkbox"'"$checked_y2"'> y2</label></div></article>'$'\n'
      (( ++qualified ))
    done
    printf '@%s: %s visible video(s) in the checkpoint overlap\n' "$channel" "$qualified"
    record_channel_check "$channel" "$newest" "$check_batch_ms" 1
    if [[ -n "$cards" ]]; then
      page_sections+=('<section class="channel"><div class="channel-title"><h2><a href="'$(html_escape "$(channel_url_for "$channel")")'" target="_blank" rel="noopener noreferrer">'$(html_escape "$channel")'</a></h2><div class="controls"><button data-action="y1" type="button">y1</button><button data-action="y2" type="button">y2</button><button data-action="none" type="button">none</button></div></div><div class="grid">'$'\n'"$cards"'</div></section>')
    fi
  done

  html_scan_cleanup
  trap - EXIT INT TERM
  (( incremental )) && save_html_video_cache

  # Channel IDs table, sorted by most recently checked then newest video.
  local -a managed_keys managed_display
  local -a missing_avatars
  while IFS= read -r line || [[ -n "$line" ]]; do
    channel=$(trim "$line")
    [[ -n "$channel" && "$channel" != '#'* ]] || continue
    key=${channel#@}
    status_touch_channel "$key"
    managed_keys+=("$key")
    managed_display+=("$channel")
    [[ -z "${status_thumbnail[$key]}" ]] && missing_avatars+=("$key")
  done < "$channels_file"
  if (( ${#missing_avatars} )); then
    channel_thumbnails_concurrent "${missing_avatars[@]}"
    for key in "${missing_avatars[@]}"; do
      (( ${+channel_thumbnails[$key]} )) && status_thumbnail[$key]=${channel_thumbnails[$key]}
    done
  fi
  local -a table_rows sortable
  local -A html3_failed_keys
  if (( html3 )); then
    for row in "${html3_failed_channels[@]}"; do
      local failed_key=${row%%$'\t'*}
      failed_key=${failed_key#@}
      [[ -n "$failed_key" ]] && html3_failed_keys[$failed_key]=1
    done
  fi
  for index in {1..${#managed_keys}}; do
    key=${managed_keys[$index]}
    sortable+=("${status_checked_ms[$key]:-0}"$'\t'"${status_latest_video_ms[$key]:-0}"$'\t'"$index")
  done
  local table_body=""
  for row in ${(f)"$(printf '%s\n' "${sortable[@]}" | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2nr)"}; do
    [[ -n "$row" ]] || continue
    index=${row##*$'\t'}
    key=${managed_keys[$index]}
    local checked_text='never' latest_text='unknown' avatar='' row_class=''
    (( ${+html3_failed_keys[$key]} )) && row_class=' class="html3-channel-error"'
    (( ${status_checked_ms[$key]:-0} > 0 )) && checked_text=$(format_relative_ms "${status_checked_ms[$key]}")
    (( ${status_latest_video_ms[$key]:-0} > 0 )) && latest_text=$(format_relative_ms "${status_latest_video_ms[$key]}")
    if [[ -n "${status_thumbnail[$key]}" ]]; then
      avatar='<img src="'$(html_escape "${status_thumbnail[$key]}")'" alt="" width="42" height="42" style="border-radius:50%;object-fit:cover">'
    fi
    table_body+='<tr'"$row_class"'><td>'"$avatar"'</td><td><a href="'$(html_escape "$(channel_url_for "$key")")'" target="_blank" rel="noopener noreferrer">'$(html_escape "${managed_display[$index]}")'</a></td><td>'$(html_escape "$checked_text")'</td><td>'$(html_escape "$latest_text")'</td><td><button class="channel-delete" data-channel="'$(html_escape "${managed_display[$index]}")'" type="button">delete</button></td></tr>'$'\n'
  done
  save_channel_check_status

  local channel_ids_html=''
  channel_ids_html='<section id="channel-ids" class="channel"><div class="channel-bar"></div><div class="channel-title"><h2>Channel IDs</h2></div><div class="controls"><input id="channel-add" placeholder="@channel or UC channel id"><button id="channel-add-button" type="button">add</button></div><table class="channel-table"><thead><tr><th>Profile</th><th>Channel</th><th>Last checked</th><th>Latest video</th><th></th></tr></thead><tbody>'$'\n'"$table_body"'</tbody></table></section>'
  if (( html3 )); then
    print -r -- "$channel_ids_html" >| "$fragments_path/channels.html" 2>/dev/null || true
    html_failure_count=$failures
    printf 'Restored %s downloaded target selection(s) in HTML.\n' "$restored"
    return 0
  fi

  tmp_page="$temporary_directory/yy.html.new.$$"
  {
    print -r -- '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>YouTube Video Download</title>'
    print -r -- "$html_page_css"
    print -r -- '<h1>YouTube Video Download</h1><p>Select y1 and/or y2, then click DOWNLOAD SELECTED to run the matching local yy hook. <span id="checkpoint-value">Checkpoint: '"$checkpoint_ms"'</span></p><div class="controls"><button id="download" type="button">DOWNLOAD SELECTED</button><button id="checkpoint" type="button">CHECKPOINT</button><button id="refresh" type="button">REFRESH</button><button id="refresh-all" type="button">REFRESH ALL</button><button id="stop" type="button">STOP SERVER</button><button data-action="y1" type="button">y1</button><button data-action="y2" type="button">y2</button><button data-action="none" type="button">none</button></div><p id="status"></p><pre id="job-log" class="job-log"></pre><main>'
    (( ${#page_sections} )) && print -r -- "${(j:
:)page_sections}"
    print -r -- "$channel_ids_html"
    print -rn -- '<button id="back-to-top" class="back-to-top" type="button" onclick="window.scrollTo({top:0,behavior:'"'"'smooth'"'"'})" aria-label="Back to top" title="Back to top">&uarr;</button>'
    html_page_script "$callback_base"
    print -r -- '</main></body></html>'
  } >| "$tmp_page" || { printf 'Error: could not write %s\n' "$html_file" >&2; return 1; }
  mv -f -- "$tmp_page" "$html_file" || { printf 'Error: could not write %s\n' "$html_file" >&2; return 1; }

  html_failure_count=$failures
  printf 'Restored %s downloaded target selection(s) in HTML.\n' "$restored"
  printf 'Generated %s\n' "$html_file"
  return 0
}

# ---------------------------------------------------------------------------
# The local callback server
#
# The browser submits structured selections to this one-shot, loopback-only
# listener. It never accepts shell text: each item must name y1/y2 and a
# YouTube URL before the corresponding local yy hook is started.
# ---------------------------------------------------------------------------

# Count bytes, not characters: HTTP Content-Length is a byte count and a single
# non-ASCII title would otherwise truncate the response.
byte_length() {
  emulate -L zsh
  unsetopt multibyte
  print -r -- ${#1}
}

http_send() {
  local fd=$1 code=$2 status_text=$3 content_type=$4 body=$5 extra=${6:-}
  local length
  length=$(byte_length "$body")
  {
    printf '%s\r\n' "HTTP/1.1 ${code} ${status_text}"
    printf '%s\r\n' "Content-Type: ${content_type}"
    printf '%s\r\n' "Content-Length: ${length}"
    printf '%s\r\n' "Access-Control-Allow-Origin: *"
    printf '%s\r\n' "Access-Control-Allow-Methods: POST, OPTIONS"
    printf '%s\r\n' "Access-Control-Allow-Headers: Content-Type"
    printf '%s\r\n' "Connection: close"
    [[ -n "$extra" ]] && printf '%s\r\n' "$extra"
    printf '\r\n'
    printf '%s' "$body"
  } >&$fd 2>/dev/null || true
}

http_send_json() {
  http_send "$1" "$2" "$3" 'application/json; charset=utf-8' "$4"
}

http_send_message() {
  http_send_json "$1" "$2" "$3" "{\"message\": \"$(json_escape "$4")\"}"
}

http_send_file() {
  local fd=$1 file=$2 length
  if [[ ! -f "$file" ]]; then
    http_send_message "$fd" 404 'Not Found' 'Page not generated yet.'
    return 0
  fi
  length=$(wc -c < "$file" | tr -d ' ')
  {
    printf '%s\r\n' "HTTP/1.1 200 OK"
    printf '%s\r\n' "Content-Type: text/html; charset=utf-8"
    printf '%s\r\n' "Content-Length: ${length}"
    printf '%s\r\n\r\n' "Connection: close"
    cat -- "$file"
  } >&$fd 2>/dev/null || true
}

# Read one request from $1. Leaves the method in $req_method, the path in
# $req_path and any body in $req_body. Returns non-zero on a malformed or
# abandoned request, which the caller simply drops.
req_method=""; req_path=""; req_body=""
http_read_request() {
  local fd=$1 line content_length=0 chunk count
  req_method=""; req_path=""; req_body=""
  read -r -t 10 -u "$fd" line || return 1
  line=${line%$'\r'}
  req_method=${line%% *}
  req_path=${${line#* }%% *}
  while read -r -t 10 -u "$fd" line; do
    line=${line%$'\r'}
    [[ -n "$line" ]] || break
    if [[ "${(L)line}" == content-length:* ]]; then
      content_length=${${line#*:}// /}
      [[ "$content_length" == <-> ]] || content_length=0
    fi
  done
  (( content_length > 0 )) || return 0
  {
    emulate -L zsh
    unsetopt multibyte
    local remaining=$content_length
    while (( remaining > 0 )); do
      sysread -c count -i "$fd" -s "$remaining" -t 10 chunk || break
      (( count > 0 )) || break
      req_body+=$chunk
      (( remaining -= count ))
    done
  }
  return 0
}

# Accept only structured selections; never a path or URL the page could have
# been tricked into inventing.
validate_video_selection() {
  local target=$1 url=$2 target_dir=$3 channel_id=$4 video_id=$5 host
  [[ "$target" == y1 || "$target" == y2 ]] || return 1
  [[ "$channel_id" =~ ^UC[A-Za-z0-9_-]+$ ]] || return 1
  [[ "$video_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  [[ "$target_dir" =~ '^\./[^\\/:*?"<>|]+$' ]] || return 1
  [[ "$target_dir" != ./. && "$target_dir" != ./.. ]] || return 1
  [[ "$url" == http://* || "$url" == https://* ]] || return 1
  host=${${url#*://}%%[/?#]*}
  host=${host##*@}
  host=${host%%:*}
  [[ "$host" == youtu.be || "$host" == youtube.com || "$host" == *.youtube.com ]]
}

# Job table. Parallel arrays keyed by a monotonically increasing job number.
typeset -gA job_target job_url job_path job_channel job_video job_hook
typeset -gA job_state job_pid job_log job_rcfile job_lines job_succeeded
typeset -gA job_persisted job_last_pct job_last_bucket
typeset -ga job_ids server_logs
typeset -g job_status_json=""
typeset -gi job_active_count=0
job_counter=0

# Queue the selections from a /download payload. y2 drains before y1, keeping
# the page's order within each destination; only the scheduler starts anything.
start_selected_video_hooks() {
  local body=$1 jpath value idx field started=0 pass
  local -a parts order
  local -A sel_target sel_url sel_path sel_channel sel_video seen
  hook_error=""
  while IFS=$'\t' read -r jpath value; do
    parts=(${(ps:\x01:)jpath})
    (( ${#parts} == 3 )) || continue
    [[ "${(g::)parts[1]}" == items ]] || continue
    idx=${(g::)parts[2]}
    field=${(g::)parts[3]}
    value=${(g::)value}
    if (( ! ${+seen[$idx]} )); then
      seen[$idx]=1
      order+=("$idx")
      sel_target[$idx]=""; sel_url[$idx]=""; sel_path[$idx]=""
      sel_channel[$idx]=""; sel_video[$idx]=""
    fi
    case "$field" in
      target) sel_target[$idx]=$value ;;
      url) sel_url[$idx]=$value ;;
      path) sel_path[$idx]=$value ;;
      channel_id) sel_channel[$idx]=$value ;;
      video_id) sel_video[$idx]=$value ;;
    esac
  done < <(json_flatten_string "$body")
  if (( ${#order} == 0 )); then
    hook_error='No video selections received'
    return 1
  fi
  read_downloaded_videos >/dev/null
  local -A downloaded_set
  local key hook hook_name
  for key in "${downloaded_keys[@]}"; do downloaded_set[$key]=1; done
  for pass in y2 y1; do
    for idx in "${order[@]}"; do
      [[ "${sel_target[$idx]}" == "$pass" ]] || continue
      if ! validate_video_selection "${sel_target[$idx]}" "${sel_url[$idx]}" \
           "${sel_path[$idx]}" "${sel_channel[$idx]}" "${sel_video[$idx]}"; then
        hook_error='Invalid video selection received'
        return 1
      fi
      key="${sel_channel[$idx]}"$'\t'"${sel_video[$idx]}"$'\t'"${sel_target[$idx]}"
      if (( ${+downloaded_set[$key]} )); then
        printf 'Skipped previously downloaded selection: %s / %s / %s\n' \
          "${sel_channel[$idx]}" "${sel_video[$idx]}" "${sel_target[$idx]}"
        continue
      fi
      # y1 and y2 run the local yy1/yy2 hooks found on PATH, matching yy.ps1's
      # yy1.ps1/yy2.ps1 lookup. The hooks are what make the two labels mean
      # different destinations; point them at this wrapper to get identical
      # behaviour. Aliases and shell functions are deliberately not accepted:
      # this script is not interactive and never sources a shell rc, so a hook
      # has to be a real executable on PATH.
      hook_name="y${sel_target[$idx]}"
      hook=${commands[$hook_name]}
      if [[ -z "$hook" || ! -x "$hook" ]]; then
        hook_error="Local ${hook_name} hook was not found on PATH"
        return 1
      fi
      (( ++job_counter ))
      local id=$job_counter
      job_ids+=("$id")
      job_target[$id]=${sel_target[$idx]}
      job_url[$id]=${sel_url[$idx]}
      job_path[$id]=${sel_path[$idx]}
      job_channel[$id]=${sel_channel[$idx]}
      job_video[$id]=${sel_video[$idx]}
      job_hook[$id]=$hook
      job_state[$id]=queued
      job_pid[$id]=0
      job_log[$id]=""
      job_rcfile[$id]=""
      job_lines[$id]=0
      job_succeeded[$id]=0
      job_persisted[$id]=0
      job_last_pct[$id]=-1
      job_last_bucket[$id]=-1
      printf 'Queued: %s -p %s -t %s\n' "$hook" "${sel_path[$idx]}" "${sel_url[$idx]}"
      (( ++started ))
    done
  done
  hook_started=$started
  return 0
}

start_next_download_job() {
  local id base
  for id in "${job_ids[@]}"; do
    [[ "${job_state[$id]}" == queued ]] || continue
    base=$(mktemp "$temporary_directory/yy-html-job.XXXXXX") || return 1
    job_log[$id]="${base}.out"
    job_rcfile[$id]="${base}.rc"
    rm -f -- "$base"
    : >| "${job_log[$id]}"
    printf 'Running: %s -p %s -t %s\n' "${job_hook[$id]}" "${job_path[$id]}" "${job_url[$id]}"
    {
      "${job_hook[$id]}" -p "${job_path[$id]}" -t "${job_url[$id]}" >> "${job_log[$id]}" 2>&1
      print -r -- $? >| "${job_rcfile[$id]}"
    } &
    job_pid[$id]=$!
    job_state[$id]=running
    return 0
  done
  return 1
}

# yt-dlp emits a progress line per chunk. Keep one line per 10% so the page log
# stays readable; a second format (normally audio after video) restarts at zero
# and gets its own buckets.
should_emit_download_log() {
  local id=$1 line=$2 percent bucket
  [[ "$line" =~ '^\[download\][ ]+([0-9]+(\.[0-9]+)?)%' ]] || return 0
  percent=${match[1]}
  local pct_int=${percent%%.*}
  if (( job_last_pct[$id] >= 0 )) && (( pct_int < job_last_pct[$id] - 1 )); then
    job_last_bucket[$id]=-1
  fi
  bucket=$(( pct_int / download_progress_step_percent ))
  job_last_pct[$id]=$pct_int
  if (( bucket > job_last_bucket[$id] || pct_int >= 100 )); then
    job_last_bucket[$id]=$bucket
    return 0
  fi
  return 1
}

# Drain job logs, reap finished jobs, start the next queued one and publish the
# status JSON the page polls for in $job_status_json. This must NOT be called in
# a command substitution: the subshell would discard every job state change and
# the same job would be launched again on the next poll.
get_download_job_status() {
  local id running=0 queued=0 completed=0 failed=0 line rc entry
  local -a new_lines
  for id in "${job_ids[@]}"; do
    if [[ -n "${job_log[$id]}" && -f "${job_log[$id]}" ]]; then
      # yt-dlp rewrites the progress line with CR, so split on it too.
      new_lines=(${(f)"$(tr '\r' '\n' < "${job_log[$id]}" | sed -n "$(( job_lines[$id] + 1 )),\$p")"})
      # A command substitution with no output still yields one empty element.
      (( ${#new_lines} == 1 )) && [[ -z "${new_lines[1]}" ]] && new_lines=()
      if (( ${#new_lines} )); then
        (( job_lines[$id] += ${#new_lines} ))
        for line in "${new_lines[@]}"; do
          line=$(strip_control_chars "$line")
          [[ -n "$line" ]] || continue
          [[ "$line" == '[download]'*'has already been downloaded'* || "$line" == '[download]'*'100%'* ]] \
            && job_succeeded[$id]=1
          should_emit_download_log "$id" "$line" || continue
          entry="[${job_target[$id]}] ${line}"
          print -r -- "$entry"
          server_logs+=("$entry")
        done
        (( ${#server_logs} > 400 )) && server_logs=("${(@)server_logs[-400,-1]}")
      fi
    fi
    if [[ "${job_state[$id]}" == running ]]; then
      if [[ -n "${job_rcfile[$id]}" && -f "${job_rcfile[$id]}" ]]; then
        rc=$(<"${job_rcfile[$id]}")
        [[ "$rc" == <-> ]] || rc=1
        wait "${job_pid[$id]}" 2>/dev/null || true
        if (( rc == 0 || job_succeeded[$id] )); then
          job_state[$id]=completed
          if (( ! job_persisted[$id] )); then
            add_downloaded_video "${job_channel[$id]}" "${job_video[$id]}" "${job_target[$id]}"
            job_persisted[$id]=1
          fi
        else
          job_state[$id]=failed
        fi
        rm -f -- "${job_rcfile[$id]}" "${job_log[$id]}" 2>/dev/null || true
        job_log[$id]=""
      fi
    fi
    case "${job_state[$id]}" in
      running) (( ++running )) ;;
      queued) (( ++queued )) ;;
      completed) (( ++completed )) ;;
      *) (( ++failed )) ;;
    esac
  done
  if (( running == 0 && queued > 0 )); then
    if start_next_download_job; then
      running=1
      (( --queued ))
    fi
  fi
  local logs_json="" first=1
  local -a recent_logs=()
  # A negative range start beyond the array length collapses to one empty
  # element in zsh, so clamp it instead of slicing blindly.
  if (( ${#server_logs} > 80 )); then
    recent_logs=("${(@)server_logs[-80,-1]}")
  else
    recent_logs=("${server_logs[@]}")
  fi
  for line in "${recent_logs[@]}"; do
    (( first )) || logs_json+=', '
    first=0
    logs_json+="\"$(json_escape "$line")\""
  done
  job_status_json="{\"running\": $running, \"queued\": $queued, \"completed\": $completed, \"failed\": $failed, \"logs\": [${logs_json}]}"
  job_active_count=$(( running + queued ))
}

# Apply an add/delete from the Channel IDs table.
apply_channel_change() {
  local body=$1 action="" channel="" jpath value tmp line found=0
  while IFS=$'\t' read -r jpath value; do
    case "${(g::)jpath}" in
      action) action=${(g::)value} ;;
      channel) channel=$(trim "${(g::)value}") ;;
    esac
  done < <(json_flatten_string "$body")
  if [[ -z "$channel" || "$channel" == *[$'\r\n#']* ]]; then
    channel_change_error='Invalid channel id.'
    return 1
  fi
  tmp="$temporary_directory/channel-ids.txt.new.$$"
  : >| "$tmp" || { channel_change_error='Could not update channel-ids.txt.'; return 1; }
  if [[ -f "$channels_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$(trim "$line")" == "$channel" ]]; then
        found=1
        [[ "$action" == delete ]] && continue
      fi
      print -r -- "$line" >> "$tmp"
    done < "$channels_file"
  fi
  case "$action" in
    delete) ;;
    add) (( found )) || print -r -- "$channel" >> "$tmp" ;;
    *) rm -f -- "$tmp"; channel_change_error='Invalid channel action.'; return 1 ;;
  esac
  mv -f -- "$tmp" "$channels_file" || {
    rm -f -- "$tmp"
    channel_change_error='Could not update channel-ids.txt.'
    return 1
  }
  return 0
}

# Serve the generated page and its callbacks until STOP SERVER, Ctrl-C, or the
# page stops sending heartbeats.
invoke_html_callback_server() {
  local callback_base=$1 incremental=${2:-0} html3=${3:-0}
  local listen_fd conn_fd last_heartbeat now stop=0 refresh_all
  # Declared here, not in the request switch: a bare `local name` for a
  # variable that already exists in the same scope makes zsh *print* it.
  local state_file=""
  local page_file=$html_file
  (( html3 )) && page_file=$html3_file
  # A browser that abandons a status or heartbeat request would otherwise
  # SIGPIPE this script mid-write.
  trap '' PIPE
  # zsh's ztcp does not set SO_REUSEADDR, so a listener restarted within the
  # TIME_WAIT window fails; retry briefly before giving up.
  local bind_try=0
  while true; do
    ztcp -l "$html_listen_port" 2>/dev/null && break
    (( ++bind_try ))
    if (( bind_try >= 5 )); then
      printf 'Error: http://%s:%s is unavailable\n' "$html_listen_host" "$html_listen_port" >&2
      return 1
    fi
    sleep 1
  done
  listen_fd=$REPLY
  html_server_stop=0
  trap 'html_server_stop=1' INT TERM
  last_heartbeat=$(now_sec)
  if (( html3 )); then
    start_html3_worker "$html_token" 0
    open_html3_url "http://${html_listen_host}:${html_listen_port}/" "$html3_incognito" || true
  else
    open_url "http://${html_listen_host}:${html_listen_port}/" || true
  fi
  printf 'Waiting for DOWNLOAD SELECTED on http://%s:%s/ (Ctrl+C or STOP SERVER exits)\n' \
    "$html_listen_host" "$html_listen_port"
  while (( ! html_server_stop && ! stop )); do
    if ! zselect -t 100 -r "$listen_fd" 2>/dev/null; then
      # Keep queued jobs moving even while the page is idle. This also
      # refreshes $job_active_count for the timeout test below.
      get_download_job_status
      (( html3 )) && write_html3_worker_logs "$html_token"
      now=$(now_sec)
      # Never abandon a download that is still running or queued just because
      # the browser throttled its timers while the tab was in the background.
      if (( now - last_heartbeat >= html_heartbeat_timeout_sec && job_active_count == 0 )); then
        printf 'HTML page closed or disconnected; stopping server.\n'
        break
      fi
      continue
    fi
    ztcp -a "$listen_fd" 2>/dev/null || continue
    conn_fd=$REPLY
    # Any request proves the page is alive. In particular, count status polling
    # because browsers may throttle the dedicated heartbeat timer when this tab
    # is in the background.
    last_heartbeat=$(now_sec)
    if ! http_read_request "$conn_fd"; then
      ztcp -c "$conn_fd" 2>/dev/null || true
      continue
    fi
    req_path=${req_path%%\?*}
    case "${req_method} ${req_path}" in
      "GET /")
        http_send_file "$conn_fd" "$page_file"
        ;;
      "GET /html3/${html_token}/state")
        write_html3_worker_logs "$html_token"
        state_file=$(html3_progress_file "$html_token")
        if [[ -f "$state_file" ]]; then
          http_send "$conn_fd" 200 OK 'application/json' "$(<"$state_file")"
        else
          http_send_json "$conn_fd" 200 OK \
            '{"status":"running","success":false,"message":"Loading channels...","completed":0,"total":0,"updates":[]}'
        fi
        ;;
      "GET /html3/${html_token}/channels")
        http_send_file "$conn_fd" "$(html3_fragments_dir "$html_token")/channels.html"
        ;;
      "GET /html3/${html_token}/fragment/"<->)
        http_send_file "$conn_fd" "$(html3_fragments_dir "$html_token")/${req_path##*/}.html"
        ;;
      "GET /status/${html_token}")
        get_download_job_status
        http_send_json "$conn_fd" 200 OK "$job_status_json"
        ;;
      "OPTIONS /download/${html_token}"|"OPTIONS /stop/${html_token}")
        http_send "$conn_fd" 204 'No Content' 'text/plain' ''
        ;;
      "POST /heartbeat/${html_token}")
        http_send_message "$conn_fd" 200 OK ''
        ;;
      "POST /stop/${html_token}")
        http_send_message "$conn_fd" 200 OK 'Server stopped.'
        stop=1
        ;;
      "POST /checkpoint/${html_token}")
        local checkpoint_ms=$(now_ms)
        set_checkpoint_at "$checkpoint_ms"
        http_send_json "$conn_fd" 200 OK \
          "{\"message\": \"Checkpoint updated.\", \"checkpoint_ms\": ${checkpoint_ms}}"
        ;;
      "POST /refresh/${html_token}"|"POST /refresh-all/${html_token}")
        refresh_all=0
        [[ "$req_path" == "/refresh-all/${html_token}" ]] && refresh_all=1
        if (( refresh_all )); then
          printf 'Refreshing HTML page from all channels in channel-ids.txt...\n'
        else
          printf 'Refreshing HTML page from recent channels in channel-ids.txt...\n'
        fi
        if (( html3 )); then
          # --html3 scans in a worker process, so the refresh is asynchronous:
          # reply immediately and let the page resume polling /state.
          if html3_worker_running; then
            http_send_message "$conn_fd" 409 Conflict 'A page update is already running.'
          else
            write_html3_loading_page "$html_token" 'Loading channels...' \
              || printf 'Warning: could not rewrite the loading page.\n' >&2
            start_html3_worker "$html_token" "$refresh_all"
            http_send_message "$conn_fd" 202 Accepted 'Refreshing page.'
          fi
          last_heartbeat=$(now_sec)
          [[ -n "$conn_fd" ]] && { ztcp -c "$conn_fd" 2>/dev/null || true }
          conn_fd=""
          continue
        fi
        # Reply before the potentially long channel scan. The browser
        # immediately queues a reload, which this single-threaded server
        # answers after yy.html has been regenerated.
        http_send_message "$conn_fd" 202 Accepted 'Refreshing page.'
        ztcp -c "$conn_fd" 2>/dev/null || true
        conn_fd=""
        # A long-running server can outlive an external status repair or
        # backfill. Merge the file again so a refresh cannot overwrite newer
        # on-disk values with stale in-memory channel records.
        read_channel_check_status
        generate_html "$callback_base" "$refresh_all" "$incremental" \
          || printf 'Warning: could not refresh the page; keeping the previous page.\n' >&2
        # Heartbeats cannot be accepted while the single-threaded server is
        # regenerating the page. Do not mistake that expected pause for the
        # browser having closed as soon as generation finishes.
        last_heartbeat=$(now_sec)
        ;;
      "POST /channel/${html_token}")
        channel_change_error=""
        if apply_channel_change "$req_body"; then
          http_send_message "$conn_fd" 200 OK 'Channel IDs updated. Refreshing page.'
        else
          http_send_message "$conn_fd" 400 'Bad Request' "$channel_change_error"
        fi
        ;;
      "POST /download/${html_token}")
        hook_started=0
        if start_selected_video_hooks "$req_body"; then
          http_send_message "$conn_fd" 200 OK "Started ${hook_started} local download job(s)."
        else
          http_send_message "$conn_fd" 400 'Bad Request' "$hook_error"
        fi
        ;;
      *)
        http_send_message "$conn_fd" 404 'Not Found' 'Not found'
        ;;
    esac
    [[ -n "$conn_fd" ]] && { ztcp -c "$conn_fd" 2>/dev/null || true }
  done
  ztcp -c "$listen_fd" 2>/dev/null || true
  trap - INT TERM
  trap - PIPE
  return 0
}

# ---------------------------------------------------------------------------
# Main flow: -U, then -o/-O/--html/--html2, then -c, then download.
# ---------------------------------------------------------------------------

if [[ -n "$current_url" ]]; then
  print -r -- "$current_url" >| "$url_file"
elif [[ -f "$url_file" ]]; then
  IFS= read -r current_url < "$url_file" || current_url=""
  # yy.ps1 writes this file with a trailing CRLF on Windows, and a BOM when the
  # host defaults to UTF8; neither belongs in the URL handed to yt-dlp.
  current_url=$(trim "$current_url")
fi

run_url=$current_url
[[ -n "$temp_url" ]] && run_url=$temp_url

if (( ! output_path_passed )) && [[ "$run_url" =~ '^https?://([^/]+\.)?youtube\.com/@([^/?#]+)' ]]; then
  output_path="./${match[2]}"
fi

if (( switch_to_py )); then
  # The implementation is fetched first and the launchers only if it lands.
  # The reverse order can leave ./yy.zsh as a launcher with no ./yy.py beside
  # it, which is a directory with no working wrapper and no way back.
  if ! update_self 'yy.py' '#!/usr/bin/env python3' 'py/yy.py'; then
    printf 'Error: could not fetch py/yy.py; ./yy.zsh left untouched\n' >&2
    exit 1
  fi
  # Both wrappers are switched, not just the one that is running. A directory
  # holding a yy.zsh launcher next to a shell-build yy.ps1 is two different
  # builds sharing one state directory, and whichever wrapper the next run
  # picks would decide which build it got.
  #
  # The *other* wrapper goes first and this one last, so a failure leaves the
  # wrapper the user just invoked still able to understand --py and retry. The
  # reverse order replaces ./yy.zsh with a launcher that rejects --py, and the
  # only way forward would be the other wrapper or a manual download.
  if ! update_self 'yy.ps1' '#!/usr/bin/env pwsh' 'py/yy.ps1'; then
    printf 'Error: could not fetch py/yy.ps1; ./yy.py was replaced but both\n' >&2
    printf '       wrappers are still the shell build. Re-run --py.\n' >&2
    exit 1
  fi
  if ! update_self 'yy.zsh' '#!/bin/zsh' 'py/yy.zsh'; then
    printf 'Error: could not fetch py/yy.zsh; ./yy.py and ./yy.ps1 are now the\n' >&2
    printf '       Python build but ./yy.zsh is still the shell build.\n' >&2
    printf '       Re-run --py; what already landed is left alone.\n' >&2
    exit 1
  fi
  printf 'Switched to the Python build. Previous copies are in .tmp.\n'
  exit 0
fi

if (( do_update )); then
  exe=$(ytdlp_path) || {
    printf 'Error: yt-dlp binary not found next to this script\n' >&2
    exit 1
  }
  run_cmd "$exe" -U
  update_self 'yy.zsh' '#!/bin/zsh' && exit 0
  exit 1
fi

checkpoint_after_checks_ms=0
read_channel_check_status
remove_stale_channel_check_status

if [[ "$open_mode" == "html3-worker" ]]; then
  worker_callback_base="http://${html_listen_host}:${html_listen_port}"
  worker_progress_path=$(html3_progress_file "$html3_worker_token")
  worker_fragments_path=$(html3_fragments_dir "$html3_worker_token")
  rm -rf -- "$worker_fragments_path" 2>/dev/null || true
  if ! mkdir -p -- "$worker_fragments_path"; then
    printf 'HTML3 worker failed: could not create %s\n' "$worker_fragments_path" >&2
    exit 1
  fi
  html3_progress_updates=()
  write_html3_progress "$worker_progress_path" 0 0
  if generate_html "$worker_callback_base" "$html3_worker_refresh_all" 1 \
      "$worker_progress_path" "$worker_fragments_path"; then
    for failed_entry in "${html3_failed_channels[@]}"; do
      printf 'HTML3 skipped failed channel @%s: %s\n' "${failed_entry%%$'\t'*}" "${failed_entry#*$'\t'}"
    done
    if (( ${#html3_failed_channels} > 0 )); then
      failed_summary=""
      for failed_entry in "${html3_failed_channels[@]}"; do
        [[ -n "$failed_summary" ]] && failed_summary+=", "
        failed_summary+="@${failed_entry%%$'\t'*} (${failed_entry#*$'\t'})"
      done
      printf 'HTML3 completed with channel errors: %s\n' "$failed_summary"
    else
      printf 'HTML3 completed with no channel errors.\n'
    fi
    set_html3_worker_state "$worker_progress_path" success ''
    exit 0
  fi
  set_html3_worker_state "$worker_progress_path" error 'Page generation failed.' \
    'Could not generate the HTML3 page.'
  printf 'HTML3 worker failed: could not generate the HTML3 page.\n' >&2
  exit 1
fi

if [[ -n "$open_mode" ]]; then
  if [[ "$open_mode" == "html" ]]; then
    html_token=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    [[ -n "$html_token" ]] || html_token=$(( RANDOM * RANDOM ))
    callback_base="http://${html_listen_host}:${html_listen_port}"
    if (( html3_mode )); then
      # The shell is written first and the scan runs in a worker, so the page
      # is reachable immediately instead of after a full channel sweep.
      remove_stale_temporary_artifacts
      if ! write_html3_loading_page "$html_token" 'Loading channels...'; then
        open_failure_count=1
      fi
    elif ! generate_html "$callback_base" 0 "$html_incremental"; then
      open_failure_count=1
    fi
    if (( open_failure_count == 0 )); then
      invoke_html_callback_server "$callback_base" "$html_incremental" "$html3_mode" || open_failure_count=1
    fi
    (( open_failure_count == 0 )) && checkpoint_after_checks_ms=$(now_ms)
    (( html_failure_count > 0 )) && open_failure_count=1
  else
    run_open_mode "$open_mode" || true
    [[ "$open_mode" == "check" ]] && checkpoint_after_checks_ms=$(now_ms)
  fi
fi

if (( set_checkpoint )); then
  if [[ "$open_mode" == "check" ]] && should_skip_checkpoint "$open_failure_count" "$open_channel_count"; then
    printf 'Checkpoint not updated: %s of %s channel check(s) failed\n' \
      "$open_failure_count" "$open_channel_count" >&2
  elif (( checkpoint_after_checks_ms > 0 )); then
    set_checkpoint_at "$checkpoint_after_checks_ms"
  else
    set_checkpoint_now
  fi
fi

if [[ -n "$open_mode" ]] || (( set_checkpoint )); then
  (( open_failure_count > 0 )) && exit 1
  exit 0
fi

if [[ -n "$run_url" ]]; then
  exe=$(ytdlp_path) || {
    printf 'Error: yt-dlp binary not found next to this script\n' >&2
    exit 1
  }
  if [[ ! -f "$cookies_file" ]]; then
    printf 'Error: %s does not exist; export YouTube cookies from a browser first\n' "$cookies_file" >&2
    exit 1
  fi
  run_cmd "$exe" --cookies "$cookies_file" --paths "$output_path" "$run_url"
else
  printf 'Error: no URL provided, and %s does not exist or is empty\n' "$url_file" >&2
  exit 1
fi

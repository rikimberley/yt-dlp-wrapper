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
# - uses -c to overwrite ./checkpoint.txt with the current epoch-ms timestamp,
#   and skip any download (runs after -o/-O, so `-o -c` means "open the new
#   ones, then mark everything as seen")
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
#   ./yy.zsh -c
#   ./yy.zsh -o -c
#
# This is the macOS/Linux port of yy.ps1 and must stay behaviorally identical
# to it, except that yy.ps1 also carries --html3 (a loading-page-first variant
# of --html2 that exists only to work around Windows process start latency).
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
url_file="./current_url.txt"
channels_file="./channel-ids.txt"
channel_id_cache_file="./channel-id-cache.txt"
checkpoint_file="./checkpoint.txt"
cookies_file="./cookies.txt"
channel_status_file="./channel-check-status.json"
downloaded_videos_file="./downloaded-videos.json"
html_video_cache_file="./html-video-cache.json"
html_file="./yy.html"
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
html_heartbeat_timeout_sec=300
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
open_mode=""
html_mode=0
html_incremental=0
set_checkpoint=0
html_failure_count=0

while (( $# > 0 )); do
  case "$1" in
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
    -o|-O)
      if [[ -n "$open_mode" ]]; then
        printf 'Error: -o, -O, --html, and --html2 cannot be combined\n' >&2
        exit 1
      fi
      if [[ "$1" == "-o" ]]; then open_mode="check"; else open_mode="open"; fi
      ;;
    --html|--html2)
      if [[ -n "$open_mode" ]]; then
        printf 'Error: -o, -O, --html, and --html2 cannot be combined\n' >&2
        exit 1
      fi
      open_mode="html"
      html_mode=1
      if [[ "$1" == "--html2" ]]; then html_incremental=1; fi
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
  v = repl(v, UMARK, BS "u")
  return v
}
function emit(path, value) { printf "%s\t%s\n", esc(path), esc(value) }
function skipws(   c) {
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == " " || c == "\t" || c == "\n" || c == "\r") i++
    else return
  }
}
function parseString(   out, c, e) {
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
      else if (e == "u") { out = out UMARK substr(s, i, 4); i += 4 }
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
  CR = sprintf("%c", 13); SEP = sprintf("%c", 1); UMARK = sprintf("%c", 2)
  s = ""
}
{ s = s $0 NL }
END {
  n = length(s)
  i = 1
  parseValue("")
}
'

# Flatten the JSON in file $1. A missing or unreadable file yields no output,
# which every caller treats as "empty state", never as an error.
json_flatten_file() {
  [[ -f "$1" ]] || return 0
  awk "$json_flatten_awk" "$1" 2>/dev/null || true
}

json_flatten_string() {
  print -r -- "$1" | awk "$json_flatten_awk" 2>/dev/null || true
}

# Escape a zsh string for use as a JSON string body (without the quotes).
json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
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
  local tmp="${channel_status_file}.new.$$" channel first=1
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
  local jpath value idx field cutoff changed=0 expired=0 invalid=0 key
  local -a parts order
  local -A rec_channel rec_video rec_target rec_epoch
  cutoff=$(( $(now_sec) - downloaded_video_ttl_sec ))
  if [[ ! -f "$downloaded_videos_file" ]]; then
    printf 'Downloaded-video history not found; starting empty.\n'
    return 0
  fi
  while IFS=$'\t' read -r jpath value; do
    parts=(${(ps:\x01:)jpath})
    (( ${#parts} == 2 )) || continue
    idx=${(g::)parts[1]}
    field=${(g::)parts[2]}
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
  (( changed )) && save_downloaded_videos
  return 0
}

save_downloaded_videos() {
  local tmp="${downloaded_videos_file}.new.$$" key first=1
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
  return 0
}

save_html_video_cache() {
  local tmp="${html_video_cache_file}.new.$$" channel row first=1 entry_first
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
  errfile=$(mktemp) || return 1
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
    dir=$(mktemp -d) || return 0
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
# would leave the machine with no working wrapper at all.
update_self() {
  local name=$1 sentinel=$2 url body tmp
  url="${script_raw_base}/${name}"
  body=$(fetch_url "$url" "${name} from master") || {
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
  # Write to a same-directory temp file and rename, so an interrupted write can
  # never truncate the running script. The .bak is the escape hatch for a clone
  # that had uncommitted local edits.
  tmp="./${name}.new.$$"
  print -r -- "$body" > "$tmp" || return 1
  [[ -x "./$name" ]] && { chmod +x "$tmp" || true }
  [[ -f "./$name" ]] && { cp -p -- "./$name" "./${name}.bak" || true }
  mv -f -- "$tmp" "./$name" || return 1
  printf 'Updated %s from master (previous copy saved as %s.bak)\n' "$name" "$name"
}

# ---------------------------------------------------------------------------
# Channel id resolution
# ---------------------------------------------------------------------------

cached_channel_id() {
  local handle=$1 h id
  [[ -f "$channel_id_cache_file" ]] || return 1
  while IFS=$'\t' read -r h id || [[ -n "$h" ]]; do
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
  tmp=$(mktemp) || return 0
  if [[ -f "$channel_id_cache_file" ]]; then
    while IFS=$'\t' read -r h existing || [[ -n "$h" ]]; do
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
  local html=$1 id pattern
  for pattern in 'channel_id=UC[A-Za-z0-9_-]*' '"externalId":"UC[A-Za-z0-9_-]*' '/channel/UC[A-Za-z0-9_-]*'; do
    id=$(printf '%s' "$html" | grep -o "$pattern" | sed -n '1s/.*\(UC[A-Za-z0-9_-]*\).*/\1/p') || id=""
    if [[ -n "$id" ]]; then
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
  tmp=$(mktemp) || return 1
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
<script>const callback="@@DOWNLOAD@@",statusUrl="@@STATUS@@",stopUrl="@@STOP@@";const status=document.querySelector("#status"),jobLog=document.querySelector("#job-log"),setChecks=(root,action)=>root.querySelectorAll("input.y1,input.y2").forEach(x=>{if(action==="none")x.checked=false;else if(x.className===action)x.checked=true}),showJobs=async()=>{try{const r=await fetch(statusUrl),b=await r.json(),p=[];if(b.running)p.push(b.running+" running");if(b.queued)p.push(b.queued+" queued");if(b.completed)p.push(b.completed+" completed");if(b.failed)p.push(b.failed+" failed");status.textContent=p.length?p.join(", ")+"." : "No download jobs yet.";jobLog.textContent=(b.logs||[]).join("\n");jobLog.scrollTop=jobLog.scrollHeight;setTimeout(showJobs,1000)}catch(e){status.textContent="Status unavailable: "+e.message}};document.addEventListener("click",e=>{const b=e.target.closest("button[data-action]");if(b)setChecks(b.closest(".channel")||document,b.dataset.action)});document.querySelector("#download").onclick=async()=>{const items=[...document.querySelectorAll("input:checked")].map(x=>({target:x.className,url:x.dataset.url,path:x.dataset.path,channel_id:x.dataset.channelId,video_id:x.dataset.videoId}));if(!items.length){status.textContent="Select at least one video";return}status.textContent="Starting local downloads...";try{const r=await fetch(callback,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({items})}),b=await r.json();status.textContent=b.message||"Started";showJobs()}catch(e){status.textContent="Callback failed: "+e.message}};document.querySelector("#stop").onclick=async()=>{try{const r=await fetch(stopUrl,{method:"POST"}),b=await r.json();status.textContent=b.message||"Server stopped"}catch(e){status.textContent="Server stopped"}window.close();setTimeout(()=>location.replace("about:blank"),150)};setInterval(()=>fetch("@@HEARTBEAT@@",{method:"POST",keepalive:true}),2000);showJobs();const backToTop=document.querySelector("#back-to-top"),toggleTop=()=>backToTop.classList.toggle("visible",window.scrollY>200);window.addEventListener("scroll",toggleTop,{passive:true});toggleTop();</script><script>const postJson=(u,x)=>fetch(u,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(x)}),refreshPage=async(all=false)=>{status.textContent=all?"Refreshing all channels...":"Refreshing channels...";try{const b=await (await fetch(all?"@@REFRESHALL@@":"@@REFRESH@@",{method:"POST"})).json();status.textContent=b.message;if(!b.message||b.message==="Refreshing page.")location.reload()}catch(e){status.textContent="Refresh failed: "+e.message}};document.querySelector("#checkpoint").onclick=async()=>{const b=await (await fetch("@@CHECKPOINT@@",{method:"POST"})).json();status.textContent=b.message;if(b.checkpoint_ms)document.querySelector("#checkpoint-value").textContent="Checkpoint: "+b.checkpoint_ms};document.querySelector("#refresh").onclick=()=>refreshPage(false);document.querySelector("#refresh-all").onclick=()=>refreshPage(true);document.querySelector("#channel-add-button").onclick=async()=>{const x=document.querySelector("#channel-add").value.trim();if(x){await postJson("@@CHANNEL@@",{action:"add",channel:x});refreshPage()}};document.querySelectorAll(".channel-delete").forEach(b=>b.onclick=async()=>{await postJson("@@CHANNEL@@",{action:"delete",channel:b.dataset.channel});refreshPage()});</script>
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

# Build ./yy.html from qualifying account-visible entries on each /videos tab.
# $1 is the callback base URL, $2 enables REFRESH ALL (scan even stale
# channels), $3 enables --html2's incremental cache. Leaves the number of
# channels that could not be scanned in $html_failure_count.
generate_html() {
  local callback_base=$1 refresh_all=${2:-0} incremental=${3:-0}
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
  result_dir=$(mktemp -d) || return 1
  local -a scan_cookie_files free_slots worker_pid worker_slot worker_index
  # Declared here, not inside the pool loop: a bare `local name` for a variable
  # that already exists in the same scope makes zsh *print* it (`w=0`).
  local w done_any=0
  local -a cleanup_paths
  for (( slot = 0; slot < MAX_THREADS; slot++ )); do
    cp -f -- "$cookies_file" "./cookies${slot}.txt" 2>/dev/null || continue
    scan_cookie_files+=("./cookies${slot}.txt")
    free_slots+=("$slot")
  done
  html_scan_cleanup() {
    local p
    for p in "${scan_cookie_files[@]}"; do rm -f -- "$p" 2>/dev/null || true; done
    rm -rf -- "$result_dir" 2>/dev/null || true
  }
  trap 'html_scan_cleanup' EXIT INT TERM

  next_index=1
  while (( next_index <= ${#channels} || ${#worker_pid} > 0 )); do
    while (( next_index <= ${#channels} && ${#free_slots} > 0 )); do
      channel=${channels[$next_index]}
      if (( ${+skip_ytdlp[$channel]} )); then
        print -rn -- "" >| "$result_dir/$next_index.out"
        print -r -- 0 >| "$result_dir/$next_index.status"
        print -r -- 1 >| "$result_dir/$next_index.feedonly"
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
            free_slots+=("${worker_slot[$w]}")
            worker_pid[$w]=()
            worker_slot[$w]=()
            worker_index[$w]=()
            done_any=1
          fi
        done
        (( done_any )) || sleep 1
      done
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
      if (( ${+downloaded_set[${channel_id}$'\t'${vid}$'\t'y1]} )); then
        checked_y1=" checked"; (( ++restored ))
      fi
      if (( ${+downloaded_set[${channel_id}$'\t'${vid}$'\t'y2]} )); then
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
  for index in {1..${#managed_keys}}; do
    key=${managed_keys[$index]}
    sortable+=("${status_checked_ms[$key]:-0}"$'\t'"${status_latest_video_ms[$key]:-0}"$'\t'"$index")
  done
  local table_body=""
  for row in ${(f)"$(printf '%s\n' "${sortable[@]}" | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2nr)"}; do
    [[ -n "$row" ]] || continue
    index=${row##*$'\t'}
    key=${managed_keys[$index]}
    local checked_text='never' latest_text='unknown' avatar=''
    (( ${status_checked_ms[$key]:-0} > 0 )) && checked_text=$(format_relative_ms "${status_checked_ms[$key]}")
    (( ${status_latest_video_ms[$key]:-0} > 0 )) && latest_text=$(format_relative_ms "${status_latest_video_ms[$key]}")
    if [[ -n "${status_thumbnail[$key]}" ]]; then
      avatar='<img src="'$(html_escape "${status_thumbnail[$key]}")'" alt="" width="42" height="42" style="border-radius:50%;object-fit:cover">'
    fi
    table_body+='<tr><td>'"$avatar"'</td><td><a href="'$(html_escape "$(channel_url_for "$key")")'" target="_blank" rel="noopener noreferrer">'$(html_escape "${managed_display[$index]}")'</a></td><td>'$(html_escape "$checked_text")'</td><td>'$(html_escape "$latest_text")'</td><td><button class="channel-delete" data-channel="'$(html_escape "${managed_display[$index]}")'" type="button">delete</button></td></tr>'$'\n'
  done
  save_channel_check_status

  tmp_page="${html_file}.new.$$"
  {
    print -r -- '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>YouTube Video Download</title>'
    print -r -- "$html_page_css"
    print -r -- '<h1>YouTube Video Download</h1><p>Select y1 and/or y2, then click DOWNLOAD SELECTED to run the matching local yy hook. <span id="checkpoint-value">Checkpoint: '"$checkpoint_ms"'</span></p><div class="controls"><button id="download" type="button">DOWNLOAD SELECTED</button><button id="checkpoint" type="button">CHECKPOINT</button><button id="refresh" type="button">REFRESH</button><button id="refresh-all" type="button">REFRESH ALL</button><button id="stop" type="button">STOP SERVER</button><button data-action="y1" type="button">y1</button><button data-action="y2" type="button">y2</button><button data-action="none" type="button">none</button></div><p id="status"></p><pre id="job-log" class="job-log"></pre><main>'
    (( ${#page_sections} )) && print -r -- "${(j:
:)page_sections}"
    print -r -- '<section class="channel"><div class="channel-bar"></div><div class="channel-title"><h2>Channel IDs</h2></div><div class="controls"><input id="channel-add" placeholder="@channel or UC channel id"><button id="channel-add-button" type="button">add</button></div><table class="channel-table"><thead><tr><th>Profile</th><th>Channel</th><th>Last checked</th><th>Latest video</th><th>Actions</th></tr></thead><tbody>'
    print -rn -- "$table_body"
    print -r -- '</tbody></table></section>'
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
  local key hook
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
      # y1 and y2 both run this wrapper's own download path. The labels are
      # kept because the page, the completion history and the y2-before-y1
      # ordering are all keyed on them.
      hook=$script_self
      if [[ ! -x "$hook" ]]; then
        hook_error="This wrapper (${hook}) is not executable"
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
    base=$(mktemp -t yy-html-job) || return 1
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
  tmp="${channels_file}.new.$$"
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
  local callback_base=$1 incremental=${2:-0}
  local listen_fd conn_fd last_heartbeat now stop=0 refresh_all
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
  open_url "http://${html_listen_host}:${html_listen_port}/" || true
  printf 'Waiting for DOWNLOAD SELECTED on http://%s:%s/ (Ctrl+C or STOP SERVER exits)\n' \
    "$html_listen_host" "$html_listen_port"
  while (( ! html_server_stop && ! stop )); do
    if ! zselect -t 100 -r "$listen_fd" 2>/dev/null; then
      now=$(now_sec)
      if (( now - last_heartbeat >= html_heartbeat_timeout_sec )); then
        printf 'HTML page closed or disconnected; stopping server.\n'
        break
      fi
      # Keep queued jobs moving even while the page is idle.
      get_download_job_status
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
        http_send_file "$conn_fd" "$html_file"
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
fi

run_url=$current_url
[[ -n "$temp_url" ]] && run_url=$temp_url

if (( ! output_path_passed )) && [[ "$run_url" =~ '^https?://([^/]+\.)?youtube\.com/@([^/?#]+)' ]]; then
  output_path="./${match[2]}"
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

if [[ -n "$open_mode" ]]; then
  if [[ "$open_mode" == "html" ]]; then
    html_token=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    [[ -n "$html_token" ]] || html_token=$(( RANDOM * RANDOM ))
    callback_base="http://${html_listen_host}:${html_listen_port}"
    if ! generate_html "$callback_base" 0 "$html_incremental"; then
      open_failure_count=1
    fi
    if (( open_failure_count == 0 )); then
      invoke_html_callback_server "$callback_base" "$html_incremental" || open_failure_count=1
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

#!/bin/zsh

# yy.zsh - convenience wrapper around ./yt-dlp
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
# - uses --html to generate a local 4-column video grid with y1/y2 selections
# - uses -c to overwrite ./checkpoint.txt with the current epoch-ms timestamp,
#   and skip any download (runs after -o/-O, so `-o -c` means "open the new
#   ones, then mark everything as seen")
#
# Examples:
#   ./yy.zsh 'https://example.com/video'
#   ./yy.zsh -t 'https://example.com/one-off'
#   ./yy.zsh 'https://saved.example.com/video' -t 'https://example.com/one-off'
#   ./yy.zsh -U
#   ./yy.zsh -o
#   ./yy.zsh -O
#   ./yy.zsh --html
#   ./yy.zsh -c
#   ./yy.zsh -o -c

set -euo pipefail

cd -- "${0:A:h}"

url_file="./current_url.txt"
channels_file="./channel-ids.txt"
channel_id_cache_file="./channel-id-cache.txt"
checkpoint_file="./checkpoint.txt"
user_agent="Mozilla/5.0"
# Pre-accepted consent cookies: without them YouTube can answer a channel page
# with a consent interstitial that carries no channel_id, which looked exactly
# like "channel has no public videos".
consent_cookie="SOCS=CAI; CONSENT=YES+cb"
accept_language="en-US,en;q=0.9"
fetch_timeout_sec=45
fetch_attempts=3
ytdlp_timeout_sec=30
ytdlp_attempts=1
ytdlp_deadline_sec=30
feed_failure_limit=3
feed_fetch_failures=0
skip_feed_fetches=0
feed_failure_counted_for_channel=0
# Head of master in the wrapper's own repo, used by -U to refresh this script.
script_raw_base="https://raw.githubusercontent.com/rikimberley/yt-dlp-wrapper/master"
current_url=""
temp_url=""
output_path="./t"
do_update=0
open_mode=""
set_checkpoint=0
html_checkpoint_ms=0
html_file="./yy.html"

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

# Trim leading/trailing whitespace (and any trailing CR) from $1.
trim() {
  local s=${1%$'\r'}
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  print -r -- "$s"
}

# Convert an ISO-8601 timestamp (e.g. 2026-08-01T16:30:12+00:00) to epoch ms.
iso_to_epoch_ms() {
  local ts=$1 base secs
  base=${ts%[+-]??:??}
  base=${base%Z}
  secs=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "$base" '+%s' 2>/dev/null) \
    || secs=$(date -u -d "$ts" '+%s' 2>/dev/null) \
    || return 1
  [[ -n "$secs" ]] || return 1
  print -r -- $(( secs * 1000 ))
}

# Read ./checkpoint.txt and normalise it to epoch milliseconds.
read_checkpoint_ms() {
  local raw digits
  if [[ ! -f "$checkpoint_file" ]]; then
    printf 'Error: %s does not exist\n' "$checkpoint_file" >&2
    return 1
  fi
  IFS= read -r raw < "$checkpoint_file" || raw=""
  digits=${raw//[^0-9]/}
  if [[ -z "$digits" ]]; then
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

# Fetch a URL once. On success prints nothing and leaves the body in
# $fetch_body; on failure sets $fetch_error and returns non-zero. $fetch_status
# holds the HTTP status (0 when the request never completed).
# --compressed matters: a channel page is ~1.2 MB raw but ~270 KB gzipped, and
# the uncompressed transfer is what kept blowing the timeout.
# No account cookies are ever sent.
fetch_body=""
fetch_error=""
fetch_status=0
fetch_url_once() {
  local url=$1 errfile raw code
  local rc=0
  fetch_body=""
  fetch_error=""
  fetch_status=0
  errfile=$(mktemp) || return 1
  raw=$(curl -sS --compressed --location --max-time "$fetch_timeout_sec" \
    -A "$user_agent" \
    -H "Accept-Language: ${accept_language}" \
    -H "Cookie: ${consent_cookie}" \
    -w '\n%{http_code}' \
    -- "$url" 2>"$errfile") || rc=$?
  fetch_error=$(<"$errfile")
  rm -f -- "$errfile"
  if (( rc != 0 )); then
    if [[ -z "$fetch_error" ]]; then
      fetch_error="curl exited $rc"
    fi
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
  local url=$1 what=$2
  local attempt=1
  while (( attempt <= fetch_attempts )); do
    if (( attempt > 1 )); then
      sleep $(( attempt - 1 ))
    fi
    if fetch_url_once "$url"; then
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
    (( attempt++ ))
  done
  printf 'Warning: giving up on %s (%s): %s\n' "$what" "$url" "$fetch_error" >&2
  return 1
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
  if [[ -x "./$name" ]]; then
    chmod +x "$tmp" || true
  fi
  if [[ -f "./$name" ]]; then
    cp -p -- "./$name" "./${name}.bak" || true
  fi
  mv -f -- "$tmp" "./$name" || return 1
  printf 'Updated %s from master (previous copy saved as %s.bak)\n' "$name" "$name"
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
  for candidate in ./yt-dlp ./yt-dlp.exe; do
    if [[ -f "$candidate" ]]; then
      print -r -- "$candidate"
      return 0
    fi
  done
  return 1
}

# Print the cached UC id for a handle, or return non-zero.
# ./channel-id-cache.txt is a pure cache (TAB separated): deleting it only costs
# one page fetch per channel.
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
      if [[ -z "$h" || "$h" == "$handle" ]]; then
        continue
      fi
      printf '%s\t%s\n' "$h" "$existing" >> "$tmp"
    done < "$channel_id_cache_file"
  fi
  if [[ -n "$id" ]]; then
    printf '%s\t%s\n' "$handle" "$id" >> "$tmp"
  fi
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

# Last-resort channel id resolution using the vendored yt-dlp binary, which
# tracks YouTube's page layout far more closely than the regexes above. Stays
# logged-out (no --cookies) so the feed remains public-by-construction.
channel_id_via_ytdlp() {
  local url=$1 exe out id
  exe=$(ytdlp_path) || return 1
  run_ytdlp_metadata "$exe" --ignore-config --no-warnings --socket-timeout "$ytdlp_timeout_sec" \
    --retries "$ytdlp_attempts" --extractor-retries "$ytdlp_attempts" --flat-playlist \
    --playlist-items 0 --print 'playlist:%(channel_id)s' "$url" || return 1
  out=$ytdlp_output
  id=$(printf '%s\n' "$out" | grep -o '^UC[A-Za-z0-9_-]*$' | head -n 1) || id=""
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

# Print the newest <published> in a channel's Atom feed, in epoch ms.
# Prints "-1 fetch" when the feed could not be read, otherwise "<ms> ok"; 0
# milliseconds means it holds no entries. Those cases must stay distinguishable,
# or a network failure reads as an empty channel. The feed omits members-only
# videos, so it is public-by-construction.
feed_newest_ms() {
  local channel_id=$1 feed feed_url ts epoch newest=0 seen=0
  feed_url="https://www.youtube.com/feeds/videos.xml?channel_id=${channel_id}"
  if ! feed=$(fetch_url "$feed_url" "video feed for ${channel_id}"); then
    print -r -- '-1 fetch'
    return 0
  fi
  # Entries are not guaranteed to be date-sorted, so scan them all.
  for ts in ${(f)"$(printf '%s' "$feed" | grep -o '<published>[^<]*</published>' | sed 's/<[^>]*>//g')"}; do
    [[ -n "$ts" ]] || continue
    (( seen++ ))
    if ! epoch=$(iso_to_epoch_ms "$ts"); then
      printf "Warning: unparsable <published> value '%s' in %s\n" "$ts" "$feed_url" >&2
      continue
    fi
    (( epoch > newest )) && newest=$epoch
  done
  if (( seen > 0 && newest == 0 )); then
    print -r -- '-1 ok'
    return 0
  fi
  print -r -- "$newest ok"
}

# Metadata probes must not outlive the wrapper indefinitely. yt-dlp's own
# socket timeout does not cover every extractor subprocess on every platform.
ytdlp_output=""
run_ytdlp_metadata() {
  local tmp pid waited=0 status=0 deadline=$ytdlp_deadline_sec
  if [[ "${1:-}" == "--no-deadline" ]]; then
    deadline=0
    shift
  fi
  ytdlp_output=""
  tmp=$(mktemp) || return 1
  "$@" >"$tmp" 2>/dev/null & pid=$!
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
  done
  wait "$pid" || status=$?
  ytdlp_output=$(<"$tmp")
  rm -f -- "$tmp"
  return "$status"
}

# Fall back to the newest few entries in the channel's uploads playlist when
# the legacy Atom feed is unavailable or unusable. Resolve the entries so
# yt-dlp can provide exact timestamps and public availability. No cookies are
# sent. Prints -1 when the fallback failed and 0 when no public entry was seen.
ytdlp_newest_public_ms() {
  local channel_id=$1 exe uploads_id uploads_url out status=0 line timestamp newest=0
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
    "$uploads_url" || status=$?
  out=$ytdlp_output
  for line in ${(f)out}; do
    if [[ "$line" =~ ^fallback:([0-9]+):public$ ]]; then
      timestamp=${match[1]}
      (( timestamp *= 1000 ))
      (( timestamp > newest )) && newest=$timestamp
    fi
  done
  if (( newest > 0 )); then
    print -r -- "$newest"
  elif (( status != 0 )); then
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
  if ! resolve_channel_id "$handle" "$channel_url"; then
    return 0
  fi
  channel_id=$resolved_channel_id
  source=$resolved_source
  public_newest_ms_for_channel_id "$channel_id"
  newest=$public_newest_ms_result

  # If neither source can check a cached id, the handle may now point at a
  # different channel. Drop the stale entry and resolve once more.
  if (( newest < 0 )) && [[ "$source" == "cache" ]]; then
    store_channel_id "$handle" ""
    if ! resolve_channel_id "$handle" "$channel_url" "skip-cache"; then
      return 0
    fi
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

# Overwrite ./checkpoint.txt with the current time in epoch milliseconds.
set_checkpoint_now() {
  local now=$(( $(date +%s) * 1000 ))
  set_checkpoint_at "$now"
}

set_checkpoint_at() {
  local timestamp_ms=$1
  print -r -- "$timestamp_ms" >| "$checkpoint_file"
  printf 'Checkpoint updated: %s\n' "$timestamp_ms"
}

# Protect a checkpoint from advancing past too many channels that were not
# successfully checked. "All" only applies when at least one channel was listed.
should_skip_checkpoint() {
  local failures=$1 channel_count=$2
  (( failures >= 3 || (channel_count > 0 && failures == channel_count) ))
}

# Implement -o (check against the checkpoint) and -O (open everything).
# Records the listed-channel and failed-check counts in globals, and returns
# non-zero when any channel's check could not be completed.
open_failure_count=0
open_channel_count=0
run_open_mode() {
  local mode=$1 checkpoint_ms=0 line channel channel_url newest failures=0
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
  while IFS= read -r line || [[ -n "$line" ]]; do
    channel=$(trim "$line")
    [[ -n "$channel" && "$channel" != '#'* ]] || continue
    (( open_channel_count++ ))
    channel=${channel#@}
    channel_url=$(channel_url_for "$channel")
    if [[ "$mode" == "open" ]]; then
      open_url "$channel_url"
      continue
    fi
    newest_public_ms "$channel" "$channel_url"
    newest=$newest_public_ms_result
    if (( newest < 0 )); then
      (( failures++ ))
      printf '%s: CHECK FAILED (see warnings above; not opened)\n' "$channel"
    elif (( newest == 0 )); then
      printf '%s: no public videos found (skipped)\n' "$channel"
    elif (( newest > checkpoint_ms )); then
      printf '%s: new public video (%s > %s)\n' "$channel" "$newest" "$checkpoint_ms"
      open_url "$channel_url"
    else
      printf '%s: up to date (%s <= %s)\n' "$channel" "$newest" "$checkpoint_ms"
    fi
  done < "$channels_file"
  open_failure_count=$failures
  if (( failures > 0 )); then
    printf 'Error: %s channel check(s) failed\n' "$failures" >&2
    return 1
  fi
  return 0
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

# Build a local page from every qualifying public entry on each /videos tab.
# A file:// page cannot
# execute host commands, so the button downloads a script containing yy1/yy2
# commands for the selected videos.
generate_html() {
  local line channel channel_url exe output id url thumb title timestamp video_ms checkpoint_ms failures=0 cards
  local tmp="${html_file}.new.$$"
  exe=$(ytdlp_path) || { printf 'Error: yt-dlp binary not found next to this script\n' >&2; return 1; }
  [[ -f "$channels_file" ]] || { printf 'Error: %s does not exist\n' "$channels_file" >&2; return 1; }
  checkpoint_ms=$(read_checkpoint_ms) || return 1
  print -r -- '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>yy video grid</title>' >| "$tmp"
  print -r -- '<style>:root{--bg:#0d1117;--card:#161b22;--bd:#30363d;--fg:#e6edf3;--mut:#8b949e;--acc:#58a6ff;--ok:#3fb950}*{box-sizing:border-box}body{margin:0;padding:16px 60px;background:var(--bg);color:var(--fg);font:14px/1.55 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif}h1{font-size:32px;margin:0 0 6px;color:var(--fg);border-bottom:3px solid var(--acc);padding-bottom:8px}h2{font-size:22px;margin:0;color:var(--acc)}p{color:var(--mut);font-size:12.5px;margin:0 0 16px}button{background:#21262d;color:var(--fg);border:1px solid var(--bd);border-radius:6px;padding:5px 10px;cursor:pointer;font:inherit}button:hover{border-color:var(--acc);background:#1c2230}.grid{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:12px;margin:12px 0 28px}.card{background:var(--card);border:1px solid var(--bd);padding:10px;border-radius:10px}.video-link{display:block;color:var(--fg);text-decoration:none}.video-link:hover{color:var(--acc)}.preview{position:relative;aspect-ratio:16/9;background:#0b0f14;overflow:hidden;border-radius:6px}.preview img{width:100%;height:100%;object-fit:cover;transition:transform .2s ease,filter .2s ease}.card:hover .preview img{transform:scale(1.04);filter:brightness(.82)}.video-title{font-size:12px;line-height:1.4;margin-top:7px}.checks,.controls,.channel-title{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.checks{margin-top:8px;color:var(--mut)}.channel{margin-top:28px}.channel-title{padding-bottom:6px;border-bottom:1px solid var(--bd)}.controls button{padding:4px 9px}.back-to-top{position:fixed;bottom:24px;right:24px;width:48px;height:48px;border-radius:50%;background:var(--acc);color:var(--bg);border:none;cursor:pointer;box-shadow:0 2px 8px rgba(0,0,0,.45);display:none;font-size:34px;font-weight:700;line-height:1}.back-to-top.visible{display:flex;align-items:center;justify-content:center}.back-to-top:hover{background:#79c0ff}@media(max-width:1100px){body{padding:16px}.grid{grid-template-columns:repeat(3,minmax(0,1fr))}}@media(max-width:650px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}}</style></head><body>' >> "$tmp"
  print -r -- "<h1>yy video grid</h1><p>Select y1 and/or y2, then click DOWNLOAD SELECTED. The button downloads a command script; run it next to yy1/yy2.</p><div class=\"controls\"><span>Checkpoint: ${checkpoint_ms}</span><button id=\"download\" type=\"button\">DOWNLOAD SELECTED</button><button data-action=\"y1\" type=\"button\">y1</button><button data-action=\"y2\" type=\"button\">y2</button><button data-action=\"none\" type=\"button\">none</button></div><main>" >> "$tmp"
  while IFS= read -r line || [[ -n "$line" ]]; do
    channel=$(trim "$line"); [[ -n "$channel" && "$channel" != '#'* ]] || continue
    channel=${channel#@}; channel_url=$(channel_url_for "$channel")
    # /videos excludes Shorts; no item cap lets yt-dlp follow every continuation
    # page. Large channels are allowed to exceed the normal metadata deadline.
    run_ytdlp_metadata --no-deadline "$exe" --ignore-config --no-warnings \
      --socket-timeout "$ytdlp_timeout_sec" --retries "$ytdlp_attempts" \
      --extractor-retries "$ytdlp_attempts" --skip-download \
      --match-filter 'availability = public' \
      --print 'video:%(id)s\t%(webpage_url)s\t%(thumbnail)s\t%(title)s\t%(timestamp)s' "$channel_url" || {
      printf 'Warning: could not collect the videos tab for @%s\n' "$channel" >&2
      failures=$(( failures + 1 )); continue
    }
    output=$ytdlp_output
    cards=""
    while IFS=$'\t' read -r line; do
      [[ "$line" == video:* ]] || continue
      line=${line#video:}; IFS=$'\t' read -r id url thumb title timestamp <<< "$line"
      [[ -n "$id" && -n "$url" && "$timestamp" =~ ^[0-9]+$ ]] || continue
      video_ms=$(( timestamp * 1000 ))
      (( video_ms > checkpoint_ms )) || continue
      cards+=$(printf '<article class=card><a class=video-link href="%s" target="_blank" rel="noopener noreferrer"><div class=preview><img src="%s" alt=""></div><div class=video-title>%s</div></a><div class=checks><label><input class=y1 data-url="%s" data-path="./%s" type=checkbox> y1</label><label><input class=y2 data-url="%s" data-path="./%s" type=checkbox> y2</label></div></article>\n' \
        "$(html_escape "$url")" "$(html_escape "$thumb")" "$(html_escape "$title")" "$(html_escape "$url")" "$(html_escape "$channel")" "$(html_escape "$url")" "$(html_escape "$channel")")
    done <<< "$output"
    if [[ -n "$cards" ]]; then
      print -r -- "<section class=channel><div class=channel-title><h2>$(html_escape "$channel")</h2><div class=controls><button data-action=y1 type=button>y1</button><button data-action=y2 type=button>y2</button><button data-action=none type=button>none</button></div></div><div class=grid>" >> "$tmp"
      print -r -- "$cards" >> "$tmp"
      print -r -- '</div></section>' >> "$tmp"
    fi
  done < "$channels_file"
  print -r -- '<button id="back-to-top" class="back-to-top" type="button" onclick="window.scrollTo({top:0,behavior:&quot;smooth&quot;})" aria-label="Back to top" title="Back to top">&uarr;</button><script>const setChecks=(root,action)=>root.querySelectorAll("input.y1,input.y2").forEach(x=>{if(action==="none")x.checked=false;else if(x.className===action)x.checked=true});document.addEventListener("click",e=>{const b=e.target.closest("button[data-action]");if(b)setChecks(b.closest(".channel")||document,b.dataset.action)});document.querySelector("#download").onclick=()=>{const q=[...document.querySelectorAll("input:checked")],lines=q.map(x=>(x.className==="y1"?"yy1":"yy2")+" -p "+JSON.stringify(x.dataset.path)+" -t "+JSON.stringify(x.dataset.url));if(!lines.length){alert("Select at least one video");return}const a=document.createElement("a");a.href=URL.createObjectURL(new Blob(["#!/bin/sh\nset -eu\n"+lines.join("\n")+"\n"],{type:"text/plain"}));a.download="yy-download.sh";a.click()};const backToTop=document.querySelector("#back-to-top"),toggleTop=()=>backToTop.classList.toggle("visible",window.scrollY>200);window.addEventListener("scroll",toggleTop,{passive:true});toggleTop();</script></main></body></html>' >> "$tmp"
  mv -f -- "$tmp" "$html_file"
  html_checkpoint_ms=$(( $(date +%s) * 1000 ))
  open_url "$(pwd)/${html_file#./}"
  printf 'Generated %s\n' "$html_file"
  (( failures == 0 ))
}

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
      if (( $# == 0 )) || [[ -z "$1" ]]; then
        printf 'Error: -p requires a non-empty path argument\n' >&2
        exit 1
      fi
      output_path=$1
      ;;
    -U)
      do_update=1
      ;;
    -o)
      if [[ -n "$open_mode" ]]; then
        printf 'Error: -o and -O cannot be combined\n' >&2
        exit 1
      fi
      open_mode="check"
      ;;
    -O)
      if [[ -n "$open_mode" ]]; then
        printf 'Error: -o and -O cannot be combined\n' >&2
        exit 1
      fi
      open_mode="open"
      ;;
    --html)
      if [[ -n "$open_mode" ]]; then
        printf 'Error: --html cannot be combined with -o or -O\n' >&2
        exit 1
      fi
      open_mode="html"
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

if [[ -n "$current_url" ]]; then
  print -r -- "$current_url" >| "$url_file"
elif [[ -f "$url_file" ]]; then
  IFS= read -r current_url < "$url_file" || current_url=""
fi

run_url=$current_url
if [[ -n "$temp_url" ]]; then
  run_url=$temp_url
fi

if (( do_update )); then
  ytdlp_exe=$(ytdlp_path) || {
    printf 'Error: yt-dlp binary not found next to this script\n' >&2
    exit 1
  }
  run_cmd "$ytdlp_exe" -U
  update_status=0
  update_self "yy.zsh" '#!/bin/zsh' || update_status=1
  exit $update_status
fi

open_failures=0
checkpoint_after_checks_ms=0
if [[ -n "$open_mode" ]]; then
  if [[ "$open_mode" == "html" ]]; then
    generate_html || open_failures=1
    if (( open_failures == 0 )); then checkpoint_after_checks_ms=$html_checkpoint_ms; fi
  else
    run_open_mode "$open_mode" || open_failures=1
    if [[ "$open_mode" == "check" ]]; then checkpoint_after_checks_ms=$(( $(date +%s) * 1000 )); fi
  fi
fi

if (( set_checkpoint )); then
  if [[ "$open_mode" == "check" ]] &&
      should_skip_checkpoint "$open_failure_count" "$open_channel_count"; then
    printf 'Checkpoint not updated: %s of %s channel check(s) failed\n' \
      "$open_failure_count" "$open_channel_count" >&2
  else
    if (( checkpoint_after_checks_ms > 0 )); then
      set_checkpoint_at "$checkpoint_after_checks_ms"
    else
      set_checkpoint_now
    fi
  fi
fi

if [[ -n "$open_mode" ]] || (( set_checkpoint )); then
  exit $open_failures
fi

if [[ -n "$run_url" ]]; then
  ytdlp_exe=$(ytdlp_path) || {
    printf 'Error: yt-dlp binary not found next to this script\n' >&2
    exit 1
  }
  run_cmd "$ytdlp_exe" --cookies ./cookies.txt --paths "$output_path" "$run_url"
else
  printf 'Error: no URL provided, and %s does not exist or is empty\n' "$url_file" >&2
  exit 1
fi

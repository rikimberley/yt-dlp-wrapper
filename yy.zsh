#!/bin/zsh

# yy.zsh - convenience wrapper around ./yt-dlp
#
# Description:
# - stores a positional URL into ./current_url.txt and downloads it
# - uses -t <temp_url> to download a one-off URL without persisting it
# - uses -U to update ./yt-dlp and refresh this script from the head of master
#   on GitHub, then skip any download
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
#   ./yy.zsh 'https://example.com/video'
#   ./yy.zsh -t 'https://example.com/one-off'
#   ./yy.zsh 'https://saved.example.com/video' -t 'https://example.com/one-off'
#   ./yy.zsh -U
#   ./yy.zsh -o
#   ./yy.zsh -O
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
# Head of master in the wrapper's own repo, used by -U to refresh this script.
script_raw_base="https://raw.githubusercontent.com/rikimberley/yt-dlp-wrapper/master"
current_url=""
temp_url=""
do_update=0
open_mode=""
set_checkpoint=0

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
  out=$("$exe" --ignore-config --no-warnings --flat-playlist \
    --playlist-items 0 --print 'playlist:%(channel_id)s' "$url" 2>/dev/null) || out=""
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
# Prints -1 when the feed could not be read and 0 when it holds no entries —
# the two must stay distinguishable, or a network failure reads as an empty
# channel. That feed omits members-only videos, so it is public-by-construction.
feed_newest_ms() {
  local channel_id=$1 feed feed_url ts epoch newest=0 seen=0
  feed_url="https://www.youtube.com/feeds/videos.xml?channel_id=${channel_id}"
  if ! feed=$(fetch_url "$feed_url" "video feed for ${channel_id}"); then
    print -r -- -1
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
    print -r -- -1
    return 0
  fi
  print -r -- "$newest"
}

# Print the epoch-ms publish time of the newest public video on a channel,
# 0 when the channel genuinely has none, or -1 when the check could not be
# completed.
newest_public_ms() {
  local handle=$1 channel_url=$2 newest channel_id source
  if ! resolve_channel_id "$handle" "$channel_url"; then
    print -r -- -1
    return 0
  fi
  channel_id=$resolved_channel_id
  source=$resolved_source
  newest=$(feed_newest_ms "$channel_id")

  # An empty feed for a cached id usually means the handle now points at a
  # different channel, so drop the stale entry and resolve once more.
  if (( newest <= 0 )) && [[ "$source" == "cache" ]]; then
    store_channel_id "$handle" ""
    if ! resolve_channel_id "$handle" "$channel_url" "skip-cache"; then
      print -r -- -1
      return 0
    fi
    channel_id=$resolved_channel_id
    newest=$(feed_newest_ms "$channel_id")
  fi

  if (( newest == 0 )); then
    printf 'Warning: no <published> entries in the feed for %s (@%s)\n' \
      "$channel_id" "$handle" >&2
  fi
  print -r -- "$newest"
}

# Overwrite ./checkpoint.txt with the current time in epoch milliseconds.
set_checkpoint_now() {
  local now=$(( $(date +%s) * 1000 ))
  print -r -- "$now" >| "$checkpoint_file"
  printf 'Checkpoint updated: %s\n' "$now"
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
    newest=$(newest_public_ms "$channel" "$channel_url")
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
if [[ -n "$open_mode" ]]; then
  run_open_mode "$open_mode" || open_failures=1
fi

if (( set_checkpoint )); then
  if [[ "$open_mode" == "check" ]] &&
      should_skip_checkpoint "$open_failure_count" "$open_channel_count"; then
    printf 'Checkpoint not updated: %s of %s channel check(s) failed\n' \
      "$open_failure_count" "$open_channel_count" >&2
  else
    set_checkpoint_now
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
  run_cmd "$ytdlp_exe" --cookies ./cookies.txt --paths ./t "$run_url"
else
  printf 'Error: no URL provided, and %s does not exist or is empty\n' "$url_file" >&2
  exit 1
fi

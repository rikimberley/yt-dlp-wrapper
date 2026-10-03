#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# yy.py - convenience wrapper around ./yt-dlp
#
# Single-implementation replacement for the paired yy.zsh / yy.ps1 scripts.
# Both of those are reimplemented here once; the yy.zsh and yy.ps1 files next
# to this one are thin launchers that only locate a Python interpreter and
# hand off, so there is no behaviour to keep in sync between platforms.
#
# Standard library only, on purpose: the vendored yt-dlp binary needs no
# setup, and neither should this. Never add a pip dependency, a venv, or a
# build step.
#
# Floor is Python 3.9 (the version shipped by the macOS Command Line Tools).
# Target the floor rather than an exact version, so whatever interpreter is
# already installed is most likely to satisfy it.
# ---------------------------------------------------------------------------

import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

MIN_PYTHON = (3, 9)

if sys.version_info < MIN_PYTHON:
    sys.stderr.write(
        "Error: Python %s or newer is required (found %s)\n"
        % (".".join(map(str, MIN_PYTHON)), sys.version.split()[0])
    )
    raise SystemExit(1)


# ---------------------------------------------------------------------------
# Console setup
# ---------------------------------------------------------------------------

def _configure_streams():
    """Force UTF-8 on stdout/stderr.

    Windows consoles still default to a legacy code page, so printing a
    non-ASCII channel handle raises UnicodeEncodeError and kills the run.
    errors='replace' means a console that genuinely cannot render a glyph
    degrades to a placeholder instead of aborting a download.
    """
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            try:
                reconfigure(encoding="utf-8", errors="replace")
            except (ValueError, OSError):
                pass


def _enable_ansi():
    """Turn on ANSI escape handling, including on Windows 10+ consoles.

    yy.ps1 had to drop colour entirely because Windows PowerShell 5.1 prints
    escapes literally. Driving the console mode directly removes that
    divergence, so both platforms get the same coloured output.
    """
    if os.name != "nt":
        return
    try:
        import ctypes

        kernel32 = ctypes.windll.kernel32
        for handle_id in (-11, -12):  # stdout, stderr
            handle = kernel32.GetStdHandle(handle_id)
            mode = ctypes.c_uint32()
            if kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
                kernel32.SetConsoleMode(handle, mode.value | 0x0004)
    except Exception:
        pass


_configure_streams()
_enable_ansi()

USE_COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


# ---------------------------------------------------------------------------
# Paths
#
# This file may live in a py/ subdirectory during the migration and at the
# repository root afterwards, and the state files, cookie jar and yt-dlp
# binary always sit together at the root. Resolving the base directory by
# search rather than by a fixed relative path means the same code works in
# both layouts with no edit at cutover.
# ---------------------------------------------------------------------------

SCRIPT_PATH = Path(__file__).resolve()
SCRIPT_DIR = SCRIPT_PATH.parent


def resolve_base_dir():
    override = os.environ.get("YY_BASE")
    if override:
        return Path(override).expanduser().resolve()
    candidates = [SCRIPT_DIR] + list(SCRIPT_DIR.parents)[:2]
    for candidate in candidates:
        if (candidate / "yt-dlp").is_file() or (candidate / "yt-dlp.exe").is_file():
            return candidate
    # A fresh clone has no binary yet; fall back to the repository root so the
    # state files are still found in the right place.
    for candidate in candidates:
        if (candidate / ".git").exists():
            return candidate
    return SCRIPT_DIR


BASE_DIR = resolve_base_dir()

URL_FILE = BASE_DIR / "current_url.txt"
CHANNELS_FILE = BASE_DIR / "channel-ids.txt"
CHANNEL_ID_CACHE_FILE = BASE_DIR / "channel-id-cache.txt"
CHECKPOINT_FILE = BASE_DIR / "checkpoint.txt"
COOKIES_FILE = BASE_DIR / "cookies.txt"
CHANNEL_STATUS_FILE = BASE_DIR / "channel-check-status.json"
DOWNLOADED_VIDEOS_FILE = BASE_DIR / "downloaded-videos.json"
HTML_VIDEO_CACHE_FILE = BASE_DIR / "html-video-cache.json"
TEMPORARY_DIRECTORY = BASE_DIR / ".tmp"


def display_path(path):
    """Render a path the way the shell wrappers did, relative to the base."""
    try:
        return "./" + str(Path(path).resolve().relative_to(BASE_DIR))
    except ValueError:
        return str(path)

DEFAULT_OUTPUT_PATH = "./t"

# Channel status and cache records untouched for this long are dropped, and
# download history entries expire on the same schedule.
STALE_CHANNEL_TTL_MS = 45 * 86400 * 1000
DOWNLOADED_VIDEO_TTL_SEC = 45 * 86400

UC_ID_RE = re.compile(r"^UC[A-Za-z0-9_-]+$")
VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]+$")

USER_AGENT = "Mozilla/5.0"
ACCEPT_LANGUAGE = "en-US,en;q=0.9"
# Pre-accepted consent cookies: without them YouTube can answer a channel page
# with a consent interstitial that carries no channel_id, which looks exactly
# like "channel has no public videos". No account cookies are ever sent here;
# the channel-check path stays logged-out so the Atom feed remains
# public-by-construction and never exposes members-only videos.
CONSENT_COOKIE = "SOCS=CAI; CONSENT=YES+cb"
FETCH_TIMEOUT_SEC = 45
FETCH_ATTEMPTS = 3
YTDLP_TIMEOUT_SEC = 30
YTDLP_ATTEMPTS = 1
YTDLP_DEADLINE_SEC = 30
MAX_THREADS = 16
# Once this many channels have exhausted their feed retries in one run, stop
# fetching feeds entirely and go straight to the uploads fallback.
FEED_FAILURE_LIMIT = 3
# A yt-dlp scan is forced at least this often, however quiet the public feed
# looks, so a channel can never drift indefinitely on feed evidence alone.
HTML_FULL_SCAN_INTERVAL_MS = 24 * 60 * 60 * 1000
# yt-dlp stops with 101 when --break-match-filters trips, which is the normal
# way a bounded scan ends and must not be read as a failure.
YTDLP_BREAK_RC = 101
# Availability values that must never be offered for download.
NON_PUBLIC_AVAILABILITY = frozenset(("subscriber_only", "private", "premium_only"))

SCRIPT_RAW_BASE = (
    "https://raw.githubusercontent.com/rikimberley/yt-dlp-wrapper/master/py"
)


# ---------------------------------------------------------------------------
# Text file helpers
#
# Every plain-text state file is UTF-8 with no BOM and LF endings, and every
# reader tolerates a stray BOM or CRLF anyway, so a file copied from the other
# machine still reads correctly. Always go through these two helpers; a bare
# open() defaults to the platform code page on Windows below Python 3.15.
# ---------------------------------------------------------------------------

def read_text_file(path):
    """Return the file's contents, or None if it does not exist."""
    try:
        with open(path, "r", encoding="utf-8-sig", newline="") as handle:
            return handle.read()
    except FileNotFoundError:
        return None


def write_text_file(path, lines):
    """Write lines as UTF-8, no BOM, LF endings, with a trailing newline."""
    text = "".join(line + "\n" for line in lines)
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)


def trim(value):
    """Strip surrounding whitespace plus a stray BOM or CR."""
    if value is None:
        return ""
    return value.replace("\ufeff", "").replace("\r", "").strip()


def read_first_line(path):
    content = read_text_file(path)
    if content is None:
        return None
    for line in content.splitlines():
        return trim(line)
    return ""


# ---------------------------------------------------------------------------
# Checkpoint
# ---------------------------------------------------------------------------

def now_ms():
    return int(time.time() * 1000)


def now_sec():
    return int(time.time())


def read_checkpoint_ms():
    """Return the checkpoint in epoch milliseconds.

    A missing or empty file is not an error: it reads as 0, meaning "no
    checkpoint", so every video counts as new. Only non-empty, non-numeric
    content is an error. 12 or more digits is already milliseconds; anything
    shorter is seconds.
    """
    raw = read_first_line(CHECKPOINT_FILE)
    if raw is None:
        sys.stderr.write(
            "Warning: %s does not exist; continuing with no checkpoint (0)\n"
            % display_path(CHECKPOINT_FILE)
        )
        return 0
    digits = re.sub(r"[^0-9]", "", raw)
    if not digits:
        if raw:
            sys.stderr.write(
                "Error: %s does not contain a numeric timestamp\n"
                % display_path(CHECKPOINT_FILE)
            )
            return None
        sys.stderr.write(
            "Warning: %s is empty; continuing with no checkpoint (0)\n"
            % display_path(CHECKPOINT_FILE)
        )
        return 0
    value = int(digits)
    if len(digits) < 12:
        value *= 1000
    return value


def set_checkpoint_at(timestamp_ms):
    write_text_file(CHECKPOINT_FILE, [str(timestamp_ms)])
    print("Checkpoint updated: %s" % timestamp_ms)


# ---------------------------------------------------------------------------
# JSON state files
#
# Every one of these is optional: a missing or unreadable file degrades to the
# empty state with a warning, so a fresh deployment directory works. Writes go
# to a temp file in .tmp and are then renamed into place, so a reader never
# sees a half-written file. os.replace is atomic on Windows too, as long as
# both paths are on the same volume.
# ---------------------------------------------------------------------------

def coerce_int(value, default=0):
    """Accept an int or a numeric string; anything else falls back."""
    if isinstance(value, bool):
        return default
    if isinstance(value, int):
        return value
    if isinstance(value, str) and re.fullmatch(r"[0-9]+", value.strip()):
        return int(value)
    return default


def coerce_str(value):
    """Treat JSON null as an absent string, matching the shell readers."""
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return str(value)


def sanitize_field(value):
    """Flatten tabs and newlines, which would corrupt a TSV-shaped record."""
    return re.sub(r"[\t\r\n]", " ", coerce_str(value))


def read_json_file(path, missing_message=None):
    """Return parsed JSON, or None if absent or unusable."""
    content = read_text_file(path)
    if content is None:
        if missing_message:
            print(missing_message)
        return None
    if not content.strip():
        return None
    try:
        return json.loads(content)
    except ValueError as error:
        sys.stderr.write(
            "Warning: %s is not valid JSON (%s); continuing with no data\n"
            % (display_path(path), error)
        )
        return None


def write_json_file(path, payload):
    """Atomically write JSON as UTF-8, no BOM, LF, with literal non-ASCII.

    ensure_ascii is off deliberately. Escaping to \\uXXXX is also valid JSON,
    but keeping the text literal means the file stays readable and matches
    what the zsh writer produces.
    """
    text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    write_atomic(path, text)


def write_atomic(path, text):
    try:
        TEMPORARY_DIRECTORY.mkdir(parents=True, exist_ok=True)
        temp = TEMPORARY_DIRECTORY / ("%s.new.%d" % (Path(path).name, os.getpid()))
        with open(temp, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
        os.replace(str(temp), str(path))
        return True
    except OSError as error:
        sys.stderr.write(
            "Warning: could not write %s (%s)\n" % (display_path(path), error)
        )
        try:
            os.remove(str(temp))
        except (OSError, NameError, UnboundLocalError):
            pass
        return False


# --- channel-ids.txt -------------------------------------------------------

def read_channels():
    """Return the configured channel handles, in order, deduplicated.

    Blank lines and # comments are skipped and a leading @ is optional, so the
    file can be pasted straight from YouTube URLs. Returns None when the file
    is missing, which is a hard error for every mode that needs it.
    """
    content = read_text_file(CHANNELS_FILE)
    if content is None:
        sys.stderr.write("Error: %s does not exist\n" % display_path(CHANNELS_FILE))
        return None
    channels = []
    seen = set()
    for line in content.splitlines():
        entry = trim(line)
        if not entry or entry.startswith("#"):
            continue
        entry = entry.lstrip("@")
        if not entry or entry in seen:
            continue
        seen.add(entry)
        channels.append(entry)
    return channels


def write_channels(channels):
    write_atomic(CHANNELS_FILE, "".join(line + "\n" for line in channels))


# --- channel-id-cache.txt --------------------------------------------------

def read_channel_id_cache():
    """Return {handle: UC id}. Fields are trimmed, so a file written by an
    older yy.ps1 with a BOM and CRLF still matches."""
    content = read_text_file(CHANNEL_ID_CACHE_FILE)
    if content is None:
        return {}
    cache = {}
    for line in content.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        handle = trim(parts[0])
        channel_id = trim(parts[1])
        if handle and UC_ID_RE.match(channel_id):
            cache[handle] = channel_id
    return cache


def write_channel_id_cache(cache):
    """Sorted by raw bytes, matching the shell's LC_ALL=C sort."""
    lines = [
        "%s\t%s" % (handle, channel_id)
        for handle, channel_id in sorted(
            cache.items(), key=lambda item: item[0].encode("utf-8")
        )
    ]
    write_atomic(CHANNEL_ID_CACHE_FILE, "".join(line + "\n" for line in lines))


def cached_channel_id(handle):
    return read_channel_id_cache().get(handle)


def store_channel_id(handle, channel_id):
    cache = read_channel_id_cache()
    if channel_id:
        cache[handle] = channel_id
    else:
        cache.pop(handle, None)
    write_channel_id_cache(cache)


# --- channel-check-status.json ---------------------------------------------

def read_channel_check_status():
    """Return {channel: {checked_ms, latest_video_ms, thumbnail}}.

    Channels not checked for 45 days are dropped and the file is rewritten.
    """
    data = read_json_file(CHANNEL_STATUS_FILE)
    status = {}
    if isinstance(data, dict):
        for channel, record in data.items():
            if not channel or not isinstance(record, dict):
                continue
            status[channel] = {
                "checked_ms": coerce_int(record.get("checked_ms")),
                "latest_video_ms": coerce_int(record.get("latest_video_ms")),
                "thumbnail": coerce_str(record.get("thumbnail")),
            }
    cutoff_ms = now_ms() - STALE_CHANNEL_TTL_MS
    kept = {
        channel: record
        for channel, record in status.items()
        if not (0 < record["checked_ms"] < cutoff_ms)
    }
    if len(kept) != len(status):
        save_channel_check_status(kept)
    return kept


def save_channel_check_status(status):
    write_json_file(CHANNEL_STATUS_FILE, status)


# --- html-video-cache.json -------------------------------------------------

def read_html_video_cache():
    """Return {channel: {channel_id, checked_ms, last_full_scan_ms,
    feed_newest_ms, entries: [...]}}.

    Entries without an id are dropped, titles are flattened, and channels not
    checked for 45 days are removed and the file rewritten.
    """
    data = read_json_file(HTML_VIDEO_CACHE_FILE)
    cache = {}
    if isinstance(data, dict):
        for channel, record in data.items():
            if not channel or not isinstance(record, dict):
                continue
            entries = []
            raw_entries = record.get("entries")
            # A one-element list can be serialized as a bare object; accept it.
            if isinstance(raw_entries, dict):
                raw_entries = [raw_entries]
            if isinstance(raw_entries, list):
                for entry in raw_entries:
                    if not isinstance(entry, dict):
                        continue
                    video_id = coerce_str(entry.get("id"))
                    if not video_id:
                        continue
                    entries.append(
                        {
                            "id": video_id,
                            "url": coerce_str(entry.get("url")),
                            "title": sanitize_field(entry.get("title")),
                            "timestamp_ms": coerce_int(entry.get("timestamp_ms")),
                            "availability": coerce_str(entry.get("availability")),
                        }
                    )
            cache[channel] = {
                "channel_id": coerce_str(record.get("channel_id")),
                "checked_ms": coerce_int(record.get("checked_ms")),
                "last_full_scan_ms": coerce_int(record.get("last_full_scan_ms")),
                "feed_newest_ms": coerce_int(record.get("feed_newest_ms")),
                "entries": entries,
            }
    cutoff_ms = now_ms() - STALE_CHANNEL_TTL_MS
    kept = {
        channel: record
        for channel, record in cache.items()
        if not (0 < record["checked_ms"] < cutoff_ms)
    }
    if len(kept) != len(cache):
        save_html_video_cache(kept)
    return kept


def save_html_video_cache(cache):
    write_json_file(HTML_VIDEO_CACHE_FILE, cache)


# --- downloaded-videos.json ------------------------------------------------

def downloaded_key(record):
    return (record["channel_id"], record["video_id"], record["target"])


def read_downloaded_videos():
    """Return the download history as a list of validated records.

    Invalid and expired records are dropped and the file is rewritten. A
    top-level object is accepted as a one-element list, because a JSON writer
    can unwrap a single-element array and PowerShell's reader tolerates that
    shape; refusing it would silently read the whole history as empty.
    """
    data = read_json_file(
        DOWNLOADED_VIDEOS_FILE,
        missing_message="Downloaded-video history not found; starting empty.",
    )
    # A one-element list can be serialized as a bare object. Accept it, and
    # remember so the file gets rewritten in list form below.
    unwrapped = isinstance(data, dict)
    if unwrapped:
        data = [data]
    if not isinstance(data, list):
        data = []

    cutoff_sec = now_sec() - DOWNLOADED_VIDEO_TTL_SEC
    records = []
    seen = set()
    invalid = 0
    expired = 0
    duplicates = 0

    for item in data:
        if not isinstance(item, dict):
            invalid += 1
            continue
        channel_id = coerce_str(item.get("channel_id"))
        video_id = coerce_str(item.get("video_id"))
        target = coerce_str(item.get("target"))
        epoch = coerce_int(item.get("download_epoch"), -1)
        if (
            not UC_ID_RE.match(channel_id)
            or not VIDEO_ID_RE.match(video_id)
            or target not in ("y1", "y2")
            or epoch < 0
        ):
            invalid += 1
            continue
        if epoch < cutoff_sec:
            expired += 1
            continue
        record = {
            "channel_id": channel_id,
            "video_id": video_id,
            "target": target,
            "download_epoch": epoch,
        }
        key = downloaded_key(record)
        if key in seen:
            duplicates += 1
            continue
        seen.add(key)
        records.append(record)

    print("Loaded %s downloaded-video record(s)." % len(records))
    if expired:
        print("Pruned %s downloaded-video record(s) older than 45 days." % expired)
    if invalid:
        print("Pruned %s invalid downloaded-video record(s)." % invalid)
    if expired or invalid or duplicates or unwrapped:
        save_downloaded_videos(records)
    return records


def save_downloaded_videos(records):
    write_json_file(DOWNLOADED_VIDEOS_FILE, records)
    print("Saved %s downloaded-video record(s)." % len(records))


# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------

def run_cmd(cmd):
    rendered = " ".join(shlex.quote(str(part)) for part in cmd)
    if USE_COLOR:
        print("\033[34mRunning: %s\033[0m" % rendered)
    else:
        print("Running: %s" % rendered)
    # Python block-buffers stdout when it is not a terminal, so without an
    # explicit flush the child's output appears before the line announcing it.
    sys.stdout.flush()
    sys.stderr.flush()
    completed = subprocess.run([str(part) for part in cmd], cwd=str(BASE_DIR))
    return completed.returncode


def ytdlp_path():
    for name in ("yt-dlp.exe", "yt-dlp"):
        candidate = BASE_DIR / name
        if candidate.is_file():
            return candidate
    return None


def run_ytdlp_metadata(args, deadline_sec=YTDLP_DEADLINE_SEC, progress_label=None):
    """Run yt-dlp and capture stdout.

    deadline_sec of 0 waits forever, which a full channel scan legitimately
    needs. Returns (returncode, stdout); a timeout reports returncode 124 to
    match the shell's convention.
    """
    cmd = [str(part) for part in args]
    try:
        completed = subprocess.run(
            cmd,
            cwd=str(BASE_DIR),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE if not progress_label else None,
            timeout=deadline_sec if deadline_sec > 0 else None,
        )
    except subprocess.TimeoutExpired:
        sys.stderr.write(
            "Warning: yt-dlp metadata probe timed out after %s seconds\n"
            % deadline_sec
        )
        return 124, ""
    except OSError as error:
        sys.stderr.write("Warning: could not run yt-dlp (%s)\n" % error)
        return 1, ""
    out = completed.stdout.decode("utf-8", "replace") if completed.stdout else ""
    return completed.returncode, out


# ---------------------------------------------------------------------------
# HTTP fetching
#
# Requests advertise gzip and are retried, because a single transient hiccup
# would otherwise be indistinguishable from an empty channel. A channel page
# is ~1.2 MB raw but ~270 KB compressed, and the uncompressed transfer is what
# used to time out and surface as "no public videos found".
# ---------------------------------------------------------------------------

class FetchResult:
    def __init__(self, body=None, status=0, error=""):
        self.body = body
        self.status = status
        self.error = error

    @property
    def ok(self):
        return self.body is not None


def fetch_url_once(url, send_consent=True):
    headers = {
        "User-Agent": USER_AGENT,
        "Accept-Language": ACCEPT_LANGUAGE,
        "Accept-Encoding": "gzip, deflate",
    }
    if send_consent:
        headers["Cookie"] = CONSENT_COOKIE
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=FETCH_TIMEOUT_SEC) as response:
            raw = response.read()
            encoding = (response.headers.get("Content-Encoding") or "").lower()
            if encoding == "gzip":
                import gzip

                raw = gzip.decompress(raw)
            elif encoding == "deflate":
                import zlib

                try:
                    raw = zlib.decompress(raw)
                except zlib.error:
                    raw = zlib.decompress(raw, -zlib.MAX_WBITS)
            return FetchResult(raw.decode("utf-8", "replace"), response.status or 200)
    except urllib.error.HTTPError as error:
        return FetchResult(None, error.code, "HTTP %s" % error.code)
    except Exception as error:  # URLError, timeout, bad gzip, ...
        return FetchResult(None, 0, str(error) or error.__class__.__name__)


def fetch_url(url, what, send_consent=True):
    """Fetch with retries. Returns the body, or None when every attempt failed."""
    for attempt in range(1, FETCH_ATTEMPTS + 1):
        if attempt > 1:
            time.sleep(attempt - 1)
        result = fetch_url_once(url, send_consent)
        if result.ok:
            return result.body
        sys.stderr.write(
            "Warning: fetch of %s failed (attempt %s/%s): %s\n"
            % (what, attempt, FETCH_ATTEMPTS, result.error)
        )
        # A settled 4xx is an answer, not a hiccup; retrying only delays the
        # correct failure report. 408 and 429 are explicitly retryable.
        if 400 <= result.status < 500 and result.status not in (408, 429):
            break
    sys.stderr.write(
        "Warning: giving up on %s (%s): %s\n" % (what, url, result.error)
    )
    return None


def fetch_urls_concurrent(url_map, what, send_consent=True):
    """Fetch many URLs at once. Only successfully fetched keys are returned."""
    if not url_map:
        return {}
    from concurrent.futures import ThreadPoolExecutor

    workers = max(1, min(MAX_THREADS, len(url_map)))
    bodies = {}
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {
            key: pool.submit(fetch_url, url, "%s for %s" % (what, key), send_consent)
            for key, url in url_map.items()
        }
        for key, future in futures.items():
            try:
                body = future.result()
            except Exception as error:
                sys.stderr.write(
                    "Warning: fetch of %s for %s failed: %s\n" % (what, key, error)
                )
                body = None
            if body is not None:
                bodies[key] = body
    return bodies


# ---------------------------------------------------------------------------
# Self update
#
# A copy living outside a git clone (the Windows box) has no other way to
# track the repo, so -U refreshes the files in place from the head of master.
#
# Unlike the shells, which each refresh only themselves, there are now two
# pieces: the implementation (yy.py) and the launcher that found an
# interpreter for it. Refreshing one without the other can pair a new launcher
# with an old implementation, so both are refreshed in the same run.
#
# Only launchers that are *already* present are refreshed. A deployed Windows
# copy has yy.ps1 and no yy.zsh, and -U is not the place to start handing it
# files it never had.
# ---------------------------------------------------------------------------

# Each payload must start with its sentinel. A captive portal or a 404 page
# written over one of these would leave the machine with no working wrapper at
# all -- and no way to self-update out of it.
UPDATE_SENTINELS = (
    ("yy.py", "#!/usr/bin/env python3"),
    ("yy.zsh", "#!/bin/zsh"),
    ("yy.ps1", "#!/usr/bin/env pwsh"),
)


def update_self_file(name, sentinel):
    """Refresh one file beside this script. Returns True when it is current."""
    url = "%s/%s" % (SCRIPT_RAW_BASE, name)
    body = fetch_url(url, "%s from master" % name, send_consent=False)
    if body is None:
        sys.stderr.write("Warning: could not refresh %s from master\n" % name)
        return False
    if not body.startswith(sentinel):
        sys.stderr.write(
            "Warning: refusing to overwrite %s: fetched body does not start "
            "with %s\n" % (name, sentinel)
        )
        return False

    target = SCRIPT_DIR / name
    if read_text_file(target) == body:
        print("%s is already up to date" % name)
        return True

    # Stage in the *same directory* as the target: os.replace is only atomic
    # within one filesystem, and an interrupted write must never be able to
    # truncate the file that is running.
    temp_path = SCRIPT_DIR / ("%s.new.%s" % (name, os.getpid()))
    try:
        with open(temp_path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(body)
        if target.exists():
            # Carry the execute bit across, or a refreshed yy.zsh stops being
            # runnable as ./yy.zsh.
            shutil.copymode(str(target), str(temp_path))
            TEMPORARY_DIRECTORY.mkdir(parents=True, exist_ok=True)
            try:
                shutil.copy2(
                    str(target), str(TEMPORARY_DIRECTORY / ("%s.bak" % name))
                )
            except OSError as error:
                sys.stderr.write(
                    "Warning: could not save a backup copy of %s: %s\n"
                    % (name, error)
                )
        os.replace(str(temp_path), str(target))
    except OSError as error:
        sys.stderr.write("Warning: could not write %s: %s\n" % (name, error))
        try:
            temp_path.unlink()
        except OSError:
            pass
        return False

    print("Updated %s from master (previous copy saved in .tmp)" % name)
    return True


def run_update():
    """-U: update the yt-dlp binary, then this wrapper. Never downloads."""
    exe = ytdlp_path()
    if exe is None:
        sys.stderr.write("Error: yt-dlp binary not found next to this script\n")
        return 1
    # The shells ignore yt-dlp's own exit code here too: a failed binary
    # update must not stop the wrapper from being refreshed.
    run_cmd([exe, "-U"])

    ok = True
    for name, sentinel in UPDATE_SENTINELS:
        if name != SCRIPT_PATH.name and not (SCRIPT_DIR / name).exists():
            continue
        if not update_self_file(name, sentinel):
            ok = False
    return 0 if ok else 1


# ---------------------------------------------------------------------------
# Channel identity and the public-video feed
# ---------------------------------------------------------------------------

def channel_url_for(channel):
    """A raw UC… id is used directly; anything else is treated as a handle."""
    if UC_ID_RE.match(channel):
        return "https://www.youtube.com/channel/%s/videos" % channel
    return "https://www.youtube.com/@%s/videos" % urllib.parse.quote(
        channel, safe="._~-"
    )


CHANNEL_ID_PATTERNS = [
    re.compile(r"channel_id=(UC[A-Za-z0-9_-]+)"),
    re.compile(r'"externalId":"(UC[A-Za-z0-9_-]+)"'),
    re.compile(r"/channel/(UC[A-Za-z0-9_-]+)"),
]


def scrape_channel_id(html):
    for pattern in CHANNEL_ID_PATTERNS:
        match = pattern.search(html)
        if match:
            return match.group(1)
    return None


def channel_id_via_ytdlp(url):
    """Last-resort resolution using yt-dlp, which tracks YouTube's page layout
    far better than the regexes above. Stays logged-out, so the result remains
    public-by-construction."""
    exe = ytdlp_path()
    if exe is None:
        return None
    rc, out = run_ytdlp_metadata(
        [
            exe,
            "--ignore-config",
            "--no-warnings",
            "--socket-timeout",
            YTDLP_TIMEOUT_SEC,
            "--retries",
            YTDLP_ATTEMPTS,
            "--extractor-retries",
            YTDLP_ATTEMPTS,
            "--flat-playlist",
            "--playlist-items",
            "0",
            "--print",
            "playlist:%(channel_id)s",
            url,
        ]
    )
    if rc != 0:
        return None
    for line in out.splitlines():
        line = trim(line)
        if UC_ID_RE.match(line):
            return line
    return None


def resolve_channel_id(handle, channel_url, skip_cache=False):
    """Resolve a handle to its UC id, cheapest method first.

    Returns (channel_id, source) where source is 'cache', 'page' or 'yt-dlp',
    or (None, None) when every method failed. Every non-cache result is
    written through to the cache.
    """
    if not skip_cache:
        cached = cached_channel_id(handle)
        if cached:
            return cached, "cache"

    html = fetch_url(channel_url, "channel page for @%s" % handle)
    if html is not None:
        channel_id = scrape_channel_id(html)
        if channel_id:
            store_channel_id(handle, channel_id)
            return channel_id, "page"
        sys.stderr.write("Warning: no channel_id found on %s\n" % channel_url)

    channel_id = channel_id_via_ytdlp(channel_url)
    if channel_id:
        store_channel_id(handle, channel_id)
        return channel_id, "yt-dlp"

    sys.stderr.write("Warning: could not resolve a channel id for @%s\n" % handle)
    return None, None


PUBLISHED_RE = re.compile(r"<published>([^<]*)</published>")

# The sentinel prefix matters: yt-dlp interleaves its own chatter on stdout,
# so a bare "<digits>:<word>" line could otherwise be mistaken for a record.
FALLBACK_ROW_RE = re.compile(r"^fallback:([0-9]+):public$")


def iso_to_epoch_ms(timestamp):
    """Parse an Atom <published> value into epoch milliseconds, or None."""
    text = trim(timestamp)
    if not text:
        return None
    # Python 3.9's fromisoformat rejects 'Z' and sub-second precision varies,
    # so normalise both before parsing.
    normalised = text
    if normalised.endswith("Z"):
        normalised = normalised[:-1] + "+00:00"
    from datetime import datetime, timezone

    for candidate in (normalised, re.sub(r"\.\d+", "", normalised)):
        try:
            parsed = datetime.fromisoformat(candidate)
        except ValueError:
            continue
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return int(parsed.timestamp() * 1000)
    return None


def feed_newest_ms_from_body(feed, what):
    """Newest <published> in an Atom feed body, in epoch ms, or 0 for none.

    The entries are not reliably date-sorted, so every one is scanned.
    """
    if "<feed" not in feed or "</feed>" not in feed:
        sys.stderr.write("Warning: malformed video feed for %s\n" % what)
        return 0
    newest = 0
    for raw in PUBLISHED_RE.findall(feed):
        epoch_ms = iso_to_epoch_ms(raw)
        if epoch_ms is None:
            sys.stderr.write(
                "Warning: unparsable <published> value '%s' for %s\n" % (raw, what)
            )
            continue
        newest = max(newest, epoch_ms)
    return newest


def feed_url_for(channel_id):
    return "https://www.youtube.com/feeds/videos.xml?channel_id=%s" % channel_id


def feed_newest_ms(channel_id):
    """Newest public video in a channel's Atom feed, in epoch ms.

    Returns -1 when the feed could not be read or held nothing usable, which
    must stay distinguishable from a real timestamp. This feed omits
    members-only videos, so no extra filtering is needed and no cookies are
    sent.
    """
    feed = fetch_url(
        feed_url_for(channel_id), "video feed for %s" % channel_id, send_consent=False
    )
    if feed is None:
        return -1
    newest = feed_newest_ms_from_body(feed, channel_id)
    return newest if newest > 0 else -1


def ytdlp_newest_public_ms(channel_id):
    """Fallback for when the Atom feed is unavailable.

    Resolves the five newest entries of the channel's UU… uploads playlist and
    keeps only those explicitly marked public, so a members-only or unlisted
    upload can never advance the checkpoint. Returns -1 when the probe failed
    and 0 when the channel genuinely has no public video.
    """
    exe = ytdlp_path()
    if exe is None:
        sys.stderr.write("Warning: yt-dlp is not available for the uploads fallback\n")
        return -1
    uploads = "UU" + channel_id[2:]
    rc, out = run_ytdlp_metadata(
        [
            exe,
            "--ignore-config",
            "--no-warnings",
            "--socket-timeout",
            YTDLP_TIMEOUT_SEC,
            "--retries",
            YTDLP_ATTEMPTS,
            "--extractor-retries",
            YTDLP_ATTEMPTS,
            "--skip-download",
            "--playlist-items",
            "1:5",
            "--print",
            "fallback:%(timestamp)s:%(availability)s",
            "https://www.youtube.com/playlist?list=%s" % uploads,
        ]
    )
    newest = 0
    for line in out.splitlines():
        match = FALLBACK_ROW_RE.match(trim(line))
        if match:
            newest = max(newest, int(match.group(1)) * 1000)

    if newest > 0:
        return newest
    # The exit code, not the absence of rows, is what separates "could not
    # check" from "genuinely nothing public". A channel whose only uploads are
    # members-only exits 0 with no public row and must read as 0, or it would
    # be reported as a failed check forever.
    if rc != 0:
        sys.stderr.write(
            "Warning: yt-dlp uploads fallback failed for %s (%s)\n"
            % (channel_id, uploads)
        )
        return -1
    return 0


class FeedGate:
    """Tracks feed failures across one run.

    Once FEED_FAILURE_LIMIT channels have exhausted their retries, feed
    fetching is abandoned for every remaining channel and they go straight to
    the uploads fallback. Without this, a network-wide outage costs three
    timed-out fetches per channel.
    """

    def __init__(self):
        self.failures = 0
        self.skip_feeds = False

    def record_failure(self):
        self.failures += 1
        if self.failures >= FEED_FAILURE_LIMIT and not self.skip_feeds:
            self.skip_feeds = True
            sys.stderr.write(
                "Warning: %s feed fetches failed; skipping feeds for the rest "
                "of this run\n" % self.failures
            )


def newest_public_ms(channel, channel_url, gate=None):
    """Newest public video for a channel-ids.txt entry, in epoch ms.

    Returns -1 for "could not check" and 0 for "genuinely no public videos".
    Collapsing those two would make a network blip read as an empty channel,
    so they stay distinct all the way to the caller.
    """
    gate = gate or FeedGate()
    channel_id, source = resolve_channel_id(channel, channel_url)
    if not channel_id:
        return -1

    newest = public_newest_ms_for_channel_id(channel_id, gate)
    # A cached id that yields nothing may be a handle that moved to a new
    # channel. Drop it and resolve once more before believing the answer.
    if newest < 0 and source == "cache":
        sys.stderr.write(
            "Warning: cached channel id for @%s looks stale; re-resolving\n" % channel
        )
        store_channel_id(channel, None)
        channel_id, _ = resolve_channel_id(channel, channel_url, skip_cache=True)
        if not channel_id:
            return -1
        newest = public_newest_ms_for_channel_id(channel_id, gate)
    return newest


def public_newest_ms_for_channel_id(channel_id, gate):
    if not gate.skip_feeds:
        newest = feed_newest_ms(channel_id)
        if newest > 0:
            return newest
        gate.record_failure()
    return ytdlp_newest_public_ms(channel_id)


# ---------------------------------------------------------------------------
# Opening channels in a browser
# ---------------------------------------------------------------------------

def open_url(url):
    if sys.platform == "darwin":
        return run_cmd(["open", "--", url])
    if os.name == "nt":
        try:
            os.startfile(url)  # noqa: B606  (Windows only)
            print("Opened: %s" % url)
            return 0
        except OSError as error:
            sys.stderr.write("Error: could not open %s (%s)\n" % (url, error))
            return 1
    from shutil import which

    if which("xdg-open"):
        return run_cmd(["xdg-open", url])
    sys.stderr.write("Error: no browser opener found (need open or xdg-open)\n")
    return 1


def run_open_mode(check):
    """-o (check) and -O (open everything).

    Returns 0 on success. A channel that could not be checked is never opened
    and always makes the run exit non-zero, so a network failure is reported
    rather than silently read as an empty channel.
    """
    channels = read_channels()
    if channels is None:
        return 1

    checkpoint_ms = 0
    if check:
        checkpoint_ms = read_checkpoint_ms()
        if checkpoint_ms is None:
            return 1
        print("Checkpoint: %s" % checkpoint_ms)

    status = read_channel_check_status() if check else {}
    gate = FeedGate()
    batch_ms = now_ms()
    failures = 0

    for channel in channels:
        channel_url = channel_url_for(channel)
        if not check:
            open_url(channel_url)
            continue
        newest = newest_public_ms(channel, channel_url, gate)
        if newest < 0:
            failures += 1
            print("%s: CHECK FAILED (see warnings above; not opened)" % channel)
            continue
        record = status.setdefault(
            channel, {"checked_ms": 0, "latest_video_ms": 0, "thumbnail": ""}
        )
        record["checked_ms"] = batch_ms
        record["latest_video_ms"] = newest
        if newest == 0:
            print("%s: no public videos found (skipped)" % channel)
        elif newest > checkpoint_ms:
            print("%s: new public video (%s > %s)" % (channel, newest, checkpoint_ms))
            open_url(channel_url)
        else:
            print("%s: up to date (%s <= %s)" % (channel, newest, checkpoint_ms))

    if check:
        save_channel_check_status(status)

    run_open_mode.failure_count = failures
    run_open_mode.channel_count = len(channels)
    if failures:
        sys.stderr.write("Error: %s channel check(s) failed\n" % failures)
        return 1
    return 0


run_open_mode.failure_count = 0
run_open_mode.channel_count = 0


def should_skip_checkpoint(failures, channel_count):
    """Protect the checkpoint from advancing past channels that never got
    checked. 'All failed' only counts when at least one channel was listed."""
    return failures >= 3 or (channel_count > 0 and failures == channel_count)


# ---------------------------------------------------------------------------
# Scan engine
#
# Scans the /videos tab of each channel with the cookie-backed yt-dlp binary
# and merges the result into the incremental cache. Everything here stops at
# the merged entry list; rendering it into a page is a separate step.
#
# Approximate tab dates can precede the exact publication time, so the scan
# starts at midnight UTC on the day *before* the checkpoint date and keeps the
# overlap rather than resolving every watch page. Coverage over precision.
# ---------------------------------------------------------------------------

def day_start_sec(epoch_sec):
    return epoch_sec - epoch_sec % 86400


def scan_cutoff_for(checkpoint_ms):
    cutoff = day_start_sec(checkpoint_ms // 1000) - 86400
    return max(cutoff, 0)


def normalise_entry_ms(value):
    """yt-dlp prints %(timestamp)s in seconds; cached rows are already in ms."""
    return value * 1000 if 0 < value < 100000000000 else value


class ScanEntry:
    __slots__ = ("id", "url", "title", "timestamp_ms", "availability")

    def __init__(self, video_id, url, title, timestamp_ms, availability):
        self.id = video_id
        self.url = url
        self.title = title
        self.timestamp_ms = timestamp_ms
        self.availability = availability

    @classmethod
    def from_cache(cls, row):
        return cls(
            row["id"],
            row["url"],
            row["title"],
            normalise_entry_ms(row["timestamp_ms"]),
            row["availability"],
        )

    def to_cache(self):
        return {
            "id": self.id,
            "url": self.url,
            "title": self.title,
            "timestamp_ms": self.timestamp_ms,
            "availability": self.availability,
        }

    @property
    def is_public(self):
        return self.availability not in NON_PUBLIC_AVAILABILITY


def parse_scan_output(text):
    """Parse the TAB-separated --print rows yt-dlp emitted.

    Only lines carrying the scan: sentinel are records; yt-dlp interleaves its
    own chatter on the same stream. The template must contain a real TAB, not
    a literal backslash-t, or every row collapses into one field.
    """
    entries = []
    for line in text.splitlines():
        if not line.startswith("scan:"):
            continue
        fields = line[len("scan:") :].split("\t")
        if len(fields) < 5:
            continue
        # Only the title can legitimately contain a TAB, and the record has a
        # fixed shape, so anchor on both ends and treat the middle as the
        # title. Splitting naively would misread the title's tail as the
        # timestamp and silently drop the video.
        video_id = trim(fields[0])
        url = trim(fields[1])
        title = "\t".join(fields[2:-2])
        timestamp = trim(fields[-2])
        availability = trim(fields[-1])
        if not video_id or not re.fullmatch(r"[0-9]+", timestamp):
            continue
        entries.append(
            ScanEntry(
                video_id,
                url,
                sanitize_field(title),
                normalise_entry_ms(int(timestamp)),
                availability,
            )
        )
    return entries


SCAN_PRINT_TEMPLATE = (
    "scan:%(id)s\t%(webpage_url)s\t%(title)s\t%(timestamp)s\t%(availability)s"
)


def scan_channel(exe, channel_url, cutoff_sec, cookie_file):
    """Scan one channel's /videos tab. Returns (ok, entries).

    --lazy-playlist with --break-match-filters stops walking the tab as soon
    as an entry older than the cutoff appears, so a long-running channel costs
    only the recent page rather than its whole history.
    """
    rc, out = run_ytdlp_metadata(
        [
            exe,
            "--ignore-config",
            "--no-warnings",
            "--cookies",
            cookie_file,
            "--flat-playlist",
            "--lazy-playlist",
            "--extractor-args",
            "youtubetab:approximate_date",
            "--socket-timeout",
            YTDLP_TIMEOUT_SEC,
            "--retries",
            YTDLP_ATTEMPTS,
            "--extractor-retries",
            YTDLP_ATTEMPTS,
            "--skip-download",
            "--break-match-filters",
            "timestamp >= %s" % cutoff_sec,
            "--print",
            SCAN_PRINT_TEMPLATE,
            channel_url,
        ],
        deadline_sec=0,
    )
    ok = rc in (0, YTDLP_BREAK_RC)
    return ok, parse_scan_output(out)


class CookieJarPool:
    """Hands out one ephemeral copy of the cookie jar per worker slot.

    Concurrent yt-dlp processes rewrite their cookie file as the session
    refreshes, so sharing one jar across workers corrupts it. The copies are
    always removed, including when the run is interrupted.
    """

    def __init__(self, source, slots):
        self.paths = []
        TEMPORARY_DIRECTORY.mkdir(parents=True, exist_ok=True)
        for slot in range(slots):
            target = TEMPORARY_DIRECTORY / ("cookies%d.txt" % slot)
            try:
                shutil.copyfile(str(source), str(target))
            except OSError as error:
                sys.stderr.write(
                    "Warning: could not stage a cookie jar for slot %s (%s)\n"
                    % (slot, error)
                )
                continue
            self.paths.append(target)
        self._free = list(self.paths)
        self._lock = threading.Lock()

    def __len__(self):
        return len(self.paths)

    def acquire(self):
        with self._lock:
            return self._free.pop() if self._free else None

    def release(self, path):
        with self._lock:
            self._free.append(path)

    def cleanup(self):
        for path in self.paths:
            try:
                os.remove(str(path))
            except OSError:
                pass
        self.paths = []
        self._free = []


class ChannelPlan:
    """One channel's scan decision: which id, from what cutoff, and whether a
    yt-dlp scan is needed at all."""

    def __init__(self, channel, channel_id, cutoff_sec, last_full_ms):
        self.channel = channel
        self.channel_id = channel_id
        self.cutoff_sec = cutoff_sec
        self.last_full_ms = last_full_ms
        self.skip_scan = False
        self.feed_newest_ms = 0


def should_scan_html_channel(channel, status, refresh_all):
    """Routine scans skip channels whose newest known video is unknown or
    already 45 days old. REFRESH ALL bypasses the filter so those records can
    be repaired."""
    if refresh_all:
        return True
    record = status.get(channel)
    if not record:
        return False
    latest = record.get("latest_video_ms", 0)
    return latest > 0 and latest > now_ms() - STALE_CHANNEL_TTL_MS


def plan_channels(channels, status, cache, checkpoint_ms, incremental, refresh_all):
    """Resolve ids and per-channel cutoffs. Returns (plans, failures)."""
    base_cutoff = scan_cutoff_for(checkpoint_ms)
    plans = []
    failures = []
    for channel in channels:
        # In incremental mode a channel with no cache record is always
        # scanned, so a newly added handle can never be skipped as "stale".
        newly_added = incremental and channel not in cache
        if not newly_added and not should_scan_html_channel(
            channel, status, refresh_all
        ):
            print(
                "Skipping @%s (latest video is 1.5 months old or older, or unknown)"
                % channel
            )
            continue

        if UC_ID_RE.match(channel):
            channel_id = channel
        else:
            channel_id, _ = resolve_channel_id(channel, channel_url_for(channel))
            if not channel_id:
                failures.append((channel, "could not resolve channel id"))
                continue

        cutoff_sec = base_cutoff
        last_full_ms = 0
        if incremental and channel in cache:
            record = cache[channel]
            last_full_ms = record.get("last_full_scan_ms", 0) or record.get(
                "checked_ms", 0
            )
            if last_full_ms > 0:
                candidate = day_start_sec(last_full_ms // 1000) - 86400
                cutoff_sec = max(cutoff_sec, candidate)
        plans.append(ChannelPlan(channel, channel_id, cutoff_sec, last_full_ms))
    return plans, failures


def apply_feed_gate(plans, cache, checkpoint_ms, batch_ms):
    """Mark channels whose public feed proves nothing new has been published.

    This is the whole point of incremental mode: an unchanged feed means the
    expensive cookie-backed scan can be skipped and the cached cards reused.
    A feed that is newer, empty, malformed or unfetchable deliberately leaves
    the channel to be scanned, so the cheap check can only ever save work, not
    cause a miss. A scan is still forced every HTML_FULL_SCAN_INTERVAL_MS.
    """
    candidates = {
        plan.channel: plan
        for plan in plans
        if plan.channel in cache
        and plan.last_full_ms > 0
        and batch_ms - plan.last_full_ms < HTML_FULL_SCAN_INTERVAL_MS
    }
    if not candidates:
        return

    urls = {
        channel: feed_url_for(plan.channel_id)
        for channel, plan in candidates.items()
    }
    bodies = fetch_urls_concurrent(urls, "video feed", send_consent=False)

    base_known_ms = scan_cutoff_for(checkpoint_ms) * 1000
    for channel, plan in candidates.items():
        body = bodies.get(channel)
        if body is None:
            continue
        newest_feed_ms = feed_newest_ms_from_body(body, channel)
        if newest_feed_ms <= 0:
            continue
        plan.feed_newest_ms = newest_feed_ms
        record = cache[channel]
        known_ms = max(base_known_ms, record.get("feed_newest_ms", 0))
        for row in record.get("entries", []):
            known_ms = max(known_ms, normalise_entry_ms(row.get("timestamp_ms", 0)))
        if newest_feed_ms <= known_ms:
            plan.skip_scan = True
            print("@%s: public feed unchanged; reusing cached cards" % channel)


def run_scan_pool(plans, exe, cookies_source, on_progress=None):
    """Scan every channel that needs it, concurrently. Returns
    {channel: (scanned_ok, entries)}; a skipped channel is absent."""
    pending = [plan for plan in plans if not plan.skip_scan]
    results = {}
    if not pending:
        return results

    pool = CookieJarPool(cookies_source, min(MAX_THREADS, len(pending)))
    if not len(pool):
        sys.stderr.write("Error: could not stage any cookie jar for scanning\n")
        return {plan.channel: (False, []) for plan in pending}

    try:
        from concurrent.futures import ThreadPoolExecutor, as_completed

        def work(plan):
            jar = pool.acquire()
            if jar is None:
                return plan, False, []
            try:
                print("Checking @%s..." % plan.channel)
                ok, entries = scan_channel(
                    exe, channel_url_for(plan.channel), plan.cutoff_sec, jar
                )
                return plan, ok, entries
            finally:
                pool.release(jar)

        with ThreadPoolExecutor(max_workers=len(pool)) as executor:
            futures = [executor.submit(work, plan) for plan in pending]
            completed = 0
            for future in as_completed(futures):
                try:
                    plan, ok, entries = future.result()
                except Exception as error:
                    sys.stderr.write("Warning: a channel scan failed: %s\n" % error)
                    continue
                results[plan.channel] = (ok, entries)
                completed += 1
                if on_progress:
                    on_progress(completed, len(pending), plan, ok, entries)
    finally:
        pool.cleanup()
    return results


def merge_channel_entries(cached_entries, scanned, keep_cutoff_ms):
    """Merge freshly scanned rows over cached rows, newest first.

    A scanned row always wins over the cached row for the same video, so a
    retitled or newly-available video is corrected rather than frozen at
    whatever the first scan saw.
    """
    merged = {}
    order = []
    for row in cached_entries:
        entry = ScanEntry.from_cache(row)
        if entry.id not in merged:
            order.append(entry.id)
        merged[entry.id] = entry
    for entry in scanned:
        if entry.id not in merged:
            order.append(entry.id)
        merged[entry.id] = entry
    kept = [
        merged[video_id]
        for video_id in order
        if merged[video_id].timestamp_ms >= keep_cutoff_ms
    ]
    kept.sort(key=lambda entry: entry.timestamp_ms, reverse=True)
    return kept


def scan_all_channels(
    channels,
    checkpoint_ms,
    incremental,
    refresh_all,
    on_progress=None,
    on_channel=None,
):
    """Full scan cycle: plan, gate, scan, merge, persist.

    Returns (per_channel_entries, failures) where per_channel_entries maps a
    channel to its merged, newest-first entry list.

    Each channel is finalized the moment its own scan settles rather than
    after the whole pool drains, so --html3 can publish one fragment at a
    time. on_channel(channel, entries, channel_id) fires per channel, with entries
    None when that channel produced nothing usable; on_progress(completed, total)
    follows it. Both run on a scan worker thread, so the shared cache and
    status maps are mutated under a lock.
    """
    exe = ytdlp_path()
    if exe is None:
        sys.stderr.write("Error: yt-dlp binary not found next to this script\n")
        return None, []
    if not COOKIES_FILE.is_file():
        sys.stderr.write(
            "Error: %s does not exist; export YouTube cookies from a browser first\n"
            % display_path(COOKIES_FILE)
        )
        return None, []

    batch_ms = now_ms()
    status = read_channel_check_status()
    cache = read_html_video_cache() if incremental else {}

    plans, failures = plan_channels(
        channels, status, cache, checkpoint_ms, incremental, refresh_all
    )
    if incremental:
        apply_feed_gate(plans, cache, checkpoint_ms, batch_ms)

    keep_cutoff_ms = scan_cutoff_for(checkpoint_ms) * 1000
    per_channel = {}
    total = len(plans)
    state_lock = threading.Lock()
    completed_count = [0]

    def finalize(plan, scanned_ok, scanned):
        """Merge and persist one channel, then report it."""
        channel = plan.channel
        with state_lock:
            # A gated channel was never scanned, so it has no fresh rows but
            # is not a failure either.
            full_scan_ok = scanned_ok and not plan.skip_scan
            cached_rows = (
                cache.get(channel, {}).get("entries", []) if incremental else []
            )

            entries = None
            if not scanned_ok:
                if incremental:
                    sys.stderr.write(
                        "Warning: could not incrementally scan the videos tab "
                        "for @%s; using cached entries\n" % channel
                    )
                    failures.append(
                        (channel, "could not scan videos tab; using cached entries")
                    )
                else:
                    sys.stderr.write(
                        "Warning: could not scan the videos tab for @%s\n" % channel
                    )
                    failures.append((channel, "could not scan videos tab"))

            if scanned_ok or incremental:
                entries = merge_channel_entries(cached_rows, scanned, keep_cutoff_ms)
                per_channel[channel] = entries

                newest = max(
                    (e.timestamp_ms for e in entries if e.is_public), default=0
                )
                print(
                    "@%s: %s visible video(s) in the checkpoint overlap"
                    % (channel, sum(1 for e in entries if e.is_public))
                )

                if incremental:
                    prior = cache.get(channel, {})
                    cache[channel] = {
                        "channel_id": plan.channel_id,
                        "checked_ms": (
                            batch_ms if scanned_ok else prior.get("checked_ms", 0)
                        ),
                        "last_full_scan_ms": (
                            batch_ms if full_scan_ok else plan.last_full_ms
                        ),
                        "feed_newest_ms": (
                            plan.feed_newest_ms
                            if (scanned_ok and plan.feed_newest_ms)
                            else prior.get("feed_newest_ms", 0)
                        ),
                        "entries": [entry.to_cache() for entry in entries],
                    }

                # preserve=1: a scan that found nothing must not erase a
                # channel's known age, or the staleness filter would drop it
                # on the next run.
                record = status.setdefault(
                    channel,
                    {"checked_ms": 0, "latest_video_ms": 0, "thumbnail": ""},
                )
                record["checked_ms"] = batch_ms
                if newest:
                    record["latest_video_ms"] = newest

            completed_count[0] += 1
            done = completed_count[0]

        if on_channel:
            # The resolved UC… id must come from the plan: a channel that was
            # not already cached has none on disk yet, and a card rendered
            # with an empty channel id fails selection validation.
            on_channel(channel, entries, plan.channel_id)
        if on_progress:
            on_progress(done, total)

    # Gated channels need no network at all, so publish them first: the page
    # gets its cached cards immediately instead of waiting on the pool.
    for plan in plans:
        if plan.skip_scan:
            finalize(plan, True, [])

    finalized = {plan.channel for plan in plans if plan.skip_scan}

    def pool_progress(_completed, _total, plan, ok, entries):
        finalized.add(plan.channel)
        finalize(plan, ok, entries)

    results = run_scan_pool(plans, exe, COOKIES_FILE, pool_progress)

    # run_scan_pool can return a result without ever reporting it: it fails
    # the whole batch when no cookie jar could be staged, and it drops a
    # future that raised. Reconcile, or those channels would never be
    # finalized and the progress total would never be reached.
    for plan in plans:
        if plan.channel in finalized:
            continue
        scanned_ok, scanned = results.get(plan.channel, (True, []))
        finalize(plan, scanned_ok, scanned)

    if incremental:
        save_html_video_cache(cache)
    save_channel_check_status(status)
    return per_channel, failures


# ---------------------------------------------------------------------------
# --html3
#
# --html3 writes a loading shell immediately and then fills it in: a scan
# worker publishes one HTML fragment per channel, and the page polls /state
# and splices each fragment in as it appears. The whole page is therefore
# reachable before any channel has been scanned.
#
# The shells run the scan in a second *process* (`yy.zsh --html3-worker`)
# because they are single-threaded and would otherwise block the listener.
# Python has threads, so the worker is a thread here and the fragments and
# state live in memory instead of in .tmp files. The HTTP contract the page
# depends on - the endpoints, the JSON shape and the fragment URLs - is
# unchanged, so the page asset below is the shells' asset verbatim.
# ---------------------------------------------------------------------------

HTML3_PAGE_TEMPLATE = r"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>YouTube Video Download</title><style>:root{--bg:#0d1117;--card:#161b22;--bd:#30363d;--fg:#e6edf3;--mut:#8b949e;--acc:#58a6ff}*{box-sizing:border-box}body{margin:0;padding:16px 60px;background:var(--bg);color:var(--fg);font:14px/1.55 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif}h1{font-size:32px;margin:0 0 6px;padding-bottom:0}h2{font-size:22px;margin:0}.channel-title h2 a{color:var(--acc)}p{color:var(--mut);font-size:12.5px;margin:0 0 16px}button{background:#21262d;color:var(--fg);border:1px solid var(--bd);border-radius:6px;padding:5px 10px;cursor:pointer;font:inherit}button:disabled,input:disabled{opacity:.55;cursor:wait}.controls,.checks,.channel-title{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.controls button{padding:4px 9px}.channel{margin-top:28px}.channel-title{padding-bottom:6px;border-bottom:1px solid var(--bd)}.grid{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:12px;margin:12px 0 28px}.card{background:var(--card);border:1px solid var(--bd);padding:10px;border-radius:10px}.video-link{display:block;color:var(--fg);text-decoration:none}.preview{aspect-ratio:16/9;background:#0b0f14;overflow:hidden;border-radius:6px}.preview img{width:100%;height:100%;object-fit:cover}.video-title{font-size:12px;line-height:1.4;margin-top:7px}.checks{margin-top:8px;color:var(--mut)}.video-age{font-size:11px;color:var(--mut);margin-top:3px}.job-log{max-height:190px;overflow:auto;background:#010409;border:1px solid var(--bd);border-radius:6px;padding:8px;color:var(--mut);white-space:pre-wrap;font:12px/1.4 Consolas,monospace}.back-to-top{position:fixed;bottom:24px;right:24px;width:48px;height:48px;border-radius:50%;background:var(--acc);color:var(--bg);border:0;display:none;font-size:34px;font-weight:700}.back-to-top.visible{display:flex;align-items:center;justify-content:center}#html3-progress{margin:0 0 16px}.html3-progress-track{height:8px;overflow:hidden;border-radius:4px;background:#30363d}.html3-progress-bar{height:100%;width:0;background:#58a6ff;transition:width .25s ease}@media(max-width:1100px){body{padding:16px}.grid{grid-template-columns:repeat(3,minmax(0,1fr))}}@media(max-width:650px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}}<style>.video-age{font-size:11px;color:var(--mut);margin-top:3px}.channel-bar{height:8px;background:var(--acc);margin:42px 0 12px}.channel-table{width:100%;border-collapse:collapse;margin-top:12px}.channel-table th,.channel-table td{padding:8px;border-bottom:1px solid var(--bd);text-align:left}.channel-table th{color:var(--mut)}.channel-table a{color:var(--acc)}.channel-table tr.html3-channel-error td{background:#3C050F;border-bottom-color:#7a1828;color:#fff}.channel-table tr.html3-channel-error a{color:#fff}#channel-add{width:27em}h2{color:var(--acc)}.channel-title h2 a{text-decoration:underline;text-underline-offset:3px}button:hover{border-color:var(--acc);background:#1c2230}.video-link:hover{color:var(--acc)}.preview{position:relative}.preview img{transition:transform .2s ease,filter .2s ease}.card:hover .preview img{transform:scale(1.04);filter:brightness(.82)}.back-to-top{border:none;box-shadow:0 2px 8px rgba(0,0,0,.45)}.back-to-top:hover{background:#79c0ff}#html3-error-panel{position:fixed;z-index:10;top:18px;left:50%;transform:translateX(-50%);max-width:min(720px,calc(100vw - 32px));padding:16px 20px;border:2px solid #ff7b72;border-radius:8px;background:#1b1114;box-shadow:0 8px 28px rgba(0,0,0,.55);color:#ff7b72;font-size:18px}#html3-error-panel[hidden]{display:none}</style><style>.html3-progress-bar{position:relative;overflow:hidden}.html3-progress-bar.loading::after{content:"";position:absolute;inset:0;transform:translateX(-100%);background:linear-gradient(90deg,transparent,rgba(255,255,255,.42),transparent);animation:html3-progress-shimmer 1.2s linear infinite}@keyframes html3-progress-shimmer{to{transform:translateX(100%)}}</style></head><body><h1>YouTube Video Download</h1><div id="html3-progress" role="status" aria-live="polite"><div class="html3-progress-track"><div class="html3-progress-bar"></div></div><p id="html3-progress-status">__MESSAGE__</p></div><p>Select y1 and/or y2, then click DOWNLOAD SELECTED to run the matching local yy hook. <span id="checkpoint-value">__CHECKPOINT__</span></p><div class="controls"><button id="download" type="button">DOWNLOAD SELECTED</button><button id="checkpoint" type="button">CHECKPOINT</button><button id="refresh" type="button">REFRESH</button><button id="refresh-all" type="button">REFRESH ALL</button><button id="stop" type="button">STOP SERVER</button><button data-action="y1" type="button">y1</button><button data-action="y2" type="button">y2</button><button data-action="none" type="button">none</button></div><p id="status"></p><div id="html3-error-panel" role="alert" aria-live="assertive" hidden><div id="html3-errors"></div></div><pre id="job-log" class="job-log"></pre><main><section id="channel-ids" class="channel"><div class="channel-bar"></div><div class="channel-title"><h2>Channel IDs</h2></div><p>Loading Channel IDs...</p></section></main><button id="back-to-top" class="back-to-top" type="button" aria-label="Back to top" title="Back to top">&uarr;</button><script>(()=>{const token="__TOKEN__",base="/html3/"+token,stateUrl=base+"/state",fragmentUrl=i=>base+"/fragment/"+i,channelsUrl=base+"/channels",api=n=>"/"+n+"/"+token,controls=[...document.querySelectorAll("button,input")],top=document.querySelector("#back-to-top"),status=document.querySelector("#status"),errors=document.querySelector("#html3-errors"),errorPanel=document.querySelector("#html3-error-panel"),log=document.querySelector("#job-log"),applied=new Set(),saved=new Set();let html3Failures=[];const html3FailureSummary=()=>html3Failures.length?"Completed with channel errors: "+html3Failures.map(x=>"@"+x.channel+" ("+x.stage+")").join(", "):"";const compactLogs=logs=>{const buckets=new Map(),percents=new Map();return logs.filter(line=>{if(/^\[y[12]\]\s*$/.test(line))return false;const m=line.match(/^(\[[^\]]+\])\s+\[download\]\s+([0-9]+(?:\.[0-9]+)?)%/);if(!m)return true;const target=m[1],percent=Number(m[2]),previous=percents.get(target);if(previous!==undefined&&percent<previous-1)buckets.set(target,-1);percents.set(target,percent);const bucket=Math.floor(percent/10),last=buckets.has(target)?buckets.get(target):-1,emit=bucket>last||percent>=100;if(emit)buckets.set(target,bucket);return emit})};const showJobs=async()=>{let again=false;try{const b=await (await fetch(api("status"),{cache:"no-store"})).json(),p=[];if(b.running)p.push(b.running+" running");if(b.queued)p.push(b.queued+" queued");if(b.completed)p.push(b.completed+" completed");if(b.failed)p.push(b.failed+" failed");status.textContent=p.length?p.join(", ")+"." : "No download jobs yet.";log.textContent=compactLogs(b.logs||[]).join("\n");log.scrollTop=log.scrollHeight;if(b.running||b.queued)again=true}catch(e){status.textContent="Status unavailable: "+e.message;again=true}finally{if(again)setTimeout(showJobs,1000)}};const relativeCheckpoint=ms=>{const s=Math.max(0,Math.floor((Date.now()-Number(ms))/1000)),u=[[31536000,"year"],[2592000,"month"],[604800,"week"],[86400,"day"],[3600,"hour"],[60,"minute"]];if(s<60)return "just now";for(const[d,n]of u)if(s>=d){const x=Math.floor(s/d);return x+" "+n+(x===1?"":"s")+" ago"}},checkpointText=ms=>{if(!ms)return "";const d=new Intl.DateTimeFormat("en-US",{timeZone:"America/Los_Angeles",year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",second:"2-digit",hourCycle:"h23"}).format(new Date(Number(ms)));return "Checkpoint: "+d+" Pacific Time ("+relativeCheckpoint(ms)+")"};const key=x=>x.dataset.channelId+"|"+x.dataset.videoId+"|"+x.className,remember=()=>document.querySelectorAll("input.y1:checked,input.y2:checked").forEach(x=>saved.add(key(x))),setBusy=b=>document.querySelectorAll("button,input").forEach(x=>{if(x!==top)x.disabled=b});const apply=async u=>{if(!u||applied.has(u.channel))return;const r=await fetch(fragmentUrl(u.fragment),{cache:"no-store"});if(!r.ok)return;const text=await r.text(),old=[...document.querySelectorAll("section.channel")].find(x=>x.dataset.html3Channel===u.channel);applied.add(u.channel);if(!text){if(old)old.remove();return}remember();const t=document.createElement("template");t.innerHTML=text;const fresh=t.content.firstElementChild;if(old)old.replaceWith(fresh);else document.querySelector("main").insertBefore(fresh,document.querySelector("#channel-ids"));fresh.querySelectorAll("input.y1,input.y2").forEach(x=>{if(saved.has(key(x)))x.checked=true});fresh.querySelectorAll("button,input").forEach(x=>x.disabled=false)};const applyChannelIds=async()=>{const r=await fetch(channelsUrl,{cache:"no-store"});if(!r.ok)return;const t=document.createElement("template");t.innerHTML=await r.text();const fresh=t.content.firstElementChild,old=document.querySelector("#channel-ids");if(fresh&&old)old.replaceWith(fresh)};const poll=async()=>{try{const s=await (await fetch(stateUrl,{cache:"no-store"})).json(),bar=document.querySelector(".html3-progress-bar");bar.classList.toggle("loading",s.status==="running");if(s.status==="running")document.querySelector("#html3-progress-status").textContent=s.message||"Loading channels...";if(s.total){const partial=s.status==="running"?.5:0;bar.style.width=Math.min(100,100*((s.completed||0)+partial)/s.total)+"%";}for(const u of (Array.isArray(s.updates)?s.updates:(s.updates?[s.updates]:[])))await apply(u);if(s.status==="success"){await applyChannelIds();setBusy(false);document.querySelector("#html3-progress-status").textContent="";html3Failures=Array.isArray(s.failed_channels)?s.failed_channels:(s.failed_channels?[s.failed_channels]:[]);errors.textContent=html3FailureSummary();errorPanel.hidden=!html3Failures.length;return}if(s.status==="error"){status.textContent=s.error||"Page generation failed.";return}}catch(e){status.textContent="Progress unavailable: "+e.message}setTimeout(poll,500)};document.addEventListener("click",e=>{const b=e.target.closest("button[data-action]");if(!b)return;(b.closest(".channel")||document).querySelectorAll("input.y1,input.y2").forEach(x=>{if(b.dataset.action==="none")x.checked=false;else if(x.className===b.dataset.action)x.checked=true})});document.addEventListener("click",async e=>{const add=e.target.closest("#channel-add-button"),remove=e.target.closest(".channel-delete");if(!add&&!remove)return;const payload=add?{action:"add",channel:document.querySelector("#channel-add").value.trim()}:{action:"delete",channel:remove.dataset.channel};if(!payload.channel)return;const b=await (await fetch(api("channel"),{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)})).json();status.textContent=b.message||"Channel IDs updated.";if(b.message)setTimeout(()=>refresh(false),0)});document.querySelector("#download").onclick=async()=>{const items=[...document.querySelectorAll("input:checked")].map(x=>({target:x.className,url:x.dataset.url,path:x.dataset.path,channel_id:x.dataset.channelId,video_id:x.dataset.videoId}));if(!items.length){status.textContent="Select at least one video";return}status.textContent="Starting local downloads...";try{const b=await (await fetch(api("download"),{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({items})})).json();status.textContent=b.message||"Started";showJobs()}catch(e){status.textContent="Callback failed: "+e.message}};document.querySelector("#checkpoint").onclick=async()=>{const b=await (await fetch(api("checkpoint"),{method:"POST"})).json();status.textContent=b.message;document.querySelector("#checkpoint-value").textContent=b.checkpoint_ms?checkpointText(b.checkpoint_ms):""};const refresh=async all=>{remember();html3Failures=[];errors.textContent="";errorPanel.hidden=true;setBusy(true);const b=await (await fetch(api(all?"refresh-all":"refresh"),{method:"POST"})).json();status.textContent=b.message||"Refreshing";applied.clear();poll()};document.querySelector("#refresh").onclick=()=>refresh(false);document.querySelector("#refresh-all").onclick=()=>refresh(true);document.querySelector("#stop").onclick=async()=>{if(!window.confirm("Stop the local server? Active downloads will continue."))return;try{const b=await (await fetch(api("stop"),{method:"POST"})).json();status.textContent=b.message||"Server stopped"}catch(e){status.textContent="Server stopped"}window.close();setTimeout(()=>location.replace("about:blank"),150)};top.onclick=()=>window.scrollTo({top:0,behavior:"smooth"});const toggle=()=>top.classList.toggle("visible",scrollY>200);addEventListener("scroll",toggle,{passive:true});top.disabled=false;document.addEventListener("click",e=>{if(!errorPanel.hidden&&!errorPanel.contains(e.target))errorPanel.hidden=true});setInterval(()=>fetch(api("heartbeat"),{method:"POST",keepalive:true}),2000);showJobs();setBusy(true);poll()})()</script></body></html>"""

HTML3_HOST = "127.0.0.1"
HTML3_PORT = 8080
HTML3_HEARTBEAT_TIMEOUT_SEC = 30 * 60
HTML3_LOG_LIMIT = 400
HTML3_LOG_WINDOW = 80
DOWNLOAD_PROGRESS_STEP_PERCENT = 10

NON_PUBLIC_TARGETS = ("y1", "y2")
TARGET_DIR_RE = re.compile(r'^\./[^\\/:*?"<>|]+$')
DOWNLOAD_PERCENT_RE = re.compile(r"^\[download\]\s+([0-9]+(?:\.[0-9]+)?)%")
OG_IMAGE_RE = re.compile(r'<meta property="og:image" content="([^"]*)"')
ANSI_CSI_RE = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")
ANSI_OSC_RE = re.compile(r"\x1b\][^\x07]*\x07")
ANSI_CHARSET_RE = re.compile(r"\x1b[()][A-Za-z0-9]")
CONTROL_CHARS_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")

RELATIVE_UNITS = (
    (31536000, "year"),
    (2592000, "month"),
    (604800, "week"),
    (86400, "day"),
    (3600, "hour"),
    (60, "minute"),
)


def html_escape(value):
    import html as html_module

    return html_module.escape(coerce_str(value), quote=True)


def format_relative_ms(raw):
    """"3 days ago" for an epoch-ms timestamp; empty when unset."""
    ms = coerce_int(raw)
    if ms <= 0:
        return ""
    ms = normalise_entry_ms(ms)
    seconds = max(0, now_sec() - ms // 1000)
    for divisor, unit in RELATIVE_UNITS:
        count = seconds // divisor
        if count >= 1:
            return "%d %s%s ago" % (count, unit, "" if count == 1 else "s")
    return "just now"


def pacific_time_text(epoch_sec):
    """Format in Pacific time, degrading to local time without the zone db.

    zoneinfo is stdlib from 3.9, but on Windows it has no bundled database
    and the tzdata package is deliberately not a dependency here. Falling
    back keeps the page honest about which clock it is showing instead of
    silently labelling local time as Pacific.
    """
    import datetime

    try:
        from zoneinfo import ZoneInfo

        stamp = datetime.datetime.fromtimestamp(
            epoch_sec, ZoneInfo("America/Los_Angeles")
        )
        return stamp.strftime("%m/%d/%Y, %H:%M:%S"), "Pacific Time"
    except Exception:
        stamp = datetime.datetime.fromtimestamp(epoch_sec)
        return stamp.strftime("%m/%d/%Y, %H:%M:%S"), "local time"


def format_html3_checkpoint_text(ms):
    ms = coerce_int(ms)
    if ms <= 0:
        return ""
    stamp, zone = pacific_time_text(ms // 1000)
    return "Checkpoint: %s %s (%s)" % (stamp, zone, format_relative_ms(ms))


def strip_control_chars(text):
    """Drop ANSI sequences and raw control bytes from a yt-dlp log line.

    yt-dlp emits colour and cursor sequences even when its output is a pipe,
    so a progress line carries a raw ESC. json.dumps would escape it legally,
    but the page would then render \\u001b[K instead of text.
    """
    text = ANSI_CSI_RE.sub("", coerce_str(text))
    text = ANSI_OSC_RE.sub("", text)
    text = ANSI_CHARSET_RE.sub("", text)
    return CONTROL_CHARS_RE.sub("", text)


def channel_thumbnails_concurrent(keys):
    """Fetch each channel's og:image avatar. Missing ones are simply absent."""
    if not keys:
        return {}
    bodies = fetch_urls_concurrent(
        {key: channel_url_for(key) for key in keys}, "avatar"
    )
    thumbnails = {}
    for key, body in bodies.items():
        match = OG_IMAGE_RE.search(body)
        if match:
            thumbnails[key] = match.group(1).replace("&amp;", "&")
    return thumbnails


# --- page fragments --------------------------------------------------------

def render_channel_fragment(channel, channel_id, entries, cutoff_ms, downloaded):
    """Render one channel's card section.

    Returns (html, visible, dropped). Unlike --html/--html2, a video already
    submitted for download loses its whole card rather than coming back with
    a restored checkbox, so either target being present drops it.
    """
    cards = []
    dropped = 0
    for entry in entries or ():
        if not entry.is_public:
            continue
        if entry.timestamp_ms < cutoff_ms:
            continue
        if not entry.id or not entry.url:
            continue
        hit = 0
        for target in NON_PUBLIC_TARGETS:
            if (channel_id, entry.id, target) in downloaded:
                hit += 1
        if hit:
            dropped += hit
            continue
        thumb = "https://i.ytimg.com/vi/%s/hqdefault.jpg" % entry.id
        checks = "".join(
            '<label><input class="%s" data-url="%s" data-path="%s" '
            'data-channel-id="%s" data-video-id="%s" type="checkbox"> %s</label>'
            % (
                target,
                html_escape(entry.url),
                html_escape("./%s" % channel),
                html_escape(channel_id),
                html_escape(entry.id),
                target,
            )
            for target in NON_PUBLIC_TARGETS
        )
        cards.append(
            '<article class="card"><a class="video-link" href="%s" target="_blank" '
            'rel="noopener noreferrer"><div class="preview"><img src="%s" alt="">'
            '</div><div class="video-title">%s</div></a>'
            '<div class="video-age">%s</div><div class="checks">%s</div></article>'
            % (
                html_escape(entry.url),
                html_escape(thumb),
                html_escape(entry.title),
                html_escape(format_relative_ms(entry.timestamp_ms)),
                checks,
            )
        )

    if dropped:
        if cards:
            print(
                "Update @%s to show %s visible card(s) after %s downloaded "
                "target selection(s) loaded." % (channel, len(cards), dropped)
            )
        else:
            print(
                "Remove @%s from preview section: no visible cards after %s "
                "downloaded target selection(s) loaded." % (channel, dropped)
            )
    if not cards:
        return "", 0, dropped

    controls = "".join(
        '<button data-action="%s" type="button">%s</button>' % (name, name)
        for name in ("y1", "y2", "none")
    )
    fragment = (
        '<section class="channel" data-html3-channel="%s"><div class="channel-title">'
        '<h2><a href="%s" target="_blank" rel="noopener noreferrer">%s</a></h2>'
        '<div class="controls">%s</div></div><div class="grid">%s</div></section>'
        % (
            html_escape(channel),
            html_escape(channel_url_for(channel)),
            html_escape(channel),
            controls,
            "\n".join(cards),
        )
    )
    return fragment, len(cards), dropped


def render_channels_section(channels, status, failed_channels):
    """Render the Channel IDs table, newest-checked first."""
    failed = {name.lstrip("@") for name, _stage in failed_channels}
    rows = []
    for display in channels:
        key = display.lstrip("@")
        record = status.get(key) or {}
        rows.append(
            (
                coerce_int(record.get("checked_ms")),
                coerce_int(record.get("latest_video_ms")),
                display,
                key,
                coerce_str(record.get("thumbnail")),
            )
        )
    rows.sort(key=lambda row: (row[0], row[1]), reverse=True)

    body = []
    for checked_ms, latest_ms, display, key, thumbnail in rows:
        avatar = ""
        if thumbnail:
            avatar = (
                '<img src="%s" alt="" width="42" height="42" '
                'style="border-radius:50%%;object-fit:cover">' % html_escape(thumbnail)
            )
        body.append(
            '<tr%s><td>%s</td><td><a href="%s" target="_blank" '
            'rel="noopener noreferrer">%s</a></td><td>%s</td><td>%s</td>'
            '<td><button class="channel-delete" data-channel="%s" type="button">'
            "delete</button></td></tr>"
            % (
                ' class="html3-channel-error"' if key in failed else "",
                avatar,
                html_escape(channel_url_for(key)),
                html_escape(display),
                html_escape(format_relative_ms(checked_ms) if checked_ms else "never"),
                html_escape(format_relative_ms(latest_ms) if latest_ms else "unknown"),
                html_escape(display),
            )
        )

    return (
        '<section id="channel-ids" class="channel"><div class="channel-bar"></div>'
        '<div class="channel-title"><h2>Channel IDs</h2></div>'
        '<div class="controls"><input id="channel-add" '
        'placeholder="@channel or UC channel id">'
        '<button id="channel-add-button" type="button">add</button></div>'
        '<table class="channel-table"><thead><tr><th>Profile</th><th>Channel</th>'
        "<th>Last checked</th><th>Latest video</th><th></th></tr></thead><tbody>\n"
        "%s</tbody></table></section>" % "\n".join(body)
    )


def render_loading_page(token, message):
    page = HTML3_PAGE_TEMPLATE
    page = page.replace("__TOKEN__", token)
    page = page.replace("__MESSAGE__", html_escape(message))
    page = page.replace(
        "__CHECKPOINT__",
        html_escape(format_html3_checkpoint_text(read_checkpoint_ms())),
    )
    return page


# --- download jobs ---------------------------------------------------------

def validate_video_selection(item):
    """Accept only structured selections, never a path or URL the page could
    have been tricked into inventing."""
    target = coerce_str(item.get("target"))
    url = coerce_str(item.get("url"))
    target_dir = coerce_str(item.get("path"))
    channel_id = coerce_str(item.get("channel_id"))
    video_id = coerce_str(item.get("video_id"))
    if target not in NON_PUBLIC_TARGETS:
        return None
    if not UC_ID_RE.match(channel_id):
        return None
    if not VIDEO_ID_RE.match(video_id):
        return None
    if not TARGET_DIR_RE.match(target_dir) or target_dir in ("./.", "./.."):
        return None
    if not (url.startswith("http://") or url.startswith("https://")):
        return None
    host = url.split("://", 1)[1].split("/")[0].split("?")[0].split("#")[0]
    host = host.rsplit("@", 1)[-1].split(":")[0].lower()
    if not (host in ("youtu.be", "youtube.com") or host.endswith(".youtube.com")):
        return None
    return {
        "target": target,
        "url": url,
        "path": target_dir,
        "channel_id": channel_id,
        "video_id": video_id,
    }


class DownloadJob:
    __slots__ = (
        "target",
        "url",
        "path",
        "channel_id",
        "video_id",
        "hook",
        "state",
        "succeeded",
        "last_percent",
        "last_bucket",
    )

    def __init__(self, item, hook):
        self.target = item["target"]
        self.url = item["url"]
        self.path = item["path"]
        self.channel_id = item["channel_id"]
        self.video_id = item["video_id"]
        self.hook = hook
        self.state = "queued"
        self.succeeded = False
        self.last_percent = -1
        self.last_bucket = -1

    def should_emit(self, line):
        """One log line per 10% of a download, so the page log stays readable.

        A second format - normally audio after video - restarts near zero and
        gets its own buckets.
        """
        match = DOWNLOAD_PERCENT_RE.match(line)
        if not match:
            return True
        percent = int(float(match.group(1)))
        if self.last_percent >= 0 and percent < self.last_percent - 1:
            self.last_bucket = -1
        self.last_percent = percent
        bucket = percent // DOWNLOAD_PROGRESS_STEP_PERCENT
        if bucket > self.last_bucket or percent >= 100:
            self.last_bucket = bucket
            return True
        return False


def iter_process_lines(stream):
    """Yield lines split on CR as well as LF.

    yt-dlp rewrites its progress line with a bare CR, so reading by LF alone
    would withhold the whole download as one enormous line.
    """
    buffer = ""
    while True:
        chunk = stream.read(1)
        if not chunk:
            break
        if chunk in ("\r", "\n"):
            if buffer:
                yield buffer
                buffer = ""
            continue
        buffer += chunk
    if buffer:
        yield buffer


class JobManager:
    """Runs y1/y2 hooks one at a time, y2 before y1."""

    def __init__(self):
        self.lock = threading.Lock()
        self.jobs = []
        self.logs = []
        self.worker = None

    def submit(self, items):
        """Queue validated selections. Returns (started, error)."""
        if not items:
            return 0, "No video selections received"
        selections = []
        for item in items:
            checked = validate_video_selection(item)
            if checked is None:
                return 0, "Invalid video selection received"
            selections.append(checked)

        downloaded = {downloaded_key(r) for r in read_downloaded_videos()}
        queued = []
        # y2 drains before y1, keeping the page's order within each target.
        for pass_target in ("y2", "y1"):
            for item in selections:
                if item["target"] != pass_target:
                    continue
                key = (item["channel_id"], item["video_id"], item["target"])
                if key in downloaded:
                    print(
                        "Skipped previously downloaded selection: %s / %s / %s" % key
                    )
                    continue
                # y1/y2 run the local yy1/yy2 hooks found on PATH, matching
                # the shells. The hooks are what make the two labels mean
                # different destinations. A shell alias or function is not
                # accepted and cannot be: this is a child process that never
                # sources a shell rc, so a hook has to be a real executable.
                hook_name = "y" + pass_target
                hook = shutil.which(hook_name)
                if not hook:
                    return 0, "Local %s hook was not found on PATH" % hook_name
                queued.append(DownloadJob(item, hook))

        with self.lock:
            for job in queued:
                self.jobs.append(job)
                print("Queued: %s -p %s -t %s" % (job.hook, job.path, job.url))
            self._ensure_worker()
        return len(queued), None

    def _ensure_worker(self):
        """Caller holds the lock."""
        if self.worker is not None and self.worker.is_alive():
            return
        self.worker = threading.Thread(target=self._drain, daemon=True)
        self.worker.start()

    def _next_queued(self):
        with self.lock:
            for job in self.jobs:
                if job.state == "queued":
                    job.state = "running"
                    return job
        return None

    def _drain(self):
        while True:
            job = self._next_queued()
            if job is None:
                return
            self._run(job)

    def _append_log(self, entry):
        print(entry)
        with self.lock:
            self.logs.append(entry)
            if len(self.logs) > HTML3_LOG_LIMIT:
                del self.logs[: len(self.logs) - HTML3_LOG_LIMIT]

    def _run(self, job):
        print("Running: %s -p %s -t %s" % (job.hook, job.path, job.url))
        try:
            process = subprocess.Popen(
                [job.hook, "-p", job.path, "-t", job.url],
                cwd=str(BASE_DIR),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True,
                bufsize=1,
                errors="replace",
            )
        except OSError as error:
            self._append_log("[%s] could not start %s: %s" % (job.target, job.hook, error))
            with self.lock:
                job.state = "failed"
            return

        for raw in iter_process_lines(process.stdout):
            line = strip_control_chars(raw).strip()
            if not line:
                continue
            if "has already been downloaded" in line or (
                line.startswith("[download]") and "100%" in line
            ):
                job.succeeded = True
            if not job.should_emit(line):
                continue
            self._append_log("[%s] %s" % (job.target, line))
        process.stdout.close()
        rc = process.wait()

        with self.lock:
            # A hook that reports failure but demonstrably finished the
            # transfer still counts, mirroring the shells.
            job.state = "completed" if (rc == 0 or job.succeeded) else "failed"
        if job.state == "completed":
            add_downloaded_video(job.channel_id, job.video_id, job.target)

    def status(self):
        with self.lock:
            counts = {"running": 0, "queued": 0, "completed": 0, "failed": 0}
            for job in self.jobs:
                counts[job.state if job.state in counts else "failed"] += 1
            counts["logs"] = list(self.logs[-HTML3_LOG_WINDOW:])
            return counts

    def active_count(self):
        with self.lock:
            return sum(1 for job in self.jobs if job.state in ("queued", "running"))


def add_downloaded_video(channel_id, video_id, target):
    """Record a completed download, keeping any original timestamp."""
    records = read_downloaded_videos()
    key = (channel_id, video_id, target)
    if any(downloaded_key(record) == key for record in records):
        print(
            "Downloaded-video record already exists; keeping original "
            "timestamp: %s / %s / %s" % key
        )
        return
    print("Recording completed download: %s / %s / %s" % key)
    records.append(
        {
            "channel_id": channel_id,
            "video_id": video_id,
            "target": target,
            "download_epoch": now_sec(),
        }
    )
    save_downloaded_videos(records)


def apply_channel_change(payload):
    """Apply an add/delete from the Channel IDs table. Returns an error or None."""
    action = coerce_str(payload.get("action"))
    channel = trim(coerce_str(payload.get("channel")))
    if not channel or any(c in channel for c in "\r\n#"):
        return "Invalid channel id."
    if action not in ("add", "delete"):
        return "Invalid channel action."

    content = read_text_file(CHANNELS_FILE)
    kept = []
    found = False
    wanted = channel.lstrip("@")
    for line in (content or "").splitlines():
        # read_channels() strips a leading @, so the page sends the bare
        # handle even when the file stores "@handle". Compare both stripped
        # or deleting such an entry would silently never match.
        if trim(line).lstrip("@") == wanted:
            found = True
            if action == "delete":
                continue
        kept.append(line)
    if action == "add" and not found:
        kept.append(channel)
    try:
        write_text_file(CHANNELS_FILE, kept)
    except OSError:
        return "Could not update %s." % CHANNELS_FILE.name
    return None


# --- the scan worker and its state ----------------------------------------

class Html3State:
    """Everything the page polls for, guarded by one lock."""

    def __init__(self):
        self.lock = threading.Lock()
        self.status = "running"
        self.message = "Loading channels..."
        self.error = ""
        self.completed = 0
        self.total = 0
        self.updates = []
        self.fragments = {}
        self.channels_html = ""
        self.failed = []
        self.worker = None

    def reset(self):
        with self.lock:
            self.status = "running"
            self.message = "Loading channels..."
            self.error = ""
            self.completed = 0
            self.total = 0
            self.updates = []
            self.fragments = {}
            self.failed = []

    def publish_fragment(self, channel, html_text):
        with self.lock:
            index = len(self.updates)
            self.fragments[index] = html_text
            self.updates.append({"channel": channel, "fragment": index})

    def set_progress(self, completed, total):
        with self.lock:
            self.completed = completed
            self.total = total
            self.message = "Loading channels: %s / %s" % (completed, total)

    def finish(self, status, message, error="", failed=()):
        with self.lock:
            self.status = status
            self.message = message
            self.error = error
            self.failed = list(failed)

    def snapshot(self):
        with self.lock:
            return {
                "status": self.status,
                "success": self.status == "success",
                "message": self.message,
                "error": self.error,
                "completed": self.completed,
                "total": self.total,
                "updates": list(self.updates),
                "failed_channels": [
                    {"channel": name, "stage": stage} for name, stage in self.failed
                ],
            }

    def fragment(self, index):
        with self.lock:
            return self.fragments.get(index)

    def channels(self):
        with self.lock:
            return self.channels_html

    def set_channels(self, html_text):
        with self.lock:
            self.channels_html = html_text

    def running(self):
        return self.worker is not None and self.worker.is_alive()

    def start(self, refresh_all):
        self.reset()
        self.worker = threading.Thread(
            target=html3_scan_worker, args=(self, refresh_all), daemon=True
        )
        self.worker.start()


def html3_scan_worker(state, refresh_all):
    """Scan every channel and publish one fragment each, as they settle."""
    try:
        channels = read_channels()
        if channels is None:
            state.finish("error", "Page generation failed.", "No channels to scan.")
            return

        checkpoint_ms = read_checkpoint_ms()
        cutoff_ms = scan_cutoff_for(checkpoint_ms) * 1000
        downloaded = {downloaded_key(record) for record in read_downloaded_videos()}

        def on_channel(channel, entries, channel_id):
            fragment, _visible, _dropped = render_channel_fragment(
                channel, channel_id, entries, cutoff_ms, downloaded
            )
            state.publish_fragment(channel, fragment)

        state.set_progress(0, len(channels))
        per_channel, failures = scan_all_channels(
            channels,
            checkpoint_ms,
            True,
            refresh_all,
            on_progress=state.set_progress,
            on_channel=on_channel,
        )
        if per_channel is None:
            state.finish(
                "error", "Page generation failed.", "Could not scan any channel."
            )
            return

        status = read_channel_check_status()
        keys = [c.lstrip("@") for c in channels]
        missing = [k for k in keys if not coerce_str((status.get(k) or {}).get("thumbnail"))]
        for key, thumbnail in channel_thumbnails_concurrent(missing).items():
            record = status.setdefault(
                key, {"checked_ms": 0, "latest_video_ms": 0, "thumbnail": ""}
            )
            record["thumbnail"] = thumbnail
        save_channel_check_status(status)

        state.set_channels(render_channels_section(channels, status, failures))

        if failures:
            summary = ", ".join("@%s (%s)" % (c, s) for c, s in failures)
            print("HTML3 completed with channel errors: %s" % summary)
        else:
            print("HTML3 completed with no channel errors.")
        state.finish("success", "", failed=failures)
    except Exception as error:  # a worker crash must surface on the page
        sys.stderr.write("HTML3 worker failed: %s\n" % error)
        state.finish("error", "Page generation failed.", str(error))


# --- the callback server ---------------------------------------------------

def build_html3_handler(token, state, jobs, control):
    from http.server import BaseHTTPRequestHandler

    class Html3Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "yy"

        def log_message(self, *_args):
            """The console is the scan log, not an access log."""

        # --- replies ---
        def _send(self, code, body, content_type="application/json; charset=utf-8"):
            payload = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                self.wfile.write(payload)
            except OSError:
                # A page that navigated away mid-reply is not an error.
                pass

        def _json(self, code, payload):
            self._send(code, json.dumps(payload))

        def _message(self, code, message):
            self._json(code, {"message": message})

        def _html(self, code, body):
            self._send(code, body, "text/html; charset=utf-8")

        def _body(self):
            length = coerce_int(self.headers.get("Content-Length"))
            if length <= 0:
                return {}
            try:
                return json.loads(self.rfile.read(length).decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                return {}

        # --- routing ---
        def do_GET(self):
            path = self.path.split("?", 1)[0]
            control.touch()
            if path == "/":
                self._html(200, render_loading_page(token, "Loading channels..."))
                return
            prefix = "/html3/%s/" % token
            if path.startswith(prefix):
                rest = path[len(prefix) :]
                if rest == "state":
                    self._json(200, state.snapshot())
                    return
                if rest == "channels":
                    self._html(200, state.channels())
                    return
                if rest.startswith("fragment/"):
                    index = rest[len("fragment/") :]
                    if index.isdigit():
                        fragment = state.fragment(int(index))
                        if fragment is not None:
                            self._html(200, fragment)
                            return
                    self._message(404, "Not found")
                    return
            if path == "/status/%s" % token:
                self._json(200, jobs.status())
                return
            self._message(404, "Not found")

        def do_POST(self):
            path = self.path.split("?", 1)[0]
            control.touch()
            if not path.endswith("/%s" % token):
                self._message(404, "Not found")
                return
            action = path[1 : -(len(token) + 1)]

            if action == "heartbeat":
                self._message(200, "")
            elif action == "stop":
                self._message(200, "Server stopped.")
                control.stop()
            elif action == "checkpoint":
                checkpoint_ms = now_ms()
                set_checkpoint_at(checkpoint_ms)
                self._json(
                    200,
                    {"message": "Checkpoint updated.", "checkpoint_ms": checkpoint_ms},
                )
            elif action in ("refresh", "refresh-all"):
                refresh_all = action == "refresh-all"
                print(
                    "Refreshing HTML page from %s channels in channel-ids.txt..."
                    % ("all" if refresh_all else "recent")
                )
                if state.running():
                    self._message(409, "A page update is already running.")
                else:
                    state.start(refresh_all)
                    self._message(202, "Refreshing page.")
            elif action == "channel":
                error = apply_channel_change(self._body())
                if error:
                    self._message(400, error)
                else:
                    self._message(200, "Channel IDs updated. Refreshing page.")
            elif action == "download":
                payload = self._body()
                items = payload.get("items")
                started, error = jobs.submit(items if isinstance(items, list) else [])
                if error:
                    self._message(400, error)
                else:
                    self._message(200, "Started %s local download job(s)." % started)
            else:
                self._message(404, "Not found")

        def do_OPTIONS(self):
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Content-Length", "0")
            self.end_headers()

    return Html3Handler


class ServerControl:
    """Heartbeat clock and stop flag, shared with the request handler."""

    def __init__(self):
        self.lock = threading.Lock()
        self.last_beat = now_sec()
        self.stopped = threading.Event()

    def touch(self):
        # Any request proves the page is alive, not just the heartbeat: a
        # background tab may have its dedicated heartbeat timer throttled.
        with self.lock:
            self.last_beat = now_sec()

    def idle_for(self):
        with self.lock:
            return now_sec() - self.last_beat

    def stop(self):
        self.stopped.set()


def open_html3_url(url, incognito):
    """Open the page, preferring a Chrome incognito window when asked."""
    if not incognito:
        return open_url(url)
    chrome_app = Path("/Applications/Google Chrome.app")
    if chrome_app.is_dir() and shutil.which("open"):
        return run_cmd(["open", "-na", "Google Chrome", "--args", "--incognito", url])
    for candidate in (
        "google-chrome",
        "google-chrome-stable",
        "chromium",
        "chromium-browser",
    ):
        exe = shutil.which(candidate)
        if exe:
            try:
                subprocess.Popen(
                    [exe, "--incognito", url],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                print("Opened: %s" % url)
                return 0
            except OSError:
                break
    sys.stderr.write(
        "Warning: Google Chrome was not found; opening HTML3 in the default browser.\n"
    )
    return open_url(url)


def run_html3(incognito):
    """Serve the page until STOP SERVER, Ctrl-C, or the page stops answering."""
    import secrets
    from http.server import ThreadingHTTPServer

    if read_channels() is None:
        return 1

    token = secrets.token_hex(16)
    state = Html3State()
    jobs = JobManager()
    control = ServerControl()
    handler = build_html3_handler(token, state, jobs, control)

    try:
        server = ThreadingHTTPServer((HTML3_HOST, HTML3_PORT), handler)
    except OSError as error:
        sys.stderr.write(
            "Error: http://%s:%s is unavailable (%s)\n"
            % (HTML3_HOST, HTML3_PORT, error)
        )
        return 1
    server.daemon_threads = True

    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.2})
    thread.daemon = True
    thread.start()

    # The shell is written first and the scan runs in the background, so the
    # page is reachable immediately instead of after a full channel sweep.
    state.start(False)
    url = "http://%s:%s/" % (HTML3_HOST, HTML3_PORT)
    open_html3_url(url, incognito)
    print(
        "Waiting for DOWNLOAD SELECTED on %s (Ctrl+C or STOP SERVER exits)" % url
    )

    try:
        while not control.stopped.is_set():
            if control.stopped.wait(0.5):
                break
            # Never abandon a download that is still running or queued just
            # because the browser throttled its timers in a background tab.
            if (
                control.idle_for() >= HTML3_HEARTBEAT_TIMEOUT_SEC
                and jobs.active_count() == 0
            ):
                print("HTML page closed or disconnected; stopping server.")
                break
    except KeyboardInterrupt:
        print("")
    finally:
        server.shutdown()
        server.server_close()
    return 0


# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

USAGE = """\
yy.py - convenience wrapper around ./yt-dlp

Usage:
  yy [<url>] [-t <temp_url>] [-p <path>] [-U] [--no-py]
     [-o | -O | --html3] [--html3-incognito] [-c]
  yy -h | --help

Arguments:
  <url>               Persist this URL to ./current_url.txt, then download it.
                      With no arguments, the stored URL is re-downloaded.

Options:
  -t <temp_url>       Download this URL once, without persisting it.
  -p <path>           Download into <path>. Without -p, a youtube.com/@<id>
                      URL downloads to ./<id>, otherwise to ./t.
  -U                  Update ./yt-dlp, then refresh yy.py and the launcher
                      beside it from the head of master on GitHub, and exit
                      without downloading. The previous copies are kept in
                      .tmp. Exits non-zero if a refresh failed.
  --no-py             Switch this directory back to the shell build: fetch
                      yy.zsh (or yy.ps1) from the root of master, back up the
                      current launcher into .tmp, and replace it. Handled by
                      the launcher itself, not here, so it still works when
                      yy.py or the Python interpreter is the broken thing.
                      The shell build's --py is the inverse.
  -o                  For each channel in ./channel-ids.txt, open its /videos
                      tab only if it has a public video published after
                      ./checkpoint.txt. Exits without downloading, and exits
                      non-zero if any channel could not be checked.
  -O                  Open every channel in ./channel-ids.txt unconditionally,
                      with no check, then exit without downloading.
  --html3             Generate a local 6-column video grid with y1/y2
                      selections and serve it on http://127.0.0.1:8080,
                      opening a loading shell immediately and streaming one
                      fragment per channel from a background worker.
                      Already-downloaded video cards are dropped.
  --html3-incognito   With --html3, open the page in a Chrome/Chromium
                      incognito window instead of the default browser.
  -c                  Overwrite ./checkpoint.txt with the current epoch-ms
                      timestamp, then exit without downloading. Runs after
                      -o/-O, so "-o -c" means "open whatever is new, then mark
                      everything as seen". The checkpoint is held back if at
                      least three checks failed, or if every check failed.
  -h, --help          Show this help and exit.

-o, -O and --html3 are mutually exclusive.
Flag precedence: -h, then -U, then -o/-O/--html3, then -c, then download.

Examples:
  yy 'https://example.com/video'
  yy -t 'https://example.com/one-off'
  yy -p ./my-videos -t 'https://example.com/one-off'
  yy -U
  yy -o -c
  yy -O -c
  yy --html3
  yy --html3 --html3-incognito
"""


def print_usage():
    sys.stdout.write(USAGE)


# ---------------------------------------------------------------------------
# Argument parsing
#
# Hand-rolled rather than argparse so the flag set, the error messages and the
# precedence rules stay exactly what the shell wrappers documented. argparse
# would also prefix-match --html3 from --htm, which was never accepted.
# ---------------------------------------------------------------------------

class Options:
    def __init__(self):
        self.url = None
        self.temp_url = None
        self.output_path = DEFAULT_OUTPUT_PATH
        self.output_path_passed = False
        self.do_update = False
        self.open_mode = None
        self.html3_incognito = False
        self.set_checkpoint = False
        self.show_help = False


def parse_args(argv):
    opts = Options()
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg in ("-h", "--help"):
            opts.show_help = True
        elif arg == "-t":
            index += 1
            if index >= len(argv):
                raise UsageError("-t requires a URL")
            opts.temp_url = argv[index]
        elif arg == "-p":
            index += 1
            if index >= len(argv):
                raise UsageError("-p requires a path")
            opts.output_path = argv[index]
            opts.output_path_passed = True
        elif arg == "-U":
            opts.do_update = True
        elif arg == "-o":
            set_open_mode(opts, "check")
        elif arg == "-O":
            set_open_mode(opts, "open")
        elif arg == "--html3":
            set_open_mode(opts, "html3")
        elif arg == "--html3-incognito":
            opts.html3_incognito = True
        elif arg == "-c":
            opts.set_checkpoint = True
        elif arg.startswith("-") and arg != "-":
            raise UsageError("unsupported flag: %s" % arg)
        elif opts.url is None:
            opts.url = arg
        else:
            raise UsageError("unexpected argument: %s" % arg)
        index += 1
    return opts


class UsageError(Exception):
    pass


def set_open_mode(opts, mode):
    if opts.open_mode is not None and opts.open_mode != mode:
        raise UsageError("-o, -O, and --html3 cannot be combined")
    opts.open_mode = mode


# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

YOUTUBE_HANDLE_RE = re.compile(r"^https?://([^/]+\.)?youtube\.com/@([^/?#]+)")

def main(argv):
    try:
        opts = parse_args(argv)
    except UsageError as error:
        sys.stderr.write("Error: %s\n\n" % error)
        print_usage()
        return 1

    if opts.show_help:
        print_usage()
        return 0

    if opts.html3_incognito and opts.open_mode != "html3":
        sys.stderr.write("Error: --html3-incognito requires --html3\n")
        return 1

    if opts.do_update:
        return run_update()

    # A positional URL is persisted even when -t overrides what actually runs.
    if opts.url:
        TEMPORARY_DIRECTORY.mkdir(parents=True, exist_ok=True)
        write_text_file(URL_FILE, [opts.url])

    if opts.open_mode is not None:
        TEMPORARY_DIRECTORY.mkdir(parents=True, exist_ok=True)
        if opts.open_mode == "html3":
            rc = run_html3(opts.html3_incognito)
            # The page's own CHECKPOINT button is the normal way to advance
            # the checkpoint here; -c still works and applies on exit.
            if opts.set_checkpoint and rc == 0:
                set_checkpoint_at(now_ms())
            return rc
        rc = run_open_mode(check=(opts.open_mode == "check"))
        # -c runs after -O, so "open everything, then mark it all seen" works.
        # The checkpoint is held back when too much of the run failed, so it
        # can never advance past channels that were never really checked.
        if opts.set_checkpoint:
            if should_skip_checkpoint(
                run_open_mode.failure_count, run_open_mode.channel_count
            ):
                sys.stderr.write(
                    "Error: too many channel checks failed; checkpoint not updated\n"
                )
                return 1
            set_checkpoint_at(now_ms())
        return rc

    if opts.set_checkpoint:
        set_checkpoint_at(now_ms())
        return 0

    return download(opts)


def download(opts):
    run_url = opts.temp_url
    if not run_url:
        if opts.url:
            run_url = opts.url
        else:
            stored = read_first_line(URL_FILE)
            run_url = stored or None

    if not run_url:
        sys.stderr.write(
            "Error: no URL provided, and %s does not exist or is empty\n"
            % display_path(URL_FILE)
        )
        return 1

    output_path = opts.output_path
    if not opts.output_path_passed:
        match = YOUTUBE_HANDLE_RE.match(run_url)
        if match:
            output_path = "./" + match.group(2)

    exe = ytdlp_path()
    if exe is None:
        sys.stderr.write("Error: yt-dlp binary not found next to this script\n")
        return 1
    if not COOKIES_FILE.is_file():
        sys.stderr.write(
            "Error: %s does not exist; export YouTube cookies from a browser first\n"
            % display_path(COOKIES_FILE)
        )
        return 1

    return run_cmd(
        [
            "./" + exe.name,
            "--cookies",
            display_path(COOKIES_FILE),
            "--paths",
            output_path,
            run_url,
        ]
    )


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

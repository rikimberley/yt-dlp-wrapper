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
                    on_progress(completed, len(pending))
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
    channels, checkpoint_ms, incremental, refresh_all, on_progress=None
):
    """Full scan cycle: plan, gate, scan, merge, persist.

    Returns (per_channel_entries, failures) where per_channel_entries maps a
    channel to its merged, newest-first entry list.
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

    results = run_scan_pool(plans, exe, COOKIES_FILE, on_progress)

    keep_cutoff_ms = scan_cutoff_for(checkpoint_ms) * 1000
    per_channel = {}
    for plan in plans:
        channel = plan.channel
        scanned_ok, scanned = results.get(channel, (True, []))
        # A gated channel was never scanned, so it has no fresh rows but is
        # not a failure either.
        full_scan_ok = scanned_ok and not plan.skip_scan
        cached_rows = cache.get(channel, {}).get("entries", []) if incremental else []

        if not scanned_ok:
            if incremental:
                sys.stderr.write(
                    "Warning: could not incrementally scan the videos tab for "
                    "@%s; using cached entries\n" % channel
                )
                failures.append(
                    (channel, "could not scan videos tab; using cached entries")
                )
            else:
                sys.stderr.write(
                    "Warning: could not scan the videos tab for @%s\n" % channel
                )
                failures.append((channel, "could not scan videos tab"))
                continue

        entries = merge_channel_entries(cached_rows, scanned, keep_cutoff_ms)
        per_channel[channel] = entries

        newest = max((e.timestamp_ms for e in entries if e.is_public), default=0)
        print(
            "@%s: %s visible video(s) in the checkpoint overlap"
            % (channel, sum(1 for e in entries if e.is_public))
        )

        if incremental:
            prior = cache.get(channel, {})
            cache[channel] = {
                "channel_id": plan.channel_id,
                "checked_ms": batch_ms if scanned_ok else prior.get("checked_ms", 0),
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

        # preserve=1: a scan that found nothing must not erase a channel's
        # known age, or the staleness filter would drop it on the next run.
        record = status.setdefault(
            channel, {"checked_ms": 0, "latest_video_ms": 0, "thumbnail": ""}
        )
        record["checked_ms"] = batch_ms
        if newest:
            record["latest_video_ms"] = newest

    if incremental:
        save_html_video_cache(cache)
    save_channel_check_status(status)
    return per_channel, failures


# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

USAGE = """\
yy.py - convenience wrapper around ./yt-dlp

Usage:
  yy [<url>] [-t <temp_url>] [-p <path>] [-U] [-o | -O | --html3]
     [--html3-incognito] [-c]
  yy -h | --help

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

NOT_IMPLEMENTED = {
    "html3": "--html3",
}


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
        sys.stderr.write("Error: -U is not implemented in this build yet\n")
        return 2

    # A positional URL is persisted even when -t overrides what actually runs.
    if opts.url:
        TEMPORARY_DIRECTORY.mkdir(parents=True, exist_ok=True)
        write_text_file(URL_FILE, [opts.url])

    if opts.open_mode is not None:
        if opts.open_mode in NOT_IMPLEMENTED:
            sys.stderr.write(
                "Error: %s is not implemented in this build yet\n"
                % NOT_IMPLEMENTED[opts.open_mode]
            )
            return 2
        TEMPORARY_DIRECTORY.mkdir(parents=True, exist_ok=True)
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

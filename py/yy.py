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

import codecs
import json
import locale
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

URL_FILE = BASE_DIR / "current_url.txt"          # legacy, read-only fallback
URL_JSON_FILE = BASE_DIR / "current_url.json"
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
# U+FFFD. A real title never contains one, so its presence in the cache is
# proof the row was decoded from the wrong code page.
REPLACEMENT_CHAR = "\ufffd"

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
# Force yt-dlp to encode its output as UTF-8 rather than the locale's.
#
# yt-dlp encodes everything it prints with `encoding or preferredencoding()`,
# and crucially with errors='ignore'. On macOS the locale is already UTF-8 so
# this is a no-op, which is exactly why the bug only ever showed up on
# Windows: there preferredencoding() is the ANSI code page, and a Japanese
# title comes back either as Shift-JIS bytes (which decode to U+FFFD) or, on
# a cp1252 box, with every non-ASCII character silently *deleted*.
#
# Deleted characters are unrecoverable and undetectable downstream, so this
# has to be fixed at the producer. Do not try PYTHONIOENCODING instead --
# yt-dlp's own preferredencoding() takes precedence over it.
YTDLP_ENCODING_ARGS = ("--encoding", "utf-8")
# Bumped whenever a change invalidates previously cached scan text. A record
# stamped lower is force-rescanned once, which is the only way to clear
# damage that leaves no trace in the data itself.
SCAN_ENCODING_VERSION = 1
# In-memory marker set while reading the cache to say "these rows are
# known-bad, re-fetch the whole window". Deliberately not a persisted field:
# zeroing last_full_scan_ms was tried first and silently did nothing, because
# plan_channels falls back to `or checked_ms`, which is recent -- so the
# channel still entered the feed gate and a quiet channel reused its damaged
# cards forever. Keyed with a leading underscore so it cannot collide with a
# real cache field.
FORCE_FULL_SCAN_KEY = "_force_full_scan"

# Availability values that must never be offered for download.
NON_PUBLIC_AVAILABILITY = frozenset(("subscriber_only", "private", "premium_only"))

SCRIPT_RAW_BASE = (
    "https://raw.githubusercontent.com/rikimberley/yt-dlp-wrapper/master/py"
)

# --no-py pulls from the repository *root*, not py/. The two builds live side
# by side under the same names: master/py/yy.zsh is the launcher, master/yy.zsh
# is the shell build. Using SCRIPT_RAW_BASE here would quietly re-fetch the
# launchers and report success while changing nothing.
SHELL_BUILD_RAW_BASE = (
    "https://raw.githubusercontent.com/rikimberley/yt-dlp-wrapper/master"
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


# --- backups ---------------------------------------------------------------

def backup_to_tmp(path):
    """Copy a file to .tmp/<name>.bak, keeping its name and extension.

    Every backup this project takes lands in .tmp/ rather than beside the
    original, so a saved copy is never mistaken for a live state file and the
    git working tree stays clean. Missing sources are not an error -- there is
    simply nothing to preserve.
    """
    source = Path(path)
    if not source.exists():
        return False
    try:
        TEMPORARY_DIRECTORY.mkdir(parents=True, exist_ok=True)
        shutil.copy2(
            str(source), str(TEMPORARY_DIRECTORY / ("%s.bak" % source.name))
        )
        return True
    except OSError as error:
        sys.stderr.write(
            "Warning: could not save a backup copy of %s: %s\n"
            % (display_path(source), error)
        )
        return False


# --- current_url.json ------------------------------------------------------

def read_current_url():
    """Return the persisted URL, preferring current_url.json.

    The JSON file wins and current_url.txt is only a fallback, so a directory
    that has already migrated never drops back to the stale text copy.
    """
    data = read_json_file(URL_JSON_FILE)
    if isinstance(data, dict):
        url = trim(data.get("url"))
        if url:
            warn_if_legacy_url_is_newer(data.get("update_ts"))
            return url
    return read_first_line(URL_FILE)


def warn_if_legacy_url_is_newer(update_ts):
    """Report a current_url.txt that is newer than the JSON's update_ts.

    Only this build writes the JSON; yy.zsh and yy.ps1 still write the .txt.
    So a newer .txt means the URL was last set from one of them and the JSON
    value is about to be used instead. That is a deliberate consequence of
    migrating one build at a time, but it must not be silent -- a wrong URL
    would otherwise just download the wrong video with no explanation.
    """
    try:
        stamp = int(update_ts)
    except (TypeError, ValueError):
        return
    try:
        legacy_ms = int(URL_FILE.stat().st_mtime * 1000)
    except OSError:
        return
    if legacy_ms > stamp:
        sys.stderr.write(
            "Warning: %s is newer than %s; using the JSON value. The URL was "
            "probably set from yy.zsh or yy.ps1, which still write only the "
            ".txt file.\n" % (display_path(URL_FILE), display_path(URL_JSON_FILE))
        )


def write_current_url(url):
    """Persist the URL as JSON, preserving the legacy .txt on first write.

    current_url.txt is copied, not moved: yy.zsh and yy.ps1 have not migrated
    and still read it, so removing it would break them outright.
    """
    if not URL_JSON_FILE.exists():
        backup_to_tmp(URL_FILE)
    return write_json_file(
        URL_JSON_FILE, {"url": url, "update_ts": now_ms()}
    )


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
                "scan_encoding_version": coerce_int(
                    record.get("scan_encoding_version")
                ),
                "feed_newest_ms": coerce_int(record.get("feed_newest_ms")),
                "entries": entries,
            }
            if cache[channel]["scan_encoding_version"] < SCAN_ENCODING_VERSION:
                # Written before yt-dlp was forced to UTF-8, so the titles may
                # be mojibaked. This cannot be detected by inspecting them: on
                # a cp1252 console yt-dlp encodes with errors='ignore', which
                # *deletes* every non-ASCII character rather than leaving a
                # U+FFFD behind, so the damage is invisible and the check
                # below would miss it entirely. Force one rescan instead.
                cache[channel][FORCE_FULL_SCAN_KEY] = True
            if any(REPLACEMENT_CHAR in entry["title"] for entry in entries):
                # This row was decoded from the wrong code page and is already
                # mojibaked, so it has to be re-fetched rather than reused.
                cache[channel][FORCE_FULL_SCAN_KEY] = True
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
    # FORCE_FULL_SCAN_KEY is an in-memory signal only. Persisting it would
    # pin the channel to a full scan on every subsequent run.
    write_json_file(
        HTML_VIDEO_CACHE_FILE,
        {
            channel: {
                key: value
                for key, value in record.items()
                if key != FORCE_FULL_SCAN_KEY
            }
            for channel, record in cache.items()
        },
    )


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


def decode_child_output(raw):
    """Decode a child process's captured stdout without manufacturing U+FFFD.

    Second line of defence only. yt-dlp is now invoked with
    YTDLP_ENCODING_ARGS, so its output is UTF-8 on every platform and the
    first branch below is the normal case. This remains because the fallback
    is cheap and the failure it guards against is expensive.

    An earlier revision of this comment claimed the frozen PyInstaller build
    pins the interpreter to UTF-8 mode. That was wrong, and the mistake is
    worth recording: it was concluded from a macOS test, where the locale is
    UTF-8 and so every encoding path looks identical. yt-dlp actually honours
    preferredencoding(), which is why only Windows was affected.

    The original code decoded with errors="replace" and nothing else, which is
    lossy in the one way that matters: any byte that is not valid UTF-8 is
    burned down to U+FFFD, the damaged title is written to
    html-video-cache.json, and the page then re-serves that corruption as
    perfectly valid UTF-8 for the 45-day life of the record. Decoding with the
    local ANSI code page instead recovers the text, so a child that does emit
    legacy bytes round-trips rather than being destroyed. Replacement
    characters remain only as a last resort, so a genuinely undecodable byte
    still cannot abort a scan.
    """
    if not raw:
        return ""
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        pass
    fallback = locale.getpreferredencoding(False)
    try:
        is_utf8 = bool(fallback) and codecs.lookup(fallback).name == "utf-8"
    except LookupError:
        is_utf8 = True
    if not is_utf8:
        try:
            return raw.decode(fallback)
        except (UnicodeDecodeError, LookupError):
            pass
    return raw.decode("utf-8", "replace")


def run_ytdlp_metadata(args, deadline_sec=YTDLP_DEADLINE_SEC, progress_label=None):
    """Run yt-dlp and capture stdout.

    deadline_sec of 0 waits forever, which a full channel scan legitimately
    needs. Returns (returncode, stdout); a timeout reports returncode 124 to
    match the shell's convention.
    """
    cmd = [str(part) for part in args]
    # Inject centrally so no call site can forget it. Guarded because the
    # caller is free to pass its own --encoding.
    if "--encoding" not in cmd:
        cmd[1:1] = list(YTDLP_ENCODING_ARGS)
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
    out = decode_child_output(completed.stdout)
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

# --no-py replaces exactly the two shell wrappers; yy.py is deliberately not in
# this list, because the point is to stop using it, not to refresh it.
NO_PY_TARGETS = tuple(
    (name, sentinel) for name, sentinel in UPDATE_SENTINELS if name != "yy.py"
)

# Present in both launcher headers and in neither shell build. Keep the two
# py/ headers carrying this exact phrase.
LAUNCHER_MARKER = "Thin launcher for yy.py"


def write_self_file(name, body):
    """Atomically replace one file beside this script. Returns True on success.

    Shared by -U and --no-py so there is exactly one implementation of the
    staging rules below.
    """
    target = SCRIPT_DIR / name
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
            backup_to_tmp(target)
        elif name.endswith(".zsh"):
            # --no-py can create a yy.zsh where none existed, and a fresh file
            # is not executable. -U never reaches this branch; it skips files
            # that are absent.
            try:
                os.chmod(str(temp_path), 0o755)
            except OSError:
                pass
        os.replace(str(temp_path), str(target))
    except OSError as error:
        sys.stderr.write("Warning: could not write %s: %s\n" % (name, error))
        try:
            temp_path.unlink()
        except OSError:
            pass
        return False
    return True


def fetch_self_file(name, sentinel, base=None):
    """Fetch one wrapper from master and check its sentinel. None on failure."""
    url = "%s/%s" % (base or SCRIPT_RAW_BASE, name)
    body = fetch_url(url, "%s from master" % name, send_consent=False)
    if body is None:
        sys.stderr.write("Warning: could not refresh %s from master\n" % name)
        return None
    if not body.startswith(sentinel):
        sys.stderr.write(
            "Warning: refusing to overwrite %s: fetched body does not start "
            "with %s\n" % (name, sentinel)
        )
        return None
    return body


def update_self_file(name, sentinel):
    """Refresh one file beside this script. Returns True when it is current."""
    body = fetch_self_file(name, sentinel)
    if body is None:
        return False

    if read_text_file(SCRIPT_DIR / name) == body:
        print("%s is already up to date" % name)
        return True

    if not write_self_file(name, body):
        return False

    print("Updated %s from master (previous copy saved in .tmp)" % name)
    return True


def run_no_py():
    """--no-py: replace both launchers with the shell build from master.

    This used to live in the launchers themselves, where it was more than half
    of each file and was implemented twice -- two independent copies of the
    fetch, sentinel check and atomic write. It is handled here instead so the
    launchers are nothing but interpreter discovery plus a handoff.

    Both wrappers are replaced, not just the one that was invoked: a shell-build
    yy.zsh sitting next to a yy.ps1 launcher is two different builds sharing one
    state directory, and whichever wrapper the next run picks would decide which
    build it got.

    Every payload is fetched and validated before anything is written, so a
    failure mid-way cannot leave the directory holding one wrapper from each
    build. The launchers could not do this -- each knew only about itself.
    """
    bodies = {}
    for name, sentinel in NO_PY_TARGETS:
        body = fetch_self_file(name, sentinel, base=SHELL_BUILD_RAW_BASE)
        if body is not None and LAUNCHER_MARKER in body:
            # The shebang sentinel cannot tell the two builds apart -- they
            # share it -- so a wrong base URL would fetch the launcher, pass
            # validation, and report success having changed nothing. This is
            # the check that catches it.
            sys.stderr.write(
                "Warning: refusing to overwrite %s: fetched body is a launcher, "
                "not the shell build\n" % name
            )
            body = None
        if body is None:
            sys.stderr.write(
                "Error: --no-py aborted; nothing was written. The directory is "
                "still the Python build.\n"
            )
            return 1
        bodies[name] = body

    ok = True
    for name, _ in NO_PY_TARGETS:
        if not write_self_file(name, bodies[name]):
            ok = False
    if not ok:
        sys.stderr.write(
            "Error: --no-py wrote only part of the shell build. Re-run it; what "
            "already landed is kept.\n"
        )
        return 1

    print("Switched to the shell build. Previous copies are in .tmp.")
    if SCRIPT_PATH.exists():
        print("yy.py is left in place but unused; the shell build never reads it.")
    return 0


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

    def __init__(self, channel, channel_id, cutoff_sec, last_full_ms, force_full=False):
        self.channel = channel
        self.channel_id = channel_id
        self.cutoff_sec = cutoff_sec
        self.last_full_ms = last_full_ms
        # Set when the cached rows are known-bad and must be re-fetched over
        # the whole retention window, whatever the public feed says.
        self.force_full = force_full
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
        force_full = False
        if incremental and channel in cache:
            record = cache[channel]
            force_full = bool(record.get(FORCE_FULL_SCAN_KEY))
            # A forced record keeps base_cutoff (the whole retention window)
            # and last_full_ms 0, so the feed gate below cannot reach it and
            # every cached row is re-fetched rather than just the newest day.
            if not force_full:
                last_full_ms = record.get("last_full_scan_ms", 0) or record.get(
                    "checked_ms", 0
                )
                if last_full_ms > 0:
                    candidate = day_start_sec(last_full_ms // 1000) - 86400
                    cutoff_sec = max(cutoff_sec, candidate)
        plans.append(
            ChannelPlan(channel, channel_id, cutoff_sec, last_full_ms, force_full)
        )
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
        and not plan.force_full
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
                        # Only a real scan proves these entries came from a
                        # UTF-8-forced yt-dlp; a cache hit carries the old
                        # stamp forward so it stays eligible for the rescan.
                        "scan_encoding_version": (
                            SCAN_ENCODING_VERSION
                            if full_scan_ok
                            else prior.get("scan_encoding_version", 0)
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

HTML3_PAGE_TEMPLATE = r"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>YouTube Video Download</title><link rel="icon" type="image/png" href="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAMAAACdt4HsAAAB/lBMVEXdZJ6vV2CXWSfUpTbsY6K7jJHCO37n0rHHeFW+kB7DP4D/AP+9klr/AAC/NnzxcK2+QIWjMFiqVar/f/+4PYPoyWndrcONNz3/P7/28N3knb7LRYb+/f3jXJrsZKK5N3jaVJPEPYDBO33nYJ4AAAD+5nC5hRGueArux1GxRXfy5+mnKmfImCz99Zvoydbn1tLTplKWN1bw2ePVpzb62mnCQn7//KK8iimkahSzeS3PmLHp1a6XR0vGlBbZtHL/f3/r2Y6bVSzw5dbixZXQaJm6eJXuZaS3Vm28NnqaNWbaw6vKmVLmu0zddqfJiGn401jWt8T/VarGZ3G/P3+0WoN/AH+NJVTVpbfvZqTAOX21ZIisdFPBU3bmosHWubKnaizJp4ybLWuqVVXBPH+7Nnu0h2SaWxeTSy/cwpLWt4/mYZ6eYQ+waUvnYqLFhVjMmGrasEvou9Dcxsa4ilHiu2nPp3LFmY7Bjhu+OHu+Zmr0aKjx45OIHFXPjqx/AADijbQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAALwSMuAAAAgHRSTlPp////kv+p////zQH/AZEV//8DAv////8E///+//7+/v/+/v4A//////////////////////////////////8C////////UP9L//////////8D/wT/Av//yMv//////////wNOJf//////Q///Jf/////////////I/7////8C/+cQjRsAAAVESURBVHjanZcHVxs5FIVF3fSySbbJtjTj8TQbFzyOewNsbDAl9BpgqYH0bHr76/skjRcb0CzJOz6M/KT7zdOVZI6QxqJ8XVus968ELhkr/fVF7WaZSxH780jT6hJ1MChh1LlMAOa1259kL5ubk/V8egZCDnik1aXFohfTSNpZZzUg7VftWD5bWipRee8xiFFZe+ZhF6088AAEnmlldK+8EpAYFQj654ZCc35pd2ClfA+BAUHWDopP5zMQpNNDoWkq64dPXUO3ETRkgUsPQ3Es7w+gP9Cxh96/UXkYMjf8HoRj1B/wB2GEH+Lck84NDYVCczQo6ff7A/0IBfyyCOLphwB4joPSIQGE/B4BFgAgjr3GeAEoWAAAc4P+LODjEAOEPv4sACzggOf4hwGYwksps4AB4pieZi8BwHRqM2qP4anxigCY45SnN+1XUxTT/wFQ+n3YB4HHfI8rYgrMBEjbLD28ibrrgK+d4cdTXO6zEfzJCxND07id5owxxmvHGQDe9HVGhU8hFKfR01x0DXcqzgBgoG2djh75zADOL6w9ay3kYBY5kqJyAJMu3H11+ro/P4O+wpsLJEWs2hrpfmMXADN9juDfmAc9MYFwHKfEG2NQuUoxlQMwf/MCxsvsSZouoeKUbAHA+C9fFEsBOMcttmiKNxbu7tuCkH85wgEqX4kYlgAwFR6nqMIBL8wH2y4gzmupLburgL0BhPbwkaMzTukxT42+zHetbVSyjBbfKrHnpjnKZaZjvuCTOEpOcOG7ddfYTeU8AAwi4n3/OAKQNx0nzlPxCAfsZ/qyW8KWdz1M8B8A2qmNK5PJJwIwIwAjLccx37KaIgIwmUwm0zfELOJ69ul4ikMQxuNXJlvmzIwZF5a5UwCSM8NSbzsAyazYpXakWCy+BwjGDLA+2WdCRMQMW60j4R2kAGBnk318K09GIPQ3YosbxaKuZ7d6OADfJ83C0/TLpNhx+SQfH3vSMk3IvMsm05z8hgEiGd7ePtmqFprkDhYAbFmkuZMoHAqL3sKqvd7Pxk2zL++LbaUjab6RtnUoO2JwpwpLzSaxLNwGMIRFyJdae6m3mdzsK/ns9WwknXaP5lE8nj4YYAdzCdSWULoAAVlyD3IsmzTNVgtO4UQmctWdN4vHiSX2kjVyquoAwFaw3O1vT4zmed2+Sd2tmh+UBAnDPo916LsBQBj2dcdIOq3vu+fSNx7GBIpEcgAmJOcW4WufRUPPVJ8us29fw5idmOFO/VkAToXJWm72dXR2IFGwXYKhH35pLuSWQajCDGqeAECQMA/ye68ofeSGUbhvQRZjBQqIhrE3oB13LKPq/iIcjROVpRQMFlnkkoAUyaYP1l+7vwFf4RdNHQN9rbsADwAmvcW0cbA+0TZ1mO+SHLk8oHD1fVE/6e0dmLVP13X5BwAJ/b2u60amd6lprdVqAzb8cyFn9J4AsgVnFhYxQwhbGTgAsDb48oAUqbICDKNKUi7xglGegIIAFFzAheEBUEnCYIBMQuwCCUCB/QGBzz8VQjIMcEIIS144DivoGv9+YRBmgmEcAkAW+Boa9AIUGKDgBRhEu4qqSnq5CdwCmV5VdtH8KhAkQXYyunFAiHSAsjqPtF0sB4SrunEYlgPwLtyZFj9ISyAwByMhr0BZXSzDpWsP7GKj+af7CYAMA1zUrxJF3YNLl/a31gC7JLGTOdmR9alKA8T84tlQFcmgcLUalnQpakNcPNnVd29QkSASCYlcGdxrX301KERrrKryiZwvXl1tcJkL0BZvat8atz5cFvDhVuObdn2RX///BQWVQ1G7ZU7MAAAAAElFTkSuQmCC"><style>:root{--bg:#0d1117;--card:#161b22;--bd:#30363d;--fg:#e6edf3;--mut:#8b949e;--acc:#58a6ff}*{box-sizing:border-box}body{margin:0;padding:16px 60px;background:var(--bg);color:var(--fg);font:14px/1.55 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif}h1{font-size:32px;margin:0 0 6px;padding-bottom:0}h2{font-size:22px;margin:0}.channel-title h2 a{color:var(--acc)}p{color:var(--mut);font-size:12.5px;margin:0 0 16px}button{background:#21262d;color:var(--fg);border:1px solid var(--bd);border-radius:6px;padding:5px 10px;cursor:pointer;font:inherit}button:disabled,input:disabled{opacity:.55;cursor:wait}.controls,.checks,.channel-title{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.controls button{padding:4px 9px}.channel{margin-top:28px}.channel-title{padding-bottom:6px;border-bottom:1px solid var(--bd)}.grid{display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:12px;margin:12px 0 28px}.card{background:var(--card);border:1px solid var(--bd);padding:10px;border-radius:10px}.video-link{display:block;color:var(--fg);text-decoration:none}.preview{aspect-ratio:16/9;background:#0b0f14;overflow:hidden;border-radius:6px}.preview img{width:100%;height:100%;object-fit:cover}.video-title{font-size:12px;line-height:1.4;margin-top:7px}.checks{margin-top:8px;color:var(--mut)}.video-age{font-size:11px;color:var(--mut);margin-top:3px}.job-log{max-height:190px;overflow:auto;background:#010409;border:1px solid var(--bd);border-radius:6px;padding:8px;color:var(--mut);white-space:pre-wrap;font:12px/1.4 Consolas,monospace}.back-to-top{position:fixed;bottom:24px;right:24px;width:48px;height:48px;border-radius:50%;background:var(--acc);color:var(--bg);border:0;display:none;font-size:34px;font-weight:700}.back-to-top.visible{display:flex;align-items:center;justify-content:center}#html3-progress{margin:0 0 16px}.html3-progress-track{height:8px;overflow:hidden;border-radius:4px;background:#30363d}.html3-progress-bar{height:100%;width:0;background:#58a6ff;transition:width .25s ease}@media(max-width:1100px){body{padding:16px}.grid{grid-template-columns:repeat(3,minmax(0,1fr))}}@media(max-width:650px){.grid{grid-template-columns:repeat(2,minmax(0,1fr))}}<style>.video-age{font-size:11px;color:var(--mut);margin-top:3px}.channel-bar{height:8px;background:var(--acc);margin:42px 0 12px}.channel-table{width:100%;border-collapse:collapse;margin-top:12px}.channel-table th,.channel-table td{padding:8px;border-bottom:1px solid var(--bd);text-align:left}.channel-table th{color:var(--mut)}.channel-table a{color:var(--acc)}.channel-table tr.html3-channel-error td{background:#3C050F;border-bottom-color:#7a1828;color:#fff}.channel-table tr.html3-channel-error a{color:#fff}#channel-add{width:27em}h2{color:var(--acc)}.channel-title h2 a{text-decoration:underline;text-underline-offset:3px}button:hover{border-color:var(--acc);background:#1c2230}.video-link:hover{color:var(--acc)}.preview{position:relative}.preview img{transition:transform .2s ease,filter .2s ease}.card:hover .preview img{transform:scale(1.04);filter:brightness(.82)}.back-to-top{border:none;box-shadow:0 2px 8px rgba(0,0,0,.45)}.back-to-top:hover{background:#79c0ff}#html3-error-panel{position:fixed;z-index:10;top:18px;left:50%;transform:translateX(-50%);max-width:min(720px,calc(100vw - 32px));padding:16px 20px;border:2px solid #ff7b72;border-radius:8px;background:#1b1114;box-shadow:0 8px 28px rgba(0,0,0,.55);color:#ff7b72;font-size:18px}#html3-error-panel[hidden]{display:none}</style><style>.html3-progress-bar{position:relative;overflow:hidden}.html3-progress-bar.loading::after{content:"";position:absolute;inset:0;transform:translateX(-100%);background:linear-gradient(90deg,transparent,rgba(255,255,255,.42),transparent);animation:html3-progress-shimmer 1.2s linear infinite}@keyframes html3-progress-shimmer{to{transform:translateX(100%)}}</style></head><body><h1>YouTube Video Download</h1><div id="html3-progress" role="status" aria-live="polite"><div class="html3-progress-track"><div class="html3-progress-bar"></div></div><p id="html3-progress-status">__MESSAGE__</p></div><p>Select y1 and/or y2, then click DOWNLOAD SELECTED to run the matching local yy hook. <span id="checkpoint-value">__CHECKPOINT__</span></p><div class="controls"><button id="download" type="button">DOWNLOAD SELECTED</button><button id="checkpoint" type="button">CHECKPOINT</button><button id="refresh" type="button">REFRESH</button><button id="refresh-all" type="button">REFRESH ALL</button><button id="stop" type="button">STOP SERVER</button><button data-action="y1" type="button">y1</button><button data-action="y2" type="button">y2</button><button data-action="none" type="button">none</button></div><p id="status"></p><div id="html3-error-panel" role="alert" aria-live="assertive" hidden><div id="html3-errors"></div></div><pre id="job-log" class="job-log"></pre><main><section id="channel-ids" class="channel"><div class="channel-bar"></div><div class="channel-title"><h2>Channel IDs</h2></div><p>Loading Channel IDs...</p></section></main><button id="back-to-top" class="back-to-top" type="button" aria-label="Back to top" title="Back to top">&uarr;</button><script>(()=>{const token="__TOKEN__",base="/html3/"+token,stateUrl=base+"/state",fragmentUrl=i=>base+"/fragment/"+i,channelsUrl=base+"/channels",api=n=>"/"+n+"/"+token,controls=[...document.querySelectorAll("button,input")],top=document.querySelector("#back-to-top"),status=document.querySelector("#status"),errors=document.querySelector("#html3-errors"),errorPanel=document.querySelector("#html3-error-panel"),log=document.querySelector("#job-log"),applied=new Set(),saved=new Set();let html3Failures=[];const html3FailureSummary=()=>html3Failures.length?"Completed with channel errors: "+html3Failures.map(x=>"@"+x.channel+" ("+x.stage+")").join(", "):"";const compactLogs=logs=>{const buckets=new Map(),percents=new Map();return logs.filter(line=>{if(/^\[y[12]\]\s*$/.test(line))return false;const m=line.match(/^(\[[^\]]+\])\s+\[download\]\s+([0-9]+(?:\.[0-9]+)?)%/);if(!m)return true;const target=m[1],percent=Number(m[2]),previous=percents.get(target);if(previous!==undefined&&percent<previous-1)buckets.set(target,-1);percents.set(target,percent);const bucket=Math.floor(percent/10),last=buckets.has(target)?buckets.get(target):-1,emit=bucket>last||percent>=100;if(emit)buckets.set(target,bucket);return emit})};const showJobs=async()=>{let again=false;try{const b=await (await fetch(api("status"),{cache:"no-store"})).json(),p=[];if(b.running)p.push(b.running+" running");if(b.queued)p.push(b.queued+" queued");if(b.completed)p.push(b.completed+" completed");if(b.failed)p.push(b.failed+" failed");status.textContent=p.length?p.join(", ")+"." : "No download jobs yet.";log.textContent=compactLogs(b.logs||[]).join("\n");log.scrollTop=log.scrollHeight;if(b.running||b.queued)again=true}catch(e){status.textContent="Status unavailable: "+e.message;again=true}finally{if(again)setTimeout(showJobs,1000)}};const relativeCheckpoint=ms=>{const s=Math.max(0,Math.floor((Date.now()-Number(ms))/1000)),u=[[31536000,"year"],[2592000,"month"],[604800,"week"],[86400,"day"],[3600,"hour"],[60,"minute"]];if(s<60)return "just now";for(const[d,n]of u)if(s>=d){const x=Math.floor(s/d);return x+" "+n+(x===1?"":"s")+" ago"}},checkpointText=ms=>{if(!ms)return "";const d=new Intl.DateTimeFormat("en-US",{timeZone:"America/Los_Angeles",year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",second:"2-digit",hourCycle:"h23"}).format(new Date(Number(ms)));return "Checkpoint: "+d+" Pacific Time ("+relativeCheckpoint(ms)+")"};const key=x=>x.dataset.channelId+"|"+x.dataset.videoId+"|"+x.className,remember=()=>document.querySelectorAll("input.y1:checked,input.y2:checked").forEach(x=>saved.add(key(x))),setBusy=b=>document.querySelectorAll("button,input").forEach(x=>{if(x!==top)x.disabled=b});const apply=async u=>{if(!u||applied.has(u.channel))return;const r=await fetch(fragmentUrl(u.fragment),{cache:"no-store"});if(!r.ok)return;const text=await r.text(),old=[...document.querySelectorAll("section.channel")].find(x=>x.dataset.html3Channel===u.channel);applied.add(u.channel);if(!text){if(old)old.remove();return}remember();const t=document.createElement("template");t.innerHTML=text;const fresh=t.content.firstElementChild;if(old)old.replaceWith(fresh);else document.querySelector("main").insertBefore(fresh,document.querySelector("#channel-ids"));fresh.querySelectorAll("input.y1,input.y2").forEach(x=>{if(saved.has(key(x)))x.checked=true});fresh.querySelectorAll("button,input").forEach(x=>x.disabled=false)};const applyChannelIds=async()=>{const r=await fetch(channelsUrl,{cache:"no-store"});if(!r.ok)return;const t=document.createElement("template");t.innerHTML=await r.text();const fresh=t.content.firstElementChild,old=document.querySelector("#channel-ids");if(fresh&&old)old.replaceWith(fresh)};const poll=async()=>{try{const s=await (await fetch(stateUrl,{cache:"no-store"})).json(),bar=document.querySelector(".html3-progress-bar");bar.classList.toggle("loading",s.status==="running");if(s.status==="running")document.querySelector("#html3-progress-status").textContent=s.message||"Loading channels...";if(s.total){const partial=s.status==="running"?.5:0;bar.style.width=Math.min(100,100*((s.completed||0)+partial)/s.total)+"%";}for(const u of (Array.isArray(s.updates)?s.updates:(s.updates?[s.updates]:[])))await apply(u);if(s.status==="success"){await applyChannelIds();setBusy(false);document.querySelector("#html3-progress-status").textContent="";html3Failures=Array.isArray(s.failed_channels)?s.failed_channels:(s.failed_channels?[s.failed_channels]:[]);errors.textContent=html3FailureSummary();errorPanel.hidden=!html3Failures.length;return}if(s.status==="error"){status.textContent=s.error||"Page generation failed.";return}}catch(e){status.textContent="Progress unavailable: "+e.message}setTimeout(poll,500)};document.addEventListener("click",e=>{const b=e.target.closest("button[data-action]");if(!b)return;(b.closest(".channel")||document).querySelectorAll("input.y1,input.y2").forEach(x=>{if(b.dataset.action==="none")x.checked=false;else if(x.className===b.dataset.action)x.checked=true})});document.addEventListener("click",async e=>{const add=e.target.closest("#channel-add-button"),remove=e.target.closest(".channel-delete");if(!add&&!remove)return;const payload=add?{action:"add",channel:document.querySelector("#channel-add").value.trim()}:{action:"delete",channel:remove.dataset.channel};if(!payload.channel)return;const b=await (await fetch(api("channel"),{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)})).json();status.textContent=b.message||"Channel IDs updated.";if(b.message)setTimeout(()=>refresh(false),0)});document.querySelector("#download").onclick=async()=>{const items=[...document.querySelectorAll("input:checked")].map(x=>({target:x.className,url:x.dataset.url,path:x.dataset.path,channel_id:x.dataset.channelId,video_id:x.dataset.videoId}));if(!items.length){status.textContent="Select at least one video";return}status.textContent="Starting local downloads...";try{const b=await (await fetch(api("download"),{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({items})})).json();status.textContent=b.message||"Started";showJobs()}catch(e){status.textContent="Callback failed: "+e.message}};document.querySelector("#checkpoint").onclick=async()=>{const b=await (await fetch(api("checkpoint"),{method:"POST"})).json();status.textContent=b.message;document.querySelector("#checkpoint-value").textContent=b.checkpoint_ms?checkpointText(b.checkpoint_ms):""};const refresh=async all=>{remember();html3Failures=[];errors.textContent="";errorPanel.hidden=true;setBusy(true);const b=await (await fetch(api(all?"refresh-all":"refresh"),{method:"POST"})).json();status.textContent=b.message||"Refreshing";applied.clear();poll()};document.querySelector("#refresh").onclick=()=>refresh(false);document.querySelector("#refresh-all").onclick=()=>refresh(true);document.querySelector("#stop").onclick=async()=>{if(!window.confirm("Stop the local server? Active downloads will continue."))return;try{const b=await (await fetch(api("stop"),{method:"POST"})).json();status.textContent=b.message||"Server stopped"}catch(e){status.textContent="Server stopped"}window.close();setTimeout(()=>location.replace("about:blank"),150)};top.onclick=()=>window.scrollTo({top:0,behavior:"smooth"});const toggle=()=>top.classList.toggle("visible",scrollY>200);addEventListener("scroll",toggle,{passive:true});top.disabled=false;document.addEventListener("click",e=>{if(!errorPanel.hidden&&!errorPanel.contains(e.target))errorPanel.hidden=true});setInterval(()=>fetch(api("heartbeat"),{method:"POST",keepalive:true}),2000);showJobs();setBusy(true);poll()})()</script></body></html>"""

HTML3_HOST = "127.0.0.1"
HTML3_PORT = 8090
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


def find_file_on_path(filename):
    """Locate an exact filename on PATH, extension included."""
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        if not directory:
            continue
        candidate = os.path.join(directory, filename)
        if os.path.isfile(candidate):
            return candidate
    return None


def resolve_download_hook(name):
    """Resolve the y1/y2 hook. Returns (argv_prefix, display) or (None, None).

    On Windows the hooks are yy1.ps1 / yy2.ps1 -- that is what the PowerShell
    build looks for -- and neither half of the obvious approach works:

      * shutil.which(name) cannot find them. On Windows it only matches names
        whose extension is listed in PATHEXT, and .PS1 is not in the default
        PATHEXT. Asking it for "yy1.ps1" does not help either: because .ps1 is
        absent from PATHEXT it appends the PATHEXT entries anyway and looks for
        "yy1.ps1.EXE" and friends.
      * Popen([script, ...]) cannot run one even when handed the full path.
        Windows has no exec handler for .ps1, so it has to go through
        powershell.exe, exactly as the PowerShell build does.

    The result was that DOWNLOAD SELECTED did nothing on Windows under this
    build and said so only in the page's status line: submit() returns the
    "hook was not found" error immediately after loading the download history,
    so the console shows one "Loaded N downloaded-video record(s)." and stops.
    """
    direct = shutil.which(name)
    if direct:
        return [direct], direct

    if os.name == "nt":
        script = find_file_on_path(name + ".ps1")
        if script:
            runner = shutil.which("powershell.exe") or "powershell.exe"
            return (
                [
                    runner,
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    script,
                ],
                script,
            )
    return None, None


class DownloadJob:
    __slots__ = (
        "target",
        "url",
        "path",
        "channel_id",
        "video_id",
        "hook",
        "argv",
        "state",
        "succeeded",
        "last_percent",
        "last_bucket",
    )

    def __init__(self, item, hook, argv=None):
        self.target = item["target"]
        self.url = item["url"]
        self.path = item["path"]
        self.channel_id = item["channel_id"]
        self.video_id = item["video_id"]
        self.hook = hook
        # The command to run, without the per-job -p/-t arguments. Normally
        # just [hook]; on Windows a .ps1 hook carries its powershell.exe
        # prefix here.
        self.argv = list(argv) if argv else [hook]
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
                hook_argv, hook = resolve_download_hook(hook_name)
                if not hook:
                    looked_for = hook_name
                    if os.name == "nt":
                        looked_for = "%s or %s.ps1" % (hook_name, hook_name)
                    message = "Local %s hook was not found on PATH (looked for %s)" % (
                        hook_name,
                        looked_for,
                    )
                    # Also say so on the console. Returning only to the page
                    # left the server printing "Loaded N downloaded-video
                    # record(s)." and nothing else, which reads as a no-op.
                    sys.stderr.write("Error: %s\n" % message)
                    return 0, message
                queued.append(DownloadJob(item, hook, hook_argv))

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
                job.argv + ["-p", job.path, "-t", job.url],
                cwd=str(BASE_DIR),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True,
                bufsize=1,
                # Without an explicit encoding Python decodes with the locale
                # codepage, which mojibakes non-ASCII titles on Windows.
                encoding="utf-8",
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

    class QuietThreadingHTTPServer(ThreadingHTTPServer):
        """Suppress the traceback for a client that simply went away.

        The page polls status every second and heartbeats every two, so a
        reload, a navigation or a closed tab routinely leaves a half-open
        loopback connection. That reset surfaces inside
        BaseHTTPRequestHandler.handle_one_request while it is still reading
        the request line - before do_GET/do_POST run, so the try/except OSError
        around wfile.write() cannot see it. socketserver then prints a full
        traceback for what is entirely normal browser behaviour, which on
        Windows reads alarmingly as ConnectionResetError [WinError 10054] and
        buries the scan log it shares the console with.

        Every connection-level error is a subclass of ConnectionError, so one
        test covers reset, abort and broken pipe. Anything else still gets the
        default traceback, so a real server bug stays visible.
        """

        def handle_error(self, request, client_address):
            if isinstance(sys.exc_info()[1], ConnectionError):
                return
            super().handle_error(request, client_address)

    try:
        server = QuietThreadingHTTPServer((HTML3_HOST, HTML3_PORT), handler)
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
  yy --sync | --sync-dry-run | --sync-override
  yy -h | --help

Arguments:
  <url>               Persist this URL to ./current_url.json, then download it.
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
                      yy.zsh and yy.ps1 from the root of master, back up the
                      current launchers into .tmp, and replace both, so the
                      directory is never half of each build. Handled by the
                      launcher itself, not here, so it still works when yy.py
                      or the Python interpreter is the broken thing. The shell
                      build's --py is the inverse.
  -o                  For each channel in ./channel-ids.txt, open its /videos
                      tab only if it has a public video published after
                      ./checkpoint.txt. Exits without downloading, and exits
                      non-zero if any channel could not be checked.
  -O                  Open every channel in ./channel-ids.txt unconditionally,
                      with no check, then exit without downloading.
  --html3             Generate a local 6-column video grid with y1/y2
                      selections and serve it on http://127.0.0.1:8090,
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
  --sync              Merge this machine's state with the shared private
                      repo over git+SSH, write the result back here, push it,
                      then exit. Covers checkpoint.txt, channel-ids.txt,
                      channel-id-cache.txt, downloaded-videos.json,
                      channel-check-status.json and current_url.json.
                      cookies.txt is never synced.
  --sync-dry-run      Show what --sync would change, writing and pushing
                      nothing.
  --sync-override     Replace the shared state with this machine's copy.
                      Always previews the difference and asks first.
  -h, --help          Show this help and exit.

-o, -O and --html3 are mutually exclusive, and so are the --sync modes.
--sync cannot be combined with -o, -O or --html3; run it as its own command.
Flag precedence: -h, then -U, then --sync, then -o/-O/--html3, then -c, then
download.

Examples:
  yy 'https://example.com/video'
  yy -t 'https://example.com/one-off'
  yy -p ./my-videos -t 'https://example.com/one-off'
  yy -U
  yy -o -c
  yy -O -c
  yy --html3
  yy --html3 --html3-incognito
  yy --sync
  yy --sync-dry-run
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
        self.do_no_py = False
        self.open_mode = None
        self.html3_incognito = False
        self.set_checkpoint = False
        self.sync_mode = None
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
        elif arg == "--no-py":
            opts.do_no_py = True
        elif arg == "-o":
            set_open_mode(opts, "check")
        elif arg == "-O":
            set_open_mode(opts, "open")
        elif arg == "--html3":
            set_open_mode(opts, "html3")
        elif arg == "--html3-incognito":
            opts.html3_incognito = True
        elif arg == "--sync":
            set_sync_mode(opts, "sync")
        elif arg == "--sync-dry-run":
            set_sync_mode(opts, "dry-run")
        elif arg == "--sync-override":
            set_sync_mode(opts, "override")
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


def set_sync_mode(opts, mode):
    if opts.sync_mode is not None and opts.sync_mode != mode:
        raise UsageError(
            "--sync, --sync-dry-run, and --sync-override cannot be combined"
        )
    opts.sync_mode = mode


# ---------------------------------------------------------------------------
# --sync: share state between this machine and the other one
#
# The two machines exchange state through a private git repo. Git is the
# transport for one reason: a private repo cannot be read from the
# unauthenticated raw.githubusercontent.com path that -U uses, so the fetch
# has to be authenticated, and git+SSH is the only authenticated channel this
# project already trusts.
#
# Every merge rule below is commutative and idempotent on purpose. A push can
# lose a race, and the recovery is simply "pull again, merge again, push
# again" -- which is only safe if merging twice is the same as merging once.
# ---------------------------------------------------------------------------

SYNC_REMOTE = os.environ.get(
    "YY_SYNC_REMOTE", "git@github.com:rikimberley/yt-dlp-wrapper-state.git"
)
SYNC_BRANCH = os.environ.get("YY_SYNC_BRANCH", "master")
SYNC_SSH_KEY = os.environ.get("YY_SYNC_SSH_KEY", "~/.ssh/rikimberley_github_ed25519")
SYNC_USER_NAME = "rikimberley"
SYNC_USER_EMAIL = "85369872+rikimberley@users.noreply.github.com"

SYNC_CLONE_DIR = TEMPORARY_DIRECTORY / "state-sync"
# The state as of the end of the last successful sync. Without it a removal is
# indistinguishable from "the other machine has not added it yet".
SYNC_BASE_DIR = TEMPORARY_DIRECTORY / "state-sync-base"
SYNC_TOMBSTONE_NAME = "channel-ids-removed.txt"
SYNC_PUSH_ATTEMPTS = 3


class SyncError(Exception):
    pass


def sync_git_env():
    """Environment for every git call against the state repo.

    This clone has no local config of its own, so without -F /dev/null it
    would inherit the machine's ssh config -- which on a corporate box ends in
    a catch-all that offers the work key. Authenticating as the wrong account
    is far worse than failing, so the key is pinned and the agent is disabled.
    GIT_TERMINAL_PROMPT stops a failed auth from hanging on a password prompt.
    """
    env = dict(os.environ)
    env["GIT_SSH_COMMAND"] = (
        "ssh -F /dev/null -i %s -o IdentitiesOnly=yes -o IdentityAgent=none"
        % shlex.quote(os.path.expanduser(SYNC_SSH_KEY))
    )
    env["GIT_TERMINAL_PROMPT"] = "0"
    return env


def run_git(args, cwd=None, check=True):
    """Run git and return (returncode, stdout, stderr)."""
    try:
        proc = subprocess.Popen(
            ["git"] + args,
            cwd=str(cwd) if cwd else None,
            env=sync_git_env(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as error:
        raise SyncError("could not run git: %s" % error)
    raw_out, raw_err = proc.communicate()
    out = raw_out.decode("utf-8", "replace")
    err = raw_err.decode("utf-8", "replace")
    if check and proc.returncode != 0:
        raise SyncError(
            "git %s failed: %s" % (" ".join(args), trim(err) or trim(out))
        )
    return proc.returncode, out, err


def sync_prepare_clone():
    """Make .tmp/state-sync mirror the remote branch.

    Returns True when the branch already has commits, False when the remote is
    still empty and this is the first sync ever.
    """
    if not (SYNC_CLONE_DIR / ".git").is_dir():
        if SYNC_CLONE_DIR.exists():
            shutil.rmtree(str(SYNC_CLONE_DIR), ignore_errors=True)
        SYNC_CLONE_DIR.mkdir(parents=True, exist_ok=True)
        run_git(["init", "-q"], cwd=SYNC_CLONE_DIR)
        # Not `init -b`: that needs git 2.28+, and this has to work on
        # whatever git the Windows box happens to ship.
        run_git(
            ["symbolic-ref", "HEAD", "refs/heads/%s" % SYNC_BRANCH],
            cwd=SYNC_CLONE_DIR,
        )
        run_git(["remote", "add", "origin", SYNC_REMOTE], cwd=SYNC_CLONE_DIR)
    else:
        run_git(["remote", "set-url", "origin", SYNC_REMOTE], cwd=SYNC_CLONE_DIR)

    run_git(["config", "user.name", SYNC_USER_NAME], cwd=SYNC_CLONE_DIR)
    run_git(["config", "user.email", SYNC_USER_EMAIL], cwd=SYNC_CLONE_DIR)

    # ls-remote first, because it is the only call that cleanly separates "the
    # remote is empty" from "authentication failed". A bare fetch reports both
    # as a non-zero exit, and treating an auth failure as an empty remote
    # would push local state over a repo we simply failed to read.
    rc, out, err = run_git(["ls-remote", "origin"], cwd=SYNC_CLONE_DIR, check=False)
    if rc != 0:
        raise SyncError(
            "cannot reach %s: %s" % (SYNC_REMOTE, trim(err) or trim(out))
        )

    ref = "refs/heads/%s" % SYNC_BRANCH
    has_commits = any(line.endswith(ref) for line in out.splitlines())
    if has_commits:
        run_git(["fetch", "--quiet", "origin", SYNC_BRANCH], cwd=SYNC_CLONE_DIR)
        run_git(["reset", "--quiet", "--hard", "FETCH_HEAD"], cwd=SYNC_CLONE_DIR)
        run_git(["clean", "-qfd"], cwd=SYNC_CLONE_DIR)
    return has_commits


# --- lenient parsers -------------------------------------------------------
#
# These read an arbitrary path rather than the module-level constant, because
# a merge has to read the same file from three places: here, the clone, and
# the base snapshot. They are deliberately lenient -- the remote copy may have
# been written by a different build -- and the strict validation still happens
# when the normal readers next load the file.


def sync_dump_json(payload):
    """Serialize deterministically.

    sort_keys is not cosmetic: the merges build dicts by iterating a set, and
    Python randomizes string hashing per process, so the key order -- and
    therefore the file -- changed on every single run. That meant every sync
    saw a diff, pushed a pointless commit, and never settled.
    """
    return json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def sync_write_text(path, text):
    """Write LF-terminated UTF-8.

    Not Path.write_text(newline=...): that keyword only exists on Python 3.10+
    and this has to run on whatever interpreter the Windows box has. Pinning
    the newline matters either way -- the repo must hold LF, or every sync
    from Windows would look like a whole-file change.
    """
    with open(str(path), "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def sync_read_lines(path):
    content = read_text_file(path)
    if content is None:
        return None
    return content.splitlines()


def sync_parse_channels(path):
    lines = sync_read_lines(path)
    if lines is None:
        return None
    channels = []
    seen = set()
    for line in lines:
        entry = trim(line)
        if not entry or entry.startswith("#"):
            continue
        entry = entry.lstrip("@")
        if entry and entry not in seen:
            seen.add(entry)
            channels.append(entry)
    return channels


def sync_parse_tombstones(path):
    """Return {handle: removed_ms}."""
    lines = sync_read_lines(path) or []
    tombstones = {}
    for line in lines:
        parts = line.split("\t")
        handle = trim(parts[0]) if parts else ""
        if not handle or handle.startswith("#"):
            continue
        tombstones[handle.lstrip("@")] = (
            coerce_int(parts[1]) if len(parts) > 1 else 0
        )
    return tombstones


def sync_format_tombstones(tombstones):
    return "".join(
        "%s\t%s\n" % (handle, tombstones[handle])
        for handle in sorted(tombstones, key=lambda h: h.encode("utf-8"))
    )


def sync_parse_cache(path):
    lines = sync_read_lines(path)
    if lines is None:
        return {}
    cache = {}
    for line in lines:
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        handle = trim(parts[0])
        channel_id = trim(parts[1])
        if handle and UC_ID_RE.match(channel_id):
            cache[handle] = channel_id
    return cache


def sync_format_cache(cache):
    return "".join(
        "%s\t%s\n" % (handle, cache[handle])
        for handle in sorted(cache, key=lambda h: h.encode("utf-8"))
    )


def sync_parse_checkpoint(path):
    raw = read_first_line(path)
    digits = re.sub(r"[^0-9]", "", raw or "")
    if not digits:
        return 0
    value = int(digits)
    return value * 1000 if len(digits) < 12 else value


def sync_parse_downloaded(path):
    data = read_json_file(path)
    if isinstance(data, dict):
        data = [data]
    if not isinstance(data, list):
        return []
    records = []
    for item in data:
        if not isinstance(item, dict):
            continue
        record = {
            "channel_id": coerce_str(item.get("channel_id")),
            "video_id": coerce_str(item.get("video_id")),
            "target": coerce_str(item.get("target")),
            "download_epoch": coerce_int(item.get("download_epoch"), -1),
        }
        if (
            UC_ID_RE.match(record["channel_id"])
            and VIDEO_ID_RE.match(record["video_id"])
            and record["target"] in ("y1", "y2")
            and record["download_epoch"] >= 0
        ):
            records.append(record)
    return records


def sync_parse_status(path):
    data = read_json_file(path)
    status = {}
    if isinstance(data, dict):
        for channel, record in data.items():
            if channel and isinstance(record, dict):
                status[channel] = {
                    "checked_ms": coerce_int(record.get("checked_ms")),
                    "latest_video_ms": coerce_int(record.get("latest_video_ms")),
                    "thumbnail": coerce_str(record.get("thumbnail")),
                }
    return status


# --- merge rules -----------------------------------------------------------


def sync_merge_channels(local, remote, base, tombstones):
    """Union, local order first, minus anything tombstoned.

    A handle is tombstoned when it was in the base snapshot and is now gone
    locally -- that is a deliberate unsubscribe. Without the snapshot a plain
    union would re-add it from the other machine on the very next sync, so
    unsubscribing could never stick.

    A tombstone is cleared only when the handle is back locally *and* absent
    from the base, which is what a genuine re-add looks like. Testing just
    "present locally" would break the other machine: it still has the handle
    simply because it has not seen the removal yet, and it would resurrect it.
    """
    local = local or []
    remote = remote or []
    tombstones = dict(tombstones)
    removed = []
    restored = []

    if base is not None:
        base_set = set(base)
        local_set = set(local)
        for handle in base:
            if handle not in local_set and handle not in tombstones:
                tombstones[handle] = now_ms()
                removed.append(handle)
        for handle in local:
            if handle in tombstones and handle not in base_set:
                del tombstones[handle]
                restored.append(handle)
    else:
        # No snapshot: cannot tell a removal from "not added yet", so trust
        # the existing tombstones and do a plain union.
        for handle in local:
            if handle in tombstones:
                del tombstones[handle]
                restored.append(handle)

    merged = [h for h in local if h not in tombstones]
    added = []
    for handle in remote:
        if handle not in merged and handle not in tombstones:
            merged.append(handle)
            added.append(handle)
    return merged, tombstones, added, removed, restored


def sync_merge_cache(local, remote):
    """Union by handle. Local wins a conflict: it was resolved against a live
    page on this machine, and the entry is only a cache either way."""
    merged = dict(remote)
    merged.update(local)
    return merged


def sync_merge_downloaded(local, remote):
    """Union by (channel_id, video_id, target), keeping the earliest download,
    then re-apply the 45-day expiry.

    Pruning *after* the union is the whole point: expiry has to beat
    resurrection, or an entry this machine has already aged out comes straight
    back from the machine that has not pruned yet, and never dies.
    """
    merged = {}
    for record in list(remote) + list(local):
        key = downloaded_key(record)
        existing = merged.get(key)
        if existing is None or record["download_epoch"] < existing["download_epoch"]:
            merged[key] = record
    cutoff_sec = now_sec() - DOWNLOADED_VIDEO_TTL_SEC
    kept = [r for r in merged.values() if r["download_epoch"] >= cutoff_sec]
    kept.sort(key=downloaded_key)
    return kept, len(merged) - len(kept)


def sync_merge_status(local, remote):
    """Per channel keep the newer check, the newer video, and any thumbnail;
    then drop channels unchecked for 45 days, for the same reason as above."""
    merged = {}
    for channel in set(local) | set(remote):
        a = local.get(channel) or {}
        b = remote.get(channel) or {}
        merged[channel] = {
            "checked_ms": max(coerce_int(a.get("checked_ms")), coerce_int(b.get("checked_ms"))),
            "latest_video_ms": max(
                coerce_int(a.get("latest_video_ms")),
                coerce_int(b.get("latest_video_ms")),
            ),
            "thumbnail": coerce_str(a.get("thumbnail")) or coerce_str(b.get("thumbnail")),
        }
    cutoff_ms = now_ms() - STALE_CHANNEL_TTL_MS
    return {
        channel: record
        for channel, record in merged.items()
        if not (0 < record["checked_ms"] < cutoff_ms)
    }


def sync_merge_current_url(local, remote):
    """Larger update_ts wins. Returns (payload, took_remote)."""
    if not isinstance(local, dict) or not trim(local.get("url")):
        return (remote, True) if isinstance(remote, dict) else (None, False)
    if not isinstance(remote, dict) or not trim(remote.get("url")):
        return local, False
    if coerce_int(remote.get("update_ts")) > coerce_int(local.get("update_ts")):
        return remote, True
    return local, False


# --- the sync itself -------------------------------------------------------


def sync_plan():
    """Pull, merge everything, and return (files, notes).

    files maps a repo-relative name to the text that should end up in both the
    clone and this machine; notes is the human-readable summary.
    """
    had_commits = sync_prepare_clone()
    notes = []
    files = {}
    if not had_commits:
        notes.append("Remote branch %s is empty; seeding it." % SYNC_BRANCH)

    clone = SYNC_CLONE_DIR

    # checkpoint.txt -- newest wins
    local_cp = sync_parse_checkpoint(CHECKPOINT_FILE)
    remote_cp = sync_parse_checkpoint(clone / "checkpoint.txt")
    merged_cp = max(local_cp, remote_cp)
    files["checkpoint.txt"] = "%s\n" % merged_cp
    if merged_cp != local_cp:
        notes.append("checkpoint.txt: %s -> %s (remote newer)" % (local_cp, merged_cp))
    elif merged_cp != remote_cp:
        notes.append("checkpoint.txt: pushing %s (local newer)" % merged_cp)

    # channel-ids.txt -- union with tombstones
    local_ch = sync_parse_channels(CHANNELS_FILE)
    remote_ch = sync_parse_channels(clone / "channel-ids.txt")
    base_ch = sync_parse_channels(SYNC_BASE_DIR / "channel-ids.txt")
    tombstones = sync_parse_tombstones(clone / SYNC_TOMBSTONE_NAME)
    merged_ch, tombstones, added, removed, restored = sync_merge_channels(
        local_ch, remote_ch, base_ch, tombstones
    )
    files["channel-ids.txt"] = "".join(h + "\n" for h in merged_ch)
    files[SYNC_TOMBSTONE_NAME] = sync_format_tombstones(tombstones)
    if added:
        notes.append("channel-ids.txt: + %s" % ", ".join(added))
    if removed:
        notes.append("channel-ids.txt: tombstoned %s" % ", ".join(removed))
    if restored:
        notes.append("channel-ids.txt: un-tombstoned %s" % ", ".join(restored))
    dropped = [h for h in (local_ch or []) if h not in merged_ch]
    if dropped:
        notes.append("channel-ids.txt: removing locally %s" % ", ".join(dropped))

    # channel-id-cache.txt -- union by handle
    local_cache = sync_parse_cache(CHANNEL_ID_CACHE_FILE)
    remote_cache = sync_parse_cache(clone / "channel-id-cache.txt")
    merged_cache = sync_merge_cache(local_cache, remote_cache)
    files["channel-id-cache.txt"] = sync_format_cache(merged_cache)
    gained = len(merged_cache) - len(local_cache)
    if gained > 0:
        notes.append("channel-id-cache.txt: +%s cached id(s)" % gained)

    # downloaded-videos.json -- union, earliest wins, then expire
    local_dl = sync_parse_downloaded(DOWNLOADED_VIDEOS_FILE)
    remote_dl = sync_parse_downloaded(clone / "downloaded-videos.json")
    merged_dl, expired = sync_merge_downloaded(local_dl, remote_dl)
    files["downloaded-videos.json"] = sync_dump_json(merged_dl)
    if len(merged_dl) != len(local_dl):
        notes.append(
            "downloaded-videos.json: %s -> %s record(s)" % (len(local_dl), len(merged_dl))
        )
    if expired:
        notes.append("downloaded-videos.json: expired %s after merge" % expired)

    # channel-check-status.json -- newest per channel, then expire
    local_st = sync_parse_status(CHANNEL_STATUS_FILE)
    remote_st = sync_parse_status(clone / "channel-check-status.json")
    merged_st = sync_merge_status(local_st, remote_st)
    files["channel-check-status.json"] = sync_dump_json(merged_st)
    if len(merged_st) != len(local_st):
        notes.append(
            "channel-check-status.json: %s -> %s channel(s)"
            % (len(local_st), len(merged_st))
        )

    # current_url.json -- larger update_ts wins
    local_url = read_json_file(URL_JSON_FILE)
    remote_url = read_json_file(clone / "current_url.json")
    if not isinstance(local_url, dict) and URL_FILE.exists():
        # yy.zsh and yy.ps1 still write only the .txt, so there is no
        # update_ts to compare and no safe way to decide a winner.
        sys.stderr.write(
            "Warning: %s has no %s yet; skipping the URL merge\n"
            % (display_path(BASE_DIR), URL_JSON_FILE.name)
        )
    else:
        merged_url, took_remote = sync_merge_current_url(local_url, remote_url)
        if isinstance(merged_url, dict):
            files["current_url.json"] = sync_dump_json(merged_url)
            if took_remote:
                notes.append("current_url.json: taking the remote URL (newer)")

    # The rules above only describe what *changed semantically*, so a purely
    # local addition produced no note at all and a dry run could claim
    # "already in sync" while still having something to push. Summarise both
    # directions from the merged text itself, which cannot miss a case.
    pushing = []
    updating = []
    for name in sorted(files):
        if read_text_file(SYNC_CLONE_DIR / name) != files[name]:
            pushing.append(name)
        target = sync_local_target(name)
        if target is not None and read_text_file(target) != files[name]:
            updating.append(name)
    if updating:
        notes.append("updating here: %s" % ", ".join(updating))
    if pushing:
        notes.append("pushing: %s" % ", ".join(pushing))

    return files, notes


def sync_local_target(name):
    return BASE_DIR / name if name != SYNC_TOMBSTONE_NAME else None


def sync_apply(files):
    """Write the merged result to this machine and into the clone."""
    for name, text in sorted(files.items()):
        sync_write_text(SYNC_CLONE_DIR / name, text)
        target = sync_local_target(name)
        if target is not None:
            write_atomic(target, text)


def sync_save_base(files):
    """Snapshot what we just agreed on, so the next run can spot a removal."""
    try:
        SYNC_BASE_DIR.mkdir(parents=True, exist_ok=True)
        for name, text in files.items():
            sync_write_text(SYNC_BASE_DIR / name, text)
    except OSError as error:
        sys.stderr.write("Warning: could not save the sync snapshot: %s\n" % error)


def sync_commit_and_push(message):
    """Commit the clone and push. Returns True when the remote now has it."""
    run_git(["add", "-A"], cwd=SYNC_CLONE_DIR)
    rc, out, _ = run_git(
        ["status", "--porcelain"], cwd=SYNC_CLONE_DIR, check=False
    )
    if rc == 0 and not trim(out):
        print("Remote already matches; nothing to push.")
        return True
    run_git(["commit", "--quiet", "-m", message], cwd=SYNC_CLONE_DIR)
    rc, out, err = run_git(
        ["push", "--quiet", "origin", "HEAD:%s" % SYNC_BRANCH],
        cwd=SYNC_CLONE_DIR,
        check=False,
    )
    if rc == 0:
        return True
    sys.stderr.write("Warning: push rejected: %s\n" % (trim(err) or trim(out)))
    return False


def run_sync(dry_run=False, override=False):
    try:
        if override:
            return sync_override()
        for attempt in range(1, SYNC_PUSH_ATTEMPTS + 1):
            files, notes = sync_plan()
            print("")
            if notes:
                for note in notes:
                    print("  %s" % note)
            else:
                print("  Everything is already in sync.")
            print("")
            if dry_run:
                print("Dry run: nothing was written and nothing was pushed.")
                return 0
            sync_apply(files)
            if sync_commit_and_push("Sync state from %s" % platform_label()):
                sync_save_base(files)
                print("State synced with %s." % SYNC_REMOTE)
                return 0
            if attempt < SYNC_PUSH_ATTEMPTS:
                # The merge rules are commutative, so re-pulling and merging
                # again is always safe -- that is what makes a retry correct
                # rather than a way to clobber the other machine.
                print("Re-pulling and merging again (attempt %s)..." % (attempt + 1))
        sys.stderr.write(
            "Warning: could not push after %s attempts; local state is merged "
            "and the next sync will retry\n" % SYNC_PUSH_ATTEMPTS
        )
        return 0
    except SyncError as error:
        sys.stderr.write("Error: sync failed: %s\n" % error)
        return 1


def sync_override():
    """Replace the remote wholesale with this machine's state.

    Always previews first: this is the one path that can destroy the other
    machine's state, so it shows exactly what would be lost and asks.
    """
    sync_prepare_clone()
    local_channels = sync_parse_channels(CHANNELS_FILE) or []
    remote_channels = sync_parse_channels(SYNC_CLONE_DIR / "channel-ids.txt") or []
    # Tombstone whatever the override drops. Without this the override only
    # cleans the remote: the other machine still has those handles locally, so
    # its very next sync would union them straight back in and the override
    # would quietly undo itself.
    dropped = [h for h in remote_channels if h not in local_channels]
    tombstones = dict.fromkeys(dropped, now_ms())
    local_files = {
        "checkpoint.txt": "%s\n" % sync_parse_checkpoint(CHECKPOINT_FILE),
        "channel-ids.txt": "".join(h + "\n" for h in local_channels),
        SYNC_TOMBSTONE_NAME: sync_format_tombstones(tombstones),
        "channel-id-cache.txt": sync_format_cache(sync_parse_cache(CHANNEL_ID_CACHE_FILE)),
        "downloaded-videos.json": sync_dump_json(
            sync_parse_downloaded(DOWNLOADED_VIDEOS_FILE)
        ),
        "channel-check-status.json": sync_dump_json(
            sync_parse_status(CHANNEL_STATUS_FILE)
        ),
    }
    local_url = read_json_file(URL_JSON_FILE)
    if isinstance(local_url, dict):
        local_files["current_url.json"] = sync_dump_json(local_url)

    print("")
    print("OVERRIDE would replace the remote with this machine's state:")
    print("")
    changed = False
    for name, text in sorted(local_files.items()):
        if name == SYNC_TOMBSTONE_NAME:
            continue  # reported in full below, as a removal rather than a diff
        before = read_text_file(SYNC_CLONE_DIR / name)
        if before == text:
            continue
        changed = True
        print("  %s" % name)
        for line in sync_diff_lines(before or "", text):
            print("    %s" % line)
    if dropped:
        changed = True
        print(
            "  %s channel(s) would be marked removed so the other machine"
            % len(dropped)
        )
        print("  drops them too: %s" % ", ".join(dropped))
    if not changed:
        print("  Nothing would change.")
        return 0
    print("")
    if not sys.stdin.isatty():
        sys.stderr.write(
            "Error: --sync-override needs a terminal to confirm; refusing\n"
        )
        return 1
    try:
        answer = input("Replace the remote with the above? [y/N] ")
    except EOFError:
        answer = ""
    if trim(answer).lower() not in ("y", "yes"):
        print("Aborted; the remote was not touched.")
        return 0

    for name in local_files:
        sync_write_text(SYNC_CLONE_DIR / name, local_files[name])
    if sync_commit_and_push("Override state from %s" % platform_label()):
        sync_save_base(local_files)
        print("Remote replaced with this machine's state.")
        return 0
    sys.stderr.write("Error: override could not be pushed\n")
    return 1


def sync_diff_lines(before, after, limit=12):
    """A tiny line diff -- enough to see what an override would destroy."""
    old = before.splitlines()
    new = after.splitlines()
    old_set = set(old)
    new_set = set(new)
    lines = []
    for line in old:
        if line not in new_set:
            lines.append("- %s" % line)
    for line in new:
        if line not in old_set:
            lines.append("+ %s" % line)
    if len(lines) > limit:
        extra = len(lines) - limit
        lines = lines[:limit] + ["... and %s more line(s)" % extra]
    return lines or ["(reformatted only)"]


def platform_label():
    """A coarse OS name for the commit message -- deliberately not the
    hostname. This machine is corporate-managed and its hostname is internal
    infrastructure detail, which must not be written into a GitHub repo even a
    private one. The label only needs to say which side pushed."""
    if sys.platform.startswith("win"):
        return "windows"
    if sys.platform == "darwin":
        return "macos"
    return sys.platform


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

    # Ahead of -U deliberately: `yy -U --no-py` means "leave the Python build",
    # and refreshing yy.py on the way out would be wasted work.
    if opts.do_no_py:
        return run_no_py()

    if opts.do_update:
        return run_update()

    if opts.sync_mode is not None:
        if opts.open_mode is not None:
            sys.stderr.write(
                "Error: --sync cannot be combined with -o, -O, or --html3\n"
            )
            return 1
        TEMPORARY_DIRECTORY.mkdir(parents=True, exist_ok=True)
        return run_sync(
            dry_run=opts.sync_mode == "dry-run",
            override=opts.sync_mode == "override",
        )

    # A positional URL is persisted even when -t overrides what actually runs.
    if opts.url:
        TEMPORARY_DIRECTORY.mkdir(parents=True, exist_ok=True)
        write_current_url(opts.url)

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
            stored = read_current_url()
            run_url = stored or None

    if not run_url:
        sys.stderr.write(
            "Error: no URL provided, and neither %s nor %s has one\n"
            % (display_path(URL_JSON_FILE), display_path(URL_FILE))
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
            # See YTDLP_ENCODING_ARGS: without this yt-dlp encodes its output
            # with the console code page, so a non-ASCII title is mangled in
            # the progress lines the html3 job log captures.
            YTDLP_ENCODING_ARGS[0],
            YTDLP_ENCODING_ARGS[1],
            "--cookies",
            display_path(COOKIES_FILE),
            "--paths",
            output_path,
            run_url,
        ]
    )


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

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
import subprocess
import sys
import time
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


# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

USAGE = """\
yy.py - convenience wrapper around ./yt-dlp

Usage:
  yy [<url>] [-t <temp_url>] [-p <path>] [-U] [-O | --html3]
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
  -O                  Open every channel in ./channel-ids.txt unconditionally,
                      then exit without downloading.
  --html3             Generate a local 6-column video grid with y1/y2
                      selections and serve it on http://127.0.0.1:8080,
                      opening a loading shell immediately and streaming one
                      fragment per channel from a background worker.
                      Already-downloaded video cards are dropped.
  --html3-incognito   With --html3, open the page in a Chrome/Chromium
                      incognito window instead of the default browser.
  -c                  Overwrite ./checkpoint.txt with the current epoch-ms
                      timestamp, then exit without downloading. Runs after -O,
                      so "-O -c" means "open the channels, then mark
                      everything as seen".
  -h, --help          Show this help and exit.

-O and --html3 are mutually exclusive.
Flag precedence: -h, then -U, then -O/--html3, then -c, then download.

Examples:
  yy 'https://example.com/video'
  yy -t 'https://example.com/one-off'
  yy -p ./my-videos -t 'https://example.com/one-off'
  yy -U
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
        raise UsageError("-O and --html3 are mutually exclusive")
    opts.open_mode = mode


# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

YOUTUBE_HANDLE_RE = re.compile(r"^https?://([^/]+\.)?youtube\.com/@([^/?#]+)")

NOT_IMPLEMENTED = {
    "open": "-O",
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
        sys.stderr.write(
            "Error: %s is not implemented in this build yet\n"
            % NOT_IMPLEMENTED[opts.open_mode]
        )
        return 2

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

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

import os
import re
import shlex
import subprocess
import sys
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

DEFAULT_OUTPUT_PATH = "./t"

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
    import time

    return int(time.time() * 1000)


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
# Command execution
# ---------------------------------------------------------------------------

def display_path(path):
    """Render a path the way the shell wrappers did, relative to the base."""
    try:
        return "./" + str(Path(path).resolve().relative_to(BASE_DIR))
    except ValueError:
        return str(path)


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

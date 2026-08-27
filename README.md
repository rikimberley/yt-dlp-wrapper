# yy — a small yt-dlp wrapper

Personal convenience wrapper around the standalone [yt-dlp](https://github.com/yt-dlp/yt-dlp)
binary: remembers the last URL, downloads into a scratch directory, and opens
subscribed YouTube channels that have published something new since a saved
checkpoint.

This is **not** yt-dlp itself and is unaffiliated with the yt-dlp project — it
is just two wrapper scripts that shell out to the official binary.

Two wrappers with an identical interface — `yy.zsh` (macOS/Linux) and `yy.ps1`
(PowerShell, including Windows PowerShell 5.1).

## Setup

The yt-dlp binary is **not** committed to this repo — it self-updates in place,
so committing it would add a fresh ~38 MB blob to history on every update.
Fetch it yourself, next to the wrappers:

```bash
# macOS / Linux
curl -L -o yt-dlp https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos
chmod +x yt-dlp

# Windows: download yt-dlp.exe from the same releases page into this directory
```

Then keep it current with the wrapper's own update flag, which uses yt-dlp's
signed updater:

```bash
./yy.zsh -U
```

`-U` also refreshes the wrapper itself from the head of `master` in this repo,
so a copy that lives outside a git clone stays current. The download is refused
unless it starts with the expected shebang, and the copy it replaces is kept as
`yy.zsh.bak` / `yy.ps1.bak` — so if you had uncommitted local edits, they are
recoverable there.

You also need a `channel-ids.txt` next to the wrappers if you want `-o`/`-O` —
one channel handle (a leading `@` is optional) or raw `UC…` id per line, with
`#` comments and blank lines ignored. It is gitignored, because a subscription
list names exactly who you follow.

You also need a `cookies.txt` next to the wrappers — a Netscape-format cookie
jar exported from a browser where you are signed in to YouTube. It is
gitignored and must stay that way: it holds live session tokens. Cookies
expire; a download failing with an auth error usually means it needs
re-exporting.

## Usage

```
./yy.zsh [<url>] [-t <temp_url>] [-p <path>] [-U] [-o | -O | --html] [-c]
```

| Flag | Effect |
|---|---|
| `<url>` | Persist to `current_url.txt`, then download it |
| *(no args)* | Re-download the URL in `current_url.txt` |
| `-t <url>` | Download this URL once, without persisting it |
| `-U` | Self-update the binary *and* this wrapper from `master`, then exit |
| `-p <path>` | Download into `<path>` instead of the default `./t` |
| `-o` | Open each channel in `channel-ids.txt` that has a public video newer than `checkpoint.txt`, then exit |
| `-O` | Open every channel unconditionally, then exit |
| `--html` | Like `-o`, select channels with public videos newer than `checkpoint.txt`, then generate and open `yy.html`, a 6-column grid with hover previews and y1/y2 checkboxes |
| `-c` | With `-o` or `--html`, write the timestamp captured immediately after channel checks finish; otherwise write the current timestamp, then exit |

Precedence: `-U`, then `-o`/`-O`, then `-c`, then download. `-o` and `-O` are
mutually exclusive. `-o` exits non-zero if any channel could not be checked, and
`-U` exits non-zero if the wrapper could not be refreshed.

`./yy.zsh -o -c` means "open whatever is new, then mark everything as seen".
The checkpoint is not updated if at least three channel checks fail, or if all
listed channels fail to be checked. With `-o -c` and `--html -c`, the saved
timestamp is captured after the check pass, before channels/pages are opened;
it is written when that operation returns (after the HTML server stops).

`--html` scans each channel's `/videos` tab as a flat playlist using yt-dlp's
approximate tab dates. It starts at midnight UTC on the calendar day before the
checkpoint's UTC date, so the approximate-date window covers the entire checkpoint
date plus a one-day margin; consequently, the page can also include videos from
that overlap before the checkpoint. The scan
uses `cookies.txt`, allowing age-restricted and other videos visible to that account
to be listed; entries explicitly marked members-only, private, or premium-only are
excluded. Availability that the flat scan cannot classify is accepted without
opening each watch page. All unique channels are queued first and a work-conserving
pool scans up to sixteen concurrently; as soon as one scan finishes, its slot starts
the next queued channel. Each channel is handled by exactly one scan process, with
duplicate input lines collapsed. Before both the initial scan and each `REFRESH`,
the wrapper copies `cookies.txt` to one private `cookies0.txt` through
`cookies15.txt` jar per worker slot. A slot always uses only its own jar, preventing
yt-dlp's exit-time cookie rewrite from racing another scan; the private jars are
deleted as soon as the scan phase ends. Shorts that appear only on
`/shorts` are excluded. The generated page
displays the current checkpoint; in PowerShell it updates immediately when the
`CHECKPOINT` button is clicked. While generating the page, the wrapper prints
each channel as it starts, live yt-dlp extraction/network messages, a periodic
elapsed-time heartbeat, and the number of qualifying videos it found.
In PowerShell, a successful HTML scan updates each channel's last-checked time.
Its stored latest-video time is updated only when the scan returns at least one
accepted video; an empty or wholly unparseable result preserves the prior value.
In PowerShell, `--html` serves the page at `http://127.0.0.1:8080/` and keeps
the wrapper running so selections can be submitted repeatedly. The page sends its
checked y1/y2 YouTube URLs, with a random per-run callback token, to the
loopback listener; `yy.ps1` validates the structured selections and starts the
matching local `yy1.ps1 -p "./<channel-entry>" -t "<url>"` / `yy2.ps1 -p "./<channel-entry>" -t "<url>"` hook without making
the page wait for downloads to finish; it reports queued, running, completed,
and failed job counts plus recent yy/yt-dlp output in the page and the wrapper
console. Jobs run sequentially: all y2 selections first, then y1 selections.
Use `STOP SERVER` in the page, or Ctrl+C in the wrapper console, to end the
loopback server; the button attempts to close its page (and falls back to a
blank page when the browser disallows programmatic closing). Closing the page
also stops the server after its 30-second heartbeat timeout. Time spent
regenerating the page during a refresh does not count toward that timeout.
Temporary status-request failures do not close the page. Port 8080 must be
available. The callback never accepts arbitrary command text.

The page has y1, y2, and none selection controls beside Download selected and
beside every channel heading. A y1 or y2 control checks that destination's
boxes; none clears both destinations' boxes in its scope.

Each displayed video must itself be newer than `checkpoint.txt`. HTML download
jobs use the normalized entry from `channel-ids.txt` as their relative output
folder—for example, `liguiHD` downloads to `./liguiHD`.

The logged-out yt-dlp metadata lookups use a 30-second socket timeout and one
retry. The small `-o` fallback also has a 30-second wall-clock deadline. The
complete `/videos` traversal used by `--html` has no wall-clock deadline because
large channels can require many continuation pages.

## Files

| Path | Role |
|---|---|
| `yy.zsh` / `yy.ps1` | The wrappers. Behaviourally identical; keep them in sync. |
| `channel-ids.txt` | One channel handle (or raw `UC…` id) per line; `#` comments and blank lines ignored *(gitignored)* |
| `checkpoint.txt` | Epoch timestamp `-o` compares against *(gitignored)* |
| `channel-id-cache.txt` | Generated handle → `UC…` cache; safe to delete *(gitignored)* |
| `current_url.txt` | Last URL *(gitignored)* |
| `yy.html` | Generated `--html` video grid *(gitignored)* |
| `cookies.txt` | **Secret.** YouTube cookie jar *(gitignored)* |
| `t/` | Download output *(gitignored)* |

## Notes

`-o` never sends account cookies. It first reads the public Atom feed at
`feeds/videos.xml?channel_id=…`. If that legacy feed is unavailable or
unusable, it asks the vendored `yt-dlp` for exact timestamps and availability
from the five newest entries in the channel's uploads playlist. Only entries
explicitly reported as public are considered. After three channels exhaust the
feed-fetch retries in one `-o` run, the remaining channels skip the unreliable
feed and go directly to this fallback.

## Credits

All the actual work is done by [yt-dlp](https://github.com/yt-dlp/yt-dlp)
(Unlicense). This repo is only a pair of wrapper scripts around it.

<!-- Git operation test. -->

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
./yy.zsh [<url>] [-t <temp_url>] [-U] [-o | -O] [-c]
```

| Flag | Effect |
|---|---|
| `<url>` | Persist to `current_url.txt`, then download it |
| *(no args)* | Re-download the URL in `current_url.txt` |
| `-t <url>` | Download this URL once, without persisting it |
| `-U` | Self-update the binary *and* this wrapper from `master`, then exit |
| `-o` | Open each channel in `channel-ids.txt` that has a public video newer than `checkpoint.txt`, then exit |
| `-O` | Open every channel unconditionally, then exit |
| `-c` | Write the current timestamp to `checkpoint.txt`, then exit |

Precedence: `-U`, then `-o`/`-O`, then `-c`, then download. `-o` and `-O` are
mutually exclusive. `-o` exits non-zero if any channel could not be checked, and
`-U` exits non-zero if the wrapper could not be refreshed.

`./yy.zsh -o -c` means "open whatever is new, then mark everything as seen".
The checkpoint is not updated if at least three channel checks fail, or if all
listed channels fail to be checked.

## Files

| Path | Role |
|---|---|
| `yy.zsh` / `yy.ps1` | The wrappers. Behaviourally identical; keep them in sync. |
| `channel-ids.txt` | One channel handle (or raw `UC…` id) per line; `#` comments and blank lines ignored *(gitignored)* |
| `checkpoint.txt` | Epoch timestamp `-o` compares against *(gitignored)* |
| `channel-id-cache.txt` | Generated handle → `UC…` cache; safe to delete *(gitignored)* |
| `current_url.txt` | Last URL *(gitignored)* |
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

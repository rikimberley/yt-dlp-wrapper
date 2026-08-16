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
| `-U` | Self-update the binary, then exit |
| `-o` | Open each channel in `channel-ids.txt` that has a public video newer than `checkpoint.txt`, then exit |
| `-O` | Open every channel unconditionally, then exit |
| `-c` | Write the current timestamp to `checkpoint.txt`, then exit |

Precedence: `-U`, then `-o`/`-O`, then `-c`, then download. `-o` and `-O` are
mutually exclusive. `-o` exits non-zero if any channel could not be checked.

`./yy.zsh -o -c` means "open whatever is new, then mark everything as seen".

## Files

| Path | Role |
|---|---|
| `yy.zsh` / `yy.ps1` | The wrappers. Behaviourally identical; keep them in sync. |
| `channel-ids.txt` | One channel handle (or raw `UC…` id) per line; `#` comments and blank lines ignored |
| `checkpoint.txt` | Epoch timestamp `-o` compares against *(gitignored)* |
| `channel-id-cache.txt` | Generated handle → `UC…` cache; safe to delete *(gitignored)* |
| `current_url.txt` | Last URL *(gitignored)* |
| `cookies.txt` | **Secret.** YouTube cookie jar *(gitignored)* |
| `t/` | Download output *(gitignored)* |

## Notes

`-o` never sends account cookies: it resolves the channel id, then reads the
public Atom feed at `feeds/videos.xml?channel_id=…`, which omits members-only
videos and is therefore public by construction.

## Credits

All the actual work is done by [yt-dlp](https://github.com/yt-dlp/yt-dlp)
(Unlicense). This repo is only a pair of wrapper scripts around it.

# AGENTS.md — yt-dlp

Personal wrapper around a vendored [yt-dlp](https://github.com/yt-dlp/yt-dlp)
binary for downloading videos/playlists to a local scratch directory.

**This directory is a git repository** — a *private* repo on the maintainer's
**personal** GitHub account (`rikimberley`), not a LinkedIn one. Nothing here
is LinkedIn work. Read `## Git and GitHub` below before running any git command,
and read the parent `../AGENTS.md` (sharing and secret-handling rules still
apply — the parent tree itself remains untracked).

## Files

| Path               | Role |
|--------------------|------|
| `yt-dlp`                | Vendored yt-dlp standalone binary (~38 MB). Self-updates via `./yt-dlp -U`. Never edit; never rebuild. **Gitignored** — see `## Git and GitHub`. |
| `yy.zsh`           | macOS/Linux wrapper around `./yt-dlp`. Primary entry point. |
| `yy.ps1`           | PowerShell port of `yy.zsh`. Must stay behaviorally identical. |
| `README.md`        | Public-facing docs for the repo, including how to fetch the uncommitted binary. |
| `.gitignore`       | Secrets, the binary, runtime state and output. Treat as safety-critical. |
| `current_url.txt` | Persisted "last URL" — single line, rewritten whenever a positional URL is passed. *(gitignored)* |
| `channel-ids.txt` | Input for `-o`/`-O`. One YouTube channel handle per line (a leading `@` is optional, non-ASCII handles are fine). A raw `UC…` channel id is also accepted and skips handle resolution entirely. Blank lines and `#` comments are skipped. |
| `checkpoint.txt`  | Input for `-o`, rewritten by `-c`. Single epoch timestamp; 12+ digits is read as milliseconds, shorter as seconds. *(gitignored)* |
| `channel-id-cache.txt` | Generated cache mapping each handle to its `UC…` channel id, TAB separated, one per line. Pure cache — safe to delete, costs one page fetch per channel to rebuild. *(gitignored)* |
| `cookies.txt`            | **SECRET.** Netscape-format YouTube cookie jar with live session tokens. *(gitignored)* |
| `t/`               | Download output directory (`--paths ./t`). Treat as disposable scratch. *(gitignored)* |

## Wrapper Contract

Both `yy.zsh` and `yy.ps1` implement the same interface:

```
./yy.zsh [<url>] [-t <temp_url>] [-U] [-o | -O] [-c]
```

- positional `<url>` — persisted to `current_url.txt`, then downloaded
- no args — reuses the URL stored in `current_url.txt`
- `-t <temp_url>` — downloads this URL instead, **without** persisting it
  (a positional `<url>` given alongside `-t` is still persisted but not used
  for this run)
- `-U` — runs `./yt-dlp -U` (self-update) only, and exits without downloading
- `-o` — for each channel in `channel-ids.txt`, opens
  `https://www.youtube.com/@<channel-id>/videos` in the default browser **only
  if** that channel has a public video published after `checkpoint.txt`;
  otherwise a no-op for that channel. Exits without downloading, and exits
  non-zero if any channel could not be checked.
- `-O` — opens every channel URL unconditionally, with no check. Exits without
  downloading.
- `-c` — overwrites `checkpoint.txt` with the current epoch-ms timestamp. Runs
  **after** `-o`/`-O`, so `./yy.zsh -o -c` means "open whatever is new, then
  mark everything as seen". Exits without downloading.
- `-o` and `-O` are mutually exclusive; `-U` takes precedence over both
- error + non-zero exit when no URL is available from any source

Flag precedence when several are passed: `-U`, then `-o`/`-O`, then `-c`, then
download.

### How `-o` decides

Per channel: resolve the handle to its `UC…` id, then fetch
`https://www.youtube.com/feeds/videos.xml?channel_id=<id>` and take the newest
`<published>` across **all** entries (the feed is not reliably date-sorted).
That Atom feed omits members-only videos, so it is public-by-construction — no
extra members-only filtering is needed, and no cookies are sent.

Handle resolution is layered, cheapest first, and each result is written
through to `channel-id-cache.txt`:

1. the entry is already a `UC…` id — used as is
2. a hit in `channel-id-cache.txt` — no page fetch at all
3. scrape `channel_id=UC…` (or `"externalId"`, or `/channel/UC…`) from the
   `/videos` page
4. `./yt-dlp --flat-playlist --playlist-items 0 --print 'playlist:%(channel_id)s'`,
   which tracks YouTube's layout far better than the regexes above

If a cached id yields an empty or unreadable feed, the entry is dropped and
resolved again once — that is how a handle moving to a new channel heals.

Every fetch is retried (3 attempts, linear backoff) except on a settled 4xx
other than 408/429, and requests are gzipped: a channel page is ~1.2 MB raw but
~270 KB compressed, and the uncompressed transfer is what kept timing out on
Windows PowerShell 5.1 and surfacing as "no public videos found".

The download invocation is exactly:

```
./yt-dlp --cookies ./cookies.txt --paths ./t <url>
```

Each command is echoed in blue before running.

## Rules for Agents

- **Keep `yy.zsh` and `yy.ps1` in sync.** Any change to flags, precedence,
  error messages, or the usage header must be mirrored in both, in the same
  change. Divergence is a bug.
- **`yy.ps1` parses `$args` by hand, on purpose.** PowerShell binds parameter
  names case-insensitively, so a `param()` block cannot distinguish `-o` from
  `-O`. Do not "simplify" it back to `param()` — that would silently break the
  flag pair. Comparisons must stay case-sensitive (`-ceq`).
- **Spell yt-dlp options in long form (`--paths`, not `-P`).** PowerShell
  prefix-matches short flags against a function's common parameters, so `-P`
  was being bound as `-PipelineVariable` and never reached yt-dlp — downloads
  silently landed in the CWD instead of `t/`. `Invoke-YCommand` now reads
  `$args` (no `[Parameter()]`, hence no common parameters) so nothing is
  swallowed, but long form stays the rule for both wrappers.
- **Do not add a `param()`/`[Parameter()]` block to `Invoke-YCommand`.** That
  is what turned it into an advanced function and caused the `-P` bug above.
- **`yy.ps1` must run on Windows PowerShell 5.1**, not just pwsh 6+. That rules
  out `` `e `` escapes (5.1 prints them literally — hence no colour in `yy.ps1`,
  the one deliberate cosmetic divergence from `yy.zsh`) and bare
  `$IsWindows`/`$IsMacOS`/`$IsLinux` (undefined in 5.1, and fatal under
  `Set-StrictMode`; use `Get-Variable -ErrorAction SilentlyContinue`). Reads of
  `channel-ids.txt` must pass `-Encoding UTF8`, or 5.1 decodes non-ASCII
  handles as ANSI and builds the wrong URL. 5.1 also defaults `TLS` to 1.0 and
  returns `Invoke-WebRequest .Content` as `[byte[]]` for non-`text/*`
  responses, so `yy.ps1` pins TLS 1.2+ up front and `Get-WebContent` decodes
  `[byte[]]` bodies as UTF-8.
- **Never silently swallow a fetch failure in `-o`.** `Get-NewestPublicMs` /
  `newest_public_ms` return `-1` for "could not check" and `0` for "genuinely
  no public videos"; those two must never be collapsed, or a network blip reads
  as an empty channel. `-1` prints `CHECK FAILED`, never opens the channel, and
  makes the run exit non-zero. Each failure stage (page fetch, `channel_id`
  scrape, yt-dlp fallback, feed fetch, `<published>` parse) must emit its own
  warning to stderr in both wrappers.
- **Don't reach for `zsh` extended-glob operators (`#`, `##`) in `yy.zsh`.**
  The script never sets `extendedglob`, so `[[ $x == UC[A-Za-z0-9_-]## ]]`
  silently never matches — that is how the channel-id cache ended up dead code.
  Use `[[ $x =~ ^UC[A-Za-z0-9_-]+$ ]]` instead.
- **Fetch with gzip and retries, in both wrappers.** `yy.zsh` uses
  `curl --compressed`; `yy.ps1` uses `HttpWebRequest` with
  `AutomaticDecompression` because 5.1's `Invoke-WebRequest` never advertises
  gzip (it is kept only as a fallback path). Don't drop either.
- **The channel page is fetched with pre-accepted consent cookies**
  (`SOCS=CAI; CONSENT=YES+cb`) plus an `Accept-Language` header. Without them
  YouTube can answer with a consent interstitial that carries no `channel_id`.
  These are anonymous consent cookies, unrelated to `cookies.txt` — the `-o`
  path must stay logged-out so the feed remains public-by-construction.
- **Never read out, log, or copy `cookies.txt`.** It contains live `__Secure-*SID`,
  `SAPISID`, and `LOGIN_INFO` values. If you must inspect it, report only
  structure (cookie names, expiry), never values. Do not commit it anywhere,
  do not paste it into a summary or issue.
- Cookies expire. A download failing with an auth/consent error usually means
  `cookies.txt` needs re-exporting from a browser — that is a user action, not
  something to work around by disabling `--cookies`.
- Do not add new dependencies (Python, pip, ffmpeg wrappers, venvs). The point
  of the vendored binary is zero setup.
- Do not change the output directory away from `./t`, and do not delete
  downloaded media without being asked.
- Do not "upgrade" `yt-dlp` by downloading a new binary from the internet — use
  `./yy.zsh -U`, which uses yt-dlp's own signed updater.

## Git and GitHub

This repo lives on a **personal** GitHub account and is developed on a
**LinkedIn-managed machine**. Those two facts are in permanent tension, so the
isolation below is deliberate. Do not "simplify" any of it.

### Repo identity

| Setting | Value | Why |
|---|---|---|
| Repo | `rikimberley/yt-dlp-wrapper` (**private**) | Named `-wrapper` so it is not mistaken for upstream `yt-dlp`, whose name is taken |
| Remote | `git@github.com:rikimberley/yt-dlp-wrapper.git` | Plain github.com; the key is pinned by `core.sshCommand`, not by an SSH `Host` alias |
| `user.name` | `rikimberley` | Not the work account name |
| `user.email` | `85369872+rikimberley@users.noreply.github.com` | GitHub noreply — never publishes a real or work email |
| `core.sshCommand` | `ssh -i ~/.ssh/rikimberley_github_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none` | Pins the personal key; see below |

Note the local directory is `yt-dlp/` while the repo is `yt-dlp-wrapper` — the
directory name predates the repo and is not required to match.

All of these are set **locally in this repo only** (`git config --local`),
never globally. Verify with:

```bash
git config --local --get-regexp 'user\.|core\.sshcommand'
git log --format='%an <%ae>' | sort -u     # must show only rikimberley
```

### Why `core.sshCommand` and not an SSH config Host alias

`~/.ssh/config` on this machine is generated by LinkedIn's `go/manage-ssh` and
is marked DO NOT EDIT BY HAND, so a personal `Host` block there would be
clobbered by automation. Worse, it ends with a catch-all:

```
Host * !*.linkedin.com
    IdentityFile ~/.ssh/qihuang_at_linkedin.com_ssh_key
```

which means a plain `git@github.com` remote **offers the corporate SSH key**.
If that key is registered on the work GitHub account, the push authenticates as
the *wrong identity*. The per-repo `core.sshCommand` with `IdentitiesOnly=yes`
(only the listed key may be used) and `IdentityAgent=none` (the agent cannot
volunteer the corporate key) closes both holes without touching any
corporate-managed file. Keep personal config out of corporate files.

### The binary is intentionally not committed

`yt-dlp` (~38 MB) is gitignored. `./yy.zsh -U` rewrites it in place, so
committing it would append a fresh 38 MB blob to history on **every** update,
growing without bound and unfixable without a history rewrite. `README.md`
tells users how to fetch it. Do not add it, and do not "solve" this with Git
LFS — it buys nothing here.

### Never commit

`.gitignore` is safety-critical, not tidiness. Before any `git add`, confirm:

```bash
git check-ignore -v cookies.txt yt-dlp current_url.txt checkpoint.txt channel-id-cache.txt
git add -An            # dry run: review exactly what would be tracked
git ls-files           # after committing: must be 6 files, no secrets
```

- `cookies.txt` is the one that matters. It holds live `SID`, `SAPISID`,
  `__Secure-*PSID` and `LOGIN_INFO` values — committing it is an **account
  takeover**, not a lost login. The ignore rule is deliberately broad
  (`*cookies*`), which is also why there is no `cookies.txt.example`; document
  the format in `README.md` instead of shipping a sample file.
- If a secret is ever committed, the fix is **revoke first**: sign out of
  YouTube everywhere to kill the sessions, re-export cookies, *then* rewrite
  history. Rewriting history alone does not un-leak anything already pushed.
- `channel-ids.txt` is committed and reveals what the maintainer subscribes to.
  That is acceptable only because the repo is private — if it is ever made
  public, reconsider.

### Work-vs-personal separation

Rules for anyone (human or agent) working in this repo:

- **Never use the LinkedIn GitHub identity here.** `gh` on this machine is
  authenticated as `qihuang_LinkedIn`, and the global `user.email` is
  `qihuang@linkedin.com`. Both are wrong for this repo. Do not run `gh` here at
  all unless a second personal account is active (`gh auth switch`); prefer
  plain `git` with the pinned SSH command, which cannot pick the wrong account.
- **Never set these values globally.** A global change would silently retarget
  every LinkedIn repo on this machine. If per-directory defaults are ever
  wanted, use a `includeIf "gitdir:~/kh-private/"` block in `~/.gitconfig` —
  scoped to this tree only, never the reverse.
- **Never push this repo to a LinkedIn remote** (`git.corp.linkedin.com`, any
  LinkedIn GitHub org) and never add it to a LinkedIn org, CI, or code-scanning
  setup. Conversely, never push LinkedIn code to this personal remote.
- **Do not apply LinkedIn workflows here.** No MP / `mint` / product-spec
  tooling, no internal PR templates, no Captain/JIRA/Confluence linkage, no
  internal go-links in committed files (the ones in this file are commentary
  about the machine, not dependencies).
- **Do not commit anything LinkedIn-derived** — no internal hostnames, paths,
  usernames, ticket numbers, or snippets of internal code. The
  `go/manage-ssh` reference above is the deliberate exception, kept because it
  explains a real constraint; do not expand on it.
- **Ownership is a question for the user, not for an agent.** Developing a
  personal project on a corporate-managed machine can implicate IP-assignment
  policy. Keeping the repo private limits exposure, but if the user asks about
  making it public, tell them to confirm with their manager or legal rather
  than answering it yourself.



No test suite. After editing a wrapper:

```bash
zsh -n yy.zsh                          # syntax check
pwsh -NoProfile -File yy.ps1 -U        # PowerShell parse + update path
./yy.zsh -U                            # exercises the no-download branch
./yy.zsh -o                            # exercises the channel-check branch
```

To exercise `-o`/`-O` without actually launching browsers, put a stub `open`
earlier on `PATH`:

```bash
mkdir -p /tmp/fakebin && printf '#!/bin/sh\necho "[stub] $*"\n' > /tmp/fakebin/open
chmod +x /tmp/fakebin/open
PATH=/tmp/fakebin:$PATH ./yy.zsh -O
```

Avoid running a real download as a "test" unless the change actually affects
the download path — it hits the network and writes to `t/`.

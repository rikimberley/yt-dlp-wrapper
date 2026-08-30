# AGENTS.md — yt-dlp

Personal wrapper around a vendored [yt-dlp](https://github.com/yt-dlp/yt-dlp)
binary for downloading videos/playlists to a local scratch directory.

**This directory is a git repository** — a *public* repo on the maintainer's
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
| `channel-ids.txt` | Input for `-o`/`-O`. One YouTube channel handle per line (a leading `@` is optional, non-ASCII handles are fine). A raw `UC…` channel id is also accepted and skips handle resolution entirely. Blank lines and `#` comments are skipped. *(gitignored — it is a subscription list, and the repo is public)* |
| `checkpoint.txt`  | Input for `-o`, rewritten by `-c`. Single epoch timestamp; 12+ digits is read as milliseconds, shorter as seconds. *(gitignored)* |
| `channel-id-cache.txt` | Generated cache mapping each handle to its `UC…` channel id, TAB separated, one per line. Pure cache — safe to delete, costs one page fetch per channel to rebuild. *(gitignored)* |
| `downloaded-videos.json` | PowerShell HTML-server completion history: `channel_id`, `video_id`, `target`, and epoch-second `download_epoch`. Entries expire after 45 days. *(gitignored)* |
| `cookies.txt`            | **SECRET.** Netscape-format YouTube cookie jar with live session tokens. *(gitignored)* |
| `t/`               | Default download output directory (`--paths ./t`). Treat as disposable scratch. *(gitignored)* |

## Wrapper Contract

Both `yy.zsh` and `yy.ps1` implement the same interface:

```
./yy.zsh [<url>] [-t <temp_url>] [-p <path>] [-U] [-o | -O | --html] [-c]
```

- positional `<url>` — persisted to `current_url.txt`, then downloaded
- no args — reuses the URL stored in `current_url.txt`
- `-t <temp_url>` — downloads this URL instead, **without** persisting it
  (a positional `<url>` given alongside `-t` is still persisted but not used
  for this run)
- `-p <path>` — downloads into `<path>` instead of the default `./t`
- `-U` — runs `./yt-dlp -U` (self-update), then refreshes the wrapper itself
  from the head of `master` on GitHub, and exits without downloading. Exits
  non-zero if the refresh failed.
- `-o` — for each channel in `channel-ids.txt`, opens
  `https://www.youtube.com/@<channel-id>/videos` in the default browser **only
  if** that channel has a public video published after `checkpoint.txt`;
  otherwise a no-op for that channel. Exits without downloading, and exits
  non-zero if any channel could not be checked.
- `-O` — opens every channel URL unconditionally, with no check. Exits without
  downloading.
- `-c` — overwrites `checkpoint.txt` with the current epoch-ms timestamp. Runs
  **after** `-o`/`-O`, so `./yy.zsh -o -c` means "open whatever is new, then
  mark everything as seen". If at least three `-o` checks fail, or every listed
  channel check fails, the checkpoint is not updated. Exits without downloading.
- `-o` and `-O` are mutually exclusive; `-U` takes precedence over both
- error + non-zero exit when no URL is available from any source

Flag precedence when several are passed: `-U`, then `-o`/`-O`, then `-c`, then
download.

### How `-o` decides

Per channel: resolve the handle to its `UC…` id, then fetch
`https://www.youtube.com/feeds/videos.xml?channel_id=<id>` and take the newest
`<published>` across **all** entries (the feed is not reliably date-sorted).
That Atom feed omits members-only videos, so it is public-by-construction — no
extra members-only filtering is needed, and no cookies are sent. If the legacy
feed is unavailable or unusable, use logged-out `yt-dlp` on the channel's
derived `UU…` uploads playlist, resolve its five newest entries, keep only
entries explicitly marked public, and take the newest exact timestamp. Once
three channels exhaust their feed-fetch retries in one `-o` run, skip feed
fetching for every remaining channel and go directly to the uploads fallback.

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

### How `-U` refreshes the wrapper

Each wrapper refreshes **only itself** — `yy.zsh` fetches `yy.zsh`, `yy.ps1`
fetches `yy.ps1` — from
`https://raw.githubusercontent.com/rikimberley/yt-dlp-wrapper/master/<name>`,
reusing the same gzip + retry fetch path as `-o`. This exists because the
Windows copy is not a git clone and has no other way to track the repo.

Three invariants, both wrappers:

- **Refuse a payload that does not start with the expected shebang**
  (`#!/bin/zsh`, `#!/usr/bin/env pwsh`). A captive portal or an error page
  written over the wrapper would leave the machine with no working wrapper at
  all — and no way to self-update out of it.
- **Write to a same-directory temp file, then rename.** An interrupted write
  must never truncate the running script, and a cross-filesystem `/tmp` staging
  file would lose the atomic rename.
- **Keep the replaced copy as `<name>.bak`.** On the Mac the wrapper *is* the
  git working tree, so `-U` can clobber uncommitted edits; the `.bak` is the
  only way back. Both `*.bak` and `*.new.*` are gitignored.

The file is written as **UTF-8 with no BOM** and left with LF endings, so it
stays byte-identical to the repo. In `yy.ps1` that means
`[System.IO.File]::WriteAllText` with `UTF8Encoding($false)` — 5.1's
`Set-Content -Encoding UTF8` prepends a BOM and would make every run see a diff.

`Update-Self` reports progress with `Write-Host`, never `Write-Output`:
`Write-Output` would join the message into the function's return value and the
`if (Update-Self …)` test would stop meaning anything.

### The download invocation

The download invocation is exactly:

```
./yt-dlp --cookies ./cookies.txt --paths <path> <url>
```

`<path>` defaults to `./t`. Each command is echoed in blue before running.

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
- **Never read out, log, or manually copy `cookies.txt`.** It contains live
  `__Secure-*SID`, `SAPISID`, and `LOGIN_INFO` values. The sole exception is the
  wrapper's `--html` scan pool: it creates one ephemeral `cookies<i>.txt` jar per
  worker slot so concurrent yt-dlp processes never rewrite the same file, then
  deletes those copies when scanning ends. If you must inspect a jar, report only
  structure (cookie names, expiry), never values. Do not commit any jar anywhere,
  and do not paste one into a summary or issue.
- Cookies expire. A download failing with an auth/consent error usually means
  `cookies.txt` needs re-exporting from a browser — that is a user action, not
  something to work around by disabling `--cookies`.
- Do not add new dependencies (Python, pip, ffmpeg wrappers, venvs). The point
  of the vendored binary is zero setup.
- Keep `./t` as the default output directory. `-p <path>` may override it;
  the HTML callback uses `./<channel entry>` directories. Do not delete
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
| Repo | `rikimberley/yt-dlp-wrapper` (**public**) | Named `-wrapper` so it is not mistaken for upstream `yt-dlp`, whose name is taken. Public so `-U` can fetch the wrapper from `raw.githubusercontent.com` with no credentials — a token-authenticated fetch would mean shipping a token to every machine that runs it. |
| Default branch | `master` | Renamed from `main`; `$script_raw_base` / `$scriptRawBase` in both wrappers point at `.../master/`, so renaming the branch again breaks `-U` on every already-deployed copy |
| Remote | `git@github.com:rikimberley/yt-dlp-wrapper.git` | Plain github.com; the key is pinned by `core.sshCommand`, not by an SSH `Host` alias |
| `user.name` | `rikimberley` | Not the work account name |
| `user.email` | `85369872+rikimberley@users.noreply.github.com` | GitHub noreply — never publishes a real or work email |
| `core.sshCommand` | `ssh -F /dev/null -i ~/.ssh/rikimberley_github_ed25519 -o IdentitiesOnly=yes -o IdentityAgent=none` | Pins the personal key; **`-F /dev/null` is load-bearing**, see below |

Note the local directory `yt-dlp-wrapper/` matches the repo name. The repo is
named `-wrapper` because `yt-dlp` is upstream's name and this is only a set of
wrapper scripts around their binary.

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
If that key is registered on the work GitHub account, the operation
authenticates as the *wrong identity*.

**`IdentitiesOnly=yes` alone does not stop this — that was tried and it
failed.** `IdentitiesOnly` restricts ssh to keys *named in the configuration*,
and the catch-all above names the corporate key, so it stays a candidate. Once
the personal key was (temporarily) removed from the account, ssh fell straight
through to it:

```
Offering public key: rikimberley_github_ed25519   -> rejected
Offering public key: qihuang_at_linkedin.com_ssh_key
Server accepts key:  qihuang_at_linkedin.com_ssh_key
Authenticated to github.com using "publickey"
Repository not found.
```

That is git talking to GitHub as `qihuang_LinkedIn`. The actual fix is
**`-F /dev/null`**, which makes ssh ignore the corporate config entirely, so
only the `-i` key can ever be offered. `IdentitiesOnly=yes` and
`IdentityAgent=none` stay as defence in depth (no agent key can be volunteered
either). Do not remove `-F /dev/null`, and do not "restore" the user config for
convenience. Keep personal config out of corporate files.

Correct behaviour when the key is missing or wrong is a hard
`Permission denied (publickey)` — failing closed. If you ever see
`Repository not found` instead, stop: that means authentication *succeeded* as
some other account.

### Never add the SSH key with a token

Register the public key through the GitHub **web UI**
(github.com/settings/keys), never via `POST /user/keys` with a personal access
token. GitHub ties a key created that way to the token's authorization and
**deletes the key when the token is revoked** — which is exactly what happened
here: the key was added by API, the setup PAT was revoked minutes later as
instructed, and the key silently vanished, which is what exposed the fallback
above. A UI-added key has no such lifetime coupling.

### Pushing

Copilot CLI on this machine blocks the **bare `ssh` command** via a security
hook, so an agent cannot run `ssh -T git@github.com`. It does **not** block ssh
invoked by git as a transport, so `git push` / `git fetch` / `git ls-remote`
work normally from an agent. Do not try to work around the hook.

Do not switch the remote to HTTPS to dodge anything — HTTPS would fall back to
the `osxkeychain` credential helper, which holds the *work* GitHub token, and
the operation would authenticate as the wrong account.

Since bare `ssh -T` is unavailable, verify isolation through git instead, which
also exercises the exact command real pushes use:

```bash
GIT_SSH_COMMAND="ssh -v -F /dev/null -i ~/.ssh/rikimberley_github_ed25519 \
  -o IdentitiesOnly=yes -o IdentityAgent=none" git ls-remote origin 2>&1 \
  | grep -E 'Offering|Server accepts|Authenticated to|denied'
```

Exactly one key may be offered — `rikimberley_github_ed25519`. If
`qihuang_at_linkedin.com_ssh_key` appears on an `Offering` or `Server accepts`
line, the isolation is broken; stop and fix it before pushing.

### The binary is intentionally not committed

`yt-dlp` (~38 MB) is gitignored. `./yy.zsh -U` rewrites it in place, so
committing it would append a fresh 38 MB blob to history on **every** update,
growing without bound and unfixable without a history rewrite. `README.md`
tells users how to fetch it. Do not add it, and do not "solve" this with Git
LFS — it buys nothing here.

### Never commit

`.gitignore` is safety-critical, not tidiness. Before any `git add`, confirm:

```bash
git check-ignore -v cookies.txt yt-dlp current_url.txt checkpoint.txt channel-id-cache.txt channel-ids.txt
git add -An            # dry run: review exactly what would be tracked
git ls-files           # after committing: must be 5 files, no secrets
```

- `cookies.txt` is the one that matters. It holds live `SID`, `SAPISID`,
  `__Secure-*PSID` and `LOGIN_INFO` values — committing it is an **account
  takeover**, not a lost login. The ignore rule is deliberately broad
  (`*cookies*`), which is also why there is no `cookies.txt.example`; document
  the format in `README.md` instead of shipping a sample file.
- If a secret is ever committed, the fix is **revoke first**: sign out of
  YouTube everywhere to kill the sessions, re-export cookies, *then* rewrite
  history. Rewriting history alone does not un-leak anything already pushed.
- `channel-ids.txt` reveals what the maintainer subscribes to, so it is
  **gitignored**. It was tracked while the repo was private; that history was
  purged with `git filter-branch`, so no commit reachable from `master` contains
  it. Do not re-add it — `git add -f` would put it straight back into a public
  history.
  Note the purge is *not* a revocation: GitHub still serves orphaned commits by
  direct SHA until its own GC runs, so the pre-rewrite blob remains fetchable at
  the old SHAs. That was accepted deliberately — the exposure is two channel
  handles — rather than deleting and recreating the repo. Do not repeat this
  reasoning for anything sensitive: for a real secret the rewrite is worthless
  on its own, and the rule in this section stands (**revoke first**, then
  rewrite).

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
  policy. The repo is now **public**, which removes the containment that being
  private provided — the maintainer was told to confirm with their manager or
  legal, and that remains their call, not an agent's. Do not answer it yourself,
  and do not treat "it is already public" as settling the question.
- **Public repo tightens the "never commit" rules, it does not relax them.**
  Every `git push` is now world-readable and immediately mirrored by third-party
  crawlers, so a leaked `cookies.txt` is exposed the moment it lands rather than
  only to collaborators. Re-read `### Never commit` before any `git add`.



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

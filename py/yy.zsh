#!/bin/zsh
# ---------------------------------------------------------------------------
# Thin launcher for yy.py. All behaviour lives in yy.py; this file only finds
# a usable Python interpreter and hands off, so there is nothing here that has
# to stay in sync with yy.ps1.
#
# Keep this script trivial. Anything added here is a divergence again. The one
# exception is --no-py below, which has to live here: it exists to recover a
# directory whose yy.py or Python interpreter is the thing that is broken, so
# it cannot be implemented in yy.py.
# ---------------------------------------------------------------------------

set -u

script_dir=${0:A:h}
target="$script_dir/yy.py"
min_major=3
min_minor=9
script_raw_base="https://raw.githubusercontent.com/rikimberley/yt-dlp-wrapper/master"

# --no-py: replace this launcher with the shell build from the head of master,
# the inverse of the shell build's --py. Handled before yy.py and the
# interpreter are looked for, for the reason given above.
#
# Both wrappers are replaced, not just this one: a shell-build yy.zsh sitting
# next to a yy.ps1 launcher is two different builds sharing one state
# directory, and whichever wrapper the next run picks would decide which
# build it got.
no_py_fetch() {
  local name=$1 sentinel=$2 body tmp
  body=$(curl -fsSL --compressed --retry 3 --max-time 60 \
    "$script_raw_base/$name") || {
    printf 'Error: could not fetch %s from master\n' "$name" >&2
    return 1
  }
  # Same sentinel rule as -U: a captive portal or a 404 page written here
  # would leave the directory with no working wrapper and no way back.
  if [[ "$body" != "${sentinel}"* ]]; then
    printf 'Error: refusing to overwrite %s: ' "$name" >&2
    printf 'fetched body does not start with %s\n' "$sentinel" >&2
    return 1
  fi
  mkdir -p "$script_dir/.tmp"
  tmp="$script_dir/${name}.new.$$"
  print -r -- "$body" > "$tmp" || return 1
  # Always executable for the zsh wrapper: --no-py can create one where the
  # target does not exist yet, and -x on an absent file is false.
  if [[ -x "$script_dir/$name" || "$name" == *.zsh ]]; then chmod +x "$tmp" || true; fi
  [[ -f "$script_dir/$name" ]] && {
    cp -p -- "$script_dir/$name" "$script_dir/.tmp/${name}.bak" || true
  }
  mv -f -- "$tmp" "$script_dir/$name" || return 1
  return 0
}

for arg in "$@"; do
  [[ "$arg" == "--no-py" ]] || continue

  # The *other* wrapper goes first and this one last, so a failure leaves the
  # launcher the user just invoked still able to understand --no-py and retry.
  no_py_fetch 'yy.ps1' '#!/usr/bin/env pwsh' || exit 1
  if ! no_py_fetch 'yy.zsh' '#!/bin/zsh'; then
    printf 'Error: ./yy.ps1 is now the shell build but ./yy.zsh is still a\n' >&2
    printf '       launcher. Re-run --no-py; what already landed is kept.\n' >&2
    exit 1
  fi
  printf 'Switched to the shell build. Previous copies are in .tmp.\n'
  if [[ -f "$script_dir/yy.py" ]]; then
    printf 'yy.py is left in place but unused; the shell build never reads it.\n'
  fi
  exit 0
done

if [[ ! -f "$target" ]]; then
  printf 'Error: %s not found\n' "$target" >&2
  exit 1
fi

# Probe order: an explicit override first, then the usual names. A candidate
# has to actually run and meet the version floor; merely existing on PATH is
# not enough, because some installs are stubs that do nothing useful.
usable_python() {
  local candidate
  for candidate in "$@"; do
    [[ -n "$candidate" ]] || continue
    if "$candidate" -c "import sys; sys.exit(0 if sys.version_info >= ($min_major, $min_minor) else 1)" >/dev/null 2>&1; then
      print -r -- "$candidate"
      return 0
    fi
  done
  return 1
}

python_exe=$(usable_python "${YY_PYTHON:-}" python3 python) || {
  printf 'Error: no Python %s.%s+ interpreter found.\n' "$min_major" "$min_minor" >&2
  printf 'Install one, or set YY_PYTHON to its full path:\n' >&2
  printf '  macOS:  xcode-select --install   (provides /usr/bin/python3)\n' >&2
  printf '  Linux:  install your distribution'"'"'s python3 package\n' >&2
  exit 1
}

exec "$python_exe" "$target" "$@"

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
for arg in "$@"; do
  [[ "$arg" == "--no-py" ]] || continue

  body=$(curl -fsSL --compressed --retry 3 --max-time 60 \
    "$script_raw_base/yy.zsh") || {
    printf 'Error: could not fetch yy.zsh from master\n' >&2
    exit 1
  }
  # Same sentinel rule as -U: a captive portal or a 404 page written here
  # would leave the directory with no working wrapper and no way back.
  if [[ "$body" != '#!/bin/zsh'* ]]; then
    printf 'Error: refusing to overwrite yy.zsh: ' >&2
    printf 'fetched body does not start with #!/bin/zsh\n' >&2
    exit 1
  fi
  mkdir -p "$script_dir/.tmp"
  tmp="$script_dir/yy.zsh.new.$$"
  print -r -- "$body" > "$tmp" || exit 1
  [[ -x "$script_dir/yy.zsh" ]] && { chmod +x "$tmp" || true }
  [[ -f "$script_dir/yy.zsh" ]] && {
    cp -p -- "$script_dir/yy.zsh" "$script_dir/.tmp/yy.zsh.bak" || true
  }
  mv -f -- "$tmp" "$script_dir/yy.zsh" || exit 1
  printf 'Switched to the shell build. Previous copy is in .tmp/yy.zsh.bak\n'
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

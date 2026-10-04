#!/bin/zsh
# ---------------------------------------------------------------------------
# Thin launcher for yy.py. All behaviour lives in yy.py, including --no-py;
# this file only finds a usable Python interpreter and hands off, so there is
# nothing here that has to stay in sync with yy.ps1.
#
# Keep this script trivial. Anything added here is a divergence again: whatever
# it is would have to be written twice, once here and once in yy.ps1.
# ---------------------------------------------------------------------------

set -u

script_dir=${0:A:h}
target="$script_dir/yy.py"
min_major=3
min_minor=9

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

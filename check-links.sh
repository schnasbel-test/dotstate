#!/usr/bin/env bash
# Read-only: verifies every file install.sh would symlink from this repo
# into $HOME is still actually linked there - and correctly.
#
# Usage: ./check-links.sh
#
# Catches drift that isn't about packages but about the config files
# themselves, e.g. something (an app, an Omarchy hook, a careless `cp`)
# silently replacing a symlink with a real file. Never touches anything -
# it only reports; re-run install.sh to restore a broken link.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="$(hostname)"

log() { echo -e "\033[1;34m==>\033[0m $*"; }

declare -A expected

collect() {
  local root="$1"
  [ -d "$root" ] || return 0
  while IFS= read -r -d '' src; do
    expected["${src#"$root"/}"]="$src"
  done < <(find "$root" -type f -print0)
}

# home.$HOST/ collected after home/, so it wins on overlap - same precedence
# install.sh uses.
collect "$REPO_DIR/home"
collect "$REPO_DIR/home.$HOST"

ok=0
missing=()
real_same=()
real_diff=()
wrong_target=()

for rel in $(printf '%s\n' "${!expected[@]}" | sort); do
  src="${expected[$rel]}"
  target="$HOME/$rel"

  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    missing+=("$rel")
  elif [ -L "$target" ]; then
    if [ "$(readlink -f "$target" 2>/dev/null)" = "$(readlink -f "$src")" ]; then
      ok=$((ok + 1))
    else
      wrong_target+=("$rel -> $(readlink -f "$target" 2>/dev/null || echo "(broken)")")
    fi
  else
    if cmp -s "$target" "$src"; then
      real_same+=("$rel")
    else
      real_diff+=("$rel")
    fi
  fi
done

log "$ok file(s) correctly linked"

if [ "${#real_diff[@]}" -gt 0 ]; then
  log "Real file with DIFFERENT content than the repo (likely local edits never adopted):"
  printf '    %s\n' "${real_diff[@]}"
fi
if [ "${#wrong_target[@]}" -gt 0 ]; then
  log "Symlink pointing at the wrong place (broken or stale):"
  printf '    %s\n' "${wrong_target[@]}"
fi
if [ "${#real_same[@]}" -gt 0 ]; then
  log "Real file instead of a symlink, but content matches the repo (cosmetic, re-link when convenient):"
  printf '    %s\n' "${real_same[@]}"
fi
if [ "${#missing[@]}" -gt 0 ]; then
  log "Missing entirely (nothing at this path in \$HOME):"
  printf '    %s\n' "${missing[@]}"
fi

if [ "${#real_diff[@]}" -gt 0 ] || [ "${#wrong_target[@]}" -gt 0 ] || [ "${#real_same[@]}" -gt 0 ] || [ "${#missing[@]}" -gt 0 ]; then
  echo
  log "Nothing was changed. Fix by re-running ./install.sh (backs up any real file first),"
  log "or adopt local edits with ./adopt.sh if the DIFFERENT-content ones should win instead."
  exit 1
fi

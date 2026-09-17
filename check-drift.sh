#!/usr/bin/env bash
# Read-only: compares packages/*.txt against what's actually installed.
#
# Usage: ./check-drift.sh
#
# Never installs or removes anything - it only reports. Two kinds of drift:
#   - installed, but not tracked in packages/*.txt (you `pacman -S`'d
#     something ad-hoc and forgot to adopt it into the repo)
#   - tracked in packages/*.txt, but not installed on this machine (removed
#     locally, or the list rotted)
# Packages that are part of a stock Omarchy install are excluded from
# "untracked", since packages/*.txt is only meant to hold what's on top of
# that (see README).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$REPO_DIR/packages"
OMARCHY_INSTALL_DIR="/usr/share/omarchy/install"
HOST="$(hostname)"

log()  { echo -e "\033[1;34m==>\033[0m $*"; }

read_list() {
  grep -vE '^\s*#|^\s*$' "$1" 2>/dev/null || true
}

sorted() { tr ' ' '\n' <<<"$*" | grep -v '^$' | sort -u; }
# shellcheck disable=SC2001 # sed's per-line ^ anchor has no simple bash equivalent here
indent() { sed 's/^/    /'; }

diff_lists() {
  # Prints lines only in $1 (both args are newline-separated, pre-sorted).
  comm -23 <(echo "$1") <(echo "$2")
}

main() {
  local omarchy_native repo_native installed_native
  local repo_aur installed_aur

  if [ -f "$OMARCHY_INSTALL_DIR/omarchy-base.packages" ]; then
    omarchy_native="$(sorted "$(read_list "$OMARCHY_INSTALL_DIR/omarchy-base.packages") $(read_list "$OMARCHY_INSTALL_DIR/omarchy-other.packages")")"
  else
    log "Omarchy install package lists not found at $OMARCHY_INSTALL_DIR, treating baseline as empty"
    omarchy_native=""
  fi

  repo_native="$(sorted "$(read_list "$PKG_DIR/pacman.common.txt") $(read_list "$PKG_DIR/pacman.$HOST.txt")")"
  repo_aur="$(sorted "$(read_list "$PKG_DIR/aur.common.txt") $(read_list "$PKG_DIR/aur.$HOST.txt")")"

  installed_aur="$(sorted "$(pacman -Qqm)")"
  installed_native="$(sorted "$(comm -23 <(pacman -Qqe | sort -u) <(echo "$installed_aur"))")"

  local untracked_native untracked_aur missing_native missing_aur
  untracked_native="$(diff_lists "$installed_native" "$(sorted "$repo_native $omarchy_native")")"
  untracked_aur="$(diff_lists "$installed_aur" "$repo_aur")"
  missing_native="$(diff_lists "$repo_native" "$installed_native")"
  missing_aur="$(diff_lists "$repo_aur" "$installed_aur")"

  local dirty=0

  if [ -n "$untracked_native" ]; then
    dirty=1
    log "Installed (native) but not in packages/pacman.{common,$HOST}.txt:"
    indent <<<"$untracked_native"
  fi
  if [ -n "$untracked_aur" ]; then
    dirty=1
    log "Installed (AUR) but not in packages/aur.{common,$HOST}.txt:"
    indent <<<"$untracked_aur"
  fi
  if [ -n "$missing_native" ]; then
    dirty=1
    log "In packages/pacman.{common,$HOST}.txt but not installed here:"
    indent <<<"$missing_native"
  fi
  if [ -n "$missing_aur" ]; then
    dirty=1
    log "In packages/aur.{common,$HOST}.txt but not installed here:"
    indent <<<"$missing_aur"
  fi

  if [ "$dirty" = "0" ]; then
    log "No drift: packages/*.txt matches what's installed on $HOST."
  else
    echo
    log "Nothing was changed. Adopt manually with:"
    echo "    echo <pkg> >> packages/pacman.common.txt   (or aur.common.txt / .$HOST.txt)"
    echo "  or drop a line if it's genuinely no longer wanted."
  fi
}

main "$@"

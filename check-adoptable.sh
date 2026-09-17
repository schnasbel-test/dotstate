#!/usr/bin/env bash
# Read-only: finds well-known config paths under $HOME that aren't tracked
# in this repo yet, and prints a ready-to-run adopt.sh command for each.
#
# Usage: ./check-adoptable.sh
#
# Deliberately an ALLOWLIST, not a denylist: only paths matching ALLOWLIST
# below are ever suggested. A denylist has to name every risky thing in
# advance and this repo has already shipped one that didn't (see README.md's
# "Why adopt.sh refuses some paths") - an allowlist can only ever suggest
# too little, never too much. Extend ALLOWLIST yourself for tools it
# doesn't know about; adopt.sh's own hard blocklist still applies to
# whatever you adopt regardless of how you found it.
#
# This is a starting point, not a verdict - review each suggestion before
# running it. Checks top-level entries only (e.g. all of ~/.config/nvim as
# one candidate), matching the granularity adopt.sh itself adopts at.
# Deliberately prints one adopt.sh command per candidate rather than a
# single "adopt everything" one-liner: reviewing and running commands one
# at a time is the point, not friction to route around.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo -e "\033[1;34m==>\033[0m $*"; }

# Common terminal/editor/WM/shell config directories with no credential or
# runtime-state content of their own. Deliberately conservative: it's much
# cheaper to manually adopt something missing from this list than to clean
# up after suggesting something that shouldn't have been.
ALLOWLIST_CONFIG_DIRS=(
  hypr waybar wofi rofi walker
  alacritty kitty foot ghostty wezterm
  tmux nvim vim helix zellij
  git gtk-3.0 gtk-4.0 fontconfig
  lazygit btop htop fcitx5
  mise direnv fish
  menus autostart
)
ALLOWLIST_CONFIG_FILES=(
  mimeapps.list starship.toml user-dirs.dirs user-dirs.locale
)
ALLOWLIST_DOTFILES=(
  .bashrc .bash_profile .bash_login .profile
  .zshrc .zprofile .zshenv
  .gitconfig .gitignore_global
  .tmux.conf .vimrc .inputrc .Xresources .xinitrc
)

in_list() {
  local needle="$1" item
  shift
  for item; do [ "$needle" = "$item" ] && return 0; done
  return 1
}

already_tracked() {
  local target="$1"
  if [ -L "$target" ]; then
    case "$(readlink -f "$target" 2>/dev/null)" in
      "$REPO_DIR"/*) return 0 ;;
    esac
  fi
  return 1
}

# Prints the real path of the first symlink at or under $1 that resolves
# outside this repo, or nothing if there is none. install.sh symlinks
# individual files, not whole directories, so a directory that looks
# untouched at the top (not a symlink itself) can still be full of files
# another dotfiles repo already manages - suggesting it whole would have
# adopt.sh copy those symlinks-as-symlinks instead of their real content
# and then delete the originals, breaking whatever pointed at them.
find_foreign_symlink() {
  local path="$1" link real
  if [ -L "$path" ]; then
    real="$(readlink -f "$path" 2>/dev/null || true)"
    case "$real" in
      "$REPO_DIR"/*) ;;
      *) [ -n "$real" ] && { echo "$real"; return 0; } ;;
    esac
    return 1
  fi
  [ -d "$path" ] || return 1
  while IFS= read -r -d '' link; do
    real="$(readlink -f "$link" 2>/dev/null || true)"
    case "$real" in
      "$REPO_DIR"/*) ;;
      *) [ -n "$real" ] && { echo "$real"; return 0; } ;;
    esac
  done < <(find "$path" -type l -print0 2>/dev/null)
  return 1
}

main() {
  local candidates=() managed_elsewhere=() entry base foreign

  for entry in "$HOME"/.config/*; do
    [ -e "$entry" ] || continue
    base="$(basename "$entry")"
    if [ -d "$entry" ]; then
      in_list "$base" "${ALLOWLIST_CONFIG_DIRS[@]}" || continue
    else
      in_list "$base" "${ALLOWLIST_CONFIG_FILES[@]}" || continue
    fi
    already_tracked "$entry" && continue
    foreign="$(find_foreign_symlink "$entry")" || true
    if [ -n "$foreign" ]; then
      managed_elsewhere+=(".config/$base -> $foreign")
      continue
    fi
    candidates+=(".config/$base")
  done

  shopt -s dotglob nullglob
  for entry in "$HOME"/.*; do
    base="$(basename "$entry")"
    [ -f "$entry" ] || continue
    in_list "$base" "${ALLOWLIST_DOTFILES[@]}" || continue
    already_tracked "$entry" && continue
    foreign="$(find_foreign_symlink "$entry")" || true
    if [ -n "$foreign" ]; then
      managed_elsewhere+=("$base -> $foreign")
      continue
    fi
    candidates+=("$base")
  done
  shopt -u dotglob nullglob

  if [ "${#managed_elsewhere[@]}" -gt 0 ]; then
    log "Already managed by another repo (not suggesting these):"
    printf '    %s\n' "${managed_elsewhere[@]}"
    echo
  fi

  if [ "${#candidates[@]}" -eq 0 ]; then
    log "Nothing from the known-config allowlist found untracked under \$HOME."
    log "Have something else to adopt? Nothing was changed - run"
    log "  ./adopt.sh ~/.config/<yourtool>"
    log "yourself; this script only ever suggests from a fixed, conservative list."
    exit 0
  fi

  log "Known config paths under \$HOME not tracked yet - review each, then:"
  local c
  for c in "${candidates[@]}"; do
    echo "    ./adopt.sh \"\$HOME/$c\""
  done
  log "...use --host instead for anything machine-specific."
}

main "$@"

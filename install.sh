#!/usr/bin/env bash
# Restore dotfiles + packages on a fresh Omarchy install.
#
# Usage: ./install.sh
#
# Safe to re-run. Existing real files are backed up (not deleted) before
# being replaced with symlinks into this repo.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$HOME/.dotstate-backup-$(date +%Y%m%d-%H%M%S)"
PKG_DIR="$REPO_DIR/packages"
HOST="$(hostname)"

log()  { echo -e "\033[1;34m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m==>\033[0m $*"; }
err()  { echo -e "\033[1;31m==>\033[0m $*" >&2; }

# Refuse to run from an Omarchy plugin checkout: `omarchy plugin add` clones
# this repo into its own directory under ~/.config/omarchy/plugins/<id>/ so
# the bar widget has code to load, separate from wherever the real working
# dotfiles checkout lives (e.g. ~/Projects/dotfiles). That plugin clone is
# managed by Omarchy (updated/removed on its own schedule) and was never
# meant to be install.sh'd directly - doing so anyway has, in practice,
# ended with every symlinked config pointing into a directory that Omarchy
# then deleted out from under it. If you're reading this from a plugin
# checkout, run install.sh from your actual dotfiles repo instead.
guard_not_plugin_checkout() {
  case "$REPO_DIR" in
    "$HOME"/.config/omarchy/plugins/*)
      err "Refusing to run from an Omarchy plugin checkout ($REPO_DIR)."
      err "This directory is managed by Omarchy and can be updated/removed at any time."
      err "Run install.sh from your real dotfiles checkout (see README.md Quickstart) instead."
      exit 1
      ;;
  esac
}

read_list() {
  # Strips comments/blank lines from a package/plugin list file.
  grep -vE '^\s*#|^\s*$' "$1" 2>/dev/null || true
}

install_packages() {
  log "Installing native packages (common + $HOST)"
  local pkgs
  pkgs="$(read_list "$PKG_DIR/pacman.common.txt"; read_list "$PKG_DIR/pacman.$HOST.txt")"
  if [ -n "$pkgs" ]; then
    # shellcheck disable=SC2086 # $pkgs is a list of package names, meant to split into args
    sudo pacman -S --needed --noconfirm $pkgs
  fi

  log "Installing AUR packages (common + $HOST)"
  local aur_pkgs
  aur_pkgs="$(read_list "$PKG_DIR/aur.common.txt"; read_list "$PKG_DIR/aur.$HOST.txt")"
  if [ -n "$aur_pkgs" ]; then
    if ! command -v yay >/dev/null 2>&1; then
      warn "yay not found, skipping AUR packages: $aur_pkgs"
    else
      # shellcheck disable=SC2086 # $aur_pkgs is a list of package names, meant to split into args
      yay -S --needed --noconfirm $aur_pkgs
    fi
  fi
}

install_omarchy_plugins() {
  log "Adding Omarchy shell plugins from packages/omarchy-plugins.txt"
  if ! command -v omarchy >/dev/null 2>&1; then
    warn "omarchy CLI not found, skipping plugin install"
    return
  fi
  read_list "$PKG_DIR/omarchy-plugins.txt" | while read -r url; do
    log "  omarchy plugin add $url --enable --yes"
    omarchy plugin add "$url" --enable --yes || warn "  failed to add $url (may already be installed)"
  done
}

link_tree() {
  # Symlinks every file under $1 (a "home"-style dir mirroring $HOME) into
  # $HOME, preserving its relative path. Later calls override earlier ones
  # for the same path, since host-specific dirs are linked after home/.
  local root="$1"
  [ -d "$root" ] || return 0

  log "Symlinking dotfiles from $root into $HOME"

  while IFS= read -r -d '' src; do
    local rel="${src#"$root"/}"
    local target="$HOME/$rel"

    # Already correctly linked: nothing to do.
    if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$(readlink -f "$src")" ]; then
      continue
    fi

    # Already a symlink, but into some OTHER repo (a different dotfiles
    # checkout already manages this path): refuse instead of silently
    # backing it up and taking over. Mirrors adopt.sh's foreign-symlink
    # check - this is the exact gap that let two dotfiles repos fight over
    # the same $HOME paths with no warning, which has previously left
    # configs (including Hyprland's) pointing at a directory that got
    # deleted out from under them. No override flag: resolve it by hand
    # (decide which repo should own it, remove the other's claim) instead
    # of letting install.sh guess.
    if [ -L "$target" ]; then
      local current_link
      current_link="$(readlink -f "$target" 2>/dev/null || true)"
      case "$current_link" in
        "$REPO_DIR"/*) ;;
        *)
          if [ -n "$current_link" ]; then
            warn "Skipping $rel: already a symlink into a different repo ($current_link)."
            warn "  Not relinking - remove that repo's claim on this path first if $REPO_DIR should own it."
            conflicts=1
            continue
          fi
          ;;
      esac
    fi

    mkdir -p "$(dirname "$target")"

    if [ -e "$target" ] || [ -L "$target" ]; then
      mkdir -p "$(dirname "$BACKUP_DIR/$rel")"
      mv "$target" "$BACKUP_DIR/$rel"
      backed_up=1
    fi

    ln -s "$src" "$target"
  done < <(find "$root" -type f -print0)
}

link_dotfiles() {
  backed_up=0
  conflicts=0

  link_tree "$REPO_DIR/home"
  link_tree "$REPO_DIR/home.$HOST"

  if [ "$backed_up" = "1" ]; then
    log "Existing files were backed up to $BACKUP_DIR"
  fi
  if [ "$conflicts" = "1" ]; then
    warn "Some paths were skipped because another repo already manages them - see above."
  fi
}

setup_git_hooks() {
  log "Pointing this repo's git hooks at githooks/ (secret scan on commit)"
  git -C "$REPO_DIR" config core.hooksPath githooks
}

setup_backup_timer() {
  log "Enabling dotstate-backup timer (daily auto commit+push)"
  local unit_dir="$HOME/.config/systemd/user"
  mkdir -p "$unit_dir"
  sed "s|__REPO_DIR__|$REPO_DIR|g" "$REPO_DIR/systemd/dotstate-backup.service.tmpl" \
    > "$unit_dir/dotstate-backup.service"
  cp "$REPO_DIR/systemd/dotstate-backup.timer" "$unit_dir/dotstate-backup.timer"
  systemctl --user daemon-reload
  systemctl --user enable --now dotstate-backup.timer
}

run_post_install_hook() {
  # Optional escape hatch for whatever this repo's own configs need beyond
  # what install.sh generalizes (a theme, a personal service, ...). Dotstate
  # itself ships no such hook - add one in your own repo if you need it.
  local hook="$REPO_DIR/post-install.sh"
  if [ -x "$hook" ]; then
    log "Running post-install.sh"
    "$hook"
  fi
}

main() {
  guard_not_plugin_checkout

  install_packages
  install_omarchy_plugins
  link_dotfiles
  setup_git_hooks
  setup_backup_timer
  run_post_install_hook

  log "Done."
  echo "  - Reload:  hyprctl reload  (or just log out/in)"
  if [ ! -x "$REPO_DIR/post-install.sh" ]; then
    echo "  - Add a post-install.sh at the repo root for any manual steps specific to your setup."
  fi
  if [ "$conflicts" = "1" ]; then
    echo "  - Some configs were skipped due to another repo already managing them - see warnings above."
  fi
}

main "$@"

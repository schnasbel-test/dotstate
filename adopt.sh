#!/usr/bin/env bash
# Adopt existing config files/directories on this system into the repo.
#
# Usage: ./adopt.sh [--host] <path> [<path> ...]
#
# This is the reverse of install.sh: instead of linking repo files into
# $HOME, it takes real files that already live under $HOME, moves them
# into home/<relative-path>, replaces the original with a symlink into
# the repo (same layout install.sh creates), and stages them in git.
#
# --host adopts into home.<hostname>/ instead of home/, for config that
# is specific to this machine (different hardware, monitors, etc.) and
# should not be shared with other machines.
#
# Safe to re-run: paths already adopted (already a symlink into the repo)
# are skipped. Refuses anything that looks like credential/state data
# (by name, pattern, or just being unexpectedly large) - see README.md.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_NAME="home"

log()  { echo -e "\033[1;34m==>\033[0m $*"; }
err()  { echo -e "\033[1;31m==>\033[0m $*" >&2; }

# Hard safety net: refused no matter how the path was requested (manually
# typed or suggested by check-adoptable.sh), and there is no override flag -
# if you genuinely want one of these in git, do it by hand outside this
# script so it's a deliberate, visible act. See README.md's "Why adopt.sh
# refuses some paths" for the incident that made this necessary: a directory
# that looked like a plain config on top adopted several real credential
# files nested inside it (shell CLI auth tokens, editor session state)
# because nothing here knew their names in advance.
BLOCKED_BASENAMES=(
  ".ssh" ".gnupg" ".password-store" ".netrc" ".npmrc" ".pypirc"
  ".docker" ".kube" ".aws" ".azure" "gh" ".git-credentials"
  ".bash_history" ".zsh_history" ".python_history" ".lesshst" ".viminfo"
  ".claude.json" ".claude"
  "Code" "Cursor" "opencode" "omamail" "herdr"
)

is_blocked_by_name() {
  local rel="$1" b
  for b in "${BLOCKED_BASENAMES[@]}"; do
    case "$rel" in
      "$b" | "$b"/* | */"$b" | */"$b"/*) return 0 ;;
    esac
  done
  return 1
}

# Case-insensitive, catches credential/state-shaped names this script has
# never heard of - the actual point of this layer, since BLOCKED_BASENAMES
# above can only ever list what's already known to be risky.
is_blocked_by_pattern() {
  local rel_lower
  rel_lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$rel_lower" in
    *history*|*token*|*credential*|*secret*|*password*|*session*|*cookie*|*auth*|*cache*) return 0 ;;
  esac
  return 1
}

# A real config is small text. Anything bigger than this is almost
# certainly app state/cache/a database, adopted or not - refuse rather
# than silently committing megabytes of binary blobs to git.
MAX_ADOPT_BYTES=$((5 * 1024 * 1024))

is_too_large() {
  local path="$1" size
  size="$(du -sb "$path" 2>/dev/null | cut -f1)"
  [ -n "$size" ] && [ "$size" -gt "$MAX_ADOPT_BYTES" ]
}

# Prints why $1 (relative path $2) should be refused, checking $1 itself,
# every entry nested under it if it's a directory, and its total size -
# empty output means it's fine to proceed.
find_blocked_reason() {
  local path="$1" rel="$2" entry entry_rel

  if is_blocked_by_name "$rel" || is_blocked_by_pattern "$rel"; then
    echo "looks like credential/state data ($rel)"
    return 0
  fi

  if is_too_large "$path"; then
    echo "larger than $((MAX_ADOPT_BYTES / 1024 / 1024))MB - not a typical config, refusing to guess what's in it"
    return 0
  fi

  if [ -d "$path" ]; then
    while IFS= read -r -d '' entry; do
      entry_rel="${entry#"$HOME"/}"
      if is_blocked_by_name "$entry_rel" || is_blocked_by_pattern "$entry_rel"; then
        echo "contains $entry_rel, which looks like credential/state data"
        return 0
      fi
    done < <(find "$path" -mindepth 1 -print0 2>/dev/null)
  fi

  return 1
}

# Prints the real path of the first symlink at or under $1 that resolves
# outside this repo, or nothing if there is none. Catches both "$1 itself
# is such a symlink" and "$1 is a real directory containing one" - the
# latter is how install.sh actually lays things out (it symlinks individual
# files, not whole directories), so a directory that looks unmanaged at the
# top can still be full of files another dotfiles repo already owns.
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

adopt_path() {
  local target="$1"
  # Normalize to an absolute path WITHOUT resolving symlinks: if $target
  # is itself a symlink (e.g. already adopted, pointing into the repo),
  # we need to operate on the symlink, not on whatever it points to.
  target="$(realpath -sm "$target")"

  case "$target" in
    "$HOME"/*) ;;
    *) err "Skipping $target: not under \$HOME"; return 1 ;;
  esac

  local rel="${target#"$HOME"/}"
  local dest="$REPO_DIR/$DEST_NAME/$rel"

  if [ -L "$target" ]; then
    local current_link
    current_link="$(readlink -f "$target" 2>/dev/null || true)"
    if [ "$current_link" = "$(readlink -f "$dest" 2>/dev/null || true)" ]; then
      log "Already adopted: $rel"
      return 0
    fi
    case "$current_link" in
      "$REPO_DIR"/*)
        err "Skipping $rel: already adopted elsewhere in the repo ($current_link) - use 'git mv' manually to relocate"
        return 1
        ;;
    esac
  fi

  if [ ! -e "$target" ]; then
    err "Skipping $rel: does not exist"
    return 1
  fi

  local blocked
  blocked="$(find_blocked_reason "$target" "$rel")" || true
  if [ -n "$blocked" ]; then
    err "Refusing $rel: $blocked"
    return 1
  fi

  local foreign
  foreign="$(find_foreign_symlink "$target")" || true
  if [ -n "$foreign" ]; then
    err "Skipping $rel: already managed by another repo (points into $foreign) - adopt it there instead, or remove that management first if you really want it here"
    return 1
  fi

  if [ -e "$dest" ]; then
    err "Skipping $rel: $DEST_NAME/$rel already exists in repo (resolve manually)"
    return 1
  fi

  mkdir -p "$(dirname "$dest")"
  cp -a "$target" "$dest"
  rm -rf "$target"
  ln -s "$dest" "$target"
  git -C "$REPO_DIR" add -- "$DEST_NAME/$rel"
  log "Adopted $rel -> $DEST_NAME/$rel"
}

main() {
  while [ "$#" -gt 0 ] && [ "$1" = "--host" ]; do
    DEST_NAME="home.$(hostname)"
    shift
  done

  if [ "$#" -eq 0 ]; then
    err "Usage: $0 [--host] <path> [<path> ...]"
    exit 1
  fi

  local status=0
  for p in "$@"; do
    adopt_path "$p" || status=1
  done

  log "Done. Review with:  git -C \"$REPO_DIR\" status"
  log "Then commit + push when ready."
  exit "$status"
}

main "$@"

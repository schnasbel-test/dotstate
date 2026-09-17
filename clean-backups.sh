#!/usr/bin/env bash
# Reviews (and optionally deletes) ~/.dotstate-backup-<timestamp> dirs left
# behind by install.sh/adopt.sh whenever they found a real file where a
# symlink was about to go.
#
# Usage: ./clean-backups.sh [--older-than DAYS] [--yes]
#
# Default: dry run, only reports what it would do. A backup dir is only
# ever proposed for deletion if EVERY file inside it is byte-identical to
# what the repo has at that path right now - i.e. it was genuinely
# superseded and re-adopting it would be a no-op. Anything that differs
# (local edits that never made it into the repo) or no longer has a
# matching path in the repo is left alone and flagged for manual review -
# this script never guesses on your behalf.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="$(hostname)"
OLDER_THAN_DAYS=7
DO_DELETE=0

log() { echo -e "\033[1;34m==>\033[0m $*"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --older-than) OLDER_THAN_DAYS="$2"; shift 2 ;;
    --yes) DO_DELETE=1; shift ;;
    *) echo "Usage: $0 [--older-than DAYS] [--yes]" >&2; exit 1 ;;
  esac
done

repo_path_for() {
  # home.$HOST/ takes precedence, same as install.sh's link order.
  local rel="$1"
  if [ -f "$REPO_DIR/home.$HOST/$rel" ]; then
    echo "$REPO_DIR/home.$HOST/$rel"
  elif [ -f "$REPO_DIR/home/$rel" ]; then
    echo "$REPO_DIR/home/$rel"
  fi
}

cutoff=$(date -d "-${OLDER_THAN_DAYS} days" +%s)

shopt -s nullglob
backups=("$HOME"/.dotstate-backup-*)
shopt -u nullglob

if [ "${#backups[@]}" -eq 0 ]; then
  log "No ~/.dotstate-backup-* directories found."
  exit 0
fi

safe_dirs=()

for dir in "${backups[@]}"; do
  [ -d "$dir" ] || continue
  base="$(basename "$dir")"
  ts="${base#.dotstate-backup-}"
  dir_epoch="$(date -d "${ts:0:8} ${ts:9:2}:${ts:11:2}:${ts:13:2}" +%s 2>/dev/null || echo 0)"

  if [ "$dir_epoch" -gt "$cutoff" ]; then
    log "Skipping $base (younger than $OLDER_THAN_DAYS days)"
    continue
  fi

  all_safe=1
  diffs=()
  while IFS= read -r -d '' f; do
    rel="${f#"$dir"/}"
    repo_file="$(repo_path_for "$rel")"
    if [ -z "$repo_file" ]; then
      all_safe=0
      diffs+=("$rel (not tracked in the repo)")
    elif ! cmp -s "$f" "$repo_file"; then
      all_safe=0
      diffs+=("$rel (content differs)")
    fi
  done < <(find "$dir" -type f -print0)

  if [ "$all_safe" = "1" ]; then
    safe_dirs+=("$dir")
  else
    log "NEEDS REVIEW: $base - differs from (or has no match in) the repo:"
    printf '    %s\n' "${diffs[@]}"
  fi
done

if [ "${#safe_dirs[@]}" -eq 0 ]; then
  log "Nothing safe to delete."
  exit 0
fi

log "Safe to delete (every file byte-identical to what's in the repo now):"
printf '    %s\n' "${safe_dirs[@]}"

if [ "$DO_DELETE" = "1" ]; then
  rm -rf -- "${safe_dirs[@]}"
  log "Deleted ${#safe_dirs[@]} backup dir(s)."
else
  echo
  log "Dry run - nothing deleted. Re-run with --yes to actually delete the safe ones above."
fi

#!/usr/bin/env bash
# Automatically commit and push any changes to this dotfiles repo.
#
# Usage: ./backup.sh
#
# Run periodically by the dotstate-backup systemd user timer (see
# systemd/dotstate-backup.{service.tmpl,timer}, installed by install.sh).
# Safe to also run manually or via cron.
#
# Also writes a small status file (see $STATUS_FILE below) that the
# Dotstate bar-widget plugin polls to show sync state without shelling
# out to git itself.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

STATUS_DIR="$HOME/.cache/dotstate"
STATUS_FILE="$STATUS_DIR/status.json"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

write_status() {
  local ok="$1" dirty="$2" error="$3"
  mkdir -p "$STATUS_DIR"
  # Minimal hand-rolled JSON - keep this dependency-free (no jq requirement)
  # since it must work on a fresh Omarchy install before any adoption.
  local escaped_error
  escaped_error="$(printf '%s' "$error" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  cat > "$STATUS_FILE" <<EOF
{
  "lastRun": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "ok": $ok,
  "dirty": $dirty,
  "error": "$escaped_error"
}
EOF
}

finish() {
  local code=$?
  local dirty=false
  [ -n "$(git status --porcelain 2>/dev/null)" ] && dirty=true

  if [ "$code" -eq 0 ]; then
    write_status true "$dirty" ""
    return
  fi

  log "ERROR: backup.sh failed (exit $code), see journalctl --user -u dotstate-backup.service"
  write_status false "$dirty" "backup.sh failed (exit $code)"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send --urgency=critical --app-name="Dotstate" \
      "Dotfiles sync failed" \
      "Exit code $code - check: journalctl --user -u dotstate-backup.service" \
      || true
  fi
}
trap finish EXIT

# Runs right after login (dotstate-backup.timer's OnStartupSec) or on demand,
# both of which can race the network coming up - give it a moment rather
# than failing the whole run over a pull/push that would've worked 10s later.
if command -v nm-online >/dev/null 2>&1; then
  nm-online -q --timeout=15 || log "Network not up after 15s, trying anyway"
fi

if [ -n "$(git status --porcelain)" ]; then
  log "Changes detected, committing"
  git add -A
  git commit -m "Auto backup: $(date '+%Y-%m-%d %H:%M:%S')"
else
  log "No local changes"
fi

log "Pulling latest changes from origin (rebase)"
if ! git pull --rebase; then
  log "ERROR: rebase failed, resolve conflicts manually in $REPO_DIR"
  exit 1
fi

# shellcheck disable=SC1083 # @{u} is git's upstream-branch syntax, not a shell brace expansion
if [ -n "$(git log @{u}..HEAD 2>/dev/null)" ]; then
  log "Pushing to origin"
  git push
else
  log "Nothing to push"
fi

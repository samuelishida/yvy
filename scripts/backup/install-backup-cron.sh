#!/usr/bin/env bash
# install-backup-cron.sh — Installs a desktop crontab entry that runs
# pull-prod-backups.sh on a schedule. Replaces any previous entry (idempotent).
#
#   CRON_TIME="17 3 * * 0"   # weekly, Sunday 03:17 (default) — adjust as you like
#   bash scripts/backup/install-backup-cron.sh
#
# To remove later:  crontab -e   and delete the line containing pull-prod-backups.sh
# Alternative to cron (if your desktop uses systemd): a user timer with
# Persistent=true would catch up after the machine was off — cron just skips.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PULLER="$SCRIPT_DIR/pull-prod-backups.sh"
CRON_TIME="${CRON_TIME:-17 3 * * 0}"
LOG_DIR="${LOG_DIR:-$HOME/yvy-backups}"

mkdir -p "$LOG_DIR"

LINE="$CRON_TIME PATH=/usr/local/bin:/usr/bin:/bin /bin/bash '$PULLER' >> '$LOG_DIR/cron.log' 2>&1"

# Replace any existing entry for this puller (idempotent, keeps schedule fresh).
CURRENT="$(crontab -l 2>/dev/null || true)"
CURRENT="$(printf '%s\n' "$CURRENT" | grep -vF "$PULLER" || true)"
{ printf '%s\n' "$CURRENT"; echo "$LINE"; } | crontab -
echo "Cron entry set:"
echo "  $LINE"

echo
echo "Backups land in $LOG_DIR/weekly (last 2 kept ≈ 2 weeks)."
echo "Log: $LOG_DIR/backup.log | Cron runs: $LOG_DIR/cron.log"
echo "Manual run: bash '$PULLER'"

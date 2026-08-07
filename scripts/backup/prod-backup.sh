#!/usr/bin/env bash
# prod-backup.sh — Creates a consistent gzipped SQLite snapshot of the Yvy DB.
#
# Intended to run ON the prod VM, either directly:
#   bash scripts/prod-backup.sh
# or piped over SSH from the desktop puller (always runs the current repo copy):
#   ssh -i ~/.ssh/oci_yvy ubuntu@$VM_IP \
#       "PROD_DB_PATH=... PROD_BACKUP_DIR=... bash -s" < scripts/prod-backup.sh
#
# Prints ONLY the created archive's absolute path to stdout (the desktop
# puller parses that last line). All progress/log messages go to stderr.
set -euo pipefail

PROD_DB_PATH="${PROD_DB_PATH:-/opt/yvy/backend-lua/data/yvy.db}"
PROD_BACKUP_DIR="${PROD_BACKUP_DIR:-/opt/yvy/backups}"
PROD_RETENTION="${PROD_RETENTION:-5}"

if [[ ! -f "$PROD_DB_PATH" ]]; then
  echo "ERROR: DB not found at $PROD_DB_PATH" >&2
  exit 1
fi

mkdir -p "$PROD_BACKUP_DIR"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
ARCHIVE="$PROD_BACKUP_DIR/yvy_${TIMESTAMP}.sqlite3.gz"
TMP_DB="$PROD_BACKUP_DIR/.yvy_tmp_${TIMESTAMP}.db"

echo "[prod-backup] snapshotting $PROD_DB_PATH" >&2
if command -v sqlite3 >/dev/null 2>&1; then
  # Online backup API: consistent snapshot even with a live WAL.
  sqlite3 "$PROD_DB_PATH" ".backup '$TMP_DB'"
else
  echo "[prod-backup] WARN: sqlite3 not found, falling back to cp (may be inconsistent with WAL)" >&2
  cp "$PROD_DB_PATH" "$TMP_DB"
fi

gzip -c "$TMP_DB" > "$ARCHIVE"
rm -f "$TMP_DB"

# Full-decompress CRC validation of the archive itself.
gzip -t "$ARCHIVE"
SIZE="$(du -h "$ARCHIVE" | cut -f1)"
echo "[prod-backup] ok: $ARCHIVE ($SIZE)" >&2

# Prune old staging archives on prod (keep the newest $PROD_RETENTION).
ls -1t "$PROD_BACKUP_DIR"/yvy_*.sqlite3.gz 2>/dev/null \
  | tail -n +$((PROD_RETENTION + 1)) \
  | xargs -r rm -f 2>/dev/null || true

echo "$ARCHIVE"

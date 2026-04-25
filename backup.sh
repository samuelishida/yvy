#!/bin/sh
# Backup script for Yvy SQLite

set -eu

BACKUP_DIR="${BACKUP_DIR:-./sqlite_backups}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
SQLITE_PATH="${SQLITE_PATH:-./backend/data/yvy.db}"

if [ ! -f "$SQLITE_PATH" ]; then
  echo "SQLite database not found at: $SQLITE_PATH" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_FILE="$BACKUP_DIR/yvy_${TIMESTAMP}.sqlite3"
ARCHIVE_FILE="$BACKUP_FILE.gz"

echo "Creating SQLite backup from $SQLITE_PATH..."

if command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$SQLITE_PATH" ".backup '$BACKUP_FILE'"
else
  cp "$SQLITE_PATH" "$BACKUP_FILE"
fi

gzip -f "$BACKUP_FILE"

echo "Backup created: $ARCHIVE_FILE"
echo "Cleaning up backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -name "yvy_*.sqlite3.gz" -type f -mtime +"$RETENTION_DAYS" -delete
echo "Cleanup complete."

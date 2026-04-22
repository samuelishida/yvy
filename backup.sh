#!/bin/sh
# Backup script for Yvy MongoDB
# Prefers docker-compose exec, with a local mongodump fallback when Docker is unavailable.

set -eu

BACKUP_DIR="${BACKUP_DIR:-./mongo_backups}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
DB_NAME="${MONGO_DATABASE:-terrabrasilis_data}"
USERNAME="${MONGO_ROOT_USERNAME:-root}"
PASSWORD="${MONGO_ROOT_PASSWORD:-}"
MONGO_HOST="${MONGO_HOST:-localhost}"
MONGO_PORT="${MONGO_PORT:-27017}"

if [ -z "$PASSWORD" ]; then
  echo "MONGO_ROOT_PASSWORD must be set before running backups." >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_FILE="$BACKUP_DIR/backup_$TIMESTAMP.gz"

echo "Creating MongoDB backup at $BACKUP_FILE..."

if command -v docker-compose >/dev/null 2>&1; then
  docker-compose exec -T mongo sh -lc \
    "mongodump --authenticationDatabase admin --username \"$USERNAME\" --password \"$PASSWORD\" --db \"$DB_NAME\" --archive --gzip" \
    > "$BACKUP_FILE"
elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose exec -T mongo sh -lc \
    "mongodump --authenticationDatabase admin --username \"$USERNAME\" --password \"$PASSWORD\" --db \"$DB_NAME\" --archive --gzip" \
    > "$BACKUP_FILE"
elif command -v mongodump >/dev/null 2>&1; then
  mongodump \
    --host "$MONGO_HOST" \
    --port "$MONGO_PORT" \
    --authenticationDatabase admin \
    --username "$USERNAME" \
    --password "$PASSWORD" \
    --db "$DB_NAME" \
    --archive="$BACKUP_FILE" \
    --gzip
else
  echo "Neither docker compose nor mongodump is available on PATH." >&2
  exit 1
fi

echo "Backup created: $BACKUP_FILE"
echo "Cleaning up backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -name "backup_*.gz" -type f -mtime +"$RETENTION_DAYS" -delete
echo "Cleanup complete."

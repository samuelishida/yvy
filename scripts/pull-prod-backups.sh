#!/usr/bin/env bash
# pull-prod-backups.sh — Pulls a consistent Yvy DB snapshot from the prod VM
# down to this desktop. Keeps only the most recent WEEKLY_RETENTION backups
# (default 2, i.e. ~2 weeks) — nothing older is retained.
#
#   VM IP resolution order:  $PROD_VM_IP  >  terraform output  >  $DEFAULT_PROD_IP
#   SSH key:  $SSH_KEY  >  ~/.ssh/oci_yvy  >  ~/.ssh/id_rsa  >  ~/.ssh/id_ed25519
#
# All settings can be overridden via env vars (also useful in cron).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Config (env-overridable) ─────────────────────────────────────────────
DEFAULT_PROD_IP="${DEFAULT_PROD_IP:-137.131.152.151}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-}"
PROD_VM_IP="${PROD_VM_IP:-}"
PROD_DB_PATH="${PROD_DB_PATH:-/opt/yvy/backend-lua/data/yvy.db}"
PROD_BACKUP_DIR="${PROD_BACKUP_DIR:-/opt/yvy/backups}"
PROD_RETENTION="${PROD_RETENTION:-5}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$HOME/yvy-backups}"
WEEKLY_RETENTION="${WEEKLY_RETENTION:-2}"   # keep the last N backups (weekly → ~2 weeks)
VERIFY_INTEGRITY="${VERIFY_INTEGRITY:-0}"   # set 1 to run sqlite3 quick_check (slow on ~500MB)

WEEKLY_DIR="$LOCAL_BACKUP_DIR/weekly"
LOG_FILE="$LOCAL_BACKUP_DIR/backup.log"

mkdir -p "$WEEKLY_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# ── Resolve SSH key ──────────────────────────────────────────────────────
if [[ -z "$SSH_KEY" ]]; then
  for k in "$HOME/.ssh/oci_yvy" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ed25519"; do
    if [[ -f "$k" ]]; then SSH_KEY="$k"; break; fi
  done
fi
if [[ ! -f "$SSH_KEY" ]]; then
  log "ERROR: no SSH key found (set SSH_KEY to a private key path)"
  exit 1
fi

# ── Resolve VM IP ────────────────────────────────────────────────────────
if [[ -z "$PROD_VM_IP" ]] && command -v terraform >/dev/null 2>&1; then
  PROD_VM_IP="$(terraform -chdir="$PROJECT_DIR/infra" output -raw instance_public_ip 2>/dev/null || true)"
fi
if [[ -z "$PROD_VM_IP" ]]; then
  PROD_VM_IP="$DEFAULT_PROD_IP"
fi
log "Backing up $SSH_USER@$PROD_VM_IP -> $WEEKLY_DIR/"

SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

# ── 1. Create the snapshot on prod (runs the repo's prod-backup.sh remotely) ─
REMOTE_OUT="$(ssh "${SSH_OPTS[@]}" "$SSH_USER@$PROD_VM_IP" \
  "PROD_DB_PATH='$PROD_DB_PATH' PROD_BACKUP_DIR='$PROD_BACKUP_DIR' PROD_RETENTION='$PROD_RETENTION' bash -s" \
  < "$SCRIPT_DIR/prod-backup.sh" 2>>"$LOG_FILE" || true)"

REMOTE_ARCHIVE="$(printf '%s\n' "$REMOTE_OUT" | tail -n1 | tr -d '\r')"
if [[ "$REMOTE_ARCHIVE" != *.sqlite3.gz ]]; then
  log "ERROR: failed to create remote backup. SSH output:"
  printf '%s\n' "$REMOTE_OUT" | sed 's/^/  /' | tee -a "$LOG_FILE"
  exit 1
fi

# ── 2. Download ──────────────────────────────────────────────────────────
BASE="$(basename "$REMOTE_ARCHIVE")"
log "Downloading $BASE ($(du -h "$REMOTE_ARCHIVE" 2>/dev/null | cut -f1)) ..."
scp "${SSH_OPTS[@]}" "$SSH_USER@$PROD_VM_IP:${REMOTE_ARCHIVE}" "$WEEKLY_DIR/$BASE.tmp" 2>>"$LOG_FILE"
mv "$WEEKLY_DIR/$BASE.tmp" "$WEEKLY_DIR/$BASE"

# ── 3. Verify ────────────────────────────────────────────────────────────
gunzip -t "$WEEKLY_DIR/$BASE" \
  && log "Verified archive: $WEEKLY_DIR/$BASE ($(du -h "$WEEKLY_DIR/$BASE" | cut -f1))"

if [[ "$VERIFY_INTEGRITY" == "1" ]]; then
  if ! command -v sqlite3 >/dev/null 2>&1; then
    log "WARN: VERIFY_INTEGRITY=1 but sqlite3 CLI not installed locally; skipping deep check (gunzip -t already validated the archive)."
  else
    TMP_DB="$(mktemp)"
    gunzip -c "$WEEKLY_DIR/$BASE" > "$TMP_DB"
    if sqlite3 "$TMP_DB" "PRAGMA quick_check;" | grep -qi "ok"; then
      log "Integrity quick_check: OK"
    else
      log "ERROR: integrity quick_check FAILED for $BASE"
    fi
    rm -f "$TMP_DB"
  fi
fi

# ── 4. Retention (keep only the most recent $WEEKLY_RETENTION) ───────────
prune() { # $1 = dir, $2 = keep count
  ls -1t "$1"/yvy_*.sqlite3.gz 2>/dev/null | tail -n +$(($2 + 1)) | xargs -r rm -f 2>/dev/null || true
}
prune "$WEEKLY_DIR" "$WEEKLY_RETENTION"

log "Done."

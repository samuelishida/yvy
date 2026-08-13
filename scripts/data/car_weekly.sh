#!/usr/bin/env bash
# car_weekly.sh — dev-machine weekly cron wrapper for the full CAR pipeline.
#
# Runs the entire CAR chain on the DEV machine (the 7GB car.db + warm jobs
# physically cannot run on the 1GB prod VM), then scp's car.db + tiles_car.db
# to prod via an ATOMIC swap (car.db is WAL and mutated in place, so a naive
# overwrite is unsafe), and invalidates prod Redis car:* keys.
#
# Chain (plan: ingestion-automation, Inc 5):
#   1. download_car_wfs.py --all  → data/car/<UF>.json (27 UFs)
#   2. import_car.lua             → car.db (WAL, mutated in place)
#   3. warm protected + prodes     → precompute tables (parallel via clone worker)
#   4. merge prodes + protected    → validate version_key
#   5. render_car_tiles.py         → tiles_car.db
#   6. scp car.db + tiles_car.db to VM via temp name → integrity_check → atomic mv
#   7. invalidate prod Redis car:* keys (warm tools invalidate DEV Redis only)
#
# Uso: bash scripts/data/car_weekly.sh [--vm-ip IP] [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BACKEND_DIR="$PROJECT_DIR/backend-lua"

VM_IP=""
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-ip) VM_IP="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

run() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

echo "=== Yvy car_weekly ($(date -u +%FT%TZ)) ==="

# ── 0. Status marker helper (best-effort) ────────────────────────────────────
# shellcheck source=scripts/data/status_marker.sh
source "$SCRIPT_DIR/status_marker.sh" 2>/dev/null || true
STATUS_RESULT="fail"

# ── 1. Resolve VM_IP ─────────────────────────────────────────────────────────
if [[ -z "$VM_IP" ]]; then
  VM_IP="$(grep -E '^(VM_IP|PUBLIC_IP|INSTANCE_IP)=' "$PROJECT_DIR/.env" 2>/dev/null \
    | head -1 | cut -d= -f2- || true)"
fi
if [[ -z "$VM_IP" ]]; then
  echo "ERROR: VM_IP not provided (use --vm-ip IP or set VM_IP/PUBLIC_IP in .env)" >&2
  exit 1
fi
echo "VM_IP: $VM_IP"

# ── 2. Chave SSH (padrão deploy-local.sh) ───────────────────────────────────
SSH_KEY=""
for key in "$HOME/.ssh/oci_yvy" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ed25519"; do
  if [[ -f "$key" ]]; then
    SSH_KEY="$key"
    break
  fi
done
if [[ -z "$SSH_KEY" ]]; then
  echo "ERROR: no SSH key found in ~/.ssh/{oci_yvy,id_rsa,id_ed25519}" >&2
  exit 1
fi

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
VM_USER="ubuntu"
CAR_REMOTE_DIR="/opt/yvy/backend-lua/data/car"
TILES_REMOTE_DIR="/opt/yvy/backend-lua/data"
CAR_DB="$PROJECT_DIR/backend-lua/data/car/car.db"
TILES_DB="$PROJECT_DIR/backend-lua/data/tiles_car.db"

# ── 3. Python (venv se presente, senão system python3) ──────────────────────
if [ -x "$PROJECT_DIR/.venv/bin/python3" ]; then
    PY="$PROJECT_DIR/.venv/bin/python3"
else
    PY="python3"
fi

# ── 4. Download 27 UFs (idempotent per-UF; slow, hours) ─────────────────────
run "$PY" "$PROJECT_DIR/scripts/data/download_car_wfs.py" --all

# ── 5. Import → car.db (WAL, mutated in place) ─────────────────────────────
( cd "$BACKEND_DIR" && run lua5.1 tools/import_car.lua )

# ── 6. Warm protected + prodes (parallel per-UF via clone worker) ──────────
# The clone worker clones car.db per-UF, warms prodes in parallel, merges back,
# and validates version_key. It stops the backend if systemd is present (dev has
# no systemd service, so it's a no-op there).
# Warm/merge are OPTIONAL steps (plan): a failure degrades to a warning and does
# NOT abort the chain — car.db is still valid (just without fresh precompute),
# and prod keeps serving the previous precompute until the next successful run.
WORKDIR="${CAR_WORKDIR:-/tmp/yvy-car-weekly-workers}"
run bash "$BACKEND_DIR/tools/clone_car_prodes_worker.sh" "$CAR_DB" "$WORKDIR" "${CAR_WORKERS:-8}" \
  || echo "WARN: CAR×PRODES warm/merge failed — deploying car.db without fresh prodes precompute"

# Warm CAR × UC/TI (protected overlap) — sequential over all 27 UFs, writes
# directly to car.db (no clones). Runs after the prodes warm so both precompute
# tables are fresh against the same imported car.db.
( cd "$BACKEND_DIR" && run lua5.1 tools/warm_car_protected_overlap.lua ) \
  || echo "WARN: CAR×UC/TI warm failed — deploying car.db without fresh protected-overlap precompute"

# ── 7. Render tiles → tiles_car.db ──────────────────────────────────────────
run "$PY" "$PROJECT_DIR/scripts/data/render_car_tiles.py" --car-db "$CAR_DB" --out "$TILES_DB"

# ── 8. scp car.db + tiles_car.db to VM via ATOMIC swap ─────────────────────
# car.db is WAL and mutated in place, so "prod keeps the previous copy on
# failure" is only sound if the swap is atomic. Sequence on the VM:
#   scp to .new → integrity_check → keep .prev → mv (atomic rename) → drop .prev
run ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "mkdir -p $CAR_REMOTE_DIR $TILES_REMOTE_DIR"
run scp -i "$SSH_KEY" "$CAR_DB" "$VM_USER@$VM_IP:$CAR_REMOTE_DIR/car.db.new"
run scp -i "$SSH_KEY" "$TILES_DB" "$VM_USER@$VM_IP:$TILES_REMOTE_DIR/tiles_car.db.new"

if [[ "$DRY_RUN" == true ]]; then
  echo "[dry-run] atomic swap + Redis invalidation on VM"
else
  # integrity_check on the new car.db before it goes live
  ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" \
    "sqlite3 $CAR_REMOTE_DIR/car.db.new 'PRAGMA integrity_check;' | grep -q '^ok$' \
     || { echo 'ERROR: integrity_check failed on car.db.new' >&2; exit 1; }"
  # keep current as .prev, then atomic rename
  ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" \
    "if [ -f $CAR_REMOTE_DIR/car.db ]; then mv -f $CAR_REMOTE_DIR/car.db $CAR_REMOTE_DIR/car.db.prev; fi; \
     mv -f $CAR_REMOTE_DIR/car.db.new $CAR_REMOTE_DIR/car.db; \
     if [ -f $TILES_REMOTE_DIR/tiles_car.db ]; then mv -f $TILES_REMOTE_DIR/tiles_car.db $TILES_REMOTE_DIR/tiles_car.db.prev; fi; \
     mv -f $TILES_REMOTE_DIR/tiles_car.db.new $TILES_REMOTE_DIR/tiles_car.db"
  # drop the previous copy only after the new DB is verified live
  ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" \
    "rm -f $CAR_REMOTE_DIR/car.db.prev $TILES_REMOTE_DIR/tiles_car.db.prev"
  # ── 9. Invalidate prod Redis car:* keys ───────────────────────────────────
  # The warm tools (warm_car_prodes.lua / warm_car_protected_overlap.lua)
  # invalidate DEV Redis only (REDIS_URL default 127.0.0.1). Prod holds stale
  # car:prodes:* / car:protected:* cache (24h TTL) until cleared here.
  ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" \
    "redis-cli --scan --pattern 'car:*' | xargs -r redis-cli del >/dev/null 2>&1 || true"
  echo "OK: car.db + tiles_car.db swapped atomically; prod Redis car:* invalidated"
fi

# ── 10. Verificação ──────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == true ]]; then
  echo "[dry-run] verify remote DB sizes"
else
  CAR_SIZE="$(ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" \
    "stat -c%s $CAR_REMOTE_DIR/car.db 2>/dev/null || echo 0")"
  TILES_SIZE="$(ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" \
    "stat -c%s $TILES_REMOTE_DIR/tiles_car.db 2>/dev/null || echo 0")"
  echo "OK: remote car.db is $CAR_SIZE bytes; tiles_car.db is $TILES_SIZE bytes"
  if [[ "$CAR_SIZE" -eq 0 || "$TILES_SIZE" -eq 0 ]]; then
    echo "WARN: remote DB missing or empty — check scp" >&2
  else
    STATUS_RESULT="ok"
  fi
fi

write_status "car" "$STATUS_RESULT" 2>/dev/null || true

echo "=== car_weekly done ==="

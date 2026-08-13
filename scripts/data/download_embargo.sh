#!/usr/bin/env bash
# download_embargo.sh — wrapper bash do download de embargos IBAMA
# (plan: car-risk-expansion, Inc 2; ingestion-automation, Inc 2). Roda via
# systemd timer semanal.
#
# Chain: baixa termos de embargo do CKAN Ibama → embargo.db (swap atômico).
# Idempotente (o script Python decide via mtime; --force força).
#
# Embargo's spatial CAR resolution is its ONLY path (no explicit CAR column),
# so a missing car.db must FAIL LOUDLY, not WARN-and-drop (review finding).
# Uses the project Python venv if present, else system python3 (deter_daily.sh
# pattern).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Absolute CAR_DB_PATH: the script defaults to a *relative* path that resolves
# wrong from the unit's cwd, silently skipping spatial resolution. The service
# exports it; fall back to the absolute prod path here for manual runs.
CAR_DB_PATH="${CAR_DB_PATH:-$PROJECT_DIR/backend-lua/data/car/car.db}"
export CAR_DB_PATH

if [ -x "$PROJECT_DIR/.venv/bin/python3" ]; then
    PY="$PROJECT_DIR/.venv/bin/python3"
else
    PY="python3"
fi

echo "=== Embargo download ($(date -u +%FT%TZ)) ==="

# Status marker helper (best-effort).
# shellcheck source=scripts/data/status_marker.sh
source "$SCRIPT_DIR/status_marker.sh" 2>/dev/null || true
STATUS_RESULT="fail"

# Hard guard: spatial resolve is the only path for embargo.
if [[ ! -f "$CAR_DB_PATH" ]]; then
    echo "ERROR: car.db missing at $CAR_DB_PATH — embargo spatial resolve impossible" >&2
    write_status "embargo" "fail" 2>/dev/null || true
    exit 1
fi

if command -v "$PY" >/dev/null 2>&1; then
    ( cd "$PROJECT_DIR" && "$PY" scripts/data/download_embargo.py --out "$PROJECT_DIR/backend-lua/data/embargo/embargo.db" )
    STATUS_RESULT="ok"
else
    echo "  (python3 not available — skipping embargo download)"
    write_status "embargo" "fail" 2>/dev/null || true
    exit 1
fi

write_status "embargo" "$STATUS_RESULT" 2>/dev/null || true

echo "=== Embargo download done ==="

#!/usr/bin/env bash
# deter_daily.sh — DETER daily pipeline (plan: terrabrasilis-integration, Inc 2/3)
#
# Chain: download DETER polygons → backfill/rollup deter_alerts → (Inc 3)
# cross DETER × CAR → deter_car_alerts. Run via systemd timer/cron daily ~04:00.
#
# Uses the project Python venv (scripts/dev/setup-python-env.sh) if present, else
# falls back to system python3.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DB="${SQLITE_PATH:-$PROJECT_DIR/backend-lua/data/yvy.db}"

if [ -x "$PROJECT_DIR/.venv/bin/python3" ]; then
    PY="$PROJECT_DIR/.venv/bin/python3"
else
    PY="python3"
fi

echo "=== DETER daily pipeline ($(date -u +%FT%TZ)) ==="

# 1. Download today's DETER polygons (idempotent per view_date)
"$PY" "$SCRIPT_DIR/download_deter_wfs.py" --days 2 --db "$DB"

# 2. Roll up recent polygons into deter_alerts (polygon-derived wins)
"$PY" "$SCRIPT_DIR/backfill_deter_alerts.py" --rollup --days 3 --db "$DB"

# 3. (Inc 3) Cross DETER × CAR → deter_car_alerts
CROSS="$SCRIPT_DIR/cross_deter_car.py"
if [ -f "$CROSS" ]; then
    "$PY" "$CROSS" --db "$DB" --car-db "$PROJECT_DIR/backend-lua/data/car/car.db"
else
    echo "  (cross_deter_car.py not present yet — skipping CAR cross)"
fi

# 4. (plan: protected-area-crossing, Inc 3/4) DETER × UC/TI → alerts:deter_protected
# Scan Lua detached (mesmo env do backend). Probe o interpreter E as rocks — um
# box novo com lua5.1 mas sem lsqlite3/cjson degrada para warning, nunca aborta
# a cadeia noturna inteira (set -eu).
LUA="${LUA:-lua5.1}"
if command -v "$LUA" >/dev/null 2>&1 \
   && "$LUA" -e 'require("lsqlite3"); require("cjson")' >/dev/null 2>&1; then
    ( cd "$PROJECT_DIR/backend-lua" && SQLITE_PATH="$DB" "$LUA" tools/deter_protected_alerts.lua 30 ) \
        || echo "  (deter_protected_alerts.lua failed — see journal; continuing)"
else
    echo "  (lua5.1 + lsqlite3/cjson not available — skipping DETER×UC/TI alerts)"
fi

echo "=== DETER pipeline done ==="

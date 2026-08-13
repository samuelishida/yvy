#!/usr/bin/env bash
# scan_supplier_alerts.sh — wrapper bash do scan de alertas de fornecedores
# (plan: risk-intelligence, Inc 6). Roda via systemd timer diário.
#
# Chain: cruza alertas MapBiomas recentes × fornecedores monitorados → grava
# alertas em Redis + dispara webhook. Idempotente (lock Redis setnx).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

LUA="${LUA:-lua5.1}"
DAYS="${RISK_MONITOR_DAYS:-30}"

echo "=== Risk supplier monitor scan ($(date -u +%FT%TZ)) ==="

if command -v "$LUA" >/dev/null 2>&1 \
   && "$LUA" -e 'require("lsqlite3"); require("cjson")' >/dev/null 2>&1; then
    ( cd "$PROJECT_DIR/backend-lua" && "$LUA" tools/scan_supplier_alerts.lua "$DAYS" ) \
        || echo "  (scan_supplier_alerts.lua failed — see journal; continuing)"
else
    echo "  (lua5.1 + lsqlite3/cjson not available — skipping supplier scan)"
fi

echo "=== Risk supplier monitor scan done ==="

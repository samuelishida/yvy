#!/usr/bin/env bash
# run-lua.sh — Run Yvy Lua backend (Ubuntu/Linux)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR/backend-lua"

# Load environment
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a; source "$PROJECT_DIR/.env"; set +a
fi

if [ -z "${SQLITE_PATH:-}" ] || [[ "$SQLITE_PATH" == *"/backend/data/yvy.db" ]] || [[ "$SQLITE_PATH" == *"\\backend\\data\\yvy.db" ]]; then
    export SQLITE_PATH="$PROJECT_DIR/backend-lua/data/yvy.db"
fi
export PORT="${PORT:-5000}"
export AUTH_REQUIRED="${AUTH_REQUIRED:-0}"
export LOG_LEVEL="${LOG_LEVEL:-INFO}"

echo "=== Yvy Lua Backend ==="
echo "Port: $PORT"
echo "SQLite: $SQLITE_PATH"

exec lua main.lua

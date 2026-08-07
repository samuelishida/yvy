#!/usr/bin/env bash
# run-c-frontend.sh — Build (if needed) and run the C frontend server on Linux/macOS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BACKEND_LUA_DIR="$PROJECT_DIR/backend-lua"
EXE="$BACKEND_LUA_DIR/yvy-server"

PORT="${PORT:-5001}"
BACKEND_URL="${BACKEND_URL:-http://127.0.0.1:5000}"
SKIP_BUILD=0
for arg in "$@"; do
    [[ "$arg" == "--skip-build" ]] && SKIP_BUILD=1
done

# ── Build ──────────────────────────────────────────────────────────────────────

if [[ "$SKIP_BUILD" -eq 0 ]] || [[ ! -x "$EXE" ]]; then
    if ! command -v gcc >/dev/null 2>&1; then
        echo "gcc not found. Install build-essential (apt) or gcc (brew)." >&2
        exit 1
    fi
    echo "Building C frontend server..."
    cd "$BACKEND_LUA_DIR"
    make clean
    make
    echo "Build complete: $EXE"
fi

# ── Load env ───────────────────────────────────────────────────────────────────

if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.env"
    set +a
fi

# Extract host from BACKEND_URL (strip scheme and port)
BACKEND_HOST="${BACKEND_URL#http://}"
BACKEND_HOST="${BACKEND_HOST#https://}"
BACKEND_HOST="${BACKEND_HOST%%:*}"
BACKEND_HOST="${BACKEND_HOST%%/*}"

API_KEY="${API_KEY:-}"
STATIC_DIR="${STATIC_DIR:-$PROJECT_DIR/frontend/build}"

# ── Run ────────────────────────────────────────────────────────────────────────

echo "=== Yvy C Frontend Server ==="
echo "Port:    $PORT"
echo "Backend: $BACKEND_HOST:5000"
echo "Static:  $STATIC_DIR"

cd "$BACKEND_LUA_DIR"
exec "$EXE" \
    --port "$PORT" \
    --backend "$BACKEND_HOST" \
    --static "$STATIC_DIR" \
    --api-key "$API_KEY"

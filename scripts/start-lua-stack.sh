#!/usr/bin/env bash
# start-lua-stack.sh — Start Lua backend and C frontend in background on Linux/macOS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RUNTIME_DIR="$PROJECT_DIR/.runtime/lua-stack"

DEV_FRONTEND=0
SKIP_FRONTEND_BUILD=0
for arg in "$@"; do
    [[ "$arg" == "--dev-frontend" ]]        && DEV_FRONTEND=1
    [[ "$arg" == "--skip-frontend-build" ]] && SKIP_FRONTEND_BUILD=1
done

wait_for_port() {
    local port="$1" pid="$2" timeout="${3:-30}"
    local deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        if ss -tlnp "sport = :$port" 2>/dev/null | grep -q ":$port"; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

log_tail() {
    local path="$1"
    [ -f "$path" ] && tail -20 "$path" || true
}

mkdir -p "$RUNTIME_DIR"

"$SCRIPT_DIR/stop-lua-stack.sh"

if (( ! SKIP_FRONTEND_BUILD )); then
    echo "Building frontend..."
    BUILD_LOG="$RUNTIME_DIR/build.log"
    npm --prefix "$PROJECT_DIR/frontend" run build > "$BUILD_LOG" 2>&1 \
        || { echo "Frontend build failed. Log:"; cat "$BUILD_LOG"; exit 1; }
    echo "Frontend build done."
else
    echo "Skipping frontend build (--skip-frontend-build)."
fi

BACKEND_OUT="$RUNTIME_DIR/backend.out.log"
BACKEND_ERR="$RUNTIME_DIR/backend.err.log"
FRONTEND_OUT="$RUNTIME_DIR/frontend.out.log"
FRONTEND_ERR="$RUNTIME_DIR/frontend.err.log"

rm -f "$BACKEND_OUT" "$BACKEND_ERR" "$FRONTEND_OUT" "$FRONTEND_ERR"

echo "Starting Lua backend..."
"$SCRIPT_DIR/run-lua.sh" > "$BACKEND_OUT" 2> "$BACKEND_ERR" &
BACKEND_PID=$!
echo "$BACKEND_PID" > "$RUNTIME_DIR/backend.pid"

if ! wait_for_port 5000 "$BACKEND_PID" 30; then
    echo "Lua backend did not start on port 5000."
    log_tail "$BACKEND_ERR"
    exit 1
fi

echo "Starting C frontend..."
C_SERVER="$PROJECT_DIR/backend-lua/yvy-server"

if [ -x "$C_SERVER" ]; then
    # Load .env for API_KEY
    [ -f "$PROJECT_DIR/.env" ] && set -a && source "$PROJECT_DIR/.env" && set +a || true
    "$C_SERVER" \
        --port 5001 \
        --backend 127.0.0.1 \
        --static "$PROJECT_DIR/frontend/build" \
        --api-key "${API_KEY:-}" \
        > "$FRONTEND_OUT" 2> "$FRONTEND_ERR" &
else
    # Binary missing — build and run via run-c-frontend.sh
    "$SCRIPT_DIR/run-c-frontend.sh" > "$FRONTEND_OUT" 2> "$FRONTEND_ERR" &
fi
FRONTEND_PID=$!
echo "$FRONTEND_PID" > "$RUNTIME_DIR/frontend.pid"

if ! wait_for_port 5001 "$FRONTEND_PID" 30; then
    echo "C frontend did not start on port 5001."
    log_tail "$FRONTEND_OUT"
    log_tail "$FRONTEND_ERR"
    kill "$BACKEND_PID" 2>/dev/null || true
    exit 1
fi

echo "Lua stack running."
echo "Backend PID:  $BACKEND_PID"
echo "Frontend PID: $FRONTEND_PID"
echo "Logs:         $RUNTIME_DIR"
echo ""
echo "Access the app at: http://localhost:5001/"
echo "Backend API at:    http://localhost:5000/api/"
echo ""
echo "Run ./stop-lua-stack.sh to stop."

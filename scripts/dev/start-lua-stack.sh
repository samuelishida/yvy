#!/usr/bin/env bash
# start-lua-stack.sh — Start Yvy Lua backend + C frontend.
# Verifies port bindability before each start to prevent "address already in use".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNTIME_DIR="$PROJECT_DIR/.runtime/lua-stack"

DEV_FRONTEND=0
SKIP_FRONTEND_BUILD=0
for arg in "$@"; do
    [[ "$arg" == "--dev-frontend" ]]        && DEV_FRONTEND=1
    [[ "$arg" == "--skip-frontend-build" ]] && SKIP_FRONTEND_BUILD=1
done

# Bindability check that treats TIME-WAIT entries as benign.
port_free() {
    local port="$1"
    if ss -tan "sport = :$port" 2>/dev/null | awk 'NR>1 && $1!="TIME-WAIT"' | grep -q .; then
        return 1
    fi
    python3 - "$port" <<'PY' >/dev/null 2>&1
import socket, sys
port = int(sys.argv[1])
for fam, addr in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
    s = socket.socket(fam, socket.SOCK_STREAM)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((addr, port))
    except OSError:
        sys.exit(1)
    finally:
        s.close()
sys.exit(0)
PY
    local rc=$?
    if [ $rc -eq 0 ]; then return 0; fi
    if ss -tan "sport = :$port" 2>/dev/null | awk 'NR>1 && $1!="TIME-WAIT"' | grep -q .; then
        return 1
    fi
    return 0
}

wait_port_free() {
    local port="$1" timeout="${2:-15}"
    local deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        port_free "$port" && return 0
        sleep 0.3
    done
    return 1
}

wait_for_port() {
    local port="$1" pid="$2" timeout="${3:-30}"
    local deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        if ss -tln "sport = :$port" 2>/dev/null | grep -q ":$port"; then
            return 0
        fi
        if lsof -i :"$port" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.3
    done
    return 1
}

log_tail() {
    local path="$1"
    [ -f "$path" ] && tail -20 "$path" || true
}

dump_port_holders() {
    local port="$1"
    ss -tanp "sport = :$port" 2>/dev/null | sed 's/^/  /' || true
    lsof -i :"$port" 2>/dev/null | sed 's/^/  /' || true
    fuser -n tcp "$port" 2>/dev/null | sed 's/^/  /' || true
}

mkdir -p "$RUNTIME_DIR"

"$SCRIPT_DIR/stop-lua-stack.sh"

# Authoritative bind-check that both ports are actually free
for port in 5000 5001; do
    if ! wait_port_free "$port" 15; then
        echo "ERROR: Port $port still not bindable after stop. Holders:" >&2
        dump_port_holders "$port" >&2
        echo "Run scripts/dev/stop-lua-stack.sh — if that still fails, try: sudo fuser -k -KILL -n tcp $port" >&2
        exit 1
    fi
done

# Grace period for kernel socket cleanup
sleep 0.5

if (( ! SKIP_FRONTEND_BUILD )); then
    echo "Building frontend..."
    BUILD_LOG="$RUNTIME_DIR/build.log"
    npm --prefix "$PROJECT_DIR/frontend" run build > "$BUILD_LOG" 2>&1 \
        || { echo "Frontend build failed. Log:"; cat "$BUILD_LOG"; exit 1; }
    echo "Frontend build done."
else
    echo "Skipping frontend build (--skip-frontend-build)."
fi

# Re-verify port 5000 right before launch — npm build may have taken seconds
# during which some process could grab the port. Catch that immediately.
if ! port_free 5000; then
    echo "ERROR: Port 5000 became occupied during build. Holders:" >&2
    dump_port_holders 5000 >&2
    echo "This usually means another process is auto-restarting the backend." >&2
    echo "Run scripts/dev/stop-lua-stack.sh and identify the parent." >&2
    exit 1
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
    echo "Processes on port 5000:"
    dump_port_holders 5000
    echo "Backend stderr:"
    log_tail "$BACKEND_ERR"
    exit 1
fi

# Same protective re-check for frontend port
if ! port_free 5001; then
    echo "ERROR: Port 5001 became occupied before frontend launch. Holders:" >&2
    dump_port_holders 5001 >&2
    kill "$BACKEND_PID" 2>/dev/null || true
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

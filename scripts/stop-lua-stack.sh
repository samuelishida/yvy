#!/usr/bin/env bash
# stop-lua-stack.sh — Stop local Lua backend/frontend processes on Linux/macOS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RUNTIME_DIR="$PROJECT_DIR/.runtime/lua-stack"

stop_pid() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null && echo "Stopped PID $pid (TERM)" || true
        # Wait up to 3s for graceful exit
        local i
        for i in 1 2 3 4 5 6; do
            kill -0 "$pid" 2>/dev/null || { sleep 0.5; return 0; }
            sleep 0.5
        done
        # Force kill
        kill -9 "$pid" 2>/dev/null && echo "Force-killed PID $pid (KILL)" || true
        # Wait up to 3s for the kernel to reap the process and release fds
        for i in 1 2 3 4 5 6; do
            kill -0 "$pid" 2>/dev/null || return 0
            sleep 0.5
        done
        echo "WARNING: PID $pid still in process table after KILL" >&2
    fi
}

port_pids() {
    local port="$1"
    local pids

    # Prefer fuser (most reliable for network ports on Linux)
    pids=$(fuser -n tcp "$port" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' || true)
    if [ -n "$pids" ]; then
        echo "$pids"
        return
    fi

    # Fallback to lsof
    pids=$(lsof -ti :"$port" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        echo "$pids"
        return
    fi

    # Fallback to ss (may need root for pid=... info)
    ss -tlnp "sport = :$port" 2>/dev/null | grep -oP '(?<=pid=)\d+' || true
}

port_free() {
    local port="$1"
    if fuser -n tcp "$port" >/dev/null 2>&1; then return 1; fi
    if lsof -i :"$port" >/dev/null 2>&1; then return 1; fi
    if ss -tln "sport = :$port" 2>/dev/null | grep -q ":$port"; then return 1; fi
    return 0
}

kill_port() {
    local port="$1"
    local pids

    # 1. Blanket SIGTERM everything on the port (fuser is the most reliable here)
    fuser -k -n tcp "$port" >/dev/null 2>&1 || true
    sleep 0.5

    # 2. PID-based cleanup for anything fuser identified
    pids=$(port_pids "$port")
    for pid in $pids; do
        stop_pid "$pid"
    done

    # 3. Force-kill if still occupied
    if ! port_free "$port"; then
        fuser -k -KILL -n tcp "$port" >/dev/null 2>&1 || true
        sleep 1
    fi

    # 4. Wait up to 3s for the port to be fully released
    local i
    for i in 1 2 3 4 5 6; do
        port_free "$port" && return 0
        sleep 0.5
    done
    return 1
}

echo "Stopping Lua stack processes..."

for name in backend.pid frontend.pid; do
    pidfile="$RUNTIME_DIR/$name"
    if [ -f "$pidfile" ]; then
        stop_pid "$(cat "$pidfile")"
    fi
done

# Kill by port to catch stragglers / stale pidfiles
kill_port 5000
kill_port 5001

# Verify ports actually released
ok=1
for port in 5000 5001; do
    if ! port_free "$port"; then
        echo "WARNING: Port $port still bound after stop. Holder:" >&2
        fuser -n tcp "$port" 2>/dev/null | sed 's/^/  /' || true
        lsof -i :"$port" 2>/dev/null | sed 's/^/  /' || true
        ss -tlnp "sport = :$port" 2>/dev/null | sed 's/^/  /' || true
        ok=0
    fi
done

# Clean PID/log files
if [ -d "$RUNTIME_DIR" ]; then
    rm -f "$RUNTIME_DIR"/*.pid "$RUNTIME_DIR"/*.log
fi

if (( ok )); then
    echo "Lua stack stopped."
else
    echo "Lua stack stop incomplete — ports still occupied." >&2
    exit 1
fi

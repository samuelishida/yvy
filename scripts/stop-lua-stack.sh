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
        for _ in 1 2 3 4 5 6; do
            kill -0 "$pid" 2>/dev/null || return 0
            sleep 0.5
        done
        # Force kill if still alive
        kill -9 "$pid" 2>/dev/null && echo "Force-killed PID $pid (KILL)" || true
    fi
}

port_pids() {
    local port="$1"
    # Try lsof first (works without root for own processes)
    local pids
    pids=$(lsof -ti :"$port" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        echo "$pids"
        return
    fi
    # Try fuser (more reliable for system ports)
    pids=$(fuser -n tcp "$port" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' || true)
    if [ -n "$pids" ]; then
        echo "$pids"
        return
    fi
    # Fallback to ss (requires CAP_SYS_PTRACE or root for pid=...)
    ss -tlnp "sport = :$port" 2>/dev/null | grep -oP '(?<=pid=)\d+' || true
}

port_free() {
    local port="$1"
    if lsof -i :"$port" >/dev/null 2>&1; then return 1; fi
    if ss -tln "sport = :$port" 2>/dev/null | grep -q ":$port"; then return 1; fi
    return 0
}

kill_port() {
    local port="$1"
    local pids
    pids=$(port_pids "$port")
    for pid in $pids; do
        stop_pid "$pid"
    done
    # Final fallback: SIGKILL anything still bound (needs same user)
    if ! port_free "$port"; then
        fuser -k -KILL -n tcp "$port" 2>/dev/null || true
        sleep 1
    fi
}

echo "Stopping Lua stack processes..."

for name in backend.pid frontend.pid; do
    pidfile="$RUNTIME_DIR/$name"
    if [ -f "$pidfile" ]; then
        stop_pid "$(cat "$pidfile")"
    fi
done

kill_port 5000
kill_port 5001

# Verify ports actually released
for port in 5000 5001; do
    if ! port_free "$port"; then
        echo "WARNING: Port $port still bound after stop. Holder:"
        lsof -i :"$port" 2>/dev/null || ss -tlnp "sport = :$port" 2>/dev/null || true
    fi
done

# Clean PID/log files
if [ -d "$RUNTIME_DIR" ]; then
    rm -f "$RUNTIME_DIR"/*.pid "$RUNTIME_DIR"/*.log
fi

echo "Lua stack stopped."

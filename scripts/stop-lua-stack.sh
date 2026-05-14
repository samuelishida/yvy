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
        kill "$pid" 2>/dev/null && echo "Stopped PID $pid" || echo "Skip PID $pid"
    fi
}

kill_port() {
    local port="$1"
    local pids
    pids=$(ss -tlnp "sport = :$port" 2>/dev/null \
        | grep -oP '(?<=pid=)\d+' || true)
    if [ -z "$pids" ]; then
        pids=$(lsof -ti :"$port" 2>/dev/null || true)
    fi
    for pid in $pids; do
        stop_pid "$pid"
    done
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

# Clean PID/log files
if [ -d "$RUNTIME_DIR" ]; then
    rm -f "$RUNTIME_DIR"/*.pid "$RUNTIME_DIR"/*.log
fi

echo "Lua stack stopped."

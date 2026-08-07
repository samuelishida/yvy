#!/usr/bin/env bash
# stop-lua-stack.sh — Stop Yvy Lua backend + C frontend.
# Uses real bind() probe to confirm ports are bindable (not just LISTEN-free).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNTIME_DIR="$PROJECT_DIR/.runtime/lua-stack"

PORTS=(5000 5001)
NAME_PATTERNS=("lua.*main\\.lua" "lua5\\.1.*main" "yvy-server")

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
    local port="$1" timeout="${2:-10}"
    local deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        port_free "$port" && return 0
        sleep 0.3
    done
    return 1
}

pids_on_port() {
    local port="$1"
    {
        ss -tanp "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+'
        lsof -ti :"$port" 2>/dev/null
        fuser -n tcp "$port" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$'
    } | sort -u
}

kill_pid() {
    local pid="$1" sig="${2:-TERM}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    kill -"$sig" "$pid" 2>/dev/null || true
}

stop_pid_graceful() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    kill -TERM "$pid" 2>/dev/null || true
    local i
    for i in 1 2 3 4 5 6; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.5
    done
    kill -KILL "$pid" 2>/dev/null || true
    for i in 1 2 3 4 5 6; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.5
    done
    echo "WARNING: PID $pid still in process table after KILL" >&2
}

echo "Stopping Lua stack processes..."

# 1. Graceful stop via PID files
if [ -d "$RUNTIME_DIR" ]; then
    for name in backend.pid frontend.pid; do
        pf="$RUNTIME_DIR/$name"
        [ -f "$pf" ] && stop_pid_graceful "$(cat "$pf" 2>/dev/null)"
    done
fi

# 2. Pkill by process name (TERM)
for pat in "${NAME_PATTERNS[@]}"; do
    pkill -TERM -f "$pat" 2>/dev/null || true
done
sleep 0.4

# 3. Per-port escalation: kill any holder, then SIGKILL fallback
for port in "${PORTS[@]}"; do
    port_free "$port" && continue
    pids="$(pids_on_port "$port")"
    for pid in $pids; do kill_pid "$pid" TERM; done
    sleep 0.3
    port_free "$port" && continue
    pids="$(pids_on_port "$port")"
    for pid in $pids; do kill_pid "$pid" KILL; done
    fuser -k -KILL -n tcp "$port" >/dev/null 2>&1 || true
done

# 4. Final SIGKILL by name — catches anything pkill -TERM missed
for pat in "${NAME_PATTERNS[@]}"; do
    pkill -KILL -f "$pat" 2>/dev/null || true
done

# 5. Wait for real bindability
ok=1
for port in "${PORTS[@]}"; do
    if ! wait_port_free "$port" 10; then
        echo "ERROR: Port $port still occupied after stop:" >&2
        ss -tanp "sport = :$port" 2>/dev/null | sed 's/^/  /' >&2 || true
        lsof -i :"$port" 2>/dev/null | sed 's/^/  /' >&2 || true
        fuser -n tcp "$port" 2>/dev/null | sed 's/^/  /' >&2 || true
        ok=0
    fi
done

# Clean PID/log files
if [ -d "$RUNTIME_DIR" ]; then
    rm -f "$RUNTIME_DIR"/*.pid "$RUNTIME_DIR"/*.log 2>/dev/null || true
fi

if (( ok )); then
    echo "Lua stack stopped."
else
    echo "Lua stack stop INCOMPLETE — ports still bound." >&2
    exit 1
fi

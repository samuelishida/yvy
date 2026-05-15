#!/usr/bin/env bash
# kill-yvy.sh — Aggressive killer for Yvy Lua stack.
# Kills by PID file, by process name, by port. Verifies with real bind().
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RUNTIME_DIR="$PROJECT_DIR/.runtime/lua-stack"

PORTS=(5000 5001 5002)
NAME_PATTERNS=("lua.*main\\.lua" "lua5\\.1.*main" "yvy-server")

# Bindability check that treats TIME-WAIT entries as benign (SO_REUSEADDR
# bypasses them) and ignores transient EADDRINUSE caused by kernel cleanup.
port_free() {
    local port="$1"
    # Hard fail: real LISTEN or ESTABLISHED socket on the port
    if ss -tan "sport = :$port" 2>/dev/null | awk 'NR>1 && $1!="TIME-WAIT"' | grep -q .; then
        return 1
    fi
    # Soft check: actual bind attempt with SO_REUSEADDR
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
    # Bind failed — if only TIME-WAIT entries linger, consider it free
    # (server using SO_REUSEADDR will bind successfully anyway).
    if ss -tan "sport = :$port" 2>/dev/null | awk 'NR>1 && $1!="TIME-WAIT"' | grep -q .; then
        return 1
    fi
    return 0
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
    local name
    name="$(cat /proc/"$pid"/comm 2>/dev/null || echo unknown)"
    if kill -"$sig" "$pid" 2>/dev/null; then
        printf '  %s PID %s (%s)\n' "$sig" "$pid" "$name"
    fi
}

# 1. Kill by stale PID files first
if [ -d "$RUNTIME_DIR" ]; then
    for pf in "$RUNTIME_DIR"/*.pid; do
        [ -f "$pf" ] || continue
        kill_pid "$(cat "$pf" 2>/dev/null)" TERM
    done
fi

# 2. Pkill by process name (TERM)
for pat in "${NAME_PATTERNS[@]}"; do
    if pkill -TERM -f "$pat" 2>/dev/null; then
        printf '  TERM by name: %s\n' "$pat"
    fi
done
sleep 0.4

# 3. Kill anything still on ports (TERM, then KILL)
for port in "${PORTS[@]}"; do
    pids="$(pids_on_port "$port")"
    if [ -z "$pids" ]; then
        printf '  Nothing found on port %s\n' "$port"
        continue
    fi
    for pid in $pids; do kill_pid "$pid" TERM; done
    sleep 0.3
    pids="$(pids_on_port "$port")"
    for pid in $pids; do kill_pid "$pid" KILL; done
    fuser -k -KILL -n tcp "$port" >/dev/null 2>&1 || true
done

# 4. Final pkill -KILL by name (catches everything)
for pat in "${NAME_PATTERNS[@]}"; do
    pkill -KILL -f "$pat" 2>/dev/null || true
done
sleep 0.3

# 5. Verify ports are actually bindable (not just LISTEN-free)
all_ok=1
for port in "${PORTS[@]}"; do
    deadline=$(( $(date +%s) + 5 ))
    while ! port_free "$port"; do
        if (( $(date +%s) >= deadline )); then
            printf '  ERROR: Port %s still NOT bindable. Holders:\n' "$port" >&2
            ss -tanp "sport = :$port" 2>/dev/null | sed 's/^/    /' >&2 || true
            lsof -i :"$port" 2>/dev/null | sed 's/^/    /' >&2 || true
            fuser -n tcp "$port" 2>/dev/null | sed 's/^/    /' >&2 || true
            all_ok=0
            break
        fi
        sleep 0.3
    done
    if port_free "$port" 2>/dev/null; then
        printf '  Port %s: free (verified by bind)\n' "$port"
    fi
done

# Clean PID files
if [ -d "$RUNTIME_DIR" ]; then
    rm -f "$RUNTIME_DIR"/*.pid 2>/dev/null || true
fi

(( all_ok )) && exit 0 || exit 1

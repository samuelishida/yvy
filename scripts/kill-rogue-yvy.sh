#!/usr/bin/env bash
# kill-rogue-yvy.sh — Kill stray Yvy local dev processes on Linux/macOS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RUNTIME_DIR="$PROJECT_DIR/.runtime/lua-stack"

DRY_RUN=0
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=1
done

declare -A CANDIDATES  # pid -> reason

add_candidate() {
    local pid="$1" reason="$2"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    (( pid > 0 )) || return 0
    if [[ -v CANDIDATES[$pid] ]]; then
        CANDIDATES[$pid]="${CANDIDATES[$pid]}, $reason"
    else
        CANDIDATES[$pid]="$reason"
    fi
}

stop_candidate() {
    local pid="$1" reason="$2"
    local name
    name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
    if (( DRY_RUN )); then
        printf "DRY RUN  PID %-7s %-20s [%s]\n" "$pid" "$name" "$reason"
        return
    fi
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null \
            && printf "STOPPED  PID %-7s %-20s [%s]\n" "$pid" "$name" "$reason" \
            || printf "SKIPPED  PID %-7s %-20s [%s]\n" "$pid" "$name" "$reason"
    else
        printf "GONE     PID %-7s %-20s [%s]\n" "$pid" "$name" "$reason"
    fi
}

# Scan by process command line
while IFS= read -r line; do
    pid=$(echo "$line" | awk '{print $1}')
    cmd=$(echo "$line" | cut -d' ' -f2-)

    case "$cmd" in
        *lua5.1*main.lua*|*" lua "*main.lua*)
            add_candidate "$pid" "lua main.lua" ;;
    esac

    case "$cmd" in
        *node*server.js*|*react-scripts*start*)
            add_candidate "$pid" "frontend node" ;;
    esac

    case "$cmd" in
        *python*backend.py*|*hypercorn*backend:app*)
            add_candidate "$pid" "python/hypercorn backend" ;;
    esac

    case "$cmd" in
        *bash*run-lua.sh*|*bash*run-c-frontend.sh*|*bash*start-lua-stack.sh*)
            add_candidate "$pid" "shell wrapper" ;;
    esac

    case "$cmd" in
        *yvy-server*)
            add_candidate "$pid" "yvy-server (C frontend)" ;;
    esac
done < <(ps -eo pid= -o args= 2>/dev/null | awk '{print $1, substr($0, index($0,$2))}')

# Scan ports 5000 5001
for port in 5000 5001; do
    pids=$(ss -tlnp "sport = :$port" 2>/dev/null | grep -oP '(?<=pid=)\d+' || true)
    if [ -z "$pids" ]; then
        pids=$(lsof -ti :"$port" 2>/dev/null || true)
    fi
    for pid in $pids; do
        add_candidate "$pid" "listening on :$port"
    done
done

echo "=== Rogue Yvy Process Cleanup ==="
echo "Project: $PROJECT_DIR"
(( DRY_RUN )) && echo "Mode: dry run"

if [ ${#CANDIDATES[@]} -eq 0 ]; then
    echo "No rogue Yvy processes found."
else
    for pid in $(echo "${!CANDIDATES[@]}" | tr ' ' '\n' | sort -n); do
        stop_candidate "$pid" "${CANDIDATES[$pid]}"
    done
fi

if (( ! DRY_RUN )) && [ -d "$RUNTIME_DIR" ]; then
    rm -f "$RUNTIME_DIR"/*.pid "$RUNTIME_DIR"/*.log
fi

echo "Done."

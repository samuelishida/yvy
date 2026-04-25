#!/usr/bin/env bash
# Run both backend and frontend locally (no Docker)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Local runner defaults to DEV mode to avoid serving stale production builds.
: "${YVY_LOCAL_DEV:=1}"
export YVY_LOCAL_DEV

BACKEND_PID=""
FRONTEND_PID=""
CLEANED_UP=0

cleanup() {
    if [ "$CLEANED_UP" -eq 1 ]; then
        return
    fi
    CLEANED_UP=1
    trap - INT TERM EXIT
    echo ""
    echo "Shutting down..."
    if [ -n "$BACKEND_PID" ]; then
        kill "$BACKEND_PID" 2>/dev/null || true
    fi
    if [ -n "$FRONTEND_PID" ]; then
        kill "$FRONTEND_PID" 2>/dev/null || true
    fi
    pkill -f "[h]ypercorn backend:app" 2>/dev/null || true
    pkill -f "[p]ython backend.py" 2>/dev/null || true
    pkill -f "[r]eact-scripts start" 2>/dev/null || true
    pkill -f "[n]ode server.js" 2>/dev/null || true
}

echo "=== Yvy Local Runner ==="
echo "Starting backend + frontend..."
echo "Mode: local-dev (YVY_LOCAL_DEV=$YVY_LOCAL_DEV)"
echo ""

# Trap to kill both processes on exit
trap cleanup INT TERM EXIT

# Start backend in background
"$SCRIPT_DIR/run-backend.sh" &
BACKEND_PID=$!
echo "Backend PID: $BACKEND_PID"

# Wait for backend to be ready
echo "Waiting for backend (port 5000)..."
for i in {1..30}; do
    if curl -s http://127.0.0.1:5000/health >/dev/null 2>&1; then
        echo "Backend ready!"
        break
    fi
    sleep 1
done

# Start frontend in background
"$SCRIPT_DIR/run-frontend.sh" &
FRONTEND_PID=$!
echo "Frontend PID: $FRONTEND_PID"

echo ""
echo "=== Yvy is running ==="
echo "Frontend: http://127.0.0.1:5001"
echo "Backend:  http://127.0.0.1:5000"
echo ""
echo "Press Ctrl+C to stop both."
echo ""

# Wait for both processes
wait

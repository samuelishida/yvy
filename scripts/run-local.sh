#!/usr/bin/env bash
# Run both backend and frontend locally (no Docker)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Yvy Local Runner ==="
echo "Starting backend + frontend..."
echo ""

# Trap to kill both processes on exit
trap 'echo ""; echo "Shutting down..."; kill 0 2>/dev/null; exit 0' INT TERM EXIT

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

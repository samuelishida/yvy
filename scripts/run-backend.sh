#!/usr/bin/env bash
# Run backend locally (no Docker)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Detect venv location (project dir or home fallback for NTFS/exFAT)
VENV_DIR="$PROJECT_DIR/backend/venv"
if [ ! -f "$VENV_DIR/bin/python" ]; then
    VENV_DIR="${YVY_VENV:-$HOME/.local/share/yvy-venv}"
fi

if [ ! -f "$VENV_DIR/bin/python" ]; then
    echo "Virtual environment not found. Run: make setup"
    exit 1
fi

cd "$PROJECT_DIR/backend"

# Load environment variables
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

# Set defaults for local development
export SQLITE_PATH="${SQLITE_PATH:-$PROJECT_DIR/backend/data/yvy.db}"
export REDIS_URL="${REDIS_URL:-redis://localhost:6379/0}"
export AUTH_REQUIRED="${AUTH_REQUIRED:-0}"
export DEV="${YVY_LOCAL_DEV:-${DEV:-1}}"
export CORS_ORIGINS="${CORS_ORIGINS:-http://localhost:5001,http://127.0.0.1:5001,http://localhost:3000}"

echo "=== Yvy Backend (local) ==="
echo "SQLite: $SQLITE_PATH"
echo "Redis:  $REDIS_URL"
echo "Port:   5000"
echo ""

# Run with hypercorn (production-like) or python directly (dev)
if [ "${DEV:-1}" = "1" ]; then
    echo "Running in DEV mode (python backend.py)..."
    exec "$VENV_DIR/bin/python" backend.py
else
    echo "Running in PROD mode (hypercorn)..."
    exec "$VENV_DIR/bin/hypercorn" backend:app \
        --bind 0.0.0.0:5000 \
        --workers 1 \
        --worker-class asyncio \
        --keep-alive 120
fi

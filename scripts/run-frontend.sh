#!/usr/bin/env bash
# Run frontend locally (no Docker)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Detect node_modules location (project dir or home fallback for NTFS/exFAT)
NODE_MODULES_DIR="$PROJECT_DIR/frontend/node_modules"
if [ ! -d "$NODE_MODULES_DIR" ]; then
    NODE_MODULES_DIR="$HOME/.local/share/yvy-frontend/node_modules"
fi

if [ ! -d "$NODE_MODULES_DIR" ]; then
    echo "node_modules not found. Run: make local-setup"
    exit 1
fi

cd "$PROJECT_DIR/frontend"

# Load environment variables
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

export PORT="${PORT:-5001}"
# Force local backend URL when running without Docker
export BACKEND_URL="http://127.0.0.1:5000"
export API_KEY="${API_KEY:-}"

echo "=== Yvy Frontend (local) ==="
echo "Backend URL: $BACKEND_URL"
echo "Port:        $PORT"
echo ""

# Check if we should run dev server or production build
if [ "${DEV:-1}" = "1" ]; then
    echo "Running in DEV mode (react-scripts start)..."
    # Use node_modules from detected location
    PATH="$NODE_MODULES_DIR/.bin:$PATH"
    export NODE_PATH="${NODE_MODULES_DIR}${NODE_PATH:+:$NODE_PATH}"
    exec react-scripts start
else
    echo "Running in PROD mode (serve build)..."
    if [ ! -d "build" ]; then
        echo "Build directory not found. Building..."
        # Build in home dir where node_modules works, then copy build back
        BUILD_HOME="$HOME/.local/share/yvy-frontend"
        cp -r "$PROJECT_DIR/frontend/src" "$BUILD_HOME/" 2>/dev/null || true
        cp -r "$PROJECT_DIR/frontend/public" "$BUILD_HOME/" 2>/dev/null || true
        cp "$PROJECT_DIR/frontend/package.json" "$BUILD_HOME/" 2>/dev/null || true
        cd "$BUILD_HOME"
        PATH="$NODE_MODULES_DIR/.bin:$PATH"
        export NODE_PATH="${NODE_MODULES_DIR}${NODE_PATH:+:$NODE_PATH}"
        react-scripts build
        echo "Copying build to project..."
        cp -r "$BUILD_HOME/build" "$PROJECT_DIR/frontend/"
        cd "$PROJECT_DIR/frontend"
    fi
    exec node server.js
fi

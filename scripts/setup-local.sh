#!/usr/bin/env bash
# Setup local development environment (no Docker)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# NTFS/exFAT via fuse doesn't support symlinks, which breaks python3 -m venv.
# Use a venv in the user's home directory (ext4) instead.
VENV_DIR="${YVY_VENV:-$HOME/.local/share/yvy-venv}"

echo "=== Yvy Local Setup ==="
echo "Project dir: $PROJECT_DIR"
echo "Venv dir:    $VENV_DIR"

# Backend setup
echo ""
echo "[1/3] Setting up Python backend..."
cd "$PROJECT_DIR/backend"

if [ ! -f "$VENV_DIR/bin/python" ]; then
    echo "Creating Python virtual environment..."
    mkdir -p "$(dirname "$VENV_DIR")"
    python3 -m venv "$VENV_DIR"
fi

PIP="$VENV_DIR/bin/pip"
PYTHON="$VENV_DIR/bin/python"

echo "Installing Python dependencies..."
"$PIP" install --upgrade pip
"$PIP" install -r requirements.txt

echo "Creating data directory..."
mkdir -p data

echo "Backend setup complete."

# Frontend setup
echo ""
echo "[2/3] Setting up Node.js frontend..."
cd "$PROJECT_DIR/frontend"

if [ ! -d "node_modules" ]; then
    echo "Installing npm dependencies..."
    # NTFS/exFAT via fuse doesn't support symlinks, which npm needs for .bin/
    # Fallback: install without bin links, or install to home dir if that fails
    if npm install 2>/dev/null; then
        echo "npm install OK"
    else
        echo "WARNING: npm install failed (likely due to symlink restrictions on this filesystem)."
        echo "Installing frontend dependencies to home directory instead..."
        FRONTEND_HOME="$HOME/.local/share/yvy-frontend"
        mkdir -p "$FRONTEND_HOME"
        cp package.json package-lock.json "$FRONTEND_HOME/" 2>/dev/null || true
        cd "$FRONTEND_HOME"
        npm install
        echo "Frontend deps installed at $FRONTEND_HOME"
        echo "To run frontend: cd $FRONTEND_HOME && npm start"
    fi
fi

echo "Frontend setup complete."

# Environment check
echo ""
echo "[3/3] Checking environment..."
cd "$PROJECT_DIR"

if [ ! -f ".env" ]; then
    echo "WARNING: .env file not found. Copying from .env.example..."
    cp .env.example .env
    echo "Please edit .env with your actual API keys."
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Next steps:"
echo "  make run      # Run backend + frontend"
echo "  make backend  # Run backend only"
echo "  make frontend # Run frontend only"
echo ""

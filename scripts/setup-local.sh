#!/usr/bin/env bash
# Setup local development environment (no Docker)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# --- Cross-platform Python detection ---
# Tries: python3 (Linux/Mac), python (Windows/Mac), py (Windows launcher)
detect_python() {
    for cmd in python3 python py; do
        if command -v "$cmd" &>/dev/null; then
            # Verify it's Python 3+ using Python itself (portable across all OSes)
            major=$("$cmd" -c "import sys; print(sys.version_info.major)" 2>/dev/null || echo 0)
            if [ "$major" -ge 3 ] 2>/dev/null; then
                echo "$cmd"
                return 0
            fi
        fi
    done
    echo ""
}

PYTHON_CMD=$(detect_python)
if [ -z "$PYTHON_CMD" ]; then
    echo "ERROR: Python 3 not found. Install Python 3 from https://python.org and try again."
    exit 1
fi
echo "Using Python: $PYTHON_CMD ($($PYTHON_CMD --version 2>&1))"

# --- Detect OS for venv paths ---
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        IS_WINDOWS=1
        VENV_BIN="Scripts"
        VENV_PYTHON="Scripts/python.exe"
        VENV_PIP="Scripts/pip.exe"
        ;;
    *)
        IS_WINDOWS=0
        VENV_BIN="bin"
        VENV_PYTHON="bin/python"
        VENV_PIP="bin/pip"
        ;;
esac

# NTFS/exFAT via fuse doesn't support symlinks, which breaks venv on some setups.
# Use a venv in the user's home directory instead.
VENV_DIR="${YVY_VENV:-$HOME/.local/share/yvy-venv}"

echo "=== Yvy Local Setup ==="
echo "Project dir: $PROJECT_DIR"
echo "Venv dir:    $VENV_DIR"
echo "OS:          $(uname -s)"

# Backend setup
echo ""
echo "[1/3] Setting up Python backend..."
cd "$PROJECT_DIR/backend"

if [ ! -f "$VENV_DIR/$VENV_PYTHON" ]; then
    echo "Creating Python virtual environment..."
    mkdir -p "$(dirname "$VENV_DIR")"
    "$PYTHON_CMD" -m venv "$VENV_DIR"
fi

PIP="$VENV_DIR/$VENV_PIP"
PYTHON="$VENV_DIR/$VENV_PYTHON"

echo "Installing Python dependencies..."
# Upgrade pip — use python -m pip to avoid Windows file-lock issues
"$PYTHON" -m pip install --upgrade pip 2>/dev/null || echo "(pip upgrade skipped — continuing with current version)"
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

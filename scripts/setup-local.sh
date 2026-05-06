#!/usr/bin/env bash
# setup-local.sh - Lua-only local setup wrapper.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Yvy Local Setup (Lua) ==="

bash "$SCRIPT_DIR/setup-lua.sh"

if command -v npm >/dev/null 2>&1; then
  echo "Installing frontend dependencies..."
  cd "$PROJECT_DIR/frontend"
  if [ -f package-lock.json ]; then
    npm ci
  else
    npm install
  fi
else
  echo "WARN: npm not found; skipping frontend dependencies."
fi

echo "=== Setup complete ==="
echo "Run: make run"

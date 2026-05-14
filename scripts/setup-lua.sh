#!/usr/bin/env bash
# setup-lua.sh — Install Lua dependencies for Yvy backend (Ubuntu/Linux)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_TEST_DEPS="${YVY_INSTALL_TEST_DEPS:-1}"

echo "=== Yvy Lua Backend Setup ==="

# ── Detect OS ─────────────────────────────────────────────────────────────
case "$(uname -s)" in
    Linux)  OS="linux" ;;
    MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
    *) echo "Unsupported OS"; exit 1 ;;
esac

# ── Install Lua 5.1 + LuaRocks ────────────────────────────────────────────
if [ "$OS" = "linux" ]; then
    echo "Installing Lua + LuaRocks..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        build-essential ca-certificates pkg-config wget unzip \
        lua5.1 liblua5.1-0-dev luarocks libsqlite3-dev libssl-dev libexpat1-dev
fi

# ── Install Lua rocks (idempotent) ────────────────────────────────────────
echo "Installing Lua dependencies..."

install_rock() {
    local rock="$1"
    local flag="${2:-}"
    if luarocks list --porcelain "$rock" 2>/dev/null | grep -q "^$rock"; then
        echo "  $rock already installed, skipping"
        return 0
    fi
    echo "  installing $rock..."
    if [ -n "${flag:-}" ]; then
        sudo luarocks install "$rock" "$flag"
    else
        sudo luarocks install "$rock"
    fi
}

# Core (lsqlite3 bundles SQLite 3.51+ — no source build needed)
install_rock luasocket
install_rock copas
install_rock lsqlite3
install_rock lua-cjson
install_rock luaexpat
install_rock lua-csv
install_rock dkjson

if [ "$INSTALL_TEST_DEPS" = "1" ]; then
    install_rock busted
fi

echo "=== Setup complete ==="
echo "Run: cd backend-lua && lua main.lua"

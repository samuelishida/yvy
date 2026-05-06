#!/usr/bin/env bash
# setup-lua.sh — Install Lua dependencies for Yvy backend (Ubuntu/Linux)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

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
    sudo apt-get install -y -qq lua5.1 liblua5.1-0-dev luarocks libsqlite3-dev libssl-dev

    # Install SQLite 3.45+ from source for JSONB support
    SQLITE_VERSION="3450000"
    if ! pkg-config --atleast-version=3.45 sqlite3 2>/dev/null; then
        echo "Installing SQLite $SQLITE_VERSION from source..."
        cd /tmp
        wget -q "https://sqlite.org/2024/sqlite-autoconf-${SQLITE_VERSION}.tar.gz"
        tar xzf "sqlite-autoconf-${SQLITE_VERSION}.tar.gz"
        cd "sqlite-autoconf-${SQLITE_VERSION}"
        ./configure --prefix=/usr/local
        make -j$(nproc)
        sudo make install
        sudo ldconfig
        cd /tmp && rm -rf "sqlite-autoconf-${SQLITE_VERSION}"*
    fi
fi

# ── Install Lua rocks ─────────────────────────────────────────────────────
echo "Installing Lua dependencies..."

# Core
sudo luarocks install luasocket
sudo luarocks install copas
sudo luarocks install lsqlite3 SQLITE_DIR=/usr/local
sudo luarocks install lua-cjson
sudo luarocks install luaexpat
sudo luarocks install lua-csv
sudo luarocks install dkjson

# Test framework
sudo luarocks install busted

echo "=== Setup complete ==="
echo "Run: cd backend-lua && lua main.lua"

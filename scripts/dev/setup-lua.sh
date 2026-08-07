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
# Skip the apt step when lua5.1 and luarocks are already present. The Ansible
# playbook's apt task installs these, so re-running `apt-get update` (~15s)
# on every deploy is wasted work.
if [ "$OS" = "linux" ] && { ! command -v lua5.1 >/dev/null 2>&1 || ! command -v luarocks >/dev/null 2>&1; }; then
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

# ── Python batch environment (TerraBrasilis spatial joins / raster tools) ──
# This is a RUNTIME dependency (deter_daily.sh, PRODES raster conversion,
# CAR cross) — NOT a test dep, so it is NOT gated on YVY_INSTALL_TEST_DEPS.
# It requires the python3-venv package on Debian/Ubuntu
# (`python3 -m venv` otherwise fails with "ensurepip is not available"),
# which the playbook installs. Opt out explicitly with YVY_SKIP_PYTHON_ENV=1
# only on hosts that don't run the batch pipelines.
if [ "${YVY_SKIP_PYTHON_ENV:-0}" != "1" ]; then
    echo "Setting up Python batch environment..."
    if ! bash "$SCRIPT_DIR/setup-python-env.sh"; then
        echo "ERROR: Python batch environment setup failed." >&2
        echo "If 'python3 -m venv' failed, install python3-venv first:" >&2
        echo "  sudo apt-get install -y python3-venv" >&2
        echo "then re-run: bash scripts/dev/setup-lua.sh" >&2
        exit 1
    fi
else
    echo "Skipping Python batch environment (YVY_SKIP_PYTHON_ENV=1)." >&2
    echo "  Run it manually when needed: bash scripts/dev/setup-python-env.sh" >&2
fi

echo "=== Setup complete ==="
echo "Run: cd backend-lua && lua main.lua"

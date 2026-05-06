#!/usr/bin/env bash
# Backward-compatible wrapper for the Lua backend.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$SCRIPT_DIR/run-lua.sh" "$@"

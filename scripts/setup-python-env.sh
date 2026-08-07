#!/usr/bin/env bash
# setup-python-env.sh — Create the Yvy Python venv and install batch deps.
#
# The Lua backend never imports Python; this env is for the offline batch
# scripts (DETER/CAR spatial join, PRODES raster conversion, tile rendering)
# that run detached via cron/systemd timers.
#
# Idempotent: re-running only re-installs requirements into the existing venv.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENV_DIR="${YVY_PYTHON_VENV:-$PROJECT_DIR/.venv}"

echo "=== Yvy Python Environment Setup ==="

if [ ! -x "$VENV_DIR/bin/python3" ]; then
    echo "Creating venv at $VENV_DIR ..."
    python3 -m venv "$VENV_DIR"
fi

echo "Installing requirements (geopandas, shapely, rasterio)..."
if ! "$VENV_DIR/bin/pip" install -r "$SCRIPT_DIR/requirements.txt"; then
    echo "ERROR: pip install failed." >&2
    echo "On ARM (OCI A1) missing binary wheels need: sudo apt-get install -y libgeos-dev gdal-bin" >&2
    echo "then re-run this script." >&2
    exit 1
fi

echo "=== Python environment ready ==="
"$VENV_DIR/bin/python3" -c "import geopandas, shapely, rasterio; print('geopandas', geopandas.__version__, '| shapely', shapely.__version__, '| rasterio', rasterio.__version__)"

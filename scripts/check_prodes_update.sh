#!/usr/bin/env bash
# check_prodes_update.sh — detect + apply a new PRODES version (Inc 5)
#
# Probes candidate `prodes_brasil_<YYYY>_v<YYYYMMDD>.zip` suffixes over the last
# ~90 days (newest first) on the TerraBrasilis download area and compares with
# backend-lua/data/.prodes_version. On a newer version:
#   1. downloads + extracts the raster
#   2. converts to CSV (prodes_geotiff_to_csv.py --version)
#   3. writes .prodes_version
#   4. stops yvy-backend → one-off ingest with PRODES_FORCE_UPDATE=1 (ingest.lua
#      takes a .backup, truncates deforestation_data, re-ingests) → starts again.
#
# Usage:
#   bash scripts/check_prodes_update.sh            # detect + apply
#   bash scripts/check_prodes_update.sh check      # detect only (prints NEW_VERSION=)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$PROJECT_DIR/backend-lua/data"
VERSION_FILE="$DATA_DIR/.prodes_version"
BASE_URL="https://terrabrasilis.dpi.inpe.br/download/dataset/brasil-prodes/raster"
MODE="${1:-apply}"

if [ ! -d "$DATA_DIR" ]; then
  echo "ERROR: $DATA_DIR not found" >&2
  exit 1
fi

# ── 1. Detect newest version ───────────────────────────────────────────────
current_year=$(date +%Y)
found=""
for y in "$current_year" "$((current_year - 1))"; do
  for d in $(seq 90 -1 0); do
    stamp=$(date -d "-$d days" +%Y%m%d)
    url="$BASE_URL/prodes_brasil_${y}_v${stamp}.zip"
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 -I "$url" || true)
    if [ "$code" = "200" ]; then
      found="prodes_brasil_${y}_v${stamp}"
      break 2
    fi
  done
done

if [ -z "$found" ]; then
  echo "check_prodes_update: no new raster found (404) — NOOP"
  exit 0
fi

echo "check_prodes_update: newest detected = $found"

if [ -f "$VERSION_FILE" ] && [ "$(cat "$VERSION_FILE")" = "$found" ]; then
  echo "check_prodes_update: already at $found — skip"
  exit 0
fi

if [ "$MODE" = "check" ]; then
  echo "NEW_VERSION=$found"
  exit 0
fi

# ── 2. Download + extract + convert ────────────────────────────────────────
DEST="$DATA_DIR/$found"
mkdir -p "$DEST"
cd "$DEST"
echo "check_prodes_update: downloading $found.zip ..."
curl -s -m 600 -o "$found.zip" "$BASE_URL/$found.zip"
unzip -o -q "$found.zip"

if [ ! -f "$DEST/$found.tif" ]; then
  echo "ERROR: $found.tif not found after extraction" >&2
  exit 1
fi

PY="$PROJECT_DIR/.venv/bin/python3"
if [ ! -x "$PY" ]; then PY="python3"; fi
echo "check_prodes_update: converting to CSV ..."
"$PY" "$SCRIPT_DIR/prodes_geotiff_to_csv.py" --version "$found"

echo "$found" > "$VERSION_FILE"

# ── 3. Re-ingest (stop backend → one-off PRODES_FORCE_UPDATE → start) ─────
# ingest.lua faz .backup binário, truncate e re-ingest. Se falhar, o .preprodes
# fica para restauração manual (nunca `sqlite3 db < backup`).
restart_backend=""
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet yvy-backend 2>/dev/null; then
  restart_backend=1
  sudo systemctl stop yvy-backend || true
  trap 'sudo systemctl start yvy-backend || true' EXIT
fi

(
  cd "$PROJECT_DIR/backend-lua"
  PRODES_FORCE_UPDATE=1 PRODES_VERSION="$found" \
    lua5.1 -e 'package.path="./?.lua;./?/init.lua;"..package.path; require("app.env"); require("app.db").init_db(); require("app.ingest").run()'
)

if [ -n "$restart_backend" ]; then
  sudo systemctl start yvy-backend
  trap - EXIT
fi

echo "check_prodes_update: applied $found (see yvy-backend log for ingest result)"

#!/usr/bin/env bash
# check_prodes_update.sh — detect + apply a new PRODES version (Inc 5)
#
# Probes candidate `prodes_brasil_<YYYY>_v<YYYYMMDD>.zip` suffixes over the last
# ~90 days (newest first) on the TerraBrasilis download area and compares with
# backend-lua/data/.prodes_version. On a newer version:
#   1. downloads + verifies the zip (curl -f, unzip -t, path-traversal guard)
#   2. extracts the raster, converts to CSV (prodes_geotiff_to_csv.py --version)
#   3. one-off ingest with PRODES_FORCE_UPDATE=1 (ingest.lua backs up + verifies,
#      truncates deforestation_data, re-ingests; on failure it restores from the
#      backup and exits != 0)
#   4. writes .prodes_version ONLY after a successful ingest
#
# The re-ingest runs standalone against SQLite WAL — the service keeps serving.
#
# Usage:
#   bash scripts/check_prodes_update.sh            # detect + apply
#   bash scripts/check_prodes_update.sh check      # detect only (prints NEW_VERSION=)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
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

# ── 2. Download + verify + extract + convert ──────────────────────────────
# download_and_verify(): baixa o zip com -f (falha em HTTP error), valida o
# arquivo (unzip -t), rejeita path-traversal (entradas com '..' ou caminhos
# absolutos) e só então extrai para o destino. Qualquer falha → sem marker,
# sem re-ingest, exit != 0 (o próximo run tenta de novo).
download_and_verify() {
  local version="$1"
  local dest="$2"
  local tmp_zip="${TMPDIR:-/tmp}/yvy_prodes_${version}.zip.$$"
  local tmp_dir="${TMPDIR:-/tmp}/yvy_prodes_extract_$$"

  rm -f "$tmp_zip"
  rm -rf "$tmp_dir"
  mkdir -p "$tmp_dir"

  echo "check_prodes_update: downloading $version.zip ..."
  if ! curl -fL -m 600 -o "$tmp_zip" "$BASE_URL/$version.zip"; then
    echo "ERROR: download failed for $version.zip" >&2
    rm -f "$tmp_zip"; rm -rf "$tmp_dir"
    return 1
  fi

  # Valida que é um zip de verdade (curl -f garante HTTP 200, mas o corpo
  # poderia ser HTML/erro).
  if ! unzip -t "$tmp_zip" >/dev/null 2>&1; then
    echo "ERROR: $version.zip is not a valid zip archive" >&2
    rm -f "$tmp_zip"; rm -rf "$tmp_dir"
    return 1
  fi

  # Path-traversal guard: rejeita entradas com '..' ou caminhos absolutos.
  if unzip -Z1 "$tmp_zip" | grep -qE '(^|/)\.\.(/|$)|^/'; then
    echo "ERROR: $version.zip contains unsafe paths (path traversal)" >&2
    rm -f "$tmp_zip"; rm -rf "$tmp_dir"
    return 1
  fi

  if ! unzip -q -o "$tmp_zip" -d "$tmp_dir"; then
    echo "ERROR: extraction failed for $version.zip" >&2
    rm -f "$tmp_zip"; rm -rf "$tmp_dir"
    return 1
  fi

  # Move o conteúdo extraído para o destino (substitui a versão antiga só aqui).
  rm -rf "$dest"
  mkdir -p "$dest"
  cp -r "$tmp_dir"/. "$dest"/
  rm -f "$tmp_zip"
  rm -rf "$tmp_dir"
  return 0
}

DEST="$DATA_DIR/$found"
download_and_verify "$found" "$DEST"

if [ ! -f "$DEST/$found.tif" ]; then
  echo "ERROR: $found.tif not found after extraction" >&2
  exit 1
fi

PY="$PROJECT_DIR/.venv/bin/python3"
if [ ! -x "$PY" ]; then PY="python3"; fi
echo "check_prodes_update: converting to CSV ..."
"$PY" "$SCRIPT_DIR/prodes_geotiff_to_csv.py" --version "$found"

# ── 3. Re-ingest (standalone, SQLite WAL — sem stop/start do serviço) ─────
# ingest.lua faz .backup verificado, truncate e re-ingest; se falhar ele
# restaura deforestation_data do backup e sai != 0 → o marker NÃO é escrito
# (set -e aborta aqui) e o próximo run tenta de novo.
(
  cd "$PROJECT_DIR/backend-lua"
  PRODES_FORCE_UPDATE=1 PRODES_VERSION="$found" \
    lua5.1 -e 'package.path="./?.lua;./?/init.lua;"..package.path; require("app.env"); require("app.db").init_db(); require("app.ingest").run()'
)

# Marker só após ingest bem-sucedido (set -e garante que só chegamos aqui com
# exit 0 do re-ingest).
echo "$found" > "$VERSION_FILE"

echo "check_prodes_update: applied $found (see yvy-backend log for ingest result)"

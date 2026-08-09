#!/usr/bin/env bash
# clone_car_prodes_worker.sh — pré-cálculo CAR × PRODES em paralelo por UF
#
# Uso:
#   bash tools/clone_car_prodes_worker.sh <car.db> <workdir> [max_workers]
#
# Exemplo:
#   bash backend-lua/tools/clone_car_prodes_worker.sh \
#        data/car/car.db /tmp/yvy-prodes-workers 15
#
# Fluxo:
#   1. (Recomendado) Pare o backend antes — para um snapshot consistente do WAL.
#   2. Cria clones FILTRADOS POR UF de car.db em <workdir>/<uf>/car.db
#      (tools/clone_car_uf.lua) — ~car.db/27 por clone, sem CLI sqlite3.
#   3. Roda warm_car_prodes.lua <uf> <clone> em paralelo (xargs -P).
#      O yvy.db (PRODES) é compartilhado read-only (SQLITE_PATH real) — o warm
#      só lê deforestation_data; múltiplas leituras WAL são seguras.
#   4. Merge dos clones de volta para o car.db original (valida version_key).
#   5. Valida e imprime instruções de SCP para produção.
#
# Requisitos: bash, xargs, mkdir, lua5.1, lsqlite3. NÃO precisa do CLI sqlite3.

set -euo pipefail

CAR_DB="${1:-}"
WORKDIR="${2:-/tmp/yvy-prodes-workers}"
MAX_WORKERS="${3:-8}"

if [[ -z "$CAR_DB" || -z "$WORKDIR" ]]; then
    echo "Uso: $0 <car.db> <workdir> [max_workers]"
    exit 1
fi

if [[ ! -f "$CAR_DB" ]]; then
    echo "car.db não encontrado: $CAR_DB"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(dirname "$SCRIPT_DIR")"
cd "$BACKEND_DIR"

UFS=(AC AL AM AP BA CE DF ES GO MA MG MS MT PA PB PE PI PR RJ RN RO RR RS SC SE SP TO)

# 1. Checkpoint consistente: se o backend roda via systemd, para o serviço.
# (Dev local usa scripts/dev/stop-lua-stack.sh — pare manualmente antes.)
if command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service 2>/dev/null | grep -q 'yvy-backend'; then
    echo "Parando backend (yvy-backend.service) para snapshot consistente..."
    sudo systemctl stop yvy-backend || true
fi

# 2. Prepara clones filtrados por UF.
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
echo "Criando clones filtrados por UF (lê o WAL via lsqlite3, sem CLI sqlite3)..."
for uf in "${UFS[@]}"; do
    mkdir -p "$WORKDIR/$uf"
    lua5.1 tools/clone_car_uf.lua "$CAR_DB" "$WORKDIR/$uf/car.db" "$uf" \
        >> "$WORKDIR/clone.log" 2>&1 || { echo "clone falhou para $uf"; tail -5 "$WORKDIR/clone.log"; exit 1; }
done
echo "Clones prontos (log: $WORKDIR/clone.log)"

# 3. Warm paralelo por UF (yvy.db compartilhado read-only).
echo "Iniciando warm paralelo com $MAX_WORKERS workers..."
printf '%s\n' "${UFS[@]}" | xargs -P "$MAX_WORKERS" -I{} \
    bash -c 'cd "'"$BACKEND_DIR"'" && lua5.1 tools/warm_car_prodes.lua "$1" "'"$WORKDIR"'/$1/car.db"' _ {}

# 4. Merge de volta para o car.db original (valida version_key consistente).
echo "Fazendo merge dos clones..."
CLONES=()
for uf in "${UFS[@]}"; do
    CLONES+=("$WORKDIR/$uf/car.db")
done
CAR_DB_PATH="$CAR_DB" lua5.1 tools/merge_car_prodes.lua "${CLONES[@]}"

# 5. Validação básica.
echo "── Validação ──────────────────────────────────────────────"
lua5.1 -e '
package.path = "./?.lua;./?/init.lua;" .. package.path
local sqlite3 = require("lsqlite3")
local conn = sqlite3.open("'"$CAR_DB"'")
local total = 0
for r in conn:nrows("SELECT count(*) AS c FROM car_prodes") do total = tonumber(r.c) or 0 end
local keys = {}
for r in conn:nrows("SELECT version_key AS v, count(*) AS c FROM car_prodes GROUP BY version_key") do
    keys[#keys+1] = r.v .. " (" .. r.c .. ")"
end
local stale = 0
for r in conn:nrows("SELECT count(*) AS c FROM car_prodes WHERE datetime(computed_at) < datetime(\"now\",\"-1 day\")") do stale = tonumber(r.c) or 0 end
conn:close()
print("car_prodes rows: " .. total)
print("distinct version_key: " .. #keys .. (#keys > 1 and " ⚠️ INCONSISTENTE" or " ✓"))
for _, k in ipairs(keys) do print("  " .. k) end
print("rows stale (>1d): " .. stale)
if total == 0 or #keys ~= 1 then
    io.stderr:write("FALHA na validação — não subir para produção.\n")
    os.exit(1)
end
'

echo "── SCP para produção (opcional) ─────────────────────────"
echo "  car.db final: $CAR_DB"
echo "  Exemplo (ajuste host/chave):"
echo "  scp -i ~/.ssh/oci_yvy $CAR_DB ubuntu@137.131.152.151:/opt/yvy/backend-lua/data/car/car.db"
echo "Pré-cálculo CAR × PRODES concluído."

#!/usr/bin/env bash
# compute_area_efetiva.sh — wrapper bash do recomputo da área efetiva
# (plan: car-risk-expansion, Inc 1). Roda via systemd timer diário.
#
# Chain: cruza alertas MapBiomas × polígonos CAR → area_efetiva.db (swap
# atômico) + marker de versão. Idempotente (o script Python decide via mtime;
# --force força). Após sucesso, exporta AREA_EFETIVA_VERSION do marker para o
# risk_precompute.current_version_key invalidar scores cacheados.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

MARKER="${AREA_EFETIVA_VERSION_FILE:-$PROJECT_DIR/backend-lua/data/area_efetiva/area_efetiva.version}"

echo "=== Area efetiva recompute ($(date -u +%FT%TZ)) ==="

if command -v python3 >/dev/null 2>&1; then
    ( cd "$PROJECT_DIR" && python3 scripts/data/compute_area_efetiva.py ) \
        || echo "  (compute_area_efetiva.py failed — see journal; continuing)"
else
    echo "  (python3 not available — skipping area efetiva recompute)"
fi

# Exporta a versão do marker (se existir) para o ambiente do serviço. O
# risk_precompute.current_version_key lê AREA_EFETIVA_VERSION via env; um
# recomputo muda o marker → invalida scores cacheados.
if [[ -f "$MARKER" ]]; then
    export AREA_EFETIVA_VERSION="$(cat "$MARKER" | tr -d '[:space:]')"
    echo "  AREA_EFETIVA_VERSION=$AREA_EFETIVA_VERSION"
fi

echo "=== Area efetiva recompute done ==="

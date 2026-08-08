#!/usr/bin/env bash
# sync-sinaflor.sh — gera o sinaflor_auth.db local (se velho/ausente), faz scp
# para produção e dispara a reclassificação com versão monotônica.
#
# Fonte: CKAN Ibama (dadosabertos.ibama.gov.br), datasets ASV + AUTESP.
# Fluxo (plan: sinaflor-fogo-permitido):
#   1. python3 scripts/data/download_sinaflor_auth.py  — re-baixa se o DB local
#      tiver mais de 7 dias (o próprio script decide via mtime; --force força).
#   2. scp backend-lua/data/sinaflor/sinaflor_auth.db -> VM:/opt/yvy/.../
#   3. Reclassificação com VERSÃO MONOTÔNICA: lê/incrementa .sync_version no
#      prod e passa ?version=N NA QUERY STRING — a rota POST /api/admin/fires/
#      classify só lê ctx.req.args.version (query; o body não é mergeado em
#      args, main.lua:167 / server.lua:102-110). Sem versão monotônica a
#      reclassificação semanal seria no-op (nature_version < N não reavalia
#      `suspeito` antigos que ganharam autorização nova).
#   4. Verifica classes.permitido em /api/fires/nature-stats.
#
# Uso: bash scripts/deploy/sync-sinaflor.sh [--vm-ip IP] [--force] [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

VM_IP=""
FORCE=false
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-ip) VM_IP="${2:-}"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

run() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

echo "=== Yvy sync-sinaflor ==="

# ── 1. Resolve VM_IP ─────────────────────────────────────────────────────────
if [[ -z "$VM_IP" ]]; then
  VM_IP="$(grep -E '^(VM_IP|PUBLIC_IP|INSTANCE_IP)=' "$PROJECT_DIR/.env" 2>/dev/null \
    | head -1 | cut -d= -f2- || true)"
fi
if [[ -z "$VM_IP" ]]; then
  echo "ERROR: VM_IP not provided (use --vm-ip IP or set VM_IP/PUBLIC_IP in .env)" >&2
  exit 1
fi
echo "VM_IP: $VM_IP"

# ── 2. Chave SSH (padrão deploy-local.sh) ───────────────────────────────────
SSH_KEY=""
for key in "$HOME/.ssh/oci_yvy" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ed25519"; do
  if [[ -f "$key" ]]; then
    SSH_KEY="$key"
    break
  fi
done
if [[ -z "$SSH_KEY" ]]; then
  echo "ERROR: no SSH key found in ~/.ssh/{oci_yvy,id_rsa,id_ed25519}" >&2
  exit 1
fi

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
VM_USER="ubuntu"
REMOTE_DIR="/opt/yvy/backend-lua/data/sinaflor"
DB="$PROJECT_DIR/backend-lua/data/sinaflor/sinaflor_auth.db"

# ── 3. (Re)gera o DB local se ausente, velho (>7d) ou --force ───────────────
PY_ARGS=()
if [[ "$FORCE" == true ]]; then PY_ARGS+=(--force); fi
if [[ "$DRY_RUN" == false || ! -f "$DB" ]]; then
  run python3 "$PROJECT_DIR/scripts/data/download_sinaflor_auth.py" "${PY_ARGS[@]}"
fi
if [[ ! -f "$DB" ]]; then
  echo "ERROR: $DB not generated — cannot sync" >&2
  exit 1
fi

# ── 4. scp do DB dedicado para prod (cria o dir remoto) ─────────────────────
run ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "mkdir -p $REMOTE_DIR"
run scp -i "$SSH_KEY" "$DB" "$VM_USER@$VM_IP:$REMOTE_DIR/"
echo "DB scp'd to $VM_USER@$VM_IP:$REMOTE_DIR/"

# ── 5. Versão monotônica (.sync_version no prod) ────────────────────────────
# Em --dry-run NADA de ssh real: simula REMOTE_VER=0 / API_KEY vazia.
if [[ "$DRY_RUN" == true ]]; then
  REMOTE_VER="0"
  API_KEY=""
else
  REMOTE_VER="$(ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" \
    "cat $REMOTE_DIR/.sync_version 2>/dev/null || echo 0" | tr -d '[:space:]')"
  # API_KEY vem do .env de PROD (fonte da verdade do auth do backend; o local
  # pode ter chave diferente). Vazio + AUTH_REQUIRED=0 → curl sem header ok.
  API_KEY="$(ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" \
    "grep -E '^API_KEY=' /opt/yvy/.env 2>/dev/null | head -1 | cut -d= -f2-" || true)"
fi
NEW_VER=$((REMOTE_VER + 1))
echo "sync_version: $REMOTE_VER -> $NEW_VER"
run ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "echo $NEW_VER > $REMOTE_DIR/.sync_version"
CURL_ARGS=(-s -X POST)
if [[ -n "$API_KEY" ]]; then
  CURL_ARGS+=(-H "X-API-Key: $API_KEY")
fi
CLASSIFY_URL="http://$VM_IP:5000/api/admin/fires/classify?version=$NEW_VER"
echo "Triggering reclassification: POST $CLASSIFY_URL"
if [[ "$DRY_RUN" == true ]]; then
  echo "[dry-run] curl -s -X POST [-H X-API-Key] $CLASSIFY_URL"
else
  curl "${CURL_ARGS[@]}" "$CLASSIFY_URL" || echo "WARN: classify trigger failed (DB já está no prod; re-run seguro)"
fi

# ── 7. Verificação ───────────────────────────────────────────────────────────
STATS_URL="http://$VM_IP:5000/api/fires/nature-stats"
echo "Verifying: $STATS_URL"
if [[ "$DRY_RUN" == true ]]; then
  echo "[dry-run] curl -s $STATS_URL | grep -o '\"permitido\":[0-9]*'"
else
  curl -s "${CURL_ARGS[@]}" "$STATS_URL" | grep -o '"permitido":[0-9]*' || \
    echo "WARN: could not read classes.permitido (reclassificação pode ainda estar rodando — subprocesso destacado)"
fi

echo "=== sync-sinaflor done ==="

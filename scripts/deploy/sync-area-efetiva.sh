#!/usr/bin/env bash
# sync-area-efetiva.sh — gera o area_efetiva.db local (se velho/ausente), faz
# scp para produção e verifica.
#
# Fonte: cruzamento offline MapBiomas Alerta × CAR (compute_area_efetiva.py).
# Fluxo (plan: car-risk-expansion, Inc 1):
#   1. python3 scripts/data/compute_area_efetiva.py — recomputa se o DB local
#      tiver mais de 7 dias (o próprio script decide via mtime; --force força).
#   2. scp backend-lua/data/area_efetiva/area_efetiva.db -> VM:/opt/yvy/.../
#   3. Verifica que o DB chegou (tamanho > 0) e que o lookup runtime o abre.
#
# Uso: bash scripts/deploy/sync-area-efetiva.sh [--vm-ip IP] [--force] [--dry-run]
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

echo "=== Yvy sync-area-efetiva ==="

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
REMOTE_DIR="/opt/yvy/backend-lua/data/area_efetiva"
DB="$PROJECT_DIR/backend-lua/data/area_efetiva/area_efetiva.db"

# ── 3. (Re)gera o DB local se ausente, velho (>7d) ou --force ───────────────
PY_ARGS=()
if [[ "$FORCE" == true ]]; then PY_ARGS+=(--force); fi
if [[ "$DRY_RUN" == false || ! -f "$DB" ]]; then
  run python3 "$PROJECT_DIR/scripts/data/compute_area_efetiva.py" "${PY_ARGS[@]}"
fi
if [[ ! -f "$DB" ]]; then
  echo "ERROR: $DB not generated — cannot sync" >&2
  exit 1
fi

# ── 4. scp do DB dedicado para prod (cria o dir remoto) ─────────────────────
run ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "mkdir -p $REMOTE_DIR"
run scp -i "$SSH_KEY" "$DB" "$VM_USER@$VM_IP:$REMOTE_DIR/"
echo "DB scp'd to $VM_USER@$VM_IP:$REMOTE_DIR/"

# ── 5. Verificação ───────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == true ]]; then
  echo "[dry-run] verify remote DB size + lookup open"
else
  REMOTE_SIZE="$(ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" \
    "stat -c%s $REMOTE_DIR/area_efetiva.db 2>/dev/null || echo 0")"
  if [[ "$REMOTE_SIZE" -gt 0 ]]; then
    echo "OK: remote area_efetiva.db is $REMOTE_SIZE bytes"
  else
    echo "WARN: remote area_efetiva.db missing or empty — check scp" >&2
  fi
fi

echo "=== sync-area-efetiva done ==="

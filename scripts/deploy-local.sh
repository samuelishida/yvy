#!/usr/bin/env bash
# Script local para deploy manual: Terraform + Ansible
# Uso: bash scripts/deploy-local.sh [--skip-tf] [--skip-ansible]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}🚀 Yvy Deploy Script${NC}"
echo "========================"

SKIP_TF=false
SKIP_ANSIBLE=false
for arg in "$@"; do
  case "$arg" in
    --skip-tf) SKIP_TF=true ;;
    --skip-ansible) SKIP_ANSIBLE=true ;;
  esac
done

# Verificar dependências
command -v terraform >/dev/null 2>&1 || { echo -e "${RED}❌ Terraform não encontrado${NC}"; exit 1; }
command -v ansible-playbook >/dev/null 2>&1 || { echo -e "${RED}❌ Ansible não encontrado${NC}"; exit 1; }

# Verificar .env
if [[ ! -f "$PROJECT_DIR/.env" ]]; then
  echo -e "${YELLOW}⚠️  .env não encontrado. Gerando...${NC}"
  bash "$PROJECT_DIR/scripts/generate-secrets.sh"
fi

# Detectar SSH key
SSH_KEY=""
for key in "$HOME/.ssh/oci_yvy" "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ed25519"; do
  if [[ -f "$key" ]]; then
    SSH_KEY="$key"
    break
  fi
done

if [[ -z "$SSH_KEY" ]]; then
  echo -e "${RED}❌ Nenhuma chave SSH encontrada em ~/.ssh/{oci_yvy,id_rsa,id_ed25519}${NC}"
  exit 1
fi
echo -e "${GREEN}🔑 Usando chave SSH: $SSH_KEY${NC}"

# Terraform
PUBLIC_IP=""
if [[ "$SKIP_TF" == false ]]; then
  echo -e "\n${GREEN}📦 Etapa 1/2: Terraform (Infraestrutura)${NC}"
  cd "$PROJECT_DIR/infra"

  if [[ ! -f "terraform.tfvars" ]]; then
    echo -e "${RED}❌ terraform.tfvars não encontrado!${NC}"
    echo "Copie terraform.tfvars.example e preencha seus valores OCI."
    exit 1
  fi

  terraform init
  terraform plan -out=tfplan
  read -p "Aplicar infraestrutura? [y/N] " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    terraform apply tfplan
  else
    echo -e "${YELLOW}⏭️  Pulando Terraform${NC}"
  fi

  PUBLIC_IP=$(terraform output -raw instance_public_ip 2>/dev/null || echo "")
  if [[ -z "$PUBLIC_IP" ]]; then
    echo -e "${RED}❌ Não foi possível obter o IP público. Verifique o Terraform.${NC}"
    exit 1
  fi
  echo -e "${GREEN}✅ VM criada: $PUBLIC_IP${NC}"
else
  echo -e "${YELLOW}⏭️  Pulando Terraform (--skip-tf)${NC}"
  # Tentar obter IP de VM existente
  PUBLIC_IP=$(terraform -chdir="$PROJECT_DIR/infra" output -raw instance_public_ip 2>/dev/null || echo "")
  if [[ -z "$PUBLIC_IP" ]]; then
    echo -e "${RED}❌ Não foi possível obter IP. Execute sem --skip-tf ou configure manualmente.${NC}"
    exit 1
  fi
  echo -e "${GREEN}✅ Usando VM existente: $PUBLIC_IP${NC}"
fi

# Aguardar cloud-init
echo -e "\n${YELLOW}⏳ Aguardando cloud-init na VM...${NC}"
for i in $(seq 1 30); do
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@"$PUBLIC_IP" "cloud-init status --wait 2>/dev/null; echo READY" 2>/dev/null | grep -q READY && break
  echo "  Tentativa $i/30..."
  sleep 10
done

# Ansible
if [[ "$SKIP_ANSIBLE" == false ]]; then
  echo -e "\n${GREEN}🎻 Etapa 2/2: Ansible (Aplicação)${NC}"
  cd "$PROJECT_DIR/ansible"

  cat > inventory.ini <<EOF
[yvy]
$PUBLIC_IP ansible_user=ubuntu ansible_ssh_private_key_file=$SSH_KEY
EOF

  read -p "Executar Ansible deploy? [y/N] " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    ansible-playbook -i inventory.ini playbook.yml -v
    echo -e "\n${GREEN}🌐 Yvy (baremetal) disponível em: http://$PUBLIC_IP:5001${NC}"
  else
    echo -e "${YELLOW}⏭️  Pulando Ansible${NC}"
  fi
else
  echo -e "${YELLOW}⏭️  Pulando Ansible (--skip-ansible)${NC}"
fi

echo -e "\n${GREEN}✨ Deploy completo!${NC}"

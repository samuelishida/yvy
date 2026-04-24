#!/usr/bin/env bash
# Script local para deploy manual: Terraform + Ansible
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🚀 Yvy Deploy Script${NC}"
echo "========================"

# Verificar dependências
command -v terraform >/devdev/null 2>&1 || { echo -e "${RED}❌ Terraform não encontrado${NC}"; exit 1; }
command -v ansible-playbook >/dev/null 2>&1 || { echo -e "${RED}❌ Ansible não encontrado${NC}"; exit 1; }

# Verificar .env
if [[ ! -f "$PROJECT_DIR/.env" ]]; then
  echo -e "${YELLOW}⚠️  .env não encontrado. Gerando...${NC}"
  bash "$PROJECT_DIR/scripts/generate-secrets.sh"
fi

# Terraform
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

# Extrair IP
PUBLIC_IP=$(terraform output -raw instance_public_ip 2>/dev/null || echo "")
if [[ -z "$PUBLIC_IP" ]]; then
  echo -e "${RED}❌ Não foi possível obter o IP público. Verifique o Terraform.${NC}"
  exit 1
fi

echo -e "${GREEN}✅ VM criada: $PUBLIC_IP${NC}"

# Ansible
echo -e "\n${GREEN}🎻 Etapa 2/2: Ansible (Aplicação)${NC}"
cd "$PROJECT_DIR/ansible"

# Criar inventory dinâmico
cat > inventory.ini <<EOF
[yvy]
$PUBLIC_IP ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_rsa
EOF

read -p "Executar Ansible deploy? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  ansible-playbook -i inventory.ini playbook.yml
  echo -e "\n${GREEN}🌐 Yvy disponível em: http://$PUBLIC_IP:5001${NC}"
else
  echo -e "${YELLOW}⏭️  Pulando Ansible${NC}"
fi

echo -e "\n${GREEN}✨ Deploy completo!${NC}"

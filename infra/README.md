# 🚀 Deploy Yvy na OCI Always Free

Este diretório contém toda a infraestrutura como código (IaC) para subir o Yvy na **Oracle Cloud Infrastructure (OCI) Always Free** usando **Terraform** + **Ansible** em modo **baremetal (sem Docker)**.

---

## 📁 Estrutura

```
infra/
├── provider.tf              # Provider OCI
├── variables.tf             # Variáveis Terraform
├── main.tf                  # VM, VCN, Security List
├── outputs.tf               # IPs e comandos úteis
├── cloud-init.yml           # Setup inicial da VM (runtime baremetal, UFW)
└── terraform.tfvars.example # Template de credenciais

ansible/
├── inventory.oci.yml        # Dynamic inventory OCI
├── playbook.yml             # Deploy da aplicação
└── templates/
    ├── yvy-backend.service.j2
    └── yvy-frontend.service.j2

scripts/
├── generate-secrets.sh      # Gera .env com secrets aleatórios
└── deploy-local.sh          # Deploy manual local (Terraform + Ansible)
```

---

## 🔑 Pré-requisitos

### 1. Conta OCI Always Free

1. Acesse [oracle.com/cloud/free](https://www.oracle.com/cloud/free/)
2. Crie a conta com cartão de crédito (apenas validação, não cobra)
3. Anote: **Tenancy OCID**, **User OCID**

### 2. API Key OCI

1. Console OCI → **Identity → Users → seu usuário → API Keys → Add API Key**
2. Escolha **"Generate API Key Pair"** → baixe a chave privada
3. Anote o **Fingerprint** exibido
4. Salve a chave privada em `~/.oci/oci_api_key.pem`

### 3. Par de chaves SSH

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/oci_yvy -N ""
# ~/.ssh/oci_yvy.pub será usada no terraform.tfvars
```

### 4. Ferramentas locais

```bash
# Terraform
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform

# Ansible
pip install ansible
ansible-galaxy collection install oracle.oci
```

---

## ⚙️ Configuração

### 1. Preencher credenciais

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars
```

Preencha com seus valores:

```hcl
tenancy_ocid         = "ocid1.tenancy.oc1..xxxxxxxx"
user_ocid            = "ocid1.user.oc1..xxxxxxxx"
fingerprint          = "aa:bb:cc:dd:ee:ff:00:11"
private_key_path     = "~/.oci/oci_api_key.pem"
region               = "sa-saopaulo-1"
compartment_ocid     = "ocid1.tenancy.oc1..xxxxxxxx"
ssh_public_key_path  = "~/.ssh/oci_yvy.pub"
```

### 2. (Opcional) Ajustar inventory do Ansible

```bash
cd ../ansible
nano inventory.oci.yml
```

Atualize o `compartment_ocid` para corresponder ao seu.

---

## 🚀 Deploy Manual

### Opção A: OCI CLI

Deploy direto na VM OCI existente usando OCI CLI local. Não precisa de Terraform nem Ansible.

```bash
# 0. Variáveis
SSH_KEY=~/.ssh/oci_yvy
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SSH="ssh -i $SSH_KEY $SSH_OPTS ubuntu@<IP_DA_VM>"

# 1. Add swap (VM 1GB precisa para npm build)
$SSH "sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile \
  && sudo mkswap /swapfile && sudo swapon /swapfile \
  && echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab"

# 2. Instalar deps de runtime
$SSH "sudo apt-get update && sudo apt-get install -y git python3 python3-venv python3-pip redis-server sqlite3"

# 3. Instalar Node 18 via nvm (Node 12 do sistema é velho demais para react-scripts 5)
$SSH 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'
$SSH 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && nvm install 18'

# 4. Clonar/atualizar repo
$SSH "if [ -d /opt/yvy ]; then cd /opt/yvy && git pull; \
  else sudo mkdir -p /opt/yvy && sudo chown ubuntu:ubuntu /opt/yvy \
  && git clone https://github.com/samuelishida/yvy.git /opt/yvy; fi"

# 5. Gerar .env (apenas se não existir)
$SSH "cd /opt/yvy && bash scripts/generate-secrets.sh"
# Corrigir CORS_ORIGINS com IP público:
$SSH "sed -i 's|CORS_ORIGINS=.*|CORS_ORIGINS=http://<IP_DA_VM>:5001,http://localhost:5001|' /opt/yvy/.env"

# 6. Setup backend (venv + deps)
$SSH "cd /opt/yvy && bash scripts/setup-local.sh"

# 7. Instalar deps frontend com Node 18
$SSH 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" \
  && cd /opt/yvy/frontend && rm -rf node_modules package-lock.json && npm install'

# 8. Criar serviços systemd
$SSH 'sudo tee /etc/systemd/system/yvy-backend.service > /dev/null << EOF
[Unit]
Description=Yvy Backend Service
After=network.target redis-server.service
Wants=redis-server.service

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/opt/yvy
Environment=HOME=/home/ubuntu
Environment=YVY_LOCAL_DEV=0
ExecStart=/usr/bin/bash /opt/yvy/scripts/run-backend.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF'

$SSH 'sudo tee /etc/systemd/system/yvy-frontend.service > /dev/null << EOF
[Unit]
Description=Yvy Frontend Service
After=network.target yvy-backend.service
Wants=yvy-backend.service

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/opt/yvy
Environment=HOME=/home/ubuntu
Environment=YVY_LOCAL_DEV=1
Environment=PORT=5001
Environment=BROWSER=none
Environment=PATH=/home/ubuntu/.nvm/versions/node/v18.20.8/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/bin/bash /opt/yvy/scripts/run-frontend.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF'

# 9. Iniciar serviços
$SSH "sudo systemctl daemon-reload && sudo systemctl enable yvy-backend yvy-frontend \
  && sudo systemctl start yvy-backend && sleep 3 \
  && sudo systemctl start yvy-frontend"

# 10. Verificar
curl -s http://<IP_DA_VM>:5000/ | head -1   # backend
curl -s -o /dev/null -w '%{http_code}' http://<IP_DA_VM>:5001/  # frontend (200 = OK)
```

### Opção B: Terraform + Ansible

```bash
cd scripts
bash deploy-local.sh
```

O script executa:
1. **Terraform**: Cria VM, VCN, Security List
2. **Ansible**: Instala app, cria serviços systemd (backend/frontend), health checks

Ao final, exibe a URL de acesso.

### Notas importantes para deploy

- **Node 12 é velho demais** para react-scripts 5. Use nvm para instalar Node 18 na VM.
- **VMs com 1GB RAM** precisam de swap (2GB) para npm install e webpack.
- **Frontend roda em modo DEV** (`YVY_LOCAL_DEV=1`) na VM porque o build de produção exige mais RAM.
- **Backend usa `run-backend.sh`** que carrega o `.env` antes de iniciar o hypercorn.
- **CORS_ORIGINS** deve incluir o IP público da VM para acesso via browser.

---

## 🔄 Deploy Automático (GitHub Actions)

### Secrets necessários no GitHub

Vá em **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Descrição | Como obter |
|--------|-----------|------------|
| `OCI_TENANCY_OCID` | OCID da tenancy | Console → Tenancy Details |
| `OCI_USER_OCID` | OCID do usuário | Console → User Details |
| `OCI_FINGERPRINT` | Fingerprint da API Key | Console → API Keys |
| `OCI_PRIVATE_KEY` | Conteúdo da chave privada `oci_api_key.pem` | `cat ~/.oci/oci_api_key.pem` |
| `OCI_REGION` | Região (ex: `sa-saopaulo-1`) | — |
| `OCI_COMPARTMENT_OCID` | OCID do compartment | Geralmente igual ao tenancy_ocid |
| `OCI_SSH_PUBLIC_KEY` | Conteúdo de `~/.ssh/oci_yvy.pub` | `cat ~/.ssh/oci_yvy.pub` |
| `OCI_SSH_PRIVATE_KEY` | Conteúdo de `~/.ssh/oci_yvy` | `cat ~/.ssh/oci_yvy` |

### Trigger do deploy

O deploy automático é acionado em:
- **Push** na branch `main` ou `master`
- **Manual** via `Actions → Deploy to OCI → Run workflow`

### Fluxo do workflow

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│   Push to   │────▶│  Terraform   │────▶│   Ansible   │
│    main     │     │  (VM + VCN)  │     │  (App + DB) │
└─────────────┘     └──────────────┘     └─────────────┘
                           │                      │
                           ▼                      ▼
                    IP público OCI          Health check
                    salvo no output         na porta 5001
```

---

## 🌐 Acesso pós-deploy

```
http://<IP_PUBLICO_OCI>:5001
```

O IP é exibido no output do Terraform e no log do GitHub Actions.

---

## 🛠️ Comandos úteis

### SSH na VM
```bash
ssh -i ~/.ssh/oci_yvy ubuntu@<IP_PUBLICO>
```

### Logs da aplicação
```bash
journalctl -u yvy-backend -f
journalctl -u yvy-frontend -f
```

### Restart
```bash
sudo systemctl restart yvy-backend yvy-frontend
```

### Backup manual
```bash
cd /opt/yvy && bash backup.sh
```

### Atualizar app (nova versão)
```bash
cd /opt/yvy
git pull
bash scripts/setup-local.sh
# Reinstalar deps do frontend se necessário:
export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
cd frontend && rm -rf node_modules package-lock.json && npm install
sudo systemctl restart yvy-backend yvy-frontend
```

---

## 💰 Custos

| Recurso | Tier | Custo |
|---------|------|-------|
| VM ARM 4 OCPU / 24 GB | Always Free | **$0** |
| Boot Volume 100 GB | Always Free | **$0** |
| VCN + Subnet + IGW | Always Free | **$0** |
| Banda de saída | 10 TB/mês | **$0** |

> ⚠️ **Atenção:** Nunca exceda os limites do Always Free (ex: criar mais de 1 VM ARM ou volume > 200 GB).

---

## 🧹 Destruir infraestrutura

```bash
cd infra
terraform destroy
```

Isso remove **tudo** (VM, VCN, regras de firewall). Os dados locais serão perdidos se não houver backup.

---

## 📚 Documentação relacionada

- [OCI Always Free](https://www.oracle.com/cloud/free/)
- [Terraform OCI Provider](https://registry.terraform.io/providers/oracle/oci/latest/docs)
- [Ansible OCI Collection](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/ansible.htm)

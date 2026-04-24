# 🚀 Deploy Yvy na OCI Always Free

Este diretório contém toda a infraestrutura como código (IaC) para subir o Yvy na **Oracle Cloud Infrastructure (OCI) Always Free** usando **Terraform** + **Ansible**.

---

## 📁 Estrutura

```
infra/
├── provider.tf              # Provider OCI
├── variables.tf             # Variáveis Terraform
├── main.tf                  # VM, VCN, Security List
├── outputs.tf               # IPs e comandos úteis
├── cloud-init.yml           # Setup inicial da VM (Docker, UFW)
└── terraform.tfvars.example # Template de credenciais

ansible/
├── inventory.oci.yml        # Dynamic inventory OCI
├── playbook.yml             # Deploy da aplicação
└── templates/
    └── docker-compose.prod.yml.j2  # Override de produção

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

## 🚀 Deploy Manual (Local)

```bash
cd scripts
bash deploy-local.sh
```

O script executa:
1. **Terraform**: Cria VM, VCN, Security List
2. **Ansible**: Instala app, Docker Compose up, health checks

Ao final, exibe a URL de acesso.

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
cd /opt/yvy
docker compose -f docker-compose.yml -f docker-compose.prod.yml logs -f
```

### Restart
```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml restart
```

### Backup manual
```bash
cd /opt/yvy && bash backup.sh
```

### Atualizar app (nova versão)
```bash
cd /opt/yvy
git pull
docker compose -f docker-compose.yml -f docker-compose.prod.yml up --build -d
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

Isso remove **tudo** (VM, VCN, regras de firewall). Os dados no MongoDB serão perdidos se não houver backup.

---

## 📚 Documentação relacionada

- [OCI Always Free](https://www.oracle.com/cloud/free/)
- [Terraform OCI Provider](https://registry.terraform.io/providers/oracle/oci/latest/docs)
- [Ansible OCI Collection](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/ansible.htm)

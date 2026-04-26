# Yvy

Observabilidade ambiental para monitorar desmatamento e queimadas no Brasil.

**Produção**: https://yvy.app.br/

Stack atual:
- **Frontend**: React 18 + Express (proxy server-side) + Tailwind CSS + Leaflet
- **Backend**: Quart + Hypercorn (async ASGI)
- **Banco principal**: SQLite (aiosqlite, WAL mode, connection pool)
- **Cache/rate limit**: Redis (redis.asyncio, fallback in-memory)
- **Dados geoespaciais**: TerraBrasilis (PRODES) e NASA FIRMS
- **Notícias**: NewsAPI + MyMemory/LibreTranslate/Google Translate chain
- **Deploy**: OCI baremetal via Terraform + Ansible

## Requisitos

- Linux, macOS ou Windows (MINGW/MSYS)
- Python 3.11+
- Node.js 18+
- Redis local ativo (padrão: `redis://localhost:6379/0`)
- Git

## Setup local

```bash
cp .env.example .env
make setup
```

`make setup` faz:
- cria venv Python em `$HOME/.local/share/yvy-venv` (fallback para FS sem symlink)
- instala deps backend (`backend/requirements.txt`)
- instala deps frontend (`frontend/package.json`)

## Run local

Subir tudo:

```bash
make run
```

Subir separado:

```bash
make backend
make frontend
```

Parar processos locais:

```bash
make stop
```

URLs:
- **Produção**: https://yvy.app.br/
- **Local**:
  - Frontend: http://127.0.0.1:5001
  - Backend: http://127.0.0.1:5000

## Comandos Make

| Comando | Descrição |
|---------|-----------|
| `make setup` | Instala dependências locais |
| `make run` | Sobe backend + frontend |
| `make backend` | Sobe só o backend |
| `make frontend` | Sobe só o frontend |
| `make stop` | Mata processos locais em background + portas 5000/5001 |
| `make test` | Roda `test_sqlite_manual.py` (valida schema + queries) |
| `make sqlite-access` | Abre `.tables` do banco SQLite |

## Ingestão de dados

Não roda automaticamente no `make run`.

```bash
cd backend
python ingest_sqlite.py
```

## Endpoints da API

| Método | Rota | Auth | Descrição |
|--------|------|------|-----------|
| GET | `/health` | Não | Health check do frontend |
| GET | `/api/health` | Não | Health check do backend |
| GET | `/api/data` | Sim | Dados PRODES (bbox query) |
| GET | `/api/fires` | Sim | Focos de calor NASA FIRMS (bbox query) |
| POST | `/api/fires/sync` | Sim | Gatilho manual de sync FIRMS |
| POST | `/api/admin/firms/sync` | Sim | Sync FIRMS (admin) |
| GET | `/api/news` | Sim | Notícias paginadas (page, lang) |
| POST | `/api/news/refresh` | Opcional | Força refresh de notícias |
| POST | `/api/news/repair` | Sim | Re-tradutor de traduções corrompidas |
| GET | `/api/weather/air-quality` | Sim | Qualidade do ar (WAQI) |
| GET | `/api/weather/temperature` | Sim | Temperatura (Open-Meteo) |
| GET | `/api/stats` | Sim | Contagens de registros no DB |

## API Key

Quando `AUTH_REQUIRED=1`, o backend exige `X-API-Key` em rotas protegidas.
O frontend injeta a chave server-side via Express proxy — o navegador nunca vê a chave.

Exemplo de chamada direta ao backend:

```bash
curl "http://127.0.0.1:5000/api/data?ne_lat=-10&ne_lng=-34&sw_lat=-34&sw_lng=-74" \
  -H "X-API-Key: $API_KEY"
```

## Arquitetura

```text
Browser :5001
    │
    ▼
Express (server.js) — serve React build, proxy /api/*
    │  injeta X-API-Key server-side
    ▼
Quart (backend.py) — async routes on :5000
    │  hypercorn + asyncio workers
    ├──► SQLite (aiosqlite) — pool de 5 conexões, WAL mode
    │     ├── fire_data (NASA FIRMS)
    │     ├── deforestation_data (TerraBrasilis PRODES)
    │     └── news (artigos com tradução PT/EN)
    ├──► Redis (redis.asyncio) — rate limiting + cache
    │     └── fallback: deque in-memory por IP
    ├──► NewsAPI — sync background a cada 15 min
    │     └── MyMemory → LibreTranslate → Google Translate
    └──► NASA FIRMS API — sync background a cada 4h
          └── CSV download → bulk upsert
```

## Segurança

- **Autenticação**: X-API-Key ou Bearer token, comparação em tempo constante (`compare_digest`)
- **Rate limiting**: 60 req/min por IP (configurável), Redis + fallback in-memory
- **CSP**: Restritivo — apenas self, OSM tiles, CDN Bootstrap/jsDelivr/unpkg
- **CORS**: Baseado em whitelist via `CORS_ORIGINS`
- **Proxy**: API key injetada server-side pelo Express — nunca exposta ao browser
- **Headers de segurança**: X-Content-Type-Options, X-Frame-Options, Permissions-Policy

## Testes

Teste rápido via Make:

```bash
make test
```

Suite pytest (requer venv ativado):

```bash
cd backend
source $HOME/.local/share/yvy-venv/bin/activate  # ou .venv
pip install pytest pytest-asyncio
pytest -v
```

CI:
- `.github/workflows/ci.yml` — validação de sintaxe Python + shell
- `.gitlab-ci.yml`

> **Nota:** `tests/test_api.py` está obsoleto (usa mongomock). Use `test_db_sqlite.py` (pytest) ou `test_sqlite_manual.py` (manual).

## Deploy OCI (baremetal)

Deploy via **OCI CLI + Ansible** em VM existente (sem Terraform — evita limites do Always Free).

**Produção**: https://yvy.app.br/ (HTTPS com Let's Encrypt SSL)

### Fluxo GitHub Actions

1. **OCI CLI** descobre VM `yvy-server` em execução
2. **Ansible** aplica setup da aplicação e serviços systemd
3. **Nginx + SSL** configura reverse proxy com HTTPS
4. **Health check** valida backend + frontend

### Deploy rápido via OCI CLI (VM existente)

```bash
# 1. Configure variáveis
INSTANCE_ID=$(oci compute instance list -c $TENANCY_OCID --lifecycle-state RUNNING \
  --query 'data[?"display-name"==`yvy-server`][0].id' --raw-output)
VM_IP=$(oci network vnic get --vnic-id \
  "$(oci compute vnic-attachment list -c $TENANCY_OCID --instance-id "$INSTANCE_ID" \
    --query 'data[0]."vnic-id"' --raw-output)" \
  --query 'data."public-ip"' --raw-output)
SSH="ssh -i ~/.ssh/oci_yvy -o StrictHostKeyChecking=no ubuntu@$VM_IP"

# 2. Clone/atualize o repositório
$SSH "if [ -d /opt/yvy ]; then cd /opt/yvy && sudo git pull; \
  else sudo mkdir -p /opt/yvy && sudo chown ubuntu:ubuntu /opt/yvy \
  && git clone https://github.com/samuelishida/yvy.git /opt/yvy; fi"

# 3. Gere .env e configure CORS
$SSH "cd /opt/yvy && bash scripts/generate-secrets.sh"
$SSH "sed -i 's|CORS_ORIGINS=.*|CORS_ORIGINS=http://$VM_IP:5001,http://localhost:5001|' /opt/yvy/.env"

# 4. Setup backend (venv + deps)
$SSH "cd /opt/yvy && bash scripts/setup-local.sh"

# 5. Instale deps do frontend
$SSH 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" \
  && cd /opt/yvy/frontend && rm -rf node_modules package-lock.json && npm install'

# 6. Crie e inicie serviços systemd
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

$SSH "sudo systemctl daemon-reload && sudo systemctl enable yvy-backend \
  && sudo systemctl restart yvy-backend && sleep 3"

# 7. Instale e configure nginx + SSL
$SSH 'sudo apt-get update && sudo apt-get install -y nginx certbot python3-certbot-nginx'
$SSH 'sudo mkdir -p /var/www/certbot && sudo chown -R www-data:www-data /var/www/certbot'
$SSH "sudo bash /opt/yvy/scripts/deploy-nginx.sh"

# 8. Verifique
curl -s http://$VM_IP:5000/health
curl -s -o /dev/null -w '%{http_code}' https://$VM_IP/ --insecure
```

### Deploy via GitHub Actions (automático)

O workflow `.github/workflows/deploy-oci.yml` é acionado em push para `main`/`master`:
1. Instala OCI CLI + Ansible no runner
2. Descobre a VM `yvy-server` em execução via OCI CLI
3. Aguarda cloud-init concluir
4. Executa Ansible playbook
5. Valida health check

**Secrets necessários no GitHub** (Settings → Secrets and variables → Actions):

| Secret | Descrição |
|--------|-----------|
| `OCI_TENANCY_OCID` | OCID da tenancy |
| `OCI_USER_OCID` | OCID do usuário |
| `OCI_FINGERPRINT` | Fingerprint da API Key |
| `OCI_PRIVATE_KEY` | Conteúdo da chave privada `oci_api_key.pem` |
| `OCI_REGION` | Região (ex: `sa-saopaulo-1`) |
| `OCI_COMPARTMENT_OCID` | OCID do compartment (opcional, usa tenancy se vazio) |
| `OCI_SSH_PRIVATE_KEY` | Conteúdo de `~/.ssh/oci_yvy` |

### Terraform (infraestrutura inicial)

Use Terraform **apenas na primeira vez** para criar a VM:

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# Preencha com seus valores OCI
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Após a VM criada, todos os deploys subsequentes usam OCI CLI + Ansible.

### Arquivos de referência

- `infra/README.md` — Guia completo de infraestrutura
- `infra/main.tf` — Recursos OCI (VCN, subnet, VM)
- `ansible/playbook.yml` — Playbook de deploy
- `.github/workflows/deploy-oci.yml` — CD via GitHub Actions

## Variáveis de ambiente principais

| Variável | Padrão | Descrição |
|----------|--------|-----------|
| `API_KEY` | vazio | Chave de autenticação da API |
| `AUTH_REQUIRED` | `0` | `1` para exigir API key em produção |
| `CORS_ORIGINS` | `http://localhost:5001,...` | Origens permitidas para CORS |
| `LOG_LEVEL` | `INFO` | Nível de log (DEBUG, INFO, WARNING, ERROR) |
| `SQLITE_PATH` | `backend/data/yvy.db` | Caminho do banco SQLite |
| `REDIS_URL` | `redis://localhost:6379/0` | Conexão Redis |
| `BACKEND_URL` | `http://127.0.0.1:5000` | URL do backend para o proxy |
| `RATE_LIMIT_REQUESTS` | `60` | Requisições máximas por janela |
| `RATE_LIMIT_WINDOW_SECONDS` | `60` | Janela de rate limiting (segundos) |
| `DEV` | `0` | `1` ativa servidor dev do Quart |
| `FIRMS_MAP_KEY` | vazio | Chave da API NASA FIRMS |
| `NEWS_API_KEY` | vazio | Chave da NewsAPI |
| `WAQI_TOKEN` | vazio | Token do World Air Quality Index |
| `TRUSTED_PROXIES` | vazio | CIDRs de proxies confiáveis |

> Use `.env.example` como base (nota: ainda contém variáveis MongoDB legadas — ignore-as).

## Troubleshooting rápido

- **Porta ocupada (5000/5001)**: rode `make stop`, depois `make run`
- **Trace no shutdown com `RuntimeError: reentrant call inside _io.BufferedWriter.__repr__`**:
  interrompa com `Ctrl+C`, rode `make stop`, suba de novo com `make run`
- **Redis indisponível**: backend funciona sem Redis — rate limiting usa fallback in-memory, cache é desabilitado
- **FIRMS sem dados**: verifique se `FIRMS_MAP_KEY` está configurado no `.env`

## Backup

```bash
./backup.sh
```

Saída padrão: `sqlite_backups/`

## Operação

- `RUNBOOK.md` — Runbook de operações
- `AGENTS.md` — Guia rápido para agentes de IA
- `.github/workflows/GITHUB_SECRETS.md` — Configuração de secrets

## Licença

MIT. Veja `LICENSE`.

## Contato

Samuel Ishida:
- GitHub: https://github.com/samuelishida
- GitLab: https://gitlab.com/samuelishida

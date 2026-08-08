# Yvy

Observabilidade ambiental para monitorar desmatamento e queimadas no Brasil.

**Produção**: https://yvy.app.br/

Stack atual:
- **Frontend**: React 18 + C HTTP server (static files + API proxy) + Tailwind CSS + Leaflet
- **Backend**: Lua 5.1 (business logic, SQLite, Redis)
- **Banco principal**: SQLite (lsqlite3, WAL mode, pool de conexões, colunas JSONB BLOB)
- **Versão SQLite**: lsqlite3 (SQLite 5.1) — bindings nativos para Lua
- **Cache/rate limit**: Redis (redis.asyncio via LuaSocket, fallback in-memory)
- **Dados geoespaciais**: TerraBrasilis (PRODES) e NASA FIRMS
- **Notícias**: NewsAPI + MyMemory/LibreTranslate/Google Translate chain
- **Deploy**: OCI baremetal via Terraform + Ansible

## Requisitos

- Linux, macOS ou Windows (MINGW/MSYS)
- Lua 5.1+
- Node.js 18+ (apenas para build do frontend)
- Redis local ativo (padrão: `redis://localhost:6379/0`)
- Git
- GCC (para compilar C server)

## Setup local

```bash
cp .env.example .env
make setup
```

`make setup` faz:
- instala deps Lua (`luasocket`, `lsqlite3`, `lua-cjson`, `copas`)
- instala deps frontend (`frontend/package.json`)
- compila C server (`frontend/yvy-server.exe`)

## Run local

Subir tudo:

```bash
cd scripts\dev
.\start-lua-stack.ps1
```

Subir separado:

```bash
.\run-lua-backend.ps1    # só backend Lua
.\run-c-frontend.ps1      # só frontend C
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
| `make setup-lua` | Instala dependências Lua |
| `make run-lua` | Sobe só o backend |
| `make stop` | Para processos locais em background + portas 5000/5001 |
| `make test-lua` | Roda a suíte de testes Lua (busted) |
| `make migrate-lua` | Migra banco de flat-column para JSONB schema |
| `make sqlite-access` | Abre `.tables` do banco SQLite |

## Ingestão de dados

Não roda automaticamente no `make run`.

```bash
cd backend-lua
lua5.1 -e 'package.path="./?.lua;./?/init.lua;"..package.path; require("app.env"); require("app.db").init_db(); require("app.ingest").run()'
```

## Endpoints da API

| Método | Rota | Auth | Descrição |
|--------|------|------|-----------|
| GET | `/health` | Não | Health check do frontend (C server) |
| GET | `/api/health` | Não | Health check do backend Lua |
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
| GET | `/api/alerts` | Sim | Geração de alertas |
| GET | `/api/biomes` | Sim | Classificação de biomas |

## API Key

Quando `AUTH_REQUIRED=1`, o backend exige `X-API-Key` em rotas protegidas.
O frontend injeta a chave server-side via C server proxy — o navegador nunca vê a chave.

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
C Server (yvy-server.exe) — serve React build, proxy /api/*
    │  injeta X-API-Key server-side
    ▼
Lua Backend (main.lua) — async routes on :5000
    │  lsqlite3 + copas workers
    ├──► SQLite (lsqlite3) — pool de 3 conexões, WAL mode
    │     ├── fire_data (NASA FIRMS)
    │     │     escalar: lat, lon, acq_date, ingested_at
    │     │     JSONB:  confidence, acq_time, satellite, bright_ti4, source
    │     ├── deforestation_data (TerraBrasilis PRODES)
    │     │     escalar: lat, lon
    │     │     JSONB:  name, clazz, periods, source, color, timestamp
    │     └── news (artigos com tradução PT/EN)
    │           escalar: url, publishedAt, ingested_at
    │           JSONB:  title, description, title_en, description_en, source_name, urlToImage, content
    ├──► Redis (lua-redis) — rate limiting + cache
    │     └── fallback: table in-memory por IP
    ├──► NewsAPI — sync background a cada 15 min
    │     └── MyMemory → LibreTranslate → Google Translate
    └──► NASA FIRMS API — sync background a cada 4h
          └── CSV download → bulk upsert
```

### JSONB Schema

O banco usa um modelo híbrido: colunas escalares para campos indexados + coluna `data BLOB` (JSONB binário) para campos flexíveis. Isso combina a performance de queries indexadas com a flexibilidade de schema do JSON.

**Vantagens do JSONB no SQLite (≥ 3.45.0):**
- Armazenamento binário ~5-10% menor que JSON texto
- `json_extract()` mais rápido em formato binário
- `jsonb(?)` converte texto → binário no INSERT
- `json(data)` converte binário → texto no SELECT

**Expression indexes em campos JSONB:**
- `idx_fire_confidence` em `json_extract(data, '$.confidence')`
- `idx_def_name` em `json_extract(data, '$.name')`
- `idx_news_source` em `json_extract(data, '$.source_name')`

**⚠️ Importante:** O formato JSONB binário **não é UTF-8 válido**. Sempre use `json(data)` em queries SQL para ler, e `jsonb(?)` para escrever. Nunca faça `json.loads()` direto no BLOB.

### Migração JSONB

Para migrar um banco existente do schema flat-column para JSONB:

```bash
# Via Make
make migrate

# Ou direto
cd backend-lua
lua5.1 app/migrate.lua
```

O script de migração:
1. Cria backup automático do banco
2. Detecta schema legado (colunas como `confidence` em `fire_data`)
3. Cria novas tabelas JSONB, copia dados usando `jsonb()`
4. Troca tabelas e recria indexes (incluindo expression indexes)
5. Roda VACUUM para recuperar espaço

O app também auto-migra na inicialização se detectar schema legado.

**Nota sobre SQLite antigo:** Em sistemas com SQLite < 3.45.0 (ex: Ubuntu 22.04 com SQLite 3.37.2), o `lsqlite3` (requerimento Lua) fornece SQLite 5.1 com suporte completo a JSONB.

## Segurança

- **Autenticação**: X-API-Key ou Bearer token, comparação em tempo constante (`string.compare`)
- **Rate limiting**: 60 req/min por IP (configurável), Redis + fallback in-memory
- **CSP**: Restritivo — apenas self, OSM tiles, CDN Bootstrap/jsDelivr/unpkg
- **CORS**: Baseado em whitelist via `CORS_ORIGINS`
- **Proxy**: API key injetada server-side pelo C server — nunca exposta ao navegador
- **Headers de segurança**: X-Content-Type-Options, X-Frame-Options, Permissions-Policy

## Testes

Teste rápido:

```bash
cd backend-lua
busted --verbose tests/*.lua
```

Suite Lua:

```bash
cd backend-lua
busted --verbose tests/test_db.lua tests/test_geo.lua
```

CI:
- `.github/workflows/ci.yml` — validação de sintaxe Lua + shell
- `.gitlab-ci.yml`

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
$SSH "cd /opt/yvy && bash scripts/deploy/generate-secrets.sh"
$SSH "sed -i 's|CORS_ORIGINS=.*|CORS_ORIGINS=http://$VM_IP:5001,http://localhost:5001|' /opt/yvy/.env"

# 4. Setup Lua backend
$SSH "cd /opt/yvy && bash scripts/dev/setup-lua.sh"

# 5. Instale/build frontend
$SSH 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" \
  && cd /opt/yvy/frontend && npm ci && npm run build'

# 6. Crie e inicie serviços systemd
$SSH 'sudo tee /etc/systemd/system/yvy-backend.service > /dev/null << EOF
[Unit]
Description=Yvy Lua Backend Service
After=network.target redis-server.service
Wants=redis-server.service
[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/opt/yvy
Environment=HOME=/home/ubuntu
Environment=PORT=5000
Environment=SQLITE_PATH=/opt/yvy/backend-lua/data/yvy.db
Environment=REDIS_URL=redis://localhost:6379/0
ExecStart=/usr/bin/bash /opt/yvy/scripts/dev/run-lua.sh
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF'

$SSH 'sudo tee /etc/systemd/system/yvy-frontend.service > /dev/null << EOF
[Unit]
Description=Yvy C Frontend Service
After=yvy-backend.service
[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/opt/yvy
Environment=HOME=/home/ubuntu
Environment=PORT=5001
Environment=STATIC_DIR=/opt/yvy/frontend/build
Environment=BACKEND_URL=http://127.0.0.1:5000
ExecStart=/opt/yvy/frontend/yvy-server
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF'

$SSH "sudo systemctl daemon-reload && sudo systemctl enable yvy-backend yvy-frontend \
  && sudo systemctl start yvy-backend && sleep 3 \
  && sudo systemctl start yvy-frontend"

# 7. Instale e configure nginx + SSL
$SSH 'sudo apt-get update && sudo apt-get install -y nginx certbot python3-certbot-nginx'
$SSH 'sudo mkdir -p /var/www/certbot && sudo chown -R www-data:www-data /var/www/certbot'
$SSH "sudo bash /opt/yvy/scripts/deploy/deploy-nginx.sh"

# 8. Verifique
curl -s http://$VM_IP:5000/health
curl -s -o /dev/null -w '%{http_code}' https://$VM_IP/ --insecure
```

### Deploy via GitHub Actions (automático)

O workflow `.github/workflows/deploy-oci.yml` é acionado em push para `main`/`master`:
1. Instala Lua 5.1 + lsqlite3 no runner
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
| `SQLITE_PATH` | `backend-lua/data/yvy.db` | Caminho do banco SQLite (JSONB, WAL mode) |
| `REDIS_URL` | `redis://localhost:6379/0` | Conexão Redis |
| `BACKEND_URL` | `http://127.0.0.1:5000` | URL do backend para o proxy |
| `RATE_LIMIT_REQUESTS` | `60` | Requisições máximas por janela |
| `RATE_LIMIT_WINDOW_SECONDS` | `60` | Janela de rate limiting (segundos) |
| `FIRMS_MAP_KEY` | vazio | Chave da API NASA FIRMS |
| `NEWS_API_KEY` | vazio | Chave da NewsAPI |
| `WAQI_TOKEN` | vazio | Token do World Air Quality Index |
| `TRUSTED_PROXIES` | vazio | CIDRs de proxies confiáveis |

> Use `.env.example` como base (nota: ainda contém variáveis MongoDB legadas — ignore-as).

## Troubleshooting rápido

- **Porta ocupada (5000/5001)**: rode `.\stop-lua-stack.ps1`, depois `.\start-lua-stack.ps1`
- **Lua não encontrado**: instale Lua 5.1 via `luarocks install lua`
- **lsqlite3 não encontrado**: rode `luarocks install lsqlite3 --local`
- **Redis indisponível**: backend funciona sem Redis — rate limiting usa fallback in-memory, cache é desabilitado
- **FIRMS sem dados**: verifique se `FIRMS_MAP_KEY` está configurado no `.env`

## Backup

```bash
./backup.sh
```

Saída padrão: `sqlite_backups/`

## Operação

- `RUNBOOK.md` — Runbook de operações
- `.agents/AGENTS.md` — Guia rápido para agentes de IA
- `.github/workflows/GITHUB_SECRETS.md` — Configuração de secrets

## Licença

MIT. Veja `LICENSE`.

## Contato

Samuel Ishida:
- GitHub: https://github.com/samuelishida
- GitLab: https://gitlab.com/samuelishida

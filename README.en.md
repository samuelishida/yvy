# Yvy

Environmental observability for monitoring deforestation and wildfires in Brazil.

**Production**: https://yvy.app.br/

Current stack:
- **Frontend**: React 18 + C HTTP server (static files + API proxy) + Tailwind CSS + Leaflet
- **Backend**: Lua 5.1 (business logic, SQLite, Redis)
- **Primary database**: SQLite (lsqlite3, WAL mode, connection pool, JSONB BLOB columns)
- **SQLite version**: lsqlite3 (SQLite 5.1) — native Lua bindings
- **Cache/rate limiting**: Redis (lua-redis, in-memory fallback)
- **Geospatial data**: TerraBrasilis (PRODES) and NASA FIRMS
- **News**: NewsAPI + MyMemory/LibreTranslate/Google Translate chain
- **Deploy**: OCI baremetal via Terraform + Ansible

## Requirements

- Linux, macOS, or Windows (MINGW/MSYS)
- Lua 5.1+
- Node.js 18+ (for frontend build only)
- Redis running locally (default: `redis://localhost:6379/0`)
- Git
- GCC (to compile C server)

## Local setup

```bash
cp .env.example .env
make setup
```

`make setup` does:
- installs Lua deps (`luasocket`, `lsqlite3`, `lua-cjson`, `copas`)
- installs frontend deps (`frontend/package.json`)
- compiles C server (`frontend/yvy-server.exe`)

## Run locally

Start everything:

```bash
cd scripts
.\start-lua-stack.ps1
```

Start separately:

```bash
.\run-lua-backend.ps1    # backend only
.\run-c-frontend.ps1      # frontend only
```

Stop local processes:

```bash
make stop
```

URLs:
- **Production**: https://yvy.app.br/
- **Local**:
  - Frontend: http://127.0.0.1:5001
  - Backend: http://127.0.0.1:5000

## Make commands

| Command | Description |
|---------|-------------|
| `make setup` | Install local dependencies |
| `make run` | Start backend + frontend |
| `make backend` | Start backend only |
| `make frontend` | Start frontend only |
| `make stop` | Kill background processes + ports 5000/5001 |
| `make test` | Run `test_sqlite_manual.py` (validates schema + queries) |
| `make migrate` | Migrate database from flat-column to JSONB schema |
| `make sqlite-access` | Open SQLite `.tables` |

## Data ingestion

Does not run automatically with `make run`.

```bash
cd backend-lua
lua5.1 -e 'package.path="./?.lua;./?/init.lua;"..package.path; require("app.env"); require("app.db").init_db(); require("app.ingest").run()'
```

## API endpoints

| Method | Route | Auth | Description |
|--------|-------|------|-------------|
| GET | `/health` | No | Frontend health check |
| GET | `/api/health` | No | Backend health check |
| GET | `/api/data` | Yes | PRODES data (bbox query) |
| GET | `/api/fires` | Yes | NASA FIRMS fire hotspots (bbox query) |
| POST | `/api/fires/sync` | Yes | Manual FIRMS sync trigger |
| POST | `/api/admin/firms/sync` | Yes | FIRMS sync (admin) |
| GET | `/api/news` | Yes | Paginated news (page, lang) |
| POST | `/api/news/refresh` | Optional | Force news refresh |
| POST | `/api/news/repair` | Yes | Re-translate corrupted translations |
| GET | `/api/weather/air-quality` | Yes | Air quality (WAQI) |
| GET | `/api/weather/temperature` | Yes | Temperature (Open-Meteo) |
| GET | `/api/stats` | Yes | Record counts from DB |

### Full-Brazil fire payload (gzip)

The home map intentionally loads the **full-Brazil** `/api/fires` dataset — up to
`MAX_RESULTS = 10000` records (~1.28 MB raw JSON) with no viewport bbox. This is a
deliberate product decision (all of Brazil on load). It stays acceptable because:

- **Redis** caches the `/api/fires` bbox response (60s TTL) so cache hits are ~10 ms.
- **nginx gzip** compresses the JSON (`application/json` is in `gzip_types` in
  `ansible/templates/yvy-nginx.conf.j2`), reducing the ~1.28 MB raw payload to ~176 KB
  over the wire.

`scripts/verify-gzip.sh` (wired into CI) guards this: it asserts the nginx template
still enables gzip for `application/json`/`application/javascript`, and — when given a
URL — that a live endpoint returns `Content-Encoding: gzip`.

## API Key

When `AUTH_REQUIRED=1`, the backend requires `X-API-Key` on protected routes.
The frontend injects the key server-side via the C server proxy, so the browser never sees it.

Example direct backend call:

```bash
curl "http://127.0.0.1:5000/api/data?ne_lat=-10&ne_lng=-34&sw_lat=-34&sw_lng=-74" \
  -H "X-API-Key: $API_KEY"
```

## Architecture

```text
Browser :5001
    │
    ▼
C server (yvy-server) — serve React build, proxy /api/*
    │  injects X-API-Key server-side
    ▼
Lua backend (main.lua) — routes on :5000
    │  copas + luasocket
    ├──► SQLite (lsqlite3) — WAL mode + JSONB support
    │     ├── fire_data (NASA FIRMS)
    │     │     scalar: lat, lon, acq_date, ingested_at
    │     │     JSONB:  confidence, acq_time, satellite, bright_ti4, source
    │     ├── deforestation_data (TerraBrasilis PRODES)
    │     │     scalar: lat, lon
    │     │     JSONB:  name, clazz, periods, source, color, timestamp
    │     └── news (articles with PT/EN translation)
    │           scalar: url, publishedAt, ingested_at
    │           JSONB:  title, description, title_en, description_en, source_name, urlToImage, content
    ├──► Redis (Lua helper) — rate limiting + cache
    │     └── fallback: in-memory deque per IP
    ├──► NewsAPI — background sync every 15 min
    │     └── MyMemory → LibreTranslate → Google Translate
    └──► NASA FIRMS API — background sync every 4h
          └── CSV download → bulk upsert
```

### JSONB Schema

The database uses a hybrid model: scalar columns for heavily-queried fields + a `data BLOB` column (binary JSONB) for flexible fields. This combines the performance of indexed queries with the schema flexibility of JSON.

**Advantages of JSONB in SQLite (≥ 3.45.0):**
- Binary storage ~5-10% smaller than text JSON
- `json_extract()` faster on binary format
- `jsonb(?)` converts text → binary on INSERT
- `json(data)` converts binary → text on SELECT

**Expression indexes on JSONB fields:**
- `idx_fire_confidence` on `json_extract(data, '$.confidence')`
- `idx_def_name` on `json_extract(data, '$.name')`
- `idx_news_source` on `json_extract(data, '$.source_name')`

**⚠️ Important:** The binary JSONB format is **not valid UTF-8**. Always use `json(data)` in SQL queries to read, and `jsonb(?)` to write. Never `json.loads()` directly on the BLOB.

### JSONB Migration

To migrate an existing database from flat-column schema to JSONB:

```bash
# Via Make
make migrate

# Or directly
cd backend-lua
lua5.1 app/migrate.lua
```

The migration script:
1. Creates automatic database backup
2. Detects legacy schema (columns like `confidence` in `fire_data`)
3. Creates new JSONB tables, copies data using `jsonb()`
4. Swaps tables and recreates indexes (including expression indexes)
5. Runs VACUUM to reclaim space

The app also auto-migrates on startup if a legacy schema is detected.

**Note on older SQLite:** `scripts/setup-lua.sh` builds SQLite 3.45+ from source when the system SQLite is too old for JSONB.

## Security

- **Authentication**: X-API-Key or Bearer token, constant-time comparison in Lua
- **Rate limiting**: 60 req/min per IP (configurable), Redis + in-memory fallback
- **CSP**: Restrictive — self only, OSM tiles, Bootstrap/jsDelivr/unpkg CDN
- **CORS**: Whitelist-based via `CORS_ORIGINS`
- **Proxy**: API key injected server-side by the C server, never exposed to the browser
- **Security headers**: X-Content-Type-Options, X-Frame-Options, Permissions-Policy

## Tests

Quick test via Make:

```bash
make test
```

Lua test suite:

```bash
cd backend-lua
busted --verbose tests/*.lua
```

CI:
- `.github/workflows/ci.yml` validates Lua, C, shell syntax, and frontend build
- `.gitlab-ci.yml`

> **Note:** The old Python backend/tests are removed. Use `backend-lua/tests/*.lua`.

## OCI Deploy (baremetal)

Deploy via **OCI CLI + Ansible** to an existing VM (no Terraform — avoids Always Free limits).

**Production**: https://yvy.app.br/ (HTTPS with Let's Encrypt SSL)

### GitHub Actions flow

1. **OCI CLI** discovers running `yvy-server` VM
2. **Ansible** applies application setup and systemd services
3. **Nginx + SSL** configures reverse proxy with HTTPS
4. **Health check** validates backend + frontend

### Quick deploy via OCI CLI (existing VM)

```bash
# 1. Set up variables
INSTANCE_ID=$(oci compute instance list -c $TENANCY_OCID --lifecycle-state RUNNING \
  --query 'data[?"display-name"==`yvy-server`][0].id' --raw-output)
VM_IP=$(oci network vnic get --vnic-id \
  "$(oci compute vnic-attachment list -c $TENANCY_OCID --instance-id "$INSTANCE_ID" \
    --query 'data[0]."vnic-id"' --raw-output)" \
  --query 'data."public-ip"' --raw-output)
SSH="ssh -i ~/.ssh/oci_yvy -o StrictHostKeyChecking=no ubuntu@$VM_IP"

# 2. Clone/update the repository
$SSH "if [ -d /opt/yvy ]; then cd /opt/yvy && sudo git pull; \
  else sudo mkdir -p /opt/yvy && sudo chown ubuntu:ubuntu /opt/yvy \
  && git clone https://github.com/samuelishida/yvy.git /opt/yvy; fi"

# 3. Generate .env and configure CORS
$SSH "cd /opt/yvy && bash scripts/generate-secrets.sh"
$SSH "sed -i 's|CORS_ORIGINS=.*|CORS_ORIGINS=http://$VM_IP:5001,http://localhost:5001|' /opt/yvy/.env"

# 4. Setup Lua backend
$SSH "cd /opt/yvy && bash scripts/setup-lua.sh"

# 5. Install/build frontend
$SSH 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" \
  && cd /opt/yvy/frontend && npm ci && npm run build'

# 6. Create and start systemd services
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
ExecStart=/usr/bin/bash /opt/yvy/scripts/run-lua.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF'

$SSH "sudo systemctl daemon-reload && sudo systemctl enable yvy-backend \
  && sudo systemctl restart yvy-backend && sleep 3"

# 7. Install and configure nginx + SSL
$SSH 'sudo apt-get update && sudo apt-get install -y nginx certbot python3-certbot-nginx'
$SSH 'sudo mkdir -p /var/www/certbot && sudo chown -R www-data:www-data /var/www/certbot'
$SSH "sudo bash /opt/yvy/scripts/deploy-nginx.sh"

# 8. Verify
curl -s http://$VM_IP:5000/health
curl -s -o /dev/null -w '%{http_code}' https://$VM_IP/ --insecure
```

### Deploy via GitHub Actions (automated)

The `.github/workflows/deploy-oci.yml` workflow triggers on push to `main`/`master`:
1. Installs OCI CLI + Ansible on the runner
2. Discovers running `yvy-server` VM via OCI CLI
3. Waits for cloud-init to complete
4. Runs Ansible playbook
5. Validates health check

**Required GitHub Secrets** (Settings → Secrets and variables → Actions):

| Secret | Description |
|--------|-------------|
| `OCI_TENANCY_OCID` | Tenancy OCID |
| `OCI_USER_OCID` | User OCID |
| `OCI_FINGERPRINT` | API Key fingerprint |
| `OCI_PRIVATE_KEY` | Private key content (`oci_api_key.pem`) |
| `OCI_REGION` | Region (e.g. `sa-saopaulo-1`) |
| `OCI_COMPARTMENT_OCID` | Compartment OCID (optional, uses tenancy if empty) |
| `OCI_SSH_PRIVATE_KEY` | Content of `~/.ssh/oci_yvy` |

### Terraform (initial infrastructure)

Use Terraform **only the first time** to create the VM:

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# Fill in your OCI values
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

After the VM is created, all subsequent deploys use OCI CLI + Ansible.

### Reference files

- `infra/README.md` — Full infrastructure guide
- `infra/main.tf` — OCI resources (VCN, subnet, VM)
- `ansible/playbook.yml` — Deploy playbook
- `.github/workflows/deploy-oci.yml` — CD via GitHub Actions

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `API_KEY` | empty | API authentication key |
| `AUTH_REQUIRED` | `0` | Set `1` in production to require API key |
| `CORS_ORIGINS` | `http://localhost:5001,...` | Allowed CORS origins |
| `LOG_LEVEL` | `INFO` | Log level (DEBUG, INFO, WARNING, ERROR) |
| `SQLITE_PATH` | `backend-lua/data/yvy.db` | SQLite database path (JSONB, WAL mode) |
| `REDIS_URL` | `redis://localhost:6379/0` | Redis connection |
| `BACKEND_URL` | `http://127.0.0.1:5000` | Backend URL for proxy |
| `RATE_LIMIT_REQUESTS` | `60` | Max requests per window |
| `RATE_LIMIT_WINDOW_SECONDS` | `60` | Rate limiting window (seconds) |
| `DEV` | `0` | Reserved for local frontend mode; backend is Lua baremetal |
| `FIRMS_MAP_KEY` | empty | NASA FIRMS API key |
| `NEWS_API_KEY` | empty | NewsAPI key |
| `WAQI_TOKEN` | empty | World Air Quality Index API token |
| `TRUSTED_PROXIES` | empty | Trusted proxy CIDRs |

> Use `.env.example` as a base (note: it still contains legacy MongoDB variables — ignore them).

## Quick troubleshooting

- **Port in use (5000/5001)**: run `make stop`, then `make run`
- **Shutdown trace with `RuntimeError: reentrant call inside _io.BufferedWriter.__repr__`**:
  interrupt with `Ctrl+C`, run `make stop`, start again with `make run`
- **Redis unavailable**: backend works without Redis — rate limiting uses in-memory fallback, cache is disabled
- **FIRMS no data**: check that `FIRMS_MAP_KEY` is configured in `.env`

## Backup

```bash
./backup.sh
```

Default output: `sqlite_backups/`

## Operations

- `RUNBOOK.md` — Operations runbook
- `AGENTS.md` — Quick guide for AI agents
- `.github/workflows/GITHUB_SECRETS.md` — Secrets configuration

## License

MIT. See `LICENSE`.

## Contact

Samuel Ishida:
- GitHub: https://github.com/samuelishida
- GitLab: https://gitlab.com/samuelishida

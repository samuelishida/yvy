# AGENTS.md — Yvy

## Quick Start

```bash
# 1. Set up env
cp .env.example .env

# 2. Install dependencies
make setup

# 3. Run C frontend + Lua backend
make run

# 4. (Optional) Ingest PRODES data
cd backend-lua && lua main.lua ingest
```

App runs at `http://localhost:5001`. C server on 5001 serves React build + proxies `/api/*` to Lua backend on 5000.

## Running Tests

```bash
# Quick smoke test (SQLite schema validation)
make test-lua

# Lua unit tests
cd backend-lua/tests && lua5.1 test_db.lua && lua5.1 test_geo.lua
```

- Tests use **lsqlite3** (file-based SQLite) — no running DB server needed.
- Lua 5.1 required for lsqlite3 module (MSYS2/UCRT64 installation).
- **Note:** Old Python tests (`tests/test_api.py`) are stale and removed.

## Architecture

```
Browser :5001 → C HTTP server (yvy-server.c)
                    ├─ Serves React static files from frontend/build/
                    └─ Proxies /api/* → Lua backend :5000
                          └─ Injects X-API-Key header server-side
                          
                    Lua backend :5000 (main.lua + app/*.lua)
                          ├─ SQLite (lsqlite3, file-based at SQLITE_PATH)
                          │   └─ JSONB BLOB columns for flexible fields
                          │   └─ json_extract() for indexed field queries
                          │   └─ json() for reading JSONB back to text
                          ├─ Redis :6379 (rate limiting, connection pooling)
                          └─ curl.exe (HTTP client for news scraping, translation)
```

- **C frontend server** (`backend-lua/yvy-server.c`) — Single-threaded HTTP server, serves React build, proxies API requests, injects `X-API-Key` header server-side so browser never sees it.
- **Lua backend** (`backend-lua/main.lua` + `backend-lua/app/`) — Routes in `app/routes/`, lookups in `app/lookups/`, middleware in `app/middleware/`. Uses `lsqlite3`, `cjson`, `luasocket`.
- **SQLite layer** (`backend-lua/app/db.lua`) — JSONB support via `jsonb(?)` for writes, `json(data)` for reads, expression indexes on JSON fields. Auto-migrates from legacy flat-column schema.
- **Rate limiting** uses Redis via `app/redis.lua` with connection pooling.
- **ingest** via `app/ingest.lua` (Lua script, not Python).

### JSONB Schema

Each table uses a hybrid approach:
- **Scalar columns** for heavily-queried fields (lat, lon, acq_date, url, publishedAt, ingested_at)
- **`data BLOB`** column storing JSONB binary for all other fields

| Table | Scalar columns | JSONB `data` fields |
|---|---|---|
| `fire_data` | lat, lon, acq_date, ingested_at | confidence, acq_time, satellite, bright_ti4, source |
| `deforestation_data` | lat, lon | name, clazz, periods, source, color, timestamp |
| `news` | url, publishedAt, ingested_at | title, description, title_en, description_en, source_name, urlToImage, content |

Expression indexes on JSONB fields:
- `idx_fire_confidence` on `json_extract(data, '$.confidence')`
- `idx_def_name` on `json_extract(data, '$.name')`
- `idx_news_source` on `json_extract(data, '$.source_name')`

### Migration

To migrate an existing database from the legacy flat-column schema:
```bash
cd backend-lua
lua5.1 main.lua migrate
```

The migration script (`backend-lua/app/migrate.lua`):
1. Creates backup of the database
2. Detects legacy schema (columns like `confidence` in fire_data)
3. Creates new JSONB tables, copies data using `jsonb()`
4. Drops old tables, renames new tables
5. Recreates indexes including expression indexes
6. Runs VACUUM to reclaim space

The app also auto-migrates on startup if legacy schema is detected.

## Key Environment Variables

| Variable | Default | Notes |
|---|---|---|
| `DEV` | `0` | `1` runs Quart dev server instead of hypercorn |
| `AUTH_REQUIRED` | `0` | Set `1` in production to require `X-API-Key` |
| `API_KEY` | empty | Used by both frontend proxy and backend auth |
| `SQLITE_PATH` | `backend-lua/data/yvy.db` | Path to SQLite database file |
| `REDIS_URL` | `redis://localhost:6379/0` | Async Redis connection for rate limiting |
| `BACKEND_URL` | `http://127.0.0.1:5000` | Frontend proxy target |
| `TRUSTED_PROXIES` | private ranges | CIDR list for X-Forwarded-For trust |
| `FIRMS_MAP_KEY` | empty | NASA FIRMS API key for fire data sync |
| `NEWS_API_KEY` | empty | NewsAPI key for news aggregation |
| `WAQI_TOKEN` | empty | World Air Quality Index API token |

## Deployment

### Option A: OCI CLI (recommended — no Terraform/Ansible needed)

Deploy directly to an existing OCI VM using the local OCI CLI. Assumes VM already exists and SSH key is configured.

```bash
# 1. Find your VM
INSTANCE_ID=$(oci compute instance list \
  --compartment-id $TENANCY_OCID \
  --region sa-saopaulo-1 \
  --lifecycle-state RUNNING \
  --query 'data[0].id' --raw-output)

# 2. Get public IP
VM_IP=$(oci compute instance list-vnics \
  --instance-id "$INSTANCE_ID" \
  --region sa-saopaulo-1 \
  --query 'data[0]."public-ip"' --raw-output)

# 3. SSH into VM and deploy
SSH_KEY=~/.ssh/oci_yvy
SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@$VM_IP"

# 3a. Add swap (1GB VM needs it for npm build)
$SSH "sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile \
  && sudo mkswap /swapfile && sudo swapon /swapfile \
  && echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab"

# 3b. Install runtime deps
$SSH "sudo apt-get update && sudo apt-get install -y git python3 python3-venv python3-pip redis-server sqlite3"

# 3c. Install Node 18 via nvm (system Node 12 is too old for react-scripts 5)
$SSH 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash'
$SSH 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && nvm install 18'

# 3d. Clone/update repo
$SSH "if [ -d /opt/yvy ]; then cd /opt/yvy && git pull; \
  else sudo mkdir -p /opt/yvy && sudo chown ubuntu:ubuntu /opt/yvy \
  && git clone https://github.com/samuelishida/yvy.git /opt/yvy; fi"

# 3e. Generate .env (only if missing)
$SSH "cd /opt/yvy && bash scripts/generate-secrets.sh"
# Then fix CORS_ORIGINS with your public IP:
$SSH "sed -i 's|CORS_ORIGINS=.*|CORS_ORIGINS=http://$VM_IP:5001,http://localhost:5001|' /opt/yvy/.env"

# 3f. Setup backend (Lua deps)
$SSH "cd /opt/yvy && bash scripts/setup-lua.sh"

# 3g. Build C frontend server
$SSH 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  && cd /opt/yvy/frontend && rm -rf node_modules package-lock.json && npm install && npm run build
  && cd /opt/yvy/backend-lua && gcc -o yvy-server.exe yvy-server.c -lws2_32'

# 3h. Create systemd services
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
ExecStart=/usr/bin/lua5.1 /opt/yvy/backend-lua/main.lua
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
Environment=YVY_LOCAL_DEV=0
Environment=PORT=5001
Environment=BUILD_DIR=/opt/yvy/frontend/build
ExecStart=/opt/yvy/backend-lua/yvy-server.exe
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF'

# 3i. Start services
$SSH "sudo systemctl daemon-reload && sudo systemctl enable yvy-backend yvy-frontend \
  && sudo systemctl start yvy-backend && sleep 3 \
  && sudo systemctl start yvy-frontend"

# 4. Verify
curl -s http://$VM_IP:5000/ | head -1   # backend
curl -s -o /dev/null -w '%{http_code}' http://$VM_IP:5001/  # frontend (200 = OK)
```

### Option B: Terraform + Ansible

Baremetal via **Terraform + Ansible** (no Docker).
- `infra/` — Terraform config for OCI VM.
- `ansible/` — Ansible playbook, systemd service templates.
- `scripts/deploy-local.sh` — orchestrates Terraform + Ansible.

Production services: `yvy-backend` (systemd), `yvy-frontend` (systemd).

### Key deployment notes

- **1GB RAM VMs** need swap (2GB) for npm install and webpack compilation.
- **C frontend server** runs in production mode (`yvy-server.exe`), serves pre-built React static files.
- **Backend uses Lua 5.1** with lsqlite3, cjson, luasocket modules.
- **CORS_ORIGINS** must include the VM's public IP for browser access to work.

## Gotchas

- **JSONB BLOB format**: SQLite's `jsonb()` stores data in a binary format that is NOT valid UTF-8. Always use `json(data)` in SQL queries to convert back to text, or `json_extract(data, '$.field')` for individual fields. Never try to `json.decode()` the raw BLOB in Lua.
- **Lua version**: Must use Lua 5.1 for lsqlite3 module (compiled for 5.1 in MSYS2). `lua.exe` might be 5.5 — use `lua5.1.exe` explicitly.
- **Old Python backend removed**: `backend/` directory deleted. All logic now in `backend-lua/`.
- **C frontend server**: Single-threaded, no Node.js dependency. Build with MinGW/gcc (`gcc -o yvy-server.exe yvy-server.c -lws2_32`).
- **No linter/formatter configured** for Lua or C.
- **CI** (`.github/workflows/ci.yml`) validates: Lua syntax check, C syntax check, `sh -n` on shell scripts.

# AGENTS.md — Yvy

## Quick Start

```bash
# 1. Set up env
cp .env.example .env

# 2. Install dependencies + create venv
make setup

# 3. Run backend + frontend
make run

# 4. (Optional) Ingest PRODES data
cd backend && python ingest_sqlite.py
```

App runs at `http://localhost:5001`. Express proxy on 5001 forwards `/api/*` to Quart on 5000 (internal only).

## Running Tests

```bash
# Quick smoke test (SQLite schema validation)
make test

# Full pytest suite (requires venv activated)
cd backend
source $HOME/.local/share/yvy-venv/bin/activate  # or .venv
pip install -r requirements-test.txt
pytest -v
```

- Tests use **aiosqlite** (file-based SQLite) — no running DB server needed.
- `rasterio` is imported lazily inside `parse_tif()`, so tests don't need it installed.
- Tests use **pytest-asyncio** for Quart's async test client.
- **Note:** `tests/test_api.py` is stale (still uses mongomock). `test_db_sqlite.py` and `test_sqlite_manual.py` are current.

## Architecture

```
Browser :5001 → Express (React build + /api/* proxy + X-API-Key injection)
                      → Quart :5000 (async, hypercorn + asyncio workers)
                            → SQLite (aiosqlite, file-based at SQLITE_PATH)
                              └─ JSONB BLOB columns for flexible fields
                              └─ json_extract() for indexed field queries
                              └─ json() for reading JSONB back to text
                            → Redis :6379 (rate limiting, async redis.asyncio)
                            → NewsAPI + MyMemory (background sync for /api/news)
```

- **Express proxy** (`frontend/server.js`) injects `X-API-Key` header server-side so the browser never sees the API key.
- **Quart backend** (`backend/backend.py`) — async routes, aiosqlite (async SQLite), redis.asyncio (rate limiting), httpx (async HTTP), structured JSON logging.
- **SQLite layer** (`backend/db_sqlite.py`) — custom async connection pool (asyncio.Queue, 7 connections, WAL mode). Schema uses **JSONB BLOB columns** for flexible fields (fire metadata, deforestation attributes, news content). Scalar columns (lat, lon, url, dates) remain for indexed queries. Uses `jsonb()` for writes and `json()`/`json_extract()` for reads. Auto-migrates from legacy flat-column schema on startup.
- **Rate limiting** uses Redis via `redis.asyncio`. Falls back to in-memory per-process buckets if Redis is down.
- **ingest_sqlite.py** is an async script using `db_sqlite` module (not pymongo).

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
cd backend
python migrate_to_jsonb.py --db data/yvy.db --vacuum
```

The migration script:
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
| `SQLITE_PATH` | `backend/data/yvy.db` | Path to SQLite database file (container default: `/app/data/yvy.db`) |
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

# 3f. Setup backend (Python venv + deps)
$SSH "cd /opt/yvy && bash scripts/setup-local.sh"

# 3g. Install frontend deps with Node 18
$SSH 'export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" \
  && cd /opt/yvy/frontend && rm -rf node_modules package-lock.json && npm install'

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

- **Node 12 is too old** for react-scripts 5. Use nvm to install Node 18 on the VM.
- **1GB RAM VMs** need swap (2GB) for npm install and webpack compilation.
- **Frontend runs in DEV mode** (`YVY_LOCAL_DEV=1`) on the VM because production build requires more RAM.
- **Backend uses `run-backend.sh`** which sources `.env` before starting hypercorn.
- **CORS_ORIGINS** must include the VM's public IP for browser access to work.

## Gotchas

- **JSONB BLOB format**: SQLite's `jsonb()` stores data in a binary format that is NOT valid UTF-8. Always use `json(data)` in SQL queries to convert back to text, or `json_extract(data, '$.field')` for individual fields. Never try to `json.loads()` the raw BLOB in Python.
- **`test_api.py` is stale** — still uses mongomock and patches `bk.mongo_db`. Use `test_sqlite_manual.py` instead.
- **`requirements-dev.txt` is stale** — still lists motor/pymongo/mongomock. Don't use it.
- **`.env.example` is stale** — still has MongoDB variables, missing SQLITE_PATH and others.
- **ingest_sqlite.py** has hardcoded `/app/` paths from Docker era — these need updating for baremetal (`backend/data/`).
- **Quart/async**: All route handlers are `async def`. DB queries use `await` with aiosqlite. Redis uses `redis.asyncio`.
- **No frontend tests exist** despite `package.json` having a `test` script (react-scripts test).
- **No linter/formatter configured** for either Python or JS.
- **CI** (`.github/workflows/ci.yml`) validates backend: py_compile on Python sources, `sh -n` on shell scripts. Does NOT run pytest.
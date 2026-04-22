# AGENTS.md — Yvy

## Quick Start

```bash
# 1. Set up env
cp .env.dev.example .env

# 2. Launch all services (mongo, redis, backend, frontend)
docker compose up --build

# 3. Ingest PRODES data (not automatic)
docker compose exec backend python ingest.py
```

App runs at `http://localhost:5001`. Backend is not publicly exposed; Express proxy on 5001 forwards `/api/*` to Flask on 5000 (internal only).

## Running Tests

```bash
# From repo root — CI style
pip install -r backend/requirements-dev.txt -r backend/requirements.txt
pytest -q backend/tests

# From backend/ with a venv
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt -r requirements.txt
pytest -v
```

- Tests use **mongomock** — no running MongoDB needed.
- `rasterio` is imported lazily inside `parse_tif()`, so tests don't need it installed.
- The `reset_db` fixture patches `bk.mongo` and resets module-level globals (`AUTH_REQUIRED`, `API_KEY`, rate limit state).

## Architecture

```
Browser :5001 → Express (React build + /api/* proxy + X-API-Key injection)
                       → Flask :5000 (expose only, no public port)
                             → MongoDB :27017 (expose only)
                             → Redis :6379 (expose only)
```

- **Express proxy** (`frontend/server.js`) injects `X-API-Key` header server-side so the browser never sees the API key.
- **Flask backend** (`backend/backend.py`) — single module with routes, auth, rate limiting, structured JSON logging.
- **Rate limiting** uses Redis (shared across gunicorn workers). Falls back to in-memory per-process buckets if Redis is down.
- **MongoDB users** `yvy_app` (readWrite) and `yvy_readonly` are created by `mongo-init.js` on first container init.

## Key Environment Variables

| Variable | Default | Notes |
|---|---|---|
| `DEV` | `0` | `1` runs Flask dev server inside container instead of gunicorn |
| `AUTH_REQUIRED` | `0` | Set `1` in production to require `X-API-Key` |
| `API_KEY` | empty | Used by both frontend proxy and backend auth |
| `MONGO_URI` | auto-built | If empty, `build_mongo_uri()` assembles from `MONGO_HOST`, `MONGO_PORT`, `MONGO_APP_*` creds |
| `RUN_INGEST` | `0` | Reserved; ingestion is manual via `docker compose exec backend python ingest.py` |

## Gotchas

- **`backend:/app` bind mount** in `docker-compose.yml` overwrites the Docker image code at runtime. Remove this volume for production.
- **`download_and_extract_data()`** in `backend.py` is dead code — replaced by `ingest.py`.
- **`config.toml`** describes a `node` service that is not part of the current docker-compose setup; it appears orphaned.
- **No frontend tests exist** despite `package.json` having a `test` script (react-scripts test).
- **No linter/formatter configured** for either Python or JS — no eslint, prettier, ruff, black, or isort config found.
- **CI** (`.github/workflows/ci.yml`) only validates backend: pytest, py_compile on Python sources, `sh -n` on shell scripts, `node -c` on mongo-init.js.
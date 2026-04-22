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

App runs at `http://localhost:5001`. Backend is not publicly exposed; Express proxy on 5001 forwards `/api/*` to Quart on 5000 (internal only).

## Running Tests

```bash
# From repo root — CI style
pip install -r backend/requirements-dev.txt -r backend/requirements.txt
pytest backend/tests

# From backend/ with a venv
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt -r requirements.txt
pytest -v
```

- Tests use **mongomock** — no running MongoDB needed.
- `rasterio` is imported lazily inside `parse_tif()`, so tests don't need it installed.
- Tests use **pytest-asyncio** for Quart's async test client.
- The `reset_db` fixture patches `bk.mongo_db` and resets module-level globals.

## Architecture

```
Browser :5001 → Express (React build + /api/* proxy + X-API-Key injection)
                      → Quart :5000 (async, hypercorn + asyncio workers)
                            → MongoDB :27017 (expose only, no public port)
                            → Redis :6379 (rate limiting, async redis.asyncio)
```

- **Express proxy** (`frontend/server.js`) injects `X-API-Key` header server-side so the browser never sees the API key.
- **Quart backend** (`backend/backend.py`) — async routes, motor (async MongoDB), redis.asyncio (rate limiting), httpx (async HTTP), structured JSON logging.
- **Rate limiting** uses Redis via `redis.asyncio` (shared across workers). Falls back to in-memory per-process buckets if Redis is down.
- **MongoDB users** `yvy_app` (readWrite) and `yvy_readonly` are created by `mongo-init.js` on first container init.
- **ingest.py** is standalone synchronous script using pymongo directly (not the Quart app).

## Key Environment Variables

| Variable | Default | Notes |
|---|---|---|
| `DEV` | `0` | `1` runs Quart dev server inside container instead of hypercorn |
| `AUTH_REQUIRED` | `0` | Set `1` in production to require `X-API-Key` |
| `API_KEY` | empty | Used by both frontend proxy and backend auth |
| `MONGO_URI` | auto-built | If empty, `build_mongo_uri()` assembles from `MONGO_HOST`, `MONGO_PORT`, `MONGO_*` creds |
| `REDIS_URL` | `redis://redis:6379/0` | Async Redis connection for rate limiting |
| `TRUSTED_PROXIES` | private ranges | CIDR list for X-Forwarded-For trust |
| `RUN_INGEST` | `0` | Reserved; ingestion is manual via `docker compose exec backend python ingest.py` |

## Gotchas

- **`backend:/app` bind mount** in `docker-compose.yml` overwrites the Docker image code at runtime. Remove this volume for production.
- **ingest.py** uses pymongo directly (not motor) because it's a one-shot script, not part of the async server.
- **Quart/async**: All route handlers are `async def`. DB queries use `await cursor.to_list()`. Redis uses `redis.asyncio`.
- **No frontend tests exist** despite `package.json` having a `test` script (react-scripts test).
- **No linter/formatter configured** for either Python or JS.
- **CI** (`.github/workflows/ci.yml`) validates backend: pytest, py_compile on Python sources, `sh -n` on shell scripts, `node -c` on mongo-init.js.
Now I have a thorough understanding of the entire backend. Let me compile the comprehensive migration plan.

---

# Comprehensive Migration Plan: Python → Lua (Yvy Backend)

## 1. Executive Summary

The Yvy backend is ~1,100 lines of Python (Quart/Quart-CORS/Hypercorn) plus ~800 lines of db_sqlite.py, ~500 lines of news_sqlite.py, ~300 lines of alerts.py, and several smaller lookup modules. The migration to Lua targets **Render** as the deployment platform, which means we need a Lua web framework that runs on Render's native infrastructure.

### Key Decision: Lua Runtime on Render

Render doesn't natively support Lua runtimes. The viable paths are:

| Path | Runtime | Pros | Cons |
|------|---------|------|------|
| **A. OpenResty (nginx + LuaJIT)** | Docker on Render | Mature, fast, great SQLite bindings | Requires Dockerfile; heavier |
| **B. Lapis (Lua/Moonscript on OpenResty)** | Docker on Render | Full-featured MVC framework | Moonscript learning curve |
| **C. lua-http + cqueues** | Docker on Render | Pure Lua, lightweight | Less battle-tested |
| **D. Tarantool** | Docker on Render | Built-in DB, app server | Different paradigm entirely |

**Recommendation: Path A — OpenResty (nginx + LuaJIT + lua-resty-* libraries)**. It's the most mature Lua web ecosystem, has excellent SQLite support via `lua-resty-sqlite3` (which wraps `lsqlite3` with LuaJIT FFI), and nginx handles static file serving, SSL termination, gzip, CSP headers, and rate limiting natively — eliminating the need for the Express proxy entirely.

---

## 2. Module-by-Module Mapping

### 2.1 Web Framework: Quart → OpenResty

| Python | Lua (OpenResty) |
|--------|-----------------|
| `quart.Quart(__name__)` | nginx.conf + `content_by_lua_block` |
| `@app.route("/api/fires")` | `location /api/fires { ... }` |
| `@app.before_serving` | `init_by_lua_block` / `init_worker_by_lua_block` |
| `@app.after_serving` | `ngx.on_exit` in worker shutdown |
| `@app.before_request` / `@app.after_request` | `header_filter_by_lua_block` / `log_by_lua_block` |
| `quart_cors.cors` | `ngx.header["Access-Control-Allow-Origin"]` + `more_set_headers` |
| `hypercorn` (ASGI server) | nginx itself (event-driven, non-blocking) |
| `request.args.get("key")` | `ngx.req.get_uri_args()["key"]` |
| `request.headers.get("X-API-Key")` | `ngx.req.get_headers()["X-API-Key"]` |
| `request.remote_addr` | `ngx.var.remote_addr` |
| `abort(400)` | `ngx.exit(400)` |
| `jsonify(data)` | `cjson.encode(data)` + `ngx.say()` |
| `response.headers.setdefault(...)` | `ngx.header["Key"] = "Value"` |
| `gzip.compress(data)` | nginx `gzip` module (automatic) |
| `asyncio.create_task(...)` | `ngx.timer.at(0, handler)` / `ngx.timer.every(interval, handler)` |

### 2.2 Database: aiosqlite → lsqlite3 (LuaJIT FFI)

| Python (db_sqlite.py) | Lua |
|--------------------------|-----|
| `aiosqlite.connect(DB_PATH)` | `lsqlite3.open(DB_PATH)` |
| `conn.row_factory = aiosqlite.Row` | `sqlite3.lopen()` with custom row handler |
| `await conn.execute(sql, params)` | `db:exec(sql, bind_callback)` |
| `await conn.executemany(sql, rows)` | Loop with `db:exec()` inside transaction |
| `await conn.commit()` | `db:exec("COMMIT")` |
| `asyncio.Queue` connection pool | `lua-resty-lrucache` or `ngx.shared.DICT` for connection pooling |
| `PRAGMA journal_mode=WAL` | Same SQL, executed at init |
| `jsonb(?)` / `json(data)` | Same SQL — lsqlite3 uses the same SQLite library |
| `_encode_jsonb(dict)` → `json.dumps()` | `cjson.encode(table)` |
| `_decode_jsonb(blob)` → `json.loads()` | `cjson.decode(string)` |
| `@asynccontextmanager _get_conn()` | `pool:acquire()` / `pool:release()` pattern |

**Critical note on JSONB**: `lsqlite3` links against the system's `libsqlite3`. On Render's Docker, we must ensure SQLite ≥ 3.45.0. The Dockerfile will need to compile SQLite from source or use a pre-built binary, similar to how `pysqlite3-binary` works today.

### 2.3 HTTP Client: httpx → lua-resty-http

| Python | Lua |
|--------|-----|
| `httpx.AsyncClient(timeout=30.0)` | `resty_http.new()` with `timeout` option |
| `await client.get(url, params=...)` | `httpc:request_uri(url, { query = params })` |
| `await client.post(url, json=...)` | `httpc:request_uri(url, { method = "POST", body = cjson.encode(data) })` |
| `resp.json()` | `cjson.decode(res.body)` |
| `resp.text` | `res.body` (already string) |
| `resp.status_code` | `res.status` |
| `client.stream("GET", url)` | `httpc:request({ method = "GET", path = url })` with streaming callback |
| `csv.DictReader(io.StringIO(text))` | Custom CSV parser or `lua-csv` library |

### 2.4 Redis: redis.asyncio → lua-resty-redis

| Python | Lua |
|--------|-----|
| `aioredis.from_url(REDIS_URL)` | `resty_redis.new()` + `red:connect(host, port)` |
| `await redis_client.ping()` | `red:ping()` |
| `await redis_client.get(key)` | `red:get(key)` |
| `await redis_client.setex(key, ttl, value)` | `red:setex(key, ttl, value)` |
| `await redis_client.delete(*keys)` | `red:del(unpack(keys))` |
| `redis_client.pipeline()` | Lua scripts via `red:eval()` for atomic multi-op |
| `redis_client.scan_iter(match=...)` | `red:scan(cursor, "MATCH", pattern)` in loop |
| `redis_client.zremrangebyscore(...)` | `red:zremrangebyscore(key, min, max)` |
| `redis_client.zcard(key)` | `red:zcard(key)` |
| `redis_client.zadd(key, ...)` | `red:zadd(key, score, member)` |
| `redis_client.expire(key, ttl)` | `red:expire(key, ttl)` |

### 2.5 Background Tasks: asyncio.create_task → ngx.timer

| Python | Lua |
|--------|-----|
| `asyncio.create_task(_fires_sync_loop())` | `ngx.timer.at(10, fires_sync_loop)` |
| `asyncio.create_task(_news_sync_loop())` | `ngx.timer.at(15, news_sync_loop)` |
| `asyncio.create_task(_alerts_sync_loop())` | `ngx.timer.at(60, alerts_sync_loop)` |
| `await asyncio.sleep(3600)` inside loop | `ngx.timer.at(interval * 1000, handler)` — reschedule at end |
| `task.cancel()` | `ngx.timer` cannot be cancelled; use a flag check |
| `asyncio.Semaphore(3)` | `ngx.shared.DICT` with atomic incr/decr or `lua-resty-limit-traffic` |

### 2.6 Geospatial Lookups: Pure Python → Pure Lua

| Python | Lua |
|--------|-----|
| biome_lookup.py — `point_in_ring()` | Direct port — same ray-casting algorithm in Lua |
| indigenous_lands_lookup.py | Same pattern, load JSON at init |
| conservation_units_lookup.py | Same pattern, load JSON at init |
| _geo.py — `point_in_ring()` / `point_in_polygon()` | Port to Lua — ~30 lines, trivial |
| `json.load(open("biome_data.json"))` | `cjson.decode(io.open("biome_data.json"):read("*a"))` |

### 2.7 Alerts: alerts.py → alerts.lua

| Python | Lua |
|--------|-----|
| `_haversine_km()` | Direct port — math functions identical |
| `_parse_fire_time()` | Direct port — string parsing |
| `_is_night()` | Direct port |
| `generate_all_alerts()` | Direct port — same algorithm, same data flow |
| `math.radians()`, `math.sin()`, etc. | `math.rad()`, `math.sin()`, etc. (Lua's `math` library) |

### 2.8 News: news_sqlite.py + news_scrapers.py → news.lua

| Python | Lua |
|--------|-----|
| `NewsAPI` HTTP calls | `lua-resty-http` |
| `MyMemory` / `LibreTranslate` / `Google Translate` chain | Same HTTP calls via `lua-resty-http` |
| `RSS scraper` (`xml.etree.ElementTree`) | `lua-resty-xml` or LuaExpat binding |
| `TranslatorChain` class | Lua table with methods |
| `is_relevant()` keyword matching | Direct port — same regex via `ngx.re.match()` |
| `_repair_bad_translations()` | Direct port |

### 2.9 Data Ingestion: ingest_sqlite.py → ingest.lua

| Python | Lua |
|--------|-----|
| `rasterio` (TIF parsing) | **Cannot port directly** — rasterio is C/Python. Options: |
| | (a) Keep a small Python sidecar for TIF ingestion only |
| | (b) Use GDAL CLI (`gdal_translate` → XYZ) from Lua via `os.execute()` |
| | (c) Pre-process TIF to CSV/JSON in CI, ingest from that |
| `xml.etree.ElementTree` (QML parsing) | `lua-resty-xml` or LuaExpat |
| `zipfile.ZipFile` | `os.execute("unzip ...")` or Lua `lzlib` binding |
| `httpx.Client` (sync, for download) | `lua-resty-http` (non-blocking in OpenResty) |

**Recommendation**: Option (c) — pre-process the PRODES TIF in CI/GitHub Actions using GDAL, commit the resulting CSV, and have the Lua ingest script read CSV only. This eliminates the `rasterio` dependency entirely.

### 2.10 Migration: migrate_to_jsonb.py → migrate.lua

| Python | Lua |
|--------|-----|
| `sqlite3.connect()` (sync) | `lsqlite3.open()` |
| `PRAGMA table_info(...)` | Same SQL |
| `conn.executescript(SCHEMA)` | `db:exec(SCHEMA)` |
| `shutil.copy2()` (backup) | `os.execute("cp ...")` |
| `argparse` | `arg` table from `ngx.arg` or manual parsing |

---

## 3. Architecture Changes

### Before (Current)
```
Browser :5001 → Express (React + /api/* proxy + X-API-Key injection)
                   → Quart :5000 (Hypercorn + asyncio)
                         → SQLite (aiosqlite)
                         → Redis (redis.asyncio)
```

### After (Lua/OpenResty)
```
Browser :80/443 → nginx/OpenResty (single process)
                    ├── /api/* → Lua handlers (content_by_lua_block)
                    │               ├── SQLite (lsqlite3 via LuaJIT FFI)
                    │               └── Redis (lua-resty-redis)
                    ├── / → React static build
                    └── SSL termination, gzip, CSP, CORS, rate limiting (all nginx-native)
```

**Key simplifications:**
- **No Express proxy needed** — nginx serves React build directly and handles API key injection via `proxy_set_header` or internal Lua logic
- **No separate backend process** — everything runs inside nginx worker processes
- **No Hypercorn/Quart** — nginx is the event loop
- **Rate limiting** moves to `lua-resty-limit-traffic` or nginx's `limit_req` module (simpler, faster)
- **Gzip** is automatic via nginx `gzip` module
- **CSP/CORS headers** set via nginx `add_header` directives

---

## 4. File Structure (New)

```
backend-lua/
├── Dockerfile                    # Render Docker deployment
├── nginx.conf                    # Main nginx config with Lua hooks
├── init.lua                      # init_by_lua_block: DB init, load JSON data
├── app/
│   ├── db.lua                    # SQLite layer (port of db_sqlite.py)
│   ├── redis.lua                 # Redis helpers (port of cache_get/set/delete)
│   ├── fires.lua                 # /api/fires, /api/fires/sync, /api/admin/firms/sync
│   ├── deforestation.lua         # /api/data
│   ├── news.lua                  # /api/news, /api/news/refresh, /api/news/repair
│   ├── alerts.lua                # /api/alerts + alert generation logic
│   ├── biomes.lua                # /api/biomes + biome classification
│   ├── weather.lua               # /api/weather/air-quality, /api/weather/temperature
│   ├── geo.lua                   # point_in_ring, point_in_polygon
│   ├── indigenous_lands.lua      # TI point-in-polygon lookup
│   ├── conservation_units.lua    # UC point-in-polygon lookup
│   ├── translate.lua             # TranslatorChain (MyMemory → Libre → Google)
│   ├── scrapers.lua              # RSS scraper (port of news_scrapers.py)
│   ├── ingest.lua                # Data ingestion (CSV-based, no rasterio)
│   ├── migrate.lua               # JSONB migration script
│   ├── auth.lua                  # API key validation
│   ├── rate_limit.lua            # Rate limiting (or use nginx limit_req)
│   └── utils.lua                 # JSON encode/decode, CSV parser, date helpers
├── data/
│   ├── biome_data.json           # (unchanged)
│   ├── indigenous_lands.json     # (unchanged)
│   ├── conservation_units.json   # (unchanged)
│   └── prodes_brasil_2023.csv    # NEW: pre-processed from TIF
├── tests/
│   ├── test_db.lua               # SQLite schema + CRUD tests
│   ├── test_api.lua              # HTTP endpoint tests
│   ├── test_alerts.lua           # Alert generation tests
│   ├── test_geo.lua              # Point-in-polygon tests
│   ├── test_translate.lua        # Translation chain tests
│   └── test_runner.lua           # Test harness (or use busted)
└── .busted                       # Busted test framework config
```

---

## 5. Dependency Map

### Python Dependencies → Lua Replacements

| Python Package | Lua Equivalent | Notes |
|----------------|----------------|-------|
| `quart` | OpenResty (nginx + LuaJIT) | Built into Docker image |
| `quart-cors` | nginx `add_header` | Native |
| `hypercorn` | nginx event loop | Native |
| `aiosqlite` | `lsqlite3` (LuaJIT FFI) | `luarocks install lsqlite3` |
| `httpx` | `lua-resty-http` | `luarocks install lua-resty-http` |
| `redis[hiredis]` | `lua-resty-redis` | `luarocks install lua-resty-redis` |
| `python-dotenv` | Custom .env parser (~20 lines Lua) | Or use `lua-dotenv` from luarocks |
| `pysqlite3-binary` | Compile SQLite ≥ 3.45.0 in Dockerfile | `libsqlite3-dev` from source |
| `rasterio` | **Eliminated** — pre-process TIF in CI | GDAL CLI in GitHub Actions |
| `pytest` / `pytest-asyncio` | `busted` (Lua test framework) | `luarocks install busted` |
| `json` (stdlib) | `lua-cjson` / `cjson` | Bundled with OpenResty |
| `csv` (stdlib) | Custom (~30 lines) or `lua-csv` | `luarocks install lua-csv` |
| `gzip` (stdlib) | nginx `gzip` module | Native |
| `xml.etree.ElementTree` | `lua-resty-xml` or LuaExpat | `luarocks install luaexpat` |
| `zipfile` (stdlib) | `os.execute("unzip")` or `lzlib` | `luarocks install lzlib` |
| `ipaddress` (stdlib) | Custom CIDR matching (~15 lines) | Trivial port |
| `secrets.compare_digest` | `ngx.encode_base64()` constant-time compare | Or simple `==` for API keys |
| `threading.Lock` | `ngx.shared.DICT` atomic ops or `lua-resty-lock` | `luarocks install lua-resty-lock` |
| `signal` (stdlib) | nginx signal handling | Native |
| `multiprocessing.cpu_count` | Not needed (single-worker nginx) | — |

---

## 6. CI/CD Pipeline (GitHub Actions → Render)

### 6.1 GitHub Actions CI (ci.yml)

```yaml
name: CI

on:
  push:
    branches: [main, master]
  pull_request:

jobs:
  lua-tests:
    runs-on: ubuntu-latest
    services:
      redis:
        image: redis:7
        ports: ["6379:6379"]

    steps:
      - uses: actions/checkout@v4

      - name: Install OpenResty + LuaRocks
        run: |
          sudo apt-get update
          sudo apt-get install -y openresty luarocks libsqlite3-dev
          # Install SQLite 3.45+ from source for JSONB support
          wget https://sqlite.org/2024/sqlite-autoconf-3450000.tar.gz
          tar xzf sqlite-autoconf-3450000.tar.gz
          cd sqlite-autoconf-3450000
          ./configure --prefix=/usr/local
          make -j$(nproc)
          sudo make install
          sudo ldconfig

      - name: Install Lua dependencies
        run: |
          sudo luarocks install busted
          sudo luarocks install lsqlite3 SQLITE_DIR=/usr/local
          sudo luarocks install lua-resty-http
          sudo luarocks install lua-resty-redis
          sudo luarocks install lua-cjson
          sudo luarocks install luaexpat
          sudo luarocks install lua-csv

      - name: Run tests
        run: |
          cd backend-lua
          busted --verbose tests/

      - name: Validate shell scripts
        run: |
          sh -n backup.sh
          find ../scripts -name '*.sh' -exec sh -n {} +

      - name: Validate nginx config
        run: |
          openresty -t -c backend-lua/nginx.conf

  preprocess-prodes:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install GDAL
        run: |
          sudo apt-get update
          sudo apt-get install -y gdal-bin
      - name: Download & convert PRODES TIF → CSV
        run: |
          wget https://terrabrasilis.dpi.inpe.br/download/dataset/brasil-prodes/raster/prodes_brasil_2023.zip
          unzip prodes_brasil_2023.zip
          gdal_translate -of XYZ prodes_brasil_2023.tif prodes_brasil_2023.xyz
          # Convert XYZ to CSV with header
          echo "lon,lat,value" > backend-lua/data/prodes_brasil_2023.csv
          awk '{print $1","$2","$3}' prodes_brasil_2023.xyz >> backend-lua/data/prodes_brasil_2023.csv
      - name: Upload CSV artifact
        uses: actions/upload-artifact@v4
        with:
          name: prodes-csv
          path: backend-lua/data/prodes_brasil_2023.csv
```

### 6.2 Render Deployment

Render supports **Docker** deployments natively. The `Dockerfile`:

```dockerfile
FROM openresty/openresty:jammy

# Install build deps for SQLite 3.45+
RUN apt-get update && apt-get install -y \
    build-essential wget unzip luarocks libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Compile SQLite 3.45+ for JSONB support
RUN wget https://sqlite.org/2024/sqlite-autoconf-3450000.tar.gz \
    && tar xzf sqlite-autoconf-3450000.tar.gz \
    && cd sqlite-autoconf-3450000 \
    && ./configure --prefix=/usr/local \
    && make -j$(nproc) && make install \
    && ldconfig \
    && cd .. && rm -rf sqlite-autoconf-*

# Install Lua rocks
RUN luarocks install lsqlite3 SQLITE_DIR=/usr/local \
    && luarocks install lua-resty-http \
    && luarocks install lua-resty-redis \
    && luarocks install lua-resty-lock \
    && luarocks install luaexpat \
    && luarocks install lua-csv

# Copy app
COPY backend-lua/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY backend-lua/ /opt/yvy/backend-lua/
COPY frontend/build/ /opt/yvy/frontend/build/
COPY backend-lua/data/ /opt/yvy/data/

# Create data dir for SQLite
RUN mkdir -p /opt/yvy/data && chmod 777 /opt/yvy/data

ENV SQLITE_PATH=/opt/yvy/data/yvy.db
ENV REDIS_URL=redis://${REDIS_HOST}:6379/0

EXPOSE 80

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
```

**Render configuration** (`render.yaml`):
```yaml
services:
  - type: web
    name: yvy
    env: docker
    dockerfilePath: ./backend-lua/Dockerfile
    envVars:
      - key: API_KEY
        sync: false
      - key: AUTH_REQUIRED
        value: "1"
      - key: FIRMS_MAP_KEY
        sync: false
      - key: NEWS_API_KEY
        sync: false
      - key: WAQI_TOKEN
        sync: false
      - key: REDIS_URL
        fromService:
          name: yvy-redis
          type: redis
          property: connectionString
      - key: CORS_ORIGINS
        value: "https://yvy.app.br,https://yvy.onrender.com"
    disk:
      name: sqlite-data
      mountPath: /opt/yvy/data
      sizeGB: 10

  - type: redis
    name: yvy-redis
    plan: free
```

---

## 7. Testing Strategy

### 7.1 Test Framework: Busted

[Busted](https://olivinelabs.com/busted/) is the standard Lua test framework. It supports `describe`/`it` blocks, async testing via coroutines, and has a rich assertion library.

### 7.2 Test Categories

| Test File | What It Tests | Ported From |
|-----------|---------------|-------------|
| `test_db.lua` | Schema creation, CRUD, JSONB round-trip, bbox queries, bulk upsert, prune | test_db_sqlite.py + test_sqlite_manual.py |
| `test_api.lua` | HTTP endpoint responses, status codes, auth, rate limiting | `test_api.py` (rewrite) |
| `test_alerts.lua` | Cluster detection, night fire detection, TI/UC intersection, PM2.5 threshold | New (alerts.py has no tests today) |
| `test_geo.lua` | `point_in_ring`, `point_in_polygon` with known fixtures | New |
| `test_translate.lua` | MyMemory warning detection, fallback chain, empty input | New |
| `test_scrapers.lua` | RSS parsing, keyword relevance filter | New |
| `test_biomes.lua` | Biome classification with known lat/lon points | `test_biome_lookup.py` |

### 7.3 Test Runner Integration

```lua
-- tests/test_runner.lua
-- Can be run standalone: busted tests/
-- Or via: lua tests/test_runner.lua

local busted = require("busted")
-- busted handles discovery automatically
```

### 7.4 Mocking Strategy

- **SQLite**: Use `:memory:` database for tests (same as current Python tests)
- **Redis**: Use `lua-resty-redis` pointed at test Redis, or mock with a Lua table
- **HTTP**: Use `ngx.location.capture` for internal redirects, or mock `resty_http` with a test double
- **Time**: Override `ngx.time()` / `os.time()` in tests for deterministic alert windows

---

## 8. Tailwind CSS Consideration

Tailwind is a **frontend** concern — it runs at build time via `react-scripts build` (which invokes PostCSS + Tailwind). The backend migration to Lua has **zero impact** on Tailwind. The frontend build pipeline remains:

```
frontend/
├── src/           # React + Tailwind source
├── tailwind.config.js
├── postcss.config.js
└── package.json   # "build": "react-scripts build"
```

The only change: instead of Express serving the build, nginx serves it directly:
```nginx
location / {
    root /opt/yvy/frontend/build;
    try_files $uri /index.html;
}
```

---

## 9. Risk Assessment & Mitigation

| Risk | Severity | Mitigation |
|------|----------|------------|
| **SQLite JSONB on Render** — must compile SQLite 3.45+ | High | Dockerfile compiles from source; verify in CI |
| **lsqlite3 async safety** — OpenResty is single-threaded per worker, but lsqlite3 calls are synchronous | Medium | Use WAL mode (already); keep queries fast; use connection pool per worker |
| **No rasterio equivalent** — TIF ingestion breaks | Medium | Pre-process TIF → CSV in CI (GDAL); commit CSV to repo |
| **RSS XML parsing** — LuaExpat is SAX-based, different from ElementTree | Low | LuaExpat is well-tested; RSS feeds are simple XML |
| **Background task reliability** — `ngx.timer` has no cancellation | Low | Use flag checks; timers are lightweight in nginx |
| **Render disk persistence** — SQLite on Render disk | Medium | Render disks are network-attached; WAL mode helps; regular backups |
| **Cold start** — Loading JSON polygon data at init | Low | JSON files are small (~2MB total); parsed once at init |
| **Regex differences** — Python `re` vs `ngx.re` (PCRE) | Low | PCRE is a superset; minor syntax adjustments |

---

## 10. Implementation Phases

### Phase 1: Foundation (Week 1-2)
- [ ] Set up OpenResty Dockerfile with SQLite 3.45+
- [ ] Port `db.lua` — schema, connection pool, JSONB helpers
- [ ] Port `geo.lua` — point-in-polygon
- [ ] Port `utils.lua` — JSON, CSV, date helpers
- [ ] Port `auth.lua` + `rate_limit.lua`
- [ ] Write `test_db.lua` + `test_geo.lua`
- [ ] Get CI green on GitHub Actions

### Phase 2: Core API (Week 3-4)
- [ ] Port `fires.lua` — `/api/fires` + FIRMS sync
- [ ] Port `deforestation.lua` — `/api/data`
- [ ] Port `biomes.lua` — `/api/biomes`
- [ ] Port `weather.lua` — air quality + temperature
- [ ] Port indigenous/conservation lands endpoints
- [ ] Write `test_api.lua`
- [ ] Manual integration test against production DB copy

### Phase 3: News & Alerts (Week 5-6)
- [ ] Port `translate.lua` — TranslatorChain
- [ ] Port `scrapers.lua` — RSS + keyword filter
- [ ] Port `news.lua` — full news pipeline
- [ ] Port `alerts.lua` — all 6 alert types
- [ ] Write `test_translate.lua` + `test_alerts.lua` + `test_scrapers.lua`

### Phase 4: Data Pipeline & Migration (Week 7)
- [ ] Set up GDAL pre-processing in CI
- [ ] Port `ingest.lua` — CSV-based PRODES ingestion
- [ ] Port `migrate.lua` — JSONB migration
- [ ] End-to-end test with fresh DB

### Phase 5: Render Deployment (Week 8)
- [ ] Create `render.yaml`
- [ ] Deploy to Render staging
- [ ] Configure custom domain + SSL
- [ ] Smoke test all endpoints
- [ ] Set up Render Redis
- [ ] Performance testing (compare response times vs Python)
- [ ] Cut over DNS from OCI VM → Render

---

## 11. Estimated Effort

| Area | LOC (Python) | LOC (Lua est.) | Effort (days) |
|------|-------------|----------------|---------------|
| db_sqlite.py | ~800 | ~400 | 5 |
| backend.py (routes) | ~600 | ~500 | 8 |
| news_sqlite.py | ~500 | ~400 | 5 |
| news_scrapers.py | ~300 | ~250 | 3 |
| alerts.py | ~300 | ~250 | 4 |
| biome_lookup.py | ~100 | ~80 | 1 |
| _geo.py | ~30 | ~25 | 0.5 |
| indigenous_lands_lookup.py | ~50 | ~40 | 0.5 |
| conservation_units_lookup.py | ~50 | ~40 | 0.5 |
| ingest_sqlite.py | ~150 | ~100 | 2 |
| migrate_to_jsonb.py | ~200 | ~150 | 2 |
| Tests | ~300 | ~500 | 5 |
| Docker/nginx/config | — | ~200 | 3 |
| CI/CD | ~50 (YAML) | ~80 (YAML) | 2 |
| **Total** | **~3,430** | **~3,015** | **~41 days** |

This is a ~2 person-month effort for a solo developer working full-time, or ~2 months at half-time.

---

## 12. Open Questions

1. **Render Redis**: Does Render's managed Redis support the commands we need (`ZREMRANGEBYSCORE`, `ZADD`, `ZRANGEBYSCORE` for rate limiting)? → Yes, it's standard Redis.

2. **Render disk**: Is the 10GB disk sufficient for the SQLite DB? → Currently ~100K fire records + 239 news = well under 100MB. 10GB is plenty.

3. **WebSocket support**: Any plans for real-time updates? → OpenResty supports WebSockets via `lua-resty-websocket` if needed later.

4. **Should we keep Python for TIF ingestion?** → Recommend eliminating it entirely via GDAL pre-processing. Simpler CI, fewer dependencies.

5. **Do we need to support the existing .env format?** → Yes, a simple .env parser in Lua (~20 lines) handles `KEY=VALUE` with comments and quotes.
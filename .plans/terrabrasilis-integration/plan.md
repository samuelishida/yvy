# TerraBrasilis Integration — DETER, CAR, Fires, PRODES

## Context

**Problem:** Yvy currently has FIRMS fire points and PRODES deforestation
raster, but lacks DETER real-time alerts, CAR property-level crossing, and
the "gold standard" FIRMS+DETER+CAR criminal-intelligence pipeline. Without
this, the app cannot distinguish between a routine pasture burn and a
deliberate deforestation-to-fire cycle on a specific rural property.

**Users:** Renata (concerned citizen, returning), Carlos (first-timer).
Alerts must be legible in <20s per PRODUCT.md. The map is primary; all new
alert types must fit the unified floating-panel design.

**Constraints:**
- Backend: Lua 5.1 / copas / SQLite JSONB. Blocking work = detached subprocess.
- No PostGIS; spatial joins must be Python (GeoPandas) or Lua ray-cast.
- VM: ubuntu@137.131.152.151, ~80 GB free, OCI A1 (ARM)
- Frontend: React with Leaflet, dark scientific theme, 2-panel max
- Existing patterns must be followed: `tools/*.lua` detached, `scripts/*.py`
  for batch processing, Busted + temp SQLite for tests

## Architectural decisions

- **Decision 1 — Python GeoPandas for polygon spatial join.**
  Rationale: correct polygon intersection (area overlap), not point-sampling.
  Follows `scripts/render_car_tiles.py`, `scripts/merge_dbs.py` pattern.
  Lua `geo.lua` ray-cast is O(n²) and cannot compute polygon-polygon overlap
  for 163K fire points × ~500 DETER polygons × ~8M CAR. Python runs detached.
  Alternatives rejected: Lua point-sampling — inaccurate; WFS PostGIS
  processing — introduces external service dependency.

- **Decision 2 — Separate DETER CAR-property alerts; protected-area alerts unified.**
  Rationale: CAR-property DETER alerts (one row per affected rural property)
  have a fundamentally different data model (polygon intersection, area, severity)
  from fire-point cluster alerts. They get their own pipeline
  (`tools/deter_car_alerts.lua` → `/api/deter/car-alerts`). DETER in
  protected areas (UC/TI), however, IS a spatial alert like existing
  `indigenous_land` and `conservation_unit` fire types — they belong in the
  unified `/api/alerts` feed alongside fire-based territorial alerts.
  Alternative rejected: all DETER alerts unified in `/api/alerts` — CAR-property
  alerts are too different in data model. All DETER alerts separately —
  UC/TI DETER alerts are the same alert *type* as fire UC/TI alerts.

- **Decision 3 — WFS polygons from the start, with Shapely spatial ops.**
  Rationale: user requires FIRMS+DETER+CAR crossing for criminal intelligence
  (Cenário A/B/C). The Python spatial join uses Shapely's `intersects()` and
  `intersection()` — these replace the Lua ray-cast with correct polygon-
  polygon operations. Shapely handles MultiPolygon, holes, and degenerate
  geometries robustly. Aggregated JSON (municipality×class×date) is useful for
  stats but cannot identify *which* CAR property was affected — so WFS
  polygons are primary; the aggregate is still ingested (Inc 2 `deter_alerts`)
  for historical backfill and long-term stats. Alternative rejected: start
  with aggregated JSON only — insufficient for core use case.

- **Decision 4 — New tables `deter_polygons`, `deter_car_alerts`,
  `deter_alerts`, `ams_risk`.**
  Rationale: follows existing JSONB + scalar-column pattern from
  `fire_data`. `deter_polygons` stores raw DETER for rendering;
  `deter_car_alerts` stores the CAR-crossed result (lightweight, one
  row per affected property); `deter_alerts` holds the municipality×class×date
  aggregate for historical stats; `ams_risk` stores AMS propagation-risk
  layers (Inc 11). Alternative rejected: extend `fire_data` or `lookup_data` —
  mixing fire and deforestation semantics.

- **Decision 5 — PRODES 2025 automation as version-check + re-ingest.**
  Rationale: current `ingest.lua` skips if `count_deforestation() > 0`;
  auto-update needs a `PRODES_FORCE_UPDATE=1` flag and version tracking.
  New TerraBrasilis version detected via HTTP HEAD on the versioned TIF URL;
  if new version exists, download → `prodes_geotiff_to_csv.py` →
  `ingest.lua PRODES_FORCE_UPDATE=1`. URL pattern:
  `https://terrabrasilis.dpi.inpe.br/download/dataset/brasil-prodes/raster/prodes_brasil_<YYYY>_v<YYYYMMDD>.zip`
  (verified working for 2024/v20260407).
  Alternative rejected: manual update only — user explicitly requested
  automation.

- **Decision 6 — BdQueimadas as complementary fire source, not replacement.**
  Rationale: NASA FIRMS is the primary fire source (already working);
  BdQueimadas has different temporal coverage, different satellites, and
  different detection algorithms. Both sources enrich the data. Deduplication
  on (lat,lon,acq_date) as both detect the same physical fires.
  Alternative rejected: replace FIRMS — risk of data gap if BdQueimadas
  API is down.

- **Decision 7 — AMS as an overlay, not a new alert feed.**
  Rationale: AMS fire-spreading-risk (spec P2) is a contextual layer over
  existing fires, not a new alert type; it renders as an optional map overlay
  + fire-popup field, avoiding alert fatigue (R6).
  Alternative rejected: AMS as alert feed — duplicated signal with DETER/fire
  alerts.

- **Decision 8 — Live per-property PRODES lookup, not precomputed table.**
  Rationale: verifying PRODES by CAR receipt is an on-demand, single-property
  query; `idx_def_bbox (lat, lon)` on deforestation_data + `car_data.cod_imovel
  UNIQUE` make it cheap in Lua with no new tables. Redis caches repeat
  lookups (TTL 86400).
  Alternative rejected: precompute PRODES presence for all ~8M CAR properties —
  wasteful; only justified if query latency proves too high.

## Assumptions and answers from code

| # | Assumption / Question | Source |
|---|---|---|
| A1 | Detached subprocess pattern (`nohup lua5.1 tools/<script>.lua &`) is the approved way to run blocking work. | Code: `backend-lua/app/routes/news.lua:trigger_news_sync()` and `classify_fires.lua` |
| A2 | New DB tables use `CREATE TABLE IF NOT EXISTS` — safe to add without migration tooling. | Code: `backend-lua/app/db.lua:39-82` (fire_data, deforestation_data, news, lookup_data) |
| A3 | CAR RTree (`car.db`) exposes bbox-intersect queries; ray-cast `point_in_polygon` exists in Lua. | Code: `backend-lua/app/lookups/car_lookup.lua:classify_point()` |
| A4 | Fire nature classification already runs `crime/suspeito/natural/permitido` tier. | Code: `backend-lua/app/fire_classify.lua` |
| A5 | PRODES ingest skips if `count_deforestation() > 0`. | Code: `backend-lua/app/ingest.lua:run()` |
| A6 | Testing pattern: Busted + temp SQLite + `package.loaded["app.db"] = nil`. | Code: `backend-lua/tests/test_db.lua:setup()` |
| A7 | Deployment preserves SQLite across deploys via predeploy backup/restore. | Code: `ansible/playbook.yml` lines 154-201 |
| D1 | User wants P1+P2+P3 as a single plan (all three tiers). | User-confirmed (question gate) |
| D2 | Python GeoPandas for spatial join, not Lua ray-cast. | User-confirmed (question gate) |
| D3 | Separate DETER alert pipeline. | User-confirmed (question gate) |
| D4 | WFS polygons from the start, not aggregated JSON. | User-confirmed (question gate) |

## Risks accepted

- **R1 — GeoPandas/shapely on ARM VM**: OCI A1 is ARM (Ampere). `shapely`
  and `rasterio` may need `libgeos-dev` and compilation. *Mitigate: verify
  in Inc 1; fallback to `pip install` with binary wheels if available.*
- **R2 — WFS polygon volume**: DETER daily polygons can be large (~20 MB
  GeoJSON/day). One year = ~7 GB raw. *Mitigate: only store last 90 days
  of raw polygons in `deter_polygons`; `deter_alerts` (Inc 2) keeps the full
  municipality × class × date history in aggregate form (backfilled from
  `deter-amazon-daily.json`).*
- **R3 — CAR × DETER spatial join performance**: ~500-2000 DETER polygons/day
  × ~8M CAR imóveis is O(billion). *Mitigate: pre-filter by bbox (RTree on
  both sides), batch by UF, run nightly.*
- **R4 — WAL growth during bulk DETER writes**: large write batches bloat
  WAL. *Mitigate: checkpoint after each batch; VACUUM weekly.*
- **R5 — BdQueimadas API reliability**: INPE services have variable uptime.
  *Accept; FIRMS is the primary source.*
- **R6 — Frontend alert-fatigue**: adding multiple alert feeds (deter_protected,
  deter_car, fire-vegetation context) on top of 6 existing alert types.
  *Mitigate: severity-tiering rule — unified panel shows top 2 CRIT alerts +
  1 newest WARN alert. "Show all" expands. CAR-property alerts are in their
  own panel. Palette: CRIT=fire-gradient, DEFORESTATION=amber, PROTECTED=red.*

## Increment DAG

```
Inc 1 — DB migration + Python env (S)
  Deps: none → Unblocks: 2, 5, 9, 11

Inc 2 — DETER WFS ingest + aggregate + polygon API (M)
  Deps: 1 → Unblocks: 3, 6, 7

Inc 3 — CAR × DETER spatial join + deter_car_alerts (L)
  Deps: 2 → Unblocks: 4

Inc 4 — FIRMS × DETER crossover classification (M)
  Deps: 3 → Unblocks: none

Inc 5 — PRODES 2025 auto-update pipeline (S)
  Deps: 1 → Unblocks: none

Inc 6 — DETER in protected areas (UC/TI) alerts (M)
  Deps: 2 → Unblocks: none

Inc 7 — Territorial deforestation stats (by-municipality/UC/TI) (M)
  Deps: 2 → Unblocks: none

Inc 8 — Fire × vegetation crossing (fire in forest vs. deforested) (M)
  Deps: 1 → Unblocks: none

Inc 9 — TerraClass + Cerrado vegetation + Vegetação Secundária ingest (M)
  Deps: 1 → Unblocks: none

Inc 10 — BdQueimadas complementary fire source (L)
  Deps: 1 → Unblocks: none

Inc 11 — AMS fire-spreading-risk + active-fire overlay (M)
  Deps: 1 → Unblocks: none

Inc 12 — Property PRODES verification by CAR receipt (M)
  Deps: none → Unblocks: none
```

Parallelism: Inc 5, 9, 10, 11 can run alongside 2-8. Inc 6 and 7 run in
parallel right after 2 (deps relaxed from Inc 3). Inc 8 runs anytime after 1.
Inc 12 has no deps — can run first if preferred (uses existing car.db +
deforestation_data + idx_def_bbox).

## Increments

### Inc 1 — DB migration + Python tool scaffold (S)
**Status:** done (2026-08-07)
**Depends on:** none
**Unblocks:** 2, 5, 9, 11
**Done criteria:** `deter_polygons`, `deter_car_alerts`, `deter_alerts`,
`ams_risk` tables exist; Python venv has geopandas/shapely/rasterio.

#### Files to touch

##### backend-lua/app/db.lua
- What changes: add `deter_polygons`, `deter_car_alerts`, `deter_alerts`,
  `ams_risk`, and `idx_fire_source` index to SCHEMA:
  `CREATE INDEX IF NOT EXISTS idx_fire_source ON fire_data(json_extract(data,'$.source'))`
- Function(s): `_M.init_db()` — new CREATE TABLE IF NOT EXISTS blocks
- Data shapes:
  - `deter_polygons`: `id PK`, `classname TEXT`, `view_date TEXT`, `uf TEXT`,
    `municipality TEXT`, `mun_geocod TEXT`, `area_km2 REAL`, `uc TEXT` (native
    DETER attr, NULL when empty), `areauckm REAL`, `areamunkm REAL`,
    `publish_month TEXT`, `sensor TEXT`, `satellite TEXT`, `min_lat REAL`,
    `min_lon REAL`, `max_lat REAL`, `max_lon REAL` (bbox computed at insert by
    Python — indexed bbox queries, mirrors the `car_rtree`/`find_fires` scalar
    pattern), `geom BLOB` (JSONB MultiPolygon), `ingested_at TEXT`
    + `CREATE INDEX idx_deter_bbox ON deter_polygons(min_lat, min_lon, max_lat, max_lon)`
  - `deter_car_alerts`: `id PK`, `cod_imovel TEXT`, `classname TEXT`,
    `view_date TEXT`, `uf TEXT`, `municipio TEXT`, `area_afetada_ha REAL`,
    `fire_count INTEGER`, `fire_dates TEXT` (JSON array), `severity TEXT`
    (`maximo`|`alto`|`medio`|`baixo`), `ingested_at TEXT`,
    UNIQUE(`cod_imovel`, `classname`, `view_date`) — nightly re-runs upsert
  - `deter_alerts`: `id PK`, `mun_geocod TEXT`, `classname TEXT`,
    `view_date TEXT`, `area_km2 REAL`, `uf TEXT`, `ingested_at TEXT`,
    UNIQUE(`mun_geocod`, `classname`, `view_date`) — daily aggregate
    (spec P1: geocod × classe × data × área)
  - `ams_risk`: `id PK`, `view_date TEXT`, `viewed_at TEXT`, `satelite TEXT`,
    `municipio TEXT`, `biome TEXT`, `geocode TEXT`, `layer TEXT`
    (`fire-spreading-risk`|`active-fire-today`), `risk_level TEXT` (NULL for
    points), `min_lat REAL`, `min_lon REAL`, `max_lat REAL`, `max_lon REAL`
    (bbox for `get_ams_risk_at` nearest lookup), `geom BLOB` (JSONB),
    `ingested_at TEXT`
    + `CREATE INDEX idx_ams_bbox ON ams_risk(min_lat, min_lon, max_lat, max_lon)`
- Integration points: `init_db()` called from `init.startup()` (existing path)
- Error paths: table already exists (NOOP); migration failure → app starts without new tables (graceful)

##### scripts/requirements.txt (new)
- What changes: create Python dependency file (follows existing `scripts/` pattern —
  all Python scripts live there)
- Contents: `geopandas==0.14.4`, `shapely==2.0.6`, `requests==2.31.0`, `rasterio==1.3.10`
  (pinned for ARM reproducibility; exact versions tested on OCI A1)

##### scripts/setup-python-env.sh (new)
- What changes: create venv + pip install requirements
- Function(s): idempotent setup (`python3 -m venv .venv && .venv/bin/pip install -r scripts/requirements.txt`)
- Integration points: called by `scripts/setup-lua.sh` (extend to `pip install -r scripts/requirements.txt`
  after LuaRocks installs)
- Error paths: pip failure → exit 1 with actionable message; ARM wheel missing →
  `apt install libgeos-dev` + retry hint

##### scripts/setup-lua.sh (existing, modify)
- What changes: add Python venv setup line at end
- Integration points: existing deploy pipeline (ansible) calls this script

#### Edge cases
- Existing DB already has these tables (re-run init) → NOOP
- VM has ARM architecture → verify pip binary wheels available; fallback to `apt install libgeos-dev` + compile

#### Verification
- Run: `sqlite3 yvy.db ".schema deter_polygons"` → shows table def (plus
  `.schema deter_alerts` and `.schema ams_risk`)
- Run: `source .venv/bin/activate && python3 -c "import geopandas; print('OK')"`
- Tests: extend `test_db.lua` with table-existence check for new tables
- Done: tables exist in test DB; Python venv imports geopandas without error

---

### Inc 2 — DETER WFS ingest + aggregate + polygon API (M)
**Status:** done (2026-08-07)
**Depends on:** Inc 1
**Unblocks:** 3, 6, 7
**Done criteria:** WFS polygons downloaded, stored in `deter_polygons`; daily
aggregate (municipality × class × date) in `deter_alerts`; both served via
`/api/deter/polygons` and `/api/deter/stats`.

#### Files to touch

##### scripts/download_deter_wfs.py (new)
- What changes: fetch DETER polygons from TerraBrasilis WFS, write to SQLite.
  Persists ALL native WFS attributes (spec §3.2): `uc`, `areauckm`,
  `areamunkm`, `publish_month`, `sensor`, `satellite` — used by Inc 6/7
  without extra spatial computation.
- FIRST STEP: run `DescribeFeatureType` on the DETER layer and confirm the
  incremental filter field (`view_date` vs `published_date`/`revised_date`) —
  `run_incremental` depends on the exact CQL field name
- Function(s):
  - `fetch_deter(workspace, layer, start_date, end_date) → GeoDataFrame`
    (page with `startIndex`/`maxFeatures` — GeoServer caps ~10k features, same
    as `download_car_wfs.py`)
  - `to_sqlite(gdf, db_path) → int` (rows inserted)
  - `run_incremental(db_path)` — fetches since last stored `view_date`
- Data shapes:
  - WFS input: GeoJSON FeatureCollection (MultiPolygon + properties)
  - Output: rows in `deter_polygons` (native attrs as scalar columns; `geom`
    stored as **JSON TEXT**, NOT `jsonb()` — Python's sqlite3 may link SQLite
    < 3.45 without the `jsonb()` function; Lua `json()`/`json_extract()` read
    TEXT fine, so this avoids a version dependency)
  - `to_sqlite` computes and persists `min_lat/min_lon/max_lat/max_lon` per
    polygon (shapely `bounds`) — the bbox API and the Inc 6/11 scans depend on
    those columns
- Integration points: called by systemd timer (cron) daily at 04:00, first step
  of `scripts/deter_daily.sh`; also by Inc 5's PRODES auto-update when DETER
  ref period changes
- Error paths: WFS timeout (retry 3× with backoff); empty response (log warn, skip);
  parse error (log error + individual polygon, skip bad rows)

##### scripts/backfill_deter_alerts.py (new)
- What changes: backfill historical DETER aggregates from the dashboard JSON
  `deter-amazon-daily.json` (~20 MB, per municipality × class × date, spec §2.2)
  into `deter_alerts`; also `rollup_to_deter_alerts(db_path)` upserts the last
  day's `deter_polygons` into the same table (spec P1: DETER agregado diário)
- Function(s):
  - `backfill_from_dashboard(json_path, db_path)` — idempotent (UNIQUE key)
  - `rollup_to_deter_alerts(db_path)` — sum polygon area per
    (mun_geocod, classname, view_date)
- Data shapes: row = `{mun_geocod, classname, view_date, area_km2, uf}`; the
  dashboard JSON has TWO area fields (`d`, `e`) per municipality×class×date —
  verify their semantics on first run (dashboard JS / DescribeFeatureType) and
  store the one matching polygon-derived km² as `area_km2` (add `area_km2_alt`
  if both are meaningful, e.g. per-UC vs per-municipality)
- Integration points: second step of `scripts/deter_daily.sh` after download;
  run once on deploy for the historical backfill
- Precedence: rollup (polygon-derived) WINS for recent days; backfill only fills
  gaps (days with no `deter_alerts` row) — prevents the dashboard from
  overwriting polygon-derived areas on overlapping days
- Error paths: JSON unavailable → skip backfill (rollup still runs); bad rows → skip + log

##### backend-lua/app/routes/deter.lua (new)
- What changes: `/api/deter/polygons` bbox route + `/api/deter/stats` aggregate
- Function(s): `_M.get_polygons(ctx)`, `_M.get_stats(ctx)`
- Data shapes:
  - `GET /api/deter/polygons?sw_lat=&ne_lat=&sw_lng=&ne_lng=&days=7` →
    `{polygons: [{id, classname, view_date, uf, municipality, area_km2, geom}]}`
  - `GET /api/deter/stats?days=30` →
    `{total_km2, by_class: [{name, km2}], by_uf: [{uf, km2}], by_day: [{date, km2}],
      by_municipality: [{mun_geocod, name, km2}]}` — `by_municipality` reads
      `deter_alerts` (full history), the rest read the 90-day polygon window
- Integration points: registered in `main.lua` via `server.route("GET", "/api/deter/polygons", deter.get_polygons)`
- Error paths: invalid bbox → 400; DB read error → 500

##### backend-lua/app/db.lua
- What changes: add `get_deter_polygons(sw_lat, ne_lat, sw_lng, ne_lng, days, limit)`,
  `get_deter_stats(days)`, `get_deter_alerts(mun_geocod, classname, days)` functions
- Data shapes: same as `find_fires` pattern — bbox + date filter + JSONB decode
- Integration points: called from `routes/deter.lua`

##### backend-lua/main.lua
- What changes: `require("app.routes.deter")` + register new routes
- Integration points: alongside existing `server.route(...)` calls

#### Edge cases
- WFS has no new data → download script exits 0 (no insert)
- Polygon has MULTIPOLYGON geometry → store as-is in JSONB
- DETER Pantanal / Cerrado (additional workspaces) → script parameterizes workspace
- Historical stats (beyond the 90-day polygon window, R2) → served from
  `deter_alerts` (backfilled from `deter-amazon-daily.json` + daily rollup)
- Missing WFS attrs (e.g. `uc` empty for Cerrado) → NULL; Inc 6 falls back
  to spatial centroid logic
- SQLite write discipline (Python writers run while the Lua backend is up):
  set `busy_timeout`, commit in batches (≤1000 rows), checkpoint after the
  batch — WAL has a single writer

#### Verification
- Run: `bash scripts/deter_daily.sh` → check `sqlite3 yvy.db "SELECT COUNT(*) FROM deter_polygons"`
  and `SELECT COUNT(*) FROM deter_alerts`
- Run: `curl http://localhost:5000/api/deter/polygons?sw_lat=-20&ne_lat=0&sw_lng=-60&ne_lng=-40&days=7`
- Run: `curl http://localhost:5000/api/deter/stats?days=30` → includes `by_municipality`
- Tests: `test_deter.lua` — fake WFS response + verify DB write + rollup into
  `deter_alerts` + verify API
- Done: polygons + aggregates queryable via API; stats returns by_municipality

---

### Inc 3 — CAR × DETER spatial join + deter_car_alerts (L)
**Status:** done (2026-08-07)
**Depends on:** Inc 2
**Unblocks:** 4
**Done criteria:** Nightly Python script crosses DETER polygons against CAR; `deter_car_alerts` populated; served at `/api/deter/car-alerts`.

#### Files to touch

##### scripts/cross_deter_car.py (new)
- What changes: TWO passes over `car.db` × `fire_data` × `deforestation_data`,
  output `deter_car_alerts`. Uses Shapely `intersects()`/`intersection()` for
  correct polygon-polygon operations (replaces Lua ray-cast).
  - **Pass 1 (DETER-driven → maximo/alto)**: DETER polygons (deter_polygons) ×
    CAR polygons → one row per affected property (Cenário A/C).
  - **Pass 2 (fire-driven → medio/baixo)**: fire_data × CAR × PRODES, for CAR
    properties with fires but NO recent DETER (Cenário B). Without this pass
    `medio`/`baixo` can never be generated — a DETER-driven model can't see
    properties that have fires but no alert.
- Function(s):
  - `load_deter_recent(db_path, days) → GeoDataFrame`
  - `load_car_by_bbox(db_path, bbox, uf) → GeoDataFrame` (RTree bbox-intersect
    → Shapely `contains()` for precise filtering)
  - `load_prodes_points(db_path, bbox) → GeoDataFrame` (for Cenário B)
  - `compute_overlap(deter_gdf, car_gdf) → DataFrame` (intersection area per pair)
  - `classify_severity(row, prodes_gdf) → str` — implements Cenário A/B/C logic
  - `cross_fire_data(deter_row, fires_db) → {count, dates}` — checks fire_data
    for fires in the CAR property ±7 days of DETER date
  - `cross_fires_no_deter(fires_db, car_db, prodes_db, days) → DataFrame` —
    Pass 2: aggregate fires per CAR property (7-day window), skip properties
    with a recent DETER (checked against `deter_polygons`), `severity=medio`
    when PRODES `dYYYY` is at the fire point, else `baixo`
  - `run_daily(db_path, car_db_path)` — orchestrates Pass 1 + Pass 2 per UF,
    runs after `download_deter_wfs.py`
- Data shapes: `deter_car_alerts` row = `{cod_imovel, classname, view_date, uf,
  municipio, area_afetada_ha, fire_count, fire_dates, severity}` where:
  - `area_afetada_ha` = `intersection(DETER, CAR).area / 10000` (Pass 1); Pass 2
    rows use `classname="FIRMS"`, `area_afetada_ha=0`, `view_date` = latest fire
    date (alert is fire-driven, not DETER-driven)
  - `severity` logic (requires `deter_polygons` + `fire_data` + `deforestation_data`):
    - `maximo` = FIRMS + DETER no mesmo CAR em ≤7 dias (Cenário C)
    - `alto` = DETER sem fogo associado (Cenário A)
    - `medio` = FIRMS sem DETER, fogo em área já desmatada (PRODES dYYYY no local)
    - `baixo` = FIRMS sem DETER, fogo em vegetação nativa (sem PRODES no local)
  - `fire_dates` = JSON array of acq_date strings from fire_data
- Integration points: called after `download_deter_wfs.py` via a shell wrapper
  `scripts/deter_daily.sh` (chains: download → cross → write deter_car_alerts)
- Error paths: empty DETER set → skip (no-op); CAR query timeout (500K candidates)
  → batch and resume; geometry TopologyException → skip ± log individual polygon

##### backend-lua/app/routes/deter.lua
- What changes: add `_M.get_car_alerts(ctx)` function
- Data shapes:
  - `GET /api/deter/car-alerts?uf=&municipio=&severity=&days=7&page=1&page_size=20` →
    `{alerts: [...], total, page, page_size}`
- Integration points: alongside `get_polygons` in same module

##### backend-lua/app/db.lua
- What changes: add `get_car_alerts(uf, municipio, severity, days, page, page_size)`,
  `get_car_alert_stats(days)` functions
- Data shapes: paginated alerts with optional filters; stats = `{total, by_severity, by_uf}`
- Integration points: called from `routes/deter.lua`

#### Edge cases
- CAR property has multiple DETER polygons → aggregate (sum area, max severity)
- DETER polygon overlaps multiple CAR properties → one row per CAR; each row
  gets its EXACT `intersection(DETER, CAR).area` (Shapely) — no proportional
  split (the sum across CARs may exceed the DETER area when properties overlap)
- No fire_data for the property → `fire_count=0`, `severity=alto` (Cenário A)
- Property with fires but a recent DETER → Pass 1 handles it (maximo/alto);
  Pass 2 skips it (no duplicate medio/baixo row)
- Multiple fire clusters on the same property → ONE Pass-2 row (aggregated,
  `view_date` = latest fire date in the window)
- Old deter_car_alerts (90+ days) → archive/delete
- Re-run safety: UNIQUE(cod_imovel, classname, view_date) (schema in Inc 1) +
  `INSERT ... ON CONFLICT DO UPDATE` — running the cross twice must not duplicate

#### Verification
- Run: `bash scripts/deter_daily.sh` (download + rollup + cross)
- Run: `curl http://localhost:5000/api/deter/car-alerts?severity=maximo`
- Run: `curl http://localhost:5000/api/deter/car-alerts?severity=medio` → non-empty
  (validates the fire-driven Pass 2)
- Tests: `test_deter_car.lua` — mock deter_polygons + car.db + fire_data, verify
  both passes (maximo/alto from DETER, medio/baixo from fires without DETER)
- Validate against INPE ground truth (spec §2.3): compare monthly area sums with
  `fires-dashboard/deter/raster/deter_agregado_amz_cerrado.zip` and
  `.../car/raster/car_categories_amz_cerrado.zip` — tolerance ±5%; divergence
  logged as drift sentinel, never fails the run
- Done: CAR alerts queryable; severity classification visible in API response

---

### Inc 4 — FIRMS × DETER crossover classification (M)
**Status:** done (2026-08-07)
**Depends on:** Inc 3
**Unblocks:** none
**Done criteria:** `fire_data.nature_evidence` enriched with DETER context; existing fire-classification pipeline uses DETER data.

#### Files to touch

##### tools/enrich_fire_deter.lua (new, detached subprocess)
- What changes: for each fire in `fire_data` (last 7 days), check if it falls within
  a CAR property that has a row in `deter_car_alerts`. Enrich `nature_evidence`,
  handling BOTH row kinds from Inc 3:
  - real DETER classnames (e.g. `DESMATAMENTO_VEG`) → `has_deter_nearby=true`
  - Pass-2 `classname="FIRMS"` rows (fire-driven medio/baixo) →
    `has_deter_nearby=false`, `deter_classname=null`, severity copied from the
    row — do NOT label a fire as having a DETER alert when it doesn't
- Function(s):
  - `classify_with_deter(fire_row) → {deter_class, car_imovel, overlap, severity}` —
    branches on `classname == "FIRMS"` vs real DETER classes
  - `run()` — iterate recent fires, check CAR lookup → get car_alerts, update
- Data shapes: enriches existing `nature_evidence` JSONB field:
  ```json
  { "territory": {...}, "thermal": {...}, "deter": {
      "has_deter_nearby": true,
      "deter_classname": "DESMATAMENTO_VEG",
      "deter_view_date": "2026-08-06",
      "car_imovel": "BR-RO-1100304-XXXXX",
      "severity": "maximo"
  }}
  ```
  Pass-2 case: `{ "deter": { "has_deter_nearby": false, "deter_classname":
  null, "deter_view_date": null, "car_imovel": "BR-...", "severity":
  "medio" } }`
- Integration points: invoked by `/api/admin/fires/classify` (existing admin route,
  add step after nature classification); also runs standalone via cron
- Error paths: CAR lookup fails for point → skip; no deter_car_alerts for property → no enrichment

##### backend-lua/app/fire_classify.lua
- What changes: `classify_fire()` optionally reads `deter_car_alerts` via CAR lookup
  + DB query; passes DETER context to nature decision
- Data shapes: no schema change; internal classification may upgrade `suspeito` →
  `crime` if DETER confirms deforestation on same property within 7 days
- Integration points: existing `classify_fire()` call site in `tools/classify_fires.lua`

#### Edge cases
- Fire at (lat,lon) without CAR match → no DETER enrichment possible
- DETER alert for same day as fire → `severity=maximo` (Cenário C activated)
- Multiple DETER classes overlap → take worst (DESMATAMENTO_VEG > CICATRIZ_DE_QUEIMADA)

#### Verification
- Run: `lua5.1 tools/enrich_fire_deter.lua` → check `sqlite3 yvy.db "SELECT nature_evidence FROM fire_data WHERE json_extract(nature_evidence,'$.deter') IS NOT NULL LIMIT 3"`
- Tests: `test_fire_classify.lua` — add test case with mock DETER data
- Validate against the INPE fires dashboard ("Queimadas X Desmatamento — Queimadas
  X CAR", spec §2.2): sampled `severity=maximo` fires should match the dashboard's
  CRIT classifications for the same region/day (spot-check, manual)
- Done: fire rows have `.deter` in nature_evidence; severity upgrade logic tested

---

### Inc 5 — PRODES 2025 auto-update pipeline (S)
**Status:** done (2026-08-07)
**Depends on:** Inc 1
**Unblocks:** none
**Done criteria:** systemd timer or cron checks daily for new PRODES version on
TerraBrasilis; if detected, downloads, converts, and re-ingests automatically.

#### Files to touch

##### scripts/check_prodes_update.sh (new)
- What changes: bash wrapper — detect the newest PRODES raster on TerraBrasilis
  and compare with `backend-lua/data/.prodes_version`, trigger update if newer.
  Detection (a HEAD on a versioned URL requires knowing the release date):
  probe candidate `prodes_brasil_<YYYY>_v<YYYYMMDD>.zip` suffixes over the last
  ~90 days (newest date first, stop at first 200) OR scrape the downloads index
  (`/downloads/`) and regex the newest zip
- Data shapes: `.prodes_version` = plain text file, e.g. `prodes_brasil_2024_v20260407`
- Integration points: called by systemd timer or cron daily

##### scripts/prodes_geotiff_to_csv.py (existing, modify)
- What changes: parameterize year/version (currently hardcoded `prodes_brasil_2024_v20260407`);
  accept `--version` / `--base-dir` flags
- Data shapes: input = `{base_dir}/{version}/{version}.tif`; output = `{base_dir}/{version}/{version}.csv`
- Error paths: TIF missing → exit 1 with message; conversion failure → exit 1

##### backend-lua/app/ingest.lua (existing, modify)
- What changes: add `PRODES_FORCE_UPDATE` env-var check; when set, take a safety
  backup (`sqlite3 .backup yvy.db.preprodes`), then truncate `deforestation_data`
  before re-ingesting. Also accept `PRODES_VERSION` env to override file path pattern.
- Function(s): `_M.run()` — if `PRODES_FORCE_UPDATE=1` → `PRAGMA wal_checkpoint(TRUNCATE)`
  → `sqlite3 .backup` → `DELETE FROM deforestation_data` → proceed with ingest
- Data shapes: unchanged CSV ingest
- Error paths: checkpoint fails → retry 2×; backup fails → abort (don't delete);
  delete fails (DB locked) → retry 3×; ingest fails → restore from the binary
  snapshot: stop service → `mv yvy.db.preprodes yvy.db` → restart. NEVER
  `sqlite3 yvy.db < backup` — that only works for `.dump` text, not a binary
  snapshot. **Implemented**: backup via `VACUUM INTO yvy.db.preprodes` (SQLite
  ≥3.27, no sqlite3 CLI dependency — same standalone snapshot as `.backup`)
- Restore automation: the tool runs detached and cannot `systemctl` alone — the
  calling timer does `sudo systemctl stop yvy-backend` → `mv` → `start`; if that
  fails, log and leave the backup for manual operator restore

##### ansible/playbook.yml (existing, modify)
- What changes: add systemd timer `yvy-prodes-check.timer` + `yvy-prodes-check.service`
  that runs `check_prodes_update.sh` daily
- Integration points: alongside existing `yvy-backend` / `yvy-frontend` service definitions

#### Edge cases
- PRODES 2025 not yet released → script HEAD returns 404 → NOOP
- PRODES 2025 released but same version as current → skip
- Download interrupted → resume/reset with `.part` marker
- Ingest in progress while user queries → WAL allows concurrent reads; writes lock

#### Verification
- Run: `PRODES_FORCE_UPDATE=1 PRODES_VERSION=prodes_brasil_2024_v20260407 bash scripts/run-lua.sh`
  → verify re-ingestion produces same 2,001,410 rows
- Tests: `test_ingest.lua` — test PRODES_FORCE_UPDATE flag behavior (mock DB with existing rows, verify delete + re-ingest + backup creation)
- Done: `.prodes_version` file updated; systemd timer shows active

---

### Inc 6 — DETER in protected areas alerts (M)
**Status:** done (2026-08-07)
**Depends on:** Inc 2
**Unblocks:** none
**Done criteria:** DETER polygons inside UC/TI generate dedicated alerts; visible in
`/api/alerts` feed as `deter_protected` entries.

#### Files to touch

##### tools/deter_protected_alerts.lua (new, detached subprocess)
- What changes: nightly scan: for each DETER polygon inside a UC or TI, generate
  alert entries. Uses the native `uc` attribute (INPE-computed, persisted by
  Inc 2, possibly multi-valued) for UC detection; falls back to centroid
  point-in-polygon when `uc` is empty. TI has no native attribute → centroid
  against TI rings.
- Function(s):
  - `classify_deter_territory(deter_row) → {uc, ti}` — splits `deter_row.uc`
    on separators (`,`/`;`) into a list of UCs; falls back to centroid
    point-in-polygon against UC rings when empty; then centroid against TI
    rings; returns names if inside
  - `run()` → scans `deter_polygons` (last 30 days), records alerts
- Data shapes: writes to `alerts:deter_protected` Redis key (JSON array),
  TTL = 86400. Alert shape matches existing cluster/TI/UC pattern in
  `generate_all_alerts()`.
- Observability: writes outcome to `tools/deter_protected_alerts.log`;
  Redis key `alerts:deter_protected` TTL=86400 doubles as sentinel
  (missing key = stale or failed run)
- Integration points: alert results consumed by `routes/alerts.lua`
  `generate_all_alerts()`, which already generates TI/UC fire alerts —
  DETER-in-protected-area entries are a natural extension (same alert type
  shape, new `data_source` field)
- Error paths: UC/TI rings not loaded → skip, log warn; polygon centroid
  computation fails → skip individual polygon

##### backend-lua/app/routes/alerts.lua (existing, modify)
- What changes: `generate_all_alerts()` reads `alerts:deter_protected` from Redis,
  adds alert entries of type `deter_protected`; tick tiered by class/area —
  `crit` for MINERACAO/DESMATAMENTO_CR/DESMATAMENTO_VEG or any alert >50 ha,
  `warn` for CICATRIZ_DE_QUEIMADA/DEGRADACAO (per R6, avoid alert fatigue)
- Data shapes: alert entry = `{id, type="deter_protected", tick="crit"|"warn",
  meta="UC Jamanxim · 45 ha DETER", state="DESMATAMENTO_VEG · 2026-08-06",
  area_ha=45.2, classname="DESMATAMENTO_VEG"}` (tick from the class/area rule)
- Error paths: Redis key missing → skip (no-op)

##### frontend/src/components/Home.js (existing, modify)
- What changes: render `deter_protected` entries in the unified alert panel
  (palette PROTECTED=red, per R6) — new alert type from `/api/alerts`
- Data shapes: reads `type="deter_protected"` entries; shows `meta`
  ("UC Jamanxim · 45 ha DETER") + `state` ("DESMATAMENTO_VEG · 2026-08-06")
- Integration points: alert feed renderer alongside `indigenous_land` /
  `conservation_unit` types

#### Edge cases
- DETER polygon is split across UC boundary → use native `areauckm`/`area_km2`
  ratio when available; include polygon if ratio ≥ 10% (catch small incursions,
  per review)
- Multiple DETER polygons in same UC on same day → aggregate
- UC/TI lookup data not loaded → skip, log warn

#### Verification
- Run: `lua5.1 tools/deter_protected_alerts.lua` → check Redis `alerts:deter_protected`
- Run: `curl http://localhost:5000/api/alerts` → should contain `deter_protected` type
- Tests: `test_alerts.lua` — mock DETER data in DB, verify alert generation
- Done: DETER protected-area alerts in the alert feed

---

### Inc 7 — Territorial deforestation stats (M)
**Status:** done (2026-08-07)
**Depends on:** Inc 2
**Unblocks:** none
**Done criteria:** Routes serve deforestation area aggregated by municipality, UC, and TI.
PRODES historical data queryable by territory.

#### Files to touch

##### scripts/download_aux_layers.py (new)
- What changes: fetch territorial polygon layers missing from the repo —
  `municipalities_<biome>` (WFS, spec §3.4) and refreshed UC/TI polygons;
  write to `backend-lua/data/`. NOTE: the repo currently has
  `states_brazil.geojson`, `conservation_units.json`, `indigenous_lands.json`
  but NO municipality polygons — by-municipality stats are impossible without
  this layer.
- Function(s):
  - `fetch_wfs(workspace, layer) → GeoDataFrame` (paginated, startIndex)
  - `save(geo_dir, name, gdf)` → GeoJSON
- Integration points: run once at Inc 7 start (and on refresh cron); consumed
  by `precompute_deforestation_stats.py`
- Error paths: WFS unavailable → abort Inc 7 with message (no stats without polygons)

##### scripts/precompute_deforestation_stats.py (new)
- What changes: offline precomputation (daily cron): spatial join
  `deforestation_data` points (from yvy.db) against UC, TI, municipality
  polygon layers (from GeoJSON/lookup_data) → aggregate area by territory.
  Writes results to `lookup_data` as JSON blobs.
- Function(s):
  - `aggregate_deforestation_by_territory(db_path, geo_dir, output_path)`
  - Uses Shapely `contains()` for point-in-polygon (large PRODES point set;
    batch by UF, use spatial index)
- Data shapes: stores precomputed stats as JSON blobs keyed by
  `def_stats:<type>:<period>` (e.g., `def_stats:municipio:2024`);
  type ∈ {municipio, uc, ti}. JSON: `[{key, nome, area_km2, year}]`
- Integration points: Lua routes in `deforestation_stats.lua` read from
  `lookup_data` (fast, no live spatial join needed)
- Observability: writes outcome timestamp to `lookup_data` key
  `def_stats:last_update`

##### backend-lua/app/routes/deforestation_stats.lua (existing, extend)
- What changes: add `_M.get_by_municipality(ctx)`, `_M.get_by_uc(ctx)`,
  `_M.get_by_ti(ctx)` functions — read precomputed stats from `lookup_data`
- Data shapes:
  - `GET /api/deforestation/stats/by-municipality?year=2024&uf=PA&limit=20` →
    `[{geocodigo, nome, uf, area_km2, year}]`
  - `GET /api/deforestation/stats/by-uc?year=2024&limit=20` →
    `[{nome, categoria, grupo, area_km2, year}]`
  - `GET /api/deforestation/stats/by-ti?year=2024&limit=20` →
    `[{terrai_nom, etnia_nome, area_km2, year}]`
  - `GET /api/deforestation/stats/by-municipality?year=2024&uf=PA&compare_official=true` →
    adds `official_km2` from `prodes_historical.json` (spec §4.5 comparison with
    rates2025.json); `official_km2=null` when no official rate exists for that
    state/year
- Integration points: `main.lua` registers new routes

#### Edge cases
- Year parameter invalid (outside 2000-2025) → 400
- Stats not precomputed yet → return empty array with `precomputed: false`
- Year = "all" (aggregate all years) → sum area_km2 per territory

#### Note on Inc 8 dependency
Inc 8's fire-vegetation crossing needs **live point-level** PRODES queries
(per-fire polygon containment check), which is separate from these precomputed
territorial stats. The precomputed stats are for by-municipality/UC/TI rankings;
Inc 8 queries `deforestation_data` directly per fire point (depends on Inc 1).

#### Note on official-rates comparison
`compare_official=true` cross-checks Yvy's polygon-derived areas against INPE's
official `rates2025.json` (already mirrored in `prodes_historical.json`).
Divergence >10% for a state/year is logged (drift sentinel) but never fails
the response.

#### Note on PRODES class/year parsing (affects Inc 7, 8, 12)
`deforestation_data` stores class/year only inside `data.name` (the QML legend
label, e.g. `d2020`, `r2014`) — there is NO structured year/class column
(`clazz="Desmatamento"`, `periods="N/A"`). Parse with regex `^[dr](\d{4})$`:
`d*` = deforestation, `r*` = regrowth. Applies to
`precompute_deforestation_stats.py` (Inc 7), `get_fire_vegetation_context`
(Inc 8) and `get_deforestation_in_bbox` (Inc 12).

#### Edge cases
- Year parameter invalid (outside 2000-2025) → 400
- Territory polygon not loaded → empty result (log warn)
- Deforestation point falls exactly on boundary → assign to all overlapping (use `ANY` containment)

#### Verification
- Run: `curl "http://localhost:5000/api/deforestation/stats/by-municipality?year=2024&uf=PA&limit=5"`
- Tests: `test_deforestation_stats.lua` — verify by-municipality aggregation with fixture data
- Done: stats routes return valid aggregations

---

### Inc 8 — Fire × vegetation crossing (M)
**Status:** done (2026-08-07)
**Depends on:** Inc 1
**Unblocks:** none
**Done criteria:** API returns classification of fires as "fire in forest" vs. "fire
in already-deforested area" based on PRODES raster at the fire's location.

#### Files to touch

##### backend-lua/app/routes/fires.lua (existing, extend)
- What changes: add `_M.get_fire_vegetation_context(ctx)` — for a given fire
  point or bbox, tag each fire with: `vegetation_status` = `native` | `deforested_<year>` | `regrowth_<year>` | `unknown`
- Data shapes: extends fire response with `vegetation: {status, year, class_name}`
- Integration points: same route as `/api/fires`, new query param `?vegetation=true`
- Error paths: deforestation_data missing for that point → `unknown`

##### backend-lua/app/db.lua
- What changes: add `get_fire_vegetation_context(lat, lon)` (single fire) AND
  `get_vegetation_context_batch(bbox, fires)` — ONE `deforestation_data` query
  per bbox, then point-in-polygon assignment per fire (~30m radius, PRODES
  pixel resolution). Any PRODES point found → return its class/year; multiple
  overlapping classes → most recent `dYYYY`.
- Data shapes: return `{status, year, class_name}` or `{status="native"}`
- Integration points: `get_vegetation_context_batch` used by
  `/api/fires?vegetation=true` (avoids N per-fire queries on large bboxes);
  single-point variant for individual popup lookups

##### frontend/src/components/Home.js (existing, modify)
- What changes: when user clicks a fire marker, show vegetation context
  in the popup: "🔥 Fogo em vegetação nativa" vs. "🔥 Fogo em área
  desmatada — d2024" (includes PRODES class name for traceability per PRODUCT.md)
- Data shapes: reads `vegetation` field from fire API response

#### Edge cases
- Fire point within ~30m of a PRODES `dYYYY` pixel → `status=deforested_YYYY`
- Fire point within ~30m of a PRODES `rYYYY` (regrowth) pixel →
  `status=regrowth_YYYY`
- No PRODES point within 30m → `status=native` (point is in non-monitored or
  never-deforested area)
- GeoTIFF alternative: if PRODES GeoTIFF is available on the VM, query the
  raster band at the fire's (lon,lat) for a direct pixel-value lookup
  (eliminates the 30m radius heuristic entirely)

#### Verification
- Run: `curl "http://localhost:5000/api/fires?vegetation=true&ne_lat=-8&ne_lng=-55&sw_lat=-9&sw_lng=-56"`
- Tests: `test_fire_vegetation.lua` — fixture with known PRODES point, verify classification
- Done: fire popup shows "🔥 Fogo em vegetação nativa" or "Fogo em área desmatada (20XX)"

---

### Inc 9 — TerraClass + Vegetação Secundária + Cerrado vegetation ingest (M)
**Status:** done (2026-08-07)
**Depends on:** Inc 1
**Unblocks:** none
**Done criteria:** TerraClass land-use, Vegetação Secundária (residual), and
Cerrado vegetation-type layers available as tile layers in the map
(WMS- or precomputed-tile-based).

#### Files to touch

##### scripts/download_terraclass.py (new)
- What changes: download TerraClass raster (Amazônia, ~30m resolution) and
  Vegetação Secundária (TerraClass residual/regrowth, spec §5 P3) from the
  TerraBrasilis download area; write to `tiles_terraclass.db` using the same
  tile-precomputation pattern as `scripts/render_car_tiles.py`.
  TerraClass raster is billions of pixels — point-based SQLite is infeasible.
- Function(s):
  - `download_and_extract(url, target_dir)` → GeoTIFF
  - `render_tiles(tif_path, tiles_db_path, layer, min_zoom=6, max_zoom=12)` →
    rasterizes class-color map to XYZ tiles, stored as PNG blobs; `layer` ∈
    `terraclass` | `veg_secundaria`
- Data shapes: `tiles_terraclass.db` schema = `(z, x, y, layer) PK`, `data BLOB`,
  `content_type TEXT`, `fetched_at TEXT` (extends `tiles_car.db` with a `layer`
  column so both datasets share one tile DB)
- Integration points: tile endpoint
  `/api/tiles/terraclass?layer=terraclass|veg_secundaria` (same pattern as
  `/api/tiles/car`); `routes/tiles.lua` must be generalized: per-DB env override
  (`TerraClass_TILES_DB`, `CERRADO_VEG_TILES_DB`), `AND layer=?` filter on read,
  and MUST keep the cold-cache invariant (DBs pre-warmed offline by a single
  Python writer; runtime is read-only — see the `tiles.lua` header comment)
- Error paths: download fails → log and skip; rendering OOM for high zooms →
  cap at `max_zoom=12`. TerraClass URL is not pinned in the spec — locate the
  current download URL (TerraBrasilis `/downloads/` or BiomasBR) on first run
  and hardcode it in the script

##### scripts/download_cerrado_veg.py (new)
- What changes: fetch Cerrado vegetation types from TerraBrasilis WFS
  (`vegetation-cerrado:vegetation_types`), render to `tiles_cerrado_veg.db`
- Function(s):
  - `fetch_wfs_to_gdf(workspace, layer) → GeoDataFrame`
  - `render_polygon_tiles(gdf, tiles_db_path, ...)` → colored polygon tiles
- Data shapes: `tiles_cerrado_veg.db` = same (z,x,y) tile schema
- Integration points: tile endpoint `/api/tiles/cerrado-veg`

##### frontend/src/components/Home.js (existing, modify)
- What changes: add TerraClass and Cerrado vegetation as optional tile layers
- Data shapes: tile endpoints `/api/tiles/terraclass?z={z}&x={x}&y={y}`,
  `/api/tiles/cerrado-veg?z={z}&x={x}&y={y}`
- Integration points: same tile-serving pattern as `/api/tiles/car`

#### Edge cases
- TerraClass > 1GB raster → tile precomputation handles this (per-tile rendering)
- Cerrado WFS returns very large GeoJSON → paginate with bbox filtering
- Tiles DB grows (624MB for PRODES tiles) → monitor disk; 80GB free is ample

#### Verification
- Run: `python3 scripts/download_terraclass.py` → check `tiles_terraclass.db` exists
- Run: `curl "http://localhost:5000/api/tiles/terraclass?z=8&x=100&y=200"` → PNG
- Done: new map layers toggleable

---

### Inc 10 — BdQueimadas complementary fire source (L)
**Status:** done (2026-08-07)
**Depends on:** Inc 1
**Unblocks:** none
**Done criteria:** BdQueimadas fire foci ingested alongside FIRMS; deduplication
ensures no double-counting; API attribute `source` field distinguishes origins.

#### Files to touch

##### tools/sync_bdqueimadas.lua (new, detached subprocess)
- What changes: fetch BdQueimadas fire foci from INPE API (BDQueimadas CSV/JSON),
  convert to fire_data format, upsert with dedup on (lat,lon,acq_date)
- Function(s):
  - `fetch_bdq_fires(days) → rows`
  - `dedupe_and_upsert(rows)` — same (lat,lon,acq_date) key as FIRMS
- Data shapes: fire_data row with `source="INPE_BDQUEIMADAS"` (vs. existing
  `source="NASA_FIRMS_VIIRS_SNPP"`)
- Integration points: scheduled alongside FIRMS sync (every 6h); new source
  attribute in existing fire_data schema (already has `source` column)
- Error paths: BDQ API down → skip, log warn; response changes format → skip,
  log error

##### backend-lua/app/routes/fires.lua (existing, extend)
- What changes: add `source` filter to `/api/fires` query (`?source=bdqueimadas|firms|all`)
- Data shapes: same fire response, filterable by source
- Integration points: existing `get_fires` handler

##### backend-lua/app/db.lua
- What changes: `find_fires()` accepts optional `source` filter parameter
- Data shapes: `WHERE ... AND json_extract(data,'$.source') LIKE ?`
- Integration points: fires route

#### Edge cases
- BDQ and FIRMS detect same fire on same day → upsert (ON CONFLICT DO UPDATE),
  prefer FIRMS values (higher confidence). Set source to combined.
- BDQ has different coordinate precision → round to 3 decimal places before dedup
- BDQ format changes → version-lock the API endpoint; add format-version check

#### Verification
- Run: `lua5.1 tools/sync_bdqueimadas.lua` → check `SELECT COUNT(*) FROM fire_data WHERE json_extract(data,'$.source') LIKE '%BDQ%'`
- Run: `curl "http://localhost:5000/api/fires?source=bdqueimadas"`
- Tests: `test_bdq.lua` — mock BDQ API response, verify deduplication
- Done: fire_data enriched with BDQ source; no duplicate fires for same (lat,lon,acq_date)

---

### Inc 11 — AMS fire-spreading-risk + active-fire overlay (M)
**Status:** done (2026-08-07)
**Depends on:** Inc 1
**Unblocks:** none
**Done criteria:** AMS `fire-spreading-risk` polygons and `active-fire-today`
points ingested and served via `/api/ams/risk`; fire popups show propagation risk.

#### Files to touch

##### scripts/download_ams_wfs.py (new)
- What changes: fetch AMS layers from TerraBrasilis GeoServer workspaces
  `ams1h`/`ams2`/`ams3` (spec §3.3): `fire-spreading-risk` (polygons) and
  `active-fire-today` (points). Writes to `ams_risk` table.
- FIRST STEP: run `DescribeFeatureType` on each AMS layer
  (`/geoserver/<ws>/ows?...&request=DescribeFeatureType&typeName=<layer>`) and
  map the real risk attribute to `risk_level` — the spec only documents
  `view_date, viewed_at, satelite, municipio, biome, geocode`, so the risk
  field name MUST be verified before coding the ingest (do not assume it is
  literally `risk_level`)
- Function(s):
  - `fetch_ams(workspace, layer) → GeoDataFrame`
  - `to_sqlite(gdf, db_path) → int`
  - `run_incremental(db_path)` — replaces the previous day's rows
- Data shapes: row in `ams_risk` = `{view_date, viewed_at, satelite, municipio,
  biome, geocode, layer, risk_level, min_lat, min_lon, max_lat, max_lon, geom,
  ingested_at}` — `geom` stored as JSON TEXT (same Python sqlite3 `jsonb()`
  caveat as Inc 2); bbox from shapely `bounds` for `get_ams_risk_at` lookups
- Integration points: daily cron at 06:00, after the DETER pipeline
- Error paths: WFS timeout (retry 3× with backoff); empty layer → skip + log warn

##### backend-lua/app/db.lua
- What changes: add `ams_risk` table to SCHEMA (Inc 1); functions
  `get_ams_risk(sw_lat, ne_lat, sw_lng, ne_lng, days)` and
  `get_ams_risk_at(lat, lon)` (nearest risk polygon to a fire point)
- Data shapes: bbox + date filter, JSONB geom decode (same as `deter_polygons`)
- Error paths: table missing → empty result (NOOP)

##### backend-lua/app/routes/ams.lua (new)
- What changes: `/api/ams/risk` bbox route + `/api/ams/active` overlay route
- Function(s): `_M.get_risk(ctx)`, `_M.get_active(ctx)`
- Data shapes:
  - `GET /api/ams/risk?sw_lat=&ne_lat=&sw_lng=&ne_lng=&days=7` →
    `{polygons: [{id, risk_level, view_date, municipio, biome, geom}]}`
  - `GET /api/ams/active?bbox=...` → `{points: [{id, satelite, municipio, biome,
    geocode, viewed_at, lon, lat}]}`
- Integration points: registered in `main.lua`

##### backend-lua/app/routes/fires.lua (existing, extend)
- What changes: add `_M.get_fire_ams_risk(ctx)` — for a fire point, return the
  nearest `fire-spreading-risk` level within a small radius
- Data shapes: extends fire response with
  `ams: {risk_level, view_date, biome, municipio}`
- Integration points: same route as `/api/fires`, new param `?ams=true`

##### frontend/src/components/Home.js (existing, modify)
- What changes: optional AMS overlay (risk polygons) + fire popup shows
  "🔥 Risco de propagação: ALTA (AMS 2026-08-07)"
- Data shapes: reads `ams` field from fire API response; `/api/ams/risk` overlay
- Integration points: overlay toggle alongside TerraClass/CAR layers

#### Edge cases
- AMS publishes hourly (`ams1h`) and daily layers — pick latest layer with data;
  dedupe by (view_date, geocode)
- Risk polygon covers multiple fires → same level for all (no per-fire recompute)
- AMS data missing for a region → `ams: null` in fire response (no error)

#### Verification
- Run: `python3 scripts/download_ams_wfs.py` → check
  `sqlite3 yvy.db "SELECT COUNT(*) FROM ams_risk"`
- Run: `curl http://localhost:5000/api/ams/risk?sw_lat=-20&ne_lat=0&sw_lng=-60&ne_lng=-40`
- Run: `curl "http://localhost:5000/api/fires?ams=true&bbox=..."` → fires include `ams` field
- Tests: `test_ams.lua` — mock AMS WFS response, verify ingest + risk lookup
- Done: risk overlay togglable; fire popups show AMS risk level

#### Optional (deferred)
`cs_150km_view` / `cs_5km_diff_view` (large fire-cluster contours, spec §3.3) —
only if the base overlay proves useful.

---

### Inc 12 — Property PRODES verification by CAR receipt (M)
**Status:** done (2026-08-07)
**Depends on:** none
**Unblocks:** none
**Done criteria:** given a CAR receipt number (`cod_imovel`), the API returns
whether the property has PRODES deforestation, with area, years, and classes.

#### Files to touch

##### backend-lua/app/lookups/car_lookup.lua (existing, modify)
- What changes: expose `get_by_cod_imovel(cod_imovel)` (UNIQUE lookup on
  `car_data.cod_imovel` → `{id, uf, municipio, area, geom_geojson, bbox}`) and
  make the local `point_in_geojson` reusable (`_M.point_in_geojson`)
- Function(s):
  - `get_by_cod_imovel(cod_imovel)` — normalizes input to UPPERCASE only
    (car_import stores `cod_imovel` verbatim from SICAR; aggressive stripping
    can break the match), decodes `json(geom)`, computes bbox
  - `_M.point_in_geojson(lon, lat, geojson_text)` — extracted from current local
- Data shapes: `{id=cod_imovel, uf, municipio, area_ha, geom, bbox={min_lon,
  min_lat, max_lon, max_lat}}` or nil
- Integration points: reused by `routes/car.lua`
- Error paths: not found → nil (route returns `found:false`); invalid cod_imovel
  format → 400

##### backend-lua/app/db.lua (existing, modify)
- What changes: add `get_deforestation_in_bbox(sw_lat, ne_lat, sw_lng, ne_lng,
  limit)` — bbox query on `deforestation_data` using `idx_def_bbox`, decoding
  `class_name`/`year` from the JSONB `data` field
- Data shapes: `[{lat, lon, class_name, year, type}]` where `type` =
  `deforestation` (class `d*`) | `regrowth` (class `r*`)
- Integration points: called from `routes/car.lua`
- Error paths: empty result → `{}` (no PRODES in the bbox)

##### backend-lua/app/routes/car.lua (existing, modify)
- What changes: add `_M.get_prodes_status(ctx)` — property PRODES verification
- Function(s):
  - `get_prodes_status(ctx)` — resolve property → bbox (+~30m padding to catch
    edge pixels) → `get_deforestation_in_bbox` → `point_in_geojson` per candidate
    → aggregate
- Data shapes:
  - `GET /api/car/prodes?cod_imovel=<recibo>` →
    `{cod_imovel, found, has_prodes, prodes_area_ha, property_area_ha,
      pct_deforested, years: [...], classes: [{class_name, year, type, count}],
      regrowth: bool, sampled: bool, cached: bool}`
  - `GET /api/car/summary?cod_imovel=<recibo>` →
    `{cod_imovel, uf, municipio, area_ha}` (summary)
  - NOTE: the router matches EXACT paths (`server.lua`
    `routes[method][req.path]`) — no `:param` support; query params are used,
    like the existing `/api/car/lookup?lat=&lon=`.
- Integration points: registered in `main.lua` alongside existing `/api/car/lookup`;
  result cached in Redis `car:prodes:<cod_imovel>` (TTL 86400, observability
  sentinel + response `cached` flag)
- Error paths: cod_imovel not found → 404 `{found:false}`; deforestation_data
  empty for region → `{has_prodes:false, note:"no PRODES data"}`; candidate
  limit hit → `sampled:true` (defensive cap, e.g. 50k)

##### scripts/resolve_car_document.py (new)
- What changes: resolve other rural-property documents (CPF/CNPJ do titular,
  SNCR, matrícula) → `cod_imovel` via the official CAR public consultation API
  (`https://consultapublica.car.gov.br`); prints matching receipt number(s) so
  the user can query `/api/car/prodes?cod_imovel=`
- Function(s):
  - `resolve(documento) → [cod_imovel]`
- Integration points: CLI tool; optional hook in the frontend input (auto-resolve
  when input is not a valid CAR code)
- Error paths: API down/captcha → exit 1 with message (fallback: manual entry of
  the receipt number)

##### frontend/src/components/Home.js (existing, modify)
- What changes: "Verificar imóvel" input in the unified shell — paste a CAR
  receipt (or other document) → result card shows property summary +
  "Possui PRODES: SIM · 12,3 ha · 2020, 2024" or "NÃO", with zoom-to-property
- Data shapes: calls `/api/car/prodes?cod_imovel=<recibo>`; renders the returned card
- Integration points: shell input + float panel (2-panel max preserved)

#### Edge cases
- Receipt format variations (case, dashes) → normalized before lookup
- PRODES point exactly on the property boundary → counted (consistent with Inc 7)
- `r*` classes (regrowth) are reported separately from `d*` (deforestation) —
  `has_prodes` counts only `d*`
- Very large property (e.g. >50k candidate points) → `sampled:true` + warning
- Area is approximated as `pixel_count × 0.09 ha` (30m PRODES pixels); flag it
  in the response (`area_estimate: "pixel-based"`) — official PRODES area is
  km² per polygon, so the ha value is indicative
- No `car.db` loaded → `{found:false, note:"CAR unavailable"}`

#### Verification
- Run: `curl "http://localhost:5000/api/car/prodes?cod_imovel=<recibo>"` →
  `has_prodes` matches PRODES points within the polygon (spot-check vs a known
  property)
- Run: `python3 scripts/resolve_car_document.py --cpf <cpf>` → cod_imovel
- Tests: `test_car_prodes.lua` — fixture car.db + fixture deforestation rows,
  verify aggregation (has_prodes, years, classes)
- Done: entering a receipt in the frontend shows PRODES status with area/years

---

## Cross-cutting verification

After Inc 3: manually verify that clicking a CAR property in the frontend
shows associated DETER alerts (mocked or real).

After Inc 4: fire popup shows "DETER: DESMATAMENTO_VEG em propriedade X" when
fire is on a CAR with recent DETER alert.

After Inc 6: `/api/alerts` feed includes `deter_protected` entries alongside
existing `indigenous_land` and `conservation_unit` types.

After Inc 8: fire popup distinguishes "Fogo em área desmatada (2024)" from "Fogo em vegetação nativa".

After Inc 11: fire popup shows AMS propagation-risk level when `?ams=true`; risk overlay toggles in the map.

After Inc 12: pasting a CAR receipt (or other property document) in the shell
shows "Possui PRODES: SIM/NÃO" with area and years.

CI: add `python3 -m py_compile scripts/*.py` to `.github/workflows/ci.yml`
(currently checks only Lua/C/sh) so new Python scripts fail fast.

## Standards / common-mistakes referenced

- `backend-lua/agent.md` — architecture, JSONB schema, detached subprocess pattern
- `PRODUCT.md` — personas, brand pillars, layout constraints (2 panels max)
- `DESIGN.md` — dark theme, fire gradient, scientific palette, no drop shadows
- `AGENTS.md` — deployment flow, Lua 5.1 requirement, git auth, PRODES file gitignore

## Open questions (CONSIDER from review)

1. ~~**Cron ordering for DETER pipeline**~~ — **Resolved**: `scripts/deter_daily.sh`
   chains download → backfill/rollup → cross (Inc 2/3 integration points).
2. ~~**DETER polygon split across UC boundary threshold**~~ — **Resolved**: use
   native `areauckm`/`area_km2` ratio when available; include at ≥10% (Inc 6).
3. **Inc 10 combined-source dedup** — when BDQ and FIRMS detect the same fire,
   the plan sets `source="combined"` which loses provenance. A
   `sources` JSONB array or separate source-specific rows would be more
   auditable.
4. **Fire popup PRODES traceability** — frontend popup should show PRODES
   class name (`d2024`) alongside year for auditability per PRODUCT.md's
   "authoritative" pillar.
5. **Detached subprocess observability** — each tool writes to its own log
   file. A Redis sentinel key pattern (e.g., `deter:last_sync_status`) would
   give the health-check endpoint visibility into sync health without
   parsing log files.
6. **Alert-tiering UX** — the unified alert panel now has up to 9 alert types.
   Default-collapse rule: show top 2 CRIT + 1 newest WARN; "Show all" button
   expands. CAR-property DETER alerts are in a separate panel to avoid
   confusion with territorial alerts.

## Out of scope

- Replacing NASA FIRMS with BdQueimadas as primary fire source
- Building a full PostGIS pipeline (keeps SQLite JSONB approach)
- PRODES for biomes other than Amazônia Legal (Cerrado, Caatinga, etc.) — these
  are available but not in initial scope
- Real-time streaming (WebSocket / SSE) for DETER alerts — polling is sufficient
  for daily data
- Mobile app
- Third-party data sources beyond TerraBrasilis and NASA

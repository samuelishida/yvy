# CAR Polygon Overlay (estilo TI/UC, via tiles raster)

## Context

The Yvy map already shows TI (547) and UC (298) as vector GeoJSON polygon
overlays (toggled, clickable popups). The user wants the **same overlay
experience for CAR** (Cadastro Ambiental Rural), colored in a **livelier,
lighter green than the UCs** (`#a3e635` lime-400 vs UC `#4ade80` green-400).

**Hard constraint:** CAR is **8.4M imóveis / 6.8GB** (27 UFs, `car.db` with
RTree + JSONB geometry). It is impossible to serve as a single GeoJSON
FeatureCollection the way TI/UC are (547+298 polygons) — a Brazil-wide CAR
GeoJSON would be tens of GB and would freeze both the browser and the
single-threaded copas loop.

**Intended outcome:** a togglable CAR overlay on the map, rendered from
precomputed raster tiles (PRODES-style), with click-to-inspect showing the
imóvel (cod_imovel/município/UF) by reusing the existing
`car_lookup.classify_point`.

User-confirmed decisions (Step 3 question gate):
- **Raster tiles PRODES-style** (not vector tiles / not bbox GeoJSON).
- **Click-to-inspect** via `car_lookup.classify_point` for interactivity.
- **Color `#a3e635` (lime-400)** — vivid light green, clearly distinct from UC.

## Architectural decisions

- **Decision: raster tiles, PRODES pattern.** Pre-render CAR polygons to
  256×256 PNG tiles (z6–12) offline into a SQLite blob cache
  (`tiles_car.db`), serve via `/api/tiles/car` with immutable cache headers,
  render client-side with a react-leaflet `TileLayer`. Rationale: the only
  way to render 8.4M polygons in a browser; matches the proven
  `/api/tiles/prodes` pipeline (SQLite blob cache + EMPTY_PNG fallback +
  no-auth public). Alternatives rejected: vector tiles (tippecanoe + PBF
  server + MapLibre/VectorGrid — no MVT tooling in repo, new frontend dep,
  far more work); bbox-sliced GeoJSON (low zoom matches millions of imóveis,
  loop-blocking).
- **Decision: click-to-inspect instead of per-polygon vector hover.**
  Raster tiles have no polygon hit-testing client-side, so interactivity
  comes from a tiny `/api/car/lookup?lat&lon` route that calls the existing
  `car_lookup.classify_point` (RTree bbox → decode candidates → ray-cast).
  Rationale: zero new spatial code, per-click cost is cheap (same call the
  classification subprocess already makes). Confirmed by user.
- **Decision: separate `tiles_car.db`, no live upstream proxy.** Unlike
  PRODES (which lazily proxies a public WMS on cache miss), there is no
  CAR raster WMS we control and style to our color. Tiles are fully
  precomputed; cache miss returns the shared `EMPTY_PNG` (graceful). A
  regeneration script re-runs when `car.db` is updated.
- **Decision: tile generation is an offline Python tool**
  (`scripts/render_car_tiles.py`, Pillow), mirroring
  `scripts/cache_prodes_tiles.py` (offline, dev-run, artifact gitignored,
  shipped via scp like `car.db`). Rationale: rendering 8.4M polygons is
  CPU-heavy and must never run on the 1GB prod VM or in the copas loop.
- **Decision: `/api/tiles/car` public (no auth, rate-limit-exempt via the
  existing `/api/tiles/` whitelist); `/api/car/lookup` auth+rl** (dynamic
  per-point data endpoint, consistent with fires routes; the frontend gets
  the key via the proxy-injected `X-API-Key`).
- **Decision: overlay color constant `#a3e635`** (lime-400), rendered
  **opaque** in tiles; the **TileLayer `opacity=0.5` is the single transparency
  control**. Baking 50% into the PNG *and* applying CSS opacity would yield
  ~25% effective (double-alpha); opaque fill + one CSS opacity keeps the
  stated ~0.5 and, because layer opacity applies post-composite, overlapping
  imóveis never double-darken. One constant shared by the tile renderer (fill)
  and the frontend (toggle swatch / legend). UC stays `#4ade80`.

## Assumptions and answers from code

- Decision: TI/UC served via `serve_geo_lookup` → `bounds_to_geojson` →
  Redis `:body`/`:etag` (24h) → ETag/304; frontend lazy-fetches via
  `cachedFetch` (1h) + localStorage (`geo_*_v3`, 24h) and renders
  conditional `<GeoJSON>` layers. Source: code @ `backend-lua/main.lua:108-143`,
  `frontend/src/components/Home.js:629-630,834-853,1127-1163`. CAR **cannot**
  reuse the GeoJSON route (size); it reuses only the frontend toggle/legend
  idiom.
- Decision: PRODES tile pipeline is the pattern to copy — `tiles.lua`
  `get_tile` (SQLite blob cache `tiles(z,x,y,data,content_type,fetched_at)`,
  `EMPTY_PNG` fallback, `Cache-Control: immutable`, `tile_to_bbox`),
  `scripts/cache_prodes_tiles.py` (offline pre-fetch, `latlon_to_tile`),
  frontend `TileLayer url="/api/tiles/prodes?z={z}&x={x}&y={y}"`.
  Source: code @ `backend-lua/app/routes/tiles.lua:48-128`,
  `scripts/cache_prodes_tiles.py:48-65`, `Home.js:813-822`.
- Decision: CAR data layer exists and is queryable: `car_data` + `car_rtree`
  (native RTree), `car_lookup.classify_point` / `count` / `load_car`,
  `car_import.prepare_geometry` (5-decimal rounding). Geometry is JSONB —
  always `json(geom)` on read. Source: code @
  `backend-lua/app/car_import.lua:66-79`, `backend-lua/app/lookups/car_lookup.lua:63-137`.
- Decision: `car.db` is **gitignored** (`backend-lua/data/car/`), shipped via
  scp/rsync, never imported on the VM (1GB RAM — MG.json needs ~28GB in Lua).
  The new `tiles_car.db` follows the same policy
  (gitignore `backend-lua/data/tiles_car.db`).
- Decision: Pillow 10.2.0 already installed locally (verified). Source:
  terminal `python3 -c "import PIL"`.
- Decision: no `.agents/standards/` or `.agents/common-mistakes/` in repo
  (verified absent); conventions come from AGENTS.md + repo memory.
- Decision: `/api/tiles/` is already exempt from the C-server rate limiter
  (`yvy-server.c:749`), so `/api/tiles/car` inherits it in dev; prod nginx
  proxies `/api/` → :5000 directly. Source: code @ `yvy-server.c:749`,
  `nginx.conf:31-37`.

## Risks accepted

- **Tile render time (8.4M imóveis, z6–12):** one-time offline job; mitigated
  by low-zoom fill heuristic (z≤7: uniform translucent tile where any imóvel
  bbox touches, no polygon decode) and RTree candidate filtering at higher
  zooms. Accept; revisit if the full run exceeds a few hours — it only needs
  re-running when `car.db` is rebuilt.
- **`tiles_car.db` artifact size (~hundreds of MB):** gitignored, scp'd to the
  VM like `car.db`. Accept.
- **Raster overlay has no per-polygon hover:** covered by click-to-inspect.
  Accept (user-confirmed).
- **Overlapping CAR imóveis:** renderer draws opaque fills; CSS layer opacity
  applies post-composite, so overlaps never double-darken — the overlay is a
  clean union at the single TileLayer alpha. Accept.
- **Click-to-inspect cost on the copas loop:** per-click `classify_point` is
  cheap (RTree + a few ray-casts), same as used by the classification
  subprocess; auth+rl guards the endpoint. Accept.
- **Main-loop memory with `car.db` open:** the first `/api/car/lookup` opens
  the 6.8GB `car.db` (mmap 256MB) inside the copas-loop process — today only
  the classification subprocess opens it. Verify the 1GB VM absorbs the added
  RSS; keep lazy-load-once (`load_car()` guard) and accept the first-click
  open cost. Revisit if memory pressure appears.
- **Color fidelity across basemaps:** alpha ~50% lets OSM/satellite show
  through; the lime-400 was chosen to contrast with UC green-400. Accept.

## Increment DAG

- Inc 1 — Gerador de tiles CAR (offline, Python) (L) — depends on: none — unblocks: 2, 3
- Inc 2 — Rotas backend: /api/tiles/car + /api/car/lookup (M) — depends on: 1 (single-tile prototype) — unblocks: 3, 4
- Inc 3 — Frontend: overlay CAR + clique-inspecionar (M) — depends on: 1 (prototype), 2 (pinned API contract) — unblocks: 4
- Inc 4 — Deploy + validação em prod (S) — depends on: 1 (full z6–12 render), 2, 3 — unblocks: none

Fan-out: **Inc 1's single-tile prototype first** (de-risks the renderer), then
**Inc 2 and Inc 3 run in parallel** against the pinned API contract (URL
`/api/tiles/car?z&x&y` + JSON `{imovel:{id,name,uf}|null}`) while the full
z6–12 render (rest of Inc 1) completes offline. Inc 2 is testable against an
empty `tiles_car.db` (EMPTY_PNG fallback); Inc 3 only needs the contract, not
the live endpoint. Inc 4 gates on all three.

## Increments

### Inc 1 — Gerador de tiles CAR (offline, Python) (L)

**Status:** DONE (2026-08-06) — `scripts/render_car_tiles.py` (multiprocessing 16 workers, resumível, `--self-test` da matemática de tiles); protótipo 1 tile (Cláudia/MT z10) + smoke z6–8 validados; **render completo z6–12 concluído**: 115.404 tiles / 339,5MB (z6 41 · z7 125 · z8 426 · z9 1.544 · z10 5.786 · z11 22.053 · z12 85.429), `integrity_check: ok`, ~6,5min no z10–12. **Revisão (feedback usuário): uniform-fill z≤7 REJEITADO** (tiles quadradões não seguiam a forma do Brasil) — `--fill-max-zoom` default -1, polígonos reais em TODOS os zooms; re-render z6–7 (38+121 tiles) + CHUNK dinâmico p/ engajar workers em zooms baixos. Total final 115.397 tiles.
**Depends on:** none (needs `backend-lua/data/car/car.db`, already present)
**Unblocks:** 2, 3
**Done criteria:** `scripts/render_car_tiles.py` produces `backend-lua/data/tiles_car.db`
with real PNG tiles at z6–12 over Brazil; per-zoom counts logged; a sample
tile eyeballed shows the lime-400 overlay.

#### Files to touch

##### scripts/render_car_tiles.py (NEW)
- What changes: offline tile renderer reading `car.db` → writing `tiles_car.db`.
- Function(s):
  ```python
  # CLI: python3 scripts/render_car_tiles.py [--min-zoom 6] [--max-zoom 12]
  #       [--car-db backend-lua/data/car/car.db]
  #       [--out backend-lua/data/tiles_car.db] [--fill "#a3e635"] [--fill-max-zoom 7]
  #       [--self-test]  # round-trip tile_to_bbox ↔ latlon_to_tile (pins the math)
  # Fill is rendered OPAQUE (alpha 255); the frontend TileLayer opacity=0.5 is the
  # single transparency control (avoids the double-alpha ~25% trap).
  def tile_to_bbox(z, x, y) -> (lon_min, lat_min, lon_max, lat_max)   # same as tiles.lua:48-56
  def latlon_to_tile(lat, lon, z) -> (x, y)                            # same as cache_prodes_tiles.py:58-65
  def bbox_to_tile_range(z, lon_min, lat_min, lon_max, lat_max) -> ((x0,y0),(x1,y1))
  def covered_tiles(car_db, z) -> set[(x,y)]                           # scan car_rtree bboxes
  def render_tile(car_db, z, x, y, fill, fill_max_zoom) -> bytes|None        # PNG or None (empty); fill OPAQUE
  def main() -> None
  ```
- Data shapes:
  - Input `car.db`: `car_data(id, cod_imovel, uf, municipio, area, geom BLOB)`,
    `car_rtree(id, minLon, maxLon, minLat, maxLat)` (JSONB — always read via
    `json(geom)`).
  - Output `tiles_car.db`: `tiles(z INTEGER, x INTEGER, y INTEGER, data BLOB,
    content_type TEXT DEFAULT 'image/png', fetched_at TEXT, PRIMARY KEY(z,x,y))`
    (same schema as PRODES `tiles.lua:73-75`).
- Integration points: consumed by `tiles.get_tile_car` (Inc 2). Mirrors
  `scripts/cache_prodes_tiles.py` conventions (WAL, `synchronous=OFF`,
  batched commits, per-zoom logs).
- Error paths: missing `car.db` → clear error + exit 1; tile with no polygons
  → not stored (backend returns EMPTY_PNG); malformed geom → skip imóvel with
  warn counter.

#### Algorithm notes
1. `create_schema` in `tiles_car.db`; `PRAGMA journal_mode=WAL`,
   `synchronous=OFF`, `cache_size=-200000`, `temp_store=MEMORY`.
2. Per zoom `z`:
   a. `covered_tiles`: read all `car_rtree` bboxes once, map each bbox to its
      tile footprint at `z` (`bbox_to_tile_range` on the 4 corners, clamped to
      Brazil), accumulate into a set. (≈8.4M rows × 7 zooms — one-time, fine.)
   b. For each covered tile, **skip any already present in `tiles_car.db`
      (resumable)** — a multi-hour job will be interrupted, and re-runs must
      resume rather than restart (mirrors `cache_prodes_tiles.py` skipping
      already-cached tiles):
      - `z <= fill_max_zoom` (default 7): emit a uniform 256×256 PNG filled
        with `fill` **opaque** (alpha is the TileLayer's job, consistent with
        z≥8; CAR region ≈ continuous at low zoom; no polygon decode — big
        CPU saver).
      - else: `tile_to_bbox` → query `car_rtree` for imóveis whose bbox
        intersects the tile bbox → fetch `json(geom)` for candidates (chunked
        `id IN (...)` ~500/batch), **memoizing decoded geometry by `id` within
        the zoom (bounded LRU)** so an imóvel spanning many tiles is decoded
        once → transform each vertex lon/lat → tile pixel coords →
        `ImageDraw.polygon(fill=(fill_rgb,255))` (opaque) on an RGBA canvas →
        PNG. Empty canvas → skip storing. (No global-alpha step: opacity is
        the TileLayer's job.)
   c. Log `z{zoom}: {n} tiles em {t}s`.
3. Final: `wal_checkpoint(TRUNCATE)`, `PRAGMA optimize`.

#### Edge cases
- Imóvel crossing tile boundary / wrapping antimeridian: bbox footprint via
  corners handles crossing (no antimeridian in Brazil).
- Low zoom fill vs actual sparse CAR (some states >80% covered, some <5%):
  the `fill_max_zoom` heuristic is a fair approximation at z≤7; accept.
  **Log covered-tile counts at z=7 to eyeball the boundary before committing
  to the heuristic.**
- Very large imóvel (fazenda) spanning many tiles: covered by per-imóvel
  footprint.
- Memory: per-tile candidate decode only (never whole table); bounded.

#### Verification
- Run: `python3 scripts/render_car_tiles.py --min-zoom 6 --max-zoom 8`
  (smoke); then full `--min-zoom 6 --max-zoom 12`.
- Prototype first: render ONE tile over Cláudia/MT (lat -11.19, lon -54.90,
  z10) and eyeball the PNG (green overlay over the CAR property).
- Tests: no busted tests (offline tool); lint via `python3 -m py_compile`;
  `python3 scripts/render_car_tiles.py --self-test` asserts the
  `tile_to_bbox` ↔ `latlon_to_tile` round-trip (pins the math duplicated across
  Python/Lua).
- Done: `tiles_car.db` exists with non-zero tiles; `sqlite3 tiles_car.db
  "SELECT COUNT(*) FROM tiles"` > 0; sample PNG visually correct.

### Inc 2 — Rotas backend: /api/tiles/car + /api/car/lookup (M)

**Status:** DONE (2026-08-06) — `tiles.get_tile_car` + `app/routes/car.lua` + registro em `main.lua`; `tests/test_car_routes.lua` (8 testes); `make test-lua` 78/0; manual: lookup hit (Cláudia/MT) / miss `{imovel:null}` / 400; tile serve PNG / miss EMPTY_PNG.
**Depends on:** 1 (single-tile prototype)
**Unblocks:** 3, 4
**Done criteria:** `GET /api/tiles/car?z&x&y` serves PNG blobs from
`tiles_car.db` (immutable cache headers; EMPTY_PNG on miss); `GET
/api/car/lookup?lat&lon` returns `{imovel:{id,name,uf}|null}`.

#### Files to touch

##### backend-lua/app/routes/tiles.lua
- What changes: generalize the DB opener to accept a path; add `get_tile_car`.
- Function(s):
  ```lua
  -- open_tiles_db(path): like open_db() (tiles.lua:30-46) but keeps a cache
  -- keyed BY PATH (local _dbs = {}) — never open per request (256-tile bursts
  -- would churn connections + WAL lock contention). PRODES keeps its own
  -- cached connection; CAR gets a second cached one.
  local function open_tiles_db(path) ... end            -- per-path cached (_dbs[path])
  local CAR_TILES_DB = env.get("CAR_TILES_DB")          -- env override FIRST (test/ops)
      or env.first_with_existing_parent({               -- like tiles.lua:30-34
          "backend-lua/data/tiles_car.db", "data/tiles_car.db",
          "../backend-lua/data/tiles_car.db", "/opt/yvy/backend-lua/data/tiles_car.db",
      }) or "backend-lua/data/tiles_car.db"
  function _M.get_tile_car(ctx)                          -- mirrors get_tile (tiles.lua:62-128) minus the WMS proxy
  ```
- Data shapes: `get_tile_car` reads `tiles(z,x,y,data)` from `tiles_car.db` →
  `serve_png` (reuse, `tiles.lua:58-63`); miss → `EMPTY_PNG` (reuse
  `tiles.lua:14-28`).
- Integration points: registered in `main.lua`; the existing `/api/tiles/`
  rate-limit whitelist (`yvy-server.c:749`) already covers `/api/tiles/car`.
- Error paths: `tiles_car.db` absent → warn + EMPTY_PNG (never 500); missing
  z/x/y → 400.

##### backend-lua/app/routes/car.lua (NEW)
- What changes: small module with the point-lookup handler.
- Function(s):
  ```lua
  function _M.get_lookup(ctx)
      -- auth.enforce(ctx) → rl.enforce(ctx)
      -- lat, lon = tonumber(ctx.req.args.lat/lon); nil → 400
      -- local car = require("app.lookups.car_lookup"); car.load_car()
      -- local hit = car.classify_point(lon, lat)   -- {id, name(=municipio), uf} | nil
      -- ctx:json(200, { imovel = hit })
  end
  ```
- Data shapes: request `?lat=&lon=`; response `{imovel:{id="MT-5103056-…", name="Cláudia", uf="MT"}}` or `{imovel:null}`.
- Integration points: registered in `main.lua`; no change to `car_lookup.lua`
  (returns exactly what the popup needs).
- Error paths: missing/non-numeric lat/lon → 400; `car.db` absent →
  `{imovel:null}` (lookup degrades, never 500).

##### backend-lua/main.lua
- What changes: register the two routes.
- Add:
  ```lua
  server.route("GET", "/api/tiles/car", tiles.get_tile_car)   -- near :177-178
  server.route("GET", "/api/car/lookup", function(ctx)         -- near fires routes
      local car_routes = require("app.routes.car")
      car_routes.get_lookup(ctx)
  end)
  ```

##### backend-lua/tests/test_car_routes.lua (NEW)
- What changes: route-level busted tests with a fake `ctx` (pattern if none exists: build `{req={args=...}, json=function(...), error=function(...)}` and assert on captured args).
- Testes: `get_lookup` hit (fixture car.db) / miss (`{imovel:null}`) / non-numeric lat-lon → 400; `get_tile_car` serve (fixture `tiles_car.db` with a tiny pre-made PNG) / miss → EMPTY_PNG / missing z-x-y → 400.
- Setup: reuse `tests/test_car_lookup.lua` fixture recipe (`env.set("CAR_DB_PATH", tmp)` + `package.loaded["app.lookups.car_lookup"]=nil` + re-require); for the tile route, `env.set("CAR_TILES_DB", tmp_tiles)` (env override added in `tiles.lua`) + `package.loaded["app.routes.tiles"]=nil` + re-require; build a temp `tiles_car.db` with the same `tiles(z,x,y,data,...)` schema and insert a tiny pre-made PNG.

#### Edge cases
- Tile miss after partial generation (user zooms beyond generated range): EMPTY_PNG — graceful.
- Invalid zoom (z<0 / huge): serve EMPTY_PNG or 400; keep permissive like PRODES.
- `classify_point` on empty `car.db`: returns nil → `{imovel:null}`.

#### Verification
- Run: `luac5.1 -p backend-lua/app/routes/tiles.lua backend-lua/app/routes/car.lua backend-lua/main.lua`; `make test-lua` (green, incl. new `test_car_routes.lua`).
- Tests to add/update: `tests/test_car_routes.lua` (above); **PRODES regression** — after the `open_db`→`open_tiles_db(path)` refactor, re-check `GET /api/tiles/prodes?z&x&y` still serves a cached blob (and proxies on miss) so the existing pipeline isn't broken by the refactor.
- Manual (local stack up): `curl 'http://127.0.0.1:5000/api/tiles/car?z=10&x=…&y=…'` →
  `image/png` + `Cache-Control: immutable`; `curl 'http://127.0.0.1:5000/api/car/lookup?lat=-11.19&lon=-54.90'` → `{"imovel":{"id":"MT-5103056-…"}}`.
- Done: both endpoints behave as specified, including EMPTY_PNG miss; PRODES still serves after the refactor.

### Inc 3 — Frontend: overlay CAR + clique-inspecionar (M)

**Status:** DONE (2026-08-06) — `Home.js` (CAR_COLOR #a3e635, toggle, TileLayer zIndex 90 opacity 0.5, fire-popup-wins via FireEventsHandler, popup CAR) + `i18n.js` (`home.*`); `npm run build` OK; browser verificado: toggle CAR + overlay lime + click-inspect (Rondolândia/MT) + fire-popup-wins. **Revisão (feedback usuário): popup preso** — fix toggle-close (`carInspectOpenRef`: 1º clique abre, próximo fecha) + `onClose` limpa estado (popup Leaflet preso capturava eventos de scroll/pointer).
**Depends on:** 1 (prototype), 2 (pinned API contract)
**Unblocks:** 4
**Done criteria:** toggle "CAR" on the map shows the lime-400 overlay; clicking
the overlay opens a popup with the imóvel (or "sem imóvel CAR"); i18n pt/en.

#### Files to touch

##### frontend/src/components/Home.js
- What changes: add CAR toggle, TileLayer, click-to-inspect, and a color
  constant.
- Function(s)/consts:
  - `const CAR_COLOR = '#a3e635';` and `const CAR_TILES_VERSION = '1';`
    (bumped on regeneration — invalidates browser/immutable tile caches). Near
    `FIRE_NATURE_COLORS`, `Home.js:37-45`.
  - State `const [showCar, setShowCar] = useState(false);` (near other toggles).
  - Toggle button in `.layer-toggles` (near `Home.js:778-787`):
    `<button className={\`layer-toggle${showCar?' active':''}\`} onClick={()=>setShowCar(!showCar)}><span className="lt-dot" style={{background:CAR_COLOR}}/> {t('home.layerCar')}</button>`
  - TileLayer (near PRODES, `Home.js:813-822`):
    ```jsx
    <TileLayer key="car-tiles" url={'/api/tiles/car?z={z}&x={x}&y={y}&v='+CAR_TILES_VERSION}
      opacity={showCar ? 0.5 : 0} tileSize={256} maxNativeZoom={12} minZoom={2}
      keepBuffer={4} updateWhenZooming={false} updateWhenIdle={false} fadeIn={150}
      attribution="&copy; SICAR" zIndex={90} />
    ```
  - Click-to-inspect (**fire-popup-wins**): extend the **existing shared map
    `click` handler** (`FireEventsHandler`, `Home.js:184-196`) instead of adding
    a second `useMapEvents({click})` — Leaflet dispatches the map `click` to
    every listener before `handleFireClick`'s `stopPropagation`
    (`Home.js:977`), so a separate CAR handler would cover the fire popup
    (regression). **Placement caveat:** the handler early-returns when
    `!fires || fires.length === 0` (`Home.js:187`) — the CAR branch must go
    **before** that guard (gated only by `isZoomingRef` and `showCar`), or
    clicking with the fire layer empty would never inspect CAR. Thread
    `showCar` and an `onCarInspect(latlng)` callback as **new props** of
    `FireEventsHandler`. In the CAR branch: (1) hit-test fires via the
    module-level `findFireAtPoint` (`Home.js:114`) against the fire grid — if a
    fire is hit, do nothing (fire popup wins); (2) else if `showCar`,
    `cachedFetch('/api/car/lookup?lat='+lat+'&lon='+lng, {ttl: 60_000})` → if
    `imovel`, open `L.popup().setLatLng([lat,lng]).setContent('<strong>📋 '+imovel.id+'</strong><br/>'+imovel.name+'/'+imovel.uf).openOn(map)`;
    (3) on miss, open the `home.noCar` popup **only when the click is within
    Brazil bounds** (avoid popup spam while panning/clicking empty ocean).
- Data shapes: consumes `{imovel:{id,name,uf}|null}` from `/api/car/lookup`.
- Integration points: `FireEventsHandler`'s shared click path (new `showCar` +
  `onCarInspect` props) + `findFireAtPoint` (`Home.js:114`); `cachedFetch` from
  `frontend/src/utils/apiCache.js`.
- Error paths: lookup fetch fails → silent (no popup); layer hidden → click
  does nothing; fire hit → CAR path skipped.

##### frontend/src/i18n.js
- What changes: pt/en labels, under the existing `home.*` namespace (matches
  the current toggle labels, e.g. `home.layerDeforestation`).
- Add: `home.layerCar` ("CAR"), `home.carTitle` ("Cadastro Ambiental Rural"),
  `home.carImovel` ("Imóvel CAR"), `home.noCar` ("Sem imóvel CAR aqui" /
  "No CAR property here").

#### Edge cases
- Overlay click on top of a fire marker: the shared handler hit-tests fires
  via `findFireAtPoint` first and skips the CAR lookup when a fire is hit —
  the fire popup always wins, no stopPropagation dependency.
- `showCar` toggling: keep TileLayer mounted with opacity 0↔0.5 (same as
  PRODES), avoids refetch churn.
- Zoom beyond maxNativeZoom (12): Leaflet upscales cached tiles (like PRODES);
  click-to-inspect still works at any zoom.

#### Verification
- Run: `cd frontend && npm run build` (green); local stack up → toggle CAR on
  the map at z8 and z11; click inside and outside a CAR polygon.
- Done: overlay renders in lime-400, toggle works, popup shows imóvel on
  click, no JS console errors.

### Inc 4 — Deploy + validação em prod (S)

**Depends on:** 1, 2, 3
**Unblocks:** none
**Done criteria:** prod shows the CAR overlay, click-to-inspect works, and the
deploy steps are documented so regeneration is repeatable.

#### Files to touch

##### scripts/setup-lua.sh (or RUNBOOK.md note)
- What changes: document the `tiles_car.db` artifact (generate locally,
  scp to VM) alongside the existing `car.db` shipping step.
- Function(s): none (documentation/ops).

##### Deploy steps (runbook, not committed artifact)
1. Locally: `python3 scripts/render_car_tiles.py` (full z6–12) → `backend-lua/data/tiles_car.db`; bump `CAR_TILES_VERSION` in `Home.js` when regenerating.
2. Ship code: `tiles.lua`, `car.lua`, `main.lua` (scp/`git pull`), rebuild frontend.
3. Ship artifact: `scp backend-lua/data/tiles_car.db ubuntu@VM:/opt/yvy/backend-lua/data/tiles_car.db`.
4. Restart `yvy-backend` (+ nginx unaffected — `/api/` already proxies).
5. **Rollback (documented here):** revert the two route additions in `main.lua` (artifact is inert — EMPTY_PNG on miss, no data served) and redeploy the previous frontend build to drop the toggle. Nothing else to unwind.

#### Edge cases
- Missing `tiles_car.db` on VM: overlay renders nothing (EMPTY_PNG) — site
  stays up; verify presence in the deploy step.
- Regeneration cadence: only when `car.db` is re-imported.

#### Verification
- Run: `curl -sk https://yvy.app.br/api/tiles/car?z=10&x=…&y=…` → PNG;
  `curl -sk https://yvy.app.br/api/car/lookup?lat=-11.19&lon=-54.90` →
  `{"imovel":…}`; open the map, toggle CAR, click an imóvel.
- **Prod auth path:** confirm `/api/car/lookup` is reachable from the browser in prod — verify nginx injects `X-API-Key` for `/api/` (or that `AUTH_REQUIRED=0`), matching the working fires endpoints today; adjust route auth to `rl`-only if the prod proxy can't inject.
- Done: prod overlay + lookup verified; deploy documented (incl. rollback + regeneration).

## Cross-cutting verification

- After Inc 2 (local): `curl /api/tiles/car` returns `image/png` with
  `Cache-Control: public, max-age=2592000, immutable`; `/api/car/lookup` on
  the Cláudia/MT point (lat -11.19154, lon -54.90798) returns
  `{imovel:{id:"MT-5103056-9E28C4DE9955482495295FAE1B03FBCE", name:"Cláudia", uf:"MT"}}`.
- After Inc 3 (local): map at z8 and z11 with CAR on shows the lime-400
  overlay distinct from UC green-400; clicking a green area shows the imóvel
  popup; clicking empty land shows "Sem imóvel CAR".
- After Inc 4 (prod): same checks against the live URL; confirm the overlay
  does not appear when toggled off and does not break fire clicks.
- Color contrast: with both UC (`#4ade80`, 0.2) and CAR (`#a3e635`, ~0.5)
  toggled, the two greens are distinguishable on both OSM and satellite.

## Standards / common-mistakes referenced

- No `.agents/standards/` or `.agents/common-mistakes/` in repo. Conventions applied:
  - JSONB BLOB: always `json(geom)`/`json_extract` — never decode the raw
    blob (AGENTS.md Gotchas).
  - copas single-threaded loop: CPU-heavy work (tile rendering, 8.4M
    polygons) never inline — offline tool + subprocess/artifact pattern
    (same as `car.db` import).
  - Route pattern: `auth.enforce` → `rl.enforce` → compute → JSON +
    `Cache-Control`; public tile routes skip auth (PRODES precedent).
  - SQLite: WAL, `synchronous=OFF` bulk, VACUUM/ANALYZE/optimize after build
    (same as `car_import` / `cache_prodes_tiles`).
  - Lua 5.1 (`lua5.1`/`luac5.1 -p`), Python 3 + Pillow for offline tooling.
  - `make test-lua` (busted, `tests/*.lua`) — add `tests/test_car_routes.lua`
    (fake-ctx route tests) + the Python `--self-test` math round-trip; frontend
    verified by `npm run build`.

## Open questions (CONSIDER from review)

- **Anti-aliasing:** `ImageDraw.polygon` is not AA'd — at z8–12 the lime boundary looks jagged over OSM/satellite. Option: 512px supersampling downscaled to 256 (~4× CPU on the dominant zooms). Decide if edge quality matters before committing the full render.
- **Polygon holes:** `prepare_geometry` preserves interior rings, but filling each ring as a polygon fills the holes. Rare for CAR and visually minor; use even-odd compositing only if carved-out holes must stay transparent.
- **Miss-path `Cache-Control`:** caching EMPTY_PNG as `immutable` is fine for CAR (no upstream to backfill, unlike PRODES's `max-age=300` miss) — stated choice, revisit if a live CAR WMS proxy is ever added.
- **z7→z8 boundary:** the z≤7 uniform-fill extends up to a tile-width (~2.8° at z7) beyond true coverage and visibly jumps inward on zoom to z8. Accepted; validate with the logged z7 covered-tile counts.

## Out of scope

- Vector tiles / per-polygon hover (rejected; click-to-inspect covers it).
- Rendering CAR *types* (status_imovel, condicao, m_fiscal) as colors — the
  dump has them but `car.db` only persists cod_imovel/uf/municipio/area/geom;
  a thematic CAR map is future work.
- Serving CAR polygons as GeoJSON for any bbox (rejected: not scalable).
- Editing `car_lookup.lua` / classification logic (unchanged).
- TI/UC legend entries (CAR matches the existing toggle-with-color-dot idiom;
  a full overlay legend is out of scope).

# Bump CAR_TILES_VERSION to invalidate stale CAR overlay tiles

## Context

The CAR click-to-inspect bug persists: clicking magenta CAR overlay areas in
Pantanal/Mato Grosso and elsewhere returns "Sem imóvel CAR aqui" even though
the backend lookup resolves the point. The previous fix (commit `05d2993b`)
regenerated `tiles_car.db` from **exact polygons** (z9–12) + low-zoom blocky
fill (z6–8) and added a 1000m snapping tolerance to `/api/car/lookup`. The
backend and data are correct — but the **browser still renders the OLD
bbox-based tiles** because `CAR_TILES_VERSION` was never bumped.

Evidence (verified live):
- `CAR_TILES_VERSION = '1'` in `frontend/src/components/Home.js:817` — set in
  the original overlay commit `ac32bca0`, **never bumped** in the fix commit
  `05d2993b` (confirmed: `git show 05d2993b -- Home.js | grep -c CAR_TILES_VERSION` → 0).
- Tiles are served with `Cache-Control: public, max-age=2592000, immutable`
  (`tiles.lua:serve_png`), so a browser that cached the old tiles keeps them
  for 30 days regardless of the new DB.
- Live browser at Manaus: `fetch('/api/tiles/car?z=9&x=165&y=272&v=1')` returns
  **1595 bytes** (stale cached tile) while a cache-busted fetch
  (`&cb=<ts>`) returns **66 bytes** (transparent miss — the tile does not exist
  in the new DB). This proves the browser is serving stale tiles.
- Data integrity is sound: direct DB checks show **0% false-magenta** at
  z9–12 for Manaus and 0.007% for Pantanal/MT z12 (exact point-in-polygon
  including holes). The tiles and lookup agree.

Intended outcome: bump `CAR_TILES_VERSION` so all browsers fetch the new
exact-polygon tiles, eliminating the persistent "Sem imóvel CAR aqui" on
visible magenta pixels.

## Assumptions and decisions

- Decision: Bump `CAR_TILES_VERSION` from `'1'` to `'2'`. Source: code @
  `frontend/src/components/Home.js:817` + `.plans/car-overlay/plan.md:401`
  ("bump `CAR_TILES_VERSION` in `Home.js` when regenerating").
- Decision: The version string is the only change needed in source; the
  backend/data are already correct. Source: verified live (0% false-magenta,
  tolerance lookup working).
- Assumption: The stale tiles are cached in the browser's HTTP cache (and
  possibly a service worker / CDN). Bumping the URL query param `v=` forces a
  fresh fetch. Source: `serve_png` immutable header + live cache-bust test.
- Assumption: No service worker or CDN layer caches the HTML/JS bundle itself
  in a way that would also need invalidation. Source: `frontend/server.js`
  serves the build directly; no SW registration found in `Home.js`/`index.js`
  (to be confirmed during implementation).
- Decision: Rebuild the frontend (`npm run build`) and restart the stack so
  the served `frontend/build/` contains `v=2`. Source: `scripts/dev/start-lua-stack.sh:102-107`.
- Decision: Deploy the rebuilt bundle to the live path (`/opt/yvy/frontend/build`,
  nginx root per `nginx.conf`/`infra/nginx-yvy-prod.conf`) so live users receive
  the fix — the dev stack alone does not fix the production bug. Source:
  `infra/nginx-yvy-prod.conf` + reviewer SHOULD-FIX #2.
- Decision: The backend `get_tile_car` reads only z/x/y and ignores `v=`; the
  version is a pure client-side cache-bust, not a server cache key. Source:
  `tiles.lua:get_tile_car` + reviewer CONSIDER #1.

## Files to touch

### frontend/src/components/Home.js
- What changes: bump `CAR_TILES_VERSION` from `'1'` to `'2'`.
- Function(s): none (constant only).
- Data shapes: `const CAR_TILES_VERSION = '2';`
- Integration points: `TileLayer url={'/api/tiles/car?z={z}&x={x}&y={y}&v='+CAR_TILES_VERSION}` (line 1354).
- Error paths: none — a version bump is a pure cache-bust; no runtime failure mode.

### frontend/build/ (generated)
- What changes: rebuilt bundle containing `v=2` in the CAR TileLayer URL.
- Integration points: served by `yvy-server`/`server.js` on :5001.
- Error paths: build failure surfaces in `start-lua-stack.sh` (exits non-zero).

## Edge cases
- Browser with a service worker caching the JS bundle: if present, the new
  `v=2` URL won't be seen until the bundle itself refreshes. Mitigation: verify
  no SW is registered; if one exists, add a cache-bust to the bundle URL too.
- CDN/proxy in front of :5001 caching `v=1` responses: the `v=2` query string
  is a distinct cache key, so it bypasses any `v=1` cache entry.
- Users who never loaded the old tiles: unaffected — they fetch `v=2` fresh.
- The 1000m tolerance already shipped: no change needed; it remains the
  safety net for rasterized-edge sub-pixel shifts.

## Verification
- Run: `grep -n "CAR_TILES_VERSION = " frontend/src/components/Home.js` → `'2'`
  (authoritative source check).
- Run: `grep -ro 'tiles/car?z={z}&x={x}&y={y}&v=2' frontend/build/static/js/*.js`
  → confirms the minifier inlined the literal `v=2` in the built bundle. If the
  minifier instead emits `"v="+CAR_TILES_VERSION`, rely on the source grep
  above (do not treat a `v=[0-9]*` match as proof of the bump).
- Run (served-data check): after restart, `curl -s -o /dev/null -w '%{size_download}'
  'http://localhost:5001/api/tiles/car?z=9&x=165&y=272&v=2'` → **66 bytes**
  (transparent miss), proving the served DB is the new exact-polygon DB and the
  previously-stale coordinate no longer returns the old bbox tile.
- Manual (browser): hard-reload the app, enable CAR overlay, click a magenta
  pixel in Pantanal/MT (e.g. `-13.15438,-59.91211`) and Manaus
  (`-3.01,-60.06`). Expect the imóvel popup, not "Sem imóvel CAR aqui".
- Manual (network): in DevTools, confirm CAR tile requests now carry `v=2`
  and return the new tile bytes (not the stale 1595-byte `v=1`).
- Deploy: copy the rebuilt `frontend/build/` to the live nginx root
  (`/opt/yvy/frontend/build`) and confirm the served bundle contains `v=2`.
- Done criteria: clicking any visible magenta CAR pixel resolves to an imóvel,
  and areas that were falsely magenta under the old bbox tiles now show no
  overlay (the fix removes false magenta, not just "resolves to imóvel"). No
  stale `v=1` tile is served.

## Standards / common-mistakes referenced
- `.plans/car-overlay/plan.md:401` — regeneration must bump `CAR_TILES_VERSION`
  to invalidate immutable tile caches; this plan enforces that missed step.
- `.agents/common-mistakes/common-mistakes.md` — no direct cache rule, but the
  "marker-after-success" theme (rule 5) applies: the version bump is the
  "marker" that a regeneration happened.

## Estimated scope
S

## Open questions (CONSIDER from review)
- Document that the backend ignores `v=` (client-side cache-bust only) — noted
  in Assumptions; no code change needed.
- The user-visible change is removing false magenta (areas that were bbox-only
  now show no overlay), not just "resolves to imóvel" — captured in Done criteria.

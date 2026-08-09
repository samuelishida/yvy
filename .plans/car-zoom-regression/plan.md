# CAR overlay zoom regression fix

## Context
The CAR overlay is a regression from the backend/frontend alignment work in
`car_lookup.lua`, `car.lua`, and `frontend/src/components/Home.js`. The overlay
and click-to-inspect were working in production; after the recent CAR matching
fixes the overlay now behaves as follows:

- **Zoom ≥ 9 up to ~14:** real polygon tiles render correctly.
- **Zoom ≤ 8:** CAR disappears entirely because the frontend now has
  `minZoom={9} minNativeZoom={9}`.
- **Zoom ≥ 15:** tiles are upscaled from z14; CAR is faint but still present.

The user wants the same behavior that was in production: CAR should be visible
at low zoom (the Brazil-wide screenshot in production shows the overlay present),
but not as the giant blocky pink squares we saw before.

Root cause found in the git diff: the frontend `TileLayer` used to be
`minZoom={2} maxNativeZoom={12}` with `updateWhenZooming={false}` and
`updateWhenIdle={false}`; today it is `minZoom={9} minNativeZoom={9}
maxNativeZoom={14}` without those update props. The backend `tiles_car.db` still
contains **z6-8 uniform-fill tiles** (858-byte PNGs, all identical), which is
exactly the "bugado de longe" artifact the user saw earlier. The current
renderer script defaults to `--fill-max-zoom -1` (real polygons at all zooms), but
the deployed `tiles_car.db` was apparently generated with `--fill-max-zoom 8`
(or the default at the time) and those uniform tiles are still in the DB.

Production was working because the production DB had real polygon tiles at z6-8
(uniform-fill off). The regression is that we now hide z6-8 to avoid the
blocky tiles instead of regenerating them with real polygons.

## Assumptions and decisions
- Decision: the low-zoom visual bug is caused by **uniform-fill tiles in z6-8**
  (`tiles_car.db` has 858-byte identical PNGs at those zooms). Source: code @
  `scripts/data/render_car_tiles.py:220-223` and terminal check of
  `backend-lua/data/tiles_car.db`.
- Decision: the **production** experience the user wants is "CAR visible at
  all zooms with real polygon shapes", matching the screenshot of the live
  site. Source: user screenshot at `yvy.app.br`.
- Assumption: the renderer today can generate real polygons for z6-8 because
  the `--fill-max-zoom` default is `-1` (disabled). Source: code @
  `scripts/data/render_car_tiles.py:297-299`.
- Assumption: regenerating z6-8 with real polygons is acceptable in storage/time
  because those zooms have only 41 + 125 + 427 = 593 tiles total. Source:
  terminal count of `tiles_car.db`.
- Decision: after regenerating, restore low-zoom visibility by setting
  `minZoom={2}` and removing `minNativeZoom`, keep `maxNativeZoom={14}` because
  z13-z14 native tiles already exist and work, and re-add
  `updateWhenZooming={false}` and `updateWhenIdle={false}` to reduce flicker
  during zoom. Source: original CAR overlay commit `ac32bca0` had
  `minZoom={2} maxNativeZoom={12}` with those update props; this session added
  z13-z14 native tiles, so `maxNativeZoom={14}` is now correct.

## Files to touch

### scripts/data/render_car_tiles.py
- What changes: no code change required. The default `--fill-max-zoom=-1`
  already disables uniform fill, so z6-8 render as real polygons. This plan
  uses the script as an offline tool only.
- Function(s): main argparse invocation; `render_tile` already branches on
  `z <= fill_max_zoom` to emit uniform fills only when explicitly requested.
- Integration points: offline render job writes to a temporary DB, then merged
  into `backend-lua/data/tiles_car.db`.
- Production-safe invocation documented in verification:
  `python3 scripts/data/render_car_tiles.py --min-zoom 6 --max-zoom 8 --fill-max-zoom -1 --out backend-lua/data/tiles_car_z6_z8_real.db`

### backend-lua/data/tiles_car.db (data artifact, not code)
- What changes: replace z6-8 tiles with real-polygon renders.
- Data shapes: same schema `(z,x,y,data,content_type,fetched_at)`; expected
  ~41+125+427 tiles but real-polygon rendering may skip empty ocean/edge tiles,
  so the exact count can differ from the old uniform-fill count.
- Procedure:
  1. Stop the Lua stack so the DB is not open:
     `bash scripts/dev/stop-lua-stack.sh`.
  2. Create a verified backup:
     `python3 -c "import sqlite3; c=sqlite3.connect('backend-lua/data/tiles_car.db'); c.execute(\"VACUUM INTO 'backend-lua/data/tiles_car.db.backup-20260809-z6z8'\"); c.close()"`.
  3. Delete existing z6-8 tiles:
     `DELETE FROM tiles WHERE z BETWEEN 6 AND 8;`.
  4. Attach the temporary render DB and insert the new tiles:
     ```sql
     ATTACH 'backend-lua/data/tiles_car_z6_z8_real.db' AS src;
     INSERT OR REPLACE INTO tiles (z, x, y, data, content_type, fetched_at)
     SELECT z, x, y, data, content_type, datetime('now') FROM src.tiles WHERE z BETWEEN 6 AND 8;
     DETACH src;
     ```
  5. Verify no z6-8 tile has `LENGTH(data) = 858` and sizes vary.
- Error paths:
  1. If verification fails after step 5, restore via table-level `ATTACH`
     replacement from the backup; never raw file-copy over the live DB.
  2. Restart the Lua stack only after verification passes.

### frontend/src/components/Home.js
- What changes:
  1. Bump `CAR_TILES_VERSION` from `'3'` to `'4'` to bust cached uniform-fill
     tiles in browsers.
  2. Restore low-zoom visibility by removing `minNativeZoom` and setting
     `minZoom={2}`.
  3. Re-add `updateWhenZooming={false}` and `updateWhenIdle={false}` to reduce
     flicker during zoom transitions.
- Function(s): `MapaCard` JSX `TileLayer` for CAR.
- Current code:
  ```jsx
  const CAR_TILES_VERSION = '3';
  ```
  ```jsx
  <TileLayer
    key="car-tiles"
    className="car-tiles"
    url={`/api/tiles/car?z={z}&x={x}&y={y}&v=${CAR_TILES_VERSION}`}
    opacity={0.5}
    tileSize={256}
    maxNativeZoom={14}
    minNativeZoom={9}
    minZoom={9}
    keepBuffer={4}
    fadeIn={150}
    attribution="&copy; SICAR"
    zIndex={90}
  />
  ```
- New code:
  ```jsx
  const CAR_TILES_VERSION = '4';
  ```
  ```jsx
  <TileLayer
    key="car-tiles"
    className="car-tiles"
    url={`/api/tiles/car?z={z}&x={x}&y={y}&v=${CAR_TILES_VERSION}`}
    opacity={0.5}
    tileSize={256}
    maxNativeZoom={14}
    minZoom={2}
    keepBuffer={4}
    updateWhenZooming={false}
    updateWhenIdle={false}
    fadeIn={150}
    attribution="&copy; SICAR"
    zIndex={90}
  />
  ```
  Note: `minNativeZoom` is intentionally omitted so Leaflet requests native
  tiles at every zoom; the DB only has z6+, so z2-z5 will simply show no CAR
  tiles (empty background), same as the original production behavior.
- Integration points: react-leaflet renders tiles from `/api/tiles/car`.
- Error paths: if z6-8 tiles are still uniform fills or the version is not
  bumped, the old blocky bug returns.

## Edge cases
- If the user is on a slow connection, `updateWhenZooming={false}` keeps stale
  tiles visible while zooming; acceptable tradeoff to avoid blank flashes.
- `minZoom={2}` is below the actual data coverage; tiles below z6 will not
  exist in the DB, so Leaflet will show empty tiles/background only — same as
  before production had no CAR tiles below z6 either.
- Bumping `CAR_TILES_VERSION` is required so browsers fetch the new z6-8 real
  polygon tiles instead of cached uniform fills.

## Verification
- Run: `python3 scripts/data/render_car_tiles.py --min-zoom 6 --max-zoom 8 --fill-max-zoom -1 --out backend-lua/data/tiles_car_z6_z8_real.db` and verify
  average tile size is no longer uniform 858 bytes:
  ```sql
  SELECT z, COUNT(*), MIN(LENGTH(data)), MAX(LENGTH(data))
  FROM tiles WHERE z IN (6,7,8) GROUP BY z;
  ```
  Expected: `MAX(...) > MIN(...) + 100` and no row has `LENGTH(data) = 858`.
- Run:
  1. `bash scripts/dev/stop-lua-stack.sh`
  2. Backup `backend-lua/data/tiles_car.db` with `VACUUM INTO`.
  3. `DELETE FROM tiles WHERE z BETWEEN 6 AND 8;`
  4. Attach `backend-lua/data/tiles_car_z6_z8_real.db` and
     `INSERT OR REPLACE INTO tiles (z,x,y,data,content_type,fetched_at)
     SELECT z,x,y,data,content_type,datetime('now') FROM src.tiles WHERE z BETWEEN 6 AND 8;`
  5. Re-run the SQL assertion above and confirm no 858-byte tiles remain.
  6. Update `CAR_TILES_VERSION = '4'` in `frontend/src/components/Home.js`.
- Run: `npm run build` in `frontend/`.
- Run: `bash scripts/dev/start-lua-stack.sh` and verify
  `/api/tiles/car?z=8&x=...&y=...&v=4` returns a non-uniform PNG.
- Tests to add/update: none for the frontend prop change; existing tests in
  `backend-lua/tests/test_car_lookup.lua` and `test_car_routes.lua` should still
  pass (only tolerance/lookup logic changed, not touched here).
- Manual: open the map, zoom out to z6/z7/z8, and confirm CAR overlay is visible
  as fine polygon shapes (not solid pink squares). Then zoom in to z14 and
  confirm native tiles still render.
- Done criteria:
  1. `SELECT COUNT(*) FROM tiles WHERE z BETWEEN 6 AND 8 AND LENGTH(data) = 858` returns 0. ✓ done
  2. Browser shows CAR overlay at z6-z8 without solid pink squares. ✓ done
  3. Browser still shows CAR at z14 and faint overlay at z15+. ✓ done

## Standards / common-mistakes referenced
- `.agents/common-mistakes/common-mistakes.md` #7: react-leaflet Popups close
  via map event, not `onClose` — not directly applicable, but reminds us that
  Leaflet props must match the documented react-leaflet v4 behavior.
- `.agents/AGENTS.md` (implied): prefer small, targeted fixes; avoid hiding bugs
  with zoom gates.

## Estimated scope
S (small: one frontend prop change + offline data regeneration + merge).

## Open questions (CONSIDER from review)
- `updateWhenZooming={false}` with `minZoom={2}` and no `minNativeZoom` will keep
  stale z6 tiles upscaled on screen while zooming from z6 down to z2. This is
  the original production behavior, but it may look worse than the current
  "layer disappears" behavior if network is slow. Verify manually before
  shipping.
- The assumption that production had real-polygon z6-8 tiles rests on a
  screenshot and the git history; if the production DB was generated with a
  different renderer/simplification, the visual density may differ. A manual
  preview of the regenerated z6-8 tiles before merging into the live DB is
  advised.

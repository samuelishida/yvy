# Fixup Plan — Make CAR Frontend/Backend Matching Perfect

## Context

The CAR (Cadastro Ambiental Rural) overlay click-to-inspect feature has been through two recent fixes: (1) removing the 30-day immutable browser cache on CAR tiles and bumping the tile version, and (2) reducing click snapping tolerance to 200 m. The user now wants a rigorous fixup pass over the backend and frontend logic to ensure the match between visible magenta overlay pixels and the `/api/car/lookup` result is as correct as possible, without regressions in the overlay behavior.

## Assumptions and decisions

- Decision: Keep the precomputed CAR tile approach. Source: user request says "with working overlay without regression"; regenerating tiles offline is already established.
- Decision: Tolerance remains 200 m for the frontend → backend click lookup. Source: user-confirmed in prior turn.
- Decision: Whether to reject snaps across holes must be explicitly decided. Current code comment at `backend-lua/app/lookups/car_lookup.lua:285` says "Interior rings (holes) are ignored — for a click on a hole we still snap to the surrounding polygon, which is the desired UX." This plan chooses to change that UX: a click inside a hole (inside exterior ring but inside any interior ring) will NOT snap to the surrounding polygon; it may only snap to an exterior ring when the point is outside the polygon entirely. The code comment must be updated to match.
- Decision: The source of truth for "is there a CAR here" is `car.db` + RTree, not the raster tiles. Source: code @ `backend-lua/app/lookups/car_lookup.lua:208-253`.
- Decision: Keep the response shape backward-compatible. Source: code @ `backend-lua/app/routes/car.lua:23-45` currently returns `{imovel: object|null}`; any new diagnostic fields go inside `imovel` so existing consumers and tests keep working.
- Assumption: False negatives (pixel visible, lookup returns null) are the primary remaining risk; false positives (popup where no pixel exists) are acceptable within the 200 m snapping radius. Source: default UX posture from current implementation.
- Assumption: PRODES tiles must keep their immutable cache. Source: code @ `backend-lua/app/routes/tiles.lua:165-172` — only CAR is no-store.
- Assumption: `car.db` geometry uses GeoJSON `[lon, lat]` order. Source: code @ `backend-lua/app/lookups/car_lookup.lua:47-85` decodes coordinates as `[pt[1], pt[2]]` then passes to `geo.point_in_polygon(lon, lat, rings)`.

## Files to touch

### `frontend/src/components/Home.js`
- What changes: add a coordinate guard in `onCarInspect` to reject `lat`/`lon` that are not numbers; otherwise the existing sequence/toggle/popup logic is already correct and should be left unchanged. No new loading/cancel guard is required.
- Function(s): `onCarInspect`.
- Data shapes: `carInspect` state keeps `{lat, lng, imovel}`.
- Integration points: called by map click handlers; renders `<Popup>` for CAR.
- Error paths: invalid coordinates silently return (no popup).

### `backend-lua/app/lookups/car_lookup.lua`
- What changes: harden `classify_point_with_tolerance` and `distance_to_geom_m`; fix the hole-snap bug and make snapping semantics explicit.
- Function(s):
  - `classify_point_with_tolerance(lon, lat, tolerance_m)` — exact fallback first, then bbox query with RTree SQL `minLon<=? AND maxLon>=? AND minLat<=? AND maxLat>=?` bound as `stmt:bind(1, max_lon); stmt:bind(2, min_lon); stmt:bind(3, max_lat); stmt:bind(4, min_lat)`. For each candidate:
    1. If the point is inside the polygon (including holes), use `point_in_geom`:
       - If it returns true → exact hit, return `source = "exact"`.
       - If it is inside the exterior ring but inside any hole → treat as not a candidate for snapping to *this* property; continue to next candidate.
    2. If the point is outside the polygon, compute distance to exterior rings only and allow snapping if distance ≤ tolerance_m; return `source = "snap"` and `distance_m`.
  - `distance_to_geom_m(lat, lon, geom)` — keep returning minimum distance to exterior rings only, but expose a separate helper `point_is_in_exterior_ring(lon, lat, geom)` and `point_is_in_hole(lon, lat, geom)` so `classify_point_with_tolerance` can reject hole-contained points. Remove the `if ridx > 1 then break end` guard only inside the hole-check helper; `distance_to_geom_m` itself still scans only exterior rings for performance.
  - `meters_to_degrees(lat, meters)` — verified correct; no change.
- Data shapes: returns `{id, name, uf, distance_m?, source: "exact"|"snap"}`. `distance_m` already exists in snap path; `source` is new.
- Integration points: called by `backend-lua/app/routes/car.lua`.
- Error paths: missing `car_conn`, invalid coords, empty candidate list return `nil`.

### `backend-lua/app/routes/car.lua`
- What changes: clamp tolerance with `math.max(0, math.min(tolerance, 2000))` instead of resetting to 0; keep response shape unchanged; `imovel` will include `source` and existing `distance_m` when tolerance > 0 returns a snap.
- Function(s): `_M.get_lookup`.
- Data shapes: response remains `{imovel: object|null}` where `imovel` may contain `distance_m` and `source: "exact"|"snap"`.
- Integration points: frontend fetch.
- Error paths: 400 for missing lat/lon; tolerance clamped to `[0, 2000]`.

### `backend-lua/app/geo.lua`
- What changes: add a `distance_to_polygon_rings` helper if needed; existing `point_in_ring` / `point_in_polygon` are correct.
- Function(s): reuse existing helpers.
- Data shapes: rings as `{{lon,lat}...}...`.
- Integration points: `car_lookup.lua`.

### `scripts/data/render_car_tiles.py`
- What changes: verify current production `fill_max_zoom` value before asserting blocky bbox-fill at low zoom; no renderer code change unless visual inspection shows a mismatch > 200 m. The renderer uses exact polygon fill when `--fill-max-zoom` is unset (default `-1`).
- Function(s): `decode_geometry`, rasterization loops.
- Data shapes: PNG blob in `tiles_car.db`.
- Integration points: served by `backend-lua/app/routes/tiles.lua:get_tile_car`.
- Error paths: none runtime; regeneration is offline.
- Concrete action: confirm the value used to generate `tiles_car.db` (search for `--fill-max-zoom` in deploy/render scripts); then run `python3 scripts/data/render_car_tiles.py --self-test` and inspect a sample tile at z10-z12.

### `backend-lua/tests/test_car_lookup.lua`
- What changes: add explicit unit tests for tolerance snapping, hole rejection, coordinate order, and tie-breaking by area.
- Function(s): new test cases.
- Data shapes: synthetic polygons with holes and known distances.

### `backend-lua/tests/test_car_routes.lua`
- What changes: add assertions that `/api/car/lookup` still returns `{imovel: object|null}`; when tolerance is used and the hit is a snap, assert `imovel.source == "snap"` and `imovel.distance_m`. Add assertions that `tolerance=5000` is clamped to 2000 (returns a snapped hit at ≤2000 m) and `tolerance=-100` behaves like exact lookup.
- Function(s): route tests.
- Data shapes: JSON response.

## Edge cases

- Click inside a polygon hole: `classify_point` already returns `nil` because `geo.point_in_polygon` tests all rings. With tolerance, the new behavior is: if the point is inside the exterior ring but inside any hole, do not snap to that property's exterior ring; allow snapping only to a different property whose exterior ring is nearest and within 200 m.
- Click near shared boundary of two properties: tolerance tie-break by larger area (with 0.1 m epsilon on distance), but exact hit wins unconditionally.
- Low-zoom blocky tiles: magenta covers entire bbox-intersected tiles even where no exact polygon exists. **Expected behavior**: lookup is exact (or 200 m snapped), so clicking inside a low-zoom magenta block that has no CAR within 200 m correctly returns null.
- High-zoom exact tiles: pixel should closely match polygon edge. **Expected behavior**: exact lookup succeeds almost everywhere inside the polygon.
- Invalid/missing lat/lon in frontend: `onCarInspect` should guard before calling backend.
- User rapidly clicks/toggles popup: `carInspectSeqRef` already guards; ensure no race re-opens a closed popup.
- CAR DB not loaded: backend returns `null`; frontend should not show "Sem imóvel CAR aqui" outside Brazil.
- Invalid coordinates in frontend: add a guard in `onCarInspect` to ensure `lat` and `lng` are finite numbers before calling backend. This catches swapped or bogus coordinates (e.g., strings) but not a Brazil-specific swap; the existing `isInBrazil` guard suppresses popups outside Brazil.
- Coordinate order: frontend sends `lat`/`lon`; backend `classify_point` expects `(lon, lat)`. **Expected behavior**: verify mapping is correct at every call site.

## Verification

- Run: `make test-lua` from the workspace root (defined in root `Makefile:18`). New tests must be Busted-compatible.
- Tests to add/update in `backend-lua/tests/test_car_lookup.lua`:
  - `classify_point` exact hit inside polygon, miss inside hole.
  - `classify_point_with_tolerance` returns nearest property within 200 m.
  - `classify_point_with_tolerance` rejects properties where the nearest ring distance crosses a hole (synthetic C-shaped polygon with hole).
  - `classify_point_with_tolerance` exact-hit priority: a point inside polygon A but within 200 m of polygon B's ring returns A with `source="exact"`.
  - Tie-break: two properties at equal distance (within 0.1 m epsilon) → larger area returned.
  - Coordinate-order smoke test: `(lon=-60.06, lat=-3.01)` matches Manaus fixture.
  - Route shape: `/api/car/lookup?tolerance=200` returns `imovel.source == "snap"` and `imovel.distance_m`.
- Manual:
  1. Open `http://localhost:5001/?lat=-3.01&lng=-60.06&zoom=15`.
  2. Click a clearly magenta pixel inside a known imóvel → popup appears with correct cod_imovel.
  3. Click a hole/river visible inside a magenta shape → "Sem imóvel CAR aqui" (or no popup if outside Brazil).
  4. Click near a shared boundary → the larger/nearest property is shown consistently.
  5. Zoom to low zoom (z6-7) and click inside a blocky magenta tile with no CAR within 200 m → "Sem imóvel CAR aqui".
  6. Open DevTools Network → `/api/tiles/car` responses have `cache-control: no-store`; `/api/tiles/prodes` still has `immutable`.
- Done criteria: unit tests pass; manual browser checks at z6, z10, z15 show no false negatives within 200 m of magenta pixels and no false positives inside obvious holes.

## Standards / common-mistakes referenced

- `.agents/common-mistakes/common-mistakes.md` — applies rule #1 (clock-relative fixtures) if adding date-sensitive tests, and rule #7 (react-leaflet v4 popup lifecycle) because CAR popup already uses the `PopupCloseSync` pattern and must keep it during refactor.

## Estimated scope

M — focused correctness pass across 3-4 files with new unit tests and manual browser verification.

## Open questions (CONSIDER from review)

- (filled by self-review)
- CONSIDER: Hole rejection across low-zoom blocky tiles may produce "Sem imóvel CAR aqui" inside magenta blocks that cover rivers/holes. Confirm production `fill_max_zoom` before deciding; if blocky fill is used at low zoom, consider logging first few rejections for manual inspection.
- CONSIDER: Distance function performance for huge MultiPolygons — keep `distance_to_geom_m` short-circuited to exterior rings; only walk interior rings when the point is inside the exterior ring.
- CONSIDER: The RTree bind order in `classify_point_with_tolerance` is already correct (`stmt:bind(1, max_lon); stmt:bind(2, min_lon); stmt:bind(3, max_lat); stmt:bind(4, min_lat)`); no change needed.
- CONSIDER: Floating-point equality on haversine distances for tie-breaking should use a small epsilon (0.1 m) in `classify_point_with_tolerance`.

## Status — implementation (implement-plan, 2026-08-09)

### DONE

- **Backend `car_lookup.lua`**: added `point_in_exterior_ring` / `point_in_any_hole`
  helpers; `distance_to_geom_m` stays exterior-ring-only (perf); updated the stale
  comment about holes. `classify_point_with_tolerance` now (1) exact-first with
  `source="exact"`, (2) rejects candidates where the point is inside a hole
  (`point_in_any_hole`) instead of snapping across the hole, (3) snaps to exterior
  rings with `source="snap"` + `distance_m`, (4) tie-breaks by larger area within
  a 0.1 m epsilon (`TIE_EPS`).
- **Backend `routes/car.lua`**: tolerance now clamped `math.max(0, math.min(tolerance, 2000))`
  instead of resetting to 0 on out-of-range; response shape unchanged
  (`{imovel: object|null}`); `imovel.source` and `imovel.distance_m` pass through.
- **Frontend `Home.js`**: `onCarInspect` now guards `latlng.lat`/`latlng.lng` for
  finite numbers before fetching; existing seq/toggle/popup logic untouched
  (PopupCloseSync pattern preserved per common-mistakes #7).
- **Tests**: added 6 new `classify_point_with_tolerance` cases in
  `test_car_lookup.lua` (exact source, snap source+distance, miss beyond tol,
  exact-wins-over-near-ring, tie-break-by-area, zero-tolerance fallback) plus a
  new `describe` block with a polygon-with-hole fixture asserting hole-rejection
  and exterior snap; added 3 route assertions in `test_car_routes.lua` (snap
  source/distance, tolerance=5000 clamped to 2000 still snaps, tolerance=-100 →
  exact behavior).
- **Renderer**: `python3 scripts/data/render_car_tiles.py --self-test` → OK.

### FILL_MAX_ZOOM finding (empirically confirmed)

Inspected the live `backend-lua/data/tiles_car.db` (347 MB):
- z6–8 tiles: uniform single color `#a3e635` → **blocky bbox fill** (`fill_max_zoom = 8`).
- z9–12 tiles: fill + transparent pixels → **exact polygon rendering**.
- Matches `.plans/car-tile-cache-bust/plan.md` ("exact z9–12 + low-zoom blocky z6–8").
- Implication for the hole-rejection CONSIDER: at z6–8 a magenta block may cover a
  river/hole with no CAR within 200 m → lookup correctly returns null ("Sem imóvel
  CAR aqui"). This is expected, not a regression. No renderer code change required
  (the 200 m tolerance plus exact z9–12 tiles already keep false negatives bounded).

### Remaining (manual, in-browser)

- `make test-lua` → **231 successes / 0 failures** (baseline 220; net +11 tests).
- Manual browser checks at localhost:5001 (z6 / z10 / z15) per Verification section.
- Deploy: frontend `npm run build` done (warning-free aside from 2 pre-existing
  eslint notes); served `frontend/build/` updated by `start-lua-stack.sh` on restart.

### DONE — manual browser verification (2026-08-09, localhost:5001)

- **z15 exact**: click inside imóvel → popup `AM-1302603-074D4C6F...` Manaus/AM (curl confirms `source:"exact"`).
- **z15 snap**: click ~98 m off the edge → same imóvel via snap (curl: `source:"snap"`, `distance_m` 61→158 m scaling; null beyond 200 m).
- **z15 toggle**: second click on the same point closes the popup (seq/toggle logic intact).
- **z15 far miss**: click >200 m from any polygon → "Sem imóvel CAR aqui" (no false positive).
- **z6 blocky (fill_max_zoom=8 zone)**: with FIRMS off, click inside a blocky magenta tile with no CAR within 200 m → "Sem imóvel CAR aqui" (expected; no false positive). NOTE: with FIRMS on, the fire hit-test wins at low zoom (intended precedence) — a pre-existing behavior, not a regression.
- **Cache headers** (curl): `/api/tiles/car` → `no-store`; `/api/tiles/prodes` → `public, max-age=2592000, immutable` (preserved).
- **Network**: CAR tile requests carry `v=2`; lookup fires `tolerance=200` with finite lat/lon (frontend guard active).

### DONE — cleanup (self-review)

- Removed unused `point_in_exterior_ring` helper (dead code — `point_in_any_hole` alone handles hole rejection).
- Simplified the empty-then branch in `classify_point_with_tolerance` to `if geom and not point_in_any_hole(...)`.
- `make test-lua` re-run: **231 successes / 0 failures**.

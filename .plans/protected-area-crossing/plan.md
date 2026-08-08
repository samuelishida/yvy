# Protected-Area Crossing — CAR fraud, DETER extraction & fire classification over UC/TI

## Context

The user asked to add "Área de Manejo Especial (AMS)" observability: flag CARs that
overlap public management areas as fraud-suspect, flag DETER clear-cuts inside those
areas as illegal extraction, and classify fires that fall inside them.

**Correction (user-confirmed 2026-08-07):** "AMS" is NOT an official data category.
In the TerraBrasilis context the AMS logo is just the KfW/Brazil–Germany cooperation
mark. The real data behind the request are **Unidades de Conservação (UCs)** and
**Terras Indígenas (TIs)** — and the repo **already has both**:
`backend-lua/data/conservation_units.json` (~298 UCs) and
`backend-lua/data/indigenous_lands.json` (~547 TIs), loaded in-memory by
`conservation_units_lookup.lua` / `indigenous_lands_lookup.lua`, served via
`/api/conservation-units` / `/api/indigenous-lands`, and rendered as overlays.

Therefore this plan **adds no new downloader and no new data layer**. It builds the
missing *crossings* on top of data that already exists:

| Crossing | Status today | This plan |
|---|---|---|
| Fire inside UC/TI → nature `crime` | ✅ `classify_fires.lua` + `fire_classify.lua` branch 1 | nothing to do (verify only) |
| DETER incursion in UC/TI → `deter_protected` alert | ⚠️ exists, weak geometry (TI = centroid-only; UC = native `uc` attr) | strengthen geometry (Inc 3) |
| CAR × UC/TI overlap → fraud-suspect flag | ❌ missing | new on-demand endpoint (Inc 1) + frontend badge (Inc 2) |
| Orchestration + docs | ❌ `deter_protected_alerts.lua` has no timer | wire into `deter_daily.sh` + document (Inc 4) |

Intended outcome: a property inspected in the dashboard shows whether it is
registered over a protected area and how much of it overlaps; the alert feed flags
large/likely-illegal cuts in protected areas; fires inside protected areas are
already `crime`.

## Architectural decisions

- Decision: **No new data source.** UCs/TIs already ship in the repo and are loaded
  into memory at startup. Refresh remains manual (ICMBio shapefile / CNUC-MMA /
  FUNAI geo-services) via the existing `download_aux_layers.py` pattern.
  Rationale: user-corrected that "AMS" is a logo, not a layer; downloading UCs would
  duplicate data we already serve. Alternatives rejected: new `management_areas`
  table, new downloader script, re-pointing at ICMBio WFS.
- Decision: **CAR×UC/TI overlap is computed on-demand per receipt** (grid sampling in
  Lua), cached in Redis, mirroring the `/api/car/prodes` pattern.
  Rationale: `car.db` has ~8.4M rows — a full-Brazil batch is expensive and
  low-value; per-property compute + 24h Redis cache is cheap and matches the existing
  PRODES verification UX. Alternatives rejected: offline batch over `car.db`
  (cross_deter_car.py style), Python microservice.
- Decision: **Overlap ratio is a Monte-Carlo estimate** (grid of points sampled inside
  the CAR polygon, ray-cast against candidate UC/TI polygons), not exact
  polygon-polygon clipping. Rationale: the codebase's established spatial primitive is
  Lua ray-cast (`geo.point_in_polygon`); exact clipping has no Lua lib and the
  PRODES pixel-counting endpoint already uses the same point-in-polygon aggregation
  approach. Error scales with the INTERIOR sample count (not the grid side) — a
  slender property occupying a small fraction of its bbox yields fewer interior
  points and a looser bound. The endpoint returns `sampled` and the UI shows the raw
  `overlap_pct`, so the estimate's weight is visible; the fraud flag is advisory.
- Decision: **Fraud flag is "suspeito" (advisory), not definitive fraud.** Status =
  `suspeito` when any UC/TI overlap ≥ `PROTECTED_OVERLAP_SUSPECT` (default 0.80, from
  the user's 80% rule). Rationale: legitimate overlaps exist (CAR predating the UC,
  sustainable-use UCs where activity is legal, cadastral drift). The UI shows the
  measured percentage so a human can adjudicate.
- Decision: **Illegal-extraction alert assumes suspect (no SINAFLOR check).** DETER
  inside a protected area generates the alert regardless of suppression
  authorization; the `sinaflor` hook in `fire_classify.lua` stays as the future
  extension point. Rationale: the app has no authorization data; user confirmed.
- Decision: **Reuse the existing `alerts:deter_protected` Redis feed** — Inc 3
  strengthens the scan's geometry but keeps key names, alert type, and tick rules in
  `alerts.lua` unchanged (backwards compatible).
- Decision: **No "AMS" naming.** Existing `ams_risk`/`/api/ams/*` = TerraBrasilis
  fire-risk ("Alerta e Monitoramento Sinótico") and stays untouched. New surface is
  named around protected areas (`protected-overlap`, `deter_protected`).

## Assumptions and answers from code

- Decision: UC/TI geometry is available in-memory at runtime. Source: code @
  `backend-lua/app/lookups/conservation_units_lookup.lua`,
  `backend-lua/app/lookups/indigenous_lands_lookup.lua` (loaded from `lookup_data`
  DB, seeded from the shipped JSON files at startup).
- Decision: UC lookup currently has **no per-entry bounds and no bbox prefilter**;
  TI lookup computes per-entry `bounds` and bbox-rejects first. Source: code @
  `conservation_units_lookup.lua:70-80` vs `indigenous_lands_lookup.lua:15-32,101-113`.
  → Inc 1 must add bounds + a `candidates_in_bbox` helper to BOTH lookups.
- Decision: `car_lookup` already exposes `get_by_cod_imovel`, `decode_geometry`, and
  `point_in_geom` (used by `/api/car/prodes`). Source: code @ `car_lookup.lua:108`,
  `routes/car.lua:96-127`. No new CAR primitives needed.
- Decision: `car.db` drops `status_imovel`/`tipo_imovel` on import — the schema and
  INSERT in `backend-lua/app/car_import.lua` keep only `cod_imovel, uf, municipio,
  area, geom`. The fraud flag is geometry-only — CAR status is not available.
- Decision: DETER×protected scan exists as `tools/deter_protected_alerts.lua`
  (UC via native `uc` attr + ≥10% incursion gate + centroid fallback; TI via
  centroid), writing `alerts:deter_protected` TTL 86400 + sentinel. Source: code @
  `tools/deter_protected_alerts.lua`, `routes/alerts.lua:542-560`.
- Decision: Fire-in-UC/TI → `crime` already implemented. Source: code @
  `fire_classify.lua` branch 1, `tools/classify_fires.lua`.
- User-confirmed: on-demand overlap, 80% threshold, assume-suspect (no auth data),
  protected-area naming, no AMS downloader.

## Risks accepted

- Monte-Carlo overlap is approximate (error ∝ interior sample count; ~±3% for a
  well-filled 32×32 grid, looser for slender polygons): accept; threshold
  configurable; raw pct + `sampled` shown in UI; adaptive resample near the threshold
  or on low interior counts, capped at 128 (Inc 1).
- Fraud false positives from legitimate CAR×UC/TI overlaps: status is advisory
  ("suspeito"), UI copy explains it flags for investigation; revisit if field users
  report noise.
- First hit on `/api/car/protected-overlap` is CPU-bound in the single-threaded
  copas loop (grid sampling ~1k ray-casts): bounded by sample cap + Redis cache;
  revisit if it shows up in latency.
- TI detection via centroid can miss large polygons straddling the boundary: fixed in
  Inc 3 with bbox-corner + area gate.
- `conservation_units.json` may not cover all state/municipal UCs: accept; refresh is
  out of scope (data source config is future work).

## Increment DAG

- Inc 1 — CAR × UC/TI overlap endpoint (M) — depends on: none — unblocks: 2, 3
- Inc 2 — Frontend CAR fraud badge (S) — depends on: 1
- Inc 3 — DETER × UC/TI geometry-based alerts (M) — depends on: 1 (reuses
  `candidates_in_bbox`) — unblocks: 4
- Inc 4 — Orchestration + docs (S) — depends on: 3

Inc 2 and Inc 3 are independent of each other once Inc 1 lands and can be built in
parallel (two PRs).

## Increments

### Inc 1 — CAR × UC/TI overlap endpoint (M)

**Depends on:** none
**Unblocks:** 2, 3
**Done criteria:** `GET /api/car/protected-overlap?cod_imovel=RO-...` returns
`{status:"suspeito", overlaps:[{type,name,overlap_pct}]}` for a property registered
≥80% over a UC/TI, cached in Redis; busted tests pass.

**Status: DONE** (2026-08-08 — `tests/test_car_protected.lua` 5/5; live smoke test
on real CAR returned `status:ok`/`suspeito` with Redis cache hit; full suite 187/0)

#### Files to touch

##### backend-lua/app/lookups/conservation_units_lookup.lua
- What changes: add per-entry `bounds` (computed from the outer ring at load, using
  the SAME lon-first convention as the TI lookup's `compute_bounds`) and a
  `candidates_in_bbox(min_lon, min_lat, max_lon, max_lat)` helper returning
  `{name, category, full_name, rings, bounds}` for every unit whose bounds overlap
  the box. Optionally add a bbox prefilter to `classify_point` (same speed win as TI).
- Function(s):
  - `_M.candidates_in_bbox(min_lon, min_lat, max_lon, max_lat) -> list<{name, category, rings, bounds}>`
- Data shapes: `bounds = {min_lon, min_lat, max_lon, max_lat}` (lon-first, matching
  `indigenous_lands_lookup.compute_bounds` and `car_lookup`'s `bbox`). Callers must
  pass the query box in the SAME lon-first order — a lat/lon swap here silently
  breaks both Inc 1 and Inc 3.
- Integration points: called by `routes/car.lua` (Inc 1) and `tools/deter_protected_alerts.lua`
  (Inc 3). No callers change behavior (existing `classify_point`/`count` untouched).
- Error paths: empty lookup (file/DB missing) → return `{}` (callers treat as no
  protected areas).

##### backend-lua/app/lookups/indigenous_lands_lookup.lua
- What changes: add the same `candidates_in_bbox(...)` helper (bounds already
  computed at load, lon-first).
- Function(s): `_M.candidates_in_bbox(min_lon, min_lat, max_lon, max_lat) -> list<{name, rings, bounds}>`
- Integration points / error paths: same as UC lookup.

##### backend-lua/app/routes/car.lua
- What changes: add `_M.get_protected_overlap(ctx)` — auth + rl enforce (same as
  `get_prodes_status`), Redis cache `car:protected:<COD>` (TTL 86400, decode-guard
  like `car:prodes:<COD>`), grid-sample the CAR polygon against candidate UC/TI
  polygons, return overlaps + status.
- Function(s):
  - `_M.get_protected_overlap(ctx)`
  - local `sample_overlap(prop_geom, bbox, candidates, samples) -> {overlaps, sampled, status}`
- Data shapes:
  - Request: `GET /api/car/protected-overlap?cod_imovel=RO-...`
  - Response: `{ok, cached, data:{cod_imovel, found, sampled, overlaps:[{type:"uc"|"ti", name, category?, overlap_pct}], status:"suspeito"|"ok"|"indeterminado", threshold}}`; `{cod_imovel, found:false, reason:"not_found"|"car_unavailable"}` like `/api/car/prodes`. `type` is lowercase, consistent with `deter_protected`'s `territory_type`.
- Integration points: registered in `main.lua`; reuses `car_lookup.get_by_cod_imovel`
  / `decode_geometry` / `point_in_geom`, `geo.point_in_polygon`. The route
  `pcall`-loads both lookups first (`load_conservation_units()` /
  `load_indigenous_lands()`, idempotent) — like `car.load_car()` — so it works even
  if `init.lua` hasn't run or the modules were re-required in tests.
- Error paths: no CAR → `found:false`; `car.db` unavailable → `car_unavailable`;
  too few interior points to trust the estimate (interior < 20 even at max grid) →
  `status:"indeterminado"` (UI shows it as "não avaliável", never as "ok");
  corrupted cache → recompute (decode-guard). Empty UC/TI lookup → `overlaps:[]`.

##### backend-lua/main.lua
- What changes: register `GET /api/car/protected-overlap` → `car.get_protected_overlap`.
- Integration points: alongside the other `/api/car/*` routes.

##### backend-lua/app/env.lua (+ .env.example)
- What changes: read `PROTECTED_OVERLAP_SUSPECT` (default `0.8`),
  `PROTECTED_OVERLAP_SAMPLES` (default `32`, grid side) and
  `PROTECTED_OVERLAP_MAX_SAMPLES` (default `128`, adaptive-refinement cap).
- Integration points: `.env` docs in AGENTS.md env table (Inc 4).

#### Edge cases
- MultiPolygon CARs: `point_in_geom` already iterates all polygons.
- Point inside UC AND TI simultaneously: counted in both (each listed in `overlaps`).
- `cod_imovel` case-insensitive (`:upper()`), like `/api/car/prodes`.
- Grid density too coarse for small properties: `samples` configurable; adaptive
  refinement — if the max `overlap_pct` lands within ±0.05 of the threshold OR the
  interior sample count is < 20, double the grid and recompute, up to a hard cap
  (`PROTECTED_OVERLAP_MAX_SAMPLES`, default 128) to bound first-hit latency.
- Per-point cost: inside the sampling loop, bbox-reject each candidate by its
  `bounds` before ray-casting (mirrors the TI `classify_point` prefilter) — no point
  is tested against a ring it cannot be inside.
- Very large properties (grid 32×32 fixed): fine — sampling cost is bounded; memory
  bounded.
- Candidate selection uses the CAR bbox — a superset of the CAR polygon (polygon ⊆
  bbox), so no protected area overlapping the property can be missed. Do not
  "optimize" this to the polygon itself.

#### Verification
- Run: `cd backend-lua && busted tests/*.lua`
- Tests to add/update: new `tests/test_car_protected.lua` — build temp yvy.db with
  UC/TI `lookup_data` (inline GeoJSON fixtures), temp `car.db` with
  `tests/fixtures/car_sample.json`; **clear `package.loaded` for the UC/TI lookup
  modules and `app.routes.car` before re-require** (test_car_prodes.lua pattern) so
  stale in-memory `units`/`lands` from other test files don't leak in; assert: (a) property fully inside a UC →
  `overlap_pct ≥ 99`, `status:"suspeito"`; (b) property outside → `status:"ok"`,
  `overlaps:[]`; (c) `found:false` for unknown cod; (d) Redis cache hit path
  (`cached:true`) with Redis stub (test_fires_routes.lua pattern); (e) adaptive
  refinement triggers near threshold.
- Done: endpoint returns expected shapes; `make test-lua` green.

### Inc 2 — Frontend CAR fraud badge (S)

**Depends on:** 1
**Done criteria:** inspecting a CAR property that overlaps a UC/TI ≥80% shows a
"Altamente Suspeito / Fraude" badge with the area name and overlap %, in pt/en.

**Status: DONE** (2026-08-08 — badge verified live in browser: APA Bacia Do Rio
São João/Mico-Leão-Dour, 100%, pt. Also fixed a pre-existing i18n bug: the prodes
panel keys lived under `dashboard.*` but Home.js calls `home.*` — moved to `home`.)

#### Files to touch

##### frontend/src/components/Home.js
- What changes: in the CAR inspection panel (where `/api/car/prodes` results render),
  when a `cod_imovel` is available also fetch
  `/api/car/protected-overlap?cod_imovel=` via `cachedFetch` (ttl 3600_000, 1h);
  render a badge when `data.status === "suspeito"` showing the top overlap
  (`type` UC/TI, `name`, `overlap_pct`) and a short explainer that this is a flag for
  investigation (not a definitive verdict).
- Integration points: reuse the existing CAR panel component/state; fire the request
  in the same effect that fetches `car/prodes` (single `cod_imovel`).
- Error paths: request fails or `found:false` → render nothing (badge hidden); no
  user-visible error.

##### frontend/src/i18n.js
- What changes: add `home.carFraudBadge` / `home.carFraudTitle` / `home.carFraudDetail`
  keys (pt + en).
- Integration points: same key groups as existing CAR labels.

#### Edge cases
- Property in multiple protected areas: show the max-overlap one with "+N outras".
- Stale localStorage cache: reuse `cachedFetch` TTL semantics; key
  `geo_car_protected_v1` if localStorage caching is desired.
- Toggle OFF for the CAR overlay: badge only renders when the panel is open.

#### Verification
- Run: `cd frontend && npm run build` (CI build check).
- Tests to add/update: none (frontend has no test runner).
- Done: manual — inspect a fixture CAR over a UC and a normal one; badge appears only
  on the former, in pt and en.

### Inc 3 — DETER × UC/TI geometry-based alerts (M)

**Depends on:** 1 (reuses `candidates_in_bbox`)
**Unblocks:** 4
**Done criteria:** `tools/deter_protected_alerts.lua` detects TI/UC incursions by
real geometry (bbox candidates + centroid/corner + area gate) instead of centroid-only
for TI and `uc`-attr-only for UC; keeps `alerts:deter_protected` key + alert type
compatible; busted tests pass.

**Status: DONE** (2026-08-08 — `tests/test_deter_protected.lua` 6/6; standalone
smoke run on a DB copy wrote sentinel `status:ok`; `bbox_corner_hits` added to
`app/geo.lua`; tool now require-able via arg-guard for tests)

#### Files to touch

##### backend-lua/tools/deter_protected_alerts.lua
- What changes: replace the centroid-only TI test and the `uc`-attr-only UC test with
  a geometry-based test:
  1. Load UC + TI lookups (already does) and use `candidates_in_bbox(DETER bbox)`.
  2. For each candidate: **incursion test** = DETER centroid inside polygon (existing)
     **OR** (DETER `area_km2 ≥ DETER_LARGE_CUT_KM2` AND ≥3 of the 4 DETER bbox corners
     lie inside the polygon) — catches large clear-cuts straddling the boundary that
     the centroid test misses.
  3. Keep the native `uc` attr path as an additional signal (DETER upstream already
     names the UC), but no longer require it. **Dedup hits by `(type, name)` inside
     `in_uc_or_ti` before aggregation** — one DETER polygon can otherwise hit the
     same UC via both the attr and the geometry path and double-count `area_ha`,
     fabricating a `crit` tick (`area_ha > 50`).
  4. **No fabricated area for geometry hits** (review SHOULD-FIX 1): keep the
     existing `area_ha = 0` for corner/centroid-detected hits — the code
     deliberately avoids fabricating area (`deter_protected_alerts.lua:161-164`,
     "sem área fabricada" — the old fabricated-area behavior produced false `crit`
     ticks). Geometry-detected incursions still reach `crit` via the class rule
     (`MINERACAO`/`DESMATAMENTO_CR`/`DESMATAMENTO_VEG` → crit), which covers the
     clear-cut classes this feature targets.
  5. Aggregate by `type:name:view_date` exactly as today; `type` MUST be lowercase
     `"uc"`/`"ti"` to keep the `alerts:deter_protected` aggregation key and
     `territory_type` byte-compatible with `routes/alerts.lua`; write
     `alerts:deter_protected` TTL 86400 + `alerts:deter_protected:last_run` sentinel.
- Function(s): local `corner_hits(polygon_rings, bbox) -> count`, local
  `in_uc_or_ti(deter_row, uc_lookup, ti_lookup) -> list<{type, name, area_ha}>`
  (`type` ∈ `"uc"`/`"ti"`, deduped, with the geometric area estimate).
- Integration points: called by nothing else; output consumed by `routes/alerts.lua`
  `deter_protected` generator (unchanged).
- Error paths: lookup unavailable → skip geometry test, fall back to `uc` attr path
  (current behavior), log warning.

##### backend-lua/app/env.lua (+ .env.example)
- What changes: read `DETER_LARGE_CUT_KM2` (default `5`) and `DETER_CORNER_HITS`
  (default `3`).

##### backend-lua/tests/test_deter.lua (or new tests/test_deter_protected.lua)
- What changes: add tests for the incursion helper with synthetic polygons: (a) large
  polygon with centroid outside but 4 corners inside → flagged; (b) small polygon
  with centroid inside → flagged; (c) centroid + corners outside → not flagged;
  (d) `area_km2 < gate` → not flagged even with corners inside.
- Integration points: busted, temp-file SQLite + inline GeoJSON fixtures.

#### Edge cases
- DETER bbox wider than the UC/TI (huge cut covering an entire area): corners test
  may fail → keep centroid test; area gate alone does not flag (avoid over-flagging).
- Geometry path has no 10% incursion filter (unlike the attr path): the ≥3/4-corner
  gate is strong enough that a mere bbox touch cannot flag; no additional filter
  needed.
- Degenerate bbox (point-like DETER): corner count falls back to centroid test.
- Sentinel TTL (36h) and key cleanup unchanged — Redis isolation per common-mistakes
  rule 2 (tests must teardown `alerts:deter_protected*`).

#### Verification
- Run: `cd backend-lua && busted tests/*.lua`
- Tests to add/update: see above.
- Done: scan produces the same key format; new geometry cases covered; full suite
  green.

### Inc 4 — Orchestration + docs (S)

**Depends on:** 3
**Done criteria:** `deter_protected_alerts.lua` runs nightly via `deter_daily.sh`;
RUNBOOK/AGENTS/spec document the protected-area crossing and correct the "AMS"
misconception.

**Status: DONE** (2026-08-08 — step 4 added to `deter_daily.sh` with rocks probe;
`bash -n` + `py_compile` + full suite green; RUNBOOK/AGENTS/TERRABRASILIS_SPEC
updated)

#### Files to touch

##### scripts/data/deter_daily.sh
- What changes: append step 4 — run `deter_protected_alerts.lua` so the existing
  `yvy-deter-daily` timer picks it up with no new systemd unit. Under `set -eu`,
  guard BOTH the interpreter and the rocks: probe
  `lua5.1 -e 'require("lsqlite3"); require("cjson")'` and wrap the step in
  `if …; then …; else echo "… skipping (deps missing)"; fi` — a fresh prod box with
  lua5.1 but no rocks must degrade to a warning, never abort the whole nightly chain.

##### RUNBOOK.md
- What changes: add a "Protected-area crossing" section: data sources (UCs = ICMBio
  shapefile / CNUC-MMA open data; TIs = FUNAI geo-services), what the app computes
  (CAR×UC/TI overlap endpoint, DETER×UC/TI alerts, fire×UC/TI classification), the
  threshold env vars, and how to refresh UC/TI data.

##### AGENTS.md
- What changes: add a row/note in the data/pipeline documentation: the
  `car:protected:<COD>` Redis cache, `alerts:deter_protected` scan, and the two new
  env vars.

##### TERRABRASILIS_SPEC.md
- What changes: add a clarification note that "Área de Manejo Especial" is NOT a
  TerraBrasilis/INPE data layer (the AMS logo is the KfW cooperation mark; the
  existing `ams*` workspaces remain "Alerta e Monitoramento Sinótico" fire-risk
  layers), and that protected-area crossings use UCs (CNUC/ICMBio) + TIs (FUNAI).

#### Edge cases
- `deter_daily.sh` runs on prod without `lua5.1` in PATH: guard with `command -v`
  and skip with a warning (same style as the existing steps).
- Sentinel from a failed nightly run: `last_run` TTL 36h self-expires; next run
  overwrites.

#### Verification
- Run: `bash -n scripts/data/deter_daily.sh`; `cd backend-lua && busted tests/*.lua`
  (unchanged); `make test-lua`.
- Done: script syntax-checks; docs updated; no new systemd unit required.

## Cross-cutting verification

- After Inc 2: manual walkthrough — open the map, enable the CAR overlay, click a
  property known to overlap a UC/TI → badge shows area + pct; click a normal property
  → no badge. Confirm pt and en.
- After Inc 3: run the scan, then `GET /api/alerts` and confirm `deter_protected`
  entries appear (existing tick rules unchanged).
- After Inc 4: full `make test-lua` + `bash -n scripts/data/deter_daily.sh` +
  `cd frontend && npm run build` + `find scripts -name '*.py' -print0 | xargs -0 -n1 python3 -m py_compile`.
- Confirm no regressions to the existing `/api/ams/*` fire-risk endpoints (naming
  collision avoided).

## Standards / common-mistakes referenced

- `.agents/common-mistakes/common-mistakes.md`:
  - Rule 1 (clock-relative fixtures) — new tests use `days_ago(n)` from
    `tests/helpers.lua`.
  - Rule 2 (Redis isolation + teardown) — new tests clean `car:protected:*` /
    `alerts:deter_protected*` keys in `after_each`.
  - Rule 3 (batching, no N+1) — the overlap endpoint is per-property by design; the
    DETER scan batches candidates via `candidates_in_bbox` (no per-DETER full lookup
    loop).
  - Rule 4 (live-schema verification) — no new upstream schema dependency in this
    plan (data already shipped); doc note only.

## Open questions (CONSIDER from review)

All reviewer CONSIDERs were applied in the edit pass:
- Accuracy bound stated as interior-sample-dependent, not fixed ±3%; `sampled`
  surfaced in the UI (Inc 1).
- Adaptive refinement capped at `PROTECTED_OVERLAP_MAX_SAMPLES=128` (Inc 1).
- Per-point bbox-reject against candidate bounds inside the sampling loop (Inc 1).
- `in_uc_or_ti` type pinned to lowercase `"uc"`/`"ti"` (Inc 3).
- Test clears `package.loaded` for UC/TI lookups + routes (Inc 1 tests).
- Inc 2 and Inc 3 may land in parallel (DAG updated).
- `car_import.lua` citation corrected (schema-level absence, not a line range).

## Out of scope

- Downloading/refreshing UC/TI vectors (data already in repo; refresh = manual via
  ICMBio/CNUC/FUNAI, future work to automate).
- "AMS" as a new data layer — no such official category.
- SINAFLOR / suppression-authorization integration (hook left in `fire_classify.lua`).
- CAR `status_imovel`/`tipo_imovel` re-import (needed only if the fraud flag must
  consider CAR status — geometry-only flag accepted).
- State/municipal UC coverage beyond the shipped `conservation_units.json`.
- Frontend tests (none exist in the repo).
- TerraClass / other map layers (removed in an earlier commit).

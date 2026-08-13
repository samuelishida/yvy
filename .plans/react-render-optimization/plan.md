# React Rendering Optimization

## Context

The user reports performance got worse. Investigation of `frontend/src/` (React 18.3,
react-leaflet 4.2, recharts 2.15, CRA 5) found the hot path is `Home.js` — the Leaflet
map page that renders up to 15k fire `CircleMarker`s plus TI/UC GeoJSON overlays, a
`FloatPanel` bottom sheet, and a `MapaCard` that owns ~20 pieces of state.

Three concrete regressions were identified via git blame, plus one long-standing
O(N×M) hot spot:

1. **`fireAlertMap` O(N×M)** (Home.js:1194-1200, from fde0d424): for each of ~15k fires
   it loops *all* alerts computing haversine distance. Rebuilt whenever `fireRows` **or**
   `alertRows` changes. With ~15k fires and "dozens" of alerts each rebuild is ~300k
   haversine calls ≈ **10–20 ms — not a multi-hundred-ms freeze**, but it fires on every
   180s alert poll / 240s fire refresh and compounds with the other re-renders below,
   causing periodic jank on an already-hot frame.
2. **`sheetVerifyFragments` unstable** (Home.js:1454, from 10989f93 bottom-sheet):
   `overlaysRows`/`natureLegendBody`/`prodesForm`/`prodesResultBody` are fresh JSX
   objects every `MapaCard` render, passed as `verify` to `FloatPanel` (a `React.memo`).
   The memo is defeated → the whole panel (alerts list, biomes, gauges) re-renders on
   every hover/click/state change.
3. **`keyedFireRenderList` O(N²) fallback** (Home.js:1218-1234, from fd099a44):
   `fireRows.find(f => f.id === fire.id)` inside a `.map` over visible fires. Only
   triggers on period switch (stale visible fires), but is O(N²) when it does.
4. **`useWindowSize` unthrottled** (Home.js:96-105): a `resize` listener calls `setState`
   on every pixel → re-renders the entire `MapaCard` subtree per resize event.

Good news already in place: `ViewportFireFilter` clips fires to visible bounds + zoom-gate
sampling (zoom<5), `CanvasRedrawOnToggle`, spatial-grid fire hit detection, a single shared
`Popup`, `compact=true` payload (~66% smaller), and `React.lazy` route splitting.

## Architectural decisions

- **Decision: keep all fixes inside `Home.js` (and its memoized children).** Rationale:
  the regressions are all in one file; no API or data-shape changes are needed. Alternatives
  rejected: moving fire rendering to a Web Worker (overkill for the actual cost, which is
  React reconciliation + memo defeat, not JSON parse).
- **Decision: spatial-grid the alert→fire matching** rather than a kd-tree. Rationale:
  alerts are few (dozens); a fixed lat/lon cell grid gives O(1) per-fire lookup and
  preserves the exact "nearest alert within radius" semantics. The grid is kept (not
  swapped for a precompute-only O(N×M)) because it is the only option that removes the
  O(N×M) rebuild entirely — but **alert centers (and their radian lat/lon) are precomputed
  once per `alertRows`** and reused by both the grid build and the distance check, so even
  the grid build is cheap (max performance). Alternatives rejected: kd-tree (more code, no
  measurable win at this alert count); precompute-only O(N×M) (simpler and lower-risk, but
  still O(N×M) on every poll — rejected for max performance; kept as documented fallback).
- **Decision: cell size is derived from the max alert radius, not a fixed 1°.** Rationale:
  `radius_km || 15` is a default, not a cap (Home.js:90); a fixed 1° cell could drop
  valid matches for alerts with larger radii. Cell size = `maxRadiusKm / (111 × cos(minLat))`
  (deg), with `minLat = BR_BOUNDS.swLat = -34`. **Longitude degrees shrink by `cos(lat)`**, so
  a naive `maxRadiusKm / 111` cell is only `maxRadiusKm × cos(lat)` wide in longitude — at
  lat -34 that is `0.83 × maxRadiusKm`, and an alert up to `1/cos(lat) ≈ 1.2` cells away in
  longitude would be missed by the 8-neighbor check. With the `cos(minLat)` term every cell
  is ≥ `maxRadiusKm` wide in **both** latitude and longitude for all `lat ≥ minLat`, so the
  8-neighbor check provably covers every valid match. (An equal-area/projected coordinate
  bucket would also work; the cos term is the minimal correct fix.)
- **Decision: memoize the `verify` fragments with `useMemo`** keyed on their real deps.
  Rationale: restores `FloatPanel`'s `React.memo` without restructuring the component tree.
- **Decision: rAF-throttle `useWindowSize`** and flush on resize end. Rationale: preserves
  responsive layout while collapsing per-pixel re-renders to one per frame.
- **Decision: build a `Map<id, fire>` once per `fireRows`** for the fallback lookup.
  Rationale: O(N) build, O(1) lookup, removes the O(N²) `.find`.

## Assumptions and answers from code

- Decision: prod is served through nginx (gzip + `immutable` cache for hashed assets) —
  bundle gzip is already handled at the edge. Source: `ansible/templates/yvy-nginx.conf.j2`.
  The C server's `max-age=3600` (yvy-server.c:312) is a dev/local concern, not prod.
- Decision: routes are already code-split via `React.lazy`; recharts (103KB gz) lives only
  in the Dashboard chunk and loads only on `/dashboard`. Source: `App.js`, asset-manifest.
- Decision: `fireStyle(fire)` already returns stable module-level object references
  (`FIRE_NATURE_COLORS`/`FIRE_STYLES`), so `FireMarker`'s `s` prop is stable — no change
  needed there. Source: Home.js:113-119, 1631.
- Decision: `t` from `useI18n` is memoized on `[lang]` → stable. Source: i18n.js:498.
- Decision: no frontend test suite exists; verification is `npm run build` + manual
  interaction. Source: package.json scripts.

## Risks accepted

- **Spatial-grid alert matching could change which alert wins** if two alerts overlap a
  fire. Mitigation: the grid stores each alert's original array index and picks the
  min-index among equidistant candidates, preserving the current "first in array order
  wins" tie-break. The old-vs-new comparison runs **inside Inc 1 before the old
  `alertForFire` is deleted**; any mismatch blocks the increment.
- **Spatial-grid cell size could drop valid matches** via longitude compression. Mitigation:
  the cell is sized `maxRadiusKm / (111 × cos(minLat))` with `minLat = BR_BOUNDS.swLat = -34`,
  making every cell ≥ `maxRadiusKm` wide in both axes; the 8-neighbor check then provably
  covers every alert that can reach a fire (see Inc 1).
- **Memoizing `verify` fragments could go stale** if a dep is missed. Mitigation: each
  fragment's dep list is enumerated from the code (see Inc 2), and `prodesQuery` is
  wrapped in `useCallback` so it is stable and safe to include in deps.
- **rAF-throttled resize could leave a stale size** if the user resizes and stops before a
  frame. Mitigation: flush the latest size on the final rAF; the effect also re-runs on
  mount.
- **`Map<id, fire>` fallback could collide on duplicate ids.** Mitigation: keep the
  existing `fireToFullIdxMap` (object-identity) as the primary path; the id-map is only a
  fallback for stale objects, and duplicate ids are already a data anomaly.

## Increment DAG

- Inc 1 — Spatial-index fireAlertMap (S) — depends on: none — unblocks: none
- Inc 2 — Stabilize sheetVerifyFragments (S) — depends on: none — unblocks: none
- Inc 3 — Throttle useWindowSize (S) — depends on: none — unblocks: none
- Inc 4 — Fix keyedFireRenderList O(N²) (S) — depends on: none — unblocks: none
- Inc 5 — Memoize highlightedFires (S) — depends on: none — unblocks: none
- Inc 6 — Cross-cutting verification (S) — depends on: 1,2,3,4,5 — unblocks: none

All increments are independent (single-file, no shared edits) and can land in any order;
Inc 6 is the final verification pass. Because all five touch `Home.js`, they are expected
**to land as a single PR** (or a tightly-sequenced series) to avoid merge churn on the same
file; the DAG ordering is for review/verification, not for separate PRs.

## Increments

### Inc 1 — Spatial-index fireAlertMap (S) — DONE
**Depends on:** none
**Unblocks:** none
**Done criteria:** `fireAlertMap` builds in O(N+M) instead of O(N×M); alert centers are
precomputed once per `alertRows`; no behavior change in which alert a fire maps to
(verified by the dev-only old-vs-new comparison, zero mismatches). The public output shape
is unchanged: `Map<fireIdx, alertId>` keyed by **fire array index** in `fireRows` (as today,
Home.js:1197) — only the computation changes, never the key or value type.

#### Files to touch

##### frontend/src/components/Home.js
- What changes: replace the `fireAlertMap` `useMemo` (Home.js:1194-1200) with a spatial
  grid over alert centers, plus a precomputed alert-center cache. **The public output stays
  `Map<fireIdx, alertId>` keyed by fire array index** (Home.js:1197) — consumers
  (`FireEventsHandler`, `Popup` at Home.js:1645) are untouched.
- Memo layering (three separate memos so the grid is never rebuilt on fire-only refreshes):
  1. `alertCenters = useMemo(() => buildAlertCenters(alertRows), [alertRows])` — rebuilt
     only on the 180s alert poll.
  2. `grid = useMemo(() => buildAlertGrid(alertCenters, cellDeg), [alertCenters])` — rebuilt
     only when alert centers change.
  3. `fireAlertMap = useMemo(() => { const m = new Map(); fireRows.forEach((f, idx) =>
     m.set(idx, nearestAlertForFire(grid, f, alertCenters))); return m; }, [fireRows, grid])` —
     O(N) lookups on fire refresh, O(N+M) when alerts change.
- Function(s):
  - `buildAlertCenters(alerts)` → `Map<alertId, {center, latRad, lonRad}>` — precompute
    each alert's center and its **radian** lat/lon once per `alertRows`; also computes
    `maxRadiusKm = Math.max(15, ...alerts.map(a => Number(a.radius_km) || 15))` — **the same
    `(a.radius_km || 15)` default as `alertForFire` (Home.js:90), never `?? 15`** — so the
    cell provably covers `alertForFire`'s exact reach. (The API always sends a numeric radius
    ≥ 5, `alerts.lua`; the `|| 15` only handles missing fields.)
  - `buildAlertGrid(alertCenters, cellDeg)` → `Map<cellKey, Array<{alert, center}>>` —
    buckets alerts by lat/lon cell. Cell size = `maxRadiusKm / (111 × cos(minLat))` deg with
    `minLat = -34` (BR_BOUNDS.swLat), **clamped to the actual minimum fire latitude** when a
    fire sits below it (see Edge cases). 1° lat ≈ 111 km and longitude degrees shrink by
    `cos(lat)`, so this cell is ≥ `maxRadiusKm` wide in both axes for all `lat ≥ minLat` →
    the 8-neighbor check provably covers every valid match (naive `maxRadiusKm / 111` would
    be only `0.83 × maxRadiusKm` wide in longitude at lat -34 and miss alerts ~1.2 cells away).
  - `nearestAlertForFire(grid, fire, alertCenters)` → alert id or null — looks up the fire's
    cell + 8 neighbors, applies the existing "distance ≤ radius_km, nearest wins, tie →
    first" rule (reuse `haversineKm` with the precomputed radians).
- Data shapes: `alertCenters: Map<alertId, {center:[lat,lon], latRad, lonRad}>`;
  `grid: Map<string, Array<{alert, center:[lat,lon]}>>`; `nearestAlertForFire` returns
  `alert.id`; `fireAlertMap` stays `Map<number, alertId>` (fire index → alert id).
- Integration points: called from the `fireAlertMap` `useMemo`; `fireAlertMap` is consumed
  by `FireEventsHandler` and the shared `Popup` (Home.js:1615, 1645).
- Error paths: empty `alerts` → empty grid → every fire maps to null (same as today).

#### Edge cases
- Alerts with no `center` are skipped (same as `alertForFire` today).
- A fire exactly on a cell boundary: the 8-neighbor check covers it.
- **Longitude boundary at the southern edge:** because the cell is sized with `cos(minLat)`,
  an alert at the fire's cell ±1 in both axes always covers the full haversine reach — no
  `1/cos(lat)` blind spot remains.
- **Fire south of `minLat` (data anomaly):** the coverage proof requires every fire to have
  `lat ≥ minLat`. In-country fires do (Brazil's southern tip ≈ -33.75), but to be safe
  `minLat` is clamped to the actual minimum fire latitude (`minLat = Math.min(-34, minFireLat)`),
  so an anomalous southern fire cannot be missed.
- Preserve tie-breaking: iterate alerts in original order, keep strictly-nearest (store
  each alert's original array index; min-index wins on equidistant).

#### Verification
- Run: `cd frontend && npm run build` (must succeed).
- Tests to add/update: none (no frontend suite). Add a **temporary dev-only comparison**:
  `__debugCompareFireAlertMaps(oldMap, newMap)` recomputes both the old O(N×M) map and the
  new grid map for the current `fireRows`/`alertRows` and `console.warn`s any fire whose
  mapped alert id differs (mismatch count + first 10 ids). It runs inside Inc 1, gated on
  `process.env.NODE_ENV !== 'production'`, and is **deleted before merge** (tracked in Inc 6).
  Any mismatch blocks the increment. Because live data may never hit the grid's boundary
  cases, the function **also runs a synthetic worst-case**: an alert placed exactly `cellDeg`
  away in longitude at lat −34, and one at `cellDeg` away in latitude — both must produce the
  same mapping under the old and new paths.
- Done: build passes; dev-only comparison reports zero mismatches; manual pan/zoom/hover
  stays smooth during an alert poll cycle.

### Inc 2 — Stabilize sheetVerifyFragments (S) — DONE
**Depends on:** none
**Unblocks:** none
**Done criteria:** `FloatPanel`'s `React.memo` is effective again — it does not re-render
when `MapaCard` re-renders for unrelated state (hover, click).

#### Files to touch

##### frontend/src/components/Home.js
- What changes: wrap the four `verify` fragments (`overlaysRows`, `natureLegendBody`,
  `prodesForm`, `prodesResultBody`) in `useMemo` with explicit dep arrays, and memoize the
  `sheetVerifyFragments` object itself. **First wrap `prodesQuery` (Home.js:1060) in
  `useCallback`** — it is currently a plain `async` function (new reference every render),
  so it must be stable before it can be a safe memo dep.
- Function(s):
  - `prodesQuery = useCallback(async (e, forcedCod) => {...}, [prodesInput, prodesLoading, t])` —
    stable reference; the body is unchanged. **Keep the per-render
    `prodesQueryRef.current = prodesQuery` assignment (Home.js:1113)** — `loadCarSummary`
    (Home.js:1178) calls `prodesQueryRef.current(fakeEvent, cod)` inside a `setTimeout`; with
    `useCallback` the ref simply holds the latest memoized closure, so the "verify from
    popup" flow keeps working.
  - `useMemo(() => ({ overlaysRows, natureLegendBody, prodesForm, prodesResult: prodesResultBody }), [deps])`.
- Data shapes: `sheetVerifyFragments` stays `{ overlaysRows, natureLegendBody, prodesForm, prodesResult } | null`.
- Integration points: passed as `verify` to `<FloatPanel>` (Home.js:1709). Also consumed via
  `prodesQueryRef` by `loadCarSummary` (Home.js:1178) — the ref assignment must be preserved.
- Error paths: if a dep is missed, the panel shows stale content — mitigated by explicit
  deps (see Risks).

#### Edge cases
- **Per-fragment dep lists (derived from the code):**
  - `overlaysRows` (Home.js:1300): `showDeforest`, `showIndigenous`, `showConservation`, `showCar`, `t`.
  - `natureLegendBody` (Home.js:1316): `fireDays`, `setFireDays`, `t`.
  - `prodesForm` (Home.js:1358): `prodesInput`, `prodesLoading`, `prodesQuery` (now stable), `t`.
  - `prodesResultBody` (Home.js:1381): `prodesError`, `prodesResult`, `protectedOverlap`, `clearProdes`, `t`.
  - `sheetVerifyFragments` object: `isMobile` + all four fragment references.
- `carHighlight` is **not** referenced by any fragment (it feeds `VerifiedCarHighlightLayer`
  at Home.js:1529) — it must NOT be a dep.
- **Scope of the win (do not over-expect):** stabilizing `verify` only removes the
  verify-prop-driven re-render. `FloatPanel` is *still* expected to re-render when its
  **other props** change — `alerts` (180s poll), `activeAlertId` (hover), and
  `airQuality`/`temperature` (weather) — plus the panel's own local state. The goal is that
  a hover/click that changes *none* of those props no longer re-renders the panel, not that
  the panel becomes fully static.
- This memoization only affects **mobile** (`sheetVerifyFragments` is `null` on desktop,
  Home.js:1454-1456); the desktop path renders the fragments directly and is unchanged.

#### Verification
- Run: `cd frontend && npm run build`.
- Tests to add/update: none. Manual: hover a fire dot → confirm the float panel does not
  visibly re-render (React DevTools "Highlight updates" shows no panel flash).
- Done: build passes; panel is stable during hover/click; PRODES form still submits correctly
  (prodesQuery stable + deps correct).

### Inc 3 — Throttle useWindowSize (S) — DONE
**Depends on:** none
**Unblocks:** none
**Done criteria:** resize re-renders at most once per animation frame, not per pixel.

#### Files to touch

##### frontend/src/components/Home.js
- What changes: rAF-throttle the `resize` handler in `useWindowSize` (Home.js:96-105).
- Function(s): `useWindowSize()` — keep the same return shape `{ width, height }`.
- Data shapes: unchanged.
- Integration points: `MapaCard` reads `width` to compute `isMobile` (Home.js:1000).
- Error paths: cancel the pending rAF on unmount; flush latest size on the final frame.

#### Edge cases
- Rapid continuous resize: only the latest size per frame is committed.
- Resize that stops mid-frame: the pending rAF still fires with the final size.

#### Verification
- Run: `cd frontend && npm run build`.
- Tests to add/update: none. Manual: drag the window edge; confirm `isMobile` flips at the
  breakpoint and the map does not stutter.
- Done: build passes; resize is smooth.

### Inc 4 — Fix keyedFireRenderList O(N²) (S) — DONE
**Depends on:** none
**Unblocks:** none
**Done criteria:** the stale-fire fallback lookup is O(1) instead of O(N) per visible fire.

#### Files to touch

##### frontend/src/components/Home.js
- What changes: build a `Map<id, fire>` once per `fireRows` and use it in the
  `keyedFireRenderList` fallback (Home.js:1218-1234) instead of `fireRows.find(...)`.
- Function(s): `const fireById = useMemo(() => new Map(fireRows.map(f => [f.id, f])), [fireRows])`.
- Data shapes: `Map<string, fire>`.
- Integration points: `keyedFireRenderList` → `visibleToFullIdxMap` → `FireEventsHandler`
  and the `FireMarker` list (Home.js:1236, 1626).
- Error paths: duplicate ids → last wins in the Map (acceptable; primary path is
  object-identity `fireToFullIdxMap`).

#### Edge cases
- **Null-id behavior change (intentional):** today `fireRows.find(f => f.id === fire.id)`
  returns the *first* fire whose id matches — and for `id == null` fires that matches the
  first null-id fire in the array, which is arbitrary and frequently wrong. The id-map skips
  null-id entries, so a stale null-id visible fire resolves to `null` (dropped) instead of
  "first null-id fire". This is a deliberate, more-correct change — call it out in the PR;
  do not reintroduce `.find`.
- **Duplicate non-null ids flip first→last:** the old `.find` returns the *first* fire with
  a given id; `Map` keeps the *last*. Only reachable on the rare stale-fire fallback and
  only if duplicate ids exist (a data anomaly). During Inc 4, verify duplicates do not occur
  in practice (`new Set(fireRows.map(f => f.id)).size === fireRows.length` on a sample of
  payloads); if they do, decide explicitly.
- Period switch: stale visible fires resolve via the id-map in O(1).

#### Verification
- Run: `cd frontend && npm run build`.
- Tests to add/update: none. Manual: switch the fire period selector (7/30/90/365) and
  confirm no ghost dots and no freeze.
- Done: build passes; period switch is smooth.

### Inc 5 — Memoize highlightedFires (S) — DONE
**Depends on:** none
**Unblocks:** none
**Done criteria:** `highlightedFires` is not recomputed on unrelated state changes.

#### Files to touch

##### frontend/src/components/Home.js
- What changes: confirm `highlightedFires` `useMemo` deps are `[activeAlert, fireRows]`
  (Home.js:1241-1248) and that `activeAlert` is itself memoized (it is, via
  `alertByIdMap`). This is a **verification-only increment** — the deps are already
  correct in the code, so no code change is expected. It is folded into Inc 6's manual
  pass; it exists in the DAG only to make the check explicit.
- Function(s): `highlightedFires` — unchanged signature.
- Data shapes: `Set<number> | null`.
- Integration points: `FireMarker` `highlighted` prop (Home.js:1632).
- Error paths: n/a (verification-only increment).

#### Edge cases
- `activeAlert` object identity must be stable across renders (it is, via `alertByIdMap`).
- **Note (out of scope, do not change):** `highlightedFires` uses a different radius than
  `alertForFire` — `radius_km × 1.25` (Home.js:1241-1248) vs `radius_km` (Home.js:90). This
  is intentional (a slightly larger visual highlight zone than the match radius); Inc 5 only
  verifies deps, it does not reconcile these two semantics.

#### Verification
- Run: `cd frontend && npm run build`.
- Tests to add/update: none. Manual: hover alerts; confirm no recompute jank.
- Done: build passes; deps confirmed correct.

### Inc 6 — Cross-cutting verification (S) — DONE
**Depends on:** 1,2,3,4,5
**Unblocks:** none
**Done criteria:** all increments verified together; no behavior regression.

#### Files to touch
- None (verification pass).

#### Edge cases
- Confirm TI/UC overlays still render and toggle correctly (regression from the earlier
  server.lua 304 fix must not reappear).
- Confirm the PRODES verify flow still works end-to-end (prodesQuery is now a `useCallback`).

#### Verification
- Run: `cd frontend && npm run build`; then serve the build and manually walk the Home
  page: pan, zoom, hover fire dots, click to lock, toggle all overlays, switch fire period,
  resize window, open the float panel tabs.
- Tests to add/update: none.
- Done: all manual checks pass; no console errors; interaction stays smooth.

## Cross-cutting verification

After Inc 6, manually walk the full Home flow at `/`:
1. Initial load renders the map with fire dots (zoom-gate sampling below zoom 5).
2. Pan/zoom stays at ~60fps (no long frames during an alert poll).
3. Hover a fire dot → popup appears; the float panel does not re-render.
4. Toggle TI/UC overlays → polygons render with no `ERR_EMPTY_RESPONSE`.
5. Switch fire period (7/30/90/365) → no ghost dots, no freeze.
6. Resize the window across the 720px breakpoint → `isMobile` flips cleanly.
7. Open each float-panel tab (alerts/biomes/clima/overlays/nature/verify) → content correct.

## Standards / common-mistakes referenced
- `.agents/common-mistakes/common-mistakes.md` §7 (react-leaflet v4 Popup) — applies to:
  Inc 2 (do not reintroduce unstable-position popup reopen); the existing `firePos`/`carPos`
  memoization is preserved.
- `.agents/AGENTS.md` — build/run commands (`make run`, `npm run build`).

## Open questions (CONSIDER from review — resolved)
- All five increments touch `Home.js`; they are expected to land as a single PR (or a
  tightly-sequenced series) to avoid merge churn on the same file. Confirm with the user
  whether a single PR is acceptable before implementing.
- Inc 2's memoization only affects mobile (`sheetVerifyFragments` is `null` on desktop).
  The desktop path renders the fragments directly and is unchanged — do not over-optimize
  the desktop path.
- Inc 5 is verification-only (deps already correct); it exists in the DAG only to make the
  check explicit and is folded into Inc 6's manual pass.
- CONSIDER — grid vs precompute-only O(N×M): resolved **in favor of the grid + precomputed
  alert centers** (max performance; see Architectural decisions). The lower-risk
  precompute-only alternative is documented as a fallback if Inc 1's comparison ever
  surfaces a mismatch that is not fixable.
- CONSIDER — `highlightedFires` radius (`radius_km × 1.25`) vs `alertForFire` (`radius_km`):
  intentional, out of scope; noted in Inc 5, do not reconcile.
- CONSIDER — old-vs-new comparison mechanism: resolved as a temporary dev-only
  `__debugCompareFireAlertMaps` (see Inc 1 Verification), deleted before merge.

## Out of scope
- Bundle-level work (recharts split, preload hints) — routes are already lazy-loaded and
  recharts only loads on `/dashboard`; revisit only if Dashboard becomes a bottleneck.
- Web Worker for fire rendering — the cost is React reconciliation + memo defeat, not parse.
- Backend API changes — all fixes are client-side.
- The C server's `max-age=3600` static cache — prod uses nginx with `immutable`; dev is fine.

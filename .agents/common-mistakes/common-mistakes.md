# Common Mistakes — Yvy

Shared lessons recorded after the TerraBrasilis Integration review (2026-08-07).
Future plans and reviews should check code against these. See also `.agents/AGENTS.md`.

## 1. Test fixtures must be clock-relative, never absolute dates

Hardcoded dates (`"2026-08-06"`) silently stop matching windowed queries
(DETER 90d, AMS 7d, CAR 7d) as time passes — a "passes today, fails next
month" date-bomb. Use `days_ago(n)` from `backend-lua/tests/helpers.lua`
(UTC, matching production's `os.date("!%Y-%m-%d", ...)` cutoffs). A fixture
that must be *outside* a window needs an offset strictly larger than the
largest window (e.g. `days_ago(120)` for a 90d window). Parser tests with
fixed absolute inputs (e.g. date-format parsing) and month-window tests (e.g.
moratorium July–Oct) are stable and may keep fixed dates.

## 2. Tests must never write production Redis namespaces — isolate + teardown

Tests that touch Redis (`alerts:deter_protected`, `car:prodes:*`) can leak
24h keys when they fail mid-test. Always clean up in a teardown/`after_each`
that runs on success AND failure, and use per-run receipt/alert ids so
teardown only targets this test's keys. A failed test leaking a long-TTL key
into the shared Redis db 0 is a production data-integrity bug.

## 3. Batch-write/read pipelines need the same batching pattern as siblings (N+1 is a code smell)

A per-fire lookup loop (`get_ams_risk_at` inside a fires loop) becomes an N+1
up to `MAX_RESULTS=10000`. Introduce a bounded batch (`get_ams_risk_batch`:
~2° buckets, bbox pre-filter in SQL, per-fire fallback only when a bucket
exceeds a candidate threshold) that returns the same results as the per-item
path. Any new per-item loop over a large set should get a batch sibling.

## 4. Ingest writers must be pinned to the LIVE upstream schema (DescribeFeatureType/GetCapabilities), not the spec

The BdQueimadas HTTP endpoint was a live 404 and the assumed
`bdqueimadas2:focos` WFS layer never existed; the real fire-focus layers are
`ams1h/ams3:active-fire-today`. AMS `fire-spreading-risk` is a polygon layer
with no risk attribute; `active-fire-today` is a point layer. Before relying
on a layer/field, verify it with GetCapabilities + DescribeFeatureType. Where
a schema can change, discover at runtime (WFS GetCapabilities) instead of
hardcoding layer names — a rename should log loudly, not silently break.

## 5. Destructive update paths need marker-after-success + auto-restore

PRODES force-update used to truncate before verifying the backup, write the
`.prodes_version` marker BEFORE ingest (failed runs never retried), and use
`sudo systemctl stop/start` around a standalone SQLite re-ingest. Correct
pattern: create+verify backup first, truncate → ingest → verify → write
marker after success; on any failure after truncate, restore via a
TABLE-LEVEL restore (`ATTACH` the `VACUUM INTO` backup and replace only the
affected table) — never a raw file copy over the live DB, which would corrupt
the running connection and revert concurrent writes to other tables.

## 6. `or` on a pandas Series raises — use column-presence checks

`gdf.get("uf") or gdf.get("sigla_uf") or ...` raises `ValueError` (ambiguous
truth value) because a Series is returned, not a scalar. Check `if "uf" in
gdf.columns: ... elif "sigla_uf" in gdf.columns: ...` and let the value be
`None` when no column exists (skip gracefully, never crash). Related
geometry pitfalls: compute areas in an equal-area CRS (EPSG:4326 `area` is in
square degrees, not hectares), paginate RTree candidate queries (a `LIMIT`
silently truncates), and in shapely 2.x `STRtree.query` takes a geometry, not
a `bounds` tuple.

## 7. react-leaflet v4 Popup: `onClose` prop is a no-op; close events fire on the MAP, not the popup

`<Popup onClose={...}>` does nothing in react-leaflet v4 — it only reads
`eventHandlers` (and the Leaflet Popup never fires a `close` event on itself;
it fires `popupclose` on the MAP with `{popup}`). So closing via the × button
left React state (`carInspect`, fire `lockedFireIdx`) intact and the `<Popup>`
still mounted. Two compounding traps made it REOPEN on the next re-render
(e.g. after zoom out):

- **`position={[lat, lon]}` array literal** changes identity every render, and
  the Popup lifecycle effect deps are `[element, context, setOpen, position]`
  → effect re-runs → `removeLayer` + `openOn` → close+reopen. Fix: memoize the
  position array on the stable values.
- **Leaflet default `closeOnClick: true`** closes the popup BEFORE the map
  click handler runs; combined with a `popupclose` listener that resets the
  open-ref, the same click then re-opened the popup (fresh lookup). Fix: set
  `closeOnClick={false}` and let the app's own click handler (synchronous
  toggle ref) close it.

Correct pattern (see `PopupCloseSync` in `frontend/src/components/Home.js`):
bind `map.on('popupclose')`, match `e.popup === <popupInstance>` via the
`ref` prop (v4 forwards the Leaflet instance), and clear the corresponding
React state.

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

## 8. Hand-crafted binary constants (PNG/byte literals) must be verified with the real decoder + asserted in a test

The 67-byte "minimal transparent PNG" in `app/routes/tiles.lua` was
hand-written hex with an invalid DEFLATE stream ("stored blocks" under a
`78 9C` compression header) and a wrong IDAT CRC — it looked plausible,
`#body < 100` asserts passed, and every cache-miss tile broke the browser
image decoder (`Image corrupt or truncated` spam). Rule: generate such
constants with the toolchain (`zlib`/PIL, not eyeballed hex), verify with
the real decoder (`PIL Image.open(...).load()` + per-chunk
`zlib.crc32`), and pin validity in a test that asserts more than the
signature (full decode). See plan `tile-corruption-biome-speed`.

## 9. Spawning detached subprocesses from the copas loop: setnx lock → owner releases → TTL is only the crash backstop

`alerts:refresh:lock` / `fires:classify:lock` pattern (consolidated by the
tile-corruption-biome-speed review): (a) `redis.setnx(lock, "1", TTL)`
before spawning, (b) the SUBPROCESS releases the lock on BOTH success and
failure (wrap the compute in `pcall`; delete the lock in the failure path
and `os.exit(1)`) — never rely on the TTL alone, or a crashed job zombies
the lock for the whole TTL and the weekly/timer trigger silently no-ops
(`started:false`), (c) `os.execute` returns immediately for a backgrounded
command but its success is NOT observable from the parent ("always 0" for
`cmd &`) — verify via the subprocess's Redis writes/logs, not the return
code. Same class of bug as common-mistakes §5 (marker-after-success).

## 10. Offline importers that DELETE before they INSERT: resolve paths in PRA + gate before the swap

`tools/import_car.lua` (2026-08 incident: click-in-property UI regressed to
`{"imovel":null}` for a week): (a) `debug.getinfo(1).source` is RELATIVE
(`"tools/import_car.lua"`) when the tool is run as `lua5.1 tools/foo.lua` —
deriving `data_dir` from it pointed at a nonexistent `tools/data/car/` while
`car_db_path()` (relative) still hit the REAL car.db: every per-UF `DELETE`
emptied the DB and every `import_file` silently returned 0. Rule: resolve
the script path to PRA (prefix `os.getenv('PWD')` when relative) and print
/ assert the resolved paths when a destructive step follows; (b) any batch
pipeline doing DELETE-then-INSERT in place must GATE after the import
(`SELECT COUNT(*) > 0` + cross-table consistency, e.g. `car_rtree ==
car_data`) and ABORT (exit 1) before distribution — `car_weekly.sh` used
to `set -e` past a 0-row import and scp'd the empty DB to prod; a
pre-import snapshot + restore on gate failure makes the gate reversible;
(c) a DELETE that needs a subquery on the SAME table being deleted captures
the ids BEFORE (`SELECT id ... ; DELETE data ; DELETE rtree WHERE id IN
(captured ids)`) — the original `DELETE FROM car_rtree WHERE id IN (SELECT
id FROM car_data ...)` ran after the data delete and never matched, leaving
8.4M orphan rtree rows that made point-lookups return null even though tiles
still rendered (stale spatial index + empty payload = the worst possible
combination: UI looks fine, every click comes back empty).
Variant found in the same month (alerts: card showed N, list "Sem alertas
ativos"): `app/db.lua` resolved `yvy.db` via `first_with_existing_parent()`
with RELATIVE candidates ordered for the repo-root cwd. A tool launched from
`backend-lua/` matched candidate 1 `backend-lua/data/yvy.db` at the
DIR level and `init_db`'s own `mkdir -p` materialized a mirror with an
EMPTY `backend-lua/backend-lua/data/yvy.db` — `find_fires` = 0 rows and the
warmer happily wrote a 0-alert payload over Redis's good one. Rule: when
picking the DB, prefer candidates whose FILE already exists (`io.open`,
prod absolute path first — immune to cwd); only fall back to parent-existing
resolution for a pristine setup (first fallback dir created once).

## 11. Card vs list count mismatch: one source of truth per dimension, normalized in ONE place

Alerts regression (card showed 821, list said “Sem alertas ativos”): the
card rendered `alerts.length` while the list rendered
`alerts.filter(!isOutOfBrazil)` — and `isOutOfBrazil` inferred Brazil from
the HUMAN-LABEL `meta` (whitelist of 6 biome names). Any code path that
failed to classify the biome (the detached `warm_alerts.lua` never called
`biome.load_biomes()`) made `meta = "Brasil"` for every alert → visible
count 0 while the card still showed the total. Two rules:
1. **Never derive a filter/flag from a display label.** A field like
   `meta` ("Brasil", "Amazônia · X", "UC · nome") has as many producers as
   there are alert types, and its values are copy, not data. The backend
   already knew the truth — normalize `out_of_brazil` from
   `center` in ONE place (`generate_all_alerts.extend`) so it covers
   100% of types (cluster, night_fire, TI, UC, prodes, pm25, DETER — all emit
   `center = {lat, lon}`), and let the UI trust the flag.
2. **Card and list must count the SAME set** (`brazilAlerts` computed once,
   reused for header, tab label, badges and rows). If a number shown to the
   user differs from what they see after clicking, the invariant is broken
   somewhere — fix the invariant, not the label. Keep the old meta-whitelist
   only as a FALLBACK for pre-fix cached payloads (`out_of_brazil ===
   undefined`), not as the primary signal.

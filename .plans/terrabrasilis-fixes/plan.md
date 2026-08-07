# TerraBrasilis Integration Review Fixes

## Context

The TerraBrasilis Integration PR (~55 files, 12 increments) shipped DETER/CAR/AMS/PRODES ingest, territorial stats, fire×vegetation crossing, a BdQueimadas source, tile layers, and dashboard-facing routes. An adversarial review (24 specialist runs across 10 chunks, live `DescribeFeatureType` research, high-risk claims re-verified against the code) found that **several data paths never ingest correctly against the live TerraBrasilis API**, the main map 500s on load, destructive-update paths can wipe data, and the test suite is date-bombed and pollutes production Redis.

**Intended outcome**: fix every MUST-FIX (data integrity, security, live-schema correctness) plus the cheap SHOULD-FIXs, each verified against the live service or the test suite, in reviewable single-PR increments. Frontend *visual* declutter is out of scope (owned by `.plans/visual-declutter/`).

## Architectural decisions

- **Decision: BdQueimadas ingests via WFS GetCapabilities discovery** (user-confirmed). The old endpoint (`/queimadas/api/focos/`) is a live 404 and the assumed `bdqueimadas2:focos` layer does not exist — fire foci are `ams1h/ams3:active-fire-today`. The tool discovers fire-focus layers at runtime, so a schema change can never again silently kill the integration. Alternatives rejected: hardcoded layer names (breaks silently on rename), keeping the HTTP API (still 404).
- **Decision: unknown CAR receipt → HTTP 200 + `{found:false}`** (user-confirmed). A missing receipt is not a server error; the frontend's `propertyNotFound` branch becomes reachable and `apiCache`'s throw-on-`!ok` no longer turns a 404 into a raw "HTTP 404". The two distinct not-found cases are separated via a `reason` field: `not_found` (receipt genuinely absent) vs `car_unavailable` (CAR data not ingested yet, preserving today's `:66` note semantics).
- **Decision: AMS risk is presence-based, derived from `ws:layer`** (user-confirmed). DescribeFeatureType verified live 2026-08-07: NEITHER `fire-spreading-risk` (polygons: `id, biome, geocode, geom, municipality, view_date`) nor `active-fire-today` (points: `id, biome, id, municipio, satelite, view_date, viewed_at`) carries a risk attribute — presence-based is the only option. Store `ws:layer` in the `layer` column and derive `risk_level` from a layer-name map (both → `high`) so it is never NULL.
- **Decision: PRODES re-ingest runs standalone — drop `sudo systemctl stop/start`** (user-confirmed). SQLite WAL supports concurrent readers; the service keeps serving. A brief partial-data window is accepted and mitigated by restore-on-failure + marker-after-success. No NOPASSWD sudo needed.
- **Decision: tile routes get rate-limiting + CORS allowlist, stay public** (user-confirmed). Tiles power a public map; the security fix is honoring `CORS_ORIGINS` instead of hardcoded `*`.
- **Decision: scope = MUST-FIX + cheap SHOULD-FIX** (user-confirmed). Refactors (`scripts/common.py`, frontend component extraction, `name_hash` widening, `get_deter_stats` redesign) are deferred to Open questions.
- **Decision: `db.lua` is the single SQLite layer; all index changes are idempotent `CREATE INDEX IF NOT EXISTS` in `init_db()`** (existing pattern).

## Assumptions and answers from code

All verified this session against the current tree (post `feat(terrabrasilis)` commit).

- **`vegetation_at` is a live 500 on the main map**: `db.lua:1092-1095` concatenates `p.year`, which is nil because real PRODES labels are `"7 d2007"` / `"64 r2024"` (count prefix) and the parser `d.name:match("^([dr])(%d%d%d%d)$")` at `db.lua:1022-1024` never matches → every vegetation row has nil `type`/`year`. `Home.js:1350` always requests `?vegetation=true&ams=true`, so the main fires fetch 500s.
- Fires cache key is built from raw params pre-`tonumber` → `?source=ams` (invalid value → no filter) and `?ams=true` both produce suffix `:ams` (`fires.lua:45,55-56,71-76`) → collision. `?ams=true` runs an N+1 per-fire `get_ams_risk_at` loop (`fires.lua:88-91`, up to `MAX_RESULTS=10000`); bbox only checked `ne<=sw`, never range-clamped; dead `or {status="unknown"}` fallback (`:84`).
- `car.lua:72` 404s unknown receipts; `cjson.decode(cached)` unguarded (`:57`); `point_in_geojson` re-decodes JSON per candidate (`car_lookup.lua:28-30`) up to 50k×; O(points×classes) loop (`car.lua:106`); dead `inside` counter (`:95`). Frontend `propertyNotFound` (`Home.js:987`) is unreachable because `apiCache.js:30` throws on `!r.ok`.
- `deter.lua:43-44` only clamps `limit > 5000`, never the lower bound (SQLite `LIMIT -1` = unbounded) — DoS on the single-threaded loop.
- `tiles.lua:154` hardcodes `Access-Control-Allow-Origin: *` (bypasses `server.lua:232-235` allowlist); tile routes registered bare (`main.lua:192-201`), no auth/`rl.enforce`; `open_prodes_db`/`resolve_generic_db` duplication; mixed-case env `TerraClass_TILES_DB`.
- `enrich_fire_deter.lua:82-91` builds territory with only CAR (no TI/UC) → `fire_classify.lua:144` crime path never fires → protected-area fires downgraded to natural; `build_deter` reads `alerts[1]` only (`:40-41`).
- `deter_protected_alerts.lua:139` sums whole-polygon `area_km2` (not the UC-overlap `areauckm`, which is only used for the ≥10% gate `:78-81`); no `last_run` sentinel (stale data served for up to 24h); `classname = classes[1]` (`:141-144`) while `alerts.lua:519-526` inspects only `classname` → severe classes under-ticked.
- `ingest.lua:113-124`: old backup deleted before new verified; truncate with no auto-restore; `"VACUUM INTO '" .. backup_path .. "'"` unescaped (`:117`); wal_checkpoint busy check can never fail (busy is in the result row, not the exec code, `:99-106`).
- `check_prodes_update.sh:80` writes `.prodes_version` **before** ingest (failed run never retried, `:52` skips); `curl -s -m 600 -o ...` without `--fail` (`:67-68`); `unzip -o -q` without zip-slip guard; `sudo systemctl stop/start yvy-backend` with no NOPASSWD declared anywhere.
- `download_deter_wfs.py:109` uses `areatotalkm` (absent on `deter-amz:deter_amz`) → `area_km2` always NULL. `download_ams_wfs.py`: DELETE by `view_date` only (`:109`) wipes sibling ws×layer rows (all 6 share the date); `layer` column stores feature id, not `ws:layer` (`:102`); `satelite or satelite` typo (`:100`); `ams2` has no layers; no risk attribute exists.
- `precompute_deforestation_stats.py:52` `gdf.get("uf") or ...` raises `ValueError` on a Series. `cross_deter_car.py:202` computes `inter.area / 10000` on EPSG:4326 (square degrees, not hectares); RTree `LIMIT 5000` truncates candidates (`:36`); `STRtree.query(geom.bounds)` tuple misuse (`:264`). `requirements.txt` lacks `pillow` (needed by `download_cerrado_veg.py:27`, `download_terraclass.py:31`, `render_car_tiles.py:42`).
- `ci.yml:68-87`: new shell scripts (`check_prodes_update.sh`, `deter_daily.sh`, `setup-python-env.sh`) absent from `sh -n`/`bash -n`/shellcheck lists; `[ -f "$f" ] && sh -n "$f" || echo "SKIP …"` masks real syntax errors. `.gitignore:194` pins one PRODES dir; `.prodes_version` unignored. `deter_daily.sh` has no systemd unit (only `yvy-prodes-check.timer.j2` exists, running `check_prodes_update.sh`). `ansible/templates/yvy-nginx.conf.j2` never injects `X-API-Key` (playbook passes `api_key` var to the template, template ignores it).
- Tests: `test_deter.lua` (`:53,55,79-81`), `test_ams.lua` (`:42-50,84`), `test_deter_car.lua` (`:43-52,63`) hardcode `2026-08-06`; no `os.time()`-relative fixture precedent exists. `test_alerts.lua:93-99` asserts inside the guard (vacuous) and deletes Redis only on success (`:83,101`); `test_car_prodes.lua` writes prod `car:prodes:*` with no teardown (`:48-60`); `fake_ctx` duplicated in 8 files, `package.loaded["app.db"]=nil` reset in 9 files.
- **Disconfirmed** (dropped): `ams.lua:65-69` already guards `geom.coordinates`.
- Check command: `make test-lua` = `cd backend-lua && busted --verbose tests/*.lua`. CI additionally: `luac -p` on all non-test Lua, `python3 -m py_compile scripts/*.py`, `sh -n`/`bash -n`/shellcheck, `ansible-playbook --syntax-check`, `npm run build` with `CI=true DISABLE_ESLINT_PLUGIN=true`. **Tests require a running Redis** (CI provides `redis:7`; `app/redis.lua` connects for real).

## Risks accepted

- **Live-schema drift on DETER/AMS fields** (`areauckm`/`areamunkm`, AMS layer names): mitigated by running each ingest increment against the live service during verification; BDQ additionally self-discovers via GetCapabilities; FeatureCollection validation added so a schema break is loud, not silent.
- **Brief empty/partial `deforestation_data` window during PRODES re-ingest** (we drop the service stop/start): accepted; restore-on-failure + marker-after-success guarantee a failed run never leaves the table empty or the marker written.
- **API contract change (car 404 → 200)** may surprise other API consumers: mitigated by updating the only consumer (frontend) in the same increment.
- **`db.lua` churn across Inc 1 / Inc 7** (sequential PRs, same file): mitigated by ordering (Inc 7 depends on Inc 1) and keeping changes additive.
- **Tests still require live Redis locally**: accepted; CI provides it; hygiene fixes (namespaces + teardown cleanup) ensure failures can't pollute production keys.
- **`vegetation_at` fix depends on label-format assumptions**: the new parser matches `[dr]\d{4}` anywhere in the label; if TerraBrasilis changes the format again, the nil-guard (skip → `status:unknown`) keeps the route healthy instead of 500ing.

## Increment DAG

- Inc 1 — db.lua: vegetation_at crash (S) — depends: none — unblocks: 7
- Inc 2 — Tests: de-date-bomb fixtures (S) — depends: none — unblocks: none
- Inc 3 — sync_bdqueimadas: WFS GetCapabilities rewrite (M) — depends: none — unblocks: 12
- Inc 4 — Python WFS downloaders: DETER area + AMS fixes (M) — depends: none — unblocks: 11
- Inc 5 — PRODES force-update safety (M) — depends: none — unblocks: none
- Inc 6 — Deploy + edge security (M) — depends: none — unblocks: none
- Inc 7 — db.lua hardening (M) — depends: 1 — unblocks: 9
- Inc 8 — tools: enrich_fire_deter + deter_protected_alerts (M) — depends: none — unblocks: 10, 12
- Inc 9 — routes fires+car + frontend consumers (M) — depends: 7 — unblocks: 12
- Inc 10 — routes deter/ams/tiles/alerts (M) — depends: 8 — unblocks: 12
- Inc 11 — Python batch: precompute + cross_deter_car + requirements (M) — depends: 4 — unblocks: none
- Inc 12 — Tests: Redis hygiene + review coverage (S) — depends: 2, 3, 8, 9, 10 — unblocks: none

Increments 1, 2, 3, 4, 5, 6, 8 are independent roots and can run in parallel. Serialization is on shared files: 1→7→9 (`db.lua`), 4→11 (Python helpers), 8→10 (`deter_protected_alerts` classname → `alerts.lua` tick), and the test tail: Inc 12 depends on 2, 3, 8, 9, 10 (it audits the de-date-bombed fixtures, BDQ mapping, and the route/tool behavior fixes).

---

## Increments

### Inc 1 — db.lua: fix vegetation_at nil-crash (live 500) (S) — **DONE (2026-08-07)**

**Depends on:** none
**Unblocks:** 7
**Done criteria:** `curl "http://localhost:5001/api/fires?vegetation=true"` returns 200 with vegetation context; a PRODES label like `"7 d2007"` yields `native/deforested/regrowth` statuses, and a non-matching label yields `status:"unknown"` instead of a 500.

#### Files to touch

##### backend-lua/app/db.lua
- What changes: fix the PRODES label parser (`~:1022-1024`) so it extracts type/year from count-prefixed labels (`"7 d2007"` → `type="d"`, `year="2007"`), and add a nil guard in the vegetation-context builder (`~:1068-1096`) so any row whose label fails to parse is skipped (status `unknown`), never concatenated.
- Function(s): `parse_prodes_label(name)` (new helper, returns `type, year` or nil) used by the vegetation-context builder (`get_vegetation_context_batch`).
- Data shapes: `name: "7 d2007" | "64 r2024" | "<unexpected>"` → `{type="d"|"r", year="2007"}` or nil.
- Integration points: called from `get_vegetation_context_batch` when building `deforested_`/`regrowth_` keys.
- Error paths: label doesn't parse → row contributes `{status:"unknown"}`; never raises.

##### backend-lua/tests/test_fire_vegetation.lua
- What changes: add cases for count-prefixed labels (`"7 d2007"`, `"64 r2024"`) and for a non-matching label (assert no crash, `status=="unknown"`).
- Integration points: `make test-lua`.

#### Edge cases
- Label `"d2007"` without count prefix (older data) — parser must handle both.
- Mixed dataset where some labels parse and others don't — the batch must return context for the parsable ones and `unknown` for the rest, without dropping the whole batch.
- `get_vegetation_context_batch` returns a full map (never nil) — the dead `or {status="unknown"}` fallback in `fires.lua` becomes truly dead and is removed in Inc 9.

#### Verification
- Run: `make test-lua` (busted, incl. new cases).
- Run: `curl -s "http://localhost:5001/api/fires?vegetation=true" | head -c 400` → 200.
- Done: no `attempt to concatenate a nil value` on the fires route; test_fire_vegetation green.

---

### Inc 2 — Tests: de-date-bomb fixtures (S) — **DONE (2026-08-07, partial: 3 files; remaining test files folded into Inc 12)**

**Depends on:** none
**Unblocks:** none
**Done criteria:** `make test-lua` passes on any calendar date (no absolute `2026-08-06` literals); a `git grep '"2026-' backend-lua/tests` returns 0 (stable past-dated fixtures like `"2025-01-01"` are allowed — they never move relative to the clock).

#### Files to touch

##### backend-lua/tests/helpers.lua (new)
- What changes: shared test helpers — `days_ago(n)` (returns `os.date("!%Y-%m-%d", os.time() - n*86400)`, matching production's UTC cutoff) and the first shared `fake_ctx()`.
- Function(s): `_G.days_ago(n)`, `_G.fake_ctx()`.
- Data shapes: integer days → `"YYYY-MM-DD"` string.
- Integration points: required by the de-date-bombed test files; also starts the `fake_ctx` dedup (8 copies today) — other files can migrate in Inc 12.

##### backend-lua/tests/test_deter.lua, test_ams.lua, test_deter_car.lua
- What changes: replace hardcoded `"2026-08-06"`/`"2026-08-05"`/`"2026-08-07T00:00:00Z"`/`"2026-08-03"`/`"2026-06-01"` fixtures with `days_ago(n)` values. Out-of-window fixtures become `days_ago(120)` (strictly larger than the 90-day DETER window) instead of `"2026-06-01"`.
- Data shapes: fixture dates derived from the clock.
- Integration points: window queries in `db.lua` (`os.date("!%Y-%m-%d", os.time() - days*86400)`).
- Error paths: none.

#### Edge cases
- A fixture that must be *outside* a window must use an offset strictly larger than the largest window in the codebase (90-day DETER-stats window → `days_ago(120)`) — and the assertion must not depend on the exact clock date.
- Timestamp fixtures (`"2026-08-07T00:00:00Z"` = "today at midnight") should be built as `os.date("!%Y-%m-%dT00:00:00Z", os.time())`.

#### Verification
- Run: `make test-lua` twice (today and tomorrow it still passes by construction).
- Run: `grep -rn '"2026-' backend-lua/tests/` → 0 matches.
- Done: suite is clock-relative.

---

### Inc 3 — sync_bdqueimadas.lua: WFS GetCapabilities rewrite (M) — **DONE (2026-08-07; live discovery verified: ams1h/ams3 active-fire-today only; GetFeature end-to-end ingest pending coordinator live run)**

**Depends on:** none
**Unblocks:** 12
**Done criteria:** running the tool inserts `source='bdqueimadas'` rows into `fire_data` from the live TerraBrasilis WFS; `data_pas`/`confidence` are gone; `uf` is kept and mapped from the live `estado` field; layer discovery is automatic.

#### Files to touch

##### backend-lua/tools/sync_bdqueimadas.lua
- What changes: rewrite the fetch layer. (a) Query `GetCapabilities` (`https://terrabrasilis.dpi.inpe.br/geoserver/ows?service=WFS&request=GetCapabilities`), select fire-focus layers with an EXPLICIT filter + rationale: workspace starts with `ams` AND layer name contains `active-fire` (matches `ams1h:active-fire-today` / `ams3:active-fire-today`). Rationale: these are the fire POINT layers BDQ ingests into `fire_data` — `fire-spreading-risk` is the polygon layer owned by the AMS risk downloader (Inc 4) and must NOT be ingested as fire foci. The filter naturally excludes `dummy`, `cs_*_view`, `last_date`, `municipalities_border` (no `fire` keyword); (b) page through features (WFS 1.1 `startIndex`/`count` or 2.0 `count` + `startindex`); (c) map live fields `data_hora_gmt` (→ `acq_date` normalized to `YYYY-MM-DD`), `estado` (→ `uf`), `longitude`/`latitude`; (d) reject any page that is not `type == "FeatureCollection"`; (e) insert with `source='bdqueimadas'`; (f) keep the existing Redis sentinel pattern for single-flight.
- Function(s): `discover_fire_layers()`, `fetch_wfs_page(layer, start)`, `map_feature(f)`.
- Data shapes: WFS `FeatureCollection` → `{lat, lon, acq_date, source='bdqueimadas'}`; `uf` (from `estado`) stored in the JSONB `data` field.
- Integration points: same run loop as today (dedupe/enrich style), called manually + optionally from `run-lua` docs.
- Error paths: GetCapabilities unreachable → log + exit nonzero (no partial run); zero fire layers → warn + no-op; non-FeatureCollection page → abort loudly (no silent truncation); HTTP non-200 → fail.
- Observability: log layer chosen, page count, rows inserted.

##### backend-lua/tests/test_bdq.lua
- What changes: update to the new field mapping + normalized `acq_date` (fixture-driven, no network).
- Integration points: `make test-lua`.

#### Edge cases
- WFS 1.1 vs 2.0 response namespaces — parse `featureMember` (1.1) and `member` (2.0); inspect the GetCapabilities `version` first.
- Duplicate rows across layers (a fire appearing in `ams1h` and `ams3`) — the DB dedup handles exact dupes; document that near-dupes (different timestamps) are kept (same as FIRMS behavior).
- Layer set changes between runs — discovery re-runs each invocation.
- GetCapabilities over https fails (TLS/cert) → retry once over http (the public GeoServer serves both); log the scheme used.

#### Verification
- Run: `make test-lua`.
- Run: `lua5.1 backend-lua/tools/sync_bdqueimadas.lua` against the live service → nonzero rows with `source='bdqueimadas'`; second run inserts ~0 new rows (idempotent).
- Done: integration ingests real data against the live API.

---

### Inc 4 — Python WFS downloaders: DETER area + AMS fixes (M) — **DONE (2026-08-07; code + offline functional tests 20/20; live GetFeature timing out today — discovery dry-run verified: ams1h/ams3 → fire-spreading-risk+active-fire-today, ams2 → none)**

**Depends on:** none
**Unblocks:** 11
**Done criteria:** `download_deter_wfs.py` produces non-NULL `area_km2`; `download_ams_wfs.py` leaves all ws×layer rows for the same `view_date` intact and stores `ws:layer` in the `layer` column with a non-NULL derived `risk_level`.

#### Files to touch

##### scripts/download_deter_wfs.py
- What changes: when `areatotalkm` is absent (the `deter-amz:deter_amz` case), compute `area_km2 = areauckm + areamunkm` (each defaulting to 0); validate each page is a `FeatureCollection` before reading `features`.
- Function(s): `_num(props.get("areatotalkm")) or (_num(props.get("areauckm")) + _num(props.get("areamunkm")))`.
- Data shapes: WFS feature props → `{area_km2: float}`.
- Error paths: both fields missing → NULL + warn (don't fabricate); non-FeatureCollection page → abort.
- Integration points: `to_sqlite` writer (unchanged).

##### scripts/download_ams_wfs.py
- What changes: (a) DELETE by `(view_date, layer)` instead of `view_date` alone — requires `to_sqlite` to receive and store `ws:layer`; (b) `layer` column = `f"{ws}:{layer_name}"`; (c) fix `satelite or satelite` → a single correct `satelite` read; (d) derive `risk_level` from layer presence — **DescribeFeatureType verified live 2026-08-07: neither `fire-spreading-risk` nor `active-fire-today` carries a risk attribute**, so presence-based stands and the derivation map covers BOTH layer names: `fire-spreading-risk` → `high`, `active-fire-today` → `high` (intentionally constant per layer; documented in `derive_risk`); (e) discover layers per workspace via GetCapabilities — filter = workspace starts with `ams` AND layer name contains `fire` (auto-selects `fire-spreading-risk` + `active-fire-today` in `ams1h`/`ams3`; excludes `dummy`/`cs_*_view`/`last_date`/`municipalities_border` which contain no `fire` keyword); skip workspaces with zero discovered layers gracefully; (f) validate `FeatureCollection`; (g) one-time cleanup of legacy rows for affected view_dates (`layer NOT LIKE '%:%'` or `risk_level IS NULL`); (h) wrap each layer's DELETE+INSERT in a single transaction so a mid-run failure can't wipe a layer's day.
- Function(s): `derive_risk(layer)`, `discover_workspace_layers(ws)`, `to_sqlite(rows, ws, layer)`.
- Data shapes: rows now carry `{ws, layer, risk_level, view_date, geom}`; DELETE predicate `WHERE view_date = ? AND layer = ?`.
- Error paths: empty workspace → skip with log; layer without geometry → skip row; non-FeatureCollection → abort.
- Integration points: `run()` loops workspaces × discovered layers.

#### Edge cases
- **Backfill**: existing `ams_risk` rows have `layer = feature-id` and NULL `risk_level` — the re-run's cleanup (g) deletes those legacy rows for affected view_dates, then inserts new `ws:layer` rows with derived `risk_level`, inside a per-layer transaction (h) so a failure never leaves the day half-wiped.
- Same `view_date` for all 4 discovered combos (today) — no longer wipes siblings.
- `ams2` in the live service exposes only `municipalities_border` → discovery returns zero layers → skip with a log line (no 404 noise, no failure).
- A workspace with zero layers must not fail the whole run.

#### Verification
- Run: `python3 -m py_compile scripts/download_deter_wfs.py scripts/download_ams_wfs.py`.
- Run: both scripts against the live WFS; then `SELECT layer, risk_level, COUNT(*) FROM ams_risk WHERE view_date = '<today>' GROUP BY layer, risk_level` shows all discovered layers with non-NULL risk_level; `SELECT COUNT(*) FROM deter_polygons WHERE area_km2 IS NOT NULL` > 0.
- Done: live data correct; no sibling wipe.

---

### Inc 5 — PRODES force-update safety (M) — **DONE (2026-08-07)**

**Depends on:** none
**Unblocks:** none
**Done criteria:** a failed force-update leaves `deforestation_data` intact (auto-restore) and does NOT advance `.prodes_version`; a successful run advances the marker only after ingest completes.

#### Files to touch

##### backend-lua/app/ingest.lua
- What changes: (a) force-update path: create + verify the new backup **before** truncate; on any failure after truncate, restore via a **table-level restore** — `ATTACH` the `VACUUM INTO` backup and replace only `deforestation_data` (never a raw file copy over the live DB, which would corrupt the running service's connection and revert concurrent writes to other tables like `fire_data`/`news` made during the ingest window) — then re-raise; (b) don't delete the old backup until the new one is verified; (c) escape `backup_path` in `"VACUUM INTO '" .. backup_path .. "'"` (validate it's a plain filename/path, no quote injection); (d) fix the `wal_checkpoint` success check — read the busy flag from the **result row** (`PRAGMA wal_checkpoint` returns `busy, log, checkpointed`), not the exec return code.
- Function(s): `force_update_prodes(db, backup_path)` (or the existing equivalent) reordered: backup → verify → truncate → ingest → verify → update marker; `restore_deforestation_from(backup_path)` (ATTACH + table swap/`INSERT OR REPLACE` + DETACH); `checkpoint_ok(result)`.
- Data shapes: backup file path; result row `{busy, log, checkpointed}`.
- Integration points: `run()` force path; called by `check_prodes_update.sh` re-ingest.
- Error paths: ingest throws after truncate → restore backup, exit nonzero; VACUUM INTO fails → keep old backup, exit nonzero; checkpoint busy → retry once, then warn.

##### backend-lua/tests/test_ingest.lua
- What changes: add a forced-failure test (e.g. point the ingest at a bad source) asserting `deforestation_data` is restored to pre-run contents.
- Integration points: `make test-lua`.

##### scripts/check_prodes_update.sh
- What changes: (a) move the `.prodes_version` write to AFTER successful ingest (`:80` → after `:84-97`); (b) `curl -fL -m 600` (fail on HTTP error); (c) verify the zip before use (`unzip -t`, reject non-zip content, extract with a path-traversal guard — `unzip` into a fresh dir and reject entries containing `..`); (d) **remove the `sudo systemctl stop/start yvy-backend` calls** (user decision) — the re-ingest runs standalone against SQLite WAL.
- Function(s): `download_and_verify()`.
- Error paths: curl non-zero/HTTP error → no marker write, exit nonzero; zip invalid → no marker, no re-ingest; ingest fails → marker not written (retried next run).

#### Edge cases
- First run with no existing backup — treat as "backup = current state" (create one before truncate).
- Marker file write itself fails — treat as failure (no ingest-side marker).
- A previously-failed run left the marker un-written — next run must retry (this is the fix).

#### Verification
- Run: `make test-lua` (incl. new restore test).
- Run: `bash -n scripts/check_prodes_update.sh`; simulate a failed ingest (bad zip) → `.prodes_version` unchanged, DB intact.
- Done: destructive path is safe; failed runs are retried.

---

### Inc 6 — Deploy + edge security (M) — **DONE (2026-08-07; + coordinator fix: venv is a runtime dep not a test dep — setup-lua.sh now always creates it unless YVY_SKIP_PYTHON_ENV=1; fixed pre-existing unclosed-quote bug in setup-lua.sh)**

**Depends on:** none
**Unblocks:** none
**Done criteria:** fresh VM deploy succeeds (venv created); nginx injects `X-API-Key`; CI catches syntax errors in the new shell scripts and no longer prints false "SKIP"; `git status` stays clean with a new PRODES version dir; `deter_daily.sh` is timer-scheduled.

#### Files to touch

##### ansible/playbook.yml
- What changes: add `python3-venv` to the apt list (`:26-47`); enable the new `yvy-deter-daily.timer`.
- Integration points: `setup-python-env.sh` (`python3 -m venv`) now succeeds on fresh VMs.

##### scripts/setup-lua.sh
- What changes: guard the venv setup so it can be skipped explicitly (e.g. `YVY_INSTALL_TEST_DEPS=0` already exists — make it skip `setup-python-env.sh` too), and/or print a clear error telling the operator to install `python3-venv`. (Primary fix is the playbook; this is a defensive improvement.)
- Integration points: local + VM setup.

##### ansible/templates/yvy-nginx.conf.j2
- What changes: inject `proxy_set_header X-API-Key "{{ api_key }}";` in the `/api/` location block (the playbook already passes `api_key` to the template but the template never references it — this closes the auth-bypass at the edge). Mirror in `infra/nginx-yvy-prod.conf` if it's still used.
- Error paths: empty `api_key` → skip the header + log a warning (degrade to current behavior).

##### .github/workflows/ci.yml
- What changes: (a) add `scripts/check_prodes_update.sh`, `scripts/deter_daily.sh`, `scripts/setup-python-env.sh` to the `sh -n`/`bash -n` and shellcheck lists (`:68-87`); (b) fix the false-SKIP masking: replace `[ -f "$f" ] && sh -n "$f" || echo "SKIP …"` with a form that fails on real syntax errors, e.g. `if [ -f "$f" ]; then sh -n "$f" || exit 1; else echo "skip $f"; fi`.
- Error paths: a syntax error now fails CI instead of printing "SKIP".

##### .gitignore
- What changes: replace the single pinned PRODES dir (`:194`) with `backend-lua/data/prodes_*/` and add `backend-lua/data/.prodes_version`.

##### ansible/templates/yvy-deter-daily.timer.j2 + yvy-deter-daily.service.j2 (new)
- What changes: systemd timer (e.g. daily `04:30`, staggered from the 03:10 prodes check) + oneshot service running `scripts/deter_daily.sh` as the yvy user; enabled in the playbook.
- Integration points: matches the existing `yvy-prodes-check.*` pattern.

#### Edge cases
- Shellcheck on the new scripts may flag `sudo` removal leftovers / unquoted vars — fix or `# shellcheck disable` with justification.
- The `sh -n` loop change must not break the "missing file is OK" case for optional scripts.

#### Verification
- Run: `bash -n` on every script in `scripts/`; `ansible-playbook --syntax-check -i /tmp/ci-inventory.ini ansible/playbook.yml`.
- Run: touch a fake `backend-lua/data/prodes_2025_x/` dir + `.prodes_version` → `git status` clean (ignored).
- Done: deploy + CI + edge auth all fixed.

---

### Inc 7 — db.lua hardening (M) — **DONE (2026-08-07; days_ago_iso replaced 11 inline sites; LIMIT bounds on get_deter_alerts(10000)/get_ams_risk(5000); 3 view_date indexes; ORDER BY rowid on both identical deforestation bbox queries; get_ams_risk_batch added (bounded ~2° buckets, per-fire fallback); ams.lua routes pass explicit limits 5000/20000)**

**Depends on:** 1
**Unblocks:** 9
**Done criteria:** `get_ams_risk`/`get_deter_alerts` bounded; `view_date` indexed; vegetation batch deterministic; no repeated inline date math; a batch AMS lookup exists for Inc 9.

#### Files to touch

##### backend-lua/app/db.lua
- What changes: (a) add `LIMIT` to `get_ams_risk` (`~:1893-1921`, e.g. 5000) and `get_deter_alerts` (`~:1735-1766`, e.g. 10000) with an explicit parameter — audit all callers and have each pass an explicit limit (no silent truncation for non-route callers); sanity-check the AMS cap against realistic per-day feature counts (note: after Inc 4's discovery the live service exposes 4 fire layers/day across `ams1h`+`ams3`, but `get_ams_risk` serves only the `fire-spreading-risk` polygon rows, so the cap is validated against polygon-layer counts, not point rows); (b) add idempotent `CREATE INDEX IF NOT EXISTS idx_*_view_date ON …(view_date)` for `deter_car_alerts`, `deter_alerts`, `ams_risk` in `init_db()`; (c) add `ORDER BY rowid` to the vegetation batch (`~:1010-1012`, called with 200000 at `:1121`); (d) add `_M.days_ago_iso(days)` and replace the 11 inline `os.date("!%Y-%m-%d", os.time()-days*86400)` copies (`:574,830,874,905,1611,1648,1682,1737,1778,1836,1867,1895`); (e) add `get_ams_risk_batch(fires)` — bounded-batch strategy: bucket fires so each spatial query has a bounded span (e.g. ~2° buckets), bbox-pre-filter candidates in SQL, point-in-polygon only on bbox hits, and a fallback to per-fire queries if a bucket's candidate count exceeds a threshold; returns `id → risk`; (f) document the `get_deter_stats` source split (`:1677-1679`: polygons 90d vs alerts full history) in a code comment; contract unchanged.
- Function(s): `_M.days_ago_iso(days)`, `_M.get_ams_risk_batch(fires)`, updated `get_ams_risk`/`get_deter_alerts` signatures.
- Data shapes: `get_ams_risk_batch({[{id, lat, lon}]}) → {id={risk_level, view_date}}`.
- Integration points: `init_db()` (indexes), `fires.lua` (Inc 9 uses the batch fn), all routes using the date cutoff.
- Error paths: empty fires → `{}`; no candidates → all `nil`.

#### Edge cases
- `days_ago_iso` must preserve the UTC (`!`) semantics used everywhere.
- Adding a LIMIT to `get_deter_alerts` changes its contract — the route already passes a page limit; keep the route's effective limit as the default.
- Index creation on large tables runs once (idempotent) — acceptable one-time cost in `init_db`.

#### Verification
- Run: `make test-lua`.
- Run: `sqlite3 backend-lua/data/yvy.db "EXPLAIN QUERY PLAN SELECT * FROM deter_alerts WHERE view_date >= '2026-01-01'"` shows the new index.
- Done: bounded + indexed + deterministic.

---

### Inc 8 — tools: enrich_fire_deter + deter_protected_alerts (M) — **DONE (2026-08-07; TI overlap=0 — no polygon×polygon intersection in geo.lua, accepted)**

**Depends on:** none
**Unblocks:** 10, 12
**Done criteria:** protected-area fires stay classified as crime (territory complete); a real DETER alert is not masked by a newer FIRMS line; `area_ha` reflects the UC overlap; a failed run leaves a detectable stale marker.

#### Files to touch

##### backend-lua/tools/enrich_fire_deter.lua
- What changes: (a) extend the territory built at `:82-91` to include indigenous-land and conservation-unit geometries (reuse the same lookups the classify path uses — see `fire_classify.lua:144`), so the crime path can fire; (b) `build_deter` (`:40-41`) iterates ALL alerts for the fire, choosing the best DETER by `view_date` instead of only `alerts[1]` (a newer Pass-2 `FIRMS` line must not mask a real DETER alert).
- Function(s): `build_deter(fire, alerts)` → best DETER row across all alerts.
- Data shapes: `alerts` now iterated fully; territory includes `{car, indigenous, conservation}`.
- Error paths: TI/UC lookup failure → log + keep current behavior (don't crash the tool); no DETER alert → `nil` (unchanged).

##### backend-lua/tools/deter_protected_alerts.lua
- What changes: (a) `area_ha` from the UC-overlap area (`areauckm`, or compute the overlap) instead of whole-polygon `area_km2` (`:139`); (b) write a `last_run` sentinel key at start (TTL ~36h) and clear/refresh it on success; the sentinel is operator-inspectable via Redis and the `yvy-prodes-check`/`deter_daily` timers (Inc 6) can warn when a stale marker is present; (c) store the full `classes` list in the alert payload AND set `classname` to the max-severity class (paired with the Inc 10 tier fix).
- Function(s): `area_ha = overlap_km2 * 100`; `write_last_run()/clear_last_run()`.
- Data shapes: alert rows carry `classes` (array) + `classname` (max severity).
- Error paths: no overlap → `area_ha = 0` (no fabricated crit alerts).

#### Edge cases
- A UC whose polygon overlaps multiple fires — each fire uses its own overlap area.
- Protected-area crime downgrade (the current bug) — the re-classification test must include a fire inside a TI/UC and assert `crime`.
- `last_run` sentinel absent → downstream (any stale check) warns.

#### Verification
- Run: `make test-lua`.
- Run: both tools on a fixture DB with a fire inside a conservation unit → alert `classname` is the severe class and `area_ha` ≈ overlap, not whole polygon.
- Done: no downgrade, no masking, correct areas, stale-run detectable.

---

### Inc 9 — routes fires+car + frontend consumers (M) — **DONE (2026-08-07; source whitelist + canonical ams cache key; get_ams_risk_batch (ids synthesized — find_fires has no id); CAR 200+reason not_found/car_unavailable; decode-once + bbox-prefilter; car_rtree + is_loaded TTL; Home.js esc() + reason branch; frontend build green; new test_fires_routes.lua)**

**Depends on:** 7
**Unblocks:** 12
**Done criteria:** `?source=ams` → 400 (whitelist); `?ams=true` → 200 with AMS context from one batch query; unknown CAR receipt returns 200 + `found:false` and the frontend shows `propertyNotFound`; popup fields are escaped; `/api/fires?vegetation=true` has no dead fallback.

#### Files to touch

##### backend-lua/app/routes/fires.lua
- What changes: (a) validate/whitelist `source` (only `""`, `firms`, `bdqueimadas`; anything else → 400) and canonicalize `ams` with an explicit boolean parser (`"true"`/`"1"` → 1, `"false"`/`"0"`/absent → nil) used identically for the query AND the cache key — never `tonumber` (the frontend always sends `?ams=true`; `tonumber("true")` is nil, which would silently disable AMS or re-create a collision) (`:45,55-56,71-76`); (b) replace the per-fire `get_ams_risk_at` loop (`:88-91`) with `get_ams_risk_batch` (Inc 7); (c) range-clamp bbox (lat ∈ [-90,90], lon ∈ [-180,180]); (d) remove the dead `or {status="unknown"}` fallback (`:84`).
- Function(s): `valid_source(v)`, updated cache-key builder.
- Data shapes: cache key now embeds canonicalized params only.
- Error paths: invalid `source` → 400 `{error}`; bbox out of range → clamp (not reject).

##### backend-lua/app/routes/car.lua
- What changes: (a) unknown receipt → `200 {cod_imovel, found:false, reason:...}` — distinguishing the two distinct not-found cases (review MUST-FIX): `reason:"not_found"` when the receipt is genuinely absent from CAR vs `reason:"car_unavailable", note:"CAR unavailable"` when CAR data isn't ingested yet (preserves today's `:66` note semantics); removes the 404 paths at `:72` and `:176`; (b) guard `cjson.decode(cached)` with pcall (`:57`) → on failure, treat as cache miss; (c) decode the alert geometry ONCE per alert and reuse across points (stop re-decoding per candidate via `car_lookup.point_in_geojson`); (d) replace the O(points×classes) loop (`:106`) with a bbox-prefiltered pass; (e) remove the dead `inside` counter (`:95`).
- Function(s): `find_alert_for_receipt(cod, fires)`.
- Data shapes: response contract `{found:boolean, ...}`; 200 always for a valid request.

##### backend-lua/app/lookups/car_lookup.lua
- What changes: `get_by_cod_imovel` (`:117-140`) queries `car_rtree` for bbox candidates instead of walking every coordinate; `is_loaded()` (`:147-149`) memoizes with a short TTL (60s) instead of `COUNT(*)` per request.
- Error paths: rtree missing → fall back to the current walk (log once).

##### frontend/src/components/Home.js
- What changes: (a) add a tiny `esc(s)` helper and apply it to the three unescaped `bindPopup` templates: AMS (`:1118`, `risk_level`/`view_date`), indigenous (`:1088`, `name`/`state_abbr`/`municipality`), conservation (`:1099`, `name`/`category`/`state_abbr`); (b) with the 200 contract, branch on `prodesResult.reason`: `not_found` → `home.propertyNotFound`; `car_unavailable` → a distinct "CAR data not loaded" message (new i18n key or reuse an existing 'data unavailable' string) — verify and remove any leftover `setProdesError(String(...))` path that would show raw text.
- Data shapes: `esc` = replace `& < > " '`.
- Error paths: none.

#### Edge cases
- A cached corrupt car payload must degrade to a fresh query, not 500.
- `?source=firms&ams=true` and `?source=bdqueimadas&ams=true` must remain distinct cache entries.
- The AMS batch returns `nil` risk for a fire with no overlay — same as today.
- Popup values containing quotes/HTML from the WFS feed are rendered inert.

#### Verification
- Run: `make test-lua` (new tests: cache-key distinctness, car 200+found:false, decode-guard).
- Run: perf spot-check — `?ams=true` issues one batch query (verify via SQL log / `EXPLAIN`), not one per fire; with `MAX_RESULTS`-scale data it stays single-digit SQL round-trips (per-fire fallback only when a bucket exceeds the candidate threshold).
- Run: `curl -s "http://localhost:5001/api/fires?source=ams" > a.json; curl -s "http://localhost:5001/api/fires?ams=true" > b.json` → `a.json` is a 400 (source validation); `b.json` is a 200. Cache distinctness: keys `fires:firms:ams:1` vs `fires:bdqueimadas:ams:1` are distinct and no bare `…:ams` key exists.
- Run: `cd frontend && CI=true DISABLE_ESLINT_PLUGIN=true npm run build`.
- Done: no collision, no N+1, contract fixed, XSS closed, build green.

---

### Inc 10 — routes deter/ams/tiles/alerts (M) — **DONE (2026-08-07; shared utils.parse_bbox; parse_limit lower bound 400; tiles CORS allowlist + rl.enforce (default allowance — no per-route tuning in middleware, noted); open_prodes_db→resolve_generic_db dedup + shared serve_miss; alerts ticks by max-severity classes with classname fallback)**

**Depends on:** 8
**Unblocks:** 12
**Done criteria:** `?limit=-1` on deter routes → 400; one `parse_bbox` implementation; tiles honor the CORS allowlist and are rate-limited; tiered tick reflects the max-severity class.

#### Files to touch

##### backend-lua/app/routes/deter.lua
- What changes: clamp `limit` lower bound (`:43-44`): `limit < 1` → 400 (or default), `limit > 5000` → cap (existing); move `parse_bbox` (`:14-24`) to a shared helper.
- Function(s): `parse_limit(v)`.
- Error paths: `limit=-1` → 400 `{error:"invalid limit"}`.

##### backend-lua/app/routes/ams.lua
- What changes: replace its `parse_bbox` copy (`:12-22`) with the shared helper (no behavior change; `geom.coordinates` guard at `:65-69` already exists and stays).

##### backend-lua/app/utils.lua
- What changes: add shared `parse_bbox` used by deter + ams — pinned here: `utils.lua` is the existing shared module already required by routes (not a new routes/helpers.lua).
- Function(s): `_M.parse_bbox(args)`.

##### backend-lua/app/routes/tiles.lua
- What changes: (a) replace the hardcoded `Access-Control-Allow-Origin: *` (`:154`) with the same allowlist logic as `server.lua:232-235`; (b) add `rl.enforce` to tile routes (registered at `main.lua:192-201`); tiles stay public (no auth); (c) dedup `open_prodes_db`/`resolve_generic_db` (`:127` vs `:253`) and the tile-miss handling duplicated in `get_tile`/`get_tile_car`/`serve_layer_tile` (`:274`).
- Error paths: non-allowlisted origin → no ACAO header (browser blocks); rate-limit exceeded → 429.

##### backend-lua/app/routes/alerts.lua
- What changes: the deter_protected tier logic (`:519-526`) iterates the full `classes` list and ticks by max severity, instead of only `classname`.
- Data shapes: alert payload `classes` (from Inc 8).
- Error paths: no `classes` (legacy rows) → fall back to `classname`.

#### Edge cases
- A request without an `Origin` header (curl) — no ACAO header needed.
- Tile hot-path: `rl.enforce` must not throttle the map during pan/zoom bursts (tiles are far more numerous than fires requests) — use a higher burst allowance than the fires route and verify with a real panned map load.
- Legacy alerts without `classes` — fallback keeps them ticked by `classname`.

#### Verification
- Run: `make test-lua` (limit 400, tier tests).
- Run: `curl -s -o /dev/null -w '%{http_code}' -H 'Origin: http://evil.example' "http://localhost:5001/api/tiles/..."` → no `Access-Control-Allow-Origin` in headers; `curl ... "?limit=-1"` → 400.
- Done: bounded, CORS-correct, rate-limited, correctly ticked.

---

### Inc 11 — Python batch: precompute + cross_deter_car + requirements (M) — **DONE (2026-08-07; Series column-presence fix; EPSG:5880/32723 equal-area reproject — area smoke test 12193ha≈expected; RTree pagination returns all 12345 rows; STRtree.query(geom) shapely-2.x guard; pillow>=10,<12 pinned)**

**Depends on:** 4
**Unblocks:** none
**Done criteria:** `precompute_deforestation_stats.py` runs on municipality layers with a `uf` column; `cross_deter_car.py` emits hectares-scale `area_ha` and doesn't truncate candidate lists; `pip install -r requirements.txt` installs everything the scripts import.

#### Files to touch

##### scripts/precompute_deforestation_stats.py
- What changes: fix `:52` — replace `gdf.get("uf") or gdf.get("sigla_uf") or ...` with column-presence checks (`if "uf" in gdf.columns: ... elif "sigla_uf" in ...`), never `or` on a Series.
- Error paths: no UF column at all → `None` (municipality rows skipped from UF stats, no crash).

##### scripts/cross_deter_car.py
- What changes: (a) reproject both GeoDataFrames to an equal-area CRS (e.g. `EPSG:5880` SIRGAS 2000 / Brazil Polyconic, or EPSG:32723) BEFORE `inter.area` (`:202`) so `area_ha` is real hectares; (b) RTree candidate query (`:36,92-97`): paginate over the RTree results (loop with start/end bounds) or remove the cap so no bbox silently truncates — a bigger constant is not a fix; (c) `STRtree.query(geom)` (`:264,266`) — pass a geometry (shapely 2.x), not `geom.bounds` tuple.
- Function(s): `to_equal_area(gdf)`.
- Data shapes: `area_ha` in hectares (~same magnitude as DETER `area_km2*100`).
- Error paths: reprojection failure → abort with message.

##### scripts/requirements.txt
- What changes: add `pillow` (pinned, e.g. `pillow>=10,<12`).
- Integration points: `pip install -r scripts/requirements.txt`.

#### Edge cases
- `EPSG:5880` availability in the pinned geopandas/proj — verify; fall back to `EPSG:32723` (UTM 23S) for the Amazon region if needed.
- Boundary geometries that fail reprojection — `to_crs` with `errors` handling.

#### Verification
- Run: `python3 -m py_compile scripts/precompute_deforestation_stats.py scripts/cross_deter_car.py`.
- Run: `cross_deter_car.py` on a small sample → `area_ha` within an order of magnitude of the DETER polygon's `area_km2*100`.
- Run: `pip install -r scripts/requirements.txt` in a clean venv → succeeds.
- Done: no Series ValueError, real hectares, no truncation.

---

### Inc 12 — Tests: Redis hygiene + review coverage (S) — **DONE (2026-08-07; after_each cleans alerts:deter_protected on success+failure; test_car_prodes teardown deletes car:prodes:*; vacuous-pass fixed; tiles/car fixture timestamps de-date-bombed; get_ams_risk_batch test added; .agents/common-mistakes/ created with 6 lessons; Redis hygiene verified — no leftover keys after full run. Remaining `"2026-` literals in test_utils (fixed-input parser tests) and test_fire_classify (is_moratorium is month-only → year-independent) are stable-by-construction, NOT date-bombs)**

**Depends on:** 2, 3, 8, 9, 10
**Unblocks:** none
**Done criteria:** the suite passes with a live Redis and leaves zero keys behind; assertions fail loudly (no vacuous passes); review lessons are recorded in `.agents/common-mistakes/`.

#### Files to touch

##### backend-lua/tests/test_alerts.lua
- What changes: (a) move the criticality assertion OUTSIDE the guard (`:93-99`) — first assert the entry exists, then assert its tick; (b) delete sentinel keys in a teardown that runs on success AND failure (e.g. `after_each`/`finally`), so a failed test can't leak a 24h key; (c) document the live-Redis requirement in the file header.
- Integration points: `make test-lua`.

##### backend-lua/tests/test_car_prodes.lua
- What changes: teardown (`:52-60`) deletes the `car:prodes:*` keys the test writes (use unique receipt codes so teardown targets only this test's keys).
- Integration points: `make test-lua`.

##### backend-lua/tests/test_fire_vegetation.lua, test_bdq.lua, + fires/car/deter additions
- What changes: new coverage from earlier increments lands with the behavior changes (vegetation labels in Inc 1, BDQ mapping in Inc 3, cache-key distinctness + car 200 contract in Inc 9, limit 400 + tier in Inc 10) — this increment audits that each fix has a test and backfills any missing one. `test_bdq` must also cover the Inc 3 discovery heuristic (fixture GetCapabilities listing `active-fire-today` + `fire-spreading-risk` + `dummy` layers → only the fire POINT layers are selected).
- Integration points: `make test-lua`.

##### .agents/common-mistakes/ (new)
- What changes: record the review lessons as a shared reference: (1) test fixtures must be clock-relative, never absolute dates; (2) tests must never write production Redis namespaces — isolate + teardown; (3) batch-write pipelines need the same batching pattern as siblings (N+1 is a code smell); (4) ingest writers must be pinned to the LIVE upstream schema (DescribeFeatureType/GetCapabilities), not the spec; (5) destructive update paths need marker-after-success + auto-restore; (6) `or` on a pandas Series raises — use column-presence checks.
- Integration points: referenced by future plans.

#### Edge cases
- `test_alerts` without a live Redis still fails with a clear message (documented), not a silent skip.
- Teardown must not delete keys belonging to another concurrent run (use per-run receipt codes).

#### Verification
- Run: `make test-lua` twice in a row → passes and `redis-cli --scan | grep -E 'car:prodes|alerts:deter_protected'` returns nothing after the run.
- Done: clean, loud, documented test suite + shared lessons.

---

## Cross-cutting verification

After all increments:
1. `make test-lua` — full suite green (with live Redis, as CI provides).
2. `cd frontend && CI=true DISABLE_ESLINT_PLUGIN=true npm run build` — green.
3. `python3 -m py_compile scripts/*.py` and `bash -n scripts/*.sh` — green.
4. `ansible-playbook --syntax-check -i <inventory> ansible/playbook.yml` — green.
5. Live smoke (local, post-`make run`): `curl -s "http://localhost:5001/api/fires?vegetation=true"` → 200; `curl -s "http://localhost:5001/api/deter/car-alert-stats?days=7"` → real data; `curl -s "http://localhost:5001/api/car/prodes?cod_imovel=BR-XX-0000000"` → `{found:false}` (200); BdQueimadas + DETER + AMS tools inserted live rows (Inc 3/4).
6. `git diff --stat` — only expected files.

## Standards / common-mistakes referenced

- No `.agents/standards/` or `.agents/common-mistakes/` exists in the repo — Inc 12 creates `.agents/common-mistakes/` from the review lessons (skill requirement: feed lessons back after every review).
- `AGENTS.md` — JSONB rules (always `json(data)` to read, `jsonb()` to write; never `json.decode()` the raw BLOB) apply to Inc 1/3/8/9 edits touching JSONB columns.
- `AGENTS.md` — "Tests use lsqlite3 (file-based SQLite) — no running DB server needed" is **outdated**: `test_alerts.lua` requires live Redis and CI provides it; Inc 12 documents this.

## Open questions (CONSIDER from review)

1. **`name_hash` 20-bit** in `deter_protected_alerts.lua` → ~300 expected collisions at scale; widening to 32-bit is a dedup-semantics change — deferred (would invalidate existing alert IDs).
2. **`get_deter_stats` source split** (polygons 90d vs alerts full history) — documented in Inc 7, not redesigned; revisit if the dashboard's DETER card ever needs reconciled totals.
3. **`scripts/common.py`** module extraction (4× `deter_db_path`, 4× WFS paging, 4× `tile_to_bbox`, 13× connect/checkpoint) — deferred refactor; the file doesn't exist yet.
4. **Frontend component extraction** (`AmsRiskLayer`, `ProdesCheck`, `LayerToggle`, `DataTileLayer`) and hardcoded BR bbox dedup — partially owned by `.plans/visual-declutter/`; the bbox dedup can ride along with Inc 9 if convenient.
5. **`bulk_upsert_fires_keep_first`** is a byte-for-byte clone of `bulk_upsert_fires` except `DO NOTHING` — intentional semantics (keep-first vs upsert); keep, add a comment.
6. **`?ams=true` N+1 fix needs `get_ams_risk_batch`** — the batch function's union-bbox query may return more rows than the per-point queries; validate candidate filtering in Inc 9 verification.
7. **Tests without local Redis** — full mocking of `app/redis.lua` is deferred; CI provides Redis, and Inc 12 documents the requirement.
8. **AMS cache `max-age=300` vs PRODES `60`** and mixed-case env `TerraClass_TILES_DB` — tuning/naming drift, deferred.
9. **DETER `area_km2` backfill** for rows already ingested with NULL (Inc 4 re-run fixes going forward; a one-time `UPDATE` for existing rows can be added to Inc 4 verification if needed).
10. **Inc 10 could split** (deter/ams/tiles are independent of the alerts tier piece) — current route-layer grouping kept for review coherence; split if the alerts piece blocks the others.
11. **AMS `risk_level` is constant per live layer** (`fire-spreading-risk` → `high`, `active-fire-today` → `high`): presence-based by design — DescribeFeatureType verified 2026-08-07 that neither layer carries a risk attribute, so there is no authoritative value to ingest; if real risk tiers appear upstream, `derive_risk` in `download_ams_wfs.py` is the single place to extend.
12. **`get_prodes_status` inline aggregation** (the PRODES status endpoint's ~100-line aggregation was flagged SHOULD-FIX by the review) — not in plan scope; extract to a helper when that endpoint next changes.

## Out of scope

- **Frontend visual declutter** (Home defaults, TileLayer conditional unmounting, legend, fire grid, dashboard cards) — `.plans/visual-declutter/plan.md`.
- **Full Redis test mocking** — CI provides `redis:7`; only hygiene is fixed.
- **`get_deter_stats` redesign**, **`scripts/common.py` extraction**, **`name_hash` widening**, **frontend component extraction** — Open questions.
- **AMS cache tuning** and **env-var naming normalization** — Open questions.
- **New datasets or features** — this plan only repairs the TerraBrasilis integration.

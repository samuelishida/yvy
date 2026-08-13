# CAR Risk Expansion — Fixup Plan (review findings)

> STATUS: implemented — all 4 increments done (300 Lua tests pass, frontend build passes, Python scripts parse + deterministic run verified).

## Context

The `car-risk-expansion` implementation (area efetiva precompute, embargo
ingest, enriched score + multi-page PDF, frontend) was reviewed via
`review-large-pr`. The review found 5 MUST-FIX, 5 SHOULD-FIX, and several
CONSIDER items. This plan fixes them. The feature is otherwise verified
(291 Lua tests pass, frontend build passes, 3 Python scripts parse).

The fixes fall into three clusters:
1. **Runtime-loop safety** — `GET /api/risk/report` blocks the single-threaded
   copas loop with a synchronous `os.execute`; it also uses bare `python3`
   (not the venv) and leaks temp files / allows header injection.
2. **Version-marker propagation** — `AREA_EFETIVA_VERSION` is written to a
   marker file but never reaches the backend, so cached scores never
   invalidate on area-efetiva recompute.
3. **Deployment wiring** — the area-efetiva systemd units exist as templates
   but are never registered in the playbook (the embargo units already are,
   playbook.yml:467-483); `matplotlib` is not a declared dependency; the
   `--window`/`--today` determinism bug; the `skipped` counter is dead.

**Constraints inherited from the codebase** (verified in exploration):
- Backend is **Lua 5.1, copas single-threaded**. `os.execute` blocks the
  *entire process* — copas cannot yield around it. Heavy work must run in a
  **detached subprocess** (`nohup ... &`), the established pattern in
  `spawn_batch`, `fires.lua`, `news.lua`.
- Python batch deps live in `$PROJECT_DIR/.venv/bin/python3` (see
  `check_prodes_update.sh`, `deter_daily.sh`, `yvy-backend.service.j2`).
- Version markers are **files** (`data/.prodes_version`,
  `data/area_efetiva/area_efetiva.version`); the backend reads env via
  `env.load_dotenv` + `env.get`. `risk_precompute.current_version_key()`
  currently reads env only.
- `car_protected.get(cod)` already opens a **writable** handle to car.db in
  the runtime loop (`car.lua:388`) — this is **pre-existing**, not a new
  regression. The fixup does not need to change it (downgraded from MUST-FIX).
- Tests: busted + `helpers.lua` (`days_ago`, `fake_ctx`), temp DB per file,
  Redis stub with teardown. Check command: `make test-lua`.

## Architectural decisions

- Decision: **`GET /api/risk/report` becomes async spawn + poll.** The renderer
  runs detached (`nohup ... &`); a new `GET /api/risk/report/status?id=<id>`
  returns `{status: ready|running|failed, url}`; the frontend polls then
  downloads. Rationale: honors the plan's explicit "não bloqueia o loop copas"
  constraint; `os.execute` cannot be yielded around in copas. Alternatives
  rejected: accept the bounded synchronous block (violates the stated
  constraint, DoS vector), pre-render cache with `window.open` (adds a cache
  layer and staleness concerns for a compliance artifact).
- Decision: **`risk_precompute.current_version_key()` reads the
  `area_efetiva.version` marker file directly** (fallback to env). Rationale:
  decouples from systemd env propagation (which would require a service restart
  per recompute); the marker file is the source of truth written after success
  (common-mistake #5). Alternatives rejected: propagate via
  `yvy-backend.service.j2` `Environment=` (stale until restart).
- Decision: **`get_report` uses the venv python** (`$PROJECT_DIR/.venv/bin/python3`,
  fallback to `python3`), matching `check_prodes_update.sh`/`deter_daily.sh`.
  Rationale: reportlab/matplotlib are installed only in the venv.
- Decision: **temp files keyed by a unique report id** (not the raw
  `property_id`), and the `Content-Disposition` filename sanitized. Rationale:
  fixes path/header injection and concurrent-request collision.
- Decision: **`matplotlib` added to `scripts/requirements.txt`** (pinned to a
  range). Rationale: the P5 static map needs it; currently it silently degrades
  on prod.
- Decision: **`--window` uses the `--today` anchor** in
  `compute_area_efetiva.py`. Rationale: restores the "deterministic tests"
  claim; `--today` should anchor both the marker and the window.
- Decision: **playbook registers the area-efetiva and embargo systemd units**
  (service + timer + enable), mirroring the risk-monitor block. Rationale: the
  templates exist but never deploy.

## Assumptions and answers from code

- Decision: `car_protected.get` writable handle in runtime is pre-existing
  (`car.lua:388`) — not a new regression; out of scope for this fixup.
  Source: code @ `backend-lua/app/routes/car.lua:388`.
- Decision: the venv python path is `$PROJECT_DIR/.venv/bin/python3`.
  Source: code @ `scripts/data/check_prodes_update.sh:125`,
  `scripts/data/deter_daily.sh:15`, `ansible/templates/yvy-backend.service.j2:13`.
- Decision: `env.get` reads process env + dotenv; no marker-file reader exists
  in lookups today. Source: code @ `backend-lua/app/env.lua`.
- Decision: the playbook registers systemd units via `ansible.builtin.template`
  + `ansible.builtin.systemd` (see risk-monitor block). Source: code @
  `ansible/playbook.yml:443-461`.
- Decision: `new_batch_id()` pattern (`b<time>_<rand>`) is the established id
  generator. Source: code @ `backend-lua/app/routes/risk.lua:36-40`.
- Decision: the frontend consumes the report via a direct `<a href>` to
  `/api/risk/report?id=...` (window.open). Source: code @
  `frontend/src/components/RiskIntelligence/RiskIntelligence.js:178`.

## Risks accepted

- **Async report adds a poll round-trip**: the frontend must poll
  `/api/risk/report/status` before downloading. Accepted; the render is
  bounded (~1s single property) so the poll is short.
- **Marker-file read adds a tiny I/O per `current_version_key()` call**: the
  file is small and read rarely (only on score get/upsert). Accepted; could be
  memoized with a short TTL if it becomes hot.
- **`matplotlib` adds a heavy dependency to the venv**: accepted; it's already
  used by the renderer and the P5 map is a core feature of the laudo.
- **Inc 1 is a breaking API change** (`/api/risk/report` goes from synchronous
  PDF to async 202): the frontend and backend ship in the same increment, so
  rollback requires reverting both together (contained). No other consumers of
  `/api/risk/report` exist (verified: only the RiskIntelligence page links to
  it).

## Increment DAG

- Inc 1 — Report async + venv + injection fix (L) — depends: none — unblocks: none
- Inc 2 — Version-marker propagation (S) — depends: none — unblocks: none
- Inc 3 — Playbook systemd registration + matplotlib dep (S) — depends: none — unblocks: none
- Inc 4 — Python determinism + dead-code fixes (S) — depends: none — unblocks: none

Inc 1–4 are independent (no shared files) and can run in any order or in
parallel. They are grouped by cluster for reviewability.

## Increments

### Inc 1 — Report async + venv + injection fix (L)

**Depends on:** none
**Unblocks:** none
**Status: done** (299 Lua tests pass, frontend build passes, renderer parses).
**Done criteria:** `GET /api/risk/report` spawns a detached renderer and
returns immediately; a new status endpoint reports ready/running/failed; the
frontend polls then downloads; the renderer uses the venv python; temp files
and the Content-Disposition filename are injection-safe.

#### Files to touch

##### backend-lua/app/routes/risk.lua (edit)
- What changes: `get_report` becomes async spawn + poll; add
  `get_report_status` and `get_report_download`; use venv python; unique temp
  files; sanitized filename; strict report_id validation.
- Function(s):
  - `_M.get_report(ctx)` — validate `id`; look up the score and return `404`
    when absent (as today); otherwise spawn a detached renderer and return
    `202 {report_id, status:"running"}`. No cached/ready short-circuit (the
    status+download endpoints cover the ready case; a single contract keeps the
    frontend simple).
  - `_M.get_report_status(ctx)` — read `risk:report:<id>` from Redis AND check
    the sidecar marker file; return `{status: ready|running|failed, url}`.
  - `_M.get_report_download(ctx)` — validate `report_id` against `^r%d+_%w+$`,
    serve the PDF from `/tmp/yvy_risk_report_<report_id>.pdf` with a sanitized
    `Content-Disposition`; 404 on missing/invalid.
  - `local function spawn_report(property_id, context_json)` — writes a unique
    temp context, spawns `nohup <venv-python> render_risk_report.py ... &`,
    records `risk:report:<id>` = `running` in Redis (TTL 300s), redirects
    renderer stderr to `/tmp/yvy_risk_report_<report_id>.log`.
  - `local function report_id(property_id)` — `r<time>_<rand>` (mirrors
    `new_batch_id`).
- **Completion signal (MUST-FIX)**: the detached renderer cannot write Redis
  (no client declared). Instead, the renderer writes a **sidecar marker file**
  `/tmp/yvy_risk_report_<report_id>.done` on success (or `.fail` on error).
  `get_report_status` checks the marker file in addition to Redis: if
  `risk:report:<id>` is `running` but the `.done`/`.fail` marker exists, flip
  the Redis key to `ready`/`failed` and return accordingly. This keeps the
  renderer dependency-free (no Redis client needed).

  **This requires modifying `render_risk_report.py`** (see its file entry
  below): today `main()` ignores `render_report`'s return value and writes no
  marker. The renderer must `try/except` around `render_report`, write
  `.done` on success and `.fail` on any exception (so a failed render is
  observable, not a hang until the Redis TTL expires), and exit non-zero on
  failure.
- Data shapes: `GET /api/risk/report?id=<property_id>` → `202 {report_id,
  status:"running"}` (always); `GET /api/risk/report/status?id=<report_id>` →
  `{status, url}` where `url = /api/risk/report/download?id=<report_id>`;
  `GET /api/risk/report/download?id=<report_id>` → PDF bytes.
- Integration points: `main.lua` registers the status + download routes; Redis
  `risk:report:<id>` (TTL 300s); the renderer writes the PDF + sidecar marker
  to `/tmp/yvy_risk_report_<report_id>.pdf` / `.done` / `.fail`.
- Error paths: renderer fails → `.fail` marker → status `failed` with message;
  PDF missing → status `failed`; `id` missing → 400; unknown/invalid report_id
  → 404.

##### backend-lua/main.lua (edit)
- What changes: register `GET /api/risk/report/status` and
  `GET /api/risk/report/download`.
- Function(s): `server.route("GET", "/api/risk/report/status", risk.get_report_status)`;
  `server.route("GET", "/api/risk/report/download", risk.get_report_download)`.
- Integration points: mirrors the existing `/api/risk/report` registration.

##### frontend/src/components/RiskIntelligence/RiskIntelligence.js (edit)
- What changes: the PDF link becomes a button that GETs the report (202), polls
  status, then downloads the ready PDF.
- Function(s): `ResultsTable` — replace the `<a href>` with a `downloadPdf`
  handler that calls `/api/risk/report?id=...` (gets `report_id`), polls
  `/api/risk/report/status?id=...` until `ready`, then `window.open(url)`.
- Data shapes: consumes `{report_id, status}` then `{status, url}`.
- Integration points: i18n `t('risk.*')`; direct fetch (no `cachedFetch`).
- Error paths: poll timeout → show error; status `failed` → show error.

##### frontend/src/i18n.js (edit)
- What changes: add `risk.reportGenerating`, `risk.reportReady`,
  `risk.reportFailed` PT/EN strings.
- Integration points: `t('risk.*')`.

##### scripts/data/render_risk_report.py (edit)
- What changes: write the sidecar completion marker; `try/except` around
  `render_report`.
- Function(s): `main()` — after `render_report(context, out_path)` succeeds,
  write `<out_path>.done`; on any exception, write `<out_path>.fail` and
  `sys.exit(1)`. Derive the marker path from the `out.pdf` argument (e.g.
  `Path(sys.argv[2]).with_suffix(".done")` / `".fail"`), so the Lua side
  knows the exact filenames.
- Integration points: `get_report_status` reads the `.done`/`.fail` marker
  alongside Redis.
- Error paths: reportlab ImportError already `sys.exit(1)` (no marker — the
  Lua side treats a missing `.done` after TTL as failed); internal render
  exception → `.fail` marker.

##### backend-lua/tests/test_risk_report.lua (edit)
- What changes: update for the async contract — `get_report` returns 202 with
  `report_id`; `get_report_status` returns running/ready/failed;
  `get_report_download` serves the PDF or 404s.
- **Test seam (SHOULD-FIX)**: inject/mock `spawn_report` so tests assert the
  202 contract and status transitions by setting `risk:report:<id>` and the
  sidecar marker directly in the Redis stub — **without launching a real
  renderer subprocess** (slow, side-effecting, env-dependent).
- Integration points: fake ctx; Redis stub with teardown (common-mistake #2).
- Error paths: missing id → 400; unknown report → 404; invalid report_id → 404.

#### Edge cases
- Concurrent requests for the same property → unique report_id avoids temp-file
  collision (duplicate renders accepted; dedup is a CONSIDER).
- Renderer not installed (reportlab missing) → `.fail` marker → status `failed`
  with message.
- Frontend poll timeout → user sees an error, can retry.
- Renderer stderr → captured to `/tmp/yvy_risk_report_<report_id>.log` for
  observability.

#### Verification
- Run: `make test-lua`
- Tests to add/update: `test_risk_report.lua` (async contract, status
  transitions via mocked spawn, download 200/404, 400/404).
- Renderer check: `python3 -c "import ast; ast.parse(open('scripts/data/render_risk_report.py').read())"`
  and a manual run confirming the `.done`/`.fail` marker is written next to the
  PDF.
- Done: report is async; status + download endpoints work; frontend polls +
  downloads; renderer writes the completion marker; tests pass without spawning
  a real renderer.

### Inc 2 — Version-marker propagation (S)

**Depends on:** none
**Unblocks:** none
**Status: done** (300 Lua tests pass).
**Done criteria:** `risk_precompute.current_version_key()` includes the
`area_efetiva.version` marker file content, so a recompute invalidates cached
scores.

#### Files to touch

##### backend-lua/app/lookups/risk_precompute.lua (edit)
- What changes: `current_version_key()` reads the `area_efetiva.version` marker
  file (fallback to `AREA_EFETIVA_VERSION` env).
- Function(s): `_M.current_version_key()` — add a `read_marker(path)` helper
  that `io.open`s the marker file and returns its trimmed content, else the
  env value, else `""`.
- Data shapes: marker path = `backend-lua/data/area_efetiva/area_efetiva.version`
  — resolved via its **own** `env.first_with_existing_parent` list (sibling of
  the area-efetiva DB), NOT derived from `RISK_DB_PATH`, which points at
  `risk.db` in a different directory.
- Integration points: `compute_area_efetiva.py` writes the marker after success;
  `warm_risk_scores.lua` recomputes stale scores.
- Error paths: marker file absent → `""` (no invalidation, no crash).

#### Edge cases
- Marker file absent on first deploy → `""` (scores computed with no area
  efetiva version; next recompute writes the marker and invalidates).
- Marker file changes → version key changes → `get` returns nil (stale) →
  recompute.

#### Verification
- Run: `make test-lua`
- Tests to add/update: `test_risk_score.lua` (version key changes when the
  marker file content changes).
- Done: version key reflects the marker; cached scores invalidate on recompute.

### Inc 3 — Playbook systemd registration + matplotlib dep (S)

**Depends on:** none
**Unblocks:** none
**Status: done** (playbook YAML valid, area-efetiva units registered, matplotlib declared).
**Done criteria:** the area-efetiva systemd units are registered in the
playbook (embargo already is); `matplotlib` is a declared dependency.

#### Files to touch

##### ansible/playbook.yml (edit)
- What changes: add template + systemd blocks for `yvy-area-efetiva.{service,
  timer}`, mirroring the risk-monitor block. (`yvy-embargo.{service,timer}` is
  already registered at playbook.yml:467-483 — do not duplicate it.)
- Integration points: `ansible.builtin.template` + `ansible.builtin.systemd`
  (state: started, enabled: true).
- Error paths: n/a (idempotent Ansible).

##### scripts/requirements.txt (edit)
- What changes: add `matplotlib` (pinned range, e.g. `matplotlib>=3.7,<4`).
- Integration points: `setup-python-env.sh` installs it into the venv.
- Error paths: n/a.

#### Edge cases
- Playbook re-run is idempotent (systemd units already present → no-op).
- matplotlib install on OCI A1 (ARM) — pin a range that has ARM wheels.

#### Verification
- Run: `ansible-playbook --syntax-check ansible/playbook.yml` (or `make test-lua`
  for the repo check).
- Tests to add/update: none.
- Done: units registered; matplotlib declared.

### Inc 4 — Python determinism + dead-code fixes (S)

**Depends on:** none
**Unblocks:** none
**Status: done** (parse OK; deterministic run anchored to `--today`, `skipped` real).
**Done criteria:** `compute_area_efetiva.py --window` uses the `--today` anchor;
the `skipped` counter is real.

#### Files to touch

##### scripts/data/compute_area_efetiva.py (edit)
- What changes: `load_alerts` takes a `today` param and uses it for the window
  cutoff; `run_compute` passes `today`; the `skipped` counter is incremented
  when a pair is skipped.
- Function(s): `load_alerts(db_path, window_days, today)` — cutoff =
  `(today - timedelta(days=window_days)).isoformat()`; `run_compute(...)` —
  passes `today` to `load_alerts` and increments `skipped` on no-intersection.
- Data shapes: unchanged (window filter now anchored to `--today`).
- Integration points: `main()` passes `today` through.
- Error paths: n/a.

#### Edge cases
- `--today` with `--window` → deterministic window for tests.
- No `--today` → `date.today()` (production behavior unchanged).

#### Verification
- Run: `python3 -c "import ast; ast.parse(open('scripts/data/compute_area_efetiva.py').read())"`
  **and** a real deterministic run: `python3 scripts/data/compute_area_efetiva.py
  --today 2026-08-13 --window 120 --out /tmp/area_efetiva_test.db` asserting
  the window cutoff is anchored to `2026-08-13` (not the real clock).
- Tests to add/update: none (Python script; verified by parse + deterministic
  run).
- Done: window anchored to `--today`; `skipped` counter accurate.

## Cross-cutting verification

- After Inc 1, run a batch CSV, open a report, confirm the frontend polls and
  downloads the PDF (multi-page).
- After Inc 2, recompute area efetiva and confirm cached scores invalidate
  (version key changes).
- After Inc 3, run the playbook and confirm the area-efetiva timer is active
  (embargo already is).
- After Inc 4, run `compute_area_efetiva.py --today <date> --window 120` and
  confirm the window is anchored to `<date>`.

## Standards / common-mistakes referenced

- `.agents/common-mistakes/common-mistakes.md` — applies to: #2 (Redis
  isolation + teardown in the new status tests), #5 (marker-after-success for
  the version file), #6 (pandas column-presence, equal-area CRS).
- `.agents/AGENTS.md` — architecture, deploy via Ansible.

## Open questions (CONSIDER from review)

- **Recency semantics**: `area_efetiva` is all-time; `recent_alerts` is
  windowed. Substituting changes score meaning. Not addressed by this fixup
  (documented in the original plan).
- **`get_report` reads the whole PDF into memory** (`outf:read("*a")`): fine for
  single-property reports; revisit if reports grow.
- **`embargo_lookup.get_at` is bbox-only** (no polygon containment): false
  positives possible, but not used in the score path.
- **`area_efetiva_lookup` loads all rows into memory**: documented design;
  revisit if the DB grows.
- **`scan_supplier_alerts.check_supplier` mutates the caller's `supplier`
  table**: minor; leave as-is.
- **`warm_risk_scores --all` hardcaps at `LIMIT 10000`**: truncates full
  recompute; revisit if needed.
- **Concurrent duplicate renders**: two requests for the same property spawn
  two renders. Unique report_id avoids collision; dedup (reuse an in-flight
  report_id per property) is a possible future optimization.
- **Cached/ready lifetime**: the Redis key has TTL 300s but the `/tmp` PDF
  persists longer. Define whether the PDF is cleaned up after download.
- **Marker/PDF cleanup**: the `.done`/`.fail` sidecar markers also accumulate in
  `/tmp` alongside the PDFs. Include them in any cleanup policy.
- **Redis TTL 300s vs render time**: if a render exceeds 300s, `risk:report:<id>`
  expires and status becomes unknown. Fine for single-property (~1s), but the
  TTL should exceed worst-case render time.
- **Version-key invalidation assumes the marker content changes per recompute**:
  `compute_area_efetiva.py` writes `today.isoformat().replace("-","")` (a
  changing date) as the marker, so it does change per recompute. Confirmed.
- **Soft dependency Inc 1 → Inc 3 (matplotlib)**: if Inc 1 ships before Inc 3,
  the P5 map degrades (renderer handles missing matplotlib gracefully). Note
  the ordering; not a hard dependency.

## Out of scope

- Changing `car_protected.get` to a read-only handle (pre-existing pattern;
  not a new regression).
- Recency semantics for `area_efetiva` (documented open question).
- White-label/client branding on the laudo.
- Webhook durability (backoff, dead-letter).

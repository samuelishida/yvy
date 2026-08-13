# Ingestion Automation (MapBiomas, CAR, Sinaflor, Embargo, Area Efetiva, Aux Layers)

## Context

Yvy ingests several external datasets into dedicated SQLite DBs that the Lua
backend serves read-only. Today most of that ingestion is **manual**: the
generator scripts and `sync-*.sh` wrappers exist and are correct, but nothing
schedules them. The only automated jobs are the PRODES yearly check
(`yvy-prodes-check.timer`), the DETER daily pipeline (`yvy-deter-daily.timer`),
and the risk supplier monitor (`yvy-risk-monitor.timer`).

The problem this solves: keep the served datasets fresh without a human
remembering to run `make sync-*` each week. The intended outcome is a hybrid
automation where light jobs run on the prod VM via systemd timers and the heavy
CAR pipeline runs on the dev machine via cron (5am, so the user is not on the
PC), with a forward-compatible path to move everything to a bigger VM later.

**PRODES is explicitly out of scope** — it is yearly and already automated by
`check_prodes_update.sh` + `yvy-prodes-check.timer`.

### Current state (verified 2026-08-13)

| Source | Generator | Output DB | Guard | Automated? |
|---|---|---|---|---|
| MapBiomas Alerta | `download_mapbiomas_alerta.py` | `mapbiomas_alerta.db` | 7-day mtime | ❌ manual |
| IBAMA Embargo | `download_embargo.py` | `embargo.db` | 7-day mtime | ❌ manual |
| Sinaflor (fogo permitido) | `download_sinaflor_auth.py` | `sinaflor_auth.db` | 7-day mtime + `.sync_version` | ❌ manual |
| Aux layers (UC/TI/municip) | `download_aux_layers.py` | `*.geojson/json` | none | ❌ manual |
| Deforestation stats | `precompute_deforestation_stats.py` | `lookup_data` blobs | none | ❌ manual |
| CAR perimeters | `download_car_wfs.py` → `import_car.lua` → warm → merge | `car.db` (7GB) | none | ❌ manual |
| CAR tiles | `render_car_tiles.py` | `tiles_car.db` | resumable | ❌ manual |
| Area efetiva | `compute_area_efetiva.py` | `area_efetiva.db` | 7-day mtime | ⚠️ timer template exists, **not wired** |

## Architectural decisions

- **Decision: Hybrid split — light jobs on VM timers, heavy jobs on dev cron.**
  Rationale: the prod VM is 1GB RAM + 2GB swap; the CAR pipeline (7GB `car.db`
  + warm jobs) physically cannot run there. MapBiomas Alerta is also moved to
  dev because its national-shapefile load + WKT serialization + per-alert
  spatial resolution against the 7GB `car.db` is a real OOM risk on 1GB RAM
  (review finding). The remaining light jobs (embargo/sinaflor/aux) are
  CSV/JSON-based, fit on the VM, and are designed as lightweight atomic-swap
  jobs. Alternatives rejected: (a) all-on-dev-cron — simplest but ignores the
  user's explicit hybrid preference and the existing VM timer pattern;
  (b) all-on-VM — infeasible for CAR and MapBiomas on 1GB RAM.
- **Decision: VM jobs invoke the Python generator directly with `--out` pointing
  at the prod data dir, NOT the `sync-*.sh` scripts.** Rationale: the sync
  scripts are dev-side (generate locally + scp to a remote `VM_IP`). A job
  running ON the VM writes in place. The venv path is deterministic
  (`{{ app_dir }}/.venv/bin/python3`). Alternatives rejected: reusing sync
  scripts in a "local mode" — adds a confusing mode to scripts whose contract is
  scp-to-remote.
- **Decision: Area efetiva runs on the dev machine as part of the weekly
  chain, not on the VM.** Rationale: `compute_area_efetiva.py` needs a **fresh**
  `car.db` (which only the dev CAR pipeline produces) AND a fresh
  `mapbiomas_alerta.db` (which the dev MapBiomas job produces). Both are local
  on dev, so no cross-machine fetch is needed. It runs after CAR import using
  the local fresh `car.db` + local `mapbiomas_alerta.db`, then scp's
  `area_efetiva.db`. The existing `yvy-area-efetiva.timer` template is left
  unwired (documented as superseded).
- **Decision: CAR cadence is weekly.** Rationale: web research on SICAR bulk
  update frequency was inconclusive (the bulk is stable; new registrations and
  retifications trickle in continuously but the perimeter bulk changes slowly).
  Weekly matches the 7-day freshness guard used by every other sync script and
  bounds the heavy pipeline to one run/week. Revisit if a bigger VM arrives.
- **Decision: Failure surfacing is log-only + a status marker file.** Rationale:
  matches the existing pattern (DB mtime is already the success marker,
  common-mistake #5). No new notification infra. A per-source status file
  records last-run time + result for observability.
- **Decision: BdQueimadas is out of scope.** Rationale: the user did not select
  it; it is a fire-foci gap (wiring `sync_bdqueimadas.lua` into the FIRMS loop)
  that is orthogonal to the ingestion-automation theme. Noted as future work.

## Assumptions and answers from code

- **Decision: VM has the Python batch venv (geopandas/shapely).** Source: code @
  `scripts/dev/setup-lua.sh` (installs `setup-python-env.sh` as a runtime dep,
  not gated on test deps) + `ansible/playbook.yml` (installs `python3-venv`).
  So the VM can run the geopandas-based generators directly.
- **Decision: `car.db` is deployed on the VM (7GB) and read read-only by the
  dedicated-DB generators for spatial CAR resolution.** Source: code @
  `scripts/data/download_mapbiomas_alerta.py` (`resolve_car` opens car.db
  `mode=ro`), `download_embargo.py`, `download_sinaflor_auth.py`.
- **Decision: `car.db` is WAL and mutated in place (NOT atomic-swap).** Source:
  code @ `backend-lua/tools/import_car.lua` (`PRAGMA journal_mode=WAL`,
  `DELETE FROM car_data WHERE uf=...`). Consequence: area-efetiva must NOT read
  car.db while a CAR reimport is mid-flight — hence area-efetiva runs after CAR
  completes in the same dev chain.
- **Decision: dev machine already uses cron.** Source: code @
  `scripts/backup/install-backup-cron.sh` (weekly backup cron). Local cron is an
  established pattern on this machine.
- **Decision: the existing `sync-*.sh` scripts and `make ingest-*` targets stay
  as the manual/on-demand path.** Source: code @ `Makefile` (ingest/sync targets
  for sinaflor/mapbiomas/area-efetiva/embargo). Automation is additive; it does
  not remove the manual path.
- **Decision: `yvy-area-efetiva.timer` template exists but is not wired into
  `ansible/playbook.yml`.** Source: code @ `ansible/playbook.yml` (only
  prodes-check, deter-daily, risk-monitor are wired). This plan supersedes it.

## Risks accepted

- **VM 1GB RAM OOM on geopandas load + per-row CAR spatial resolution.**
  Mitigation: MapBiomas (the heaviest geopandas job) is moved to dev. The
  remaining VM jobs (embargo/sinaflor/aux) are CSV/JSON-based and lighter.
  **However, embargo and sinaflor still run a per-row `classify_point` loop
  against the 7GB `car.db`** (`download_embargo.py:251`,
  `download_sinaflor_auth.py` equivalent): each row does an RTree bbox query →
  decodes candidate JSON geoms → shapely `Point.contains`. The embargo dataset
  is typically a few thousand rows (CSV-based, much smaller than MapBiomas's
  hundreds of thousands), so the loop is bounded and the RTree keeps candidate
  decoding cheap. Sinaflor is similar. This should fit on the 1GB VM **but is
  not guaranteed** — if either OOMs, move it to the dev cron (the sync scripts
  already support that path). The aux-layers job has no CAR dependency and is
  safe. Revisit if a bigger VM arrives.
- **Area-efetiva reading car.db mid-reimport.** Mitigation: area-efetiva runs
  after CAR completes in the same dev chain (sequential, not parallel).
- **Dev cron requires the machine to be on at 5am.** Mitigation: accept; the
  user chose 5am. `Persistent`-like catch-up is not available for cron; a missed
  run is caught by the next weekly run (7-day guard means a stale DB is simply
  regenerated).
- **Sinaflor reclassify version monotonicity when run from the VM.** Mitigation:
  the VM service replicates the `.sync_version` increment + `POST
  /api/admin/fires/classify?version=N` logic from `sync-sinaflor.sh`, reading
  the version from the prod data dir. The dev `sync-sinaflor.sh` path is retired
  for this source so the VM timer is the sole writer.
- **CAR scp over a WAL, in-place-mutated car.db.** Mitigation: the swap is
  atomic (scp to `.new` → `integrity_check` → keep `.prev` → `mv`), so a failed
  run never serves a half-written DB and a clean rollback copy is retained.
- **SICAR bulk cadence uncertainty.** Mitigation: weekly is a safe upper bound;
  the pipeline is idempotent per-UF so a more frequent run is safe later.

## Increment DAG

- Inc 1 — Dev cron: MapBiomas Alerta (M) — depends: none — unblocks: 6, 7
- Inc 2 — VM timer: IBAMA Embargo (S) — depends: none — unblocks: 7
- Inc 3 — VM timer: Sinaflor + reclassify (M) — depends: none — unblocks: 7
- Inc 4 — VM timer: Aux layers + def stats (M) — depends: none — unblocks: 7
- Inc 5 — Dev cron: CAR pipeline (L) — depends: none — unblocks: 6, 7
- Inc 6 — Dev cron: Area efetiva (M) — depends: 1, 5 — unblocks: 7
- Inc 7 — Status markers + RUNBOOK + CI (M) — depends: 1,2,3,4,5,6 — unblocks: none

Inc 1–5 are independent and may run in parallel. Inc 6 needs Inc 1's fresh
`mapbiomas_alerta.db` AND Inc 5's fresh `car.db` (both local on dev). Inc 7
documents/verifies everything.

## Increments

### Inc 1 — Dev cron: MapBiomas Alerta (M) — ✅ done
**Depends on:** none
**Unblocks:** 6, 7
**Done criteria:** `mapbiomas_alerta.db` is regenerated weekly on the dev machine
by a cron job and scp'd to prod.

> **Why dev, not the VM:** the national MapBiomas Alerta shapefile is hundreds
> of thousands of polygons; `read_alerts` loads all geometries via geopandas,
> serializes each to WKT, then runs a per-alert spatial resolution against the
> 7GB `car.db` RTree. On the 1GB VM this is a real OOM risk (review finding).
> Moving it to dev also gives `area_efetiva_weekly.sh` (Inc 6) a local fresh
> `mapbiomas_alerta.db`.

#### Files to touch

##### scripts/data/mapbiomas_weekly.sh (new)
- What changes: orchestration wrapper (modeled on `deter_daily.sh`) that runs
  `download_mapbiomas_alerta.py` on dev and scp's the DB to prod.
- Function(s): n/a (bash orchestration).
- Data shapes: n/a.
- Integration points: `python3 scripts/data/download_mapbiomas_alerta.py`
  (7-day guard; `--force` to bypass), then scp
  `backend-lua/data/mapbiomas/mapbiomas_alerta.db` to
  `VM_IP:/opt/yvy/backend-lua/data/mapbiomas/`. Reuse the SSH-key/VM_IP
  resolution from `sync-mapbiomas.sh`.
- Error paths: `set -eu`; generator failure aborts before scp (prod keeps the
  previous DB). scp failure → exit non-zero, retry next week.

##### scripts/backup/install-backup-cron.sh (or a new install-cron script)
- What changes: add a weekly 5am cron entry for `mapbiomas_weekly.sh`.
- Function(s): n/a.
- Data shapes: n/a.
- Integration points: `0 5 * * 1` (Monday 5am); log to a file.
- Error paths: idempotent install (grep before append).

#### Edge cases
- `car.db` absent on dev → generator logs WARN and drops rows without
  `cod_imovel` (already handled in `resolve_car`); DB still written. On dev
  `car.db` is present (it is the CAR pipeline source), so this is unlikely.
- **Rollback:** remove the cron line; the manual `make sync-mapbiomas` path
  remains.

#### Verification
- Run: `bash scripts/data/mapbiomas_weekly.sh --dry-run` then a real run.
- Tests to add/update: none (no new Python logic; existing `--today` determinism
  covers the generator).
- Done: cron entry present, `mapbiomas_alerta.db` scp'd to prod, prod
  `/api/mapbiomas` (or the risk score) serves fresh data.

### Inc 2 — VM timer: IBAMA Embargo (S) — ✅ done
**Depends on:** none
**Unblocks:** 7
**Done criteria:** `embargo.db` on the VM is regenerated weekly by a systemd
timer; a manual `systemctl start yvy-embargo` produces a fresh DB.

#### Files to touch

##### ansible/templates/yvy-embargo.service.j2 (new)
- What changes: oneshot unit running `download_embargo.py` directly on the VM.
- Function(s): n/a.
- Data shapes: n/a.
- Integration points: `ExecStart={{ app_dir }}/.venv/bin/python3
  {{ app_dir }}/scripts/data/download_embargo.py --out
  {{ app_dir }}/backend-lua/data/embargo/embargo.db`. Same env/type/user as Inc 1.
  **Must export `Environment=CAR_DB_PATH={{ app_dir }}/backend-lua/data/car/car.db`**
  — the script defaults `CAR_DB_PATH` to a *relative* path that resolves wrong
  from the unit's cwd, silently skipping spatial resolution (review finding).
- Error paths: generator exits non-zero without writing DB; unit fails; retry
  next week.

##### ansible/templates/yvy-embargo.timer.j2 (new)
- What changes: weekly timer.
- Function(s): n/a.
- Data shapes: n/a.
- Integration points: `OnCalendar=*-*-* 02:30:00`, `Persistent=true`,
  `RandomizedDelaySec=300` (staggered after mapbiomas).
- Error paths: n/a.

##### ansible/playbook.yml
- What changes: wire `yvy-embargo.{service,timer}` like Inc 1.
- Function(s): n/a.
- Data shapes: n/a.
- Integration points: after the mapbiomas block.
- Error paths: n/a.

#### Edge cases
- Embargo spatial CAR resolution needs `car.db` on VM (present — it is deployed).
  **Hard guard:** if `car.db` is absent, the unit should fail loudly (not
  WARN-and-drop), because the spatial fallback is the only path for embargo.
  Add a pre-check in the unit that exits non-zero when `car.db` is missing.
- **Rollback:** `systemctl disable --now yvy-embargo.timer`; the manual
  `make sync-embargo` path remains.

#### Verification
- Run: `systemctl start yvy-embargo && systemctl status yvy-embargo`.
- Tests: none new.
- Done: timer active, `embargo.db` mtime fresh.

### Inc 3 — VM timer: Sinaflor + reclassify (M) — ✅ done
**Depends on:** none
**Unblocks:** 7
**Done criteria:** `sinaflor_auth.db` regenerated weekly AND the fire
reclassification is triggered with a monotonic `.sync_version` on the VM.

#### Files to touch

##### ansible/templates/yvy-sinaflor.service.j2 (new)
- What changes: oneshot unit that (1) runs `download_sinaflor_auth.py` directly
  on the VM, (2) increments `.sync_version` in the prod data dir, (3) curls
  `POST /api/admin/fires/classify?version=N` on localhost:5000. Replicates the
  logic in `scripts/deploy/sync-sinaflor.sh` but in-place (no scp).
- Function(s): n/a (ExecStart is a small bash `-c` chain or a thin wrapper).
- Data shapes: `.sync_version` is an integer file in
  `{{ app_dir }}/backend-lua/data/sinaflor/`.
- Integration points: `ExecStart=/usr/bin/bash -c '...'` — run generator with
  `--out {{ app_dir }}/backend-lua/data/sinaflor/sinaflor_auth.db`, then
  `NEW=$(( $(cat .../.sync_version 2>/dev/null || echo 0) + 1 ))`, write it,
  `curl -s -X POST "http://127.0.0.1:5000/api/admin/fires/classify?version=$NEW"`.
  Env: `YVY_LOCAL_DEV=0`, `WorkingDirectory={{ app_dir }}`,
  `Environment=CAR_DB_PATH={{ app_dir }}/backend-lua/data/car/car.db` (absolute
  path — see Inc 2).
- Error paths: if the generator fails, do NOT increment version or classify
  (guard with `&&`); unit fails; retry next week. If classify curl fails, the DB
  is already in place and the next run re-triggers (idempotent).

##### ansible/templates/yvy-sinaflor.timer.j2 (new)
- What changes: weekly timer.
- Function(s): n/a.
- Data shapes: n/a.
- Integration points: `OnCalendar=*-*-* 03:00:00`, `Persistent=true`,
  `RandomizedDelaySec=300`.
- Error paths: n/a.

##### ansible/playbook.yml
- What changes: wire `yvy-sinaflor.{service,timer}` like Inc 1.
- Function(s): n/a.
- Data shapes: n/a.
- Integration points: after the embargo block.
- Error paths: n/a.

#### Edge cases
- `.sync_version` absent on first run → default 0 → NEW=1 (matches
  `sync-sinaflor.sh`).
- Reclassify is a detached subprocess; the curl may return before it finishes —
  the DB is already in place, so a later run re-triggers safely.
- **Single-writer coordination:** the VM timer must be the SOLE writer of
  `.sync_version`. Retire the dev `sync-sinaflor.sh` path for this source (do
  not run it while the timer is active) to avoid a version race (review
  finding).
- **Rollback:** `systemctl disable --now yvy-sinaflor.timer`; the manual
  `make sync-sinaflor` path remains (re-enable only if the timer is disabled).

#### Verification
- Run: `systemctl start yvy-sinaflor && systemctl status yvy-sinaflor`, then
  `curl -s http://127.0.0.1:5000/api/fires/nature-stats | grep -o '"permitido":[0-9]*'`.
- Tests: none new.
- Done: timer active, `sinaflor_auth.db` mtime fresh, `.sync_version` incremented.

### Inc 4 — VM timer: Aux layers + def stats (M) — ✅ done
**Depends on:** none
**Unblocks:** 7
**Done criteria:** UC/TI/municipality polygons refreshed monthly AND
`precompute_deforestation_stats.py` re-runs on the VM.

#### Files to touch

##### ansible/templates/yvy-aux-layers.service.j2 (new)
- What changes: oneshot unit running `download_aux_layers.py` then
  `precompute_deforestation_stats.py` on the VM.
- Function(s): n/a.
- Data shapes: writes `backend-lua/data/{municipalities.geojson,
  conservation_units.json, indigenous_lands.json}` and `lookup_data` blobs.
- Integration points: `ExecStart={{ app_dir }}/.venv/bin/python3
  {{ app_dir }}/scripts/data/download_aux_layers.py` then
  `.../precompute_deforestation_stats.py`. Env/type/user as Inc 1.
- Error paths: aux download failure → unit fails; def-stats is optional (skip
  with `||` so a polygon refresh still lands).

##### ansible/templates/yvy-aux-layers.timer.j2 (new)
- What changes: monthly timer.
- Function(s): n/a.
- Data shapes: n/a.
- Integration points: `OnCalendar=*-*-01 02:00:00`, `Persistent=true`,
  `RandomizedDelaySec=300`.
- Error paths: n/a.

##### ansible/playbook.yml
- What changes: wire `yvy-aux-layers.{service,timer}` like Inc 1.
- Function(s): n/a.
- Data shapes: n/a.
- Integration points: after the sinaflor block.
- Error paths: n/a.

#### Edge cases
- `precompute_deforestation_stats.py` skips missing territory files (already
  handled); the aux download must run first.
- **Def-stats scope:** `precompute_deforestation_stats.py` aggregates by
  territory (municipality/UC/TI) × year — it does NOT need `car.db`. So Inc 4
  has no CAR dependency (review finding).
- **Rollback:** `systemctl disable --now yvy-aux-layers.timer`; the manual
  `download_aux_layers.py` path remains.

#### Verification
- Run: `systemctl start yvy-aux-layers && systemctl status yvy-aux-layers`.
- Tests: none new.
- Done: timer active, polygon files mtime fresh.

### Inc 5 — Dev cron: CAR pipeline (L) — ✅ done
**Depends on:** none
**Unblocks:** 6, 7
**Done criteria:** a single dev-machine cron job (5am weekly) runs the full CAR
chain — download 27 UFs → import → warm (protected + prodes) → merge → render
tiles — and scp's `car.db` + `tiles_car.db` to prod.

#### Files to touch

##### scripts/data/car_weekly.sh (new)
- What changes: orchestration wrapper (modeled on `deter_daily.sh`) that runs the
  CAR chain on the dev machine and scp's the results to prod.
- Function(s): n/a (bash orchestration).
- Data shapes: n/a.
- Integration points:
  1. `python3 scripts/data/download_car_wfs.py --all` → `data/car/<UF>.json`
  2. `cd backend-lua && lua5.1 tools/import_car.lua` (all 27 UFs) → `car.db`
  3. `make warm-car-protected` and `make warm-car-prodes` (or
     `clone_car_prodes_worker.sh` for parallel) → precompute tables
  4. `make merge-car-prodes` (validates version_key) + merge protected overlap
  5. `python3 scripts/data/render_car_tiles.py` → `tiles_car.db`
  6. scp `car.db` + `tiles_car.db` to the VM **via a temp name, then verify and
     atomically move into place** (see Error paths — car.db is WAL, not
     atomic-swap, so a naive overwrite is unsafe).
  7. **Invalidate prod Redis `car:*` keys** after the swap (see Error paths —
     the warm tools invalidate dev Redis, not prod's, so prod holds stale
     `car:prodes:*`/`car:protected:*` cache with 24h TTL until cleared).
- Error paths: `set -eu`; any step failure aborts before scp (prod keeps the
  previous car.db). Optional steps (warm/merge) degrade to warning with `||`,
  never abort the whole chain silently. scp failure → exit non-zero, retry next
  week.
  **CAR scp is NOT a plain overwrite** (review finding): `car.db` is WAL and
  mutated in place by the warm scripts, so "prod keeps the previous copy on
  failure" is only sound if the swap is atomic. Sequence on the VM:
  1. scp to `car.db.new` (and `tiles_car.db.new`)
  2. run `PRAGMA integrity_check` on `car.db.new`
  3. keep the current `car.db` as `car.db.prev`
  4. `mv car.db.new car.db` (atomic rename)
  5. only after the new DB is verified, drop `car.db.prev`
  6. **Invalidate prod Redis:** `redis-cli --scan --pattern 'car:*' | xargs
     redis-cli del` on the VM (clears stale `car:prodes:*` and
     `car:protected:*` cache left by the warm tools, which invalidated dev
     Redis only — `warm_car_prodes.lua:216` and
     `warm_car_protected_overlap.lua:394` call `redis.delete_pattern` against
     `REDIS_URL` default `127.0.0.1:6379`, i.e. dev, not prod).
  This preserves a clean rollback copy and avoids serving a half-written DB.

##### scripts/backup/install-backup-cron.sh (or a new install-cron script)
- What changes: add a weekly 5am cron entry for `car_weekly.sh` (and, in Inc 6,
  `area_efetiva_weekly.sh`). Follow the existing cron-install pattern.
- Function(s): n/a.
- Data shapes: n/a.
- Integration points: `30 5 * * 1` (Monday 5:30am, staggered after MapBiomas
  at 5:00 — see Inc 1); log to a file.
- Error paths: cron install is idempotent (grep before append).

#### Edge cases
- CAR download is slow (27 UFs, paged, 0.4s sleep) — hours; 5:30am start gives
  headroom before the user is active.
- `car.db` is 7GB; scp over the network is large — use `rsync` if available,
  else `scp` (matches existing sync scripts).
- Warm jobs are memory-heavy — run on dev (ample RAM), never on the VM.
- **Rollback:** remove the cron line; the manual `import_car.lua` + warm tools
  path remains. The VM keeps `car.db.prev` until the next successful swap.

#### Verification
- Run: `bash scripts/data/car_weekly.sh --dry-run` then a real run.
- Tests: none new (existing `import_car.lua` + warm tools are already tested).
- Done: cron entry present, `car.db` + `tiles_car.db` scp'd to prod, prod
  `/api/car/*` and `/api/tiles/car` serve fresh data, prod Redis `car:*` keys
  invalidated (verify: `redis-cli --scan --pattern 'car:*' | wc -l` returns 0
  immediately after the run, then repopulates as traffic arrives).

### Inc 6 — Dev cron: Area efetiva (M) — ✅ done
**Depends on:** 1, 5
**Unblocks:** 7
**Done criteria:** `area_efetiva.db` recomputed on dev after the CAR chain and
scp'd to prod, weekly.

#### Files to touch

##### scripts/data/area_efetiva_weekly.sh (new)
- What changes: orchestration wrapper that runs `compute_area_efetiva.py` on
  dev (using the fresh local `car.db` + local `mapbiomas_alerta.db`) and scp's
  `area_efetiva.db` to prod.
- Function(s): n/a.
- Data shapes: n/a.
- Integration points: `python3 scripts/data/compute_area_efetiva.py` (7-day
  guard; `--force` to bypass), then scp
  `backend-lua/data/area_efetiva/area_efetiva.db` **AND the `area_efetiva.version`
  marker** to `VM_IP:/opt/yvy/backend-lua/data/area_efetiva/`. Reuse SSH/VM_IP
  resolution. **The `.version` marker must be scp'd** (review finding):
  `compute_area_efetiva.py:246-248` writes it next to the DB, and the Ansible
  service exports `AREA_EFETIVA_VERSION` from it to invalidate cached risk
  scores. Without it, prod's `AREA_EFETIVA_VERSION` won't advance and cached
  risk scores won't invalidate.
- Error paths: `set -eu`; failure aborts before scp. Must run AFTER `car_weekly.sh`
  completes (sequential in the same cron chain or a later cron slot).

##### scripts/backup/install-backup-cron.sh (or new install-cron script)
- What changes: add a weekly cron entry for `area_efetiva_weekly.sh`, scheduled
  after the CAR job.
- Function(s): n/a.
- Data shapes: n/a.
- Integration points: `0 6 * * 1` (Monday 6:00am, staggered after CAR at
  5:30 — see Inc 1 and Inc 5).
- Error paths: idempotent install.

#### Edge cases
- `compute_area_efetiva.py` needs a fresh `mapbiomas_alerta.db` (produced by
  Inc 1 on dev) AND a fresh `car.db` (produced by Inc 5 on dev) — both local,
  so no cross-machine fetch. This is why Inc 6 depends on BOTH 1 and 5.
- Must not read `car.db` mid-reimport — guaranteed by running after Inc 5.
- **Rollback:** remove the cron line; the manual `make sync-area-efetiva` path
  remains.

#### Verification
- Run: `bash scripts/data/area_efetiva_weekly.sh --dry-run` then a real run.
- Tests: none new.
- Done: cron entry present, `area_efetiva.db` scp'd to prod, prod
  `/api/area-efetiva` (or the risk score) reflects the new version.

### Inc 7 — Status markers + RUNBOOK + CI (M) — ✅ done
**Depends on:** 1,2,3,4,5,6
**Unblocks:** none
**Done criteria:** every automated job writes a status marker; the RUNBOOK
documents the automation architecture; CI syntax-checks the new Python scripts.

#### Files to touch

##### scripts/data/status_marker.sh (new, or a helper in each wrapper)
- What changes: a small helper that writes a per-source status file
  (`<data_dir>/<source>/.last_sync` with ISO timestamp + result) after each job.
  The DB mtime remains the primary success marker (common-mistake #5); the
  status file adds human-readable last-run observability.
- Function(s): `write_status <source> <result>`.
- Data shapes: `source: <name>\nresult: <ok|fail>\nat: <ISO>\n`.
- Integration points: called at the end of each VM service and dev wrapper.
- Error paths: status write failure is non-fatal (best-effort).

##### RUNBOOK.md
- What changes: add an "Automation / scheduled jobs" section listing every timer
  and cron job, its schedule, what it runs, and how to check its status.
- Function(s): n/a (docs).
- Data shapes: n/a.
- Integration points: n/a.
- Error paths: n/a.

##### .github/workflows/ci.yml
- What changes: add a `py_compile` syntax check for the Python data scripts
  (offline, no network), mirroring the existing Lua `luac -p` step. This was
  already proposed in `deter-ingest-gaps` and is additive.
- Function(s): n/a.
- Data shapes: n/a.
- Integration points: new step in the `lua-tests` or a new `python-syntax` job.
- Error paths: n/a.

##### Makefile
- What changes: add `car-weekly` and `area-efetiva-weekly` targets invoking the
  new wrappers (for manual runs), matching the existing `ingest-*`/`sync-*`
  targets.
- Function(s): n/a.
- Data shapes: n/a.
- Integration points: `.PHONY` list + targets.
- Error paths: n/a.

#### Edge cases
- Status files must not be confused with the DB mtime marker — document that the
  DB mtime is authoritative.

#### Verification
- Run: `bash -n scripts/data/car_weekly.sh scripts/data/area_efetiva_weekly.sh`
  and `python3 -m py_compile scripts/data/*.py` locally; CI runs the new step.
- Tests: none new.
- Done: status files written after each job; RUNBOOK section present; CI green.

## Cross-cutting verification

After Inc 1, 5 and 6, manually walk the prod flow: confirm `mapbiomas_alerta.db`,
`car.db` + `tiles_car.db` + `area_efetiva.db` + `area_efetiva.version` are fresh
on the VM, `/api/car/*` and `/api/tiles/car` serve data, prod Redis `car:*` keys
were invalidated by the CAR swap, and the risk score reflects the new
`AREA_EFETIVA_VERSION`. After Inc 2–4, confirm each dedicated DB's mtime is
fresh and the corresponding route serves data. After Inc 7, confirm every
`.last_sync` status file exists and is recent.

## Standards / common-mistakes referenced

- `.agents/common-mistakes/common-mistakes.md` — applies to: #5 (marker-after-
  success + atomic swap — every generator already follows it; the new wrappers
  must not break it), #4 (live-schema discovery — generators already do this),
  #1 (clock-relative fixtures — no new fixtures needed).
- `.agents/AGENTS.md` — applies to: architecture (dedicated read-only DBs),
  env vars (venv path, `YVY_LOCAL_DEV=0`), deploy flow (playbook wiring).

## Open questions (CONSIDER from review)

- **Embargo/Sinaflor per-row spatial resolution on the 1GB VM (resolved).**
  Both scripts run `classify_point` per row against the 7GB `car.db`. Analysis:
  the RTree index makes bbox lookups O(log n) and only decodes the JSON geom
  for the handful of candidates whose bbox contains the point. The embargo
  dataset is CSV-sourced (a few thousand rows, not the hundreds of thousands
  that MapBiomas has), so peak memory is bounded by the shapely geometry
  objects in flight per row (one at a time, GC'd each iteration). Sinaflor is
  similar. **Verdict: should fit on the 1GB VM, but flag as a known risk.** If
  either job OOMs in practice, the fallback is to move it to the dev cron —
  the `sync-embargo.sh` and (retired) `sync-sinaflor.sh` paths already support
  dev-side generation + scp. No plan change needed; document in the RUNBOOK
  (Inc 7) that embargo/sinaflor are VM-jobs-until-proven-otherwise.
- **Python dependency footprint on the VM.** MapBiomas/Embargo/Sinaflor import
  `geopandas`, `shapely`, `pandas`, `requests`. Installing geopandas on a 1GB VM
  is itself heavy. Confirm these are provisioned via Ansible (the playbook
  already installs `python3-venv` and `setup-lua.sh` installs the batch env) and
  that the VM can host them alongside the running backend. If the VM cannot,
  move embargo/sinaflor to dev too.
- **MapBiomas freshness vs car.db staleness.** MapBiomas runs weekly on dev, and
  car.db is refreshed weekly by the dev CAR cron. The spatial resolution uses a
  car.db that can be up to 7 days stale. This matches today's manual flow, so
  acceptable, but it is a known freshness bound worth documenting in the RUNBOOK.

## Out of scope

- PRODES yearly update (already automated; user confirmed no new automation).
- BdQueimadas fire-foci wiring into the FIRMS loop (orthogonal; future work).
- Moving the CAR pipeline to a bigger VM (future work; the dev-cron design is
  forward-compatible — the wrapper can be re-pointed to a VM timer).
- Email/webhook failure notifications (user chose log-only + status marker).
- New ingestion sources beyond the six selected.

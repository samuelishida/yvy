# scripts/ Refactor — Functional Subdirectory Layout

## Context

`scripts/` is a flat folder of ~40 files mixing local dev lifecycle (`.sh` + `.ps1`),
deploy/provisioning, backup tooling, and ~16 TerraBrasilis Python data scripts. It is
hard to navigate, mixes naming conventions, contains dead scripts, and has stale
references scattered through CI, Ansible, systemd templates, and docs.

The goal is a **safe reorganization** — no behavior changes to any pipeline — that:

- Groups scripts into function-based subdirectories.
- Deletes truly orphaned scripts.
- Updates **every** in-repo caller (Makefile, CI, Ansible, systemd templates, Lua
  runtime, docs) so nothing breaks.
- Fixes stale references found along the way.
- Preserves the already-wired `deter_daily.sh` systemd timer.

Explicitly out of scope: repo-root files (`backup.sh`, `stop.sh`, `main.py`, `gpw.py`,
`test_biome_api.py`, `tmp-node-test.js`, `config.toml`), and code-level dedup of the
WFS downloaders / tile renderers (see Out of scope).

## Architectural decisions

- **Decision: subdirectories by function** — `scripts/dev/` (local lifecycle),
  `scripts/deploy/` (provisioning), `scripts/backup/` (prod + desktop backup),
  `scripts/data/` (TerraBrasilis ingest/enrichment), `scripts/lib/` (shared runtime
  helpers). Rationale: mirrors how the scripts are used and matches the "too
  convoluted" complaint. Alternatives rejected: keep flat (doesn't solve
  navigation), group by language (`.sh` vs `.py` — doesn't reflect function).
- **Decision: keep language-native naming** — kebab-case for `.sh`/`.ps1`,
  snake_case for `.py`. Do NOT rename existing working basenames (`check_prodes_update.sh`,
  `deter_daily.sh`, `download_deter_wfs.py`, …). Rationale: renaming snake→kebab on
  systemd-referenced scripts adds churn/risk for zero functional gain. Only new
  files adopt kebab-case for shell.
- **Decision: delete orphaned scripts, keep referenced-but-manual `.py` tools.**
  Delete `ansible-check.sh` (zero callers), `kill-yvy.sh` (zero exec callers;
  `stop-lua-stack.sh` supersedes it), `backfill_news_images_playwright.py` (zero
  references repo-wide; imports constants from `browser_fallback.py` only). Keep all
  manual `.py` tools whose *outputs* are consumed by Lua (`tiles_*.db`, `car.db`,
  `lookup_data` blobs, geojson files) — they move into `scripts/data/`.
- **Decision: no backward-compat symlinks.** One repo, one coordinated set of PRs —
  all callers updated in the same increment. Rationale: symlinks would permanently
  clutter the new structure. Git history is preserved via `git mv`.
- **Decision: `requirements.txt` stays at `scripts/` root** as the single project
  Python deps file (used by `setup-python-env.sh` and the data scripts). Rationale:
  avoids cross-folder path churn; it is project-wide, not data-only.
- **Decision: deter_daily systemd wiring already exists — preserve it.** Templates
  `yvy-deter-daily.{service,timer}.j2` and the playbook enable/start tasks are
  already present (Inc 6 of the terrabrasilis plan). The refactor only updates the
  `ExecStart` path; no new templates are created.

## Assumptions and answers from code

- All script inventories, callers, and dead-code analysis answered from code (see
  `/memories/repo/scripts-docs-inventory.md` and the three Explore reports).
- Decision: move `.ps1` alongside their `.sh` counterparts (user-confirmed).
- Decision: delete orphans (user-confirmed); stay strictly inside `scripts/`
  (user-confirmed); subdirectories by function (user-confirmed).
- Decision: deter_daily timer — user requested wiring; **found already wired** in
  `ansible/templates/yvy-deter-daily.{service,timer}.j2` + `playbook.yml:400-414,
  429-433`. Refactor preserves it (path update only).
- Stale refs to fix: `scripts/run-backend.sh` / `scripts/run-frontend.sh` (files
  don't exist) in `.gitlab-ci.yml:44-45`, `infra/README.md:182,280`, `AGENTS.md:200`.
- `Makefile` documents nonexistent targets in README (`make backend/frontend/test/migrate`)
  — actual targets are `setup, run, setup-lua, run-lua, test-lua, migrate-lua,
  sqlite-access, stop`.
- Port 5002 appears only in `kill-yvy.sh` (being deleted); no other reference exists
  → dropping it is safe (verify in Inc 1).

## Risks accepted

- **Missed caller reference** → mitigation: grep gate in each increment
  (`rg -n 'scripts/(dev|deploy|backup|data|lib)/<name>'` and a sweep for old flat
  paths); CI `sh -n`/`py_compile`/ansible-syntax gate.
- **`browser_fallback.py` is a live prod runtime dep** → mitigation: `browser_fallback.lua`
  path candidates updated in the *same commit* as the move; verified by local backend
  start + a live fetch smoke test.
- **`.gitlab-ci.yml` glob `sh -n ../scripts/*.sh` does not recurse** → mitigation:
  rewrite to `find ../scripts -name '*.sh' -exec sh -n {} +` in Inc 1.
- **Deleting `kill-yvy.sh` loses port-5002 + "aggressive" kill affordance** →
  mitigation: `stop-lua-stack.sh` already does graceful→KILL escalation on 5000/5001
  (all live ports). The port-5002 confirmation is now a concrete Inc 1 verification
  step with a defined outcome (if live, keep the script or fold 5002 into
  `stop-lua-stack.sh`). Help-text references scrubbed. Accept; revisit if a 5002
  service ever appears.
- **Doc/make-table drift re-introduced later** → mitigation: Inc 3 aligns README make
  table to the actual Makefile; cross-cutting grep checks no doc mentions old paths.

## Increment DAG

- Inc 1 — Relocate + delete orphans + update all callers (L) — depends: none — unblocks: 2, 3
- Inc 2 — Delegate `make stop` to stop-lua-stack.sh (S) — depends: 1 — unblocks: none
- Inc 3 — Documentation update (M) — depends: 1 — unblocks: none

## Increments

### Inc 1 — Relocate scripts into functional subdirs + delete orphans + update all callers (L)

**Depends on:** none
**Unblocks:** 2, 3
**Done criteria:** repo-wide grep for old flat `scripts/<name>` paths returns only
`.plans/` hits and the deleted names; `make setup && make run && make stop` works
locally; GitHub + GitLab CI green; `ansible-playbook --syntax-check` passes.

#### Target layout

```
scripts/
├── requirements.txt            # stays (project-wide Python deps)
├── dev/                        # local dev lifecycle
│   ├── setup-local.sh
│   ├── setup-lua.sh
│   ├── setup-lua.ps1
│   ├── setup-python-env.sh
│   ├── run-lua.sh
│   ├── run-lua-backend.ps1
│   ├── run-lua.ps1             # backward-compat wrapper (kept)
│   ├── run-c-frontend.sh
│   ├── run-c-frontend.ps1
│   ├── start-lua-stack.sh
│   ├── start-lua-stack.ps1
│   ├── stop-lua-stack.sh
│   ├── stop-lua-stack.ps1
│   ├── kill-rogue-yvy.sh
│   ├── kill-rogue-yvy.ps1
│   └── verify-gzip.sh
├── deploy/                     # provisioning
│   ├── deploy-local.sh
│   ├── deploy-nginx.sh
│   └── generate-secrets.sh
├── backup/                     # backup + restore
│   ├── prod-backup.sh
│   ├── pull-prod-backups.sh
│   └── install-backup-cron.sh
├── data/                       # TerraBrasilis ingest + enrichment
│   ├── check_prodes_update.sh
│   ├── deter_daily.sh
│   ├── backfill_deter_alerts.py
│   ├── cache_prodes_tiles.py
│   ├── cross_deter_car.py
│   ├── download_ams_wfs.py
│   ├── download_aux_layers.py
│   ├── download_car_wfs.py
│   ├── download_cerrado_veg.py
│   ├── download_deter_wfs.py
│   ├── download_terraclass.py
│   ├── merge_dbs.py
│   ├── precompute_deforestation_stats.py
│   ├── prodes_geotiff_to_csv.py
│   ├── render_car_tiles.py
│   └── resolve_car_document.py
└── lib/                        # shared runtime helpers
    └── browser_fallback.py
```

Deleted: `ansible-check.sh`, `kill-yvy.sh`, `backfill_news_images_playwright.py`.

#### Files to touch

##### scripts/ (moves + deletions)
- `git mv` every kept script into its target subdir (see layout).
- `git rm scripts/ansible-check.sh scripts/kill-yvy.sh scripts/backfill_news_images_playwright.py`.
- Verify nothing references the deleted names: `rg -n 'ansible-check|kill-yvy|backfill_news_images' --glob '!scripts/**' --glob '!.plans/**'`.

##### scripts/dev/setup-python-env.sh
- What changes: `requirements.txt` path.
- Function(s): the `pip install -r` line(s).
- Integration: `$SCRIPT_DIR/requirements.txt` → `$SCRIPT_DIR/../requirements.txt`.
- Error paths: fail loudly if `../requirements.txt` missing (same behavior as before).

##### scripts/dev/start-lua-stack.sh
- What changes: scrub `./kill-yvy.sh` help-text lines (94, 118) → point to
  `scripts/dev/stop-lua-stack.sh` / `sudo fuser -k ...` as appropriate.
- Integration: help text only; no logic change.

##### Makefile (root)
- What changes: four target commands.
- Function(s): `setup` → `bash scripts/dev/setup-local.sh`; `run` →
  `bash scripts/dev/start-lua-stack.sh`; `setup-lua` →
  `bash scripts/dev/setup-lua.sh`; `run-lua` → `bash scripts/dev/run-lua.sh`.
- `stop:` delegated in Inc 2 (not here).

##### .github/workflows/ci.yml
- What changes: script path lists + one exec + py_compile glob.
- **GitHub CI uses explicit file lists, not globs** (verified: `for f in backup.sh
  stop.sh scripts/setup-local.sh ...`). Update every entry in the `sh -n` list
  (69-80), `bash -n` list (84-86), and shellcheck list (93-101) to its new path
  (`dev/`, `deploy/`, `backup/`). Do NOT rely on a glob — a non-recursive
  `scripts/*.sh` glob after the move would match zero files and pass vacuously.
- `bash scripts/verify-gzip.sh` (107) → `bash scripts/dev/verify-gzip.sh`.
- `python3 -m py_compile scripts/*.py` (129) → recurse:
  `find scripts -name '*.py' -print0 | xargs -0 -n1 python3 -m py_compile`, with
  `export PYTHONPYCACHEPREFIX="$RUNNER_TEMP/pycache"` so subdir `__pycache__/`
  dirs aren't left in the tree.
- Error paths: keep `[ -f "$f" ] && ... || echo "SKIP"` pattern so missing scripts
  don't hard-fail (existing convention).

##### .gitlab-ci.yml
- What changes: fix stale names + new paths + recursive glob.
- `sh -n scripts/setup-local.sh` (43) → `scripts/dev/setup-local.sh`.
- `sh -n scripts/run-backend.sh` (44, STALE) → `scripts/dev/run-lua.sh`.
- `sh -n scripts/run-frontend.sh` (45, STALE) → `scripts/dev/run-c-frontend.sh`.
- `sh -n scripts/deploy-local.sh` (46) → `scripts/deploy/deploy-local.sh`.
- `sh -n scripts/deploy-nginx.sh` (47) → `scripts/deploy/deploy-nginx.sh`.
- `sh -n ../scripts/*.sh` (77) → `find ../scripts -name '*.sh' -exec sh -n {} +`
  (glob does not recurse).

##### ansible/playbook.yml
- `cmd: bash scripts/generate-secrets.sh` (209) → `bash scripts/deploy/generate-secrets.sh`.
- `cmd: bash scripts/setup-lua.sh` (225) → `bash scripts/dev/setup-lua.sh`.

##### ansible/templates/*.j2 (full set — 7 files)
Enumerate every template; only 3 need script-path edits:
- `yvy-backend.service.j2:15` — `ExecStart=.../scripts/run-lua.sh` → `.../scripts/dev/run-lua.sh`.
- `yvy-prodes-check.service.j2:13` — `.../scripts/check_prodes_update.sh` → `.../scripts/data/check_prodes_update.sh`.
- `yvy-deter-daily.service.j2:12` — `.../scripts/deter_daily.sh` → `.../scripts/data/deter_daily.sh`.
- `yvy-nginx.conf.j2:41` — comment referencing `verify-gzip.sh` → `scripts/dev/verify-gzip.sh`.
- `yvy-frontend.service.j2` — **no change** (verified: runs `{{ c_server_bin }}` binary
  directly with `--api-key ${API_KEY}`; no script reference).
- `yvy-deter-daily.timer.j2`, `yvy-prodes-check.timer.j2` — no script paths.
- Sweep: `rg -n 'scripts/' ansible/templates/ ansible/playbook.yml` and confirm every
  remaining hit resolves to the new layout (playbook also has no `check_prodes_update.sh`/
  `deter_daily.sh` direct tasks beyond the two commands already listed).

##### backend-lua/app/browser_fallback.lua
- What changes: `resolve_script_path()` candidates.
- Function(s): `resolve_script_path()` — the two candidates
  `"scripts/browser_fallback.py"`, `"../scripts/browser_fallback.py"` →
  `"scripts/lib/browser_fallback.py"`, `"../scripts/lib/browser_fallback.py"`.
- Error paths: same fallback return path (`"scripts/lib/browser_fallback.py"`).
- Integration: called by `scrapers.lua` on HTTP failure; smoke-test via
  `lua5.1 -e 'require("app.browser_fallback")'` after move (file exists check).

##### status.md
- What changes: line 49 `scripts/kill-yvy.sh` → `scripts/dev/stop-lua-stack.sh`
  (kill-yvy.sh deleted). Wording should say "stop the 5000/5001 stack" — do NOT imply
  it also covers port 5002 (that port only existed in the deleted `kill-yvy.sh`).

#### Internal references that survive automatically
`$SCRIPT_DIR`-based calls stay correct because each caller and its targets are
co-located after the move: `setup-local.sh`→`setup-lua.sh`,
`setup-lua.sh`→`setup-python-env.sh`, `start-lua-stack.sh`→`stop-lua-stack.sh`,
`pull-prod-backups.sh`→`prod-backup.sh` (SSH pipe),
`deter_daily.sh`→{`download_deter_wfs.py`,`backfill_deter_alerts.py`,`cross_deter_car.py`},
`check_prodes_update.sh`→`prodes_geotiff_to_csv.py`,
`deploy-local.sh`→`generate-secrets.sh`, `install-backup-cron.sh`→`pull-prod-backups.sh`.

#### Audit non-co-located path references (MUST-FIX from review)
The repo-wide grep gate only matches literal `scripts/<name>` strings — it CANNOT
see `$SCRIPT_DIR`-relative or `dirname "$0"`-derived references inside moved
scripts. Two concrete breaks are already confirmed; fix both, then sweep the rest:

- **`scripts/backup/pull-prod-backups.sh:13`** — `PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"`
  becomes `scripts/` after the move (not the repo root), so line 47
  `terraform -chdir="$PROJECT_DIR/infra"` would look for `scripts/infra/`. Fix to
  `PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"`.
- **`scripts/dev/setup-python-env.sh:29`** — `pip install -r "$SCRIPT_DIR/requirements.txt"`
  resolves to `scripts/dev/requirements.txt` (missing). Fix to
  `"$SCRIPT_DIR/../requirements.txt"`.

Then, in the increment, run on every moved script:
`rg -n '\$SCRIPT_DIR|dirname "\$0"|cd "\$' scripts/` and rewrite any reference whose
resolved target is not in the same new subdir (e.g. `../dev/setup-lua.sh`,
`../requirements.txt`). Specifically re-read `deploy-local.sh`, `deter_daily.sh`,
`check_prodes_update.sh`, `install-backup-cron.sh` in full. Note: `deter_daily.sh`
and `check_prodes_update.sh` reference `$PROJECT_DIR/.venv/bin/python3` (PROJECT_DIR
is derived from `dirname "$SCRIPT_DIR"`, so it stays the repo root from any
subdir) — no change needed there; `pull-prod-backups.sh` is the only script that
computes PROJECT_DIR as `SCRIPT_DIR/..` (one extra level).

#### Python import graph for browser_fallback.py (MUST-FIX from review)
Moving `browser_fallback.py` to `scripts/lib/` changes `sys.path[0]` to `scripts/lib/`
for any importer. Run `rg -n '(from browser_fallback|import browser_fallback)' scripts/`
repo-wide. The only known importer (`backfill_news_images_playwright.py`) is deleted
in this increment; if any other importer exists, add `scripts/lib` to its `sys.path`
or co-locate the shared constants. `browser_fallback.py` itself is invoked as a
standalone script (`python3 scripts/lib/browser_fallback.py`), so its own imports
are unaffected.

#### Edge cases
- Remove stale `__pycache__/` dirs under `scripts/` and all new subdirs so
  `py_compile`/imports can't pick up old module paths.
- Do not `git mv` any `requirements.txt` (stays at root).
- `.runtime/lua-stack/` PID/log paths referenced by dev scripts are `$PROJECT_DIR`-
  relative, not script-relative — unaffected by moves.
- `Makefile stop:` (lines 31-46) is intentionally untouched in this increment
  (Inc 2). Verified: its inline block references process names/ports only
  (`pkill lua main.lua`, `yvy-server`, ports 5000/5001) — no `scripts/` path, so it
  does not break Inc 1's own `make stop` done-criterion.

#### Verification
- Run: `make setup` (if deps present), `make run`, `make stop`; `cd backend-lua && busted --verbose tests/*.lua` (busted is the runner used by `make test-lua` and CI); `bash scripts/dev/verify-gzip.sh`; `python3 -m py_compile` over all `.py`; `ansible-playbook --syntax-check -i <tmp-ini> ansible/playbook.yml`.
- Non-co-located audit: `rg -n '\$SCRIPT_DIR|dirname "\$0"|cd "\$' scripts/**/*.sh` — every resolved target is in the same subdir or explicitly `..`-qualified (the two MUST-FIX edits above are applied).
- Import audit: `rg -n '(from browser_fallback|import browser_fallback)' --glob '!.plans/**'` → only the deleted `backfill_news_images_playwright.py` and `browser_fallback.py` itself.
- Port 5002: `rg -n '5002' scripts/ backend-lua/` and `ss -tlnp | rg 5002` — if anything is live on 5002, keep `kill-yvy.sh` (or fold 5002 into `stop-lua-stack.sh`) instead of deleting it.
- Grep gate: `rg -n 'scripts/(setup-local|setup-lua|setup-python-env|run-lua|run-c-frontend|start-lua-stack|stop-lua-stack|kill-rogue-yvy|verify-gzip|deploy-local|deploy-nginx|generate-secrets|prod-backup|pull-prod-backups|install-backup-cron|check_prodes_update|deter_daily|browser_fallback)' --glob '!.plans/**' --glob '!scripts/**'` → only expected hits remain.
- Done: local stack boots on 5000/5001; CI lint jobs pass; Ansible syntax OK; both MUST-FIX audits clean.

Note on `kill-rogue-yvy.sh` vs deleted `kill-yvy.sh`: they are NOT the same tool.
`kill-rogue-yvy.sh` is the gentle `--dry-run` rogue-process finder for dev
workflows; `kill-yvy.sh` was the aggressive name/port killer now superseded by
`stop-lua-stack.sh` (graceful→KILL escalation on 5000/5001). Keeping the former
and deleting the latter is intentional.

### Inc 2 — Delegate `make stop` to stop-lua-stack.sh (S)

**Depends on:** 1
**Unblocks:** none
**Done criteria:** `make stop` produces the same result (both processes gone, ports
5000/5001 free) as the previous inline logic; CI shell-check green.

#### Files to touch

##### Makefile (root)
- What changes: `stop:` target body.
- Function(s): replace the inline `pkill`/`lsof` block (31-46) with
  `bash scripts/dev/stop-lua-stack.sh` (which already implements graceful→KILL on
  process names + ports 5000/5001).
- Error paths: `stop-lua-stack.sh` is `set -euo pipefail` and exits cleanly when
  nothing is running; verify it tolerates "nothing to stop" (it does — `kill -0`
  guards).

#### Edge cases
- Confirm nothing listens on port 5002 (only `kill-yvy.sh` referenced it; it is
  being deleted). `ss -tlnp | rg 5002`.
- Keep the friendly "Local processes stopped." echo in `make stop` (wrap the script
  call with `@echo`).

#### Verification
- Run: start stack, `make stop`, then `ss -tlnp | rg ':(5000|5001)'` returns nothing.
- Done: parity with old inline behavior.

### Inc 3 — Documentation update (M)

**Depends on:** 1
**Unblocks:** none
**Done criteria:** no doc file references an old flat `scripts/` path; README make
table matches the actual Makefile targets; stale `run-frontend.sh` references gone.

#### Files to touch

##### README.md / README.en.md
- Make table (70-77): align to real targets `setup, run, setup-lua, run-lua,
  test-lua, migrate-lua, sqlite-access, stop`; remove nonexistent `backend/frontend/
  test/migrate`; `make test` → `make test-lua`.
- Test commands (204, 211-212): `lua scripts/test_db.lua` etc. don't exist → point to
  `cd backend-lua && busted --verbose tests/*.lua` (already what README.en says at 218).
- Script paths: `scripts/generate-secrets.sh` → `scripts/deploy/generate-secrets.sh`
  (250/263), `scripts/setup-lua.sh` → `scripts/dev/setup-lua.sh` (254/267),
  `scripts/run-lua.sh` → `scripts/dev/run-lua.sh` (275/287),
  `scripts/deploy-nginx.sh` → `scripts/deploy/deploy-nginx.sh` (309/301),
  `scripts/verify-gzip.sh` → `scripts/dev/verify-gzip.sh` (116 en).

##### AGENTS.md
- `scripts/generate-secrets.sh` (151) → `scripts/deploy/...`.
- `scripts/setup-lua.sh` (156) → `scripts/dev/...`.
- `scripts/run-lua.sh` (176) → `scripts/dev/...`.
- `scripts/run-frontend.sh` (200, STALE) → `scripts/dev/run-c-frontend.sh`
  (or note the prod frontend runs the compiled binary directly, matching
  `yvy-frontend.service.j2`).

##### RUNBOOK.md
- `scripts/pull-prod-backups.sh` (20) → `scripts/backup/...`;
  `scripts/install-backup-cron.sh` (23) → `scripts/backup/...`;
  `scripts/deploy-local.sh` (44) → `scripts/deploy/...`;
  `scripts/setup-local.sh` (46) → `scripts/dev/...`.

##### HYBRID_ARCHITECTURE.md
- File tree (99-102) and inline paths (140, 156, 159, 165, 250, 263, 302-303, 311):
  update `.ps1`/`.sh` names to `scripts/dev/...`.

##### backend-lua/STRUCTURE.md
- `scripts/run-c-frontend.ps1` (193) → `scripts/dev/run-c-frontend.ps1`.

##### infra/README.md
- `scripts/generate-secrets.sh` (25, 133, 231) → `scripts/deploy/...`.
- `scripts/setup-lua.sh` (138, 236, 396) → `scripts/dev/...`.
- `scripts/run-lua.sh` (158, 256) → `scripts/dev/...`.
- `scripts/run-frontend.sh` (182, 280, STALE) → `scripts/dev/run-c-frontend.sh`.
- Update the duplicated OCI-CLI block consistently (both copies).

##### status.md
- `scripts/kill-yvy.sh` (49) → `scripts/dev/stop-lua-stack.sh` (if not already done
  in Inc 1).

#### Edge cases
- README PT/EN diverge — update both and keep them in sync.
- `infra/README.md` has the OCI-CLI block duplicated verbatim (130-185, 228-283);
  update both copies.
- `.plans/*` docs are historical planning records — do **not** edit them; the grep
  gate excludes `.plans/`.

#### Verification
- Run: `rg -n 'scripts/[a-z_-]+\.(sh|ps1|py)' *.md README*.md backend-lua/STRUCTURE.md infra/README.md scripts/status.md` → all hits resolve to existing files (excluding `.plans/`).
- Done: docs match reality; no dead `make` targets documented.

## Cross-cutting verification

After Inc 3 (i.e. end of the whole effort):

1. `rg -n 'run-frontend|run-backend' --glob '!.plans/**'` → zero hits (stale names gone).
2. Deleted-script sweep — use BARE basenames too (docs/cron may reference them
   without the `scripts/` prefix): `rg -n 'ansible-check|kill-yvy|backfill_news_images' --glob '!.plans/**'` → zero hits.
3. Every path in every doc `rg` (Inc 3 gate) resolves to a file that exists.
4. Full local smoke: `make setup` (or note preinstalled deps), `make run`, hit
   `http://localhost:5001/health` (200), `make stop`.
5. GitHub Actions CI green: lua-tests, shell-check (sh -n + shellcheck + verify-gzip),
   python-check (py_compile over subdirs), frontend-build.
6. GitLab pipeline syntax: `sh -n` recursive + ansible-playbook syntax-check.
7. `browser_fallback.lua` candidate set verified: exactly two candidates exist
   (`scripts/lib/browser_fallback.py`, `../scripts/lib/browser_fallback.py`), and a
   live fetch smoke test via the backend's scraper path succeeds.

## Standards / common-mistakes referenced

- No `.agents/standards/` or `.agents/common-mistakes/` exist in this repo — the
  governing conventions are in `AGENTS.md` (Lua 5.1, JSONB BLOB gotchas, no
  linter/formatter for Lua/C) and `.plans/terrabrasilis-integration/plan.md`
  ("`scripts/*.py` batch, `tools/*.lua` detached" pattern).

## Open questions (CONSIDER from review)

- Whether `kill-yvy.sh`'s port-5002 coverage matters (Inc 1 gate resolves this; if
  live, keep the script or fold 5002 into `stop-lua-stack.sh`).
- Whether to merge Inc 2 into Inc 1 (both touch the Makefile) — kept separate for
  review clarity; easy to collapse if preferred.
- `status.md` redirect wording must not imply port-5002 coverage (see Inc 1/3).
- Test runner consistency: `make test-lua`/CI use `busted`; `lua5.1 test_db.lua`
  remains a valid manual fallback (AGENTS.md) — Inc 3 points docs at `make test-lua`
  as primary and removes only the nonexistent `lua scripts/test_*.lua` paths.

## Out of scope

- Repo-root cleanup (`backup.sh`, `stop.sh`, `main.py`, `gpw.py`, `test_biome_api.py`,
  `tmp-node-test.js`, `config.toml`) — user chose to stay inside `scripts/`.
- Code-level consolidation of the ~5 near-identical WFS downloaders into a shared
  `wfs_client` (Group A), or the 4 raster-tile renderers onto shared `tile_utils`
  (Group B). This is a behavior-touching refactor of live data pipelines — follow-up
  work; `scripts/lib/` is the future home.
- Extending/splitting `requirements.txt` (missing `pandas`, `pillow`, `numpy`,
  `pyproj`, `playwright` pins) — separate task.
- Renaming snake_case shell scripts to kebab-case.
- Deleting manual `.py` tools that Lua comments reference (user chose to keep them).

# Risk Score Pillars — Severity / Legality / Evidence + Confidence

## Context

The current risk score is a single 0–100 number normalized over *active*
factors. Two problems make it commercially indefensible as an
"Environmental Risk Score":

1. **It is really a "Deforestation Severity Score".** With only
   `deforestation` (0.40) + `embargo` (0.20) fed in production, the headline
   is dominated by deforestation volume. A property with 3,000 ha of
   *authorized* suppression scores ~97, while a property with 500 ha of
   *unauthorized, recent, inside-UC* deforestation scores lower. That is
   backwards for a risk engine.
2. **"No data" is treated as low risk.** A CNPJ with no CAR linkage scores
   `0 / baixo`, which a bank could read as "excellent" when it actually means
   "we don't know".

The user confirmed the product direction: keep the **single 0–100 headline**
(as the synthesis, ranking key, and bank/trading integration point), but make
it **explainable** by three sub-scores — **Severity**, **Legality**,
**Evidence** — plus a separate **Confidence %**. Legality must be able to
**invert** the order (Fazenda A 3,000 ha authorized < Fazenda B 500 ha
irregular). Absence of evidence must be an explicit **`UNKNOWN / EVIDENCE_GAP`**
state, not `0 / baixo`.

This plan restructures the engine, persists the new fields, wires the two
legality signals that already have lookups, makes `UNKNOWN` reportable in the
PDF, and surfaces pillars + confidence in the frontend.

## Architectural decisions

- Decision: **Headline score 0–100 stays the primary badge/sort key**; it is
  the weighted blend of Severity and Legality. Rationale: preserves the
  existing integration surface (batch table, PDF cover, supplier `last_score`)
  and the user's explicit product choice. Alternatives rejected: three
  co-equal pillar scores (breaks ranking/integration), removing the headline
  (loses the synthesis).
- Decision: **Headline = weighted blend of Severity and Legality, renormalized over the fed pillars** — base weights `0.55*severity + 0.45*legality`, but when only one pillar is fed the weights renormalize to 1.0 over that pillar (e.g. only severity → headline = severity). The headline is intentionally independent of Confidence; the UI always pairs `score` + `confidence` so a 97 with 40% confidence is visually distinct from a 97 with 95% confidence. Rationale: the user requires Legality to "alterar materialmente o resultado final" (0.45 is material enough to invert), while a single-signal property must not be artificially halved and Confidence must be a separate trust signal, not a multiplier that collapses the score. Alternatives rejected: Legality as a pure modulator within the same level (cannot invert); a fixed formula that errors on a nil pillar; confidence attenuating the score (would hide high-risk low-confidence cases).
- Decision: **Severity and Legality are each 0..1 composites** over their
  signals; **Evidence = weighted coverage of the signals actually fed**;
  **Confidence = Evidence × 100**. Rationale: separates "how much happened"
  (Severity), "how problematic legally" (Legality), and "how much we can
  assert" (Evidence/Confidence). This is the user's three-pillar model. Note:
  `evidence` (the pillar) and the legacy `coverage` field are numerically equal
  in v1 (both = sum of active weights); `coverage` is kept only for
  backward-compat with the existing batch payload field, `evidence` is the
  pillar label.
- Decision: **`UNKNOWN / EVIDENCE_GAP` is a first-class level** (not `0/baixo`),
  triggered when Evidence < 0.15 (no CAR linkage / no fed signal). It is
  **reportable in the PDF** (the report endpoint no longer 404s on it).
  Rationale: absence of evidence must not read as low risk. Alternatives
  rejected: keep `0/baixo` + coverage hint (still misreadable), UNKNOWN badge
  but PDF 404s (inconsistent).
- Decision: **Wire only the two legality signals that already have lookups**:
  `protected_overlap` (UC/TI, `car_protected_overlap.get`) and **Sinaflor
  suppression authorization** (`sinaflor.authorized`) to *de-risk* deforestation.
  The v1 legality composite weights are **embargo 0.40, protected_overlap
  0.30, sinaflor_authorized 0.30** (renormalized over the fed signals).
  `unauthorized_suppression` and `car_status` are **not** in the v1 legality
  weights — they have no derivation/source and would be permanently nil.
  Rationale: the user's Q2 list emphasized PRODES/DETER, authorization,
  embargo, UC/TI, CAR overlap, occurrence date, recurrence — all of which map
  to existing data except CAR status. Fires were not in the user's list and
  have no fires-by-CAR lookup (fires are lat/lon in `fire_data`), so fires
  stays a defined-but-unfed factor in v1. `car_status` has no data source
  (`car_lookup` has no status column) → out of scope.
- **Dependency:** `protected_overlap` requires `car_protected_overlap` to be
  precomputed offline by `tools/warm_car_protected_overlap.lua` (it is NOT built
  by the batch/warm flow). The plan adds a verification warning when the
  precompute is missing/stale and makes `RISK_VERSION` sensitive to the
  protected-overlap version key.
- Decision: **Additive response change** — keep `score`/`level`/`recommendation`
  and add `pillars`, `confidence`, `unknown`. Rationale: only the
  RiskIntelligence page consumes the risk API (verified), so additive is safe
  and rollback-friendly.
- Decision: **Extend `suppliers` table** with `last_level TEXT`,
  `last_confidence INTEGER`, `last_unknown INTEGER`. The supplier monitor
  currently stores only `last_score INTEGER`; without the new columns the
  monitor/webhook silently downgrades the new model back to a single integer.
  Rationale: keeps the supplier flow consistent with the new score semantics.
- Decision: **Bump `RISK_VERSION`** to force recompute + invalidate all cached
  scores after the schema change. Rationale: `current_version_key()` already
  hashes `RISK_VERSION`; bumping it is the established invalidation mechanism.
- Decision: **Extend `risk_precompute.current_version_key()` to include the
  Sinaflor DB hash and the `car_protected_overlap` version key.** After Inc 3,
  score results depend on these two new lookup sources, but the current
  version key only hashes `RISK_VERSION`, `PRODES_VERSION`, `MAPBIOMAS_VERSION`,
  and `AREA_EFETIVA_VERSION`. Without this, a Sinaflor or protected-overlap
  update will not invalidate cached scores. Rationale: correctness of the
  cache invalidation chain.

## Assumptions and answers from code

- Decision: Only 3 of 5 weights are ever active in production
  (`protected_overlap`, `car_status`, `fires` hardcoded `nil` in `build_ctx`).
  Source: code @ `backend-lua/tools/run_batch_analysis.lua:59-95`,
  `backend-lua/tools/warm_risk_scores.lua:38-64`.
- Decision: `protected_overlap` lookup exists and returns
  `{sampled, overlaps, status, max_pct, threshold, version_key, computed_at}`.
  Source: code @ `backend-lua/app/lookups/car_protected_overlap.lua:123`.
- Decision: Sinaflor `authorized(car_prop, acq_date)` returns
  `{nro, modo, data_inicio, data_fim}` or `nil`; `car_prop` is the
  `territory.car` object `{id, name, uf}`. Source: code @
  `backend-lua/app/lookups/sinaflor_lookup.lua:125`.
- Decision: `car_status` has no data source (`car_lookup` has no status column).
  Source: code @ `backend-lua/app/lookups/car_lookup.lua` (grep: no status col).
- Decision: `risk_scores` table has no pillar/confidence/coverage columns;
  `coverage`/`evidence_gap` are in-memory only, dropped at persistence,
  `get_report` context, PDF, and frontend. Source: code @
  `backend-lua/app/lookups/risk_precompute.lua:54-63,142-191`.
- Decision: `get_report` 404s when `risk_precompute.get` returns nil. Source:
  code @ `backend-lua/app/routes/risk.lua:337-373`.
- Decision: Only the RiskIntelligence page consumes the risk API. Source: code
  @ `frontend/src/components/RiskIntelligence/RiskIntelligence.js`.
- Decision: Version invalidation via `current_version_key()` hashing
  `RISK_VERSION`. Source: code @ `backend-lua/app/lookups/risk_precompute.lua:96-113`.
- Decision: Tests run with cwd = `backend-lua/`; temp DB via `env.set` +
  `package.loaded=nil` + re-require; check command `make test-lua`. Source:
  code @ `backend-lua/tests/test_risk_score.lua`, `Makefile:42-44`.

## Risks accepted

- **Legality at 0.45 can invert the headline** — a property with huge but
  fully-authorized deforestation could score lower than a small irregular one.
  This is the intended product behavior (user-confirmed), but it may surprise
  users who expect volume to dominate. Mitigation: the PDF and frontend show
  the pillar breakdown so the "why" is visible; the matrix is documented and
  calibratable.
- **Sinaflor absence is neutral, not "irregular"** — Sinaflor only covers
  ASV/AUTESP, so "no authorization record" does not mean "unauthorized". The
  factor only *reduces* risk when a valid authorization exists; it never
  penalizes absence. Mitigation: documented in the matrix; avoids false
  positives.
- **`UNKNOWN` becomes reportable** — the report endpoint no longer 404s on
  no-score. This changes the contract for `test_risk_report.lua` (which asserts
  a 404). Mitigation: the test is updated in the same increment; no external
  consumers exist.
- **Schema change requires a recompute** — existing cached scores are
  invalidated by the `RISK_VERSION` bump; the warm/batch must re-run to
  repopulate. Mitigation: `make -C backend-lua warm-risk-scores` after deploy.
- **Fires and car_status remain unfed in v1** — the Legality/Severity pillars
  are still partial (max Evidence < 1.0). Mitigation: documented as out of
  scope; the pillar structure is ready to accept them when sources exist.

## Increment DAG

- Inc 1 — Engine: 3-pillar score + UNKNOWN + Confidence (L) — depends: none — unblocks: 2, 3, 4
- Inc 2 — Persistence: risk_scores schema + version bump (M) — depends: 1 — unblocks: 3, 4
- Inc 3 — Wire signals: protected_overlap + Sinaflor in batch/warm (M) — depends: 1, 2 — unblocks: 5
- Inc 4 — Routes + PDF: UNKNOWN reportable + pillars/confidence (M) — depends: 2 — unblocks: 5
- Inc 5 — Frontend: pillars + confidence + UNKNOWN badge (M) — depends: 3, 4

Inc 3 and Inc 4 are independent (both depend only on 1, 2) and can run in
parallel. Inc 5 depends on both.

## Increments

### Inc 1 — Engine: 3-pillar score + UNKNOWN + Confidence (L) — DONE

**Depends on:** none
**Unblocks:** 2, 3, 4
**Done criteria:** `risk_score.score()` returns `{score, level, recommendation,
factors, pillars{severity, legality, evidence}, confidence, coverage,
evidence_gap, unknown}`; Legality can invert the headline; no-evidence yields
`unknown` (not `0/baixo`); all existing `test_risk_score.lua` cases updated and
passing. (Threshold `UNKNOWN_EVIDENCE_THRESHOLD` is set to 0.15; re-evaluate with
real coverage histograms after production warm.)

#### Files to touch

##### backend-lua/app/risk_score.lua (rewrite)
- What changes: restructure from 5 flat factors into 3 pillars. Keep the pure
  `_M.` engine pattern. Add `_M.PILLAR_WEIGHTS` (headline blend), `_M.SEVERITY_WEIGHTS`,
  `_M.LEGALITY_WEIGHTS`, `_M.UNKNOWN_EVIDENCE_THRESHOLD`. Add `unknown` level.
- Function(s):
  - `_M.score(property, ctx)` — compute severity, legality, evidence, confidence,
    headline, level, recommendation. Return the new shape.
    (Future CONSIDER: add PRODES/DETER per-property loss as severity signals.
    They currently exist in the DB and tooling but are not fed into the score
    engine.)
  - `local severity_factor(ctx)` — composite: area (log, ref `_M.AREA_REF_HA`),
    count (log, ref `_M.COUNT_REF`), recency (year decay), fires (log, ref 20).
    Returns 0..1 or nil if no severity signal fed.
  - `local legality_factor(ctx)` — composite over the v1-fed signals: embargo
    (0.40), protected_overlap (0.30), sinaflor_authorized (0.30). Returns 0..1
    or nil if no legality signal fed. `unauthorized_suppression` and
    `car_status` are future weights, not in v1.
  - `local authorization_factor(ctx)` — if `ctx.sinaflor_authorized` is true
    (a valid ASV/AUTESP covers the latest alert), return a low value (0.1,
    meaning low legality risk from this angle); if `ctx.sinaflor_checked` is
    false (no data), return nil (neutral). If `ctx.sinaflor_checked` is true
    but `sinaflor_authorized` is false (DB loaded, property has alerts, no
    valid auth), return nil (neutral) — consistent with "never penalizes
    absence". Never penalizes absence.
  - `local evidence_score(ctx)` — weighted coverage of the severity+legality
    signals actually fed (0..1); `confidence = evidence * 100`.
  - `_M.recommendation(level, evidence_gap, coverage, unknown)` — add an
    `unknown` branch: "Risco indeterminado — não foi possível vincular a
    propriedade a um CAR válido / evidência insuficiente."
- Data shapes:
  - Input `ctx` gains `protected_overlap` (0..1), `sinaflor_authorized` (bool),
    `sinaflor_checked` (bool). Existing fields unchanged.
  - Output:
    ```lua
    {
      score = integer,            -- 0..100 headline (0 when unknown)
      level = "alto"|"medio"|"baixo"|"unknown",
      recommendation = string,
      factors = { {id, name, weight, max_weight, value, fed, reason}, ... },
        -- per-signal metadata for the evidence table: `fed` tells whether the
        -- signal was actually available; `max_weight` is the configured weight;
        -- `weight` is the effective (renormalized) contribution; `reason`
        -- explains "not fed" / "authorized" / "overlap x%" etc.
      pillars = { severity = 0..1, legality = 0..1, evidence = 0..1 },
      confidence = integer,       -- 0..100
      coverage = number,          -- 0..1 (sum of active weights, kept for compat)
      evidence_gap = 0|1,
      unknown = 0|1,              -- 1 when evidence < threshold
    }
    ```
- Integration points: `run_batch_analysis.lua`, `warm_risk_scores.lua`,
  `risk_precompute.lua`, `risk.lua`, `render_risk_report.py`, frontend.
- Error paths: no severity and no legality signal → `unknown=1`, `score=0`,
  `confidence=0`; partial signals → `unknown=0`, confidence reflects coverage.

#### Edge cases
- `ctx.sinaflor_checked=false` (no Sinaflor data) must be neutral, never
  penalize. `ctx.sinaflor_checked=true, sinaflor_authorized=false` (DB loaded,
  property has alerts, no valid auth) is also neutral — never penalizes absence.
- `ctx.protected_overlap` absent → legality uses remaining signals; if none,
  legality is nil.
- Recency with no year → neutral 0.5 (unchanged).
- Headline blend when only one pillar is fed: renormalize the weights over the
  fed pillar (e.g. only severity → headline = severity), so a single-signal
  property is not artificially halved. `coverage`/`evidence` still reflect the
  gap. A nil pillar is treated as weight 0 and the remaining weights
  renormalize to 1.0.

#### Verification
- Run: `cd backend-lua && busted --verbose tests/test_risk_score.lua`
- Tests to add/update: rewrite `test_risk_score.lua` for the new shape —
  assert pillars present, Legality-inverts case (Fazenda A authorized <
  Fazenda B irregular), `unknown` on no-evidence, confidence reflects
  coverage, `recommendation` unknown branch.
- Done: `make test-lua` passes (all files), new engine cases green.

### Inc 2 — Persistence: risk_scores schema + version bump (M) — DONE

**Depends on:** 1
**Unblocks:** 3, 4
**Done criteria:** `risk_scores` has columns for pillars, confidence, coverage,
evidence_gap, unknown; `get`/`upsert`/`bulk_upsert` round-trip them;
`RISK_VERSION` bumped so cached scores invalidate.

#### Files to touch

##### backend-lua/app/lookups/risk_precompute.lua (edit)
- What changes: extend `ensure_schema` with new columns; extend `get`,
  `upsert`, `bulk_upsert` to read/write them; bump `RISK_VERSION` default.
- Function(s):
  - `_M.ensure_schema(conn)` — add columns `severity REAL`, `legality REAL`,
    `evidence REAL`, `confidence INTEGER`, `coverage REAL`, `evidence_gap
    INTEGER`, `unknown INTEGER`. Use `ALTER TABLE ... ADD COLUMN` guarded by a
    `PRAGMA table_info` check (additive migration, common-mistake #5 pattern)
    so existing DBs upgrade in place. **Pillars are stored as individual
    columns** (severity/legality/evidence), NOT a JSON BLOB — `get` reconstructs
    the `pillars{}` table from them, avoiding dual representation drift.
  - `_M.current_version_key()` — extend the hash to include the Sinaflor DB
    hash (`sinaflor_lookup.version_key()` or file mtime, whichever exists) and
    the `car_protected_overlap` version key (`car_protected.current_version_key()`).
    This is required because Inc 3 starts feeding these sources into the score;
    without inclusion, a Sinaflor or protected-overlap update will not invalidate
    cached scores.
  - `_M.get(property_id)` — return the new fields alongside existing ones;
    reconstruct `pillars{severity,legality,evidence}` from the columns.
  - `_M.upsert(property_id, result)` / `_M.bulk_upsert(rows)` — persist the new
    fields.
- Data shapes: `get` returns `{property_id, score, level, recommendation,
  factors, pillars{severity,legality,evidence}, confidence, coverage,
  evidence_gap, unknown, version_key, computed_at}`.
- Integration points: `run_batch_analysis.lua`, `warm_risk_scores.lua`,
  `risk.lua` `build_report_context`.

##### backend-lua/app/lookups/supplier_monitor.lua (edit)
- What changes: extend the `suppliers` table schema with columns
  `last_level TEXT`, `last_confidence INTEGER`, `last_unknown INTEGER`.
  Update the monitor upsert path that currently writes only
  `last_score INTEGER` so it stores the new headline `level`, `confidence`,
  and `unknown` flag alongside `last_score`. Update any webhook/email payload
  builder that reads `last_score` to also send the new fields.
- Function(s):
  - `_M.ensure_schema()` — add the three columns via `ALTER TABLE ... ADD COLUMN`
    guarded by `PRAGMA table_info`.
  - `_M.record_score(supplier_id, score_result)` — new helper that persists
    `last_score`, `last_level`, `last_confidence`, `last_unknown`, and
    `updated_at` atomically.
  - Update existing alert/webhook callers to pass the full `score_result`.
- Integration points: any monitor job that calls `supplier_monitor` from
  batch/warm or scheduled checks.
- Rationale: the supplier monitor currently downgrades the new multi-pillar
  model to a single integer; without these columns the risk-state delta logic
  cannot detect when a supplier moves into/out of UNKNOWN or changes
  confidence.
- Error paths: old rows without new columns → `get` returns nil (stale via
  version_key) → recompute; `ALTER TABLE` on a fresh DB is a no-op.

#### Edge cases
- Additive migration must not fail on a DB that already has the columns
  (idempotent `PRAGMA table_info` guard).
- Pillars are individual columns; `get` reconstructs `pillars{}` — no JSON BLOB
  for pillars (avoids dual representation drift).

#### Verification
- Run: `cd backend-lua && busted --verbose tests/test_risk_score.lua`
- Tests to add/update: `test_risk_score.lua` precompute block — upsert→get
  round-trips pillars/confidence/unknown; version bump invalidates.
- Done: `make test-lua` passes.

### Inc 3 — Wire signals: protected_overlap + Sinaflor in batch/warm (M) — DONE

**Depends on:** 1, 2
**Unblocks:** 5
**Done criteria:** `build_ctx` in both `run_batch_analysis.lua` and
`warm_risk_scores.lua` feeds `protected_overlap` and `sinaflor_authorized`/
`sinaflor_checked`; Legality pillar is real in production.

#### Files to touch

##### backend-lua/tools/run_batch_analysis.lua (edit)
- What changes: in `build_ctx`, after resolving `cod`, feed
  `protected_overlap` from `car_protected_overlap.get(cod)` (map `max_pct`/
  `status` to 0..1) and `sinaflor_authorized`/`sinaflor_checked` from
  `sinaflor.authorized({id=cod}, latest_alert_date)`. Load the two lookups in
  `run_batch`. **Also extend `process_row`'s return shape** with `pillars`,
  `confidence`, `unknown` (this is the DAG dependency that Inc 5's frontend
  reads).
- Function(s):
  - `local function build_ctx(property)` — add the two legality signals.
  - `_M.run_batch(batch_id, csv_path)` — `car_protected.load_car_protected()`
    and `sinaflor.load_sinaflor()` before processing.
  - `_M.process_row(row)` — add `pillars = result.pillars`,
    `confidence = result.confidence`, `unknown = result.unknown` to the return
    payload.
- Data shapes: `ctx.protected_overlap = 0..1` (from `max_pct`/`threshold`);
  `ctx.sinaflor_authorized = true|false`; `ctx.sinaflor_checked = true|false`.
  `process_row` returns `{found, property_id, nome, score, level,
  recommendation, coverage, area_efetiva_ha, pillars, confidence, unknown}`.
- Integration points: `risk_score.score`; `risk_precompute.upsert`; frontend
  batch table (Inc 5).
- Error paths: `car_protected_overlap.get` returns nil (no precompute) → leave
  `protected_overlap` nil (neutral); `sinaflor.authorized` returns nil → set
  `sinaflor_checked=true, sinaflor_authorized=false` only when Sinaflor DB is
  loaded and non-empty, else `sinaflor_checked=false` (neutral).

##### backend-lua/tools/warm_risk_scores.lua (edit)
- What changes: mirror the `build_ctx` changes and lookup loads from
  `run_batch_analysis.lua`.
- Function(s): `local function build_ctx(property)`, `_M.run_batch(all, limit)`.
- Integration points: `risk_score.score`; `risk_precompute.bulk_upsert`.

#### Edge cases
- `protected_overlap` mapping: derive 0..1 from `max_pct`/`threshold`/`status`
  (e.g. `clamp01(max_pct / 100)`), and **verify the exact mapping against how
  `car.lua` surfaces it** before committing (the reviewer flagged this as
  unverified).
- Sinaflor date: use the latest alert's **`data_deteccao`** (full `YYYY-MM-DD`
  string) as the `acq_date` — `sinaflor.authorized` requires a string and does
  lexicographic comparison, so the integer `ano_det` (e.g. `2026`) would fail
  the window match. Normalize `data_deteccao` with a strict `YYYY-MM-DD`
  extractor; if it cannot be normalized or is NULL (the mapbiomas schema
  allows NULL), skip Sinaflor for that property (no valid date to match →
  neutral). If no alerts, skip Sinaflor (no deforestation to de-risk).

#### Verification
- Run: `cd backend-lua && busted --verbose tests/test_risk_score.lua`
- Tests to add/update: add a `test_run_batch_analysis.lua` (following
  `test_car_prodes_warm.lua` template) that `require`s the tool and calls
  `process_row`/`run_batch` against temp DBs, asserting `protected_overlap` and
  `sinaflor_authorized` reach the ctx. Also add an end-to-end assertion that a
  processed row with Sinaflor authorization scores a lower legality/headline
  than an otherwise-similar row with protected overlap and no authorization,
  proving the Legality inversion is wired through the batch/warm path, not
  only the engine unit.
- Done: `make test-lua` passes.

### Inc 4 — Routes + PDF: UNKNOWN reportable + pillars/confidence (M) — DONE

**Depends on:** 2
**Unblocks:** 5
**Done criteria:** `GET /api/risk/report` renders an `UNKNOWN` property (no
404); `build_report_context` propagates pillars/confidence/unknown; the PDF
shows the pillar breakdown, Confidence %, and an UNKNOWN state.

#### Files to touch

##### backend-lua/app/routes/risk.lua (edit)
- What changes: `get_report` no longer 404s when the score is `unknown` —
  instead it builds a report with the UNKNOWN state. `build_report_context`
  propagates `pillars`, `confidence`, `unknown` into `context.score`.
- Function(s):
  - `_M.get_report(ctx)` — validate the `id` parameter first. If missing,
    empty, or invalid → return `400`/`404` as today. If the id is valid but
    `risk_precompute.get` returns nil OR `score.unknown==1`, build a report
    with the UNKNOWN state instead of 404.
  - `local function build_report_context(property_id)` — add `pillars`,
    `confidence`, `unknown` to `context.score`.
- Data shapes: `context.score = {score, level, recommendation, computed_at,
  pillars{severity,legality,evidence}, confidence, unknown}`.
- Integration points: `render_risk_report.py`; `risk_precompute.get`.
- Error paths: missing/empty/invalid `id` → 400/404; valid id with no score OR
  `unknown==1` → UNKNOWN report with a reason note.

##### scripts/data/render_risk_report.py (edit)
- What changes: render the pillar breakdown (Severity/Legality/Evidence bars),
  Confidence %, and an UNKNOWN state on the cover/summary when `unknown==1`.
  When a score exists, render the headline score and the confidence %
  side-by-side on the cover (e.g. "Score 87 — Confiança 92%") so the receiver
  cannot confuse a high score with low confidence.
- Function(s): `render_report(context)` — add pillar bars + confidence to the
  cover/summary; add an UNKNOWN branch to the level color/score rendering.
- Data shapes: reads `context.score.pillars`, `context.score.confidence`,
  `context.score.unknown`.
- Integration points: `spawn_report` (unchanged); the PDF is the compliance
  artifact, so the breakdown must be server-side (consistent with the
  risk-intelligence shaping decision).

#### Edge cases
- UNKNOWN report must still render the property header and the reason note, not
  a blank page. For a CNPJ-only row (no CAR), there is no CAR geometry to
  render — the header shows the `property_id` (the CNPJ surrogate) plus the
  reason note, and the spatial sections are omitted (consistent with the
  existing `build_report_context` early-return for non-CAR property_ids).
- Pillar bars must handle nil pillars (partial evidence) gracefully.

#### Verification
- Run: `cd backend-lua && busted --verbose tests/test_risk_report.lua`
- Tests to add/update: `test_risk_report.lua` — the 404-on-no-score assertion
  becomes a 202-with-UNKNOWN assertion; assert `context.score.pillars` and
  `confidence` are present.
- Done: `make test-lua` passes; `python3 -c "import ast; ast.parse(open('scripts/data/render_risk_report.py').read())"` parses.

### Inc 5 — Frontend: pillars + confidence + UNKNOWN badge (M) — DONE

**Depends on:** 3, 4
**Unblocks:** none
**Done criteria:** the RiskIntelligence batch table shows the pillar breakdown
and Confidence %; an `UNKNOWN` badge renders distinctly (not green/baixo);
the default sort is `unknown asc, score desc, confidence desc` so UNKNOWN
rows rank last, and among same-score rows the higher-confidence ones rank
higher; i18n and CSS updated. Add/update frontend tests that verify the new
UNKNOWN badge and pillar columns if a test harness already exists for this
component (if not, add a manual QA checklist in the PR).

#### Files to touch

##### frontend/src/components/RiskIntelligence/RiskIntelligence.js (edit)
- What changes: `ScoreBadge` handles the `unknown` level; `ResultsTable` adds
  columns for Confidence % and a pillar breakdown (or a tooltip); read
  `r.pillars`, `r.confidence`, `r.unknown` from the batch payload.
- Function(s): `ScoreBadge` — add `unknown` to `LEVEL_CLASS`; `ResultsTable` —
  render `confidence` and pillar bars. Default sort is
  `unknown asc, score desc, confidence desc`; if `confidence` is `undefined`
  (old payload), treat it as `0` for sorting so legacy rows sink below
  scored rows.
- Data shapes: consumes `r.pillars{severity,legality,evidence}`,
  `r.confidence`, `r.unknown`.
- Integration points: i18n `t('risk.*')`; direct fetch (no `cachedFetch`).
- Error paths: missing `pillars`/`confidence` on old payloads → render
  gracefully (hide the breakdown).

##### frontend/src/components/RiskIntelligence/RiskIntelligence.css (edit)
- What changes: add an `unknown` badge color (e.g. gray/neutral, distinct from
  green baixo) and pillar-bar styles.
- Integration points: `LEVEL_CLASS` mapping.

##### frontend/src/i18n.js (edit)
- What changes: add `risk.levelUnknown`, `risk.confidence`, `risk.pillarSeverity`,
  `risk.pillarLegality`, `risk.pillarEvidence` PT/EN strings.
- Integration points: `t('risk.*')`.

#### Edge cases
- `unknown` badge must not be green (must not read as low risk).
- Pillar bars must handle nil pillars.

#### Verification
- Run: `npm --prefix frontend run build`
- Tests to add/update: none (no frontend test framework); manual check of the
  batch table.
- Done: frontend build passes; the batch table shows pillars + confidence +
  UNKNOWN badge.

## Cross-cutting verification

- After Inc 5, run the full stack (`make run`) and walk the RiskIntelligence
  batch flow: upload a CSV with a CNPJ-only row (expect UNKNOWN), a
  high-deforestation authorized row (expect lower headline than an irregular
  small row), and a normal row (expect pillars + confidence visible). Confirm
  the PDF renders the pillar breakdown and the UNKNOWN state.
- Run `make -C backend-lua warm-risk-scores` after the last deployed increment
  (Inc 3). Because Inc 2 extends `current_version_key()` to include Sinaflor
  and protected-overlap versions, a single warm run after Inc 3 is sufficient to
  repopulate the cache under the new schema and new signal set. Without this,
  `/api/risk/report` returns UNKNOWN for every pre-existing property until a
  batch is submitted.

## Standards / common-mistakes referenced

- `.agents/common-mistakes/common-mistakes.md` — #5 (additive migration via
  `PRAGMA table_info` guard, marker-after-success), #3 (batch pattern for
  lookups, no N+1), #2 (test Redis isolation + teardown).
- `.agents/AGENTS.md` — pure `_M.` engine pattern, JSONB BLOB columns,
  version-marker invalidation.

## Open questions (CONSIDER from review)

- `sinaflor_checked=true, sinaflor_authorized=false` is defined as neutral in
  v1 (never penalizes absence). Revisit whether a mild penalty is warranted
  once Sinaflor coverage is understood in production.
- The `protected_overlap` → 0..1 mapping (`max_pct/100`) must be verified
  against `car.lua`'s existing surface before committing (Inc 3).
- `coverage` (legacy) and `evidence` (pillar) are numerically equal in v1;
  consider dropping `coverage` from the API in a future cleanup once no
  consumer depends on it.
- `UNKNOWN` is triggered when `evidence < 0.15`, not when `score == 0`. A
  property with some fed signals but below the threshold should still get a
  computed headline and be tagged UNKNOWN, rather than returning `0/baixo`.

## Out of scope

- Wiring `fires` into the score (no fires-by-CAR lookup; not in the user's
  signal list). The pillar structure is ready to accept it later.
- Wiring `car_status` (no data source in the stack).
- APP/Reserva Legal overlap as a legality signal (no lookup yet; the user
  listed it, but it requires new data work — future increment).
- Multi-tenant, auth, or supplier `last_score` schema changes (the supplier
  table keeps a single integer; pillar/confidence for suppliers is future work).

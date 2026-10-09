# Add Flávio cases to `/politica`

## Context

Yvy `/politica` compiles legal claims from the sibling `eleicao-2026/escandalos/` corpus into a vendored snapshot and static `data.json`. The sibling ledger now has 18 legal claims, including four claims intended to appear in two new Flávio cards:

- `flavio_master_filme` and `flavio_master_repasse` → **Banco Master / Dark Horse**.
- `flavio_imoveis_copacabana` and `flavio_imoveis_barra` → **Imóveis de Copacabana e Barra**.

The two cards need distinct, current status citations. The Master card should describe an investigation, not a charge or finding of guilt. Agência Brasil reports Flávio was included in the police investigation on 22 July 2026; the checked sources do not report a formal charge by the 2026-10-09 snapshot. [Agência Brasil, 11 Sep 2026](https://agenciabrasil.ebc.com.br/justica/noticia/2026-09/mendonca-incluiu-flavio-bolsonaro-como-investigado-no-caso-dark-horse).

The two property allegations were reported as part of the Rachadinha complaint rejected by TJ-RJ in 2022. The card must describe that rejection as occurring before a merits ruling, and must not present the properties as a separate proceeding or finding. [G1 on the 2022 rejection](https://g1.globo.com/rj/rio-de-janeiro/noticia/2022/05/16/tj-rj-rejeita-denuncia-contra-flavio-bolsonaro-no-caso-das-rachadinhas.ghtml) · [G1 on Copacabana](https://g1.globo.com/rj/rio-de-janeiro/noticia/2019/12/19/flavio-bolsonaro-pagou-r-638-mil-em-dinheiro-para-lavar-compra-de-imoveis-diz-mp.ghtml) · [Congresso em Foco on Barra](https://www.congressoemfoco.com.br/noticia/22707/mp-diz-que-flavio-bolsonaro-pagou-apartamento-com-dinheiro-de-origem-desconhecida).

Money attribution needs care: about R$ 61 million was reportedly transferred to a U.S. film fund, not shown as received personally by Flávio; R$ 134 million was the negotiated amount, not the amount transferred. Do not imply a connection to Rio public pension investments without a source establishing one. Exclude the family-wide “51 imóveis” statistic; it covers relatives and transactions outside these two corpus claims.

## Assumptions and decisions

- Decision: add exactly two cards, covering both user-confirmed additions (“add ambos”). Source: user-confirmed and `../eleicao-2026/escandalos/claims.tsv`.
- Assumption: “imóveis” means the existing Copacabana and Barra claims. The family-wide “51 imóveis” report is outside this card scope.
- Decision: Master case status is `sob_investigacao`. PT/EN copy says the cited record documents a police inquiry and no formal charge is documented in the cited sources as of 2026-10-09; it does not claim a finding of guilt. Status quote/source: Agência Brasil. The STF docket URL returned 403 during review, and search results did not independently establish that Inq. 5070 is this investigation; do not ship it as corroboration.
- Decision: every new card carries separate `status_sources` and a status quote. The existing compiler uses a primary claim quote as the case-status quote; the four new claim quotes establish allegations and amounts, not current legal status (`scripts/politica/lib/escandalos.mjs:348-378`). Gate 3 must fetch only the status sources when checking that quote.
- Decision: property card uses existing `denunciado_arquivado` status token, but labels it as the shared Rachadinha complaint rejected/archived in 2022 before a merits judgment. Note that MP asked to end the complaint after financial evidence used in the accusation was invalidated by STJ/STF. This is not acquittal, a separate property charge, or a claim that the underlying reported transactions did not occur. Sources: `g1_stj_2021` and `g1_tjrj_2022`.
- Decision: Master evidence items use `alegado_em_apuracao`, visibly labeled “alegação em apuração” / “allegation under investigation.” This avoids implying that an allegation is proven or that the evidence itself has a court-established status. Keep both property claims as `alegado_na_denuncia`; add one separate `extraEvidence` artifact for financial records used in the complaint, state `anulado`, sources `g1_stj_2021` and `g1_tjrj_2022`. Do not label press reports or the allegations themselves annulled.
- Decision: display R$ 61 million only as reportedly transferred to the production fund. Display R$ 134 million as the negotiated amount, not as paid or received by Flávio.
- Decision: replace side-based extra-group matching with explicit `includeClaimIds`. Current compiler compares corpus sides (`lula`/`flavio`) to UI sides (`pt`/`pl`), so the `extraGrupos` path does not include those claims reliably (`scripts/politica/lib/escandalos.mjs:341-344`).
- Decision: preserve vendor/static JSON flow. Refresh vendor snapshot and generated outputs with `make politica-data`; run gates against committed artifacts with `make politica-check` (`Makefile:83-99`).
- Decision: update vintage to `2026-10-09` and upstream legal metrics to `18/18`, matching the sibling's 2026-10-09 changelog; rerun its gates during implementation and stop if either metric no longer passes (`../eleicao-2026/CHANGELOG.md:24`).
- Decision: live citation gate requires an `OK` status-source match for `flavio_master` and `flavio_imoveis`; `BLOCKED` remains non-fatal for legacy cards. Standard CI runs deterministic/static checks only; full `make politica-check` remains the pre-merge live-source check.
- Decision: render each `status_sources` ID as its own link beside the status quote. Existing `SourceRef` shows only first source plus a count, so it cannot expose every status source on the property card.
- Scope: touches more than three existing files; implementation should receive human review before merge.

## Files to touch

### `../eleicao-2026/escandalos/sources.tsv`
- What changes: add `agenciabrasil_master_inquiry` row for current Master status; retain existing claim sources.
- Function(s): none; TSV data consumed by the compiler.
- Data shapes: existing columns `id, publisher, title, url, retrieved, kind, tier`; Agência Brasil is `imprensa` tier 2.
- Integration points: `scripts/politica/build_data.mjs` copies sibling sources into Yvy vendor snapshot.
- Error paths: duplicate/missing IDs fail schema/provenance checks; the fetchable Agência Brasil status source must return `OK` for Gate 3.

### `scripts/politica/lib/escandalos.mjs`
- What changes: add `flavio_master` and `flavio_imoveis` groups; configure separate status citations and status-source IDs; use explicit claim inclusion; set each new claim's evidence state.
- Function(s): keep `buildCases({ claimsTsv, sourcesTsv, loadTxt })`; change group selection to `c.grupo === g.grupo || g.includeClaimIds?.includes(c.claim_id)`.
- Data shapes: group config adds `includeClaimIds?: string[]`, `status_citation_pt?: string`, `status_source_ids?: string[]`; emitted cases add `status_sources: string[]`. Master status quote uses the Agência Brasil fragment “Flávio foi incluído em 22 de julho na investigação” and source ID `agenciabrasil_master_inquiry`; property status quote uses the G1 report/title and source IDs `g1_tjrj_2022`, `g1_stj_2021`.
- Claim mapping: Master group explicitly includes `flavio_master_repasse`; property group includes both property IDs. Preserve current Flávio Rachadinha membership with explicit `flavio_depositos_2mi` and `flavio_coaf_12mi`; preserve Lula Lava Jato membership with `lula_petrobras_62bi` and `lula_odebrecht_85bi`. No claim may leak into multiple cards unless intentionally mapped.
- Evidence states: Master IDs → `alegado_em_apuracao`; property claim IDs → `alegado_na_denuncia`; a separate `extraEvidence` row for financial records used in the complaint → `anulado`, with sources `g1_stj_2021`, `g1_tjrj_2022`. Keep R$ 61 million and R$ 134 million in evidence text/quotes, not `financial[]`.
- Integration points: new status quotes are independent from `primaryClaim` evidence quotes; emit `status_sources` and preserve those IDs in the card's general `sources` list.
- Error paths: unknown status-source IDs, missing required status quote, or missing group claims fail the compiler. Legacy groups without explicit status-source IDs retain their existing behavior.

### `scripts/politica/lib/escandalos_en.mjs`
- What changes: provide English status-citation translations and evidence strings for four claim IDs.
- Function(s): extend `CASE_CITATION_EN`, `EVIDENCE_EN`, and scope maps only if required.
- Data shapes: case-ID → English status citation; claim-ID → existing `{ artifact_en, proves_en }` shape.
- Integration points: compiler output feeds `/politica` PT/EN rendering.
- Error paths: render gate fails for blank required English text or leaked translation keys.

### `.gitignore`, `scripts/politica/lib/paths.mjs`, and `scripts/politica/lib/recompute.mjs`
- What changes: the generic Python `lib/` ignore currently hides every Node module required by the `/politica` compiler and gates. Add narrow exceptions for `scripts/politica/lib/*.mjs` so clean checkouts include these already-present modules.
- Function(s): no logic changes to `paths.mjs` or `recompute.mjs`.
- Data shapes: none.
- Integration points: `build_data.mjs`, `check_provenance.mjs`, and `verify_values.mjs` import these files.
- Error paths: clean CI must fail visibly if any required module is absent, not silently rely on local ignored files.

### `scripts/politica/schema.mjs`
- What changes: add `sob_investigacao` to `ENUM_CASE_STATUS`, `alegado_em_apuracao` to `ENUM_EVIDENCE_STATE`, and validate each case's `status_sources` IDs against `data.sources`.
- Function(s): extend `validate(data)`; keep case status and evidence-item state as separate enums.
- Data shapes: `status_sources: non-empty string[]` required for the two new cards; optional for legacy cases. Each status quote must match at least one named status source; other named status sources may corroborate context without carrying the exact quote.
- Integration points: compiler output and `make politica-check`.
- Error paths: unknown enum, empty required status sources, or unresolved source ID fails schema validation.

### `scripts/politica/verify_citations.mjs`
- What changes: verify each case's `status_citation_pt` against its `status_sources`; use `case.sources` only for legacy cards without `status_sources`. For `flavio_master` and `flavio_imoveis`, fail unless at least one named status source returns `OK`; a fully blocked result is not verification.
- Function(s): citation loop in `main()`; keep existing `--offline` behavior.
- Data shapes: source URLs resolved by ID from `data.sources`; a case passes only if one of its status sources returns `OK`.
- Integration points: `make politica-citations` Gate 3; `make politica-check` invokes it after static checks.
- Error paths: either new card fails unless at least one named status source returns `OK`; a `MISS-SRC` from a different corroborating source does not negate a match. Legacy cards retain existing blocked-source policy; `--offline` remains an explicit skip, not a passing proof.

### `scripts/politica/negative_tests.mjs`
- What changes: add deterministic Gate 3 regression proving a strict case cannot fall back to `case.sources` when its `status_sources` do not resolve.
- Function(s): add one negative case and allow it to run under `--skip-live`; keep other live citation negatives skipped.
- Data shapes: clone `flavio_master` and replace only its `status_sources` with an unknown ID.
- Integration points: included by `make politica-check-static` without network access.
- Error paths: the test fails if Gate 3 uses general sources for a case that declares status sources.

### `scripts/politica/verify_render.mjs`
- What changes: assert both case IDs render in PT and EN with readable status/evidence labels, status notes, exact status-source links beside each status quote, the annulled-record evidence item, and no raw i18n keys.
- Function(s): extend current rendered-DOM assertions.
- Data shapes: expected IDs `flavio_master`, `flavio_imoveis`; expected status/evidence enums.
- Integration points: run from repo root after frontend `npm ci`.
- Error paths: missing card, status phrase, translated content, or citation link fails the gate.

### `frontend/src/components/Politica/PoliticaDossier.js`
- What changes: render one `SourceRef` per `c.status_sources` ID beside the status quote, wrapped with `data-source-id` for DOM verification; legacy cards retain one `SourceRef` over `c.sources`.
- Function(s): `CaseCard({ c, sources })`; add stable `data-case-id` to the article.
- Data shapes: optional `status_sources: string[]` on case data.
- Integration points: uses existing `SourceRef`; keep existing evidence source behavior and render the case source reference once next to its status quote.
- Error paths: missing source ID remains caught by schema and render checks.

### `scripts/politica/claims_crosswalk.json`
- What changes: add four mappings from legal claim IDs to their case evidence nodes; update coverage comment from 36 claims (22 numeric + 14 legal) to 40 (22 + 18).
- Function(s): none; consumed by `check_provenance.mjs`.
- Data shapes: claim ID → resolvable `cases[flavio_master]` or `cases[flavio_imoveis]` path. Existing path grammar resolves cases by `id`; it does not support matching evidence rows by `claim_id`.
- Integration points: provenance gate verifies every ledger claim is surfaced or explicitly excluded and every path resolves.
- Error paths: missing ID or invalid data path fails the gate.

### `scripts/politica/check_provenance.mjs`
- What changes: assert each new `claim_id` appears in exactly its intended case's `claim_ids` and in that case's `evidence[]`; retain ledger coverage and crosswalk path checks.
- Function(s): extend `main()` after loading the crosswalk and generated `data.json`.
- Data shapes: expected membership map for the four new claims; no duplicate membership across the two new cases.
- Integration points: `make politica-check` provenance gate.
- Error paths: missing, duplicated, or cross-assigned claim IDs fail the check.

### `scripts/politica/build_data.mjs`
- What changes: set vintage to `2026-10-09`; update scope/count wording and upstream quality rates from `14/14` to verified `18/18`; remove stale vendor comment saying 14 claims.
- Function(s): preserve `build()` and `vendorEvidence()` signatures.
- Data shapes: `meta.vintage`, bilingual `meta.scope_note`, and `meta.verification.upstream` reflect actual ledger/check results.
- Integration points: `make politica-data` refreshes vendor, `data.json`, and `.lock`.
- Error paths: fail the update if a fresh sibling gate does not confirm `18/18`; do not copy the changelog rate after a later gate failure.

### `Makefile`
- What changes: add `politica-upstream-check` for the sibling ledger gates; make `politica-data` depend on it. Add `politica-check-static` for schema, provenance, source hygiene, values, negative tests, render; add `politica-citations` for live source verification; make `politica-check` depend on both. Document frontend dependency for static/render gate.
- Function(s): `politica-upstream-check`, `politica-check-static`, `politica-citations`, and `politica-check` targets.
- Data shapes: no schema changes.
- Integration points: `politica-check-static` runs in CI; full `politica-check` runs locally before merge.
- Error paths: upstream failure blocks data refresh; render gate fails with its existing actionable `npm ci` message if dependencies are absent.

### `.github/workflows/ci.yml`
- What changes: run `make politica-check-static` in existing Node 20 frontend job after `npm ci` and frontend build; keep network-dependent live citation check out of per-PR CI.
- Function(s): add CI step under `frontend-build`.
- Data shapes: uses committed vendor snapshot and `data.json`, so sibling repository is not required.
- Integration points: clone-clean deterministic checks; full live check remains `make politica-check` before merge.
- Error paths: any schema, provenance, source, value, citation, negative-case, or render failure fails the job.

### `frontend/src/components/Politica/politicaUi.js`
- What changes: add distinct icons for `sob_investigacao` and `alegado_em_apuracao`.
- Function(s): extend `STATUS_ICON` and `EVIDENCE_ICON`; keep pill signatures unchanged.
- Data shapes: icon maps keyed by enum strings.
- Integration points: existing generic case/evidence rendering; status citations use `PoliticaDossier.js` to link exact status sources.
- Error paths: render gate asserts visible label and icon class for both new states.

### `frontend/src/i18n.js`
- What changes: add PT/EN labels and explanatory phrases for both new enums; label `alegado_em_apuracao` as an allegation, not a proven evidence state; clarify existing `denunciado_arquivado` wording as “complaint rejected/shelved before merits ruling” in both locales.
- Function(s): extend existing `pt.politica` and `en.politica` entries.
- Data shapes: `status_sob_investigacao`, `statusPhrase_sob_investigacao`, `state_alegado_em_apuracao`, plus accurate status label/phrase for `denunciado_arquivado`.
- Integration points: `StatusPill`, `StatusPhrase`, and `StatePill`.
- Error paths: missing key appears raw in rendered output and fails render gate.

### `frontend/src/components/Politica/Politica.css`
- What changes: add distinct readable styles for investigation case/evidence states, visually separate from annulled/archived/acquitted.
- Function(s): CSS selectors for enum-derived class names.
- Data shapes: no schema changes.
- Integration points: pills in `politicaUi.js`.
- Error paths: render gate checks class presence and allegation wording; manual review confirms contrast/readability.

### Generated artifacts: `scripts/politica/vendor/escandalos/**`, `frontend/public/politica/data.json`, `frontend/public/politica/data.json.lock`
- What changes: regenerate with `make politica-data`; output includes seven case cards, 18 legal ledger claims, verified metadata, status-source references, and new bilingual copy.
- Integration points: static `/politica` page loads the generated JSON; lock verifies exact output.
- Error paths: malformed corpus, missing evidence/source, mismatched coverage, or stale lock fails build/check.

## Implementation sequence

### Increment 1 — Compiler, provenance, and generated data — DONE
- Add status sources, separate status quotes, exact claim grouping, evidence-state treatment, schema validation, strict live citation requirement, crosswalk coverage, and generated vendor/data artifacts.
- Verify: `make politica-data` reran sibling gates (`18/18`, `GATE1=OK`, `GATE2=OK`); Yvy schema, provenance (`40` claims), source (`31` sources), values (`364` checks), and citation (`7/7`; both new status citations `OK`) gates passed. `negative_tests.mjs --skip-live` passed, including strict status-source scope.

### Increment 2 — UI and rendered checks — DONE
- Add PT/EN labels, icons/styles, direct status-source links, property annulled-record item, and DOM assertions for both cards and exact source links.
- Verify: `verify_render.mjs` passed in PT/EN (`100%`, 98,017 rendered chars), including all seven cards and every direct status-source URL; `npm run build` passed.

### Increment 3 — CI and final review — DONE
- Split Make targets into static and live gates; run static gate in CI and keep live gate as pre-merge verification.
- Verify: `make politica-check` passed all static/live gates (`40` claims, `364` value checks, render `100%`, citations `7/7`); upstream gates passed at `18/18`; `npm run build` and `git diff --check` passed. Reviewed source/status attribution, generated metadata, case membership, and preserved pre-existing untracked files.

## Edge cases

- Master status is an ongoing inquiry; no card text may imply formal charge, conviction, or proven wrongdoing.
- Keep the two Dark Horse investigation lines distinct. This card covers Flávio/Vorcaro financing only; do not merge public-emenda allegations involving other people.
- R$ 61 million means reported transfer to the production fund; R$ 134 million means negotiated total. Neither is Flávio's personal receipt.
- Property allegations are two evidence items in one thematic card tied to the Rachadinha complaint rejected in 2022. Do not count them as two criminal proceedings.
- A rejected complaint without merits ruling is not acquittal. Keep allegation claims distinct from the separate annulled financial-record artifact; describe only the scope established by `g1_stj_2021` and `g1_tjrj_2022`.
- “51 imóveis” is family-wide and stays out of Flávio-specific copy and counts.
- Claim grouping must preserve all existing Lula and Flávio claim membership while preventing cross-case leakage; assert expected claim IDs per card.
- English mode translates status notes, evidence descriptions, and money attribution; verbatim quotations remain in Portuguese.
- The STF docket URL returned 403 during review. Do not claim it as a verified source; the fetched Agência Brasil report supports Gate 3.

## Verification

- Run upstream `eleicao-2026/escandalos` claim/source gates; confirm four new claims and actual quality-rate outputs before copying metadata.
- Run `make politica-data` to refresh vendor snapshot, generated JSON, and lock.
- Run `make politica-check-static`: schema, vendor provenance/crosswalk, source hygiene, independent values, negative tests, and rendered-DOM checks.
- Run `make politica-check`: static checks plus live status citations; both new cards must return `OK`, not `BLOCKED`.
- Run `cd frontend && npm run build`.
- Tests to add/update: `verify_render.mjs` checks seven cards, both new IDs/statuses/evidence states, both locales, source links, and no leaked i18n keys; provenance tests assert exact per-case claim IDs and no cross-case duplication; citation gate verifies quotes only against status sources; a deterministic negative case proves strict status-source scope.
- Manual: open `/politica` in PT and EN; confirm both cards under Flávio, direct status-source links, property card explains annulled financial evidence and complaint rejection without merits ruling, and Master money text distinguishes fund transfer from personal receipt.
- Done criteria: seven cards render from static JSON; all 18 legal claims are surfaced or explicitly excluded; each new status quote is verified against its named status sources; attribution and procedural posture remain accurate.

## Standards / common-mistakes referenced

- `.agents/AGENTS.md` — project conventions and command usage.
- `.agents/common-mistakes/common-mistakes.md` — reviewed; no directly applicable ingestion/backend pitfall.

## Estimated scope

M

## Plan review — 2026-10-09

- Resolved ambiguity: evidence state is `alegado_em_apuracao`, with explicit allegation wording in PT/EN.
- Resolved source risk: removed unverified STF Inq. 5070 URL after 403 and insufficient independent confirmation; use fetched Agência Brasil report as Master status source.
- Resolved UI gap: `SourceRef` exposes only first source plus a count; status sources will each get a direct link, with `data-source-id` checked in rendered output.
- Resolved clean-checkout gap: `.gitignore` hid all `/politica` Node modules. Unignore only `scripts/politica/lib/*.mjs` so compiler and static gates have their required sources in CI.
- Clarified Gate 3: pass each new card only when at least one named status source matches quote; another source may corroborate context without repeating that exact quote.
- No remaining MUST-FIX items. Dependencies are ordered: compiler/data → UI/render → CI/final review.

## Follow-up — remove government comparison section — DONE

- User requested complete removal of “Comparar governos” / “Comparação por período de governo” from `/politica`.
- Removed its section registration and navigation entry, deleted the dedicated component, and removed unused PT/EN copy for that section.
- Updated the rendered-DOM gate so it no longer imports or renders the deleted component.
- Kept `kpis[].compare` data and its schema/provenance checks because they are part of the generated source ledger, independent of this page section.
- Verification: source/build search found no section/component/i18n references. The active `yvy-server` serves `frontend/build`, which still held the old bundle; `npm run build` refreshed it. `GET /politica` returned 200, and the served JS hash matches the new build with no removed labels.
- Build passed with existing warnings in `GeoBreakdown.js` and `Home.js`, plus stale Browserslist data. Tests were not run.

## Follow-up — explain disposition grounds across scandal cards — DONE

- User requested clearer reasons for acquittals, annulments, prescriptions, and refusals across every `/politica` scandal card.
- Reviewed all seven cards in PT/EN. Clarified Mensalão's preclusion (Lula was never a defendant); Lava Jato's Curitiba jurisdiction ruling and separate Moro-bias ruling; triplex prescription and age-reduced deadline; and Atibaia's prescription plus the TRF-1 refusal to suspend closure because the pending STF appeal had no suspensive effect.
- Corrected Atibaia status wording: the 2025 TRF-1 ruling refused a request to suspend the closed case pending STF review; it was not a new merits ruling on the allegations. Added Jornal de Brasília as a status source for that procedural ground.
- Clarified Rachadinha and properties: STJ/STF rulings excluded affected secrecy-derived data over forum/authorization grounds; TJ-RJ rejected the complaint for lack of just cause at MP-RJ's request. Copy says this did not establish that the transactions were either true or false. Master remains labeled an open investigation, with no merits finding.
- Removed stale generated/source-corpus assertions that TJ-RJ blocked another reopening attempt in March 2026.
- Verification: syntax checks, `node scripts/politica/build_data.mjs --no-sibling`, `npm run build`, generated-data review, `git diff --check`, and `GET /politica` (200). Build passed with existing unrelated ESLint warnings in `GeoBreakdown.js` and `Home.js`, plus stale Browserslist data. Tests were not run.

#!/usr/bin/env node
// /politica — schema validation (plan: politica-transparencia, Inc 1).
// Zero external deps: the repo has no ajv and the CI job must run `node` only.
//
// The enums below are the SINGLE SOURCE OF TRUTH for the two closed vocabularies
// the plan defines (case status × evidence state). They are imported by the gates
// so no gate can drift from the schema.
//
// Usage:  node scripts/politica/schema.mjs [path/to/data.json]

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

export const ENUM_CASE_STATUS = [
  'condenado_anulado', // conviction annulled (nulidade) — never a final conviction
  'denunciado_arquivado', // charged, then shelved without a merits ruling
  'absolvido', // acquitted on the merits
  'prescrito', // charges time-barred
  'em_curso', // still running
  'nunca_reu', // never a defendant
  'nao_confirmado', // not confirmed — build must fail if this reaches the panel
];

// Evidence/allegation state — a SEPARATE vocabulary applied to evidence items,
// never to the case itself.
export const ENUM_EVIDENCE_STATE = [
  'alegado_na_denuncia', // alleged in the indictment
  'usado_no_processo', // used in the proceedings
  'anulado', // annulled by a court
];

export const ENUM_KIND = [
  'official',
  'press',
  'portal',
  'api',
  'survey',
  'index',
  'report',
  'dataset',
];

export const ENUM_FIN_STATUS = [
  'reconhecido', // recognised (audited/own statement)
  'estimado', // estimate
  'suspenso_2024', // suspended by Toffoli (Pet 11.972, 01/02/2024)
  'alegado_na_denuncia', // alleged in the indictment only
];

const isStr = (v) => typeof v === 'string' && v.trim() !== '';
const isNum = (v) => typeof v === 'number' && Number.isFinite(v);
const isArr = (v) => Array.isArray(v);

// Every rendered number must carry provenance: a non-empty sources[] whose ids
// all resolve in data.sources.
function checkSources(node, sourceIds, errors, where) {
  if (!isArr(node.sources) || node.sources.length === 0) {
    errors.push(`${where}: missing non-empty sources[]`);
    return;
  }
  for (const id of node.sources) {
    if (!sourceIds.has(id)) errors.push(`${where}: unknown source id "${id}"`);
  }
}

export function validate(data) {
  const errors = [];
  const E = (m) => errors.push(m);

  if (!data || typeof data !== 'object') return { ok: false, errors: ['root is not an object'] };

  // ── meta ──────────────────────────────────────────────────────────────────
  const meta = data.meta || {};
  if (!isStr(meta.vintage) || !/^\d{4}-\d{2}-\d{2}$/.test(meta.vintage)) {
    E('meta.vintage: expected YYYY-MM-DD');
  }
  if (!isStr(meta.generated_by)) E('meta.generated_by: missing');
  if (!isStr(meta.scope_note_pt) || !isStr(meta.scope_note_en)) {
    E('meta.scope_note_pt/en: both required');
  }
  if (!isStr(meta.series_cap)) E('meta.series_cap: missing');

  // ── sources (index first — everything else resolves into it) ───────────────
  if (!isArr(data.sources) || data.sources.length === 0) E('sources[]: missing');
  const sourceIds = new Set();
  for (const [i, s] of (data.sources || []).entries()) {
    const w = `sources[${i}]`;
    if (!isStr(s.id)) E(`${w}.id: missing`);
    else if (sourceIds.has(s.id)) E(`${w}.id: duplicate "${s.id}"`);
    else sourceIds.add(s.id);
    for (const f of ['publisher', 'title', 'url', 'date']) {
      if (!isStr(s[f])) E(`${w}.${f}: missing`);
    }
    if (isStr(s.url) && !/^https?:\/\//.test(s.url)) E(`${w}.url: must start with http`);
    if (!ENUM_KIND.includes(s.kind)) E(`${w}.kind: "${s.kind}" not in ${ENUM_KIND.join('|')}`);
    if (!(s.tier === 1 || s.tier === 2)) E(`${w}.tier: expected 1 or 2`);
  }

  // ── kpis ──────────────────────────────────────────────────────────────────
  if (!isArr(data.kpis) || data.kpis.length === 0) E('kpis[]: missing');
  const kpiIds = new Set();
  for (const [i, k] of (data.kpis || []).entries()) {
    const w = `kpis[${i}]`;
    if (!isStr(k.id)) E(`${w}.id: missing`);
    else kpiIds.add(k.id);
    for (const f of ['label_pt', 'label_en', 'unit', 'direction', 'plain_pt', 'plain_en']) {
      if (!isStr(k[f])) E(`${w}.${f}: missing`);
    }
    if (!isNum(k.value)) E(`${w}.value: not a finite number`);
    // A percent KPI/compare must be 0..100. This is the guard that catches a
    // weighted-mean that forgot (or added) a ×100 — exactly the class of bug a
    // unit-mismatch produces.
    if (k.unit === '%') {
      if (isNum(k.value) && (k.value < 0 || k.value > 100)) E(`${w}.value: ${k.value} out of 0..100 for a % KPI`);
      for (const [j, c] of (k.compare || []).entries()) {
        if (isNum(c.value) && (c.value < 0 || c.value > 100)) E(`${w}.compare[${j}].value: ${c.value} out of 0..100 for a % KPI`);
      }
    }
    if (!isArr(k.compare)) E(`${w}.compare: expected array`);
    else
      for (const [j, c] of k.compare.entries()) {
        if (!isStr(c.label_pt) || !isStr(c.label_en)) E(`${w}.compare[${j}].label_pt/en: missing`);
        if (!isNum(c.value)) E(`${w}.compare[${j}].value: not a finite number`);
      }
    checkSources(k, sourceIds, errors, w);
  }

  // ── series ────────────────────────────────────────────────────────────────
  if (!isArr(data.series) || data.series.length === 0) E('series[]: missing');
  const seriesIds = new Set();
  for (const [i, s] of (data.series || []).entries()) {
    const w = `series[${i}]`;
    if (!isStr(s.id)) E(`${w}.id: missing`);
    else seriesIds.add(s.id);
    if (!isStr(s.unit) || !isStr(s.label_pt) || !isStr(s.label_en)) E(`${w}.unit/label_pt/en: missing`);
    if (!isArr(s.x) || !isArr(s.y)) E(`${w}.x/y: expected arrays`);
    else if (s.x.length !== s.y.length) E(`${w}.x/y: length mismatch`);
    else if (s.x.length === 0) E(`${w}.x/y: empty`);
    else if (s.y.some((v) => !isNum(v))) E(`${w}.y: contains a non-finite number`);
    // temporal monotonicity (Gate 1 also checks this; keep it here so `schema` alone is strict)
    if (isArr(s.x) && s.x.length > 1) {
      for (let j = 1; j < s.x.length; j += 1) {
        if (String(s.x[j]) <= String(s.x[j - 1])) {
          E(`${w}.x: not strictly increasing at index ${j}`);
          break;
        }
      }
    }
    if (typeof s.partial_end !== 'boolean') E(`${w}.partial_end: expected boolean`);
    // Optional government-period demarcations for the chart.
    if (s.periods !== undefined) {
      if (!isArr(s.periods)) E(`${w}.periods: expected array`);
      else
        for (const [j, p] of s.periods.entries()) {
          const pw = `${w}.periods[${j}]`;
          for (const f of ['id', 'label_pt', 'label_en', 'short_pt', 'short_en', 'tone', 'x1', 'x2']) {
            if (!isStr(p[f])) E(`${pw}.${f}: missing`);
          }
          if (isArr(s.x) && p.x1 !== undefined && !s.x.includes(p.x1)) E(`${pw}.x1: not a tick of the series`);
          if (isArr(s.x) && p.x2 !== undefined && !s.x.includes(p.x2)) E(`${pw}.x2: not a tick of the series`);
        }
    }
    checkSources(s, sourceIds, errors, w);
  }

  // ── geo ───────────────────────────────────────────────────────────────────
  const geo = data.geo || {};
  if (!isArr(geo.uf_losers)) E('geo.uf_losers: expected array');
  if (!isArr(geo.municipalities)) E('geo.municipalities: expected array');
  if (!geo.summary || typeof geo.summary !== 'object') E('geo.summary: missing');
  else for (const f of ['pl_majority_2022', 'pl_majority_2026', 'pt_majority_2022', 'pt_majority_2026', 'neither_2026']) {
    if (!isNum(geo.summary[f])) E(`geo.summary.${f}: not a finite number`);
  }
  if (geo.summary) checkSources(geo.summary, sourceIds, errors, 'geo.summary');

  // ── cases ─────────────────────────────────────────────────────────────────
  if (!isArr(data.cases) || data.cases.length === 0) E('cases[]: missing');
  for (const [i, c] of (data.cases || []).entries()) {
    const w = `cases[${i}]`;
    if (!isStr(c.id)) E(`${w}.id: missing`);
    if (!['pt', 'pl'].includes(c.side)) E(`${w}.side: expected pt|pl`);
    for (const f of [
      'name_pt', 'name_en', 'period', 'allegation_pt', 'allegation_en',
      'status_note_pt', 'status_note_en', 'status_citation_pt', 'status_citation_en',
      'defense_pt', 'defense_en',
    ]) {
      if (!isStr(c[f])) E(`${w}.${f}: missing`);
    }
    if (!ENUM_CASE_STATUS.includes(c.status)) {
      E(`${w}.status: "${c.status}" not in ${ENUM_CASE_STATUS.join('|')}`);
    }
    // `nao_confirmado` is a valid enum value but a hard build failure on the panel.
    if (c.status === 'nao_confirmado') E(`${w}.status: "nao_confirmado" must not ship (Inc 8)`);
    // citation_scope is optional, but when present it must be bilingual — it is the
    // honest note on what the rendered verbatim quote does and does not prove.
    if (c.citation_scope_pt !== undefined || c.citation_scope_en !== undefined) {
      if (!isStr(c.citation_scope_pt) || !isStr(c.citation_scope_en)) {
        E(`${w}.citation_scope_pt/en: both required when either is set`);
      }
    }

    if (!isArr(c.financial)) E(`${w}.financial: expected array`);
    else for (const [j, f] of c.financial.entries()) {
      const fw = `${w}.financial[${j}]`;
      if (!isNum(f.value)) E(`${fw}.value: not a finite number`);
      if (!isStr(f.object)) E(`${fw}.object: missing ("a que se refere")`);
      if (!isStr(f.measuredBy)) E(`${fw}.measuredBy: missing ("órgão que mediu")`);
      if (f.currency !== 'BRL') E(`${fw}.currency: expected BRL`);
      if (!ENUM_FIN_STATUS.includes(f.status)) {
        E(`${fw}.status: "${f.status}" not in ${ENUM_FIN_STATUS.join('|')}`);
      }
      checkSources(f, sourceIds, errors, fw);
    }

    if (!isArr(c.evidence) || c.evidence.length === 0) E(`${w}.evidence[]: missing/empty`);
    else for (const [j, e] of c.evidence.entries()) {
      const ew = `${w}.evidence[${j}]`;
      for (const f of ['artifact_pt', 'artifact_en', 'proves_pt', 'proves_en']) {
        if (!isStr(e[f])) E(`${ew}.${f}: missing`);
      }
      if (!ENUM_EVIDENCE_STATE.includes(e.state)) {
        E(`${ew}.state: "${e.state}" not in ${ENUM_EVIDENCE_STATE.join('|')}`);
      }
      checkSources(e, sourceIds, errors, ew);
    }
    checkSources(c, sourceIds, errors, w);
  }

  if (!data.labels || typeof data.labels !== 'object') E('labels: missing');

  return { ok: errors.length === 0, errors };
}

// ── CLI ─────────────────────────────────────────────────────────────────────
const here = dirname(fileURLToPath(import.meta.url));
const DEFAULT_PATH = resolve(here, '../../frontend/public/politica/data.json');

function main(argv) {
  const path = argv[2] ? resolve(process.cwd(), argv[2]) : DEFAULT_PATH;
  let data;
  try {
    data = JSON.parse(readFileSync(path, 'utf8'));
  } catch (err) {
    console.error(`schema: cannot read/parse ${path}: ${err.message}`);
    process.exit(1);
  }
  const { ok, errors } = validate(data);
  if (!ok) {
    console.error(`schema: ${errors.length} error(s) in ${path}`);
    for (const e of errors) console.error(`  - ${e}`);
    process.exit(1);
  }
  console.log(`schema: OK (${path})`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv);

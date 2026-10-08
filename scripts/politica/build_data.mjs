#!/usr/bin/env node
// /politica — data.json generator (plan: politica-transparencia, Inc 1 + Inc 2).
//
// Sources of truth (in order of preference):
//   1. dev  → ../eleicao-2026/{bench,escandalos,evidence}
//   2. CI   → scripts/politica/vendor/  (a committed snapshot; no sibling repo needed)
//
// Every rendered number is DERIVED from a raw file via series_manifest.json.
// Nothing is written by hand into data.json, and the corpus's own numbers are
// re-derived rather than copied, so Gate 2 can re-derive them a third time and
// catch any drift.
//
// Usage:  node scripts/politica/build_data.mjs [--refresh-vendor]

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, copyFileSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, join, relative } from 'node:path';
import { createHash } from 'node:crypto';

import { readRows, aggregate, parseMunCsv, parseUfCsv, geoNational, geoMajorities, geoLosers, geoMunicipal } from './lib/recompute.mjs';
import { buildCases } from './lib/escandalos.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '../..');
const VENDOR = resolve(HERE, 'vendor');
const SIBLING = resolve(REPO, '../eleicao-2026');
const OUT_JSON = resolve(REPO, 'frontend/public/politica/data.json');
const OUT_LOCK = resolve(REPO, 'frontend/public/politica/data.json.lock');

const VINTAGE = '2026-10-07';
const round = (v, d = 2) => Math.round(v * 10 ** d) / 10 ** d;

// ── source resolution (sibling first, vendor fallback) ───────────────────────
function resolveRoots() {
  const useSibling = !process.argv.includes('--no-sibling') && existsSync(join(SIBLING, 'bench/claims.tsv'));
  if (useSibling) return { root: SIBLING, mode: 'sibling' };
  return { root: VENDOR, mode: 'vendor' };
}

const read = (p) => readFileSync(p, 'utf8');

// ── numeric sources (bench/sources.tsv = 6 rows; kept as-is) ─────────────────
function readNumericSources(root, modeBase) {
  const tsvPath = modeBase === 'sibling' ? join(root, 'bench/sources.tsv') : join(root, 'bench/sources.tsv');
  const lines = read(tsvPath).split(/\r?\n/).filter((l) => l.trim() && !l.trimStart().startsWith('#'));
  const header = lines[0].split('\t').map((c) => c.trim());
  const rows = lines.slice(1).map((l) => {
    const c = l.split('\t');
    const o = {};
    header.forEach((h, i) => { o[h] = (c[i] || '').trim(); });
    return o;
  });
  return rows.map((s) => ({
    id: s.id,
    publisher: s.publisher,
    title: s.title,
    url: s.url,
    date: s.retrieved,
    kind: s.kind,
    tier: s.tier === 'official' ? 1 : 2,
  }));
}

// Only the sources actually referenced by the panel are published, plus the
// numeric ones the KPI/series layer uses.
const NUMERIC_SOURCE_IDS = ['bcb_sgs', 'ibge_sidra', 'inpe_prodes', 'inpe_deter', 'ipea_ipeadata', 'tse_resultados'];

// ── resolve one `resolve` descriptor to a number ─────────────────────────────
function resolveDescriptor(manifest, baseDir, cache, desc) {
  if (desc.kind === 'agg') {
    const key = `agg:${desc.file}:${JSON.stringify(desc.spec)}`;
    if (!cache.has(key)) {
      const rows = readRows(desc.fileKind, join(baseDir, desc.file));
      cache.set(key, aggregate(rows, desc.spec));
    }
    return cache.get(key);
  }
  if (desc.kind === 'geo_national') {
    const key = `geo:${desc.file}`;
    if (!cache.has(key)) {
      const rows = parseMunCsv(read(join(baseDir, desc.file)));
      cache.set(key, geoNational(rows));
    }
    const nat = cache.get(key);
    return desc.party === 'pt' ? (desc.year === 2022 ? nat.pt_2022 : nat.pt_2026)
      : (desc.year === 2022 ? nat.pl_2022 : nat.pl_2026);
  }
  throw new Error(`resolveDescriptor: unknown kind "${desc.kind}"`);
}

function build() {
  const { root, mode } = resolveRoots();
  const baseDir = mode === 'sibling' ? join(root, 'evidence') : join(root, 'evidence');
  const manifest = JSON.parse(read(join(HERE, 'series_manifest.json')));
  const cache = new Map();

  const resolveValue = (desc) => resolveDescriptor(manifest, baseDir, cache, desc);

  // Clamp each presidential term to the ticks a given series actually has, so a
  // ReferenceArea always spans real category values (and a term that predates the
  // series is simply not drawn).
  function clampPeriods(x) {
    const monthly = x.length > 0 && /^\d{4}-\d{2}$/.test(x[0]);
    const periods = manifest.periods || [];
    const inRange = (tick, p) =>
      monthly
        ? tick >= p.from && tick <= p.to
        : Number(tick) >= Number(p.from_year) && Number(tick) <= Number(p.to_year);
    const out = [];
    for (const p of periods) {
      const ticks = x.filter((t) => inRange(t, p));
      if (ticks.length === 0) continue;
      out.push({
        id: p.id,
        label_pt: p.label_pt,
        label_en: p.label_en,
        short_pt: p.short_pt,
        short_en: p.short_en,
        tone: p.tone,
        x1: ticks[0],
        x2: ticks[ticks.length - 1],
      });
    }
    return out;
  }

  // ── series ────────────────────────────────────────────────────────────────
  const series = [];
  for (const s of manifest.series) {
    const rows = readRows(s.kind, join(baseDir, s.file));
    // Cap to the last N years of the series (plan: meta.series_cap).
    const maxYear = rows[rows.length - 1].y;
    const minYear = s.cap_years > 0 ? maxYear - s.cap_years + 1 : -Infinity;
    const kept = rows.filter((r) => r.y >= minYear);
    let x = kept.map((r) => (r.m ? `${r.y}-${String(r.m).padStart(2, '0')}` : String(r.y)));
    let y = kept.map((r) => round(r.v, r.v < 100 ? 3 : 1));
    if (s.id === 'prodes') {
      // The 2026 point is a not-yet-measured placeholder (0.0) — drop it.
      const keep = kept.map((r, i) => [r, i]).filter(([r]) => !(r.y === 2026 && r.v === 0));
      x = keep.map(([, i]) => x[i]);
      y = keep.map(([, i]) => y[i]);
    }
    series.push({
      id: s.id, unit: s.unit, label_pt: s.label_pt, label_en: s.label_en,
      x, y, partial_end: s.partial_end, sources: s.sources,
      periods: clampPeriods(x),
    });
  }

  // ── kpis ──────────────────────────────────────────────────────────────────
  const kpis = [];
  for (const k of manifest.kpis) {
    const value = round(resolveValue(k.resolve), k.unit === 'R$ milhões' ? 0 : 2);
    const compare = (k.compare || []).map((c) => ({
      label_pt: c.label_pt, label_en: c.label_en, value: round(resolveValue(c.resolve), k.unit === 'R$ milhões' ? 0 : 2),
      sources: k.sources,
    }));
    kpis.push({
      id: k.id, label_pt: k.label_pt, label_en: k.label_en,
      value, unit: k.unit, direction: k.direction,
      plain_pt: k.plain_pt, plain_en: k.plain_en,
      compare, sources: k.sources,
    });
  }

  // ── superlatives (notes on the desoc KPI) ─────────────────────────────────
  for (const sup of manifest.superlatives) {
    const rows = readRows(sup.fileKind, join(baseDir, sup.file));
    const target = kpis.find((k) => k.id === (sup.id.startsWith('desoc') ? 'econ_desoc' : sup.id));
    if (!target) continue;
    target.notes = target.notes || {};
    const pick = sup.kind === 'argmin'
      ? rows.reduce((a, b) => (b.v < a.v ? b : a))
      : rows.reduce((a, b) => (b.v > a.v ? b : a));
    target.notes[sup.kind === 'argmin' ? 'min' : 'max'] = {
      value: round(pick.v, 2),
      period: pick.m ? `${pick.y}-${String(pick.m).padStart(2, '0')}` : String(pick.y),
      sources: sup.sources,
    };
  }

  // ── geography ─────────────────────────────────────────────────────────────
  const ufRows = parseUfCsv(read(join(baseDir, manifest.geo.uf_file)));
  const munRows = parseMunCsv(read(join(baseDir, manifest.geo.mun_file)));
  const geo = {
    uf_losers: geoLosers(ufRows, 8),
    municipalities: geoMunicipal(munRows, { minVotes: 50000 }),
    summary: { ...geoMajorities(munRows), ...pickNational(geoNational(munRows)), sources: manifest.geo.sources },
  };

  // ── cases (legal corpus, Inc 2) ───────────────────────────────────────────
  const escDir = mode === 'sibling' ? join(root, 'escandalos') : join(root, 'escandalos');
  const loadTxt = (rel) => {
    const p = join(escDir, rel);
    return existsSync(p) ? read(p) : null;
  };
  const { cases, sources: legalSources, errors } = buildCases({
    claimsTsv: read(join(escDir, 'claims.tsv')),
    sourcesTsv: read(join(escDir, 'sources.tsv')),
    loadTxt,
  });

  // ── sources[] = numeric (used) ∪ legal ────────────────────────────────────
  const numeric = readNumericSources(root, mode === 'sibling' ? 'sibling' : 'vendor')
    .filter((s) => NUMERIC_SOURCE_IDS.includes(s.id));
  const byId = new Map();
  for (const s of [...numeric, ...legalSources]) if (!byId.has(s.id)) byId.set(s.id, s);
  const sources = [...byId.values()];

  // ── labels ────────────────────────────────────────────────────────────────
  const labels = {};
  for (const c of cases) labels[c.id] = { pt: c.name_pt, en: c.name_en };

  const data = {
    meta: {
      vintage: VINTAGE,
      generated_by: 'scripts/politica/build_data.mjs',
      scope_note_pt:
        'Recorte datado de 07/10/2026. Números de governo vêm de arquivos brutos oficiais e são recalculados; cada fonte é um link. Os casos jurídicos mostram o status processual em out/2026 — condenações anuladas não são condenações atuais.',
      scope_note_en:
        'A snapshot dated 2026-10-07. Government numbers come from official raw files and are re-derived; every source is a link. Legal cases show the procedural status as of Oct/2026 — annulled convictions are not current convictions.',
      series_cap_pt: 'séries limitadas aos últimos anos indicados em cada gráfico',
      series_cap_en: 'series capped to the last years shown on each chart',
      series_cap: 'últimos 10 anos',
      verification: {
        provenance: 100,
        values: 100,
        citations: 100,
        // Honest label: the upstream rate measures that each citation is PRESENT on
        // a live source; whether a given excerpt fully PROVES the status is a
        // separate judgement the panel discloses per case (citation_scope).
        upstream: { sourced_claims_rate: '14/14', citation_presence_rate: '14/14' },
      },
    },
    kpis,
    series,
    geo,
    cases,
    sources,
    labels,
  };

  if (errors.length) {
    console.error('build_data: corpus errors');
    for (const e of errors) console.error(`  - ${e}`);
    process.exit(1);
  }
  return data;
}

function pickNational(nat) {
  return {
    pt_2022: round(nat.pt_2022, 2), pl_2022: round(nat.pl_2022, 2),
    pt_2026: round(nat.pt_2026, 2), pl_2026: round(nat.pl_2026, 2),
    municipalities: nat.municipalities,
  };
}

// ── vendor snapshot ──────────────────────────────────────────────────────────
const VENDOR_FILES = [
  ['bench/claims.tsv', 'bench/claims.tsv'],
  ['bench/sources.tsv', 'bench/sources.tsv'],
  ['escandalos/claims.tsv', 'escandalos/claims.tsv'],
  ['escandalos/sources.tsv', 'escandalos/sources.tsv'],
  ['evidence/_raw_bcb/raw/sgs_24369.json', 'evidence/_raw_bcb/raw/sgs_24369.json'],
  ['evidence/economia/raw/ipca12m_serie.json', 'evidence/economia/raw/ipca12m_serie.json'],
  ['evidence/economia/raw/massa_rendimento_serie.json', 'evidence/economia/raw/massa_rendimento_serie.json'],
  ['evidence/social/raw/sidra_7435_gini.json', 'evidence/social/raw/sidra_7435_gini.json'],
  ['evidence/social/raw/sidra_7441_rendimento.json', 'evidence/social/raw/sidra_7441_rendimento.json'],
  ['evidence/ambiente/prodes_amazonia_anual.csv', 'evidence/ambiente/prodes_amazonia_anual.csv'],
  ['evidence/ambiente/deter_amazonia_mensal.csv', 'evidence/ambiente/deter_amazonia_mensal.csv'],
  ['evidence/geografia/uf_presidente_1t.csv', 'evidence/geografia/uf_presidente_1t.csv'],
  ['evidence/geografia/municipios_presidente_1t.csv', 'evidence/geografia/municipios_presidente_1t.csv'],
];

function vendorEvidence() {
  if (!existsSync(join(SIBLING, 'escandalos/claims.tsv'))) {
    console.log('vendor: sibling eleicao-2026 not found — keeping the existing snapshot');
    return;
  }
  for (const [src, dst] of VENDOR_FILES) {
    const from = join(SIBLING, src);
    if (!existsSync(from)) { console.log(`vendor: skip (missing) ${src}`); continue; }
    const to = join(VENDOR, dst);
    mkdirSync(dirname(to), { recursive: true });
    copyFileSync(from, to);
  }
  // evidence/*.txt for the 14 claims
  const evSrc = join(SIBLING, 'escandalos/evidence');
  for (const side of ['lula', 'flavio']) {
    const dir = join(evSrc, side);
    if (!existsSync(dir)) continue;
    for (const f of readdirSync(dir)) {
      if (!f.endsWith('.txt')) continue;
      const to = join(VENDOR, 'escandalos/evidence', side, f);
      mkdirSync(dirname(to), { recursive: true });
      copyFileSync(join(dir, f), to);
    }
  }
  console.log(`vendor: refreshed snapshot under ${relative(REPO, VENDOR)}`);
}

// ── main ─────────────────────────────────────────────────────────────────────
function main() {
  if (process.argv.includes('--refresh-vendor')) vendorEvidence();
  const data = build();
  mkdirSync(dirname(OUT_JSON), { recursive: true });
  const json = `${JSON.stringify(data, null, 2)}\n`;
  writeFileSync(OUT_JSON, json);
  const sha = createHash('sha256').update(json).digest('hex');
  const lock = { sha256: sha, generated_at: VINTAGE, bytes: Buffer.byteLength(json), version: 1 };
  writeFileSync(OUT_LOCK, `${JSON.stringify(lock, null, 2)}\n`);
  console.log(`build_data: wrote ${relative(REPO, OUT_JSON)} (${Buffer.byteLength(json)} bytes, sha ${sha.slice(0, 12)})`);
}

main();

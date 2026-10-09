// /politica — independent recomputation from raw files (plan: politica-transparencia).
//
// This module is the single place that turns a RAW evidence file (BCB SGS JSON,
// SIDRA JSON, INPE CSV, TSE-derived CSV) into numbers. It is used by
// `build_data.mjs` to populate `data.json` AND by `verify_values.mjs` (Gate 2) to
// re-derive the same numbers from the vendored copy of the raw file.
//
// Crucially, Gate 2 recomputes from the RAW FILE — not from the corpus's own
// `.txt` evidence and not from `data.json`. That is what makes it independent:
// editing `data.json` without editing the raw file breaks the gate.
//
// Every parser is defensive: a missing/empty file throws, never silently returns 0.

import { readFileSync } from 'node:fs';

// ── row normalisation ────────────────────────────────────────────────────────
// Canonical row: { y: number, m: number|null, v: number }
const num = (x) => {
  if (typeof x === 'number') return Number.isFinite(x) ? x : null;
  if (typeof x !== 'string') return null;
  const t = x.trim().replace(/\s/g, '');
  if (t === '' || t === '-' || t === '..' || t === '...' || t === 'X') return null;
  const n = Number(t);
  return Number.isFinite(n) ? n : null;
};

// BCB SGS — both shapes the corpus produced:
//   raw:      `[{"data":"01/03/2012","valor":"8.0"}, ...]`
//   normalised: `[[2012, 3, 8.0], ...]`
export function parseSgs(text) {
  const data = JSON.parse(text);
  if (!Array.isArray(data)) throw new Error('sgs: root is not an array');
  const rows = [];
  for (const r of data) {
    if (Array.isArray(r)) {
      const [y, m, v] = r;
      const vv = num(v);
      if (vv === null) continue;
      rows.push({ y: Number(y), m: Number(m), v: vv });
    } else if (r && typeof r === 'object') {
      const [dd, mm, yy] = String(r.data).split('/');
      const vv = num(r.valor);
      if (vv === null) continue;
      rows.push({ y: Number(yy), m: Number(mm), v: vv });
    }
  }
  if (rows.length === 0) throw new Error('sgs: no usable rows');
  rows.sort((a, b) => a.y - b.y || (a.m || 0) - (b.m || 0));
  return rows;
}

// SIDRA — first object is the header; data rows carry V, D3C/D3N (period) and
// optionally D4C/D4N (a dimension to filter, e.g. "Cor ou raça").
export function parseSidra(text) {
  const data = JSON.parse(text);
  if (!Array.isArray(data) || data.length < 2) throw new Error('sidra: no data rows');
  const rows = [];
  for (const r of data.slice(1)) {
    if (r.D4N !== undefined && r.D4N !== 'Total') continue; // keep the Total row only
    const v = num(r.V);
    if (v === null) continue;
    const code = String(r.D3C ?? '');
    let y = null;
    let m = null;
    if (/^\d{4}$/.test(code)) y = Number(code);
    else if (/^\d{6}$/.test(code)) {
      y = Number(code.slice(0, 4));
      m = Number(code.slice(4, 6));
    }
    if (y === null) continue;
    rows.push({ y, m, v });
  }
  if (rows.length === 0) throw new Error('sidra: no usable rows');
  rows.sort((a, b) => a.y - b.y || (a.m || 0) - (b.m || 0));
  return rows;
}

// CSV with a header row; `col` names the numeric column, `key` the period column.
export function parseCsv(text, { key, col }) {
  const lines = text.split(/\r?\n/).filter((l) => l.trim() !== '');
  const header = lines[0].split(',').map((c) => c.trim());
  const ki = header.indexOf(key);
  const ci = header.indexOf(col);
  if (ki === -1 || ci === -1) throw new Error(`csv: missing column ${key}/${col}`);
  const rows = [];
  for (const line of lines.slice(1)) {
    const cells = line.split(',');
    const v = num(cells[ci]);
    if (v === null) continue;
    const rawKey = String(cells[ki]).trim();
    if (/^\d{4}$/.test(rawKey)) rows.push({ y: Number(rawKey), m: null, v });
    else if (/^\d{4}-\d{2}$/.test(rawKey)) rows.push({ y: Number(rawKey.slice(0, 4)), m: Number(rawKey.slice(5, 7)), v });
  }
  if (rows.length === 0) throw new Error(`csv: no usable rows for ${col}`);
  rows.sort((a, b) => a.y - b.y || (a.m || 0) - (b.m || 0));
  return rows;
}

// ── aggregations over normalised rows ────────────────────────────────────────
// Spec forms (declared in series_manifest.json; no formula lives in the data):
//   {agg:"last"} {agg:"first"} {agg:"min"} {agg:"max"}
//   {agg:"value_at", year, month?}
//   {agg:"mean", from, to}          // inclusive year range
//   {agg:"year_sum", year}          // sum of that year's (monthly) points
//   {agg:"year_mean", from, to}     // mean of annual points
export function aggregate(rows, spec) {
  const within = (r) => r.y >= spec.from && r.y <= spec.to;
  switch (spec.agg) {
    case 'last':
      return rows[rows.length - 1].v;
    case 'first':
      return rows[0].v;
    case 'min':
      return Math.min(...rows.map((r) => r.v));
    case 'max':
      return Math.max(...rows.map((r) => r.v));
    case 'value_at': {
      const hit = rows.find((r) => r.y === spec.year && (spec.month == null || r.m === spec.month));
      if (!hit) throw new Error(`value_at: no point for ${spec.year}-${spec.month}`);
      return hit.v;
    }
    case 'mean': {
      const sel = rows.filter(within);
      if (sel.length === 0) throw new Error(`mean: empty range ${spec.from}-${spec.to}`);
      return sel.reduce((a, r) => a + r.v, 0) / sel.length;
    }
    case 'year_sum': {
      const sel = rows.filter((r) => r.y === spec.year);
      if (sel.length === 0) throw new Error(`year_sum: no points for ${spec.year}`);
      return sel.reduce((a, r) => a + r.v, 0);
    }
    case 'year_mean': {
      const sel = rows.filter(within);
      if (sel.length === 0) throw new Error(`year_mean: empty range ${spec.from}-${spec.to}`);
      return sel.reduce((a, r) => a + r.v, 0) / sel.length;
    }
    default:
      throw new Error(`aggregate: unknown agg "${spec.agg}"`);
  }
}

// ── geography (municipality-level TSE-derived CSV) ───────────────────────────
export function parseMunCsv(text) {
  const lines = text.split(/\r?\n/).filter((l) => l.trim() !== '');
  const header = lines[0].split(',').map((c) => c.trim());
  const idx = (name) => header.indexOf(name);
  const cols = {
    uf: idx('uf'), mun: idx('municipio'),
    v22: idx('votos_1t_22'), v26: idx('votos_1t_26'),
    pt22: idx('pt_22'), pl22: idx('pl_22'), pt26: idx('pt_26'), pl26: idx('pl_26'),
    dpt: idx('delta_pt'), dpl: idx('delta_pl'),
  };
  const rows = [];
  for (const line of lines.slice(1)) {
    const c = line.split(',');
    rows.push({
      uf: c[cols.uf], municipio: c[cols.mun],
      v22: Number(c[cols.v22]), v26: Number(c[cols.v26]),
      pt22: Number(c[cols.pt22]), pl22: Number(c[cols.pl22]),
      pt26: Number(c[cols.pt26]), pl26: Number(c[cols.pl26]),
      dpt: Number(c[cols.dpt]), dpl: Number(c[cols.dpl]),
    });
  }
  return rows;
}

export function parseUfCsv(text) {
  const lines = text.split(/\r?\n/).filter((l) => l.trim() !== '');
  const header = lines[0].split(',').map((c) => c.trim());
  const idx = (name) => header.indexOf(name);
  const cols = {
    uf: idx('uf'), n: idx('n_municipios'),
    pt22: idx('pt_22'), pl22: idx('pl_22'), pt26: idx('pt_26'), pl26: idx('pl_26'),
    dpt: idx('delta_pt'), dpl: idx('delta_pl'),
  };
  return lines.slice(1).map((line) => {
    const c = line.split(',');
    return {
      uf: c[cols.uf], n: Number(c[cols.n]),
      pt22: Number(c[cols.pt22]), pl22: Number(c[cols.pl22]),
      pt26: Number(c[cols.pt26]), pl26: Number(c[cols.pl26]),
      dpt: Number(c[cols.dpt]), dpl: Number(c[cols.dpl]),
    };
  });
}

// National 1st-round share, weighted by the municipality's valid votes (the
// shares in the CSV are per-municipality, so a plain mean would be wrong).
// The CSV columns are already in percent, so Σ(votes × pct) / total IS the
// weighted percent — no further ×100.
export function geoNational(rows) {
  const v22 = rows.reduce((a, r) => a + r.v22, 0);
  const v26 = rows.reduce((a, r) => a + r.v26, 0);
  const share = (voteCol, pctCol, total) => rows.reduce((a, r) => a + r[voteCol] * r[pctCol], 0) / total;
  return {
    pt_2022: share('v22', 'pt22', v22),
    pl_2022: share('v22', 'pl22', v22),
    pt_2026: share('v26', 'pt26', v26),
    pl_2026: share('v26', 'pl26', v26),
    municipalities: rows.length,
  };
}

export function geoMajorities(rows) {
  const maj = (col) => rows.filter((r) => r[col] >= 50).length;
  return {
    pl_majority_2022: maj('pl22'),
    pl_majority_2026: maj('pl26'),
    pt_majority_2022: maj('pt22'),
    pt_majority_2026: maj('pt26'),
    neither_2026: rows.filter((r) => r.pt26 < 50 && r.pl26 < 50).length,
  };
}

export function geoLosers(rows, topN = 8) {
  return rows
    .filter((r) => r.uf !== 'ZZ')
    .sort((a, b) => a.dpt - b.dpt)
    .slice(0, topN)
    .map((r) => ({ uf: r.uf, pt_delta_pp: r.dpt, pl_delta_pp: r.dpl, n_municipios: r.n }));
}

export function geoMunicipal(rows, { minVotes = 50000 } = {}) {
  const big = rows.filter((r) => r.v26 >= minVotes);
  const topPl = [...big].sort((a, b) => b.dpl - a.dpl).slice(0, 8)
    .map((r) => ({ name: r.municipio, uf: r.uf, delta_pp: r.dpl, side: 'pl', votes: r.v26 }));
  const topPt = [...big].sort((a, b) => b.dpt - a.dpt).slice(0, 8)
    .map((r) => ({ name: r.municipio, uf: r.uf, delta_pp: r.dpt, side: 'pt', votes: r.v26 }));
  return [...topPl, ...topPt];
}

// ── raw-file readers (used by both build and Gate 2) ─────────────────────────
export function readRows(kind, path) {
  const text = readFileSync(path, 'utf8');
  switch (kind) {
    case 'sgs':
      return parseSgs(text);
    case 'sidra':
      return parseSidra(text);
    case 'csv_year':
      return parseCsv(text, { key: 'ano', col: 'area_km2' });
    case 'csv_month':
      return parseCsv(text, { key: 'ano_mes', col: 'area_km2' });
    default:
      throw new Error(`readRows: unknown kind "${kind}"`);
  }
}

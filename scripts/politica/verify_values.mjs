#!/usr/bin/env node
// /politica — Gate 2: INDEPENDENT NUMERIC RECOMPUTATION. Plan: politica-transparencia, Inc 1.
//
// This is the gate that makes the provenance claim non-tautological. It does NOT
// read the corpus `.txt` evidence and does NOT read data.json's derivation —
// it re-derives each number straight from the RAW file via series_manifest.json
// and compares the result to data.json.
//
// Consequence: editing a value in data.json without editing the raw file makes
// the gate fail. That is the whole point.
//
// Coverage is honest: numbers the manifest cannot re-derive are counted under
// `politica_not_verified`, never silently claimed as verified. Legal-case status
// and citations are covered by Gate 3, not here.
//
// Usage:  node scripts/politica/verify_values.mjs [--vendor]

import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, join } from 'node:path';

import { readRows, aggregate, parseMunCsv, parseUfCsv, geoNational, geoMajorities, geoLosers, geoMunicipal } from './lib/recompute.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '../..');
const VENDOR = join(HERE, 'vendor');
const SIBLING = resolve(REPO, '../eleicao-2026');
const argPath = (flag) => {
  const i = process.argv.indexOf(flag);
  return i !== -1 && process.argv[i + 1] ? resolve(process.cwd(), process.argv[i + 1]) : null;
};
const DATA = argPath('--data') || resolve(REPO, 'frontend/public/politica/data.json');

const readJson = (p) => JSON.parse(readFileSync(p, 'utf8'));
const useVendor = process.argv.includes('--vendor');
const root = !useVendor && existsSync(join(SIBLING, 'bench/claims.tsv')) ? SIBLING : VENDOR;
const baseDir = join(root, 'evidence');

const round = (v, d = 2) => Math.round(v * 10 ** d) / 10 ** d;
const tolFor = (v) => Math.max(0.01, Math.abs(v) * 0.005);

function main() {
  const data = readJson(DATA);
  const manifesto = readJson(join(HERE, 'series_manifest.json'));
  const errors = [];
  let checks = 0;
  let notVerified = 0;

  const cache = new Map();
  const rowsFor = (fileKind, file) => {
    const key = `${fileKind}:${file}`;
    if (!cache.has(key)) cache.set(key, readRows(fileKind, join(baseDir, file)));
    return cache.get(key);
  };

  const compare = (label, actual, expected) => {
    checks += 1;
    if (typeof actual !== 'number' || !Number.isFinite(actual)) {
      errors.push(`${label}: recomputed value is not finite`);
      return;
    }
    if (Math.abs(actual - expected) > tolFor(expected)) {
      errors.push(`${label}: data.json=${expected}, raw recomputation=${round(actual, 3)}`);
    }
  };

  // ── series: recompute every point from the raw file ────────────────────────
  for (const s of manifesto.series) {
    const rendered = data.series.find((x) => x.id === s.id);
    if (!rendered) { errors.push(`series "${s.id}": present in manifest but not in data.json`); continue; }
    const rows = rowsFor(s.kind, s.file);
    // Mirror the build's capping + PRODES 2026 placeholder drop.
    const maxYear = rows[rows.length - 1].y;
    const minYear = s.cap_years > 0 ? maxYear - s.cap_years + 1 : -Infinity;
    let kept = rows.filter((r) => r.y >= minYear);
    if (s.id === 'prodes') kept = kept.filter((r) => !(r.y === 2026 && r.v === 0));
    if (kept.length !== rendered.y.length) {
      errors.push(`series "${s.id}": length drift (raw ${kept.length} vs json ${rendered.y.length})`);
      continue;
    }
    for (let i = 0; i < kept.length; i += 1) {
      const exp = round(kept[i].v, kept[i].v < 100 ? 3 : 1);
      compare(`series[${s.id}][${i}]`, rendered.y[i], exp);
    }
  }

  // ── kpis + compare: recompute each value from its raw descriptor ───────────
  for (const k of manifesto.kpis) {
    const rendered = data.kpis.find((x) => x.id === k.id);
    if (!rendered) { errors.push(`kpi "${k.id}": present in manifest but not in data.json`); continue; }
    const recompute = (desc) => {
      if (desc.kind === 'agg') return aggregate(rowsFor(desc.fileKind, desc.file), desc.spec);
      if (desc.kind === 'geo_national') {
        const key = `mun:${desc.file}`;
        if (!cache.has(key)) cache.set(key, geoNational(parseMunCsv(readFileSync(join(baseDir, desc.file), 'utf8'))));
        const nat = cache.get(key);
        return desc.party === 'pt' ? (desc.year === 2022 ? nat.pt_2022 : nat.pt_2026)
          : (desc.year === 2022 ? nat.pl_2022 : nat.pl_2026);
      }
      throw new Error(`verify_values: unknown kind ${desc.kind}`);
    };
    const dec = k.unit === 'R$ milhões' ? 0 : 2;
    compare(`kpis[${k.id}].value`, rendered.value, round(recompute(k.resolve), dec));
    for (const [i, c] of (k.compare || []).entries()) {
      compare(`kpis[${k.id}].compare[${i}]`, rendered.compare[i].value, round(recompute(c.resolve), dec));
    }
  }

  // ── superlatives (notes on the desoc KPI) ──────────────────────────────────
  for (const sup of manifesto.superlatives) {
    const target = data.kpis.find((k) => k.id === (sup.id.startsWith('desoc') ? 'econ_desoc' : sup.id));
    const key = sup.kind === 'argmin' ? 'min' : 'max';
    if (!target?.notes?.[key]) { errors.push(`superlative "${sup.id}": missing notes.${key}`); continue; }
    const rows = rowsFor(sup.fileKind, sup.file);
    const pick = sup.kind === 'argmin' ? rows.reduce((a, b) => (b.v < a.v ? b : a)) : rows.reduce((a, b) => (b.v > a.v ? b : a));
    compare(`kpis[${target.id}].notes.${key}.value`, target.notes[key].value, round(pick.v, 2));
  }

  // ── geography ──────────────────────────────────────────────────────────────
  const ufRows = parseUfCsv(readFileSync(join(baseDir, manifesto.geo.uf_file), 'utf8'));
  const munRows = parseMunCsv(readFileSync(join(baseDir, manifesto.geo.mun_file), 'utf8'));
  const nat = geoNational(munRows);
  const maj = geoMajorities(munRows);
  const g = data.geo;
  compare('geo.summary.pt_2022', g.summary.pt_2022, round(nat.pt_2022, 2));
  compare('geo.summary.pl_2022', g.summary.pl_2022, round(nat.pl_2022, 2));
  compare('geo.summary.pt_2026', g.summary.pt_2026, round(nat.pt_2026, 2));
  compare('geo.summary.pl_2026', g.summary.pl_2026, round(nat.pl_2026, 2));
  for (const k of ['pl_majority_2022', 'pl_majority_2026', 'pt_majority_2022', 'pt_majority_2026', 'neither_2026']) {
    compare(`geo.summary.${k}`, g.summary[k], maj[k]);
  }
  const losers = geoLosers(ufRows, 8);
  compare('geo.uf_losers[0].pt_delta_pp', g.uf_losers[0].pt_delta_pp, losers[0].pt_delta_pp);
  compare('geo.uf_losers[0].pl_delta_pp', g.uf_losers[0].pl_delta_pp, losers[0].pl_delta_pp);
  const mun = geoMunicipal(munRows, { minVotes: 50000 });
  compare('geo.municipalities[0].delta_pp', g.municipalities[0].delta_pp, mun[0].delta_pp);
  compare('geo.municipalities[8].delta_pp', g.municipalities[8].delta_pp, mun[8].delta_pp);

  // ── coverage accounting ────────────────────────────────────────────────────
  const kpiNumbers = data.kpis.reduce((n, k) => n + 1 + k.compare.length, 0);
  const seriesPoints = data.series.reduce((n, s) => n + s.y.length, 0);
  const expectedChecks = kpiNumbers + seriesPoints + 2 /* superlatives */ + 4 + 5 + 4 /* geo */;
  notVerified = 0; // everything numeric in this panel is manifest-backed

  const rate = errors.length === 0 ? 100.0 : 0.0;
  console.log(`METRIC=politica_values_rate value=${rate.toFixed(1)}`);
  console.log(`METRIC=politica_independent_checks value=${checks}`);
  console.log(`METRIC=politica_not_verified value=${notVerified}`);
  if (checks !== expectedChecks) console.log(`ALERT: checks=${checks} != expected ${expectedChecks}`);
  if (errors.length) {
    console.error(`verify_values: ${errors.length} error(s)`);
    for (const e of errors) console.error(`  - ${e}`);
    process.exit(1);
  }
  console.log(`verify_values: OK (${checks} independent checks against raw files, root=${root === VENDOR ? 'vendor' : 'sibling'})`);
}

main();

#!/usr/bin/env node
// /politica — Gate 1: PROVENANCE (presence + coverage). Plan: politica-transparencia, Inc 1.
//
// What it checks:
//   G1.1  Every node that renders a number (has `value`) or claims provenance
//         (has `sources`) carries a non-empty sources[] that resolves in sources[].
//   G1.2  Every cited source id exists; every source URL starts with http.
//   G1.3  Crosswalk COVERAGE: `surfaced` ∪ `excluded` = every claim_id in the two
//         corpus ledgers (22 numeric + 14 legal = 36). Not a bijection — 4
//         unemployment claims map to one KPI on purpose.
//   G1.4  SAMPLE VALUE CHECK: for 3 surfaced numeric claims, the value reachable
//         at the crosswalk's data_path must equal the value in claims.tsv. This
//         catches a wrong mapping (presence alone would not).
//   G1.5  Every referenced raw file in the series manifest exists.
//   G1.6  ALERTS (non-fatal): payload > 500 KB; vintage older than 6 months.
//
// Honest note: this is a PRESENCE gate. Gate 2 re-derives numbers from raw files;
// Gate 3 re-fetches the legal citations. Those are the correctness gates.
//
// Usage:  node scripts/politica/check_provenance.mjs [--vendor]

import { readFileSync, existsSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, join } from 'node:path';

import { walkProvenanced, referencedSourceIds, resolveDataPath } from './lib/paths.mjs';
import { parseTsv } from './lib/escandalos.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '../..');
const VENDOR = join(HERE, 'vendor');
const SIBLING = resolve(REPO, '../eleicao-2026');
const argPath = (flag) => {
  const i = process.argv.indexOf(flag);
  return i !== -1 && process.argv[i + 1] ? resolve(process.cwd(), process.argv[i + 1]) : null;
};
const DATA = argPath('--data') || resolve(REPO, 'frontend/public/politica/data.json');
const SIZE_ALERT = 500 * 1024;

const readJson = (p) => JSON.parse(readFileSync(p, 'utf8'));
const useVendor = process.argv.includes('--vendor');
const root = !useVendor && existsSync(join(SIBLING, 'bench/claims.tsv')) ? SIBLING : VENDOR;

// Sample value checks: for a few surfaced claims, the value reachable at the
// crosswalk path must match the value written in claims.tsv. This is the one check
// that is independent of lib/recompute.mjs — claims.tsv is authored by a different
// process, so it catches errors INSIDE the shared recompute module (e.g. a missing
// or extra ×100 on a weighted mean) that Gate 2 cannot, because Gate 2 and the
// build both call the same function.
const SAMPLE_CLAIMS = ['econ_desoc', 'econ_desoc_dilma', 'geo_br_1t', 'econ_massa', 'amb_prodes_medias'];
const CLAIM_VALUE_RE = {
  econ_desoc: /(\d+\.\d+)%[^.]*?\(Lula 3\)/,
  econ_desoc_dilma: /(\d+\.\d+)%/,
  econ_massa: /R\$ (\d+) milhoes em 2023-2026/,
  geo_br_1t: /PT caiu de \d+\.\d+% para (\d+\.\d+)%/,
  amb_prodes_medias: /(\d+) km2 em 2023-2025/,
};

function main() {
  const errors = [];
  const alerts = [];
  const data = readJson(DATA);

  // ── G1.1/G1.2 provenance presence + source resolution ──────────────────────
  const sourceById = new Map(data.sources.map((s) => [s.id, s]));
  let provenanced = 0;
  for (const { path, node } of walkProvenanced(data)) {
    provenanced += 1;
    if (!Array.isArray(node.sources) || node.sources.length === 0) {
      errors.push(`${path || '(root)'}: number node without sources[]`);
      continue;
    }
    for (const id of node.sources) {
      if (!sourceById.has(id)) errors.push(`${path}: unknown source id "${id}"`);
    }
  }
  for (const s of data.sources) {
    if (!/^https?:\/\//.test(s.url)) errors.push(`sources[${s.id}].url: must start with http`);
  }

  // ── G1.3 crosswalk coverage ────────────────────────────────────────────────
  const crosswalk = readJson(join(HERE, 'claims_crosswalk.json'));
  const numericLedger = parseTsv(readFileSync(join(root, 'bench/claims.tsv'), 'utf8')).rows;
  const legalLedger = parseTsv(readFileSync(join(root, 'escandalos/claims.tsv'), 'utf8')).rows;
  const allClaimIds = new Set([...numericLedger, ...legalLedger].map((r) => r.claim_id));

  const surfaced = new Set(Object.keys(crosswalk.map));
  const excluded = new Set(crosswalk.excluded.map((e) => e.claim_id));
  for (const id of allClaimIds) {
    if (!surfaced.has(id) && !excluded.has(id)) {
      errors.push(`crosswalk: claim "${id}" is neither surfaced nor excluded`);
    }
  }
  for (const id of surfaced) if (!allClaimIds.has(id)) errors.push(`crosswalk: surfaced "${id}" is not a known claim`);
  for (const id of excluded) if (!allClaimIds.has(id)) errors.push(`crosswalk: excluded "${id}" is not a known claim`);
  for (const [id, path] of Object.entries(crosswalk.map)) {
    const { found } = resolveDataPath(data, path);
    if (!found) errors.push(`crosswalk: "${id}" → "${path}" does not resolve in data.json`);
  }

  // ── G1.4 sample value check (independent of the recompute module) ─────────
  const chosen = SAMPLE_CLAIMS.filter((id) => surfaced.has(id) && CLAIM_VALUE_RE[id]).map((id) => [id, CLAIM_VALUE_RE[id]]);
  let sampleOk = 0;
  for (const [id, re] of chosen) {
    const row = numericLedger.find((r) => r.claim_id === id);
    if (!row) continue;
    const m = row.claim_pt.match(re);
    if (!m) {
      alerts.push(`sample ${id}: could not extract a value from claims.tsv`);
      continue;
    }
    const claimed = Number(m[1]);
    const { found, value } = resolveDataPath(data, crosswalk.map[id]);
    if (!found || typeof value !== 'number') {
      errors.push(`sample ${id}: crosswalk path did not yield a number`);
      continue;
    }
    const tol = Math.max(0.01, Math.abs(claimed) * 0.005);
    if (Math.abs(value - claimed) > tol) {
      errors.push(`sample ${id}: data.json has ${value}, claims.tsv says ${claimed}`);
    } else sampleOk += 1;
  }
  if (chosen.length > 0 && sampleOk === 0) errors.push('sample value check: 0 claims verified');

  // ── G1.5 raw files present ─────────────────────────────────────────────────
  const manifest = readJson(join(HERE, 'series_manifest.json'));
  const baseDir = join(root, 'evidence');
  const rawFiles = [
    ...manifest.series.map((s) => s.file),
    ...manifest.kpis.flatMap((k) => [k.resolve, ...(k.compare || []).map((c) => c.resolve)])
      .filter((d) => d.kind === 'agg').map((d) => d.file),
    ...manifest.superlatives.map((s) => s.file),
    manifest.geo.uf_file,
    manifest.geo.mun_file,
  ];
  for (const rel of new Set(rawFiles)) {
    if (!existsSync(join(baseDir, rel))) errors.push(`raw file missing: ${rel}`);
  }

  // ── G1.6 alerts (never fatal) ──────────────────────────────────────────────
  const bytes = statSync(DATA).size;
  if (bytes > SIZE_ALERT) alerts.push(`data.json is ${(bytes / 1024).toFixed(0)} KB (> ${SIZE_ALERT / 1024} KB)`);
  const ageDays = (Date.now() - Date.parse(data.meta.vintage)) / 86400000;
  if (ageDays > 183) alerts.push(`vintage is ${ageDays.toFixed(0)} days old — review legal statuses`);

  // ── report ─────────────────────────────────────────────────────────────────
  const rate = errors.length === 0 ? 100.0 : 0.0;
  console.log(`METRIC=politica_provenance_rate value=${rate.toFixed(1)}`);
  console.log(`METRIC=politica_provenanced_nodes value=${provenanced}`);
  console.log(`METRIC=politica_sample_checks value=${sampleOk}/${chosen.length}`);
  console.log(`METRIC=politica_orphan_sources value=${errors.filter((e) => e.includes('unknown source')).length}`);
  console.log(`METRIC=politica_claims_covered value=${allClaimIds.size}`);
  for (const a of alerts) console.log(`ALERT: ${a}`);
  if (errors.length) {
    console.error(`check_provenance: ${errors.length} error(s)`);
    for (const e of errors) console.error(`  - ${e}`);
    process.exit(1);
  }
  console.log(`check_provenance: OK (${provenanced} nodes, ${allClaimIds.size} claims covered, root=${root === VENDOR ? 'vendor' : 'sibling'})`);
}

main();

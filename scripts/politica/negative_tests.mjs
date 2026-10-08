#!/usr/bin/env node
// /politica — negative tests for the three gates. Plan: politica-transparencia, Inc 1.
//
// Proves the gates go RED when the data lies:
//   A  remove sources from a KPI            → Gate 1 must fail
//   B  change a numeric value in data.json   → Gate 2 must fail
//   C  replace a status citation with a fake → Gate 3 must fail (MISS)
//
// Each variant is written to a temp file and checked by the gate via --data, so
// the committed data.json is never touched. Exits 0 only if every gate behaved.
//
// Usage:  node scripts/politica/negative_tests.mjs

import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, join } from 'node:path';
import { tmpdir } from 'node:os';

const HERE = dirname(fileURLToPath(import.meta.url));
const DATA = resolve(HERE, '../../frontend/public/politica/data.json');
const dir = mkdtempSync(join(tmpdir(), 'politica-neg-'));
const base = JSON.parse(readFileSync(DATA, 'utf8'));
const clone = () => JSON.parse(JSON.stringify(base));

const run = (script, file) => {
  const r = spawnSync(process.execPath, [join(HERE, script), '--data', file], { encoding: 'utf8' });
  return { code: r.status, out: `${r.stdout || ''}${r.stderr || ''}` };
};

const cases = [
  {
    name: 'A — KPI without sources ⇒ Gate 1 fails',
    file: join(dir, 'a.json'),
    make: (d) => { delete d.kpis.find((k) => k.id === 'econ_desoc').sources; return d; },
    script: 'check_provenance.mjs',
    expectFail: true,
  },
  {
    name: 'B — forged KPI value ⇒ Gate 2 fails',
    file: join(dir, 'b.json'),
    make: (d) => { d.kpis.find((k) => k.id === 'econ_desoc').value = 99.99; return d; },
    script: 'verify_values.mjs',
    expectFail: true,
  },
  {
    name: 'C — forged status citation ⇒ Gate 3 fails',
    file: join(dir, 'c.json'),
    make: (d) => { d.cases[0].status_citation_pt = 'frase inventada que nao existe em fonte alguma zzz'; return d; },
    script: 'verify_citations.mjs',
    expectFail: true,
    offline: false,
  },
  {
    // The build and Gate 2 share lib/recompute.mjs, so a unit bug INSIDE that
    // module passes both. This proves Gate 1's sample check (which compares against
    // the independently-authored claims.tsv) catches such a bug: here the geo vote
    // KPI is corrupted with the ×100 mistake that was actually found in review.
    name: 'D — forged vote KPI ⇒ Gate 1 sample check fails',
    file: join(dir, 'd.json'),
    make: (d) => { d.kpis.find((k) => k.id === 'geo_br_1t_pt').value = 4516.5; return d; },
    script: 'check_provenance.mjs',
    expectFail: true,
  },
];

let failures = 0;
for (const c of cases) {
  writeFileSync(c.file, JSON.stringify(c.make(clone())));
  if (process.argv.includes('--skip-live') && c.script === 'verify_citations.mjs') {
    console.log(`SKIP  ${c.name} (live fetch skipped)`);
    continue;
  }
  const { code, out } = run(c.script, c.file);
  const failed = code !== 0;
  const pass = failed === c.expectFail;
  if (!pass) failures += 1;
  const metric = (out.match(/METRIC=\S+ value=\S+/) || [])[0] || out.trim().split('\n').slice(-1)[0];
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${c.name}  (exit=${code})  ${metric}`);
}

if (failures > 0) {
  console.error(`negative_tests: ${failures} gate(s) did not behave as expected`);
  process.exit(1);
}
console.log('negative_tests: OK — all gates fail when the data lies');

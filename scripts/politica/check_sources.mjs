#!/usr/bin/env node
// /politica — case-level source hygiene. Plan: politica-transparencia, Inc 2.
//
// Complements Gate 1 (which checks global presence + crosswalk coverage) with the
// rules that only apply to the legal dossiê:
//   - every sourceId used by a case resolves in data.sources[]
//   - every URL starts with http
//   - a load-bearing case rests on ≥2 independent sources, else WARN (never fail —
//     inventing a second source would be worse than declaring the shortfall)
//   - at least one source per case is official or reference-press
//
// The ≥2 rule is a WARNING by design: the tríplex case rests on a single G1 article
// because no second source exists in the verified corpus. Gate 3 still proves the
// citation is live on that one source, and the panel declares the shortfall.
//
// Usage:  node scripts/politica/check_sources.mjs [--data path.json]

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const argPath = (flag) => {
  const i = process.argv.indexOf(flag);
  return i !== -1 && process.argv[i + 1] ? resolve(process.cwd(), process.argv[i + 1]) : null;
};
const DATA = argPath('--data') || resolve(HERE, '../../frontend/public/politica/data.json');

function main() {
  const data = JSON.parse(readFileSync(DATA, 'utf8'));
  const byId = new Map(data.sources.map((s) => [s.id, s]));
  const errors = [];
  const warnings = [];

  for (const s of data.sources) {
    if (!/^https?:\/\//.test(s.url)) errors.push(`source "${s.id}": url must start with http`);
    if (![1, 2].includes(s.tier)) errors.push(`source "${s.id}": tier must be 1 or 2`);
  }

  for (const c of data.cases) {
    const ids = c.sources || [];
    for (const id of ids) {
      if (!byId.has(id)) errors.push(`case "${c.id}": unknown source id "${id}"`);
    }
    if (ids.length < 2) {
      warnings.push(`case "${c.id}" (${c.status}): rests on ${ids.length} source — a load-bearing status should have ≥2`);
    }
    const tiers = ids.map((id) => byId.get(id)?.tier).filter(Boolean);
    if (tiers.length > 0 && !tiers.some((t) => t === 1 || t === 2)) {
      errors.push(`case "${c.id}": no tier-1/2 source`);
    }
  }

  const rate = errors.length === 0 ? 100.0 : 0.0;
  console.log(`METRIC=politica_sources_rate value=${rate.toFixed(1)}`);
  console.log(`METRIC=politica_single_source_cases value=${warnings.length}`);
  for (const w of warnings) console.log(`WARN: ${w}`);
  if (errors.length) {
    console.error(`check_sources: ${errors.length} error(s)`);
    for (const e of errors) console.error(`  - ${e}`);
    process.exit(1);
  }
  console.log(`check_sources: OK (${data.cases.length} cases, ${data.sources.length} sources)`);
}

main();

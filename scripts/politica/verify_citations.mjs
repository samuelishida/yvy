#!/usr/bin/env node
// /politica — Gate 3: LIVE LEGAL-CITATION VERIFICATION. Plan: politica-transparencia, Inc 1.
//
// This is the only defence against the tautology the research memory warns about:
// checking the corpus `.txt` against itself. Instead it goes to the SOURCE: for
// every legal case, it fetches the cited URLs and confirms the case's
// `status_citation_pt` genuinely appears in the served text.
//
// Mirrors `eleicao-2026/escandalos/verify_citations.py`:
//   OK        → the citation fragment appears on the page
//   MISS-SRC  → page returned substantive text but not the fragment
//   JS        → page is a shell (too little text — STF/STJ portals are SPAs)
//   REDIRECT  → the URL redirected elsewhere
//   HTTPERR   → 4xx/5xx/timeout
// A case PASSES if ANY of its sources returns OK (the STF source is always paired
// with a reference-press source precisely because the portal is an SPA).
// MISS is a hard failure. BLOCKED (all sources JS/redirect/error) is declared and
// reduces coverage but does not fail — otherwise a network-less CI would go red.
//
// Usage:  node scripts/politica/verify_citations.mjs [--offline]

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const argPath = (flag) => {
  const i = process.argv.indexOf(flag);
  return i !== -1 && process.argv[i + 1] ? resolve(process.cwd(), process.argv[i + 1]) : null;
};
const DATA = argPath('--data') || resolve(HERE, '../../frontend/public/politica/data.json');
const TIMEOUT = 25000;
const SCRIPT_THRESHOLD = 1200; // normalised chars below this ⇒ page is a shell
const FRAGMENT_WORDS = 8;
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';

// Strip accents/diacritics and markup — the source page never has our exact bytes.
export function norm(s) {
  return String(s)
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/<[^>]+>/g, ' ')
    .replace(/&[a-z]+;/g, ' ')
    .replace(/[^a-z0-9 ]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

export function fragmentOf(citation) {
  return norm(citation).split(' ').slice(0, FRAGMENT_WORDS).join(' ');
}

async function fetchText(url) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT);
  try {
    const res = await fetch(url, {
      headers: { 'User-Agent': UA, 'Accept-Language': 'pt-BR,pt;q=0.9' },
      redirect: 'follow',
      signal: ctrl.signal,
    });
    const body = await res.text();
    return { ok: true, status: res.status, finalUrl: res.url, body };
  } catch (err) {
    return { ok: false, status: 0, error: err.name || 'fetch error', body: '' };
  } finally {
    clearTimeout(timer);
  }
}

async function classify(url, fragment, cache) {
  if (cache.has(url)) return cache.get(url);
  const { ok, status, finalUrl, body, error } = await fetchText(url);
  const pageNorm = norm(body);
  let verdict;
  if (fragment && pageNorm.includes(fragment)) verdict = 'OK';
  else if (!ok) verdict = 'HTTPERR';
  else if (finalUrl && finalUrl.replace(/\/$/, '') !== url.replace(/\/$/, '')) verdict = 'REDIRECT';
  else if (pageNorm.length < SCRIPT_THRESHOLD) verdict = 'JS';
  else verdict = 'MISS-SRC';
  const out = { url, verdict, len: pageNorm.length, error, status };
  cache.set(url, out);
  return out;
}

async function main() {
  if (process.argv.includes('--offline')) {
    console.log('METRIC=politica_citation_rate value=0.0');
    console.log('METRIC=politica_citation_miss value=0');
    console.log('ALERT: --offline — live citation verification skipped (coverage reduced)');
    return;
  }
  const data = JSON.parse(readFileSync(DATA, 'utf8'));
  const sourceById = new Map(data.sources.map((s) => [s.id, s]));
  const cache = new Map();

  let ok = 0;
  let miss = 0;
  let blocked = 0;
  const misses = [];
  const blockedIds = [];

  for (const c of data.cases) {
    const frag = fragmentOf(c.status_citation_pt);
    const results = [];
    let substantive = false;
    for (const id of c.sources) {
      const src = sourceById.get(id);
      if (!src) continue;
      const r = await classify(src.url, frag, cache);
      results.push(`${id}=${r.verdict}`);
      if (r.verdict === 'OK') substantive = true;
      if (r.verdict === 'MISS-SRC') substantive = true;
    }
    const hasOk = results.some((r) => r.endsWith('=OK'));
    let verdict;
    if (hasOk) { verdict = 'OK'; ok += 1; }
    else if (substantive) { verdict = 'MISS'; miss += 1; misses.push(c.id); }
    else { verdict = 'BLOCKED'; blocked += 1; blockedIds.push(c.id); }
    console.log(`${verdict.padEnd(8)} ${c.id.padEnd(24)} ${results.join(' ')}`);
  }

  const total = data.cases.length;
  const rate = total === 0 ? 100 : (ok / total) * 100;
  console.log('---');
  console.log(`METRIC=politica_citation_rate value=${rate.toFixed(1)}`);
  console.log(`METRIC=politica_citation_miss value=${miss}`);
  console.log(`METRIC=politica_citation_blocked value=${blocked}`);
  console.log(`METRIC=politica_citation_ok value=${ok}/${total}`);
  if (blocked > 0) console.log(`ALERT: ${blocked} case(s) had no fetchable source: ${blockedIds.join(', ')}`);
  if (miss > 0) {
    console.error(`verify_citations: ${miss} case(s) whose status citation is NOT on any cited source: ${misses.join(', ')}`);
    process.exit(1);
  }
  console.log('verify_citations: OK (no MISS)');
}

main();

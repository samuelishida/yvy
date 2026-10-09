#!/usr/bin/env node
// /politica — Gate 4: RENDERED-DOM SNAPSHOT. Plan: politica-transparencia, Inc 8.
//
// The "number hard-coded in the view" risk cannot be checked with a regex over JSX:
// `height={260}`, `strokeWidth={2}`, array indices and logic all produce false
// positives. So instead this gate actually RENDERS the panel's section components
// with react-dom/server against a known data.json, extracts the visible text, and
// flags any digit-sequence in that text that does not occur anywhere in the JSON.
//
// Consequence: a literal like `6.7` typed into a component fails the gate; a value
// that came from data.json passes.
//
// It runs INSIDE the frontend (needs react-dom + @babel/core). A require hook
// transpiles only files under frontend/src; CSS/asset imports are stubbed.
//
// Usage:  node scripts/politica/verify_render.mjs   (run from the repo root)

import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, resolve } from 'node:path';
import { createRequire } from 'node:module';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '../..');
const FRONTEND = resolve(REPO, 'frontend');
const SRC = resolve(FRONTEND, 'src');
const DATA = resolve(FRONTEND, 'public/politica/data.json');

if (!existsSync(resolve(FRONTEND, 'node_modules'))) {
  console.error('verify_render: frontend/node_modules missing — run `npm ci` first');
  process.exit(1);
}

const require = createRequire(resolve(FRONTEND, 'package.json'));

// ── require hook: transpile ONLY frontend/src; stub CSS + assets ──────────────
const babel = require('@babel/core');
const origJs = require.extensions['.js'];
require.extensions['.js'] = function politHijack(module, filename) {
  if (!filename.startsWith(SRC) || filename.includes('node_modules')) {
    return origJs(module, filename);
  }
  const code = readFileSync(filename, 'utf8');
  const out = babel.transformSync(code, {
    filename,
    babelrc: false,
    configFile: false,
    presets: [
      [require.resolve('@babel/preset-env'), { targets: { node: 'current' } }],
      [require.resolve('@babel/preset-react'), { runtime: 'automatic' }],
    ],
  });
  return module._compile(out.code, filename);
};
for (const ext of ['.css', '.svg', '.png', '.jpg', '.jpeg', '.gif', '.webp']) {
  require.extensions[ext] = () => {};
}

const React = require('react');
const { renderToStaticMarkup } = require('react-dom/server');

// ── load components + provider ──────────────────────────────────────────────
const { I18nProvider, translations } = require(resolve(SRC, 'i18n.js'));
const { PoliticaContext, PoliticaBody } = require(resolve(SRC, 'components/Politica/Politica.js'));
const SECTIONS = [
  ['Kpis', require(resolve(SRC, 'components/Politica/PoliticaKpis.js')).default],
  ['Series', require(resolve(SRC, 'components/Politica/PoliticaSeries.js')).default],
  ['Dossier', require(resolve(SRC, 'components/Politica/PoliticaDossier.js')).default],
  ['Sources', require(resolve(SRC, 'components/Politica/PoliticaSources.js')).default],
];

// The section list above renders each part in isolation; this additionally renders
// the WHOLE page body (provider + all sections) so a context/wiring bug in the
// shell fails the gate rather than only showing up in a browser.
const FULL_PAGE = [['PageBody', PoliticaBody]];

const data = JSON.parse(readFileSync(DATA, 'utf8'));

function renderWithLanguage(lang, render) {
  const previous = global.localStorage;
  global.localStorage = { getItem: () => lang, setItem: () => {} };
  try {
    return render();
  } finally {
    if (previous === undefined) delete global.localStorage;
    else global.localStorage = previous;
  }
}

// ── render each section, collect visible text ───────────────────────────────
function renderSection(Comp, lang) {
  const el = React.createElement(
    I18nProvider,
    null,
    React.createElement(
      PoliticaContext.Provider,
      { value: { data, lang } },
      React.createElement(Comp),
    ),
  );
  return renderWithLanguage(lang, () => renderToStaticMarkup(el));
}

// Full page: renders PoliticaBody, which creates its own provider — so this hits
// the same code path the browser does (and would surface a broken context call).
function renderFullPage(lang) {
  const el = React.createElement(
    I18nProvider,
    null,
    React.createElement(PoliticaBody, { data, lang }),
  );
  return renderWithLanguage(lang, () => renderToStaticMarkup(el));
}

// Strip tags so we inspect only the text a reader sees (props never reach here,
// which is exactly why this beats a regex over the JSX source).
function visibleText(html) {
  return html
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&#x27;|&#39;/g, "'")
    .replace(/&quot;/g, '"');
}

// ── numeric comparison ──────────────────────────────────────────────────────
// The rendered text is produced by formatters (rounding, locale separators, unit
// scaling), so a digit-string equality test would be all false positives. Instead
// we compare NUMERICALLY with a tolerance of half the last displayed decimal.
//
// Crucially, props never reach `renderToStaticMarkup`'s text output — so `height={260}`
// and `strokeWidth={2}` cannot even be seen here. That is the whole reason to
// render instead of grepping the JSX.
function collectNumbers(node, out = []) {
  if (typeof node === 'number') { if (Number.isFinite(node)) out.push(node); return out; }
  if (typeof node === 'string') return out;
  if (Array.isArray(node)) { node.forEach((c) => collectNumbers(c, out)); return out; }
  if (node && typeof node === 'object') { Object.values(node).forEach((c) => collectNumbers(c, out)); }
  return out;
}

// Candidates a formatter may produce from a stored number: itself (rounded), and
// the scaled money forms. A rendered number must be near one of these.
function allowedSet(numbers) {
  const set = [];
  for (const n of numbers) {
    set.push(n, n * 1e6, n * 1e9, n * 1e12, n / 1e6);
  }
  return set;
}

// A token like "4.702,6" is ambiguous across locales. Return every plausible float.
function candidateFloats(raw) {
  const out = new Set();
  const pt = raw.replace(/\./g, '').replace(',', '.');
  const en = raw.replace(/,/g, '');
  if (/^-?\d+(\.\d+)?$/.test(pt)) out.add(Number(pt));
  if (/^-?\d+(\.\d+)?$/.test(en)) out.add(Number(en));
  const bare = Number(raw.replace(/[.,]/g, ''));
  if (Number.isFinite(bare)) out.add(bare);
  return [...out];
}

function decimalsOf(s) {
  const m = s.match(/[.,](\d+)$/);
  return m ? m[1].length : 0;
}

// Tolerance blends: half the last shown decimal, a small fraction of the value
// (so a scaled money figure like 6.2 bi matches 6.2e9/1e9), and a flat floor that
// absorbs integer rounding of large counts (11617.45 → 11617).
function nearAllowed(cand, decimals, allowed) {
  const tol = Math.max(0.5 * 10 ** -decimals, Math.abs(cand) * 0.001, 0.6);
  return allowed.some((a) => Math.abs(a - cand) <= tol);
}

function escapeAttr(value) {
  return String(value).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function caseMarkup(html, caseId) {
  const marker = `data-case-id="${caseId}"`;
  const at = html.indexOf(marker);
  if (at < 0) return null;
  const start = html.lastIndexOf('<article', at);
  const close = html.indexOf('</article>', at);
  return start < 0 || close < 0 ? null : html.slice(start, close + '</article>'.length);
}

// Collect every number the JSON can legitimately produce: numeric leaves AND
// digit tokens embedded in strings ("2005–2014", "38 réus", "R$ 6,2 bi"). The
// latter are just as data-driven as the former — both live in data.json.
function allowedNumbers(data) {
  const out = collectNumbers(data);
  const scanStrings = (node) => {
    if (typeof node === 'string') {
      for (const raw of node.match(/\d+(?:[.,]\d+)*/g) || []) out.push(...candidateFloats(raw));
      return;
    }
    if (Array.isArray(node)) { node.forEach(scanStrings); return; }
    if (node && typeof node === 'object') Object.values(node).forEach(scanStrings);
  };
  scanStrings(data);
  // scaled money forms
  const scaled = [];
  for (const n of out) scaled.push(n * 1e6, n * 1e9, n * 1e12, n / 1e6, n / 1e9);
  return [...out, ...scaled];
}

function main() {
  const errors = [];
  let renderedChars = 0;

  // Numbers may come from data.json OR from the i18n chrome dictionary
  // (`translations`, e.g. ">50%"). Both are content sources; a number typed into a
  // component appears in neither.
  const allowed = [...allowedNumbers(data), ...allowedNumbers(translations)];

  for (const lang of ['pt', 'en']) {
    for (const [name, Comp] of [...SECTIONS, ...FULL_PAGE]) {
      let html;
      try {
        html = name === 'PageBody' ? renderFullPage(lang) : renderSection(Comp, lang);
      } catch (err) {
        errors.push(`${name} [${lang}]: render threw — ${err.message}`);
        continue;
      }
      const text = visibleText(html);
      renderedChars += text.length;
      const matches = text.match(/\d+(?:[.,]\d+)*/g) || [];
      for (const raw of matches) {
        const d = decimalsOf(raw);
        const ok = candidateFloats(raw).some((c) => nearAllowed(c, d, allowed));
        if (!ok) {
          errors.push(`${name} [${lang}]: rendered number "${raw}" does not match any value in data.json (hard-coded?)`);
        }
      }
    }
  }

  if (renderedChars < 500) errors.push(`render produced only ${renderedChars} chars — components likely failed to render`);

  // Assert legal-card content, translations, evidence labels, and direct status
  // links in both locales. `SourceRef` normally collapses sources after the first
  // into a count; status-source wrappers ensure each required link is visible.
  const Dossier = SECTIONS.find((s) => s[0] === 'Dossier')[1];
  const caseById = new Map(data.cases.map((c) => [c.id, c]));
  const sourceById = new Map(data.sources.map((s) => [s.id, s]));
  for (const lang of ['pt', 'en']) {
    const html = renderSection(Dossier, lang);
    const dossierText = visibleText(html);
    if (/"status":/i.test(dossierText)) errors.push(`dossier [${lang}]: raw enum leaked as JSON`);
    if (dossierText.includes('politica.')) errors.push(`dossier [${lang}]: an i18n key leaked raw`);
    const cardCount = (html.match(/data-case-id=/g) || []).length;
    if (cardCount !== 7) errors.push(`dossier [${lang}]: expected 7 case cards, found ${cardCount}`);

    for (const c of data.cases) {
      const article = caseMarkup(html, c.id);
      if (!article) {
        errors.push(`dossier [${lang}]: case ${c.id} did not render`);
        continue;
      }
      const text = visibleText(article);
      const dict = translations[lang].politica;
      if (!text.includes(dict[`status_${c.status}`] || '')) errors.push(`dossier [${lang}]: missing status label for ${c.id}`);
      if (!text.includes(dict[`statusPhrase_${c.status}`] || '')) errors.push(`dossier [${lang}]: missing status phrase for ${c.id}`);
      for (const e of c.evidence || []) {
        if (!text.includes(dict[`state_${e.state}`] || '')) errors.push(`dossier [${lang}]: missing evidence label ${e.state} on ${c.id}`);
        const artifact = lang === 'en' ? e.artifact_en || e.artifact_pt : e.artifact_pt;
        if (artifact && !text.includes(artifact)) errors.push(`dossier [${lang}]: missing evidence text on ${c.id}`);
      }

      if (['flavio_master', 'flavio_imoveis'].includes(c.id)) {
        const citation = lang === 'en' ? c.status_citation_en : c.status_citation_pt;
        const citationAt = article.indexOf(citation);
        if (citationAt < 0) errors.push(`dossier [${lang}]: missing status quote on ${c.id}`);
        for (const id of c.status_sources || []) {
          const source = sourceById.get(id);
          if (!source) {
            errors.push(`dossier [${lang}]: unknown status source ${id} on ${c.id}`);
            continue;
          }
          const sourceMarker = `data-source-id="${id}"`;
          const sourceAt = article.indexOf(sourceMarker);
          if (sourceAt < 0 || citationAt < 0 || sourceAt < citationAt || sourceAt - citationAt > 1600) {
            errors.push(`dossier [${lang}]: status source ${id} is not linked beside ${c.id} quote`);
            continue;
          }
          const href = `href="${escapeAttr(source.url)}"`;
          if (!article.includes(href, sourceAt)) errors.push(`dossier [${lang}]: status source ${id} has no direct URL on ${c.id}`);
        }
      }
    }
  }

  const master = caseById.get('flavio_master');
  if (!master || master.status !== 'sob_investigacao') errors.push('data: missing flavio_master investigation status');
  else if (!master.evidence.some((e) => e.state === 'alegado_em_apuracao')) errors.push('data: master allegations lack alegado_em_apuracao state');
  const properties = caseById.get('flavio_imoveis');
  if (!properties || !properties.evidence.some((e) => e.state === 'anulado')) errors.push('data: property card lacks separate annulled-evidence item');

  const rate = errors.length === 0 ? 100.0 : 0.0;
  console.log(`METRIC=politica_render_rate value=${rate.toFixed(1)}`);
  console.log(`METRIC=politica_render_chars value=${renderedChars}`);
  if (errors.length) {
    console.error(`verify_render: ${errors.length} error(s)`);
    for (const e of errors.slice(0, 40)) console.error(`  - ${e}`);
    if (errors.length > 40) console.error(`  … ${errors.length - 40} more`);
    process.exit(1);
  }
  console.log('verify_render: OK (no hard-coded numbers, no raw i18n keys)');
}

main();

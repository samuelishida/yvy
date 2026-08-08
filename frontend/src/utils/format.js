// Locale-aware formatting helpers (plan: dashboard-enhancement, Inc 1).
// Replace the hardcoded toLocaleString('pt-BR') calls so EN mode formats
// numbers the way an English reader expects. `lang` comes from useI18n().

function intLocale(lang) {
  return lang === 'en' ? 'en-US' : 'pt-BR';
}

// Safe integer: null/undefined/NaN → '—', never "NaN" or "undefined".
export function formatInt(n, lang) {
  const num = Number(n);
  if (!Number.isFinite(num)) return '—';
  return num.toLocaleString(intLocale(lang));
}

// km² with thousands separators + unit.
export function formatKm2(n, lang) {
  const num = Number(n);
  if (!Number.isFinite(num)) return '—';
  return `${num.toLocaleString(intLocale(lang))} km²`;
}

// Percentage with one decimal, safe on NaN/Infinity.
export function formatPct(n, lang) {
  const num = Number(n);
  if (!Number.isFinite(num)) return '—';
  return `${num.toFixed(1)}%`;
}

// Period-over-period delta: { pct, direction } where direction is
// 'up' | 'down' | 'flat' | 'unknown'. `unknown` when there is no valid
// baseline (previous is 0/nullish) — the caller renders "no prior data",
// never a fake "+∞%". `goodDirection` is decided by the caller per metric
// (down is good for deforestation, bad for protected-area fires, etc.).
export function formatDelta(current, previous) {
  const cur = Number(current);
  const prev = Number(previous);
  if (!Number.isFinite(cur) || !Number.isFinite(prev) || prev === 0) {
    return { pct: null, direction: 'unknown' };
  }
  const pct = ((cur - prev) / prev) * 100;
  if (Math.abs(pct) < 0.05) return { pct: 0, direction: 'flat' };
  return { pct, direction: pct > 0 ? 'up' : 'down' };
}

// Signed display for a delta percentage ("+12.3%", "-5.0%", "0%").
export function formatDeltaPct(pct, lang) {
  const num = Number(pct);
  if (!Number.isFinite(num)) return '—';
  const sign = num > 0 ? '+' : '';
  return `${sign}${num.toFixed(1)}%`;
}

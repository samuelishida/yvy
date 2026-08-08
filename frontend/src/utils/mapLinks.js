// Map deep-link helpers (plan: dashboard-enhancement, Inc 9).
// Centralizes ?focus=<kind>:<id> construction so card drilldown is consistent
// and middle-click / open-in-new-tab work. `days` is carried over so the map
// session can keep the dashboard's range in the URL.

function esc(v) {
  return encodeURIComponent(v);
}

function base(kind, id, days) {
  const p = new URLSearchParams();
  p.set('focus', `${kind}:${id}`);
  if (days) p.set('days', String(days));
  return `/?${p.toString()}`;
}

export function mapUrlForState(uf, days) {
  if (!uf) return '/';
  return base('state', uf, days);
}

export function mapUrlForBiome(name, days) {
  if (!name) return '/';
  return base('biome', name, days);
}

export function mapUrlForLand({ name, lat, lon } = {}, days) {
  const n = Number(lat);
  const m = Number(lon);
  if (Number.isFinite(n) && Number.isFinite(m)) {
    const p = new URLSearchParams();
    p.set('focus', `land:${esc(String(name || ''))}`);
    p.set('lat', n.toFixed(4));
    p.set('lng', m.toFixed(4));
    p.set('zoom', '8');
    if (days) p.set('days', String(days));
    return `/?${p.toString()}`;
  }
  if (!name) return '/';
  return base('land', name, days);
}

// Safe decode of a ?focus=kind:id value; returns null when malformed.
export function parseFocus(raw) {
  if (!raw || typeof raw !== 'string') return null;
  const idx = raw.indexOf(':');
  if (idx <= 0 || idx === raw.length - 1) return null;
  return { kind: raw.slice(0, idx), id: decodeURIComponent(raw.slice(idx + 1)) };
}

// Approximate UF centroids (lat, lon) — used to center the map on a state
// drilldown. Rough is fine: the goal is "put MT in the middle of the viewport".
export const UF_CENTROIDS = {
  AC: [-9.0, -70.0], AL: [-9.6, -36.7], AP: [1.0, -52.0], AM: [-4.0, -63.0],
  BA: [-12.5, -41.5], CE: [-5.0, -39.5], DF: [-15.8, -47.9], ES: [-19.5, -40.5],
  GO: [-16.0, -49.3], MA: [-5.5, -45.5], MT: [-12.5, -55.5], MS: [-20.5, -54.5],
  MG: [-18.5, -44.0], PA: [-3.0, -52.5], PB: [-7.0, -36.0], PR: [-24.5, -51.5],
  PE: [-8.5, -37.0], PI: [-7.5, -43.0], RJ: [-22.0, -42.0], RN: [-5.5, -36.0],
  RS: [-30.0, -53.0], RO: [-10.5, -62.5], RR: [2.0, -61.0], SC: [-27.0, -50.5],
  SP: [-22.0, -48.5], SE: [-10.5, -37.5], TO: [-10.0, -48.0],
};

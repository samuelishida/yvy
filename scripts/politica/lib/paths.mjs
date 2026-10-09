// /politica — shared helpers for the provenance/value gates.

// Resolve a crosswalk/manifest data path against the panel JSON.
// Grammar: `name` · `name.foo` · `kpis[id].value` · `cases[id].financial[0]`
//   · `series[id]` · `geo.uf_losers[0]`
// Returns { found: boolean, value } — never throws on a missing path.
export function resolveDataPath(data, path) {
  const segments = splitPath(path);
  let cur = data;
  for (const seg of segments) {
    if (cur == null) return { found: false, value: undefined };
    if (Array.isArray(seg)) {
      const [name, key] = seg;
      if (name) {
        // object keyed by id, e.g. `kpis[econ_desoc]`
        const container = cur[name];
        if (Array.isArray(container)) {
          const hit = container.find((x) => x && x.id === key);
          if (!hit) return { found: false, value: undefined };
          cur = hit;
        } else if (container && typeof container === 'object') {
          cur = container[key];
        } else {
          return { found: false, value: undefined };
        }
      } else {
        // numeric index, e.g. `[0]`
        const idx = Number(key);
        if (!Array.isArray(cur) || !Number.isInteger(idx) || idx < 0 || idx >= cur.length) {
          return { found: false, value: undefined };
        }
        cur = cur[idx];
      }
      continue;
    }
    if (typeof cur !== 'object' || !(seg in cur)) return { found: false, value: undefined };
    cur = cur[seg];
  }
  return { found: true, value: cur };
}

function splitPath(path) {
  const out = [];
  for (const raw of String(path).split('.')) {
    const m = raw.match(/^([A-Za-z0-9_]+)(?:\[([^\]]*)\])?$/);
    if (!m) {
      out.push(raw);
      continue;
    }
    const [, name, key] = m;
    if (key === undefined) {
      out.push(name); // plain field traversal
    } else if (/^\d+$/.test(key)) {
      out.push(name); // traverse into the field first …
      out.push([null, key]); // … then index the array
    } else {
      out.push([name, key]); // id lookup: `kpis[econ_desoc]`
    }
  }
  return out;
}

// Walk every node and collect { path, node } for objects that carry a `sources`
// field, plus any leaf carrying a numeric `value` (which must be provenance-bearing).
// The root is NOT visited as a node: its `sources` is the catalog, not a claim.
export function walkProvenanced(data) {
  const found = [];
  const visit = (node, path) => {
    if (Array.isArray(node)) {
      node.forEach((child, i) => visit(child, `${path}[${i}]`));
      return;
    }
    if (node && typeof node === 'object') {
      const hasSources = Array.isArray(node.sources) && node.sources.every((s) => typeof s === 'string');
      const hasValue = 'value' in node && typeof node.value === 'number';
      if (hasSources || hasValue) found.push({ path, node });
      for (const [k, v] of Object.entries(node)) visit(v, path ? `${path}.${k}` : k);
    }
  };
  for (const [k, v] of Object.entries(data)) visit(v, k);
  return found;
}

// Collect every sourceId referenced anywhere under a node with `sources`.
export function referencedSourceIds(data) {
  const ids = new Set();
  for (const { node } of walkProvenanced(data)) {
    if (Array.isArray(node.sources)) for (const id of node.sources) ids.add(id);
  }
  return ids;
}

// Tiny in-memory fetch dedup with TTL.
// Multiple components requesting the same URL within the TTL window share a single in-flight promise + result.

const cache = new Map();

export function cachedFetch(url, { ttl = 60_000, signal } = {}) {
  const now = Date.now();
  const entry = cache.get(url);

  if (entry) {
    if (entry.promise) {
      return entry.promise;
    }
    if (now - entry.ts < ttl) {
      return Promise.resolve(entry.data);
    }
  }

  const promise = fetch(url, { signal })
    .then(r => {
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return r.json();
    })
    .then(data => {
      cache.set(url, { data, ts: Date.now(), promise: null });
      return data;
    })
    .catch(err => {
      cache.delete(url);
      throw err;
    });

  cache.set(url, { ...(entry || {}), promise });
  return promise;
}

export function invalidateApiCache(url) {
  if (url) cache.delete(url);
  else cache.clear();
}

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

  /* Retry on 429 with exponential backoff (up to 3 attempts).
   * Tiles and dashboard API bursts can hit rate limits; retrying
   * is better than dropping the request silently. */
  const MAX_RETRIES = 3;
  const doFetch = (attempt = 0) =>
    fetch(url, { signal })
      .then(r => {
        if (r.status === 429 && attempt < MAX_RETRIES) {
          const wait = Math.min(500 * Math.pow(2, attempt), 4000);
          return new Promise(resolve => setTimeout(resolve, wait)).then(() => doFetch(attempt + 1));
        }
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json();
      });

  const promise = doFetch()
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

/** Simple localStorage cache with TTL */
const CACHE_PREFIX = 'yvy_cache_';

export function getCache(key, ttlMinutes = 5) {
  try {
    const raw = localStorage.getItem(CACHE_PREFIX + key);
    if (!raw) return null;
    const { data, ts } = JSON.parse(raw);
    const ageMin = (Date.now() - ts) / 60000;
    if (ageMin > ttlMinutes) {
      localStorage.removeItem(CACHE_PREFIX + key);
      return null;
    }
    return data;
  } catch {
    return null;
  }
}

// Defer to idle: JSON.stringify + localStorage.setItem are sync and can block
// 200-500ms when caching large payloads (e.g., 50k fires).
const _scheduleIdle = (cb) => {
  if (typeof requestIdleCallback === 'function') requestIdleCallback(cb, { timeout: 2000 });
  else setTimeout(cb, 0);
};

export function setCache(key, data) {
  _scheduleIdle(() => {
    try {
      localStorage.setItem(CACHE_PREFIX + key, JSON.stringify({ data, ts: Date.now() }));
    } catch {}
  });
}

/** Synchronous cache write — use when the payload is small (e.g. news, not fires).
 *  Deferred writes (setCache) can miss if the user navigates away before the
 *  idle callback fires, leaving stale data for the next mount. */
export function setCacheSync(key, data) {
  try {
    localStorage.setItem(CACHE_PREFIX + key, JSON.stringify({ data, ts: Date.now() }));
  } catch {}
}

export function clearCache(key) {
  localStorage.removeItem(CACHE_PREFIX + key);
}

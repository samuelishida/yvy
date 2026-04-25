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

export function setCache(key, data) {
  try {
    localStorage.setItem(CACHE_PREFIX + key, JSON.stringify({ data, ts: Date.now() }));
  } catch {
    // ignore quota errors
  }
}

export function clearCache(key) {
  localStorage.removeItem(CACHE_PREFIX + key);
}

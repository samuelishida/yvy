import { useEffect, useState, useCallback, useRef } from 'react';
import { cachedFetch, invalidateApiCache } from '../../utils/apiCache';

// Data-fetch hook that collapses the fetch/abort/error/retry boilerplate
// duplicated across dashboard cards (plan: dashboard-enhancement, Inc 1).
// Re-runs whenever `url` changes — which is how filter changes refetch.
//
// cardState: 'loading' | 'ready' | 'empty' | 'error' | 'idle'
//   - `empty` when the resolved data satisfies `isEmpty` (default: null/undefined)
//   - `error` keeps the last good `data` so a transient failure doesn't blank the card
//
// `isEmpty` is read via a ref so inline predicates don't re-trigger the effect
// (a new function identity every render would otherwise cause an infinite loop).
export default function useCardData(
  url,
  { ttl = 120_000, enabled = true, isEmpty } = {},
) {
  const [data, setData] = useState(null);
  const [cardState, setCardState] = useState(enabled && url ? 'loading' : 'idle');
  const [nonce, setNonce] = useState(0);
  const abortRef = useRef(null);
  const isEmptyRef = useRef(isEmpty || ((d) => d == null));
  useEffect(() => {
    isEmptyRef.current = isEmpty || ((d) => d == null);
  });

  useEffect(() => {
    if (!enabled || !url) {
      setCardState('idle');
      return undefined;
    }
    const ac = new AbortController();
    abortRef.current = ac;
    setCardState('loading');

    cachedFetch(url, { ttl, signal: ac.signal })
      .then((d) => {
        if (ac.signal.aborted) return;
        setData(d);
        setCardState(isEmptyRef.current(d) ? 'empty' : 'ready');
      })
      .catch((err) => {
        if (err.name !== 'AbortError') setCardState('error');
      });

    return () => ac.abort();
    // nonce re-triggers the effect on retry; isEmpty deliberately excluded (ref).
  }, [url, ttl, enabled, nonce]);

  const retry = useCallback(() => {
    if (url) invalidateApiCache(url);
    setNonce((n) => n + 1);
  }, [url]);

  return { data, cardState, retry };
}

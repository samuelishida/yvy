import React, { createContext, useContext, useMemo } from 'react';
import { useI18n } from '../../i18n';
import useCardData from './useCardData';

// Data-source freshness (plan: dashboard-enhancement, Inc 8).
// Fetches /api/dashboard/freshness once and exposes per-source availability +
// attribution coverage. Cards that can't serve a filter (DETER/AMS/CAR with
// empty tables) read `available(id)` and render the CardShell `unavailable`
// state instead of a misleading empty chart.

const FreshnessContext = createContext({ sources: {}, coverage: {}, available: () => true });

export function FreshnessProvider({ children }) {
  const { data } = useCardData('/api/dashboard/freshness', { ttl: 300_000 });

  const value = useMemo(() => {
    const sources = {};
    if (data && Array.isArray(data.sources)) {
      for (const s of data.sources) sources[s.id] = s;
    }
    return {
      sources,
      coverage: (data && data.coverage) || {},
      ready: !!(data && Array.isArray(data.sources)),
      available: (id) => !!(sources[id] && sources[id].available),
    };
  }, [data]);

  return <FreshnessContext.Provider value={value}>{children}</FreshnessContext.Provider>;
}

export function useFreshness() {
  return useContext(FreshnessContext);
}

const SOURCE_ORDER = ['firms', 'news', 'deter', 'deter_car', 'ams'];

function isStale(iso) {
  const t = new Date(iso).getTime();
  if (!Number.isFinite(t)) return false;
  return Date.now() - t > 48 * 3600 * 1000; // >48h = stale
}

function relativeLabel(iso, t) {
  const ms = Date.now() - new Date(iso).getTime();
  if (!Number.isFinite(ms) || ms < 0) return t('dashboard.justNow');
  const h = Math.floor(ms / 3600_000);
  if (h < 1) return t('dashboard.updatedMinutes');
  if (h < 24) return `${h}h`;
  return `${Math.floor(h / 24)}d`;
}

export default function FreshnessBar() {
  const { t } = useI18n();
  const { sources, coverage } = useFreshness();

  return (
    <div className="dash-freshness">
      <span className="dash-freshness__label">{t('dashboard.dataSource')}</span>
      {SOURCE_ORDER.map((id) => {
        const s = sources[id];
        if (!s) return null;
        const cls = !s.available
          ? 'is-empty'
          : isStale(s.last_ingested_at) ? 'is-stale' : 'is-fresh';
        const title = s.available
          ? `${id} · ${relativeLabel(s.last_ingested_at, t)}`
          : `${id} · ${t('dashboard.unavailable')}`;
        return (
          <span key={id} className={`dash-freshness__dot ${cls}`} title={title}>
            {id}
          </span>
        );
      })}
      {coverage.state_pct != null && (
        <span className="dash-freshness__coverage" title={t('dashboard.coverageHint')}>
          {t('dashboard.coverageState')} {(coverage.state_pct * 100).toFixed(0)}%
        </span>
      )}
    </div>
  );
}

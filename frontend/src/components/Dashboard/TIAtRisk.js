import React, { useMemo } from 'react';
import { Link } from 'react-router-dom';
import { useI18n } from '../../i18n';
import { useDashboardFilters } from './DashboardFilters';
import { useFreshness } from './FreshnessBar';
import useCardData from './useCardData';
import CardShell from './CardShell';
import { mapUrlForLand } from '../../utils/mapLinks';
import { formatInt } from '../../utils/format';

export default function TIAtRisk() {
  const { t } = useI18n();
  const { lang } = useI18n();
  const { days } = useDashboardFilters();
  const { ready: freshReady, available } = useFreshness();

  // Redis-only route; cold cache serves stale/empty + refreshes in background.
  const url = `/api/fires/ti-at-risk?days=${days}&limit=10`;
  const { data, cardState, retry } = useCardData(url, {
    ttl: 120_000,
    isEmpty: (d) => !d || !Array.isArray(d.lands) || d.lands.length === 0,
  });

  const firmsAvail = freshReady ? available('firms') : true;
  const lands = useMemo(() => (data ? data.lands || [] : []), [data]);
  const finalState = cardState === 'empty' && !firmsAvail ? 'unavailable' : cardState;
  const maxCount = useMemo(() => Math.max(...lands.map((l) => l.fire_count || 0), 1), [lands]);

  return (
    <CardShell
      title={t('dashboard.tiAtRisk')}
      state={finalState}
      onRetry={retry}
      freshness={{ windowLabel: t(`dashboard.range${days}d`) }}
      exportData={{
        filename: `yvy-ti-at-risk-${days}d.csv`,
        rows: lands.map((l) => ({ name: l.name, state: l.state_abbr, fires: l.fire_count })),
      }}
    >
      <div className="ti-table" role="img" aria-label={lands.map((l) => `${l.name}: ${l.fire_count}`).join(', ')}>
        {lands.map((l, idx) => {
          const pct = ((l.fire_count || 0) / maxCount) * 100;
          return (
            <div key={l.name || idx} className="ti-row">
              <div className="ti-rank">{idx + 1}</div>
              <div className="ti-info">
                <div className="ti-name">
                  <Link to={mapUrlForLand(l, days)} className="ti-link">{l.name}</Link>
                </div>
                <div className="ti-meta">
                  {l.state_abbr || ''} · {formatInt(l.fire_count || 0, lang)} {t('dashboard.firesUnit')}
                </div>
              </div>
              <div className="ti-bar-wrap">
                <div className="ti-bar" style={{ width: `${pct}%` }} />
              </div>
            </div>
          );
        })}
      </div>
    </CardShell>
  );
}

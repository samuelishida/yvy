import React, { useMemo } from 'react';
import { useNavigate } from 'react-router-dom';
import { useI18n } from '../../i18n';
import { useDashboardFilters } from './DashboardFilters';
import useCardData from './useCardData';
import CardShell from './CardShell';
import { mapUrlForState } from '../../utils/mapLinks';
import { formatInt } from '../../utils/format';

// Ordem de exibição das classes; cores espelham FIRE_NATURE_COLORS do mapa.
const CLASS_ORDER = ['crime', 'suspeito', 'permitido', 'natural', 'unclassified'];

const CLASS_COLORS = {
  crime:        '#ef4444',
  suspeito:     '#f97316',
  permitido:    '#22c55e',
  natural:      '#38bdf8',
  unclassified: '#9ca3af',
};

export default function NatureStats() {
  const { t } = useI18n();
  const { lang } = useI18n();
  const { days, state, queryString } = useDashboardFilters();
  const navigate = useNavigate();
  const scope = t('dashboard.scopeLabel', {
    window: t(`dashboard.range${days}d`),
    region: state || t('dashboard.allBrazil'),
  });

  const url = `/api/fires/nature-stats?${queryString}`;
  const { data, cardState, retry } = useCardData(url, {
    ttl: 120_000,
    isEmpty: (d) => !d || !d.classes,
  });

  const classes = useMemo(
    () => CLASS_ORDER.map((k) => ({ key: k, count: (data && data.classes && data.classes[k]) || 0 })).filter((c) => c.count > 0),
    [data],
  );
  const classMax = useMemo(() => Math.max(...classes.map((c) => c.count), 1), [classes]);
  // by_state is null when a single state is selected (backend only returns the
  // per-state breakdown for the national view).
  const byState = useMemo(
    () => (data && Array.isArray(data.by_state) ? data.by_state : null),
    [data],
  );

  const exportRows = [
    ...classes.map((c) => ({ class: c.key, fires: c.count })),
    ...(byState || []).map((st) => ({ state: st.state, total: st.total })),
  ];

  return (
    <CardShell
      title={t('dashboard.natureStats')}
      subtitle={t('dashboard.natureStatsSub')}
      state={cardState}
      onRetry={retry}
      freshness={{ windowLabel: scope }}
      exportData={{ filename: `yvy-nature-detail-${queryString.replace(/[=&]/g, '-')}.csv`, rows: exportRows }}
    >
      <div className="nature-classes">
        {classes.length === 0 ? (
          <div className="dash-empty">{t('dashboard.noData')}</div>
        ) : (
          classes.map((c) => {
            const pct = Math.max(2, (c.count / classMax) * 100);
            return (
              <div key={c.key} className="bar-row">
                <div className="bar-swatch" style={{ background: CLASS_COLORS[c.key] }} />
                <div className="bar-label">{t(`home.nature_${c.key}`)}</div>
                <div className="bar-track">
                  <div className="bar-fill" style={{ width: `${pct}%`, background: CLASS_COLORS[c.key] }} />
                </div>
                <div className="bar-nums">
                  <span className="bar-count">{formatInt(c.count, lang)}</span>
                </div>
              </div>
            );
          })
        )}
      </div>
      {byState && byState.length > 0 && (
        <div className="nature-by-state">
          <div className="nature-by-state__title">{t('dashboard.natureByState')}</div>
          {byState.map((st) => {
            const shares = CLASS_ORDER
              .filter((k) => (st[k] || 0) > 0)
              .map((k) => ({ key: k, count: st[k] || 0 }));
            return (
              <button
                key={st.state}
                type="button"
                className="nature-state-row nature-state-row--btn"
                onClick={() => navigate(mapUrlForState(st.state, days))}
                title={t('dashboard.clickStateMap')}
              >
                <span className="nature-state-label">{st.state || '—'}</span>
                <span className="nature-state-track">
                  {shares.map((s) => (
                    <span
                      key={s.key}
                      className="nature-state-seg"
                      style={{ width: `${(s.count / st.total) * 100}%`, background: CLASS_COLORS[s.key] }}
                      title={`${t(`home.nature_${s.key}`)}: ${formatInt(s.count, lang)}`}
                    />
                  ))}
                </span>
                <span className="nature-state-total">{formatInt(st.total, lang)}</span>
              </button>
            );
          })}
        </div>
      )}
    </CardShell>
  );
}

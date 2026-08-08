import React from 'react';
import { useI18n } from '../../i18n';
import { useDashboardFilters } from './DashboardFilters';
import useCardData from './useCardData';
import { formatInt, formatDelta, formatDeltaPct } from '../../utils/format';

// KPI hero row (plan: dashboard-enhancement, Inc 6). Backed by a single
// /api/dashboard/summary request; revives the dormant .stat-card CSS.
//
// Colors are per-metric, not global: for fires/crime/suspeito "up" is bad
// (red), for natural vegetation "up" is good — so `goodDirection` flips the
// delta class.

const KPI_DEFS = [
  { key: 'fires',    labelKey: 'dashboard.kpiFires',    icon: '🔥', goodDirection: 'down' },
  { key: 'crime',    labelKey: 'dashboard.kpiCrime',    icon: '🚨', goodDirection: 'down' },
  { key: 'suspeito', labelKey: 'dashboard.kpiSuspeito', icon: '⚠️', goodDirection: 'down' },
  { key: 'natural',  labelKey: 'dashboard.kpiNatural',  icon: '🌳', goodDirection: 'up' },
];

function KpiCard({ def, kpi, lang, t }) {
  const { pct, direction } = formatDelta(kpi.current, kpi.previous);
  const incomplete = kpi.complete === false;

  // Flip the up/down class when "up" is the good direction for this metric.
  const effective = def.goodDirection === 'up'
    ? direction === 'up' ? 'down' : direction === 'down' ? 'up' : 'flat'
    : direction;
  const deltaCls = effective === 'unknown' ? 'stat-card__delta--flat' : `stat-card__delta--${effective}`;

  return (
    <div className="stat-card">
      <div className="stat-card__icon">{def.icon}</div>
      <div className="stat-card__body">
        <div className="stat-card__value">{formatInt(kpi.current, lang)}</div>
        <div className="stat-card__label">{t(def.labelKey)}</div>
        {direction === 'unknown' || incomplete ? (
          <span className="stat-card__delta stat-card__delta--flat" title={t('dashboard.wowUnavailable')}>
            {direction === 'unknown' ? t('dashboard.kpiNew') : t('dashboard.wowUnavailable')}
          </span>
        ) : (
          <span className={`stat-card__delta ${deltaCls}`}>
            {formatDeltaPct(pct, lang)} · {t('dashboard.wowVsPrev')}
          </span>
        )}
      </div>
    </div>
  );
}

function DeterCard({ kpi, lang, t }) {
  if (!kpi || !kpi.available) {
    return (
      <div className="stat-card" title={t('dashboard.unavailable')}>
        <div className="stat-card__icon">🛰️</div>
        <div className="stat-card__body">
          <div className="stat-card__value">—</div>
          <div className="stat-card__label">{t('dashboard.kpiDeter')}</div>
          <span className="stat-card__delta stat-card__delta--flat">{t('dashboard.unavailable')}</span>
        </div>
      </div>
    );
  }
  const { pct, direction } = formatDelta(kpi.current, kpi.previous);
  const deltaCls = direction === 'unknown' ? 'stat-card__delta--flat' : `stat-card__delta--${direction}`;
  return (
    <div className="stat-card">
      <div className="stat-card__icon">🛰️</div>
      <div className="stat-card__body">
        <div className="stat-card__value">{formatInt(kpi.current, lang)} km²</div>
        <div className="stat-card__label">{t('dashboard.kpiDeter')}</div>
        {direction === 'unknown'
          ? <span className="stat-card__delta stat-card__delta--flat">{t('dashboard.kpiNew')}</span>
          : <span className={`stat-card__delta ${deltaCls}`}>{formatDeltaPct(pct, lang)} · {t('dashboard.wowVsPrev')}</span>}
      </div>
    </div>
  );
}

function ProdesCard({ kpi, lang, t }) {
  if (!kpi) return null;
  return (
    <div className="stat-card">
      <div className="stat-card__icon">🌲</div>
      <div className="stat-card__body">
        <div className="stat-card__value">{formatInt(kpi.km2, lang)} km²</div>
        <div className="stat-card__label">{t('dashboard.kpiProdes')} · {kpi.year}</div>
        {kpi.delta_pct == null
          ? <span className="stat-card__delta stat-card__delta--flat">{t('dashboard.kpiNew')}</span>
          : <span className="stat-card__delta stat-card__delta--up">
              {formatDeltaPct(kpi.delta_pct, lang)} · {t('dashboard.yoyDelta')}
            </span>}
      </div>
    </div>
  );
}

export default function KpiHero() {
  const { t } = useI18n();
  const { lang } = useI18n();
  const { queryString } = useDashboardFilters();
  const url = `/api/dashboard/summary?${queryString}`;
  const { data, cardState, retry } = useCardData(url, { ttl: 120_000 });

  if (cardState === 'error') {
    return (
      <div className="dash-error" role="alert">
        <span>{t('dashboard.errorShort')}</span>
        <button type="button" className="dash-retry" onClick={retry}>{t('dashboard.retry')}</button>
      </div>
    );
  }
  if (cardState !== 'ready' || !data || !data.kpis) {
    return (
      <div className="stat-grid" aria-hidden={cardState === 'loading'}>
        {[0, 1, 2, 3, 4, 5].map((i) => (
          <div key={i} className="stat-card stat-card--skeleton"><div className="dash-loading" /></div>
        ))}
      </div>
    );
  }

  return (
    <div className="kpi-hero">
      <div className="stat-grid">
        {KPI_DEFS.map((def) => (
          <KpiCard key={def.key} def={def} kpi={data.kpis[def.key]} lang={lang} t={t} />
        ))}
        <DeterCard kpi={data.kpis.deter_km2} lang={lang} t={t} />
        <ProdesCard kpi={data.kpis.prodes_latest} lang={lang} t={t} />
      </div>
    </div>
  );
}

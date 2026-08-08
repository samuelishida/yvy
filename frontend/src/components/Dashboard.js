import React, { useMemo } from 'react';
import { useI18n } from '../i18n';
import { DashboardFilterProvider, useDashboardFilters } from './Dashboard/DashboardFilters';
import FilterBar from './Dashboard/DashboardFilters';
import { FreshnessProvider, useFreshness } from './Dashboard/FreshnessBar';
import FreshnessBar from './Dashboard/FreshnessBar';
import useCardData from './Dashboard/useCardData';
import CardShell from './Dashboard/CardShell';
import KpiHero from './Dashboard/KpiHero';
import HistoricalTrend from './Dashboard/HistoricalTrend';
import GeoBreakdown from './Dashboard/GeoBreakdown';
import TIAtRisk from './Dashboard/TIAtRisk';
import NatureStats from './Dashboard/NatureStats';
import { formatInt, formatKm2 } from '../utils/format';
import './Dashboard.css';

const asArray = (v) => (Array.isArray(v) ? v : []);

const ALERT_TYPES = [
  { key: 'indigenous_land',   tKey: 'dashboard.cat_indigenous_land',   color: '#f59e0b', priority: 1 },
  { key: 'conservation_unit', tKey: 'dashboard.cat_conservation_unit', color: '#4ade80', priority: 2 },
  { key: 'cluster',           tKey: 'dashboard.cat_cluster',           color: '#3b82f6', priority: 3 },
  { key: 'night_fire',        tKey: 'dashboard.cat_night_fire',        color: '#ec4899', priority: 4 },
  { key: 'prodes',            tKey: 'dashboard.cat_prodes',            color: '#8b5cf6', priority: 5 },
  { key: 'pm25',              tKey: 'dashboard.cat_pm25',              color: '#f97316', priority: 6 },
  { key: 'deter_protected',   tKey: 'dashboard.cat_deter_protected',   color: '#a3e635', priority: 7 },
];

const DETER_CLASS_COLORS = {
  DESMATAMENTO_VEG: '#fbbf24',
  CICATRIZ_DE_QUEIMADA: '#f97316',
  DEGRADACAO: '#fde047',
  MINERACAO: '#ef4444',
};
const DETER_CLASS_KEYS = {
  DESMATAMENTO_VEG: 'dashboard.deterDesmatamentoVeg',
  CICATRIZ_DE_QUEIMADA: 'dashboard.deterCicatriz',
  DEGRADACAO: 'dashboard.deterDegradacao',
  MINERACAO: 'dashboard.deterMineracao',
};

const SEVERITY_COLORS = {
  maximo: '#ef4444',
  alto: '#f97316',
  medio: '#fbbf24',
  baixo: '#22c55e',
};

// Solid swatch colors mirroring the biome lookup palette (for /api/fires/by-biome).
const BIOME_COLORS = {
  'Amazônia': '#ef4444',
  'Cerrado': '#f97316',
  'Caatinga': '#fbbf24',
  'Mata Atlântica': '#a78bfa',
  'Pantanal': '#2dd4ff',
  'Pampa': '#4ade80',
};

// Shared scope label for filter-aware cards: "{window} · {region}".
function useScopeLabel() {
  const { t } = useI18n();
  const { days, state } = useDashboardFilters();
  return t('dashboard.scopeLabel', {
    window: t(`dashboard.range${days}d`),
    region: state || t('dashboard.allBrazil'),
  });
}

function BiomesCard() {
  const { t } = useI18n();
  const { lang } = useI18n();
  const { days, state, queryString } = useDashboardFilters();
  const scope = useScopeLabel();
  const url = `/api/fires/by-biome?${queryString}`;
  const { data, cardState, retry } = useCardData(url, {
    ttl: 120_000,
    isEmpty: (d) => !d || !Array.isArray(d.biomes) || d.biomes.length === 0,
  });

  const sorted = useMemo(
    () => (data ? [...data.biomes].sort((a, b) => b.count - a.count) : []),
    [data],
  );
  const max = useMemo(() => Math.max(...sorted.map((b) => b.count), 1), [sorted]);

  return (
    <CardShell
      title={t('dashboard.firesByBiome')}
      state={cardState}
      onRetry={retry}
      freshness={{ windowLabel: scope }}
      exportData={{
        filename: `yvy-biomes-${days}d-${state || 'br'}.csv`,
        rows: sorted.map((b) => ({ biome: b.name, fires: b.count, share_pct: b.pct })),
      }}
    >
      <div className="bar-chart" role="img" aria-label={sorted.map((b) => `${b.name}: ${b.count}`).join(', ')}>
        {sorted.map((b) => {
          const color = BIOME_COLORS[b.name] || '#6b7280';
          const pct = Math.max(2, (b.count / max) * 100);
          return (
            <div key={b.name} className="bar-row">
              <div className="bar-swatch" style={{ background: color }} />
              <div className="bar-label">{b.name}</div>
              <div className="bar-track">
                <div className="bar-fill" style={{ width: `${pct}%`, background: color }} />
              </div>
              <div className="bar-nums">
                <span className="bar-count">{formatInt(b.count, lang)}</span>
                <span className="bar-pct">{b.pct}%</span>
              </div>
            </div>
          );
        })}
      </div>
    </CardShell>
  );
}

function DeterCard() {
  const { t } = useI18n();
  const { lang } = useI18n();
  const { days, state } = useDashboardFilters();
  const { ready: freshReady, available } = useFreshness();
  const scope = useScopeLabel();
  const url = `/api/deter/stats?days=${days}${state ? `&uf=${state}` : ''}`;
  const { data, cardState, retry } = useCardData(url, {
    ttl: 300_000,
    isEmpty: (d) => !d || !Array.isArray(d.by_class) || d.by_class.length === 0,
  });

  const deterAvail = freshReady ? available('deter') : true;
  const byClass = asArray(data && data.by_class);
  const max = useMemo(() => Math.max(...byClass.map((c) => c.km2 || 0), 1), [byClass]);
  const finalState = cardState === 'empty' && !deterAvail ? 'unavailable' : cardState;

  return (
    <CardShell
      title={t('dashboard.deterActivity')}
      subtitle={t('dashboard.deterActivityMeta')}
      state={finalState}
      onRetry={retry}
      freshness={{ windowLabel: scope }}
      exportData={{
        filename: `yvy-deter-${days}d-${state || 'br'}.csv`,
        rows: byClass.map((c) => ({ class: c.name, area_km2: c.km2 })),
      }}
    >
      <div className="bar-chart" role="img" aria-label={byClass.map((c) => `${c.name}: ${c.km2}`).join(', ')}>
        {byClass.map((c) => {
          const color = DETER_CLASS_COLORS[c.name] || '#6b7280';
          const pct = Math.max(2, ((c.km2 || 0) / max) * 100);
          return (
            <div key={c.name} className="bar-row">
              <div className="bar-swatch" style={{ background: color }} />
              <div className="bar-label">{DETER_CLASS_KEYS[c.name] ? t(DETER_CLASS_KEYS[c.name]) : c.name}</div>
              <div className="bar-track">
                <div className="bar-fill" style={{ width: `${pct}%`, background: color }} />
              </div>
              <div className="bar-nums">
                <span className="bar-count">{formatKm2(c.km2 || 0, lang)}</span>
              </div>
            </div>
          );
        })}
      </div>
    </CardShell>
  );
}

// Fire × nature headline numbers (honest aggregate, replaces the old capped
// /api/fires?vegetation=true client-side truncation).
function NatureHeadlineCard() {
  const { t } = useI18n();
  const { lang } = useI18n();
  const { queryString } = useDashboardFilters();
  const scope = useScopeLabel();
  const url = `/api/fires/nature-stats?${queryString}`;
  const { data, cardState, retry } = useCardData(url, {
    ttl: 120_000,
    isEmpty: (d) => !d || !d.classes,
  });

  const classes = (data && data.classes) || {};
  const rows = [
    { key: 'crime', icon: '🚨', label: t('dashboard.kpiCrime'), count: classes.crime || 0 },
    { key: 'suspeito', icon: '⚠️', label: t('dashboard.kpiSuspeito'), count: classes.suspeito || 0 },
    { key: 'natural', icon: '🌳', label: t('dashboard.kpiNatural'), count: classes.natural || 0 },
  ];

  return (
    <CardShell
      title={t('dashboard.fireNature')}
      subtitle={t('dashboard.fireNatureMeta')}
      state={cardState}
      onRetry={retry}
      freshness={{ windowLabel: scope }}
      exportData={{
        filename: `yvy-nature-${queryString.replace(/[=&]/g, '-')}.csv`,
        rows,
      }}
    >
      <div className="stat-grid stat-grid--3">
        {rows.map((r) => (
          <div key={r.key} className="stat-item">
            <span className="stat-icon">{r.icon}</span>
            <span className="stat-num">{formatInt(r.count, lang)}</span>
            <span className="stat-label">{r.label}</span>
          </div>
        ))}
      </div>
    </CardShell>
  );
}

function AlertsCard() {
  const { t } = useI18n();
  // /api/alerts is a single national 1800s snapshot — it does NOT accept
  // filter params. Label it explicitly so it's not misread as filtered.
  const { data, cardState, retry } = useCardData('/api/alerts', {
    ttl: 180_000,
    isEmpty: (d) => !d || !Array.isArray(d.alerts) || d.alerts.length === 0,
  });

  const alerts = asArray(data && data.alerts);
  const byType = useMemo(
    () => alerts.reduce((acc, a) => { acc[a.type] = (acc[a.type] || 0) + 1; return acc; }, {}),
    [alerts],
  );
  const max = useMemo(() => Math.max(...ALERT_TYPES.map((x) => byType[x.key] || 0), 1), [byType]);
  const visible = ALERT_TYPES.filter((at) => (byType[at.key] || 0) > 0).sort((a, b) => a.priority - b.priority);

  return (
    <CardShell
      title={t('dashboard.alertsByCategory')}
      state={cardState}
      onRetry={retry}
      freshness={{ windowLabel: t('dashboard.alertsScope') }}
      exportData={{
        filename: 'yvy-alerts.csv',
        rows: visible.map((v) => ({ category: t(v.tKey), count: byType[v.key] || 0 })),
      }}
    >
      <div className="bar-chart" role="img" aria-label={visible.map((v) => `${t(v.tKey)}: ${byType[v.key]}`).join(', ')}>
        {visible.map(({ key, tKey, color }) => {
          const count = byType[key] || 0;
          const pct = count ? Math.max(2, (count / max) * 100) : 0;
          return (
            <div key={key} className="bar-row">
              <div className="bar-swatch" style={{ background: color }} />
              <div className="bar-label">{t(tKey)}</div>
              <div className="bar-track">
                <div className="bar-fill" style={{ width: `${pct}%`, background: color }} />
              </div>
              <div className="bar-nums">
                <span className="bar-count" style={{ color: count ? color : undefined }}>{count}</span>
              </div>
            </div>
          );
        })}
      </div>
    </CardShell>
  );
}

function CarAlertsCard() {
  const { t } = useI18n();
  const { lang } = useI18n();
  const { days, state } = useDashboardFilters();
  const { ready: freshReady, available } = useFreshness();
  const scope = useScopeLabel();
  const url = `/api/deter/car-alert-stats?days=${days}${state ? `&uf=${state}` : ''}`;
  const { data, cardState, retry } = useCardData(url, {
    ttl: 300_000,
    isEmpty: (d) => !d || !Array.isArray(d.by_severity) || d.by_severity.length === 0,
  });

  const carAvail = freshReady ? available('deter_car') : true;
  const bySeverity = asArray(data && data.by_severity);
  const max = useMemo(() => Math.max(...bySeverity.map((s) => s.count || 0), 1), [bySeverity]);
  const finalState = cardState === 'empty' && !carAvail ? 'unavailable' : cardState;

  return (
    <CardShell
      title={t('dashboard.carAlerts')}
      subtitle={t('dashboard.carAlertsMeta')}
      state={finalState}
      onRetry={retry}
      freshness={{ windowLabel: scope }}
      exportData={{
        filename: `yvy-car-alerts-${days}d-${state || 'br'}.csv`,
        rows: bySeverity.map((s) => ({ severity: s.severity, count: s.count })),
      }}
    >
      <div className="bar-chart" role="img" aria-label={bySeverity.map((s) => `${s.severity}: ${s.count}`).join(', ')}>
        {bySeverity.map((s) => {
          const color = SEVERITY_COLORS[s.severity] || '#6b7280';
          const pct = Math.max(2, ((s.count || 0) / max) * 100);
          const sevKey = 'dashboard.sev' + (s.severity ? s.severity.charAt(0).toUpperCase() + s.severity.slice(1) : '');
          return (
            <div key={s.severity} className="bar-row">
              <div className="bar-swatch" style={{ background: color }} />
              <div className="bar-label">{t(sevKey)}</div>
              <div className="bar-track">
                <div className="bar-fill" style={{ width: `${pct}%`, background: color }} />
              </div>
              <div className="bar-nums">
                <span className="bar-count">{formatInt(s.count || 0, lang)}</span>
              </div>
            </div>
          );
        })}
      </div>
    </CardShell>
  );
}

export default function Dashboard() {
  const { t } = useI18n();
  return (
    <DashboardFilterProvider>
      <FreshnessProvider>
        <div className="dashboard">
          <header className="dash-header">
            <div>
              <h1 className="dash-title">{t('dashboard.title')}</h1>
              <p className="dash-sub">{t('dashboard.subtitle')}</p>
            </div>
          </header>

          <FilterBar />
          <FreshnessBar />

          <div className="dash-body">
            <KpiHero />
            <HistoricalTrend />
            <DeterCard />
            <BiomesCard />
            <NatureHeadlineCard />
            <AlertsCard />
            <CarAlertsCard />
            <TIAtRisk />
            <NatureStats />
            <GeoBreakdown />
          </div>
        </div>
      </FreshnessProvider>
    </DashboardFilterProvider>
  );
}

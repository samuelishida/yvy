import React, { useEffect, useState, useMemo } from 'react';
import { useI18n } from '../i18n';
import { cachedFetch } from '../utils/apiCache';
import DashboardFilters from './Dashboard/DashboardFilters';
import FireTrend from './Dashboard/FireTrend';
import HistoricalTrend from './Dashboard/HistoricalTrend';
import HealthContext from './Dashboard/HealthContext';
import GeoBreakdown from './Dashboard/GeoBreakdown';
import StateSparklines from './Dashboard/StateSparklines';
import TIAtRisk from './Dashboard/TIAtRisk';
import './Dashboard.css';

const asArray = v => Array.isArray(v) ? v : [];

function DeltaChip({ pct, t }) {
  if (pct == null) {
    return <div className="stat-card__delta stat-card__delta--flat">{t('dashboard.wowUnavailable')}</div>;
  }
  if (!Number.isFinite(pct)) return null;
  const rounded = Math.abs(pct) < 1 ? 0 : Math.round(pct);
  if (rounded === 0) {
    return <div className="stat-card__delta stat-card__delta--flat">{t('dashboard.wowFlat')}</div>;
  }
  const dir = rounded > 0 ? 'up' : 'down';
  const arrow = rounded > 0 ? '↑' : '↓';
  return (
    <div className={`stat-card__delta stat-card__delta--${dir}`}>
      {arrow} {Math.abs(rounded)}% {t('dashboard.wowVsPrev')}
    </div>
  );
}

function StatCard({ icon, label, value, accent, delta, t }) {
  return (
    <div className="stat-card" style={{ '--accent': accent || '#00C97A' }}>
      <div className="stat-card__icon">{icon}</div>
      <div className="stat-card__body">
        <div className="stat-card__value">{value ?? '—'}</div>
        <div className="stat-card__label">{label}</div>
        {delta !== undefined && <DeltaChip pct={delta} t={t} />}
      </div>
    </div>
  );
}

const ALERT_TYPES = [
  { key: 'indigenous_land',   tKey: 'dashboard.cat_indigenous_land',   color: '#f59e0b', priority: 1 },
  { key: 'conservation_unit', tKey: 'dashboard.cat_conservation_unit', color: '#4ade80', priority: 2 },
  { key: 'cluster',           tKey: 'dashboard.cat_cluster',           color: '#3b82f6', priority: 3 },
  { key: 'night_fire',        tKey: 'dashboard.cat_night_fire',        color: '#ec4899', priority: 4 },
  { key: 'prodes',            tKey: 'dashboard.cat_prodes',            color: '#8b5cf6', priority: 5 },
  { key: 'pm25',              tKey: 'dashboard.cat_pm25',              color: '#f97316', priority: 6 },
];

function computeWoW(series) {
  if (!Array.isArray(series) || series.length < 14) return null;
  const last7 = series.slice(-7).reduce((s, p) => s + (Number(p.count) || 0), 0);
  const prev7 = series.slice(-14, -7).reduce((s, p) => s + (Number(p.count) || 0), 0);
  if (prev7 === 0) return { last7, prev7, pct: null };
  return { last7, prev7, pct: ((last7 - prev7) / prev7) * 100 };
}

export default function Dashboard() {
  const { t } = useI18n();
  const [stats,  setStats]  = useState(null);
  const [biomes, setBiomes] = useState(null);
  const [alerts, setAlerts] = useState(null);
  const [wow,    setWow]    = useState(null);

  const [selectedBiome, setSelectedBiome] = useState(null);
  const [rangeDays,     setRangeDays]     = useState(30);

  useEffect(() => {
    const ac = new AbortController();
    const logErr = err => { if (err.name !== 'AbortError') console.error('Dashboard fetch error:', err); };

    cachedFetch('/api/stats',  { ttl: 60_000,  signal: ac.signal }).then(setStats).catch(logErr);
    cachedFetch('/api/biomes', { ttl: 60_000,  signal: ac.signal }).then(d => setBiomes(asArray(d.biomes))).catch(logErr);
    cachedFetch('/api/alerts', { ttl: 180_000, signal: ac.signal }).then(d => setAlerts(asArray(d.alerts))).catch(logErr);
    cachedFetch('/api/fires/timeseries?days=14', { ttl: 60_000, signal: ac.signal })
      .then(d => setWow(computeWoW(d.series)))
      .catch(logErr);

    return () => ac.abort();
  }, []);

  const alertsByType = useMemo(() => {
    if (!alerts) return {};
    return alerts.reduce((acc, a) => { acc[a.type] = (acc[a.type] || 0) + 1; return acc; }, {});
  }, [alerts]);

  const alertMaxCount = useMemo(
    () => Math.max(...ALERT_TYPES.map(x => alertsByType[x.key] || 0), 1),
    [alertsByType]
  );

  const biomeMaxCount = useMemo(
    () => (!biomes || !biomes.length ? 1 : Math.max(...biomes.map(b => b.count), 1)),
    [biomes]
  );

  const biomeTotal = useMemo(
    () => (!biomes ? 0 : biomes.reduce((s, b) => s + b.count, 0) || 1),
    [biomes]
  );

  const sortedBiomes = useMemo(
    () => (!biomes ? [] : [...biomes].sort((a, b) => b.count - a.count)),
    [biomes]
  );

  const sortedAlertTypes = useMemo(
    () => [...ALERT_TYPES].sort((a, b) => a.priority - b.priority),
    []
  );

  return (
    <div className="dashboard">
      <div className="dash-header">
        <div className="dash-header__left">
          <h1 className="dash-title">{t('dashboard.monitorTitle')}</h1>
          <p className="dash-sub">{t('dashboard.monitorSub')}</p>
        </div>
      </div>

      <div className="stat-grid">
        <StatCard
          icon="FC"
          label={t('dashboard.cardFires')}
          value={stats?.fires?.toLocaleString('pt-BR')}
          accent="#EF5350"
          delta={wow?.pct}
          t={t}
        />
        <StatCard icon="PD" label={t('dashboard.cardProdes')} value={stats?.deforestation?.toLocaleString('pt-BR')} accent="#00C97A" t={t} />
        <StatCard icon="AL" label={t('dashboard.cardAlerts')} value={alerts?.length?.toLocaleString('pt-BR')}       accent="#FF6200" t={t} />
        <StatCard icon="NI" label={t('dashboard.cardNews')}   value={stats?.news?.toLocaleString('pt-BR')}          accent="#00C97A" t={t} />
      </div>

      <DashboardFilters
        selectedBiome={selectedBiome}
        onBiomeChange={setSelectedBiome}
        rangeDays={rangeDays}
        onRangeChange={setRangeDays}
      />

      <div className="dash-body">
        <div className="chart-card chart-card--trend">
          <FireTrend days={rangeDays} />
        </div>

        <div className="chart-card">
          <div className="chart-card__header">
            <h2>{t('dashboard.firesByBiome')}</h2>
            <span className="chart-card__total">{t('dashboard.firesByBiomeMeta')}</span>
          </div>
          {biomes ? (
            <div className="bar-chart">
              {sortedBiomes.map((b, i) => {
                const pct  = Math.max(2, (b.count / biomeMaxCount) * 100);
                const share = ((b.count / biomeTotal) * 100).toFixed(1);
                const dimmed = selectedBiome && selectedBiome !== b.name;
                return (
                  <div key={i} className={`bar-row${dimmed ? ' bar-row--dim' : ''}`}>
                    <div className="bar-swatch" style={{ background: b.color }} />
                    <div className="bar-label">{b.name}</div>
                    <div className="bar-track">
                      <div className="bar-fill" style={{ width: `${pct}%`, background: b.color }} />
                    </div>
                    <div className="bar-nums">
                      <span className="bar-count">{b.count.toLocaleString('pt-BR')}</span>
                      <span className="bar-pct">{share}%</span>
                    </div>
                  </div>
                );
              })}
            </div>
          ) : <div className="dash-loading">{t('dashboard.loadingShort')}</div>}
        </div>

        <GeoBreakdown />
        <StateSparklines />
        <TIAtRisk />

        <div className="chart-card">
          <div className="chart-card__header">
            <h2>{t('dashboard.alertsByCategory')}</h2>
            {alerts && <span className="chart-card__total">{alerts.length} {t('dashboard.activeLow')}</span>}
          </div>
          {alerts ? (
            <div className="bar-chart">
              {sortedAlertTypes.map(({ key, tKey, color }) => {
                const count = alertsByType[key] || 0;
                const pct   = count ? Math.max(2, (count / alertMaxCount) * 100) : 0;
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
          ) : <div className="dash-loading">{t('dashboard.loadingShort')}</div>}
        </div>
      </div>

      <div className="dash-body dash-body--single">
        <HistoricalTrend />
        <HealthContext />
      </div>
    </div>
  );
}

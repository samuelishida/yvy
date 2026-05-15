import React, { useEffect, useState, useMemo } from 'react';
import { useI18n } from '../i18n';
import { cachedFetch } from '../utils/apiCache';
import HistoricalTrend from './Dashboard/HistoricalTrend';
import GeoBreakdown from './Dashboard/GeoBreakdown';
import TIAtRisk from './Dashboard/TIAtRisk';
import './Dashboard.css';

const asArray = v => Array.isArray(v) ? v : [];

const ALERT_TYPES = [
  { key: 'indigenous_land',   tKey: 'dashboard.cat_indigenous_land',   color: '#f59e0b', priority: 1 },
  { key: 'conservation_unit', tKey: 'dashboard.cat_conservation_unit', color: '#4ade80', priority: 2 },
  { key: 'cluster',           tKey: 'dashboard.cat_cluster',           color: '#3b82f6', priority: 3 },
  { key: 'night_fire',        tKey: 'dashboard.cat_night_fire',        color: '#ec4899', priority: 4 },
  { key: 'prodes',            tKey: 'dashboard.cat_prodes',            color: '#8b5cf6', priority: 5 },
  { key: 'pm25',              tKey: 'dashboard.cat_pm25',              color: '#f97316', priority: 6 },
];

export default function Dashboard() {
  const { t } = useI18n();
  const [biomes, setBiomes] = useState(null);
  const [alerts, setAlerts] = useState(null);

  useEffect(() => {
    const ac = new AbortController();
    const logErr = err => { if (err.name !== 'AbortError') console.error('Dashboard fetch error:', err); };

    cachedFetch('/api/biomes', { ttl: 60_000,  signal: ac.signal }).then(d => setBiomes(asArray(d.biomes))).catch(logErr);
    cachedFetch('/api/alerts', { ttl: 180_000, signal: ac.signal }).then(d => setAlerts(asArray(d.alerts))).catch(logErr);

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
    () => ALERT_TYPES.filter(at => (alertsByType[at.key] || 0) > 0)
                     .sort((a, b) => a.priority - b.priority),
    [alertsByType]
  );

  return (
    <div className="dashboard">
      <div className="dash-body">
        <HistoricalTrend />

        <div className="chart-card chart-card--combo">
          <div className="combo-card__section">
            <div className="chart-card__header">
              <h2>{t('dashboard.firesByBiome')}</h2>
              <span className="chart-card__total">{t('dashboard.firesByBiomeMeta')}</span>
            </div>
            {biomes ? (
              <div className="bar-chart">
                {sortedBiomes.map((b, i) => {
                  const pct  = Math.max(2, (b.count / biomeMaxCount) * 100);
                  const share = ((b.count / biomeTotal) * 100).toFixed(1);
                  return (
                    <div key={i} className="bar-row">
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
          <div className="combo-card__divider" />
          <div className="combo-card__section">
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

        <TIAtRisk />

        <GeoBreakdown />
      </div>
    </div>
  );
}

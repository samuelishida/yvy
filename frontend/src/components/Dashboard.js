import React, { useEffect, useState, useMemo } from 'react';
import { useI18n } from '../i18n';
import { cachedFetch } from '../utils/apiCache';
import HistoricalTrend from './Dashboard/HistoricalTrend';
import GeoBreakdown from './Dashboard/GeoBreakdown';
import TIAtRisk from './Dashboard/TIAtRisk';
import NatureStats from './Dashboard/NatureStats';
import './Dashboard.css';

const asArray = v => Array.isArray(v) ? v : [];

const ALERT_TYPES = [
  { key: 'indigenous_land',   tKey: 'dashboard.cat_indigenous_land',   color: '#f59e0b', priority: 1 },
  { key: 'conservation_unit', tKey: 'dashboard.cat_conservation_unit', color: '#4ade80', priority: 2 },
  { key: 'cluster',           tKey: 'dashboard.cat_cluster',           color: '#3b82f6', priority: 3 },
  { key: 'night_fire',        tKey: 'dashboard.cat_night_fire',        color: '#ec4899', priority: 4 },
  { key: 'prodes',            tKey: 'dashboard.cat_prodes',            color: '#8b5cf6', priority: 5 },
  { key: 'pm25',              tKey: 'dashboard.cat_pm25',              color: '#f97316', priority: 6 },
  { key: 'deter_protected',   tKey: 'dashboard.cat_deter_protected',   color: '#a3e635', priority: 7 },
];

// DETER classes (by_class do /api/deter/stats) → cores + labels i18n.
const DETER_CLASS_COLORS = {
  DESMATAMENTO_VEG: '#fbbf24',       // amber
  CICATRIZ_DE_QUEIMADA: '#f97316',   // orange
  DEGRADACAO: '#fde047',             // yellow
  MINERACAO: '#ef4444',              // red
};
const DETER_CLASS_KEYS = {
  DESMATAMENTO_VEG: 'dashboard.deterDesmatamentoVeg',
  CICATRIZ_DE_QUEIMADA: 'dashboard.deterCicatriz',
  DEGRADACAO: 'dashboard.deterDegradacao',
  MINERACAO: 'dashboard.deterMineracao',
};

// Severidade dos alertas DETER×CAR (maximo > alto > medio > baixo).
const SEVERITY_COLORS = {
  maximo: '#ef4444',  // red
  alto: '#f97316',    // orange
  medio: '#fbbf24',   // amber
  baixo: '#22c55e',   // green
};

export default function Dashboard() {
  const { t } = useI18n();
  const [biomes, setBiomes] = useState(null);
  const [alerts, setAlerts] = useState(null);
  const [deter, setDeter] = useState(null);
  const [carAlerts, setCarAlerts] = useState(null);
  const [vegFires, setVegFires] = useState(null);

  useEffect(() => {
    const ac = new AbortController();
    const logErr = err => { if (err.name !== 'AbortError') console.error('Dashboard fetch error:', err); };

    cachedFetch('/api/biomes', { ttl: 60_000,  signal: ac.signal }).then(d => setBiomes(asArray(d.biomes))).catch(logErr);
    cachedFetch('/api/alerts', { ttl: 180_000, signal: ac.signal }).then(d => setAlerts(asArray(d.alerts))).catch(logErr);
    cachedFetch('/api/deter/stats', { ttl: 300_000, signal: ac.signal }).then(d => setDeter(d)).catch(logErr);
    cachedFetch('/api/deter/car-alert-stats?days=7', { ttl: 300_000, signal: ac.signal }).then(d => setCarAlerts(d)).catch(logErr);
    cachedFetch('/api/fires?vegetation=true', { ttl: 300_000, signal: ac.signal }).then(d => setVegFires(asArray(d.fires))).catch(logErr);

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

  // Inc 6: DETER por classe (30d) — maior área para escala das barras.
  const deterMaxKm2 = useMemo(
    () => (!deter || !deter.by_class || !deter.by_class.length ? 1 : Math.max(...deter.by_class.map(c => c.km2 || 0), 1)),
    [deter]
  );

  // Inc 6: severidade CAR (7d) — maior contagem para escala das barras.
  const carAlertMax = useMemo(
    () => (!carAlerts || !carAlerts.by_severity || !carAlerts.by_severity.length ? 1 : Math.max(...carAlerts.by_severity.map(s => s.count || 0), 1)),
    [carAlerts]
  );

  // Inc 6: fogo×vegetação — janela atual (~3 dias, cap MAX_RESULTS). Status usa
  // prefixos native/deforested/regrowth (Home.js usa startsWith no popup).
  const vegStats = useMemo(() => {
    if (!vegFires) return null;
    let native = 0, deforested = 0, regrowth = 0;
    for (const f of vegFires) {
      const st = (f.vegetation && f.vegetation.status) || '';
      if (st.startsWith('deforested')) deforested += 1;
      else if (st.startsWith('regrowth')) regrowth += 1;
      else if (st === 'native') native += 1;
    }
    return { native, deforested, regrowth };
  }, [vegFires]);

  return (
    <div className="dashboard">
      <div className="dash-body">
        <HistoricalTrend />

        <div className="chart-card chart-card--deter">
          <div className="chart-card__header">
            <h2>{t('dashboard.deterActivity')}</h2>
            <span className="chart-card__total">{t('dashboard.deterActivityMeta')}</span>
          </div>
          {deter ? (
            deter.by_class && deter.by_class.length ? (
              <div className="bar-chart">
                {deter.by_class.map((c, i) => {
                  const color = DETER_CLASS_COLORS[c.name] || '#6b7280';
                  const pct = Math.max(2, ((c.km2 || 0) / deterMaxKm2) * 100);
                  return (
                    <div key={i} className="bar-row">
                      <div className="bar-swatch" style={{ background: color }} />
                      <div className="bar-label">{DETER_CLASS_KEYS[c.name] ? t(DETER_CLASS_KEYS[c.name]) : c.name}</div>
                      <div className="bar-track">
                        <div className="bar-fill" style={{ width: `${pct}%`, background: color }} />
                      </div>
                      <div className="bar-nums">
                        <span className="bar-count">{(c.km2 || 0).toLocaleString('pt-BR')} km²</span>
                      </div>
                    </div>
                  );
                })}
              </div>
            ) : <div className="dash-empty">{t('dashboard.noData')}</div>
          ) : <div className="dash-loading">{t('dashboard.loadingShort')}</div>}
        </div>

        <div className="chart-card chart-card--biomes">
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

        <div className="chart-card chart-card--veg">
          <div className="chart-card__header">
            <h2>{t('dashboard.fireVegetation')}</h2>
            <span className="chart-card__total">{t('dashboard.fireVegetationMeta')}</span>
          </div>
          {vegStats ? (
            <div className="stat-grid">
              <div className="stat-item">
                <span className="stat-icon">🔥</span>
                <span className="stat-num">{vegStats.native.toLocaleString('pt-BR')}</span>
                <span className="stat-label">{t('dashboard.vegNative')}</span>
              </div>
              <div className="stat-item">
                <span className="stat-icon">🪓</span>
                <span className="stat-num">{vegStats.deforested.toLocaleString('pt-BR')}</span>
                <span className="stat-label">{t('dashboard.vegDeforested')}</span>
              </div>
              <div className="stat-item">
                <span className="stat-icon">🌱</span>
                <span className="stat-num">{vegStats.regrowth.toLocaleString('pt-BR')}</span>
                <span className="stat-label">{t('dashboard.vegRegrowth')}</span>
              </div>
            </div>
          ) : <div className="dash-loading">{t('dashboard.loadingShort')}</div>}
        </div>

        <div className="chart-card chart-card--alerts">
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

        <div className="chart-card chart-card--car-alerts">
          <div className="chart-card__header">
            <h2>{t('dashboard.carAlerts')}</h2>
            {carAlerts && <span className="chart-card__total">{carAlerts.total} {t('dashboard.activeLow')}</span>}
          </div>
          {carAlerts ? (
            carAlerts.by_severity && carAlerts.by_severity.length ? (
              <div className="bar-chart">
                {carAlerts.by_severity.map((s, i) => {
                  const color = SEVERITY_COLORS[s.severity] || '#6b7280';
                  const pct = Math.max(2, ((s.count || 0) / carAlertMax) * 100);
                  const sevKey = 'dashboard.sev' + (s.severity ? s.severity.charAt(0).toUpperCase() + s.severity.slice(1) : '');
                  return (
                    <div key={i} className="bar-row">
                      <div className="bar-swatch" style={{ background: color }} />
                      <div className="bar-label">{t(sevKey)}</div>
                      <div className="bar-track">
                        <div className="bar-fill" style={{ width: `${pct}%`, background: color }} />
                      </div>
                      <div className="bar-nums">
                        <span className="bar-count">{s.count || 0}</span>
                      </div>
                    </div>
                  );
                })}
              </div>
            ) : <div className="dash-empty">{t('dashboard.noData')}</div>
          ) : <div className="dash-loading">{t('dashboard.loadingShort')}</div>}
        </div>

        <TIAtRisk />

        <NatureStats />

        <GeoBreakdown />
      </div>
    </div>
  );
}

import React, { useEffect, useState, useMemo } from 'react';
import './Dashboard.css';

const asArray = v => Array.isArray(v) ? v : [];

function StatCard({ icon, label, value, accent }) {
  return (
    <div className="stat-card" style={{ '--accent': accent || '#00b4d8' }}>
      <div className="stat-card__icon">{icon}</div>
      <div className="stat-card__body">
        <div className="stat-card__value">{value ?? '—'}</div>
        <div className="stat-card__label">{label}</div>
      </div>
    </div>
  );
}

const ALERT_TYPES = [
  { key: 'cluster',           label: 'Clusters de Fogo',   color: '#ef4444' },
  { key: 'night_fire',        label: 'Focos Noturnos',      color: '#a855f7' },
  { key: 'indigenous_land',   label: 'Terras Indígenas',    color: '#f59e0b' },
  { key: 'conservation_unit', label: 'Unid. Conservação',   color: '#4ade80' },
  { key: 'prodes',            label: 'Zonas Desmatadas',    color: '#2dd4ff' },
  { key: 'pm25',              label: 'Qualidade do Ar',     color: '#94a3b8' },
];

export default function Dashboard() {
  const [stats,  setStats]  = useState(null);
  const [biomes, setBiomes] = useState(null);
  const [alerts, setAlerts] = useState(null);

  useEffect(() => {
    fetch('/api/stats').then(r => r.json()).then(setStats).catch(() => {});
    fetch('/api/biomes').then(r => r.json()).then(d => setBiomes(asArray(d.biomes))).catch(() => {});
    fetch('/api/alerts').then(r => r.json()).then(d => setAlerts(asArray(d.alerts))).catch(() => {});
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

  return (
    <div className="dashboard">
      <div className="dash-header">
        <div className="dash-header__left">
          <h1 className="dash-title">Monitor Ambiental</h1>
          <p className="dash-sub">Queimadas · Desmatamento · Alertas · Brasil</p>
        </div>
      </div>

      <div className="stat-grid">
        <StatCard icon="🔥" label="Focos de Calor"     value={stats?.fires?.toLocaleString('pt-BR')}         accent="#ef4444" />
        <StatCard icon="🌳" label="Registros PRODES"   value={stats?.deforestation?.toLocaleString('pt-BR')} accent="#22c55e" />
        <StatCard icon="⚠️" label="Alertas Ativos"     value={alerts?.length?.toLocaleString('pt-BR')}       accent="#f97316" />
        <StatCard icon="📰" label="Notícias Indexadas" value={stats?.news?.toLocaleString('pt-BR')}          accent="#3b82f6" />
      </div>

      <div className="dash-body">
        {/* Biome fire distribution */}
        <div className="chart-card">
          <div className="chart-card__header">
            <h2>Focos por Bioma</h2>
            <span className="chart-card__total">24h · Brasil</span>
          </div>
          {biomes ? (
            <div className="bar-chart">
              {biomes.sort((a, b) => b.count - a.count).map((b, i) => {
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
          ) : <div className="dash-loading">Carregando...</div>}
        </div>

        {/* Alert cross-reference by category */}
        <div className="chart-card">
          <div className="chart-card__header">
            <h2>Alertas por Categoria</h2>
            {alerts && <span className="chart-card__total">{alerts.length} ativos</span>}
          </div>
          {alerts ? (
            <div className="bar-chart">
              {ALERT_TYPES.map(({ key, label, color }) => {
                const count = alertsByType[key] || 0;
                const pct   = count ? Math.max(2, (count / alertMaxCount) * 100) : 0;
                return (
                  <div key={key} className="bar-row">
                    <div className="bar-swatch" style={{ background: color }} />
                    <div className="bar-label">{label}</div>
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
          ) : <div className="dash-loading">Carregando...</div>}
        </div>
      </div>
    </div>
  );
}

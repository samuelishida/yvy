import React, { useEffect, useState, useMemo } from 'react';
import { useI18n } from '../i18n';
import './Dashboard.css';

const BBOX = { ne_lat: 5.5, ne_lng: -34.0, sw_lat: -34.0, sw_lng: -74.0 };

function classLabel(clazz, t) {
  if (!clazz) return t('home.unknown');
  const key = clazz.toLowerCase().charAt(0);
  const map = {
    d: t('home.deforestation'),
    r: t('home.regeneration'),
    f: t('home.forest'),
    h: t('home.hydrography'),
    n: t('home.nonForest'),
  };
  return map[key] || clazz;
}

function StatCard({ icon, label, value, sub, accent }) {
  return (
    <div className="stat-card" style={{ '--accent': accent || '#00b4d8' }}>
      <div className="stat-card__icon">{icon}</div>
      <div className="stat-card__body">
        <div className="stat-card__value">
          {value}
          {sub && <span className="stat-card__sub">&nbsp;{sub}</span>}
        </div>
        <div className="stat-card__label">{label}</div>
      </div>
    </div>
  );
}

export default function Dashboard() {
  const { t } = useI18n();
  const [records, setRecords] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    const params = new URLSearchParams(BBOX).toString();
    fetch(`/api/data?${params}`)
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}: ${r.statusText}`);
        return r.json();
      })
      .then((d) => {
        setRecords(Array.isArray(d) ? d : []);
        setLoading(false);
      })
      .catch((e) => {
        setError(e.message);
        setLoading(false);
      });
  }, []);

  const stats = useMemo(() => {
    if (!records) return null;
    const byClazz = {};
    const byColor = {};

    records.forEach(({ clazz, color }) => {
      const label = classLabel(clazz, t);
      byClazz[label] = (byClazz[label] || { count: 0, color: color || '#888' });
      byClazz[label].count += 1;
      if (color) byColor[color] = (byColor[color] || 0) + 1;
    });

    const sorted = Object.entries(byClazz).sort((a, b) => b[1].count - a[1].count);
    const maxCount = sorted.length ? sorted[0][1].count : 1;

    return {
      total: records.length,
      categories: sorted.length,
      topCategory: sorted[0]?.[0] || '–',
      topCount: sorted[0]?.[1].count || 0,
      topColor: sorted[0]?.[1].color || '#00b4d8',
      sorted,
      maxCount,
    };
  }, [records, t]);

  return (
    <div className="dashboard">
      <div className="dash-header">
        <div className="dash-header__left">
          <h1 className="dash-title">{t('dashboard.title')}</h1>
          <p className="dash-sub">{t('dashboard.subtitle')}</p>
        </div>
        <div className="dash-header__badge">
          <span className="badge-dot" />
          <span>{t('dashboard.mongoLive')}</span>
        </div>
      </div>

      {loading && (
        <div className="dash-status">
          <div className="spinner" />
          <span>{t('dashboard.loading')}</span>
        </div>
      )}

      {error && (
        <div className="dash-error">
          <span className="dash-error__icon">⚠️</span>
          <div>
            <strong>{t('dashboard.connectionError')}</strong>
            <p>{error}</p>
            <p className="dash-error__hint">
              {t('dashboard.errorHint')}{' '}
              <code>cd backend && python ingest_sqlite.py</code>
            </p>
          </div>
        </div>
      )}

      {stats && stats.total === 0 && (
        <div className="dash-empty">
          <span className="dash-empty__icon">🗂️</span>
          <h3>{t('dashboard.noData')}</h3>
          <p>{t('dashboard.noDataHint')}</p>
          <code>cd backend && python ingest_sqlite.py</code>
        </div>
      )}

      {stats && stats.total > 0 && (
        <>
          <div className="stat-grid">
            <StatCard
              icon="📍"
              label={t('dashboard.recordsLoaded')}
              value={stats.total.toLocaleString('pt-BR')}
              accent="#00b4d8"
            />
            <StatCard
              icon="🎨"
              label={t('dashboard.distinctCategories')}
              value={stats.categories}
              accent="#9f7aea"
            />
            <StatCard
              icon="📌"
              label={t('dashboard.dominantCategory')}
              value={stats.topCategory}
              sub={`(${stats.topCount.toLocaleString('pt-BR')})`}
              accent={stats.topColor}
            />
            <StatCard
              icon="🛰️"
              label={t('dashboard.dataSource')}
              value="PRODES / INPE"
              accent="#38a169"
            />
          </div>

          <div className="chart-card">
            <div className="chart-card__header">
              <h2>{t('dashboard.distributionByCategory')}</h2>
              <span className="chart-card__total">
                {stats.total.toLocaleString('pt-BR')} {t('dashboard.points')}
              </span>
            </div>
            <div className="bar-chart">
              {stats.sorted.map(([label, { count, color }]) => {
                const pct = Math.max(2, (count / stats.maxCount) * 100);
                const share = ((count / stats.total) * 100).toFixed(1);
                return (
                  <div key={label} className="bar-row">
                    <div
                      className="bar-swatch"
                      style={{ background: color }}
                      title={label}
                    />
                    <div className="bar-label">{label}</div>
                    <div className="bar-track">
                      <div
                        className="bar-fill"
                        style={{ width: `${pct}%`, background: color }}
                      />
                    </div>
                    <div className="bar-nums">
                      <span className="bar-count">{count.toLocaleString('pt-BR')}</span>
                      <span className="bar-pct">{share}%</span>
                    </div>
                  </div>
                );
              })}
            </div>
          </div>

          <div className="map-card">
            <div className="map-card__header">
              <h2>{t('dashboard.deforestationMap')}</h2>
              <a
                href="https://terrabrasilis.dpi.inpe.br/app/map/deforestation?hl=pt_br"
                target="_blank"
                rel="noopener noreferrer"
                className="map-card__ext"
              >
                {t('dashboard.openFullScreen')}
              </a>
            </div>
            <iframe
              src="https://terrabrasilis.dpi.inpe.br/app/map/deforestation?hl=pt_br"
              title="TerraBrasilis Deforestation Map"
              className="dash-iframe"
              allow="fullscreen"
              sandbox="allow-scripts allow-same-origin allow-popups allow-forms"
              referrerPolicy="no-referrer"
            />
          </div>
        </>
      )}
    </div>
  );
}
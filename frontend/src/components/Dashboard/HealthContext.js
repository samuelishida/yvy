import React, { useEffect, useState } from 'react';
import { useI18n } from '../../i18n';
import { cachedFetch } from '../../utils/apiCache';

const CAPITALS = [
  { key: 'manaus',   lat: -3.10,  lon: -60.02, tKey: 'dashboard.capManaus' },
  { key: 'belem',    lat: -1.46,  lon: -48.50, tKey: 'dashboard.capBelem' },
  { key: 'brasilia', lat: -15.78, lon: -47.93, tKey: 'dashboard.capBrasilia' },
  { key: 'cuiaba',   lat: -15.60, lon: -56.10, tKey: 'dashboard.capCuiaba' },
  { key: 'saopaulo', lat: -23.55, lon: -46.63, tKey: 'dashboard.capSaopaulo' },
];

function aqiTier(aqi, t) {
  const v = Number(aqi);
  if (!Number.isFinite(v)) return { label: t('dashboard.noData'), color: 'rgba(138, 158, 147, 0.5)' };
  if (v <= 50)  return { label: t('dashboard.aqiGood'),          color: '#4ade80' };
  if (v <= 100) return { label: t('dashboard.aqiModerate'),      color: '#FBBF24' };
  if (v <= 150) return { label: t('dashboard.aqiUnhealthy'),     color: '#F97316' };
  if (v <= 200) return { label: t('dashboard.aqiVeryUnhealthy'), color: '#EF5350' };
  return        { label: t('dashboard.aqiHazardous'),            color: '#8b5cf6' };
}

function windDir(deg) {
  if (!Number.isFinite(Number(deg))) return null;
  const dirs = ['N','NE','L','SE','S','SO','O','NO'];
  const idx = Math.round(((Number(deg) % 360) / 45)) % 8;
  return dirs[idx];
}

function CapitalCard({ data, label, t }) {
  if (!data) {
    return (
      <div className="aqi-card aqi-card--empty">
        <div className="aqi-card__label">{label}</div>
        <div className="aqi-card__noData">{t('dashboard.noData')}</div>
      </div>
    );
  }
  const tier = aqiTier(data.aqi, t);
  const dir = windDir(data.wind_direction);
  const showSmokeHint = Number(data.aqi) > 100 && dir;
  return (
    <div className="aqi-card" style={{ '--aqi': tier.color }}>
      <div className="aqi-card__head">
        <div className="aqi-card__label">{label}</div>
        <div className="aqi-card__tier">{tier.label}</div>
      </div>
      <div className="aqi-card__body">
        <div className="aqi-card__aqi">
          <span className="aqi-card__num">{Number.isFinite(Number(data.aqi)) ? Math.round(data.aqi) : '—'}</span>
          <span className="aqi-card__unit">AQI</span>
        </div>
        <div className="aqi-card__meta">
          {Number.isFinite(Number(data.temp)) && (
            <span>{Math.round(data.temp)}°C</span>
          )}
          {dir && (
            <span className="aqi-card__wind">
              <span
                className="aqi-card__arrow"
                style={{ transform: `rotate(${Number(data.wind_direction) || 0}deg)` }}
                aria-hidden="true"
              >↑</span>
              {dir}
            </span>
          )}
        </div>
      </div>
      {showSmokeHint && (
        <div className="aqi-card__hint">{t('dashboard.smokeHint', { direction: dir })}</div>
      )}
    </div>
  );
}

export default function HealthContext() {
  const { t } = useI18n();
  const [byKey, setByKey] = useState({});

  useEffect(() => {
    const ac = new AbortController();
    let cancelled = false;
    Promise.allSettled(
      CAPITALS.map(c =>
        cachedFetch(`/api/weather?lat=${c.lat}&lon=${c.lon}`, { ttl: 600_000, signal: ac.signal })
          .then(d => ({ key: c.key, data: d }))
      )
    ).then(results => {
      if (cancelled) return;
      const next = {};
      for (const r of results) {
        if (r.status === 'fulfilled') next[r.value.key] = r.value.data;
      }
      setByKey(next);
    });
    return () => { cancelled = true; ac.abort(); };
  }, []);

  return (
    <div className="chart-card chart-card--wide">
      <div className="chart-card__header">
        <h2>{t('dashboard.airQualityCards')}</h2>
      </div>
      <div className="aqi-grid">
        {CAPITALS.map(c => (
          <CapitalCard key={c.key} data={byKey[c.key]} label={t(c.tKey)} t={t} />
        ))}
      </div>
    </div>
  );
}

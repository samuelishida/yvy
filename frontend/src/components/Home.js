import React, { useEffect, useState } from 'react';
import { MapContainer, TileLayer, CircleMarker, Popup, useMapEvents } from 'react-leaflet';
import { Thermometer, TreePine, Flame } from 'lucide-react';
import { useI18n } from '../i18n';
import { getCache, setCache } from '../utils/cache';
import 'leaflet/dist/leaflet.css';
import '../Home.css';

const FIRE_STYLES = {
  nominal: { color: '#ef4444', fillColor: '#ef4444', fillOpacity: 0.85, radius: 5 },
  high:    { color: '#f97316', fillColor: '#f97316', fillOpacity: 0.8,  radius: 4 },
  low:     { color: '#fbbf24', fillColor: '#fbbf24', fillOpacity: 0.4,  radius: 3 },
};

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

function fireStyle(confidence) {
  const key = (confidence || 'low').toLowerCase();
  if (key === 'nominal' || key === 'h') return FIRE_STYLES.nominal;
  if (key === 'high') return FIRE_STYLES.high;
  return FIRE_STYLES.low;
}

function VisibleFiresCounter({ fires, showFires, onVisibleCountChange }) {
  const map = useMapEvents({
    moveend: () => {
      if (!showFires || !fires) return;
      const bounds = map.getBounds();
      onVisibleCountChange(fires.filter(f => bounds.contains([f.lat, f.lon])).length);
    },
    zoomend: () => {
      if (!showFires || !fires) return;
      const bounds = map.getBounds();
      onVisibleCountChange(fires.filter(f => bounds.contains([f.lat, f.lon])).length);
    },
  });
  useEffect(() => {
    if (!showFires || !fires) return;
    const bounds = map.getBounds();
    onVisibleCountChange(fires.filter(f => bounds.contains([f.lat, f.lon])).length);
  }, [fires, showFires]); // eslint-disable-line
  return null;
}

function Sparkline({ data, color = '#2dd4ff', height = 28 }) {
  const w = 200;
  const max = Math.max(...data);
  const min = Math.min(...data);
  const range = max - min || 1;
  const pts = data.map((v, i) => {
    const x = (i / (data.length - 1)) * w;
    const y = height - ((v - min) / range) * height;
    return `${x},${y}`;
  }).join(' ');
  const id = `sg${color.replace(/[^a-z0-9]/gi, '')}`;
  return (
    <svg viewBox={`0 0 ${w} ${height}`} className="stat-spark" preserveAspectRatio="none">
      <defs>
        <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={color} stopOpacity="0.35" />
          <stop offset="100%" stopColor={color} stopOpacity="0" />
        </linearGradient>
      </defs>
      <polygon points={`0,${height} ${pts} ${w},${height}`} fill={`url(#${id})`} />
      <polyline points={pts} fill="none" stroke={color} strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function GaugeRing({ value, max, color, size = 64 }) {
  const r = (size - 8) / 2;
  const c = 2 * Math.PI * r;
  const pct = Math.min(1, Math.max(0, value / max));
  return (
    <svg viewBox={`0 0 ${size} ${size}`} style={{ width: '100%', height: '100%', transform: 'rotate(-90deg)' }}>
      <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="rgba(255,255,255,0.07)" strokeWidth="5" />
      <circle
        cx={size / 2} cy={size / 2} r={r} fill="none"
        stroke={color} strokeWidth="5"
        strokeDasharray={c} strokeDashoffset={c * (1 - pct)}
        strokeLinecap="round"
        style={{ transition: 'stroke-dashoffset 1s ease', filter: `drop-shadow(0 0 4px ${color})` }}
      />
    </svg>
  );
}

function BiomePanel() {
  const { t } = useI18n();
  const [biomes, setBiomes] = useState([]);
  const [totalFires, setTotalFires] = useState(0);

  useEffect(() => {
    fetch('/api/biomes')
      .then(r => r.json())
      .then(d => {
        setBiomes(d.biomes || []);
        setTotalFires(d.total_fires || 0);
      })
      .catch(err => {
        console.error('Failed to fetch biomes:', err);
      });
  }, []);

  return (
    <div className="panel">
      <div className="panel-header">
        <div className="panel-title">
          <span className="panel-icon"><TreePine size={14} /></span>
          <span className="panel-title-text">{t('home.focosByBiome')}</span>
        </div>
        <span className="panel-meta">24H · BR</span>
      </div>
      <div className="panel-body" style={{ paddingTop: 4, paddingBottom: 8 }}>
        {biomes
          .sort((a, b) => b.count - a.count)
          .map((b, i) => (
          <div key={i} className="biome-row">
            <div className="biome-name">{b.name}</div>
            <div className="biome-bar">
              <div className="biome-bar-fill" style={{ width: `${b.pct}%`, background: b.color }} />
            </div>
            <div className="biome-val">{b.count.toLocaleString('pt-BR')}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

const ALERT_TYPE_KEYS = {
  cluster: 'alertCluster',
  night_fire: 'alertNightFire',
  indigenous_land: 'alertIndigenousLand',
  conservation_unit: 'alertConservationUnit',
  prodes: 'alertProdes',
  pm25: 'alertPm25',
};

function AlertsPanel() {
  const { t } = useI18n();
  const [alerts, setAlerts] = useState([]);

  useEffect(() => {
    const fetchAlerts = () => {
      fetch('/api/alerts')
        .then(r => r.json())
        .then(d => setAlerts(d.alerts || []))
        .catch(err => console.error('Failed to fetch alerts:', err));
    };
    fetchAlerts();
    const id = setInterval(fetchAlerts, 60000);
    return () => clearInterval(id);
  }, []);

  return (
    <div className="panel">
      <div className="panel-header">
        <div className="panel-title">
          <span className="panel-icon" style={{ color: '#fb923c' }}>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z" />
              <line x1="12" y1="9" x2="12" y2="13" />
              <line x1="12" y1="17" x2="12.01" y2="17" />
            </svg>
          </span>
          <span className="panel-title-text">{t('home.liveAlerts')}</span>
        </div>
        <span className="panel-meta">{alerts.length} {t('home.active')}</span>
      </div>
      <div className="panel-body" style={{ paddingTop: 4, paddingBottom: 8 }}>
        {alerts.length === 0 ? (
          <div className="alert-empty">{t('home.noAlerts')}</div>
        ) : alerts.map((a, i) => (
          <div key={a.id || i} className="alert-row">
            <div className={`alert-tick ${a.tick}`} />
            <div className="alert-body">
              <div className="alert-title">
                <span>{t('home.' + (ALERT_TYPE_KEYS[a.type] || a.type))}</span>
                <span className="ts">{a.ts}</span>
              </div>
              <div className="alert-meta">
                {a.meta} <span className="sep">/</span> {a.state}
              </div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function MapaCard({ records, fires, showDeforest, showFires, setShowDeforest, setShowFires, loading, error, t, airQuality, temperature }) {
  const [satellite, setSatellite] = useState(true);
  const [visibleCount, setVisibleCount] = useState(null);

  const tileUrl = satellite
    ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
    : 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png';
  const tileAttr = satellite
    ? '&copy; Esri, Earthstar Geographics'
    : '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>';

  const count   = visibleCount ?? fires?.length ?? 0;
  const aqiVal  = airQuality ? airQuality.aqi : 0;
  const humVal  = temperature ? temperature.humidity : 0;
  const aqiColor = aqiVal <= 50 ? '#4ade80' : aqiVal <= 100 ? '#fbbf24' : '#ef4444';

  return (
    <div className="map-stage">
      {/* Header overlay */}
      <div className="map-overlay-top">
        <div className="layer-toggles">
          <button
            className={`layer-toggle${showDeforest ? ' on-cyan' : ''}`}
            onClick={() => setShowDeforest(!showDeforest)}
          >
            <span className="lt-dot" /> PRODES
          </button>
          <button
            className={`layer-toggle${showFires ? ' on-red' : ''}`}
            onClick={() => setShowFires(!showFires)}
          >
            <Flame size={10} /> FIRMS
          </button>
          <button
            className={`layer-toggle${satellite ? ' on-violet' : ''}`}
            onClick={() => setSatellite(!satellite)}
          >
            <span className="lt-dot" /> Satélite
          </button>
        </div>
      </div>

      {/* Map */}
      {loading && <div className="map-loading">{t('home.loading')}</div>}
      {error   && <div className="map-error">{t('home.error')}: {error}</div>}
      {!loading && !error && (
        <MapContainer
          center={[-14.235, -51.925]}
          zoom={4}
          scrollWheelZoom
          style={{ position: 'absolute', inset: 0, width: '100%', height: '100%' }}
        >
          <TileLayer key={satellite ? 'sat' : 'osm'} attribution={tileAttr} url={tileUrl} />
          <VisibleFiresCounter fires={fires} showFires={showFires} onVisibleCountChange={setVisibleCount} />
          {showDeforest && records && records.slice(0, 500).map((rec, idx) => (
            <CircleMarker
              key={`d-${idx}`}
              center={[rec.lat, rec.lon]}
              pathOptions={{ color: rec.color || '#2dd4ff', fillColor: rec.color, fillOpacity: 0.5 }}
              radius={3}
            >
              <Popup>
                <strong>{classLabel(rec.clazz, t)}</strong><br />
                {t('home.source')}: PRODES/INPE<br />
                Lat: {rec.lat.toFixed(4)}, Lng: {rec.lon.toFixed(4)}
              </Popup>
            </CircleMarker>
          ))}
          {showFires && fires && fires.map((fire, idx) => {
            const s = fireStyle(fire.confidence);
            return (
              <CircleMarker key={`f-${idx}`} center={[fire.lat, fire.lon]} pathOptions={s} radius={s.radius}>
                <Popup>
                  <strong>{t('home.heatFocus')}</strong><br />
                  {t('home.confidence')}: {fire.confidence}<br />
                  {t('home.date')}: {fire.acq_date} {fire.acq_time}<br />
                  {t('home.satellite')}: {fire.satellite}<br />
                  {t('home.brightnessTemp')}: {fire.bright_ti4}K<br />
                  {t('home.sourceNasa')}
                </Popup>
              </CircleMarker>
            );
          })}
        </MapContainer>
      )}

      {/* Floating: fires — top right */}
      <div className="fl-card fl-stats">
        <div className="fl-eyebrow">
          <span className="dot" style={{ background: '#ef4444', boxShadow: '0 0 6px #ef4444' }} />
          {t('home.heatFocus')}
        </div>
        <div className="fl-big-number" style={{ color: '#fda4af' }}>
          {count.toLocaleString('pt-BR')}
          <span className="unit">focos</span>
        </div>
        <a
          href="https://firms.modaps.eosdis.nasa.gov/map/?lang=pt"
          target="_blank"
          rel="noopener noreferrer"
          className="fl-link"
        >
          <span>NASA FIRMS</span>
          <span>↗</span>
        </a>
      </div>

      {/* Floating: metrics — bottom left */}
      <div className="fl-card fl-metrics">
        <div className="metric-gauge">
          <div className="metric-gauge-svg">
            <GaugeRing value={aqiVal} max={300} color={aqiColor} size={64} />
            <div className="metric-gauge-num">{airQuality ? aqiVal : '—'}</div>
          </div>
          <div className="metric-meta">
            <div className="metric-label">{t('home.airQuality')}</div>
            <div className="metric-sub">PM2.5 · {airQuality ? airQuality.pm25 : '—'}</div>
          </div>
        </div>
        <div className="metric-divider" />
        <div className="metric-gauge">
          <div className="metric-gauge-svg">
            <GaugeRing value={humVal} max={100} color="#3b82f6" size={64} />
            <div className="metric-gauge-num">{humVal || '—'}</div>
          </div>
          <div className="metric-meta">
            <div className="metric-label">{t('home.humidity')}</div>
            <div className="metric-sub">{temperature?.city || 'Local'}</div>
          </div>
        </div>
      </div>

      {/* Floating: temperature — bottom right */}
      <div className="fl-card fl-temp">
        <div className="fl-eyebrow">
          <Thermometer size={10} style={{ color: '#fb923c' }} />
          <span style={{ color: 'var(--ink-3)', letterSpacing: '0.15em', textTransform: 'uppercase', fontSize: 9, fontFamily: 'var(--font-mono)' }}>
            {t('home.temperature')}
          </span>
        </div>
        <div className="fl-temp__big">
          {temperature ? temperature.temp.toFixed(1) : '—'}
          <span className="deg">°C</span>
        </div>
        {temperature && (
          <div className="fl-temp__feels">
            {t('home.feelsLike')}: {temperature.feels_like.toFixed(1)}°
          </div>
        )}
        {temperature?.city && (
          <div className="fl-temp__city">{temperature.city}</div>
        )}
      </div>
    </div>
  );
}

const DEFAULT_LAT = -14.235;
const DEFAULT_LON = -51.925;

export default function Home() {
  const { t } = useI18n();
  const [records,     setRecords]     = useState(null);
  const [fires,       setFires]       = useState(null);
  const [loading,     setLoading]     = useState(true);
  const [error,       setError]       = useState(null);
  const [airQuality,  setAirQuality]  = useState(null);
  const [temperature, setTemperature] = useState(null);
  const [showDeforest, setShowDeforest] = useState(true);
  const [showFires,    setShowFires]    = useState(true);

  useEffect(() => {
    fetch('/api/data')
      .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}: ${r.statusText}`); return r.json(); })
      .then(d => { setRecords(Array.isArray(d) ? d : []); setLoading(false); })
      .catch(e => { setError(e.message); setLoading(false); });

    const cached = getCache('fires', 10);
    if (cached) setFires(cached.fires || []);
    fetch('/api/fires')
      .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
      .then(d => { const f = d.fires || []; setFires(f); setCache('fires', { fires: f, last_sync: d.last_sync }); })
      .catch(() => { if (!cached) setFires([]); });

    const fetchWeather = (lat, lon) => {
      fetch(`/api/weather/air-quality?lat=${lat}&lon=${lon}`)
        .then(r => r.json())
        .then(d => { if (d.aqi != null) setAirQuality({ aqi: d.aqi, pm25: d.pm25 ?? '-', humidity: d.humidity ?? '-' }); })
        .catch(() => {});
      fetch(`/api/weather/temperature?lat=${lat}&lon=${lon}`)
        .then(r => r.json())
        .then(d => { if (d.temp != null) setTemperature({ temp: d.temp, feels_like: d.feels_like, humidity: d.humidity, city: d.city }); })
        .catch(() => {});
    };

    if (navigator.geolocation) {
      navigator.geolocation.getCurrentPosition(
        p  => fetchWeather(p.coords.latitude, p.coords.longitude),
        () => fetchWeather(DEFAULT_LAT, DEFAULT_LON),
        { timeout: 5000 }
      );
    } else {
      fetchWeather(DEFAULT_LAT, DEFAULT_LON);
    }
  }, []);

  return (
    <>
      <div className="home-main">
        <MapaCard
          records={records}
          fires={fires}
          showDeforest={showDeforest}
          showFires={showFires}
          setShowDeforest={setShowDeforest}
          setShowFires={setShowFires}
          loading={loading}
          error={error}
          t={t}
          airQuality={airQuality}
          temperature={temperature}
        />
        <div className="sidebar">
          <BiomePanel />
          <AlertsPanel />
        </div>
      </div>
    </>
  );
}

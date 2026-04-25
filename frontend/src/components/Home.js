import React, { useEffect, useState } from 'react';
import { MapContainer, TileLayer, CircleMarker, Popup, useMapEvents } from 'react-leaflet';
import {
  Thermometer,
  TreePine,
  Flame,
} from 'lucide-react';
import { useI18n } from '../i18n';
import { getCache, setCache } from '../utils/cache';
import 'leaflet/dist/leaflet.css';

const FIRE_STYLES = {
  nominal: { color: '#ef4444', fillColor: '#ef4444', fillOpacity: 0.85, radius: 5 },
  high: { color: '#f97316', fillColor: '#f97316', fillOpacity: 0.8, radius: 4 },
  low: { color: '#fbbf24', fillColor: '#fbbf24', fillOpacity: 0.4, radius: 3 },
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

function GaugeCircle({ value, max = 100, size = 120, strokeWidth = 10, color = '#22d3ee', label, centerText }) {
  const radius = (size - strokeWidth) / 2;
  const circumference = 2 * Math.PI * radius;
  const pct = Math.min(1, Math.max(0, value / max));
  const offset = circumference * (1 - pct);

  return (
    <div className="flex flex-col items-center gap-2">
      <div className="relative" style={{ width: size, height: size }}>
        <svg width={size} height={size} className="-rotate-90 absolute inset-0">
          <circle cx={size / 2} cy={size / 2} r={radius} fill="none" stroke="#1e293b" strokeWidth={strokeWidth} />
          <circle
            cx={size / 2} cy={size / 2} r={radius} fill="none"
            stroke={color} strokeWidth={strokeWidth}
            strokeDasharray={circumference} strokeDashoffset={offset}
            strokeLinecap="round" className="transition-all duration-700 ease-out"
          />
        </svg>
        <div className="absolute inset-0 flex flex-col items-center justify-center">
          <span className="text-2xl font-bold text-white leading-none">{centerText ?? value}</span>
        </div>
      </div>
      {label && <span className="text-xs text-slate-400">{label}</span>}
    </div>
  );
}

function GlassCard({ children, className = '' }) {
  return (
    <div
      className={`bg-slate-900/50 backdrop-blur-md border border-white/10 rounded-3xl ${className}`}
    >
      {children}
    </div>
  );
}

function VisibleFiresCounter({ fires, showFires, onVisibleCountChange }) {
  const map = useMapEvents('moveend', () => {
    if (!showFires || !fires) return;
    const bounds = map.getBounds();
    const visible = fires.filter(f => 
      bounds.contains([f.lat, f.lon])
    );
    onVisibleCountChange(visible.length);
  });
  useEffect(() => {
    if (!showFires || !fires) return;
    const bounds = map.getBounds();
    const visible = fires.filter(f => 
      bounds.contains([f.lat, f.lon])
    );
    onVisibleCountChange(visible.length);
  }, [fires, showFires]);
  return null;
}

function MapaCard({ records, fires, showDeforest, showFires, setShowDeforest, setShowFires, loading, error, t, onVisibleFiresChange }) {
  const mapCenter = [-14.235, -51.925];
  const mapZoom = 4;
  const [satellite, setSatellite] = useState(true);

  const tileUrl = satellite
    ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
    : 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png';
  const tileAttribution = satellite
    ? '&copy; Esri, Earthstar Geographics'
    : '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>';

  return (
    <div className="relative w-full rounded-3xl overflow-hidden border border-white/10" style={{ minHeight: '80vh' }}>
      {/* Map header */}
      <div className="absolute top-0 left-0 right-0 z-[500] flex items-center justify-between px-5 py-3 bg-gradient-to-b from-slate-950/80 to-transparent">
        <div className="flex items-center gap-2">
          <TreePine size={16} className="text-cyan-400" />
          <h2 className="text-sm font-semibold text-white">{t('home.mapTitle')}</h2>
        </div>
        <div className="flex items-center gap-2">
          <button
            onClick={() => setShowDeforest(!showDeforest)}
            className={`flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full transition-colors ${
              showDeforest ? 'bg-cyan-500/30 text-cyan-300' : 'bg-slate-800/70 text-slate-500'
            }`}
          >
            <span className={`w-1.5 h-1.5 rounded-full ${showDeforest ? 'bg-cyan-400' : 'bg-slate-600'}`} />
            PRODES
          </button>
          <button
            onClick={() => setShowFires(!showFires)}
            className={`flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full transition-colors ${
              showFires ? 'bg-red-500/30 text-red-300' : 'bg-slate-800/70 text-slate-500'
            }`}
          >
            <Flame size={11} />
            FIRMS
          </button>
          <button
            onClick={() => setSatellite(!satellite)}
            className={`flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full transition-colors ${
              satellite ? 'bg-indigo-500/30 text-indigo-300' : 'bg-slate-800/70 text-slate-500'
            }`}
          >
            <span className={`w-1.5 h-1.5 rounded-full ${satellite ? 'bg-indigo-400' : 'bg-slate-600'}`} />
            Satelite
          </button>
        </div>
      </div>

      {/* Map */}
      {loading && (
        <div className="absolute inset-0 flex items-center justify-center text-slate-400 text-sm bg-slate-900">
          {t('home.loading')}
        </div>
      )}
      {error && (
        <div className="absolute inset-0 flex items-center justify-center text-red-400 text-sm bg-slate-900">
          {t('home.error')}: {error}
        </div>
      )}
      {!loading && !error && (
        <MapContainer center={mapCenter} zoom={mapZoom} scrollWheelZoom={true} className="w-full h-full" style={{ minHeight: '82vh' }}>
          <TileLayer
            key={satellite ? 'sat' : 'osm'}
            attribution={tileAttribution}
            url={tileUrl}
          />
          <VisibleFiresCounter fires={fires} showFires={showFires} onVisibleCountChange={onVisibleFiresChange} />
          {showDeforest &&
            records &&
            records.slice(0, 500).map((record, idx) => (
              <CircleMarker
                key={`d-${idx}`}
                center={[record.lat, record.lon]}
                pathOptions={{ color: record.color || '#00b4d8', fillColor: record.color, fillOpacity: 0.5 }}
                radius={3}
              >
                <Popup>
                  <strong>{classLabel(record.clazz, t)}</strong><br />
                  {t('home.source')}: PRODES/INPE<br />
                  Lat: {record.lat.toFixed(4)}, Lng: {record.lon.toFixed(4)}
                </Popup>
              </CircleMarker>
            ))}
          {showFires &&
            fires &&
            fires.map((fire, idx) => {
              const style = fireStyle(fire.confidence);
              return (
                <CircleMarker key={`f-${idx}`} center={[fire.lat, fire.lon]} pathOptions={style} radius={style.radius}>
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
    </div>
  );
}

function MetricsRow({ airQuality, temperature, t }) {
  const aqiVal = airQuality ? airQuality.aqi : 0;
  const humVal = temperature ? temperature.humidity : 0;
  const aqiColor = aqiVal <= 50 ? '#22d3ee' : aqiVal <= 100 ? '#facc15' : '#ef4444';
  const aqiLabel = aqiVal <= 50 ? 'Boa' : aqiVal <= 100 ? 'Moderada' : 'Ruim';
  const aqiLabelColor = aqiVal <= 50 ? 'text-emerald-400' : aqiVal <= 100 ? 'text-yellow-400' : 'text-red-400';

  return (
    <GlassCard className="p-2 sm:p-4 flex items-center justify-around gap-2 sm:gap-3">
      <div className="flex flex-col items-center gap-1 sm:gap-3">
        <GaugeCircle value={aqiVal} max={300} size={52} strokeWidth={5} color={aqiColor} centerText={airQuality ? aqiVal : '--'} />
        <div className="text-center">
          <p className="text-[9px] sm:text-sm font-semibold text-white">{t('home.airQuality')}</p>
          <p className="hidden sm:block text-xs text-slate-400">PM2.5: {airQuality ? airQuality.pm25 : '--'}</p>
          <p className={`text-[9px] sm:text-xs font-medium ${aqiLabelColor}`}>{airQuality ? aqiLabel : ''}</p>
        </div>
      </div>
      <div className="w-px h-10 sm:h-16 bg-white/10" />
      <div className="flex flex-col items-center gap-1 sm:gap-3">
        <GaugeCircle value={humVal} max={100} size={52} strokeWidth={5} color="#3b82f6" centerText={humVal ? `${humVal}` : '--'} />
        <div className="text-center">
          <p className="text-[9px] sm:text-sm font-semibold text-white">{t('home.humidity')}</p>
          <p className="text-[8px] sm:text-xs text-slate-400">{temperature?.city || ''}</p>
        </div>
      </div>
    </GlassCard>
  );
}

function TemperatureCard({ temperature, t }) {
  return (
    <GlassCard className="p-2 sm:p-4 flex flex-col items-center justify-center gap-1 sm:gap-2 text-center">
      <div className="flex items-center gap-1 text-slate-400">
        <Thermometer size={11} className="text-orange-400" />
        <span className="text-[9px] sm:text-[10px] font-medium uppercase tracking-wider">{t('home.temperature')}</span>
      </div>
      <div className="flex flex-col items-center gap-0.5 sm:gap-1">
        <span className="text-xl sm:text-3xl font-bold text-white tracking-tight">
          {temperature ? temperature.temp.toFixed(1) : '--'}
          <span className="text-sm sm:text-lg text-orange-400 ml-0.5">°C</span>
        </span>
        {temperature && (
          <span className="text-[9px] sm:text-xs text-slate-400">
            {t('home.feelsLike')}: {temperature.feels_like.toFixed(1)}°
          </span>
        )}
        {temperature?.city && (
          <span className="text-[8px] sm:text-[10px] text-slate-500">{temperature.city}</span>
        )}
      </div>
    </GlassCard>
  );
}

function FiresCard({ fires, visibleCount, lastSync, t }) {
  return (
    <GlassCard className="p-2 sm:p-4 flex flex-col items-center justify-center gap-1 sm:gap-3 text-center">
      <div className="flex flex-col items-center gap-0.5">
        <span className="text-lg sm:text-2xl font-bold text-orange-300 leading-none">
          {(visibleCount ?? fires?.length ?? 0).toLocaleString('pt-BR')}
        </span>
        <span className="text-[8px] sm:text-[9px] text-slate-300 uppercase tracking-wider">
          {t('home.totalOnMap')}
        </span>
      </div>
      <a
        href="https://firms.modaps.eosdis.nasa.gov/map/?lang=pt"
        target="_blank"
        rel="noopener noreferrer"
        className="text-[9px] sm:text-[10px] text-cyan-400 hover:text-cyan-300 transition-colors"
      >
        {t('home.viewOnFirms')}
      </a>
    </GlassCard>
  );
}

const DEFAULT_LAT = -14.235;
const DEFAULT_LON = -51.925;

export default function Home() {
  const { t } = useI18n();
  const [records, setRecords] = useState(null);
  const [fires, setFires] = useState(null);
  const [firesLastSync, setFiresLastSync] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [airQuality, setAirQuality] = useState(null);
  const [temperature, setTemperature] = useState(null);
  const [showDeforest, setShowDeforest] = useState(true);
  const [showFires, setShowFires] = useState(true);

  useEffect(() => {
    fetch('/api/data')
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

    // Load FIRMS from cache first, then fetch fresh data
    const cachedFires = getCache('fires', 10);
    if (cachedFires) {
      setFires(cachedFires.fires || []);
      setFiresLastSync(cachedFires.last_sync || null);
    }
    fetch('/api/fires')
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json();
      })
      .then((d) => {
        const firesData = d.fires || [];
        setFires(firesData);
        setFiresLastSync(d.last_sync || null);
        setCache('fires', { fires: firesData, last_sync: d.last_sync });
      })
      .catch(() => {
        if (!cachedFires) setFires([]);
      });

    const fetchWeather = (lat, lon) => {
      fetch(`/api/weather/air-quality?lat=${lat}&lon=${lon}`)
        .then((r) => r.json())
        .then((d) => {
          if (d.aqi != null) {
            setAirQuality({ aqi: d.aqi, pm25: d.pm25 ?? '-', humidity: d.humidity ?? '-' });
          }
        })
        .catch(() => {});

      fetch(`/api/weather/temperature?lat=${lat}&lon=${lon}`)
        .then((r) => r.json())
        .then((d) => {
          if (d.temp != null) {
            setTemperature({ temp: d.temp, feels_like: d.feels_like, humidity: d.humidity, city: d.city });
          }
        })
        .catch(() => {});
    };

    if (navigator.geolocation) {
      navigator.geolocation.getCurrentPosition(
        (pos) => fetchWeather(pos.coords.latitude, pos.coords.longitude),
        () => fetchWeather(DEFAULT_LAT, DEFAULT_LON),
        { timeout: 5000 }
      );
    } else {
      fetchWeather(DEFAULT_LAT, DEFAULT_LON);
    }
  }, []);

  const [visibleFiresCount, setVisibleFiresCount] = useState(null);

  return (
    <div className="min-h-screen p-4 lg:p-6">
      <div className="w-full max-w-[1920px] mx-auto relative">
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
          firesLastSync={firesLastSync}
          onVisibleFiresChange={setVisibleFiresCount}
        />
        {/* Floating widgets - right column */}
        <div className="absolute top-16 right-2 z-[500] flex flex-col gap-2 w-32 sm:top-20 sm:right-4 sm:gap-3 sm:w-52">
          <FiresCard fires={fires} visibleCount={visibleFiresCount} lastSync={firesLastSync} t={t} />
        </div>
        {/* Floating widget - bottom left */}
        <div className="absolute bottom-8 left-2 z-[500] w-40 sm:bottom-10 sm:left-4 sm:w-60">
          <MetricsRow airQuality={airQuality} temperature={temperature} t={t} />
        </div>
        {/* Floating widget - bottom right */}
        <div className="absolute bottom-8 right-2 z-[500] w-32 sm:bottom-10 sm:right-4 sm:w-52">
          <TemperatureCard temperature={temperature} t={t} />
        </div>
      </div>
    </div>
  );
}
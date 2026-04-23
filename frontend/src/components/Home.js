import React, { useEffect, useState, useMemo } from 'react';
import { MapContainer, TileLayer, CircleMarker, Popup } from 'react-leaflet';
import { PieChart, Pie, Cell, BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer } from 'recharts';
import 'leaflet/dist/leaflet.css';
import '../Home.css';

const BBOX = { ne_lat: 5.5, ne_lng: -34.0, sw_lat: -34.0, sw_lng: -74.0 };

const CLASS_LABELS = {
  d: 'Desmatamento',
  r: 'Regeneração',
  f: 'Floresta',
  h: 'Hidrografia',
  n: 'Não floresta',
};

const FIRE_STYLES = {
  nominal: { color: '#ef4444', fillColor: '#ef4444', fillOpacity: 0.85, radius: 5 },
  high: { color: '#f97316', fillColor: '#f97316', fillOpacity: 0.8, radius: 4 },
  low: { color: '#fbbf24', fillColor: '#fbbf24', fillOpacity: 0.4, radius: 3 },
};

function classLabel(clazz) {
  if (!clazz) return 'Desconhecido';
  const key = clazz.toLowerCase().charAt(0);
  return CLASS_LABELS[key] || clazz;
}

function fireStyle(confidence) {
  const key = (confidence || 'low').toLowerCase();
  if (key === 'nominal' || key === 'h') return FIRE_STYLES.nominal;
  if (key === 'high' || key === 'high') return FIRE_STYLES.high;
  return FIRE_STYLES.low;
}

function WidgetCard({ title, value, sub, icon, accent, children }) {
  return (
    <div className="widget-card" style={{ '--accent': accent || '#00b4d8' }}>
      <div className="widget-card__header">
        <span className="widget-card__icon">{icon}</span>
        <h3 className="widget-card__title">{title}</h3>
      </div>
      {value && (
        <div className="widget-card__value">
          {value}
          {sub && <span className="widget-card__sub">{sub}</span>}
        </div>
      )}
      {children}
    </div>
  );
}

function FiresWidget({ fires, lastSync }) {
  const last3 = useMemo(() => {
    if (!fires || !fires.length) return 0;
    const threeDaysAgo = new Date();
    threeDaysAgo.setDate(threeDaysAgo.getDate() - 3);
    return fires.filter((f) => new Date(f.acq_date) >= threeDaysAgo).length;
  }, [fires]);

  return (
    <div className="fires-widget">
      <div className="fires-widget__header">
        <span className="widget-card__icon">🔥</span>
        <h3 className="widget-card__title">Queimadas Recentes</h3>
      </div>
      <div className="fires-widget__stats">
        <div className="fires-stat">
          <span className="fires-stat__value">{last3.toLocaleString('pt-BR')}</span>
          <span className="fires-stat__label">Últimos 3 dias</span>
        </div>
        <div className="fires-stat">
          <span className="fires-stat__value">{(fires?.length || 0).toLocaleString('pt-BR')}</span>
          <span className="fires-stat__label">Total no mapa</span>
        </div>
      </div>
      {lastSync && (
        <div className="fires-widget__sync">
          <span className="badge-dot" />
          <span>Sync: {new Date(lastSync).toLocaleDateString('pt-BR')}</span>
        </div>
      )}
      <a
        href="https://firms.modaps.eosdis.nasa.gov/map/?lang=pt"
        target="_blank"
        rel="noopener noreferrer"
        className="fires-widget__link"
      >
        ↗ Ver no FIRMS
      </a>
    </div>
  );
}

function LayerToggle({ label, icon, active, onChange, color }) {
  return (
    <label className="layer-toggle">
      <input type="checkbox" checked={active} onChange={(e) => onChange(e.target.checked)} />
      <span className="layer-toggle__dot" style={{ background: active ? color : '#555' }} />
      <span className="layer-toggle__icon">{icon}</span>
      <span className="layer-toggle__label">{label}</span>
    </label>
  );
}

export default function Home() {
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

    fetch(`/api/fires?${params}`)
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json();
      })
      .then((d) => {
        setFires(d.fires || []);
        setFiresLastSync(d.last_sync || null);
      })
      .catch(() => {
        setFires([]);
      });

    fetch('/api/weather/air-quality')
      .then((r) => r.json())
      .then((d) => {
        if (d.aqi != null) {
          setAirQuality({ aqi: d.aqi, pm25: d.pm25 ?? '-', humidity: d.humidity ?? '-' });
        }
      })
      .catch(() => {});

    fetch('/api/weather/temperature')
      .then((r) => r.json())
      .then((d) => {
        if (d.temp != null) {
          setTemperature({ temp: d.temp, feels_like: d.feels_like, city: d.city });
        }
      })
      .catch(() => {});
  }, []);

  const stats = useMemo(() => {
    if (!records) return null;
    const byClazz = {};

    records.forEach(({ clazz, color }) => {
      const label = classLabel(clazz);
      byClazz[label] = (byClazz[label] || { count: 0, color: color || '#888' });
      byClazz[label].count += 1;
    });

    const sorted = Object.entries(byClazz).sort((a, b) => b[1].count - a[1].count);
    const total = records.length;

    return {
      total,
      categories: sorted.length,
      sorted,
      pieData: sorted.map(([name, { count, color }]) => ({ name, value: count, color })),
    };
  }, [records]);

  const mapCenter = [-14.235, -51.925];
  const mapZoom = 4;

  return (
    <div className="home-new">
      <div className="home-header">
        <h1 className="home-title">Environmental Observability Brazil</h1>
        <p className="home-subtitle">Monitoramento ambiental em tempo real</p>
      </div>

      <div className="home-grid">
        <div className="home-grid__main">
          <div className="map-card-large">
            <div className="map-card-large__header">
              <div className="map-card-large__header-left">
                <h2>Mapa de Desmatamento &amp; Queimadas</h2>
                <div className="layer-toggles">
                  <LayerToggle
                    label="PRODES"
                    icon="🌳"
                    active={showDeforest}
                    onChange={setShowDeforest}
                    color="#00b4d8"
                  />
                  <LayerToggle
                    label="Queimadas FIRMS"
                    icon="🔥"
                    active={showFires}
                    onChange={setShowFires}
                    color="#ef4444"
                  />
                </div>
              </div>
              <div className="map-card-large__badges">
                <span className="map-badge">
                  <span className="badge-dot" />
                  PRODES · INPE
                </span>
                {firesLastSync && (
                  <span className="map-badge map-badge--fire">
                    <span className="badge-dot badge-dot--fire" />
                    FIRMS · {new Date(firesLastSync).toLocaleDateString('pt-BR')}
                  </span>
                )}
              </div>
            </div>
            <div className="map-card-large__body">
              {loading && <div className="map-loading">Carregando mapa...</div>}
              {error && <div className="map-error">Erro: {error}</div>}
              {!loading && !error && (
                <MapContainer center={mapCenter} zoom={mapZoom} scrollWheelZoom={true} className="leaflet-map">
                  <TileLayer
                    attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
                    url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
                  />
                  {showDeforest && records && records.slice(0, 500).map((record, idx) => (
                    <CircleMarker
                      key={`d-${idx}`}
                      center={[record.lat, record.lon]}
                      pathOptions={{ color: record.color || '#00b4d8', fillColor: record.color, fillOpacity: 0.5 }}
                      radius={3}
                    >
                      <Popup>
                        <strong>{classLabel(record.clazz)}</strong>
                        <br />
                        Fonte: PRODES/INPE
                        <br />
                        Lat: {record.lat.toFixed(4)}, Lng: {record.lon.toFixed(4)}
                      </Popup>
                    </CircleMarker>
                  ))}
                  {showFires && fires && fires.map((fire, idx) => {
                    const style = fireStyle(fire.confidence);
                    return (
                      <CircleMarker
                        key={`f-${idx}`}
                        center={[fire.lat, fire.lon]}
                        pathOptions={style}
                        radius={style.radius}
                      >
                        <Popup>
                          <strong>🔥 Foco de Calor</strong>
                          <br />
                          Confiança: {fire.confidence}
                          <br />
                          Data: {fire.acq_date} {fire.acq_time}
                          <br />
                          Satélite: {fire.satellite}
                          <br />
                          Temp. brilho: {fire.bright_ti4}K
                          <br />
                          Fonte: NASA FIRMS
                        </Popup>
                      </CircleMarker>
                    );
                  })}
                </MapContainer>
              )}
            </div>
          </div>
        </div>

        <div className="home-grid__sidebar">
          <WidgetCard
            title="Air Quality"
            value={airQuality ? airQuality.aqi : '--'}
            sub={airQuality ? `PM2.5: ${airQuality.pm25}` : ''}
            icon="💨"
            accent="#4ade80"
          >
            {airQuality && (
              <div className="aqi-gauge">
                <div className="gauge-bar" style={{ width: `${Math.min(100, (airQuality.aqi / 300) * 100)}%` }} />
              </div>
            )}
          </WidgetCard>

          <WidgetCard
            title="Temperature"
            value={temperature ? `${temperature.temp.toFixed(1)}°` : '--'}
            sub={temperature ? `Sensação: ${temperature.feels_like.toFixed(1)}°` : ''}
            icon="🌡️"
            accent="#f97316"
          >
            {temperature && (
              <div className="temp-slider">
                <div className="temp-indicator" style={{ left: `${Math.min(100, Math.max(0, ((temperature.temp + 10) / 50) * 100))}%` }} />
              </div>
            )}
          </WidgetCard>

          <FiresWidget fires={fires} lastSync={firesLastSync} />
        </div>

        <div className="home-grid__bottom">
          <div className="chart-card">
            <div className="chart-card__header">
              <h2>Distribuição por Categoria</h2>
              <span className="chart-total">{stats?.total.toLocaleString('pt-BR') || 0} pontos</span>
            </div>
            <div className="chart-body">
              <ResponsiveContainer width="100%" height={250}>
                <PieChart>
                  <Pie
                    data={stats?.pieData || []}
                    cx="50%"
                    cy="50%"
                    innerRadius={60}
                    outerRadius={100}
                    paddingAngle={2}
                    dataKey="value"
                    label={({ name, percent }) => `${name} ${(percent * 100).toFixed(0)}%`}
                  >
                    {(stats?.pieData || []).map((entry, index) => (
                      <Cell key={`cell-${index}`} fill={entry.color} />
                    ))}
                  </Pie>
                  <Tooltip />
                </PieChart>
              </ResponsiveContainer>
            </div>
          </div>

          <div className="chart-card">
            <div className="chart-card__header">
              <h2>Air Quality Details</h2>
            </div>
            <div className="chart-body">
              <div className="aqi-cards">
                <div className="aqi-circle" style={{ borderColor: '#4ade80' }}>
                  <span className="aqi-value">{airQuality?.aqi || '--'}</span>
                  <span className="aqi-label">AQI</span>
                </div>
                <div className="aqi-circle" style={{ borderColor: '#f97316' }}>
                  <span className="aqi-value">{airQuality?.pm25 || '--'}</span>
                  <span className="aqi-label">PM2.5</span>
                </div>
                <div className="aqi-circle" style={{ borderColor: '#00b4d8' }}>
                  <span className="aqi-value">{airQuality?.humidity || '--'}</span>
                  <span className="aqi-label">Humidity</span>
                </div>
              </div>
            </div>
          </div>

          <div className="chart-card">
            <div className="chart-card__header">
              <h2>Categorias - Detalhado</h2>
            </div>
            <div className="chart-body">
              <ResponsiveContainer width="100%" height={200}>
                <BarChart data={stats?.sorted.slice(0, 5).map(([name, { count }]) => ({ name, count })) || []}>
                  <XAxis dataKey="name" />
                  <YAxis />
                  <Tooltip />
                  <Bar dataKey="count" fill="#00b4d8" />
                </BarChart>
              </ResponsiveContainer>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
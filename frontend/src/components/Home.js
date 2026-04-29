import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { MapContainer, TileLayer, CircleMarker, Circle, Popup, GeoJSON, useMapEvents } from 'react-leaflet';
import { TreePine, Flame, ChevronDown } from 'lucide-react';
import { useI18n } from '../i18n';
import { getCache, setCache } from '../utils/cache';
import 'leaflet/dist/leaflet.css';
import '../Home.css';

const FIRE_STYLES = {
  nominal: { color: '#ef4444', fillColor: '#ef4444', fillOpacity: 0.85, radius: 5, weight: 1 },
  high:    { color: '#f97316', fillColor: '#f97316', fillOpacity: 0.8,  radius: 4, weight: 1 },
  low:     { color: '#fbbf24', fillColor: '#fbbf24', fillOpacity: 0.4,  radius: 3, weight: 1 },
};

function haversineKm(lat1, lon1, lat2, lon2) {
  const R = 6371, rad = Math.PI / 180;
  const p1 = lat1 * rad, p2 = lat2 * rad;
  const a = Math.sin((lat2 - lat1) * rad / 2) ** 2
          + Math.cos(p1) * Math.cos(p2) * Math.sin((lon2 - lon1) * rad / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function alertForFire(fire, alerts) {
  let best = null, bestDist = Infinity;
  for (const a of alerts) {
    if (!a.center) continue;
    const d = haversineKm(fire.lat, fire.lon, a.center[0], a.center[1]);
    if (d <= (a.radius_km || 15) && d < bestDist) { bestDist = d; best = a.id; }
  }
  return best;
}

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

function FireHoverLock({ fires, hoveredFireIdx, lockedFireIdx, onHoverEnd, onClearLock }) {
  const map = useMapEvents({
    mousemove: (e) => {
      if (lockedFireIdx != null) return;
      if (hoveredFireIdx == null) return;
      const fire = fires?.[hoveredFireIdx];
      if (!fire) {
        onHoverEnd();
        return;
      }
      const cursor = map.latLngToContainerPoint(e.latlng);
      const firePoint = map.latLngToContainerPoint([fire.lat, fire.lon]);
      const baseRadius = fireStyle(fire.confidence).radius;
      const lockRadius = Math.max(baseRadius + 6, 10);
      if (cursor.distanceTo(firePoint) > lockRadius) {
        onHoverEnd();
      }
    },
    mouseout: () => {
      if (lockedFireIdx != null) return;
      if (hoveredFireIdx != null) onHoverEnd();
    },
    click: () => {
      if (lockedFireIdx != null) onClearLock();
    },
  });
  return null;
}

function windDir(deg) {
  if (deg == null) return '—';
  const dirs = ['N','NE','L','SE','S','SO','O','NO'];
  return dirs[Math.round(deg / 45) % 8];
}

function boundsToGeoJSON(raw) {
  return {
    type: 'FeatureCollection',
    features: Object.entries(raw).map(([name, d]) => ({
      type: 'Feature',
      properties: { name, state_abbr: d.state_abbr, municipality: d.municipality, category: d.category, full_name: d.full_name },
      geometry: { type: 'MultiPolygon', coordinates: d.rings.map(r => [r]) },
    })),
  };
}

function GaugeRing({ value, max, color, size = 64 }) {
  const r = (size - 8) / 2;
  const c = 2 * Math.PI * r;
  const pct = Math.min(1, Math.max(0, value / max));
  return (
    <svg viewBox={`0 0 ${size} ${size}`} style={{ width: '100%', height: '100%', transform: 'rotate(-90deg)' }}>
      <circle cx={size/2} cy={size/2} r={r} fill="none" stroke="rgba(255,255,255,0.07)" strokeWidth="5" />
      <circle cx={size/2} cy={size/2} r={r} fill="none" stroke={color} strokeWidth="5"
        strokeDasharray={c} strokeDashoffset={c * (1 - pct)} strokeLinecap="round"
        style={{ transition: 'stroke-dashoffset 1s ease', filter: `drop-shadow(0 0 4px ${color})` }}
      />
    </svg>
  );
}

function DraggableCard({ className, style, children, title, collapsed: controlledCollapsed, onToggleCollapse }) {
  const [internalCollapsed, setInternalCollapsed] = useState(false);
  const collapsed = controlledCollapsed != null ? controlledCollapsed : internalCollapsed;
  const handleToggle = onToggleCollapse || (() => setInternalCollapsed(c => !c));
  const [offset, setOffset] = useState(null);
  const isDragging = useRef(false);
  const startData = useRef(null);
  const elRef = useRef(null);

  const onMouseDown = (e) => {
    if (e.button !== 0) return;
    const el = elRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    const parent = el.offsetParent?.getBoundingClientRect() || { top: 0, left: 0 };
    startData.current = {
      mouseX: e.clientX, mouseY: e.clientY,
      top:  offset ? offset.top  : rect.top  - parent.top,
      left: offset ? offset.left : rect.left - parent.left,
      moved: false,
    };
    isDragging.current = true;
  };

  useEffect(() => {
    const onMove = (e) => {
      if (!isDragging.current || !startData.current) return;
      const dx = e.clientX - startData.current.mouseX;
      const dy = e.clientY - startData.current.mouseY;
      if (!startData.current.moved && Math.hypot(dx, dy) < 4) return;
      startData.current.moved = true;
      setOffset({ top: startData.current.top + dy, left: startData.current.left + dx });
    };
    const onUp = () => { isDragging.current = false; };
    window.addEventListener('mousemove', onMove);
    window.addEventListener('mouseup', onUp);
    return () => { window.removeEventListener('mousemove', onMove); window.removeEventListener('mouseup', onUp); };
  }, []);

  const posStyle = offset ? { top: offset.top, left: offset.left, right: 'auto', bottom: 'auto' } : {};
  return (
    <div ref={elRef} className={`${className}${collapsed ? ' card-collapsed' : ''}`} style={{ ...style, ...posStyle, cursor: 'grab', userSelect: 'none' }} onMouseDown={onMouseDown}>
      {title && (
        <div className="card-collapse-bar" onMouseDown={e => e.stopPropagation()} onClick={handleToggle}>
          <span className="card-collapse-title">{title}</span>
          <ChevronDown size={14} className={`card-collapse-chevron${collapsed ? ' flipped' : ''}`} />
        </div>
      )}
      <div className={`card-body${collapsed ? ' card-body-hidden' : ''}`}>
        {children}
      </div>
    </div>
  );
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


const BiomePanel = React.memo(function BiomePanel() {
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
            <div className="biome-val" style={{ color: b.color || 'var(--ink-2, rgba(255,255,255,0.65))' }}>{b.count.toLocaleString('pt-BR')}</div>
          </div>
        ))}
      </div>
    </div>
  );
});

const ALERT_TYPE_KEYS = {
  cluster: 'alertCluster',
  night_fire: 'alertNightFire',
  indigenous_land: 'alertIndigenousLand',
  conservation_unit: 'alertConservationUnit',
  prodes: 'alertProdes',
  pm25: 'alertPm25',
};

const AlertsPanel = React.memo(function AlertsPanel({ alerts, activeAlertId, onAlertEnter, onAlertLeave }) {
  const { t } = useI18n();

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
          <div
            key={a.id || i}
            className={`alert-row${activeAlertId === a.id ? ' alert-row--active' : ''}`}
            onMouseEnter={() => onAlertEnter(a.id)}
            onMouseLeave={onAlertLeave}
          >
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
});

const MapaCard = React.memo(function MapaCard({ records, fires, showDeforest, showFires, setShowDeforest, setShowFires, showIndigenous, setShowIndigenous, showConservation, setShowConservation, indigenousGeo, conservationGeo, loading, error, t, airQuality, temperature, alerts, activeAlertId, hoveredFireIdx, lockedFireIdx, onFireOver, onFireHoverEnd, onFireClick, onClearFireLock, onAlertEnter, onAlertLeave }) {
  const [satellite, setSatellite] = useState(true);
  const [visibleCount, setVisibleCount] = useState(null);

  const activeAlert = useMemo(() => alerts?.find(a => a.id === activeAlertId) || null, [alerts, activeAlertId]);

  const highlightedFires = useMemo(() => {
    if (!activeAlert?.center || !fires) return null;
    const [alat, alon] = activeAlert.center;
    const rkm = (activeAlert.radius_km || 15) * 1.25;
    const s = new Set();
    fires.forEach((f, i) => { if (haversineKm(f.lat, f.lon, alat, alon) <= rkm) s.add(i); });
    return s;
  }, [activeAlert, fires]);

  const ringColor = activeAlert
    ? (activeAlert.tick === 'crit' ? '#ef4444' : activeAlert.tick === 'warn' ? '#f97316' : '#2dd4ff')
    : '#2dd4ff';

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
          <button
            className={`layer-toggle${showIndigenous ? ' on-amber' : ''}`}
            onClick={() => setShowIndigenous(!showIndigenous)}
          >
            <span className="lt-dot" /> TI
          </button>
          <button
            className={`layer-toggle${showConservation ? ' on-green' : ''}`}
            onClick={() => setShowConservation(!showConservation)}
          >
            <span className="lt-dot" /> UC
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
          <FireHoverLock
            fires={fires}
            hoveredFireIdx={hoveredFireIdx}
            lockedFireIdx={lockedFireIdx}
            onHoverEnd={onFireHoverEnd}
            onClearLock={onClearFireLock}
          />
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
          {showFires && activeAlert?.center && (
            <Circle
              center={activeAlert.center}
              radius={(activeAlert.radius_km || 15) * 1250}
              pathOptions={{ color: ringColor, fillColor: ringColor, fillOpacity: 0.04, weight: 1.5, opacity: 0.65, dashArray: '6 4', className: 'alert-highlight-ring' }}
            />
          )}
          {showIndigenous && indigenousGeo && (
            <GeoJSON
              key="indigenous"
              data={indigenousGeo}
              style={() => ({ color: '#f59e0b', fillColor: '#f59e0b', fillOpacity: 0.12, weight: 1.5, opacity: 0.6 })}
              onEachFeature={(feature, layer) => {
                const p = feature.properties;
                layer.bindPopup(`<strong>🏕 ${p.name}</strong><br/>Terra Indígena · ${p.state_abbr || ''}<br/><small>${p.municipality || ''}</small>`);
              }}
            />
          )}
          {showConservation && conservationGeo && (
            <GeoJSON
              key="conservation"
              data={conservationGeo}
              style={() => ({ color: '#4ade80', fillColor: '#4ade80', fillOpacity: 0.1, weight: 1.5, opacity: 0.55 })}
              onEachFeature={(feature, layer) => {
                const p = feature.properties;
                layer.bindPopup(`<strong>🌿 ${p.name}</strong><br/>${p.category || 'UC'} · ${p.state_abbr || ''}`);
              }}
            />
          )}
          {showFires && fires && fires.map((fire, idx) => {
            const hi = highlightedFires?.has(idx);
            const s = fireStyle(fire.confidence);
            const fireAlertId = alertForFire(fire, alerts || []);
            const fireAlert = alerts?.find(a => a.id === fireAlertId) || null;
            const landTag = fireAlert && (() => {
              if (fireAlert.type === 'indigenous_land')   return { cls: 'indigenous',   label: `Terra Indígena: ${fireAlert.meta}` };
              if (fireAlert.type === 'conservation_unit') return { cls: 'conservation', label: `UC: ${fireAlert.meta}` };
              if (fireAlert.type === 'night_fire')        return { cls: 'night-fire',   label: 'Foco Noturno' };
              if (fireAlert.type === 'prodes')            return { cls: 'prodes',       label: `PRODES: ${fireAlert.meta}` };
              return null;
            })();
            return (
              <React.Fragment key={`f-${idx}`}>
                <CircleMarker
                  center={[fire.lat, fire.lon]}
                  pathOptions={s}
                  radius={s.radius}
                  eventHandlers={{
                    mouseover: () => onFireOver(fireAlertId, idx),
                    click: (e) => onFireClick(fireAlertId, idx, e),
                  }}
                >
                  <Popup>
                    <strong>{t('home.heatFocus')}</strong><br />
                    {t('home.confidence')}: {fire.confidence}<br />
                    {t('home.date')}: {fire.acq_date} {fire.acq_time}<br />
                    {t('home.satellite')}: {fire.satellite}<br />
                    {t('home.brightnessTemp')}: {fire.bright_ti4}K
                    {landTag && (
                      <>
                        <br />
                        <span className={`fire-land-tag ${landTag.cls}`}>{landTag.label}</span>
                        {fireAlert.state && <><br /><span style={{ fontSize: 10, color: '#888' }}>{fireAlert.state}</span></>}
                      </>
                    )}
                    <br />
                    {t('home.sourceNasa')}
                  </Popup>
                </CircleMarker>
                {hi && (
                  <CircleMarker
                    center={[fire.lat, fire.lon]}
                    pathOptions={{ color: '#fff', fillColor: s.fillColor, fillOpacity: 1, radius: s.radius + 3, weight: 2 }}
                    interactive={false}
                  />
                )}
              </React.Fragment>
            );
          })}
        </MapContainer>
      )}

      {/* Floating: fires — top right */}
      <DraggableCard className="fl-card fl-stats" title={t('home.heatFocus')}>
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
      </DraggableCard>

      {/* Floating: 4-gauge weather card — bottom left */}
      <DraggableCard className="fl-card fl-weather" title={temperature?.city ? `CLIMA · ${temperature.city}` : 'CLIMA'}>
        <div className="fl-weather__gauges">
          <div className="fl-weather__gauge">
            <div className="fl-weather__gauge-svg">
              <GaugeRing value={aqiVal} max={300} color={aqiColor} size={56} />
              <div className="fl-weather__gauge-num" style={{ color: aqiColor }}>{airQuality ? aqiVal : '—'}</div>
            </div>
            <div className="fl-weather__gauge-label">AQI</div>
            <div className="fl-weather__gauge-sub">{airQuality ? `PM2.5·${airQuality.pm25}` : '—'}</div>
          </div>
          <div className="fl-weather__gauge">
            <div className="fl-weather__gauge-svg">
              <GaugeRing value={humVal} max={100} color="#3b82f6" size={56} />
              <div className="fl-weather__gauge-num">{humVal || '—'}</div>
            </div>
            <div className="fl-weather__gauge-label">{t('home.humidity')}</div>
            <div className="fl-weather__gauge-sub">%</div>
          </div>
          <div className="fl-weather__gauge">
            <div className="fl-weather__gauge-svg">
              <GaugeRing value={temperature ? Math.max(temperature.temp, 0) : 0} max={45} color="#fb923c" size={56} />
              <div className="fl-weather__gauge-num">{temperature ? temperature.temp.toFixed(0) : '—'}</div>
            </div>
            <div className="fl-weather__gauge-label">Temp</div>
            <div className="fl-weather__gauge-sub">{temperature ? `SC ${temperature.feels_like.toFixed(0)}°` : '—'}</div>
          </div>
          <div className="fl-weather__gauge">
            <div className="fl-weather__gauge-svg">
              <GaugeRing value={temperature?.wind_speed ?? 0} max={80} color="#2dd4ff" size={56} />
              <div className="fl-weather__gauge-num">{temperature?.wind_speed != null ? Math.round(temperature.wind_speed) : '—'}</div>
            </div>
            <div className="fl-weather__gauge-label">Vento</div>
            <div className="fl-weather__gauge-sub">{windDir(temperature?.wind_direction)}</div>
          </div>
        </div>
      </DraggableCard>

      {/* Floating: biome panel — top left */}
      <DraggableCard className="fl-panel-biome" title={t('home.focosByBiome')}>
        <BiomePanel />
      </DraggableCard>

      {/* Floating: alerts panel — right, below fires count */}
      <DraggableCard className="fl-panel-alerts" title={t('home.liveAlerts')}>
        <AlertsPanel
          alerts={alerts}
          activeAlertId={activeAlertId}
          onAlertEnter={onAlertEnter}
          onAlertLeave={onAlertLeave}
        />
      </DraggableCard>
    </div>
  );
});

const DEFAULT_LAT = -14.235;
const DEFAULT_LON = -51.925;

export default function Home() {
  const { t } = useI18n();
  const [records,        setRecords]        = useState(null);
  const [fires,          setFires]          = useState(null);
  const [loading,        setLoading]        = useState(false);
  const [error,          setError]          = useState(null);
  const [airQuality,     setAirQuality]     = useState(null);
  const [temperature,    setTemperature]    = useState(null);
  const [showDeforest,   setShowDeforest]   = useState(false);
  const [showFires,      setShowFires]      = useState(true);
  const [showIndigenous, setShowIndigenous] = useState(true);
  const [showConservation, setShowConservation] = useState(true);
  const [indigenousGeo,  setIndigenousGeo]  = useState(null);
  const [conservationGeo, setConservationGeo] = useState(null);
  const [alerts,         setAlerts]         = useState([]);
  const [alertHoverId,   setAlertHoverId]   = useState(null);
  const [fireAlertId,    setFireAlertId]    = useState(null);
  const [hoveredFireIdx, setHoveredFireIdx] = useState(null);
  const [lockedFireIdx,  setLockedFireIdx]  = useState(null);
  const [lockedFireAlertId, setLockedFireAlertId] = useState(null);
  const fireHoverOutTimeoutRef = useRef(null);
  const deforestFetchedRef  = useRef(false);
  const indiFetchedRef      = useRef(false);
  const consFetchedRef      = useRef(false);

  const activeAlertId = lockedFireAlertId || alertHoverId || fireAlertId;

  const handleFireOver = (id, idx) => {
    if (lockedFireIdx != null && lockedFireIdx !== idx) return;
    if (fireHoverOutTimeoutRef.current) {
      clearTimeout(fireHoverOutTimeoutRef.current);
      fireHoverOutTimeoutRef.current = null;
    }
    setHoveredFireIdx(idx);
    setFireAlertId(id);
  };

  const clearFireHover = () => {
    if (lockedFireIdx != null) return;
    if (fireHoverOutTimeoutRef.current) {
      clearTimeout(fireHoverOutTimeoutRef.current);
    }
    fireHoverOutTimeoutRef.current = setTimeout(() => {
      setHoveredFireIdx(null);
      setFireAlertId(null);
      fireHoverOutTimeoutRef.current = null;
    }, 80);
  };

  const handleFireClick = (id, idx, e) => {
    if (e?.originalEvent?.stopPropagation) e.originalEvent.stopPropagation();
    if (lockedFireIdx === idx) {
      setLockedFireIdx(null);
      setLockedFireAlertId(null);
      return;
    }
    if (id == null) {
      setLockedFireIdx(null);
      setLockedFireAlertId(null);
      return;
    }
    setLockedFireIdx(idx);
    setLockedFireAlertId(id);
    setHoveredFireIdx(null);
    setFireAlertId(null);
  };

  const clearFireLock = useCallback(() => {
    setLockedFireIdx(null);
    setLockedFireAlertId(null);
    setHoveredFireIdx(null);
    setFireAlertId(null);
  }, []);

  const handleAlertEnter = useCallback(id => setAlertHoverId(id), []);
  const handleAlertLeave = useCallback(() => setAlertHoverId(null), []);

  useEffect(() => () => {
    if (fireHoverOutTimeoutRef.current) {
      clearTimeout(fireHoverOutTimeoutRef.current);
    }
  }, []);

  useEffect(() => {
    const fetchAlerts = () => {
      fetch('/api/alerts')
        .then(r => r.json())
        .then(d => setAlerts(d.alerts || []))
        .catch(() => {});
    };
    fetchAlerts();
    const id = setInterval(fetchAlerts, 60000);
    return () => clearInterval(id);
  }, []);

  // Fire data (cached 4h)
  useEffect(() => {
    const cached = getCache('fires', 240);
    if (cached) setFires(cached.fires || []);
    fetch('/api/fires')
      .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
      .then(d => { const f = d.fires || []; setFires(f); setCache('fires', { fires: f, last_sync: d.last_sync }); })
      .catch(() => { if (!cached) setFires([]); });
  }, []);

  // Weather (cached 15min in localStorage)
  useEffect(() => {
    const fetchWeather = (lat, lon) => {
      const latK = lat.toFixed(1), lonK = lon.toFixed(1);
      const aqiKey = `weather_aqi_${latK}_${lonK}`;
      const tempKey = `weather_temp_${latK}_${lonK}`;

      const cachedAqi = getCache(aqiKey, 15);
      if (cachedAqi) { setAirQuality(cachedAqi); }
      else {
        fetch(`/api/weather/air-quality?lat=${lat}&lon=${lon}`)
          .then(r => r.json())
          .then(d => {
            if (d.aqi != null) {
              const aq = { aqi: d.aqi, pm25: d.pm25 ?? '-', humidity: d.humidity ?? '-' };
              setAirQuality(aq); setCache(aqiKey, aq);
            }
          }).catch(() => {});
      }

      const cachedTemp = getCache(tempKey, 15);
      if (cachedTemp) { setTemperature(cachedTemp); }
      else {
        fetch(`/api/weather/temperature?lat=${lat}&lon=${lon}`)
          .then(r => r.json())
          .then(d => {
            if (d.temp != null) {
              const temp = { temp: d.temp, feels_like: d.feels_like, humidity: d.humidity, city: d.city, wind_speed: d.wind_speed, wind_direction: d.wind_direction };
              setTemperature(temp); setCache(tempKey, temp);
            }
          }).catch(() => {});
      }
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

  // Lazy-load PRODES deforestation points (only when layer enabled)
  useEffect(() => {
    if (!showDeforest || deforestFetchedRef.current) return;
    deforestFetchedRef.current = true;
    const cached = getCache('prodes_records', 15);
    if (cached) { setRecords(cached); return; }
    setLoading(true);
    fetch('/api/data')
      .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
      .then(d => { const rows = Array.isArray(d) ? d : []; setRecords(rows); setCache('prodes_records', rows); setLoading(false); })
      .catch(e => { setError(e.message); setLoading(false); });
  }, [showDeforest]);

  // Lazy-load indigenous lands boundary
  useEffect(() => {
    if (!showIndigenous || indiFetchedRef.current) return;
    indiFetchedRef.current = true;
    fetch('/api/indigenous-lands')
      .then(r => r.json())
      .then(d => setIndigenousGeo(boundsToGeoJSON(d)))
      .catch(() => {});
  }, [showIndigenous]);

  // Lazy-load conservation units boundary
  useEffect(() => {
    if (!showConservation || consFetchedRef.current) return;
    consFetchedRef.current = true;
    fetch('/api/conservation-units')
      .then(r => r.json())
      .then(d => setConservationGeo(boundsToGeoJSON(d)))
      .catch(() => {});
  }, [showConservation]);

  return (
    <div className="home-main">
      <MapaCard
        records={records}
        fires={fires}
        showDeforest={showDeforest}
        showFires={showFires}
        setShowDeforest={setShowDeforest}
        setShowFires={setShowFires}
        showIndigenous={showIndigenous}
        setShowIndigenous={setShowIndigenous}
        showConservation={showConservation}
        setShowConservation={setShowConservation}
        indigenousGeo={indigenousGeo}
        conservationGeo={conservationGeo}
        loading={loading}
        error={error}
        t={t}
        airQuality={airQuality}
        temperature={temperature}
        alerts={alerts}
        activeAlertId={activeAlertId}
        hoveredFireIdx={hoveredFireIdx}
        lockedFireIdx={lockedFireIdx}
        onFireOver={handleFireOver}
        onFireHoverEnd={clearFireHover}
        onFireClick={handleFireClick}
        onClearFireLock={clearFireLock}
        onAlertEnter={handleAlertEnter}
        onAlertLeave={handleAlertLeave}
      />
    </div>
  );
}

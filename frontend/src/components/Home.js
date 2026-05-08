import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { MapContainer, TileLayer, CircleMarker, Circle, Popup, GeoJSON, useMapEvents } from 'react-leaflet';
import { TreePine, Flame, ChevronDown } from 'lucide-react';
import { useI18n } from '../i18n';
import { getCache, setCache } from '../utils/cache';
import 'leaflet/dist/leaflet.css';
import '../Home.css';
import L from 'leaflet';

const FIRE_STYLES = {
  nominal: { color: '#ef4444', fillColor: '#ef4444', fillOpacity: 0.85, radius: 5, weight: 1 },
  high:    { color: '#f97316', fillColor: '#f97316', fillOpacity: 0.8,  radius: 4, weight: 1 },
  low:     { color: '#fbbf24', fillColor: '#fbbf24', fillOpacity: 0.4,  radius: 3, weight: 1 },
};

const asArray = value => Array.isArray(value) ? value : [];
const asObject = value => value && typeof value === 'object' && !Array.isArray(value) ? value : {};

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

function VisibleFiresCounter({ fires, showFires, onVisibleCountChange, onBboxChange }) {
  const timerRef = useRef(null);
  const bboxTimerRef = useRef(null);
  const update = (map) => {
    if (!showFires || !fires) return;
    clearTimeout(timerRef.current);
    timerRef.current = setTimeout(() => {
      const bounds = map.getBounds();
      onVisibleCountChange(fires.filter(f => bounds.contains([f.lat, f.lon])).length);
    }, 50);
  };
  const map = useMapEvents({
    moveend: () => {
      update(map);
      clearTimeout(bboxTimerRef.current);
      bboxTimerRef.current = setTimeout(() => {
        const b = map.getBounds();
        onBboxChange({ sw_lat: b.getSouthWest().lat.toFixed(2), ne_lat: b.getNorthEast().lat.toFixed(2), sw_lng: b.getSouthWest().lng.toFixed(2), ne_lng: b.getNorthEast().lng.toFixed(2) });
      }, 300);
    },
    zoomend: () => update(map),
  });
  useEffect(() => {
    update(map);
  }, [fires, showFires]); // eslint-disable-line
  return null;
}

// Spatial grid for O(1) fire hit detection - bucket fires by screen cell
function buildFireGrid(map, fires, cellSize = 20) {
  const grid = new Map();
  fires.forEach((fire, idx) => {
    const p = map.latLngToContainerPoint([fire.lat, fire.lon]);
    const key = `${Math.floor(p.x / cellSize)},${Math.floor(p.y / cellSize)}`;
    if (!grid.has(key)) grid.set(key, []);
    grid.get(key).push({ idx, fire, p });
  });
  return grid;
}

// Fire hit detection using spatial grid - O(1) bucket lookup instead of O(n) loop
function findFireAtPoint(map, fires, point, maxRadius = 8, gridRef) {
  if (!fires || fires.length === 0) return null;

  // Build grid if not provided (cached between calls)
  const cellSize = 20;
  const key = `${Math.floor(point.x / cellSize)},${Math.floor(point.y / cellSize)}`;

  // Check current cell + 8 neighbors
  const candidates = [];
  for (let dx = -1; dx <= 1; dx++) {
    for (let dy = -1; dy <= 1; dy++) {
      const neighborKey = `${Math.floor(point.x / cellSize) + dx},${Math.floor(point.y / cellSize) + dy}`;
      if (gridRef.current.has(neighborKey)) {
        candidates.push(...gridRef.current.get(neighborKey));
      }
    }
  }

  for (const { idx, fire, p } of candidates) {
    const dist = Math.hypot(point.x - p.x, point.y - p.y);
    const radius = fire.confidence === 'nominal' || fire.confidence === 'h' ? 5
               : fire.confidence === 'high' ? 4 : 3;
    if (dist <= Math.max(radius, maxRadius)) {
      return idx;
    }
  }
  return null;
}

// Throttled fire hit detection for pointer events with spatial grid caching
function FireEventsHandler({ fires, fireAlertMap, alertRows, onFireOver, onFireClick, onFireHoverEnd }) {
  const rafRef = useRef(null);
  const lastIdxRef = useRef(null);
  const gridRef = useRef(new Map());
  const prevFiresRef = useRef(null);
  const isZoomingRef = useRef(false);

  const map = useMapEvents({
    zoomstart: () => { isZoomingRef.current = true; },
    zoomend: () => {
      isZoomingRef.current = false;
      // Rebuild grid after zoom (screen positions changed)
      if (fires && fires.length > 0) {
        gridRef.current = buildFireGrid(map, fires);
        prevFiresRef.current = fires;
      }
    },
    moveend: () => {
      // Rebuild grid when map moves (fires screen positions changed)
      if (fires && fires.length > 0) {
        gridRef.current = buildFireGrid(map, fires);
        prevFiresRef.current = fires;
      }
    },
    mousemove: (e) => {
      if (isZoomingRef.current) return; // skip hover during zoom animation
      if (!fires || fires.length === 0) return;
      // Rebuild grid if fires array changed
      if (prevFiresRef.current !== fires) {
        gridRef.current = buildFireGrid(map, fires);
        prevFiresRef.current = fires;
      }
      if (rafRef.current) return; // throttle: skip if already scheduled
      rafRef.current = requestAnimationFrame(() => {
        rafRef.current = null;
        const rawIdx = findFireAtPoint(map, fires, e.containerPoint, 8, gridRef);
        // Only hover fires with associated alert — protect from non-alert point glitches
        const idx = (rawIdx !== null && fireAlertMap.get(rawIdx) != null) ? rawIdx : null;
        if (idx !== lastIdxRef.current) {
          lastIdxRef.current = idx;
          if (idx !== null) {
            const fireAlertId = fireAlertMap.get(idx);
            onFireOver(fireAlertId, idx);
          } else {
            onFireHoverEnd();
          }
        }
      });
    },
    click: (e) => {
      if (isZoomingRef.current) return;
      if (!fires || fires.length === 0) return;
      const idx = findFireAtPoint(map, fires, e.containerPoint, 8, gridRef);
      // Only click fires with associated alert
      if (idx !== null && fireAlertMap.get(idx) != null) {
        const fireAlertId = fireAlertMap.get(idx);
        onFireClick(fireAlertId, idx, e);
      }
    },
  });

  // Build grid on mount/fires change
  useEffect(() => {
    if (fires && fires.length > 0) {
      gridRef.current = buildFireGrid(map, fires);
      prevFiresRef.current = fires;
    }
  }, [fires, map]);

  // Cancel pending RAF on unmount
  useEffect(() => {
    return () => { if (rafRef.current) cancelAnimationFrame(rafRef.current); };
  }, []);

  return null;
}

// FirePopupContent - single shared popup content (not thousands)
function FirePopupContent({ fire, fireAlert, t }) {
  const landTag = fireAlert && (() => {
    if (fireAlert.type === 'indigenous_land')   return { cls: 'indigenous',   label: `Terra Indígena: ${fireAlert.meta}` };
    if (fireAlert.type === 'conservation_unit') return { cls: 'conservation', label: `UC: ${fireAlert.meta}` };
    if (fireAlert.type === 'night_fire')        return { cls: 'night-fire',   label: 'Foco Noturno' };
    if (fireAlert.type === 'prodes')            return { cls: 'prodes',       label: `PRODES: ${fireAlert.meta}` };
    return null;
  })();
  return (
    <>
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
    </>
  );
}

// FireMarker - no Popup child (heavy!). Popup shown via single shared component.
const FireMarker = React.memo(function FireMarker({ fire, idx, s, highlighted }) {
  return (
    <React.Fragment key={`f-${idx}`}>
      <CircleMarker
        center={[fire.lat, fire.lon]}
        pathOptions={s}
        radius={s.radius}
      />
      {highlighted && (
        <CircleMarker
          center={[fire.lat, fire.lon]}
          pathOptions={{ color: '#fff', fillColor: s.fillColor, fillOpacity: 1, radius: s.radius + 3, weight: 2 }}
          interactive={false}
        />
      )}
    </React.Fragment>
  );
});

// MapController handles pan-to-alert and smooth wheel zoom
function MapController({ activeAlert }) {
  const map = useMapEvents({});

  useEffect(() => {
    // Enable SmoothWheelZoom if available (Google Maps-style smooth zoom)
    if (L && L.SmoothWheelZoom) {
      map.options.scrollWheelZoom = 'center';
      map.addHandler('smoothWheelZoom', L.SmoothWheelZoom);
    }
  }, []); // eslint-disable-line

  useEffect(() => {
    if (activeAlert?.center) {
      // setView instead of flyTo: pans directly without zoom-out-zoom-in animation
      map.setView(activeAlert.center, Math.max(map.getZoom(), 8), {
        animate: true,
        duration: 1.0,
      });
    }
  }, [activeAlert?.id]); // eslint-disable-line

  return null;
}

function FireHoverLock({ fires, hoveredFireIdx, lockedFireIdx, onHoverEnd, onClearLock }) {
  const rafRef = useRef(null);
  const map = useMapEvents({
    mousemove: (e) => {
      if (lockedFireIdx != null) return;
      if (hoveredFireIdx == null) return;
      if (rafRef.current) return;
      rafRef.current = requestAnimationFrame(() => {
        rafRef.current = null;
        const fire = fires?.[hoveredFireIdx];
        if (!fire) {
          onHoverEnd();
          return;
        }
        const cursor = map.latLngToContainerPoint(e.latlng);
        const firePoint = map.latLngToContainerPoint([fire.lat, fire.lon]);
        const baseRadius = fireStyle(fire.confidence).radius;
        if (cursor.distanceTo(firePoint) > Math.max(baseRadius + 6, 10)) {
          onHoverEnd();
        }
      });
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
  const entries = Object.entries(asObject(raw)).filter(([, d]) => Array.isArray(d?.rings));
  return {
    type: 'FeatureCollection',
    features: entries.map(([name, d]) => ({
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

const BiomePanel = React.memo(function BiomePanel() {
  const { t } = useI18n();
  const [biomes, setBiomes] = useState([]);

  useEffect(() => {
    fetch('/api/biomes')
      .then(r => r.json())
      .then(d => {
        setBiomes(asArray(d.biomes));
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

const INDIGENOUS_STYLE = { color: '#f59e0b', fillColor: '#f59e0b', fillOpacity: 0.12, weight: 1.5, opacity: 0.6 };
const CONSERVATION_STYLE = { color: '#4ade80', fillColor: '#4ade80', fillOpacity: 0.1, weight: 1.5, opacity: 0.55 };

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

const MapaCard = React.memo(function MapaCard({ fires, showDeforest, showFires, setShowDeforest, setShowFires, showIndigenous, setShowIndigenous, showConservation, setShowConservation, indigenousGeo, conservationGeo, t, alerts, activeAlertId, flyToAlertId, hoveredFireIdx, lockedFireIdx, onFireOver, onFireHoverEnd, onFireClick, onClearFireLock, onAlertEnter, onAlertLeave, onBboxChange }) {
  const [satellite, setSatellite] = useState(true);
  const alertRows = asArray(alerts);
  const fireRows = asArray(fires);

  const fireAlertMap = useMemo(() => {
    const m = new Map();
    if (alertRows.length && fireRows.length) {
      fireRows.forEach((fire, idx) => { m.set(idx, alertForFire(fire, alertRows)); });
    }
    return m;
  }, [fireRows, alertRows]);

  // Alert lookup for O(1) access instead of O(n) find in render loop
  const alertByIdMap = useMemo(() => {
    const m = new Map();
    alertRows.forEach(a => m.set(a.id, a));
    return m;
  }, [alertRows]);

  const activeAlert = useMemo(() => alertByIdMap.get(activeAlertId) || null, [alertByIdMap, activeAlertId]);
  // flyToAlert only tracks explicit panel hover — not fire dot hover — to avoid unwanted map pans
  const flyToAlert = useMemo(() => alertByIdMap.get(flyToAlertId) || null, [alertByIdMap, flyToAlertId]);

  const highlightedFires = useMemo(() => {
    if (!activeAlert?.center || fireRows.length === 0) return null;
    const [alat, alon] = activeAlert.center;
    const rkm = (activeAlert.radius_km || 15) * 1.25;
    const s = new Set();
    fireRows.forEach((f, i) => { if (haversineKm(f.lat, f.lon, alat, alon) <= rkm) s.add(i); });
    return s;
  }, [activeAlert, fireRows]);

  const ringColor = activeAlert
    ? (activeAlert.tick === 'crit' ? '#ef4444' : activeAlert.tick === 'warn' ? '#f97316' : '#2dd4ff')
    : '#2dd4ff';

  const tileUrl = satellite
    ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
    : 'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png';
  const tileAttr = satellite
    ? '&copy; Esri, Earthstar Geographics'
    : '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>';

  return (
    <div className="map-stage">
      {/* Header overlay */}
      <div className="map-overlay-top">
        <div className="layer-toggles">
          <button
            className={`layer-toggle${showDeforest ? ' on-cyan' : ''}`}
            onClick={() => setShowDeforest(!showDeforest)}
          >
            <span className="lt-dot" /> {t('home.layerDeforestation')}<span className="lt-sub">PRODES</span>
          </button>
          <button
            className={`layer-toggle${showFires ? ' on-red' : ''}`}
            onClick={() => setShowFires(!showFires)}
          >
            <Flame size={10} /> {t('home.layerFires')}<span className="lt-sub">FIRMS</span>
          </button>
          <button
            className={`layer-toggle${satellite ? ' on-violet' : ''}`}
            onClick={() => setSatellite(!satellite)}
          >
            <span className="lt-dot" /> {t('home.layerSatellite')}
          </button>
          <button
            className={`layer-toggle${showIndigenous ? ' on-amber' : ''}`}
            onClick={() => setShowIndigenous(!showIndigenous)}
          >
            <span className="lt-dot" /> {t('home.layerIndigenous')}
          </button>
          <button
            className={`layer-toggle${showConservation ? ' on-green' : ''}`}
            onClick={() => setShowConservation(!showConservation)}
          >
            <span className="lt-dot" /> {t('home.layerConservation')}
          </button>
        </div>
      </div>

      {/* Map */}
      <MapContainer
          center={[-14.235, -51.925]}
          zoom={4}
          zoomSnap={0.5}
          zoomDelta={0.5}
          scrollWheelZoom
          style={{ position: 'absolute', inset: 0, width: '100%', height: '100%' }}
        >
          <TileLayer key={satellite ? 'sat' : 'osm'} attribution={tileAttr} url={tileUrl} />
          <MapController activeAlert={flyToAlert} />
          <VisibleFiresCounter fires={fireRows} showFires={showFires} onVisibleCountChange={() => {}} onBboxChange={onBboxChange} />
          <FireHoverLock
            fires={fireRows}
            hoveredFireIdx={hoveredFireIdx}
            lockedFireIdx={lockedFireIdx}
            onHoverEnd={onFireHoverEnd}
            onClearLock={onClearFireLock}
          />
          {showDeforest && (
            <TileLayer
              url="/api/tiles/prodes?z={z}&x={x}&y={y}"
              opacity={0.33}
              tileSize={256}
              maxNativeZoom={12}
              attribution="&copy; INPE/TerraBrasilis PRODES"
            />
          )}
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
              style={INDIGENOUS_STYLE}
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
              style={CONSERVATION_STYLE}
              onEachFeature={(feature, layer) => {
                const p = feature.properties;
                layer.bindPopup(`<strong>🌿 ${p.name}</strong><br/>${p.category || 'UC'} · ${p.state_abbr || ''}`);
              }}
            />
          )}
          {showFires && (
            <>
              <FireEventsHandler
                fires={fireRows}
                fireAlertMap={fireAlertMap}
                alertRows={alertRows}
                onFireOver={onFireOver}
                onFireClick={onFireClick}
                onFireHoverEnd={onFireHoverEnd}
              />
              {fireRows.map((fire, idx) => (
                <FireMarker
                  key={`f-${idx}`}
                  fire={fire}
                  idx={idx}
                  s={fireStyle(fire.confidence)}
                  highlighted={highlightedFires?.has(idx)}
                />
              ))}
              {/* Single shared Popup for hovered/locked fire - avoids thousands of Popup components */}
              {(hoveredFireIdx != null || lockedFireIdx != null) && fireRows[hoveredFireIdx ?? lockedFireIdx] && (
                <Popup
                  position={[fireRows[hoveredFireIdx ?? lockedFireIdx].lat, fireRows[hoveredFireIdx ?? lockedFireIdx].lon]}
                  autoClose={!lockedFireIdx}
                  closeOnClick={false}
                >
                  <FirePopupContent
                    fire={fireRows[hoveredFireIdx ?? lockedFireIdx]}
                    fireAlert={alertByIdMap.get(fireAlertMap.get(hoveredFireIdx ?? lockedFireIdx))}
                    t={t}
                  />
                </Popup>
              )}
            </>
          )}
        </MapContainer>

      {/* Floating: alerts panel — bottom right */}
      <DraggableCard className="fl-panel-alerts" title={t('home.liveAlerts')}>
        <AlertsPanel
          alerts={alertRows}
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
  const [fires,          setFires]          = useState(null);
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
  const alertFlyToTimerRef  = useRef(null);
  const indiFetchedRef      = useRef(false);
  const consFetchedRef      = useRef(false);

  const activeAlertId = lockedFireAlertId || alertHoverId || fireAlertId;

  const handleFireOver = useCallback((id, idx) => {
    if (lockedFireIdx != null && lockedFireIdx !== idx) return;
    if (fireHoverOutTimeoutRef.current) {
      clearTimeout(fireHoverOutTimeoutRef.current);
      fireHoverOutTimeoutRef.current = null;
    }
    setHoveredFireIdx(idx);
    setFireAlertId(id);
  }, [lockedFireIdx]);

  const clearFireHover = useCallback(() => {
    if (lockedFireIdx != null) return;
    if (fireHoverOutTimeoutRef.current) {
      clearTimeout(fireHoverOutTimeoutRef.current);
    }
    fireHoverOutTimeoutRef.current = setTimeout(() => {
      setHoveredFireIdx(null);
      setFireAlertId(null);
      fireHoverOutTimeoutRef.current = null;
    }, 80);
  }, [lockedFireIdx]);

  const handleFireClick = useCallback((id, idx, e) => {
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
  }, [lockedFireIdx]);

  const clearFireLock = useCallback(() => {
    setLockedFireIdx(null);
    setLockedFireAlertId(null);
    setHoveredFireIdx(null);
    setFireAlertId(null);
  }, []);

  const [flyToAlertId, setFlyToAlertId] = useState(null);

  const handleAlertEnter = useCallback(id => {
    setAlertHoverId(id);
    // Debounce flyTo 400ms: prevents accidental pan when mouse briefly crosses panel while panning
    clearTimeout(alertFlyToTimerRef.current);
    alertFlyToTimerRef.current = setTimeout(() => setFlyToAlertId(id), 400);
  }, []);
  const handleAlertLeave = useCallback(() => {
    setAlertHoverId(null);
    clearTimeout(alertFlyToTimerRef.current);
  }, []);

  useEffect(() => () => {
    if (fireHoverOutTimeoutRef.current) clearTimeout(fireHoverOutTimeoutRef.current);
    if (alertFlyToTimerRef.current) clearTimeout(alertFlyToTimerRef.current);
  }, []);

  useEffect(() => {
    const fetchAlerts = () => {
      fetch('/api/alerts')
        .then(r => r.json())
        .then(d => setAlerts(asArray(d.alerts)))
        .catch(() => {});
    };
    fetchAlerts();
    const id = setInterval(fetchAlerts, 60000);
    return () => clearInterval(id);
  }, []);

  // Fire data — fetch viewport bbox for smaller payloads, fallback to global
  const [fireBbox, setFireBbox] = useState(null);

  useEffect(() => {
    const validFire = f => f.lat != null && f.lon != null;
    const cached = getCache('fires', 240);
    if (cached) setFires(asArray(cached.fires).filter(validFire));
    const params = fireBbox
      ? `/api/fires?sw_lat=${fireBbox.sw_lat}&ne_lat=${fireBbox.ne_lat}&sw_lng=${fireBbox.sw_lng}&ne_lng=${fireBbox.ne_lng}`
      : '/api/fires';
    fetch(params)
      .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
      .then(d => {
        const f = asArray(d.fires).filter(validFire);
        setFires(f);
        if (!fireBbox) setCache('fires', { fires: f, last_sync: d.last_sync });
      })
      .catch(() => { if (!cached) setFires([]); });
  }, [fireBbox]);

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

  const aqiVal   = airQuality ? airQuality.aqi : 0;
  const aqiColor = aqiVal <= 50 ? '#4ade80' : aqiVal <= 100 ? '#fbbf24' : '#ef4444';

  return (
    <div className="home-main">
      <MapaCard
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
        t={t}
        alerts={alerts}
        activeAlertId={activeAlertId}
        flyToAlertId={flyToAlertId}
        hoveredFireIdx={hoveredFireIdx}
        lockedFireIdx={lockedFireIdx}
        onFireOver={handleFireOver}
        onFireHoverEnd={clearFireHover}
        onFireClick={handleFireClick}
        onClearFireLock={clearFireLock}
        onAlertEnter={handleAlertEnter}
        onAlertLeave={handleAlertLeave}
        onBboxChange={setFireBbox}
      />
      <div className="dashboard">
        <div className="dash-card dash-weather">
          <div className="dash-card-title">CLIMA{temperature?.city ? ` · ${temperature.city}` : ''}</div>
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
                <GaugeRing value={temperature ? temperature.humidity : 0} max={100} color="#3b82f6" size={56} />
                <div className="fl-weather__gauge-num">{temperature ? temperature.humidity : '—'}</div>
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
        </div>
        <div className="dash-card dash-biome">
          <BiomePanel />
        </div>
      </div>
    </div>
  );
}

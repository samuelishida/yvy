import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { MapContainer, TileLayer, CircleMarker, Circle, Popup, GeoJSON, useMapEvents, useMap } from 'react-leaflet';
import { TreePine, Flame, ChevronDown } from 'lucide-react';
import { useI18n } from '../i18n';
import { getCache, setCache } from '../utils/cache';
import { cachedFetch, invalidateApiCache } from '../utils/apiCache';
import { parseFocus, UF_CENTROIDS } from '../utils/mapLinks';
import 'leaflet/dist/leaflet.css';
import '../Home.css';
import L from 'leaflet';
// Vendored smooth wheel zoom (dead CDN replaced — see vendor file header).
import '../vendor/Leaflet.SmoothWheelZoom';

// Each MapContainer mount gets a unique key so React creates a fresh DOM node
// and Leaflet never sees a container with a stale _leaflet_id.
let _mapMountCounter = 0;

const BRAZIL_BIOMES = new Set(['Amazônia', 'Cerrado', 'Mata Atlântica', 'Caatinga', 'Pantanal', 'Pampa']);
const BRAZIL_BIOMES_ARR = Array.from(BRAZIL_BIOMES);
const isOutOfBrazil = (a) => a.out_of_brazil === true ||
  (!BRAZIL_BIOMES.has(a.meta) && !BRAZIL_BIOMES_ARR.some(b => a.meta?.startsWith(b)));

const BIOME_HIGHLIGHT_COLORS = {
  'Amazônia':       '#ef4444',
  'Cerrado':        '#fb923c',
  'Caatinga':       '#fbbf24',
  'Mata Atlântica': '#a78bfa',
  'Pantanal':       '#2dd4ff',
  'Pampa':          '#4ade80',
};

const FIRE_STYLES = {
  nominal: { color: '#EF5350', fillColor: '#EF5350', fillOpacity: 0.4,  radius: 2.5, weight: 0 },
  high:    { color: '#f97316', fillColor: '#f97316', fillOpacity: 0.32, radius: 2,   weight: 0 },
  low:     { color: '#fbbf24', fillColor: '#fbbf24', fillOpacity: 0.2,  radius: 1.5, weight: 0 },
};

// Nature classes (Inc 7): crime = vermelho, suspeito = laranja, permitido =
// verde, natural = azul. Aplicado quando fire.nature vem preenchido (Inc 5);
// sem nature cai no fallback por confidence (FIRE_STYLES).
const FIRE_NATURE_COLORS = {
  crime:     { color: '#ef4444', fillColor: '#ef4444', fillOpacity: 0.42, radius: 3,   weight: 0 },
  suspeito:  { color: '#f97316', fillColor: '#f97316', fillOpacity: 0.38, radius: 2.5, weight: 0 },
  permitido: { color: '#22c55e', fillColor: '#22c55e', fillOpacity: 0.25, radius: 2.5, weight: 0 },
  natural:   { color: '#38bdf8', fillColor: '#38bdf8', fillOpacity: 0.35, radius: 2.5, weight: 0 },
};

const asArray = value => Array.isArray(value) ? value : [];

// Escapes HTML metacharacters before interpolating feature properties into
// Leaflet popup HTML (bindPopup builds HTML strings from source/user data —
// TI names, municipios, risk levels — which must not break out of the markup).
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => (
  { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
));

const DEFAULT_BIOMES = [
  { name: 'Cerrado' },
  { name: 'Mata Atlântica' },
  { name: 'Amazônia' },
  { name: 'Caatinga' },
  { name: 'Pantanal' },
  { name: 'Pampa' },
];
// Accept either the legacy raw bounds map ({ name: {rings, ...} }) or a
// pre-built GeoJSON FeatureCollection. Returns a FeatureCollection or null.
function toFeatureCollection(raw) {
  if (!raw || typeof raw !== 'object') return null;
  if (raw.type === 'FeatureCollection' && Array.isArray(raw.features)) return raw;
  const entries = Object.entries(raw).filter(([, d]) => Array.isArray(d?.rings));
  if (!entries.length) return null;
  return {
    type: 'FeatureCollection',
    features: entries.map(([name, d]) => ({
      type: 'Feature',
      properties: { name, state_abbr: d.state_abbr, municipality: d.municipality, category: d.category, full_name: d.full_name },
      geometry: { type: 'MultiPolygon', coordinates: d.rings.map(r => [r]) },
    })),
  };
}

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

const MOBILE_BREAKPOINT = 720;

function useWindowSize() {
  const [size, setSize] = useState({ width: window.innerWidth, height: window.innerHeight });
  useEffect(() => {
    const onResize = () => setSize({ width: window.innerWidth, height: window.innerHeight });
    window.addEventListener('resize', onResize);
    return () => window.removeEventListener('resize', onResize);
  }, []);
  return size;
}

function fireStyle(fire) {
  const nature = fire?.nature;
  if (nature && FIRE_NATURE_COLORS[nature]) return FIRE_NATURE_COLORS[nature];
  const confidence = (fire?.confidence || 'low').toLowerCase();
  if (confidence === 'nominal' || confidence === 'h') return FIRE_STYLES.nominal;
  if (confidence === 'high') return FIRE_STYLES.high;
  return FIRE_STYLES.low;
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

  const cellSize = 20;

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
function FireEventsHandler({ fires, fireAlertMap, visibleToFullIdxMap, onFireOver, onFireClick, onFireHoverEnd, showCar, onCarInspect }) {
  const rafRef = useRef(null);
  const lastIdxRef = useRef(null);
  const gridRef = useRef(new Map());
  const prevFiresRef = useRef(null);
  const isZoomingRef = useRef(false);

  const map = useMapEvents({
    zoomstart: () => { isZoomingRef.current = true; },
    zoomend: () => {
      isZoomingRef.current = false;
      if (fires && fires.length > 0) {
        gridRef.current = buildFireGrid(map, fires);
        prevFiresRef.current = fires;
      }
    },
    moveend: () => {
      if (fires && fires.length > 0) {
        gridRef.current = buildFireGrid(map, fires);
        prevFiresRef.current = fires;
      }
    },
    mousemove: (e) => {
      if (isZoomingRef.current) return;
      if (!fires || fires.length === 0) return;
      if (prevFiresRef.current !== fires) {
        gridRef.current = buildFireGrid(map, fires);
        prevFiresRef.current = fires;
      }
      if (rafRef.current) return;
      rafRef.current = requestAnimationFrame(() => {
        rafRef.current = null;
        const visIdx = findFireAtPoint(map, fires, e.containerPoint, 8, gridRef);
        const fullIdx = visIdx != null ? visibleToFullIdxMap.get(visIdx) : null;
        const alertId = fullIdx != null ? fireAlertMap.get(fullIdx) : null;
        const idx = alertId != null ? fullIdx : null;
        if (idx !== lastIdxRef.current) {
          lastIdxRef.current = idx;
          if (idx !== null) {
            onFireOver(alertId, idx);
          } else {
            onFireHoverEnd();
          }
        }
      });
    },
    click: (e) => {
      if (isZoomingRef.current) return;
      // 1. Fire hit-test first — o popup de fogo vence quando clica num foco.
      if (fires && fires.length > 0) {
        const visIdx = findFireAtPoint(map, fires, e.containerPoint, 8, gridRef);
        const fullIdx = visIdx != null ? visibleToFullIdxMap.get(visIdx) : null;
        const alertId = fullIdx != null ? fireAlertMap.get(fullIdx) : null;
        if (alertId != null) {
          onFireClick(alertId, fullIdx, e);
          return;
        }
      }
      // 2. Click em espaço vazio do mapa + overlay CAR ativo → inspeciona imóvel.
      if (showCar) {
        onCarInspect(e.latlng);
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
// Os dados pesados de nature_evidence são buscados sob demanda via
// /api/fire-detail, reduzindo o payload da listagem de focos.
function FirePopupContent({ fire, fireAlert, t }) {
  const [detail, setDetail] = useState(null);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (!fire?.id) return;
    // Não precisa refazer se o popup já tem evidence no fire (fallback).
    if (fire.nature_evidence) {
      setDetail(fire);
      return;
    }
    setLoading(true);
    let aborted = false;
    fetch(`/api/fire-detail?id=${encodeURIComponent(fire.id)}`)
      .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
      .then(d => { if (!aborted) setDetail(d.fire || fire); })
      .catch(() => { if (!aborted) setDetail(fire); })
      .finally(() => { if (!aborted) setLoading(false); });
    return () => { aborted = true; };
  }, [fire]);

  const d = detail || fire;
  const landTag = fireAlert && (() => {
    if (fireAlert.type === 'indigenous_land')   return { cls: 'indigenous',   label: `${t('home.tagIndigenous')}: ${fireAlert.meta}` };
    if (fireAlert.type === 'conservation_unit') return { cls: 'conservation', label: `${t('home.tagConservation')}: ${fireAlert.meta}` };
    if (fireAlert.type === 'night_fire')        return { cls: 'night-fire',   label: t('home.tagNightFire') };
    if (fireAlert.type === 'prodes')            return { cls: 'prodes',       label: `${t('home.tagProdes')}: ${fireAlert.meta}` };
    return null;
  })();
  return (
    <>
      <strong>{t('home.heatFocus')}</strong><br />
      {t('home.confidence')}: {d.confidence}<br />
      {d.nature && (
        <>
          {t('home.nature')}:{' '}
          <span style={{ color: FIRE_NATURE_COLORS[d.nature]?.color || '#E8F0EC', fontWeight: 600 }}>
            {t(`home.nature_${d.nature}`)}
          </span>
          <br />
        </>
      )}
      {loading && <span style={{ color: '#888', fontSize: 11 }}>{t('home.loading')}…</span>}
      {d.nature_evidence?.authorization && (
        <>
          {t('home.authorization')}:{' '}
          <span style={{ color: FIRE_NATURE_COLORS.permitido.color, fontWeight: 600 }}>
            {d.nature_evidence.authorization.nro} ({d.nature_evidence.authorization.modo})
          </span>
          <br />
        </>
      )}
      {t('home.date')}: {d.acq_date} {d.acq_time}<br />
      {t('home.satellite')}: {d.satellite}<br />
      {t('home.brightnessTemp')}: {d.bright_ti4}K
      {d.vegetation && (
        <>
          <br />
          <span style={{ color: '#2dd4ff' }}>
            {d.vegetation.status === 'deforested' || (d.vegetation.status || '').startsWith('deforested')
              ? `${t('home.fireInDeforested')} (${d.vegetation.class_name || d.vegetation.year || ''})`
              : (d.vegetation.status || '').startsWith('regrowth')
                ? t('home.fireInRegrowth')
                : t('home.fireInNativeVeg')}
          </span>
        </>
      )}
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
// Aumenta o raio no zoom out para que os pontos amostrados não fiquem invisíveis.
const FireMarker = React.memo(function FireMarker({ fire, idx, s, highlighted }) {
  const map = useMap();
  const zoom = map ? map.getZoom() : 5;
  const scale = zoom < 4 ? 1 + (4 - zoom) * 0.35 : 1;
  const radius = Math.max(2.5, Math.min(7, s.radius * scale));
  const pathOptions = {
    ...s,
    radius,
    fillOpacity: Math.min(0.6, s.fillOpacity * (zoom < 4 ? 1.25 : 1)),
  };
  return (
    <React.Fragment key={`f-${idx}`}>
      <CircleMarker
        center={[fire.lat, fire.lon]}
        pathOptions={pathOptions}
        radius={radius}
      />
      {highlighted && (
        <CircleMarker
          center={[fire.lat, fire.lon]}
          pathOptions={{ color: '#fff', fillColor: s.fillColor, fillOpacity: 1, radius: radius + 3, weight: 2 }}
          interactive={false}
        />
      )}
    </React.Fragment>
  );
});

// ViewportFireFilter - clips fires to visible bounds + 15% margin
function ViewportFireFilter({ fires, generation, onVisibleFiresChange }) {
  const rafRef = useRef(null);
  // Guarda a última geração processada; se mudou, descarta resultados
  // baseados em arrays do período anterior.
  const lastGenerationRef = useRef(generation);
  const updateVisibleFires = useCallback((map) => {
    if (rafRef.current) cancelAnimationFrame(rafRef.current);
    rafRef.current = requestAnimationFrame(() => {
      rafRef.current = null;
      if (!fires || fires.length === 0) {
        onVisibleFiresChange([]);
        lastGenerationRef.current = generation;
        return;
      }
      const zoom = map.getZoom();
      const b = map.getBounds();
      const latSpan = b.getNorth() - b.getSouth();
      const lonSpan = b.getEast() - b.getWest();
      const padLat = latSpan * 0.15;
      const padLon = lonSpan * 0.15;
      const north = Math.min(b.getNorth() + padLat, 85);
      const south = Math.max(b.getSouth() - padLat, -85);
      const east = Math.min(b.getEast() + padLon, 180);
      const west = Math.max(b.getWest() - padLon, -180);

      // Zoom-gate: abaixo de zoom 5 os pontos individuais viram sopa visual e
      // 15k CircleMarkers pesam o canvas. Em vez de sumir completamente,
      // amostramos um representante por célula da tela — mantém a visão geral
      // no zoom out sem travar o frontend.
      if (zoom < 5) {
        // Densidade variável: mantém pontos visíveis no zoom out sem renderizar
        // 15k CircleMarkers. Células menores no zoom 4 (quase visualização completa)
        // e maiores conforme afasta, mas nunca sumindo completamente.
        const cellSize = zoom >= 4.5 ? 14 : zoom >= 4 ? 18 : zoom >= 3.5 ? 24 : zoom >= 3 ? 32 : zoom >= 2.5 ? 42 : 56;
        const cells = new Map();
        for (const f of fires) {
          if (f.lat < south || f.lat > north || f.lon < west || f.lon > east) continue;
          const p = map.latLngToContainerPoint([f.lat, f.lon]);
          const key = `${Math.floor(p.x / cellSize)},${Math.floor(p.y / cellSize)}`;
          if (!cells.has(key)) cells.set(key, f);
        }
        onVisibleFiresChange(Array.from(cells.values()));
        lastGenerationRef.current = generation;
        return;
      }

      const visible = fires.filter(f =>
        f.lat >= south && f.lat <= north && f.lon >= west && f.lon <= east
      );
      lastGenerationRef.current = generation;
      onVisibleFiresChange(visible);
    });
  }, [fires, generation, onVisibleFiresChange]);

  const map = useMapEvents({
    moveend: () => updateVisibleFires(map),
    zoomend: () => updateVisibleFires(map),
  });

  useEffect(() => {
    // Mudou de período e ainda não processamos a nova geração: limpa
    // visibleFires para não exibir pontos do período anterior.
    if (generation !== lastGenerationRef.current) {
      onVisibleFiresChange([]);
    }
    updateVisibleFires(map);
    return () => { if (rafRef.current) cancelAnimationFrame(rafRef.current); };
  }, [updateVisibleFires, map, generation, onVisibleFiresChange]);

  return null;
}

// Reconciles the fire layer with the showFires toggle. Two known issues with
// react-leaflet + preferCanvas:
//   1. Unmounting many CircleMarkers does not always trigger a canvas redraw,
//      leaving ghost dots until the next pan/zoom.
//   2. Under React 18 strict-mode / concurrent renders, react-leaflet
//      occasionally drops the unmount path for a marker, leaving the Leaflet
//      layer attached even though the React component is gone.
//
// Strategy: defer one animation frame so React's commit finishes, then —
// when showFires is false — sweep every CircleMarker still on the map and
// detach it. Finally force every canvas renderer to clear+redraw.
function CanvasRedrawOnToggle({ flag }) {
  const map = useMap();
  useEffect(() => {
    if (!map) return;
    const id = requestAnimationFrame(() => {
      if (!flag) {
        const stragglers = [];
        map.eachLayer(layer => {
          if (layer instanceof L.CircleMarker) stragglers.push(layer);
        });
        stragglers.forEach(l => { try { map.removeLayer(l); } catch (_) {} });
      }
      const renderers = new Set();
      if (map._renderer) renderers.add(map._renderer);
      map.eachLayer(layer => {
        const r = layer._renderer || layer.options?.renderer;
        if (r) renderers.add(r);
      });
      renderers.forEach(r => {
        if (r._ctx && r._bounds) {
          const size = r._bounds.getSize();
          try { r._ctx.clearRect(0, 0, size.x, size.y); } catch (_) {}
        }
        if (typeof r._update === 'function') {
          try { r._update(); } catch (_) {}
        }
      });
    });
    return () => cancelAnimationFrame(id);
  }, [flag, map]);
  return null;
}

// MapController handles pan-to-alert and smooth wheel zoom

// Handles ?focus= from the dashboard drilldown (plan: dashboard-enhancement,
// Inc 9). state:UF centers on the UF centroid; biome is handled by
// BiomeHighlightLayer (it fits bounds once the boundaries load); land:* uses
// the existing lat/lng/zoom params in MapController.
function FocusController({ focus }) {
  const map = useMapEvents({});
  useEffect(() => {
    if (!focus || focus.kind !== 'state') return;
    const c = UF_CENTROIDS[focus.id];
    if (c) map.setView(c, 6, { animate: true, duration: 0.8 });
  }, [focus?.kind, focus?.id, map]);
  return null;
}

function MapController({ activeAlert }) {
  const map = useMapEvents({});

  useEffect(() => {
    // Enable SmoothWheelZoom if available (Google Maps-style smooth zoom)
    if (L && L.SmoothWheelZoom) {
      map.options.scrollWheelZoom = 'center';
      map.addHandler('smoothWheelZoom', L.SmoothWheelZoom);
    }

    // Focus from URL params: /?lat=...&lng=...&zoom=...
    try {
      const params = new URLSearchParams(window.location.search);
      const lat = parseFloat(params.get('lat'));
      const lng = parseFloat(params.get('lng'));
      const zoom = parseInt(params.get('zoom'), 10);
      if (Number.isFinite(lat) && Number.isFinite(lng)) {
        map.setView([lat, lng], Number.isFinite(zoom) ? zoom : 8, { animate: true, duration: 0.8 });
      }
    } catch (_) {}
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
        const baseRadius = fireStyle(fire).radius;
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

// react-leaflet v4 NÃO converte props on* em handlers (onClose era no-op) e o
// Popup do Leaflet não dispara evento 'close' próprio — só o MAPA dispara
// 'popupclose' com {popup}. Sem sincronização, fechar via × deixava o estado
// (carInspect / lock de fogo) intacto e o <Popup> continuava montado, reabrindo
// no próximo re-render (ex: após zoom out). Este componente casa o popupclose
// do mapa com a instância do popup (via ref) e limpa o estado correspondente.
function PopupCloseSync({ carPopupRef, firePopupRef, onCarClose, onFireClose }) {
  const map = useMap();
  useEffect(() => {
    const handler = (e) => {
      if (carPopupRef.current && e.popup === carPopupRef.current) onCarClose();
      if (firePopupRef.current && e.popup === firePopupRef.current) onFireClose();
    };
    map.on('popupclose', handler);
    return () => { map.off('popupclose', handler); };
  }, [map, carPopupRef, firePopupRef, onCarClose, onFireClose]);
  return null;
}

function windDir(deg) {
  if (deg == null) return '—';
  const dirs = ['N','NE','L','SE','S','SO','O','NO'];
  return dirs[Math.round(deg / 45) % 8];
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

const FloatPanel = React.memo(function FloatPanel({ alerts, activeAlertId, activeBiome, onAlertEnter, onAlertLeave, airQuality, temperature, onBiomeHover, loaded, isMobile }) {
  // Always collapsed on mount — the summary line already shows the live count
  // (crit/warn badges + total); the user expands on demand. Auto-opening would
  // defeat the collapse-by-default declutter.
  const [open, setOpen] = useState(false);
  const [tab, setTab] = useState('biomes');
  const { t } = useI18n();
  const critCount = alerts.filter(a => a.tick === 'crit').length;
  const warnCount = alerts.filter(a => a.tick === 'warn').length;
  const aqiVal = airQuality ? airQuality.aqi : 0;
  const aqiColor = aqiVal <= 50 ? '#4ade80' : aqiVal <= 100 ? '#fbbf24' : '#ef4444';
  const activeAlertRowRef = useRef(null);

  const sortedAlerts = useMemo(() => {
    const typePriority = { indigenous_land: 0, conservation_unit: 1, deter_protected: 2, cluster: 3, night_fire: 4, prodes: 5, pm25: 6 };
    return alerts.filter(a => !isOutOfBrazil(a)).sort((a, b) => {
      const pa = typePriority[a.type] ?? 9;
      const pb = typePriority[b.type] ?? 9;
      if (pa !== pb) return pa - pb;
      const tier = { crit: 0, warn: 1, info: 2 };
      return (tier[a.tick] ?? 9) - (tier[b.tick] ?? 9);
    });
  }, [alerts]);

  // Ensure the active alert row stays visible when the alerts tab is open.
  useEffect(() => {
    if (!open || tab !== 'alerts') return;
    const node = activeAlertRowRef.current;
    if (node && typeof node.scrollIntoView === 'function') {
      node.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    }
  }, [activeAlertId, tab, open]);

  const toggleOpen = () => setOpen(o => !o);
  const handleTab = (t) => { setTab(t); if (t !== 'biomes') onBiomeHover?.(null); };

  return (
    <div className={`float-panel${open ? ' float-panel--open' : ''}${isMobile ? ' float-panel--mobile' : ''}`}>
      <button className="fp-summary" onClick={toggleOpen} aria-expanded={open}>
        <div className="fp-hero">
          <span className="fp-count">{loaded ? alerts.length.toLocaleString('pt-BR') : '—'}</span>
          <span className="fp-unit">{t('home.panelAlertsUnit')}</span>
        </div>
        <div className="fp-right">
          {critCount > 0 && <span className="fp-badge fp-badge--crit">{critCount}</span>}
          {warnCount > 0 && <span className="fp-badge fp-badge--warn">{warnCount}</span>}
          <ChevronDown size={14} className={`fp-chevron${open ? ' fp-chevron--open' : ''}`} />
        </div>
      </button>
      {open && (
        <div className="fp-body">
          <div className="fp-tabs">
            <button className={`fp-tab${tab === 'alerts' ? ' fp-tab--active' : ''}`} onClick={() => handleTab('alerts')}>
              {t('home.tabAlerts')} ({alerts.length})
            </button>
            <button className={`fp-tab${tab === 'biomes' ? ' fp-tab--active' : ''}`} onClick={() => { setTab('biomes'); onBiomeHover?.(null); }}>
              {t('home.tabBiomes')}
            </button>
            <button className={`fp-tab${tab === 'clima' ? ' fp-tab--active' : ''}`} onClick={() => handleTab('clima')}>
              {t('home.tabClima')}
            </button>
          </div>
          <div className="fp-content">
            {tab === 'alerts' && (
              <div className="fp-alerts">
                {sortedAlerts.length === 0 ? (
                  <div className="fp-empty">{t('home.emptyAlerts')}</div>
                ) : (
                  sortedAlerts.slice(0, Math.max(12, sortedAlerts.findIndex(a => a.id === activeAlertId) + 1)).map((a, i) => (
                    <div
                      key={a.id || i}
                      ref={activeAlertId === a.id ? activeAlertRowRef : null}
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
                        <div className="alert-meta">{a.meta} <span className="sep">/</span> {a.state}</div>
                      </div>
                    </div>
                  ))
                )}
              </div>
            )}
            {tab === 'biomes' && (
              <div className="fp-biomes">
                <BiomePanel onBiomeHover={onBiomeHover} activeBiome={activeBiome} open={open} tab={tab} />
              </div>
            )}
            {tab === 'clima' && (
              <div className="fp-clima">
                {temperature?.city && <div className="fp-clima-city">{temperature.city}</div>}
                <div className="fp-gauges">
                  <div className="fp-gauge">
                    <div className="fp-gauge-svg">
                      <GaugeRing value={aqiVal} max={300} color={aqiColor} size={52} />
                      <div className="fp-gauge-num" style={{ color: aqiColor }}>{airQuality ? aqiVal : '—'}</div>
                    </div>
                    <div className="fp-gauge-label">AQI</div>
                    {airQuality && <div className="fp-gauge-sub">PM2.5·{airQuality.pm25}</div>}
                  </div>
                  <div className="fp-gauge">
                    <div className="fp-gauge-svg">
                      <GaugeRing value={temperature ? temperature.humidity : 0} max={100} color="#3b82f6" size={52} />
                      <div className="fp-gauge-num">{temperature ? temperature.humidity : '—'}</div>
                    </div>
                    <div className="fp-gauge-label">{t('home.gaugeHumidity')}</div>
                    <div className="fp-gauge-sub">%</div>
                  </div>
                  <div className="fp-gauge">
                    <div className="fp-gauge-svg">
                      <GaugeRing value={temperature ? Math.max(temperature.temp, 0) : 0} max={45} color="#fb923c" size={52} />
                      <div className="fp-gauge-num">{temperature ? temperature.temp.toFixed(0) : '—'}</div>
                    </div>
                    <div className="fp-gauge-label">{t('home.gaugeTemp')}</div>
                    <div className="fp-gauge-sub">{temperature ? `SC ${temperature.feels_like.toFixed(0)}°` : '—'}</div>
                  </div>
                  <div className="fp-gauge">
                    <div className="fp-gauge-svg">
                      <GaugeRing value={temperature?.wind_speed ?? 0} max={80} color="#2dd4ff" size={52} />
                      <div className="fp-gauge-num">{temperature?.wind_speed != null ? Math.round(temperature.wind_speed) : '—'}</div>
                    </div>
                    <div className="fp-gauge-label">{t('home.gaugeWind')}</div>
                    <div className="fp-gauge-sub">{windDir(temperature?.wind_direction)}</div>
                  </div>
                </div>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
});

const BiomePanel = React.memo(function BiomePanel({ onBiomeHover, activeBiome, tab, open }) {
  const { t } = useI18n();
  const [biomes, setBiomes] = useState(null);
  const activeRowRef = useRef(null);

  useEffect(() => {
    const ac = new AbortController();
    cachedFetch('/api/biomes', { ttl: 60_000, signal: ac.signal })
      .then(d => { setBiomes(asArray(d.biomes)); })
      .catch(err => { if (err.name !== 'AbortError') console.error('Biomes fetch error:', err); });
    return () => ac.abort();
  }, []);

  // Keep the active biome row visible when the biomes tab is open.
  useEffect(() => {
    if (!open || tab !== 'biomes') return;
    const node = activeRowRef.current;
    if (node && typeof node.scrollIntoView === 'function') {
      node.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    }
  }, [activeBiome, tab, open]);

  const sortedBiomes = useMemo(
    () => biomes === null ? DEFAULT_BIOMES : [...biomes].sort((a, b) => b.count - a.count),
    [biomes]
  );

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
        {sortedBiomes.map((b, i) => (
          <div
            key={b.name}
            ref={activeBiome === b.name ? activeRowRef : null}
            className={`biome-row${activeBiome === b.name ? ' biome-row--active' : ''}`}
            onMouseEnter={() => onBiomeHover?.(b.name)}
            onMouseLeave={() => onBiomeHover?.(null)}
          >
            <div className="biome-name">{b.name}</div>
            <div className="biome-bar">
              <div className="biome-bar-fill" style={{ width: `${b.pct ?? 0}%`, background: b.color ?? 'var(--ink-2, rgba(255,255,255,0.3))' }} />
            </div>
            <div className="biome-val" style={{ color: b.color ?? 'var(--ink-2, rgba(255,255,255,0.65))' }}>
              {b.count != null ? b.count.toLocaleString('pt-BR') : '—'}
            </div>
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
  deter_protected: 'alertDeterProtected',
};

const INDIGENOUS_STYLE = { color: '#f59e0b', fillColor: '#f59e0b', fillOpacity: 0.08, weight: 1.25, opacity: 0.85, dashArray: '5 4' };
const CONSERVATION_STYLE = { color: '#4ade80', fillColor: '#4ade80', fillOpacity: 0.07, weight: 1.25, opacity: 0.85, dashArray: '5 4' };

// CAR overlay: tiles são PNGs opacos pré-renderizados em lime (#a3e635, ver
// scripts/data/render_car_tiles.py). O TileLayer .car-tiles aplica um filtro
// CSS hue-rotate(240deg) saturate(1.8) que recolore para magenta (#FF84FF) —
// contrasta com os tons quentes (PRODES/focos) quando tudo está ligado. O dot
// da layer bar (CAR_COLOR) espelha a cor renderizada. TileLayer opacity=0.5 é
// o único controle de transparência. CAR_TILES_VERSION é bumped ao regenerar os
// tiles (busta caches).
const CAR_COLOR = '#FF84FF';
// CAR tiles are served with Cache-Control: no-store (see tiles.lua
// serve_png_no_cache) so the browser always re-fetches from the backend — the
// rasterized pixel positions shift whenever car.db is re-imported, so a long
// immutable cache made browsers keep stale bbox tiles. The version param is
// kept only to force one fresh fetch for browsers that cached the old v=1
// tiles before no-store shipped; it is otherwise ignored by the backend.
const CAR_TILES_VERSION = '2';

// Bounds do Brasil para o popup "sem imóvel" (mesmo clamp do backend).
const BR_BOUNDS = { swLat: -34.0, neLat: 5.5, swLng: -74.0, neLng: -34.0 };
const isInBrazil = (lat, lng) =>
  lat >= BR_BOUNDS.swLat && lat <= BR_BOUNDS.neLat && lng >= BR_BOUNDS.swLng && lng <= BR_BOUNDS.neLng;


function BiomeHighlightLayer({ activeBiome, biomeGeoJSON }) {
  const map = useMap();
  const attachedRef = useRef(null);

  // Pre-build per-biome Leaflet layer + bounds once when geojson arrives.
  // Avoids re-parsing/re-vectorizing on every hover (the actual hover-lag source).
  const biomeCache = useMemo(() => {
    if (!biomeGeoJSON?.features) return null;
    const byName = new Map();
    for (const f of biomeGeoJSON.features) {
      const name = f.properties?.name;
      if (!name) continue;
      if (!byName.has(name)) byName.set(name, []);
      byName.get(name).push(f);
    }
    const result = {};
    for (const [name, features] of byName) {
      const color = BIOME_HIGHLIGHT_COLORS[name] || '#00C97A';
      const layer = L.geoJSON({ type: 'FeatureCollection', features }, {
        style: { color, fillColor: color, fillOpacity: 0.18, weight: 2.5, opacity: 0.9, dashArray: '5 4' },
        interactive: false,
      });
      let bounds = null;
      try {
        const b = layer.getBounds();
        if (b && b.isValid()) bounds = b;
      } catch (_) {}
      result[name] = { layer, bounds };
    }
    return result;
  }, [biomeGeoJSON]);

  useEffect(() => {
    if (attachedRef.current) {
      attachedRef.current.remove();
      attachedRef.current = null;
    }
    if (!activeBiome || !biomeCache) return;
    const entry = biomeCache[activeBiome];
    if (!entry) return;
    entry.layer.addTo(map);
    attachedRef.current = entry.layer;
    if (entry.bounds) {
      map.fitBounds(entry.bounds, { maxZoom: 7, padding: [30, 30], animate: true, duration: 0.6 });
    }
    return () => {
      if (attachedRef.current) {
        attachedRef.current.remove();
        attachedRef.current = null;
      }
    };
  }, [activeBiome, biomeCache, map]);

  return null;
}

// Voa até o bbox do imóvel quando o resultado da verificação PRODES chega
// (plan: terrabrasilis-integration, Inc 12). Filho do MapContainer (useMap).
const ProdesFlyTo = React.memo(function ProdesFlyTo({ bbox }) {
  const map = useMap();
  useEffect(() => {
    if (bbox) {
      map.flyToBounds(
        [[bbox.min_lat, bbox.min_lon], [bbox.max_lat, bbox.max_lon]],
        { padding: [48, 48], maxZoom: 14 }
      );
    }
  }, [map, bbox]);
  return null;
});

const MapaCard = React.memo(function MapaCard({ fires, showDeforest, showFires, setShowDeforest, setShowFires, showIndigenous, setShowIndigenous, showConservation, setShowConservation, indigenousGeo, conservationGeo, t, alerts, activeAlertId, flyToAlertId, hoveredFireIdx, lockedFireIdx, onFireOver, onFireHoverEnd, onFireClick, onClearFireLock, onAlertEnter, onAlertLeave, airQuality, temperature, activeBiome, biomeGeoJSON, onBiomeHover, focus, fireDays, setFireDays, fireDataGeneration }) {
  const { width: windowWidth } = useWindowSize();
  const isMobile = windowWidth <= MOBILE_BREAKPOINT;
  const [satellite, setSatellite] = useState(true);
  // Unique per-mount key prevents "Map container already initialized" on remount
  const [mapKey] = useState(() => ++_mapMountCounter);
  const [visibleFires, setVisibleFires] = useState([]);
  // CAR overlay (Inc 3): showCar toggle (padrão ON) + carInspect popup state (local ao card).
  const [showCar, setShowCar] = useState(true);
  const [carInspect, setCarInspect] = useState(null);
  // Verificação PRODES por recibo CAR (plan: terrabrasilis-integration, Inc 12).
  const [prodesInput, setProdesInput] = useState('');
  const [prodesResult, setProdesResult] = useState(null);
  const [prodesLoading, setProdesLoading] = useState(false);
  const [prodesError, setProdesError] = useState(null);
  // Sobreposição CAR × UC/TI (plan: protected-area-crossing, Inc 2) — badge de
  // grilagem. Busca separada do PRODES para uma falha não derrubar o resumo.
  const [protectedOverlap, setProtectedOverlap] = useState(null);
  // Fecha o card de verificação e devolve a interação do mapa (sem isso o card
  // ficava preso cobrindo o mapa até recarregar a página).
  const clearProdes = useCallback(() => {
    setProdesResult(null);
    setProdesError(null);
    setProtectedOverlap(null);
  }, []);
  const prodesQueryRef = useRef(null);
  const prodesQuery = async (e, forcedCod) => {
    if (e && e.preventDefault) e.preventDefault();
    const cod = (forcedCod || prodesInput).trim();
    if (!cod || prodesLoading) return;
    setProdesLoading(true);
    setProdesError(null);
    setProtectedOverlap(null);
    try {
      const d = await cachedFetch(`/api/car/prodes?cod_imovel=${encodeURIComponent(cod)}`, { ttl: 60_000 });
      setProdesResult(d);
    } catch (err) {
      // Sem texto cru de erro (ex. string de exceção do fetch/404 antigo) —
      // mensagem traduzida genérica; o caso "não encontrado" vem como 200 + reason.
      setProdesError(t('home.error'));
      setProdesResult(null);
    } finally {
      setProdesLoading(false);
    }
    // No mobile fecha o modal de input após a busca; o resultado aparece como
    // um card flutuante compacto, sem bloquear o mapa.
    if (isMobile) {
      setShowMobileProdes(false);
    }
    // Badge de grilagem: independente do PRODES — falha aqui não derruba o resumo.
    // Só aplica a resposta do recibo ATUAL — uma resposta atrasada de um recibo
    // anterior não pode vazar para o card novo.
    cachedFetch(`/api/car/protected-overlap?cod_imovel=${encodeURIComponent(cod)}`, { ttl: 3_600_000 })
      .then(ov => {
        if (ov && ov.data && ov.data.found && ov.data.cod_imovel === cod) {
          setProtectedOverlap(ov.data);
        } else {
          setProtectedOverlap(null);
        }
      })
      .catch(() => setProtectedOverlap(null));
  };
  prodesQueryRef.current = prodesQuery;

  const alertRows = asArray(alerts);
  const fireRows = asArray(fires);

  // Clique-para-inspecionar: 1º clique abre o popup do imóvel; o próximo clique
  // no mapa FECHA (toggle) — evita o card preso. O toggle é decidido de forma
  // SÍNCRONA no clique (ref atualizado na hora, não no render) e respostas de
  // lookups superados são descartadas (seq), então cliques rápidos não reabrem
  // um popup que o usuário acabou de fechar. Popup "sem imóvel" só dentro do
  // Brasil (evita spam de popup em oceano). onClose limpa o estado quando o
  // Leaflet fecha nativamente (ex: abriu o popup de fogo por cima).
  const carInspectSeqRef = useRef(0);
  const carInspectOpenRef = useRef(false);
  const onCarInspect = async (latlng) => {
    const seq = ++carInspectSeqRef.current;
    if (carInspectOpenRef.current) {
      // Toggle: fecha.
      carInspectOpenRef.current = false;
      setCarInspect(null);
      return;
    }
    // Marca como abrindo imediatamente — o próximo clique já fecha, mesmo antes
    // do lookup resolver.
    carInspectOpenRef.current = true;
    try {
      // Não cacheamos lookup por clique: cada clique é uma coordenada única
      // e cachear com TTL fazia o popup reter respostas antigas (ex. miss de
      // polígono) quando o usuário clicava num ponto próximo que deveria ter CAR.
      // The CAR overlay tiles are now rasterized from the exact polygons, but
      // a rasterized edge can still shift a few pixels. Use a 1 km snapping
      // tolerance so clicks on visible magenta pixels resolve to the nearest
      // imóvel without matching a far-away property.
      const url = `/api/car/lookup?lat=${latlng.lat}&lon=${latlng.lng}&tolerance=1000`;
      if (process.env.NODE_ENV === 'development') {
        // eslint-disable-next-line no-console
        console.log('[CAR click]', latlng.lat, latlng.lng);
      }
      const d = await fetch(url)
        .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); });
      if (process.env.NODE_ENV === 'development') {
        // eslint-disable-next-line no-console
        console.log('[CAR lookup]', d);
      }
      if (seq !== carInspectSeqRef.current) return; // lookup superado, descarta
      const imovel = (d && d.imovel) || null;
      if (!imovel && !isInBrazil(latlng.lat, latlng.lng)) {
        carInspectOpenRef.current = false;
        setCarInspect(null);
        return;
      }
      setCarInspect({ lat: latlng.lat, lng: latlng.lng, imovel });
    } catch (e) {
      carInspectOpenRef.current = false;
      // silencioso — sem popup em falha de lookup
      if (process.env.NODE_ENV === 'development') {
        // eslint-disable-next-line no-console
        console.error('[CAR lookup error]', e);
      }
    }
  };

  // Carrega o resumo PRODES/sobreposição de um imóvel no painel lateral,
  // sem o usuário precisar copiar/colar o código do popup.
  const loadCarSummary = useCallback((cod) => {
    if (!cod || prodesLoading) return;
    setProdesInput(cod);
    // Dispara a busca no próximo tick para garantir que o estado do input já
    // foi atualizado (e o botão reflete "Verificando...").
    setTimeout(() => {
      const fakeEvent = { preventDefault: () => {} };
      prodesQueryRef.current(fakeEvent, cod);
    }, 0);
  }, [prodesLoading]);

  const fireAlertMap = useMemo(() => {
    const m = new Map();
    if (alertRows.length && fireRows.length) {
      fireRows.forEach((fire, idx) => { m.set(idx, alertForFire(fire, alertRows)); });
    }
    return m;
  }, [fireRows, alertRows]);

  // Build fire -> fullIdx lookup once per fireRows change (O(N) build, O(1) lookup)
  const fireToFullIdxMap = useMemo(() => {
    const m = new Map();
    fireRows.forEach((f, i) => m.set(f, i));
    return m;
  }, [fireRows]);

  const fireRenderList = useMemo(() => {
    if (!showFires || visibleFires.length === 0) return [];
    return visibleFires.map(fire => ({ fire, fullIdx: fireToFullIdxMap.get(fire) }));
  }, [visibleFires, fireToFullIdxMap, showFires]);

  // Quando os dados de fogo mudam, o array anterior de visibleFires pode
  // conter objetos de outro conjunto (outro período). Esses objetos legados
  // não são encontrados no fireToFullIdxMap → fullIdx undefined → keys
  // duplicadas e pontos fantasmas. Reconcilia usando id do foco se houver.
  const keyedFireRenderList = useMemo(() => {
    return fireRenderList
      .map(({ fire }) => {
        const fullIdx = fireToFullIdxMap.get(fire);
        if (fullIdx != null) return { fire, fullIdx };
        // Fallback por id quando o objeto visibleFire veio de cache/estado anterior
        const found = fireRows.find(f => f.id === fire.id);
        if (found) {
          const idx = fireToFullIdxMap.get(found);
          if (idx != null) return { fire: found, fullIdx: idx };
        }
        return null;
      })
      .filter(Boolean);
  }, [fireRenderList, fireToFullIdxMap, fireRows]);

  const visibleToFullIdxMap = useMemo(() => {
    const m = new Map();
    keyedFireRenderList.forEach(({ fullIdx }, visIdx) => m.set(visIdx, fullIdx));
    return m;
  }, [keyedFireRenderList]);

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

  // Posições estáveis p/ os Popups compartilhados: o array literal [lat, lon]
  // mudava de identidade a cada render e o efeito de lifecycle do react-leaflet
  // v4 (deps: [element, context, setOpen, position]) re-executava → removeLayer
  // + openOn → REABRIA o popup a cada re-render (ex: após zoom out).
  const fireIdx = hoveredFireIdx ?? lockedFireIdx;
  const firePos = useMemo(
    () => (fireIdx != null && fireRows[fireIdx] ? [fireRows[fireIdx].lat, fireRows[fireIdx].lon] : null),
    [fireIdx, fireRows]
  );
  const carPos = useMemo(
    () => (carInspect ? [carInspect.lat, carInspect.lng] : null),
    [carInspect]
  );
  // react-leaflet v4 não expõe onClose no Popup (prop on* é ignorada) e o Popup
  // do Leaflet não dispara 'close' próprio — o PopupCloseSync escuta o
  // 'popupclose' do MAPA e casa com a instância (via ref) para limpar o estado
  // de verdade quando o popup fecha (×, autoClose, Esc).
  const firePopupRef = useRef(null);
  const carPopupRef = useRef(null);
  const onCarPopupClose = useCallback(() => {
    carInspectOpenRef.current = false;
    setCarInspect(null);
  }, []);

  const [showMobileProdes, setShowMobileProdes] = useState(false);
  const [showMobileLegend, setShowMobileLegend] = useState(!isMobile);

  return (
    <div className={`map-stage${isMobile ? ' map-stage--mobile' : ''}`}>
      {/* Layer bar */}
      <div className={`layer-bar${isMobile ? ' layer-bar--mobile' : ''}`}>
        <div className="layer-toggles">
          <button
            className={`layer-toggle${showDeforest ? ' active' : ''}`}
            onClick={() => setShowDeforest(!showDeforest)}
          >
            <span className="lt-dot" /> {t('home.layerDeforestation')}<span className="lt-sub">PRODES</span>
          </button>
          <button
            className={`layer-toggle${showFires ? ' active' : ''}`}
            onClick={() => setShowFires(!showFires)}
          >
            <Flame size={10} /> {t('home.layerFires')}<span className="lt-sub">FIRMS</span>
          </button>
          <button
            className={`layer-toggle${satellite ? ' active' : ''}`}
            onClick={() => setSatellite(!satellite)}
          >
            <span className="lt-dot" /> {t('home.layerSatellite')}
          </button>
          <button
            className={`layer-toggle${showIndigenous ? ' active' : ''}`}
            onClick={() => setShowIndigenous(!showIndigenous)}
          >
            <span className="lt-dot" style={{ background: INDIGENOUS_STYLE.color }} /> {t('home.layerIndigenous')}
          </button>
          <button
            className={`layer-toggle${showConservation ? ' active' : ''}`}
            onClick={() => setShowConservation(!showConservation)}
          >
            <span className="lt-dot" style={{ background: CONSERVATION_STYLE.color }} /> {t('home.layerConservation')}
          </button>
          <button
            className={`layer-toggle${showCar ? ' active' : ''}`}
            onClick={() => setShowCar(!showCar)}
          >
            <span className="lt-dot" style={{ background: CAR_COLOR }} /> {t('home.layerCar')}<span className="lt-sub">CAR</span>
          </button>
        </div>
      </div>

      {/* Verificação PRODES por recibo CAR (plan: terrabrasilis-integration, Inc 12) */}
      <div className={`prodes-check${isMobile ? ' prodes-check--mobile' : ''}${showMobileProdes ? ' prodes-check--mobile-open' : ''}${prodesResult || prodesError ? ' prodes-check--mobile-has-result' : ''}`}>
        {isMobile && !showMobileProdes && (
          <button
            className="prodes-check-toggle"
            onClick={() => setShowMobileProdes(true)}
            aria-label={t('home.verifyProperty')}
          >
            {t('home.verifyProperty')}
          </button>
        )}
        {(!isMobile || showMobileProdes) && (
          <form className="prodes-check-form" onSubmit={prodesQuery}>
            <div className="prodes-check-header">
              <label className="prodes-check-label" htmlFor="prodes-input">
                {t('home.verifyProperty')}
              </label>
              {isMobile && (
                <button
                  className="prodes-result-close"
                  type="button"
                  onClick={() => setShowMobileProdes(false)}
                  aria-label={t('home.close')}
                >×</button>
              )}
            </div>
            <div className="prodes-check-row">
              <input
                id="prodes-input"
                className="prodes-check-input"
                value={prodesInput}
                onChange={(e) => setProdesInput(e.target.value)}
                placeholder={t('home.receiptPlaceholder')}
                aria-label={t('home.receiptPlaceholder')}
              />
              <button className="prodes-check-btn" type="submit" disabled={prodesLoading}>
                {prodesLoading ? t('home.checkingProperty') : t('home.check')}
              </button>
            </div>
          </form>
        )}

        {/* Resultado/erro: no mobile vira um card flutuante compacto quando o
            modal de input está fechado, para não bloquear o mapa após o CHECAR. */}
        {prodesError && (
          <div className="prodes-error">
            <span>{prodesError}</span>
            <button
              className="prodes-result-close"
              onClick={clearProdes}
              aria-label={t('home.close')}
              title={t('home.close')}
            >×</button>
          </div>
        )}
        {prodesResult && (
          <div className="prodes-result">
            {prodesResult.data ? (
              <>
                <div className="prodes-result-header">
                  <div className="prodes-result-title">{t('home.propertySummary')}</div>
                  <button
                    className="prodes-result-close"
                    onClick={clearProdes}
                    aria-label={t('home.close')}
                    title={t('home.close')}
                  >×</button>
                </div>
                <div className="prodes-result-code"><strong>{prodesResult.data.cod_imovel}</strong></div>
                {protectedOverlap && protectedOverlap.status === 'suspeito' && (
                  <div className="prodes-fraud">
                    <div className="prodes-fraud-title">⚠ {t('home.carFraudTitle')}</div>
                    <div className="prodes-fraud-detail">
                      {t('home.carFraudDetail', {
                        name: protectedOverlap.overlaps[0].name,
                        type: protectedOverlap.overlaps[0].type === 'uc' ? 'UC' : 'TI',
                        pct: protectedOverlap.overlaps[0].overlap_pct,
                      })}
                      {protectedOverlap.overlaps.length > 1 &&
                        ` ${t('home.carFraudMore', { n: protectedOverlap.overlaps.length - 1 })}`}
                    </div>
                    <div className="prodes-fraud-note">{t('home.carFraudNote')}</div>
                  </div>
                )}
                {protectedOverlap && protectedOverlap.status === 'indeterminado' && (
                  <div className="prodes-result-meta">{t('home.carOverlapIndeterminate')}</div>
                )}
                {prodesResult.data.has_prodes ? (
                  <div className="prodes-result-yes">
                    {t('home.hasProdesYes', {
                      area: prodesResult.data.prodes_area_ha,
                      years: (prodesResult.data.years || []).join(', '),
                    })}
                  </div>
                ) : (
                  <div className="prodes-result-no">{t('home.hasProdesNo')}</div>
                )}
                <div className="prodes-result-meta">
                  {t('home.propertyAreaLabel', { area: prodesResult.data.property_area_ha ?? '—' })} · {t('home.prodesEstimate')}
                </div>
                {prodesResult.data.years && prodesResult.data.years.length > 0 && (
                  <div className="prodes-result-meta">
                    {t('home.yearsLabel', { years: prodesResult.data.years.join(', ') })}
                  </div>
                )}
                {prodesResult.data.regrowth && (
                  <div className="prodes-result-meta">{t('home.regrowthNote')}</div>
                )}
              </>
            ) : (
              <div className="prodes-result-no">
                {prodesResult.reason === 'car_unavailable'
                  ? t('home.carUnavailable')
                  : prodesResult.reason === 'not_found'
                    ? t('home.propertyNotFound')
                    : t('home.prodesNotAvailable')}
              </div>
            )}
          </div>
        )}
      </div>

      {/* Map */}
      <MapContainer
          key={mapKey}
          center={[-14.235, -51.925]}
          zoom={5}
          zoomSnap={0.5}
          zoomDelta={0.5}
          scrollWheelZoom
          preferCanvas
          zoomControl={false}
          attributionControl={false}
          style={{ position: 'absolute', inset: 0, width: '100%', height: '100%' }}
        >
          <TileLayer key={satellite ? 'sat' : 'osm'} attribution={tileAttr} url={tileUrl} />
          <MapController activeAlert={flyToAlert} />
          <FocusController focus={focus} />
          <ProdesFlyTo bbox={prodesResult && prodesResult.data ? prodesResult.data.bbox : null} />
          <BiomeHighlightLayer activeBiome={activeBiome} biomeGeoJSON={biomeGeoJSON} />
          <FireHoverLock
            fires={fireRows}
            hoveredFireIdx={hoveredFireIdx}
            lockedFireIdx={lockedFireIdx}
            onHoverEnd={onFireHoverEnd}
            onClearLock={onClearFireLock}
          />
          <PopupCloseSync
            carPopupRef={carPopupRef}
            firePopupRef={firePopupRef}
            onCarClose={onCarPopupClose}
            onFireClose={onClearFireLock}
          />
          {showDeforest && (
            <TileLayer
              key="prodes-tiles"
              url="/api/tiles/prodes?z={z}&x={x}&y={y}"
              opacity={0.33}
              tileSize={256}
              maxNativeZoom={12}
              minZoom={2}
              keepBuffer={4}
              updateWhenZooming={false}
              updateWhenIdle={false}
              fadeIn={150}
              attribution="&copy; INPE/TerraBrasilis PRODES"
              zIndex={100}
            />
          )}
          {showCar && (
            <TileLayer
              key="car-tiles"
              className="car-tiles"
              url={`/api/tiles/car?z={z}&x={x}&y={y}&v=${CAR_TILES_VERSION}`}
              opacity={0.5}
              tileSize={256}
              maxNativeZoom={12}
              minNativeZoom={6}
              minZoom={2}
              keepBuffer={4}
              updateWhenZooming={false}
              updateWhenIdle={false}
              fadeIn={150}
              attribution="&copy; SICAR"
              zIndex={90}
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
                layer.bindPopup(`<strong>🏕 ${esc(p.name)}</strong><br/>Terra Indígena · ${esc(p.state_abbr)}<br/><small>${esc(p.municipality)}</small>`);
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
                layer.bindPopup(`<strong>🌿 ${esc(p.name)}</strong><br/>${esc(p.category) || 'UC'} · ${esc(p.state_abbr)}`);
              }}
            />
          )}
          <ViewportFireFilter fires={fireRows} generation={fireDataGeneration} onVisibleFiresChange={setVisibleFires} />
          <CanvasRedrawOnToggle flag={showFires} />
          {(showFires || showCar) && (
            <FireEventsHandler
              fires={visibleFires}
              fireAlertMap={fireAlertMap}
              visibleToFullIdxMap={visibleToFullIdxMap}
              onFireOver={onFireOver}
              onFireClick={onFireClick}
              onFireHoverEnd={onFireHoverEnd}
              showCar={showCar}
              onCarInspect={onCarInspect}
            />
          )}
          {showFires && (
            <>
              {keyedFireRenderList.map(({ fire, fullIdx }) => (
                <FireMarker
                  key={`f-${fullIdx}`}
                  fire={fire}
                  idx={fullIdx}
                  s={fireStyle(fire)}
                  highlighted={highlightedFires?.has(fullIdx)}
                />
              ))}
              {/* Single shared Popup for hovered/locked fire - avoids thousands of Popup components */}
              {(hoveredFireIdx != null || lockedFireIdx != null) && fireRows[hoveredFireIdx ?? lockedFireIdx] && (
                <Popup
                  ref={firePopupRef}
                  position={firePos}
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
          {carInspect && (
            <Popup
              ref={carPopupRef}
              position={carPos}
              autoClose
              closeOnClick={false}
            >
              {carInspect.imovel ? (
                <div className="car-popup">
                  <div className="car-popup-title">📋 {carInspect.imovel.id}</div>
                  <div className="car-popup-sub">{carInspect.imovel.name}/{carInspect.imovel.uf}</div>
                  <button
                    className="car-popup-btn"
                    onClick={() => loadCarSummary(carInspect.imovel.id)}
                    disabled={prodesLoading}
                  >
                    {prodesLoading ? t('home.checkingProperty') : t('home.viewPropertySummary')}
                  </button>
                </div>
              ) : (
                <div>{t('home.noCar')}</div>
              )}
            </Popup>
          )}
        </MapContainer>

      {/* Nature legend — bottom left on desktop; mobile uses a pill toggle that opens a modal sheet so it never covers other controls. */}
      {showFires && (
        <div className={`nature-legend${isMobile ? ' nature-legend--mobile' : ''}${isMobile && !showMobileLegend ? ' nature-legend--mobile-collapsed' : ''}${isMobile && showMobileLegend ? ' nature-legend--mobile-open' : ''}`}>
          {isMobile && (
            <button
              className="nature-legend-toggle"
              onClick={() => setShowMobileLegend(o => !o)}
              aria-label={showMobileLegend ? t('home.collapseLegend') : t('home.expandLegend')}
            >
              <span className="nature-legend-toggle-dots">
                {['crime', 'suspeito', 'permitido', 'natural'].map(n => (
                  <span key={n} className="nature-legend-dot" style={{ background: FIRE_NATURE_COLORS[n].color }} />
                ))}
              </span>
              {showMobileLegend ? '×' : t('home.natureLegend')}
            </button>
          )}
          {(!isMobile || showMobileLegend) && (
            isMobile ? (
              <div className="nature-legend-card" onClick={(e) => { if (e.target === e.currentTarget) setShowMobileLegend(false); }}>
                <div className="nature-legend-card-inner">
                  <div className="nature-legend-card-header">
                    <span className="nature-legend-title">{t('home.natureLegend')}</span>
                    <button
                      className="nature-legend-card-close"
                      onClick={() => setShowMobileLegend(false)}
                      aria-label={t('home.close')}
                    >×</button>
                  </div>
                  {['crime', 'suspeito', 'permitido', 'natural'].map(n => (
                    <span key={n} className="nature-legend-item">
                      <span className="nature-legend-dot" style={{ background: FIRE_NATURE_COLORS[n].color }} />
                      {t(`home.nature_${n}`)}
                    </span>
                  ))}
                  <span className="nature-legend-sep" />
                  <span className="nature-legend-title">{t('home.confidenceLegend')}</span>
                  <span className="nature-legend-gradient">
                    <span style={{ background: FIRE_STYLES.nominal.color }} />
                    <span style={{ background: FIRE_STYLES.high.color }} />
                    <span style={{ background: FIRE_STYLES.low.color }} />
                  </span>
                  <span className="nature-legend-item nature-legend-item--confidence">
                    <span>{t('home.confidenceNominal')}</span>
                    <span>{t('home.confidenceHigh')}</span>
                    <span>{t('home.confidenceLow')}</span>
                  </span>
                  <span className="nature-legend-sep" />
                  <div className="nature-legend-period">
                    <span className="nature-legend-title">{t('home.firePeriod')}</span>
                    <div className="days-chips">
                      {[['', t('home.firePeriodRecent')], ['7', `7 ${t('home.days')}`], ['30', `30 ${t('home.days')}`], ['90', `90 ${t('home.days')}`], ['365', `365 ${t('home.days')}`]].map(([val, label]) => {
                        const active = (fireDays == null ? '' : String(fireDays)) === val;
                        return (
                          <button
                            key={val}
                            type="button"
                            className={`days-chip${active ? ' days-chip--active' : ''}`}
                            onClick={() => setFireDays(val === '' ? null : Number(val))}
                          >
                            {label}
                          </button>
                        );
                      })}
                    </div>
                  </div>
                </div>
              </div>
            ) : (
              <>
                <span className="nature-legend-title">{t('home.natureLegend')}</span>
                {['crime', 'suspeito', 'permitido', 'natural'].map(n => (
                  <span key={n} className="nature-legend-item">
                    <span className="nature-legend-dot" style={{ background: FIRE_NATURE_COLORS[n].color }} />
                    {t(`home.nature_${n}`)}
                  </span>
                ))}
                <span className="nature-legend-sep" />
                <span className="nature-legend-title">{t('home.confidenceLegend')}</span>
                <span className="nature-legend-gradient">
                  <span style={{ background: FIRE_STYLES.nominal.color }} />
                  <span style={{ background: FIRE_STYLES.high.color }} />
                  <span style={{ background: FIRE_STYLES.low.color }} />
                </span>
                <span className="nature-legend-item nature-legend-item--confidence">
                  <span>{t('home.confidenceNominal')}</span>
                  <span>{t('home.confidenceHigh')}</span>
                  <span>{t('home.confidenceLow')}</span>
                </span>
                <span className="nature-legend-sep" />
                <div className="nature-legend-period">
                  <span className="nature-legend-title">{t('home.firePeriod')}</span>
                  <div className="days-chips">
                    {[['', t('home.firePeriodRecent')], ['7', `7 ${t('home.days')}`], ['30', `30 ${t('home.days')}`], ['90', `90 ${t('home.days')}`], ['365', `365 ${t('home.days')}`]].map(([val, label]) => {
                      const active = (fireDays == null ? '' : String(fireDays)) === val;
                      return (
                        <button
                          key={val}
                          type="button"
                          className={`days-chip${active ? ' days-chip--active' : ''}`}
                          onClick={() => setFireDays(val === '' ? null : Number(val))}
                        >
                          {label}
                        </button>
                      );
                    })}
                  </div>
                </div>
              </>
            )
          )}
        </div>
      )}

      {/* Consolidated float panel — bottom right */}
      <FloatPanel
        alerts={alertRows}
        loaded={alerts !== null}
        activeAlertId={activeAlertId}
        activeBiome={activeBiome}
        onAlertEnter={onAlertEnter}
        onAlertLeave={onAlertLeave}
        airQuality={airQuality}
        temperature={temperature}
        onBiomeHover={onBiomeHover}
        isMobile={isMobile}
      />
    </div>
  );
});

const DEFAULT_LAT = -14.235;
const DEFAULT_LON = -51.925;

export default function Home() {
  const { t } = useI18n();
  const [firesState,     setFiresState]     = useState({ fires: null, generation: 0 });
  const fires = firesState.fires;
  const setFires = useCallback((next) => {
    if (next && typeof next === 'object' && 'fires' in next && 'generation' in next) {
      setFiresState(next);
    } else {
      setFiresState(prev => ({ fires: next, generation: prev.generation }));
    }
  }, []);
  // Período dos focos (plan: sinaflor-fogo-permitido): null = 10k mais recentes;
  // 7/30/90/365 = janela ?days=N (revela focos antigos, ex: permitido).
  // Default 90 — durante a moratória (jul-out) os 10k mais recentes são todos
  // 'crime' e escondem os 'permitido' (Abr–Jun); 90 dias é o mínimo para ver
  // verdes sem carregar o ano todo.
  const [fireDays,       setFireDays]       = useState(90);
  const [airQuality,     setAirQuality]     = useState(null);
  const [temperature,    setTemperature]    = useState(null);
  const [showDeforest,   setShowDeforest]   = useState(true);
  const [showFires,      setShowFires]      = useState(true);
  const [showIndigenous, setShowIndigenous] = useState(false);
  const [showConservation, setShowConservation] = useState(false);
  const [indigenousGeo,  setIndigenousGeo]  = useState(null);
  const [conservationGeo, setConservationGeo] = useState(null);
  const [alerts,         setAlerts]         = useState(null);
  const [alertHoverId,   setAlertHoverId]   = useState(null);
  const [fireAlertId,    setFireAlertId]    = useState(null);
  const [hoveredFireIdx, setHoveredFireIdx] = useState(null);
  const [lockedFireIdx,  setLockedFireIdx]  = useState(null);
  const [lockedFireAlertId, setLockedFireAlertId] = useState(null);
  const [activeBiome,    setActiveBiome]    = useState(null);
  const [biomeGeoJSON,   setBiomeGeoJSON]   = useState(null);
  const fireHoverOutTimeoutRef = useRef(null);
  // Versão incremental para invalidar viewport-derived visibleFires quando o
  // período muda. O array visibleFires pode reter objetos do período anterior,
  // então bampeamos a geração até que o novo fetch re-popule fires.
  const fireDataGenerationRef = useRef(0);
  const alertFlyToTimerRef  = useRef(null);
  const biomeHoverTimerRef  = useRef(null);
  const indiFetchedRef      = useRef(false);
  const consFetchedRef      = useRef(false);
  const biomeFetchedRef     = useRef(false);
  const biomeFetchAcRef     = useRef(null);

  const activeAlertId = lockedFireAlertId || alertHoverId || fireAlertId;

  // Drilldown target from the dashboard (?focus=state:UF|biome:NAME|land:NAME).
  const focus = useMemo(() => {
    try { return parseFocus(new URLSearchParams(window.location.search).get('focus')); }
    catch { return null; }
  }, []);

  // Biome focus: fetch the boundaries eagerly (normally lazy on hover) and
  // highlight the biome; BiomeHighlightLayer fits bounds once loaded.
  useEffect(() => {
    if (!focus || focus.kind !== 'biome' || !focus.id) return;
    if (!biomeFetchedRef.current) {
      biomeFetchedRef.current = true;
      const ac = new AbortController();
      biomeFetchAcRef.current = ac;
      fetch('/api/biome-boundaries', { signal: ac.signal })
        .then(r => r.json())
        .then(d => setBiomeGeoJSON(d))
        .catch(err => { if (err.name !== 'AbortError') console.error('Biome boundaries fetch error:', err); });
    }
    setActiveBiome(focus.id);
  }, [focus]);

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

  const handleBiomeHover = useCallback((name) => {
    // Kick off the boundaries fetch on first interaction (no debounce — it's idempotent)
    if (name && !biomeFetchedRef.current) {
      biomeFetchedRef.current = true;
      const ac = new AbortController();
      biomeFetchAcRef.current = ac;
      fetch('/api/biome-boundaries', { signal: ac.signal })
        .then(r => r.json())
        .then(d => setBiomeGeoJSON(d))
        .catch(err => { if (err.name !== 'AbortError') console.error('Biome boundaries fetch error:', err); });
    }
    // Debounce highlight commit: rapid mouse-over across biome rows no longer
    // queues expensive fitBounds animations. On leave (name=null) commit immediately.
    if (biomeHoverTimerRef.current) clearTimeout(biomeHoverTimerRef.current);
    if (name == null) {
      setActiveBiome(null);
    } else {
      biomeHoverTimerRef.current = setTimeout(() => setActiveBiome(name), 120);
    }
  }, []);

  useEffect(() => () => {
    if (fireHoverOutTimeoutRef.current) clearTimeout(fireHoverOutTimeoutRef.current);
    if (alertFlyToTimerRef.current) clearTimeout(alertFlyToTimerRef.current);
    if (biomeHoverTimerRef.current) clearTimeout(biomeHoverTimerRef.current);
    if (biomeFetchAcRef.current) biomeFetchAcRef.current.abort();
  }, []);

  useEffect(() => {
    let ac = new AbortController();
    const fetchAlerts = (forceRefresh) => {
      ac.abort();
      ac = new AbortController();
      if (forceRefresh) invalidateApiCache('/api/alerts');
      cachedFetch('/api/alerts', { ttl: 180_000, signal: ac.signal })
        .then(d => setAlerts(asArray(d.alerts)))
        .catch(err => { if (err.name !== 'AbortError') console.error('Alerts fetch error:', err); });
    };
    fetchAlerts(false);
    const id = setInterval(() => fetchAlerts(true), 180000);
    return () => {
      clearInterval(id);
      ac.abort();
    };
  }, []);

const NATURE_EXPAND = { c: 'crime', s: 'suspeito', p: 'permitido', n: 'natural' };
const CONF_EXPAND = { n: 'nominal', h: 'high', l: 'low' };

function expandCompactFires(compact) {
  return compact.map(f => ({
    id: f.i,
    lat: f.la,
    lon: f.lo,
    confidence: CONF_EXPAND[f.c] || f.c || 'low',
    nature: NATURE_EXPAND[f.n] || f.n || null,
    acq_date: f.d,
    acq_time: null,
    satellite: null,
    bright_ti4: null,
  })).filter(f => f.lat != null && f.lon != null);
}

  // Fire data — single global fetch, cached client-side (240s) and viewport-clipped by Leaflet/canvas.
  // Re-fetching on pan was causing the fires array identity to change every pan, remounting all CircleMarkers
  // and producing visible pop-in. Canvas renderer (preferCanvas on MapContainer) handles viewport clipping cheaply.
  //
  // Usa ?compact=true: backend envia campos curtos (i,la,lo,c,n,d) reduzindo
  // o payload JSON em ~66% (3.5MB → 1.1MB para 15k pontos). O frontend expande
  // localmente; detalhes (satélite, temp, evidence, vegetation) vêm do popup via
  // /api/fire-detail.
  useEffect(() => {
    const ac = new AbortController();
    const generation = ++fireDataGenerationRef.current;
    const validFire = f => f.lat != null && f.lon != null;
    // Cache por período (chave inclui fireDays) — trocar o seletor não pode
    // servir o cache de outra janela.
    const cacheKey = 'fires' + (fireDays ? ':' + fireDays : '');
    const cached = getCache(cacheKey, 240);
    if (cached) setFires(asArray(cached.fires).filter(validFire));
    // ?limit=15000: cap suficiente para ver permitido (162/90d) sem travar
    // o frontend com 50k CircleMarkers. Sem days, o default já é 10k.
    // Vegetação (PRODES) não é mais trazida em lote — é buscada sob demanda
    // no popup via /api/fire-detail, reduzindo o tempo de resposta de ~4s para ~0.02s.
    const limit = fireDays ? '&limit=15000' : '';
    const url = '/api/fires' + (fireDays ? `?days=${fireDays}` : '') + limit + '&compact=true';
    fetch(url, { signal: ac.signal })
      .then(r => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
      .then(d => {
        const raw = asArray(d.fires);
        // Compat: backend pode devolver compacto (array de arrays/objetos curtos)
        // ou formato expandido. Detecta pelo primeiro campo.
        const isCompact = raw.length > 0 && (Array.isArray(raw[0]) || raw[0].i != null);
        const f = (isCompact ? expandCompactFires(raw) : raw).filter(validFire);
        setFires({ fires: f, generation });
        setCache(cacheKey, { fires: f, last_sync: d.last_sync });
      })
      .catch(err => {
        if (err.name !== 'AbortError') {
          console.error('Fires fetch error:', err);
          if (!cached) setFires({ fires: [], generation });
        }
      });
    return () => ac.abort();
  }, [fireDays]);

  // Weather (cached 15min in localStorage)
  useEffect(() => {
    const ac = new AbortController();
    const fetchWeather = (lat, lon) => {
      const latK = lat.toFixed(1), lonK = lon.toFixed(1);
      const aqiKey = `weather_aqi_${latK}_${lonK}`;
      const tempKey = `weather_temp_${latK}_${lonK}`;

      const cachedAqi = getCache(aqiKey, 15);
      const cachedTemp = getCache(tempKey, 15);
      if (cachedAqi) setAirQuality(cachedAqi);
      if (cachedTemp) setTemperature(cachedTemp);
      if (cachedAqi && cachedTemp) return;

      cachedFetch(`/api/weather?lat=${lat}&lon=${lon}`, { ttl: 60_000, signal: ac.signal })
        .then(d => {
          if (d.aqi != null) {
            const aq = { aqi: d.aqi, pm25: d.pm25 ?? '-', humidity: d.aqi_humidity ?? '-' };
            setAirQuality(aq); setCache(aqiKey, aq);
          }
          if (d.temp != null) {
            const temp = { temp: d.temp, feels_like: d.feels_like, humidity: d.humidity, city: d.city, wind_speed: d.wind_speed, wind_direction: d.wind_direction };
            setTemperature(temp); setCache(tempKey, temp);
          }
        })
        .catch(err => { if (err.name !== 'AbortError') console.error('Weather fetch error:', err); });
    };

    fetchWeather(DEFAULT_LAT, DEFAULT_LON);

    if (navigator.geolocation) {
      navigator.geolocation.getCurrentPosition(
        p  => fetchWeather(p.coords.latitude, p.coords.longitude),
        () => {},
        { timeout: 3000 }
      );
    }
    return () => ac.abort();
  }, []);

  // Lazy-load indigenous lands GeoJSON. Backend returns FeatureCollection (newer)
  // or legacy raw bounds map; toFeatureCollection normalizes both. v3 cache key
  // invalidates any stale localStorage written during the mid-deploy window.
  useEffect(() => {
    if (!showIndigenous || indiFetchedRef.current) return;
    indiFetchedRef.current = true;
    const cached = getCache('geo_indigenous_lands_v3', 1440);
    const cachedFc = cached && toFeatureCollection(cached);
    if (cachedFc) { setIndigenousGeo(cachedFc); return; }
    const ac = new AbortController();
    cachedFetch('/api/indigenous-lands', { ttl: 3600_000, signal: ac.signal })
      .then(d => {
        const fc = toFeatureCollection(d);
        if (!fc) return;
        setIndigenousGeo(fc);
        setCache('geo_indigenous_lands_v3', fc);
      })
      .catch(err => { if (err.name !== 'AbortError') console.error('Indigenous lands fetch error:', err); });
    return () => ac.abort();
  }, [showIndigenous]);

  // Lazy-load conservation units GeoJSON (same normalization + cache strategy).
  useEffect(() => {
    if (!showConservation || consFetchedRef.current) return;
    consFetchedRef.current = true;
    const cached = getCache('geo_conservation_units_v3', 1440);
    const cachedFc = cached && toFeatureCollection(cached);
    if (cachedFc) { setConservationGeo(cachedFc); return; }
    const ac = new AbortController();
    cachedFetch('/api/conservation-units', { ttl: 3600_000, signal: ac.signal })
      .then(d => {
        const fc = toFeatureCollection(d);
        if (!fc) return;
        setConservationGeo(fc);
        setCache('geo_conservation_units_v3', fc);
      })
      .catch(err => { if (err.name !== 'AbortError') console.error('Conservation units fetch error:', err); });
    return () => ac.abort();
  }, [showConservation]);

  return (
    <div className="home-main">
      <MapaCard
        fires={fires}
        showDeforest={showDeforest}
        showFires={showFires}
        setShowDeforest={setShowDeforest}
        setShowFires={setShowFires}
        fireDays={fireDays}
        setFireDays={setFireDays}
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
        airQuality={airQuality}
        temperature={temperature}
        activeBiome={activeBiome}
        biomeGeoJSON={biomeGeoJSON}
        onBiomeHover={handleBiomeHover}
        focus={focus}
        fireDataGeneration={fireDataGenerationRef.current}
      />
    </div>
  );
}

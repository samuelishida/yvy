import React, { useState } from 'react';
import './Home.css';

const MAPS = [
  {
    id: 'deforestation',
    label: 'Desmatamento',
    icon: '🌳',
    tag: 'PRODES · INPE',
    src: 'https://terrabrasilis.dpi.inpe.br/app/map/deforestation?hl=pt_br',
  },
  {
    id: 'air-quality',
    label: 'Qualidade do Ar',
    icon: '💨',
    tag: 'WAQI',
    src: 'https://waqi.info/#/c/-14.636/-58.315/5.1z?lang=pt',
  },
  {
    id: 'temperature',
    label: 'Temperatura',
    icon: '🌡️',
    tag: 'OpenWeatherMap',
    src: 'https://openweathermap.org/weathermap?basemap=map&cities=true&layer=temperature&lat=-22.8042&lon=-47.0668&zoom=5&lang=pt_br',
  },
  {
    id: 'windy',
    label: 'Tempestades',
    icon: '🌩️',
    tag: 'Windy',
    src: 'https://embed.windy.com/embed2.html?lat=-22.952&lon=-43.212&detailLat=-22.952&detailLon=-43.212&width=650&height=450&zoom=5&level=surface&overlay=wind&product=ecmwf&menu=&message=true&marker=true&calendar=now&pressure=true&type=map&location=coordinates&detail=true&metricWind=default&metricTemp=default&radarRange=-1',
  },
  {
    id: 'forest',
    label: 'Florestas Globais',
    icon: '🌲',
    tag: 'Global Forest Watch',
    src: 'https://www.globalforestwatch.org/map/?lang=pt_BR&map=eyJjZW50ZXIiOnsibGF0IjotMTQuODM5NDU2MDI0MjIzNDQsImxuZyI6LTU3LjMxMDExNzE1MDUyODc2fSwiem9vbSI6NC4xOTIyMzU2Njc2Njc4MDh9',
  },
  {
    id: 'sea-level',
    label: 'Nível do Mar',
    icon: '🌊',
    tag: 'Climate Central',
    src: 'https://coastal.climatecentral.org/embed/map/10/-43.3654/-22.7935/?theme=water_level&map_type=water_level_above_mhhw&basemap=roadmap&contiguous=true&elevation_model=best_available&water_level=1.0&water_unit=m',
  },
  {
    id: 'nasa-fire',
    label: 'Incêndios NASA',
    icon: '🔥',
    tag: 'NASA FIRMS',
    src: 'https://firms.modaps.eosdis.nasa.gov/map/?lang=pt',
  },
];

export default function Home() {
  const [active, setActive] = useState(MAPS[0].id);
  const activeMap = MAPS.find((m) => m.id === active);

  return (
    <div className="home">
      {/* Selector bar */}
      <div className="selector-bar">
        <div className="selector-scroll">
          {MAPS.map((m) => (
            <button
              key={m.id}
              className={`map-btn ${active === m.id ? 'map-btn--active' : ''}`}
              onClick={() => setActive(m.id)}
            >
              <span className="map-btn__icon">{m.icon}</span>
              <span className="map-btn__label">{m.label}</span>
              {m.tag && <span className="map-btn__tag">{m.tag}</span>}
            </button>
          ))}
        </div>
      </div>

       {/* Map iframe panel */}
       <div className="map-panel">
         {MAPS.map((m) => (
            <iframe
              key={m.id}
              src={m.src}
              title={m.label}
              className={`map-iframe ${active === m.id ? 'map-iframe--visible' : ''}`}
              allow="fullscreen"
              loading="lazy"
              sandbox="allow-scripts allow-same-origin allow-popups allow-forms"
              referrerPolicy="no-referrer"
              onError={(e) => {
                // Suppress cross-origin iframe JS errors in console
                e.preventDefault();
                return false;
              }}
            />
         ))}
         <div className="map-overlay-corner">
           <span className="overlay-dot" />
           <span className="overlay-text">Dados em tempo real</span>
         </div>
       </div>
    </div>
  );
}

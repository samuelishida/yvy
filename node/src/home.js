import React, { useState } from 'react';
import 'bootstrap/dist/css/bootstrap.min.css'; // Certifique-se de importar o CSS do Bootstrap

const Home = () => {
  const [activeIframe, setActiveIframe] = useState('iframe-main'); // Estado para controlar qual iframe será exibido
  const [navbarOpen, setNavbarOpen] = useState(false); // Estado para controlar o colapso da navbar

  const showIframe = (iframeId) => {
    setActiveIframe(iframeId); // Alterna os iframes conforme o botão clicado
  };

  const toggleNavbar = () => {
    setNavbarOpen(!navbarOpen); // Alterna entre aberto/fechado para o menu responsivo
  };

  return (
    <div>
      {/* Navbar Responsiva */}
      <nav className="navbar navbar-expand-lg navbar-light bg-light">
        <a className="navbar-brand" href="#">Yvy</a>
        <button
          className="navbar-toggler"
          type="button"
          onClick={toggleNavbar}
          aria-controls="navbarResponsive"
          aria-expanded={navbarOpen}
          aria-label="Toggle navigation"
        >
          <span className="navbar-toggler-icon"></span>
        </button>
        <div className={`collapse navbar-collapse ${navbarOpen ? 'show' : ''}`} id="navbarResponsive">
          <ul className="navbar-nav ml-auto">
            {/* Botão com dropdown */}
            <li className="nav-item dropdown">
              <a
                className="nav-link dropdown-toggle"
                href="#"
                id="navbarDropdown"
                role="button"
                data-toggle="dropdown"
                aria-haspopup="true"
                aria-expanded="false"
              >
                Visualizações Ambientais
              </a>
              <div className="dropdown-menu" aria-labelledby="navbarDropdown">
                <button className="dropdown-item" onClick={() => showIframe('iframe-air-quality')}>Qualidade do Ar</button>
                <button className="dropdown-item" onClick={() => showIframe('iframe-forest')}>Florestas Global Forest Watch</button>
                <button className="dropdown-item" onClick={() => showIframe('iframe-temperature')}>Temperatura OpenWeatherMap</button>
                <button className="dropdown-item" onClick={() => showIframe('iframe-terrabrasilis')}>TerraBrasilis</button>
                <button className="dropdown-item" onClick={() => showIframe('iframe-sea-level')}>Nível do Mar 80 anos</button>
              </div>
            </li>
            {/* Link externo separado */}
            <li className="nav-item">
              <a
                className="nav-link"
                href="https://worldview.earthdata.nasa.gov/"
                target="_blank"
                rel="noopener noreferrer"
              >
                Queimadas da NASA
              </a>
            </li>
          </ul>
        </div>
      </nav>

      {/* Renderizando os iframes conforme a seleção */}
      <div id="iframe-air-quality" className="iframe-container" style={{ display: activeIframe === 'iframe-air-quality' ? 'block' : 'none' }}>
        <iframe
          src="https://waqi.info/#/c/-14.636/-58.315/5.1z"
          title="Mapa de Qualidade do Ar"
          width="100%"
          height="600px"
          style={{ border: 'none' }}
        />
      </div>

      <div id="iframe-forest" className="iframe-container" style={{ display: activeIframe === 'iframe-forest' ? 'block' : 'none' }}>
        <iframe
          src="https://www.globalforestwatch.org/map/?lang=pt_BR&map=eyJjZW50ZXIiOnsibGF0IjotMTQuODM5NDU2MDI0MjIzNDQsImxuZyI6LTU3LjMxMDExNzE1MDUyODc2fSwiem9vbSI6NC4xOTIyMzU2Njc2Njc4MDh9"
          title="Mapa de Florestas Global Forest Watch"
          width="100%"
          height="600px"
          style={{ border: 'none' }}
        />
      </div>

      <div id="iframe-temperature" className="iframe-container" style={{ display: activeIframe === 'iframe-temperature' ? 'block' : 'none' }}>
        <iframe
          src="https://openweathermap.org/weathermap?basemap=map&cities=true&layer=temperature&lat=-22.8042&lon=-47.0668&zoom=5"
          title="Mapa de Temperatura OpenWeatherMap"
          width="100%"
          height="600px"
          style={{ border: 'none' }}
        />
      </div>

      <div id="iframe-terrabrasilis" className="iframe-container" style={{ display: activeIframe === 'iframe-terrabrasilis' ? 'block' : 'none' }}>
        <iframe
          src="https://terrabrasilis.dpi.inpe.br/app/map/deforestation?hl=pt_br"
          title="Mapa TerraBrasilis"
          width="100%"
          height="600px"
          style={{ border: 'none' }}
        />
      </div>

      <div id="iframe-sea-level" className="iframe-container" style={{ display: activeIframe === 'iframe-sea-level' ? 'block' : 'none' }}>
        <iframe
          src="https://coastal.climatecentral.org/embed/map/10/-43.3654/-22.7935/?theme=water_level&map_type=water_level_above_mhhw&basemap=roadmap&contiguous=true&elevation_model=best_available&water_level=1.0&water_unit=m"
          title="Climate Central | Land below 1.0 meters of water"
          width="100%"
          height="600px"
          style={{ border: 'none' }}
        />
      </div>
    </div>
  );
};

export default Home;

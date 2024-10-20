import React from 'react';

const Home = () => {
  return (
   
    <link href="https://stackpath.bootstrapcdn.com/bootstrap/4.5.2/css/bootstrap.min.css" rel="stylesheet">
    <title>Yvy - Visualização de Mapas e Notícias Ambientais</title>

    <div className="iframe-container">
      

      <div class="jumbotron text-center">
        <h1 class="display-4">Bem-vindo ao Yvy!</h1>
        <p class="lead">Visualize dados ambientais de forma fácil e interativa.</p>
        <div class="d-flex flex-wrap justify-content-center mt-4">
            <button class="btn btn-custom btn-lg mb-3" onclick="showIframe('iframe-air-quality')">Qualidade do Ar</button>
            <button class="btn btn-custom btn-lg mb-3" onclick="showIframe('iframe-forest')">Florestas Global Forest Watch</button>
            <button class="btn btn-custom btn-lg mb-3" onclick="showIframe('iframe-temperature')">Temperatura OpenWeatherMap</button>
            <a class="btn btn-custom btn-lg mb-3" href="https://worldview.earthdata.nasa.gov/" target="_blank">Queimadas da NASA</a>
            <button class="btn btn-custom btn-lg mb-3" onclick="showIframe('iframe-terrabrasilis')">TerraBrasilis</button>
            <button class="btn btn-custom btn-lg mb-3" onclick="showIframe('iframe-sea-level')">Nível do Mar 80 anos</button>
        </div>
    </div>

    <!-- Iframe principal que deve sempre ser visível -->
    <div id="iframe-main" class="iframe-container">
        <iframe src="/hub.html" title="Yvy Home"></iframe>
    </div>

    <!-- Iframes secundários para exibir os mapas -->
    <div id="iframe-air-quality" class="iframe-container iframe-secondary">
        <iframe src="https://waqi.info/#/c/-14.636/-58.315/5.1z" title="Mapa de Qualidade do Ar"></iframe>
    </div>
    <div id="iframe-forest" class="iframe-container iframe-secondary">
        <iframe src="https://www.globalforestwatch.org/map/?lang=pt_BR&map=eyJjZW50ZXIiOnsibGF0IjotMTQuODM5NDU2MDI0MjIzNDQsImxuZyI6LTU3LjMxMDExNzE1MDUyODc2fSwiem9vbSI6NC4xOTIyMzU2Njc2Njc4MDh9" title="Mapa de Florestas Global Forest Watch"></iframe>
    </div>
    <div id="iframe-temperature" class="iframe-container iframe-secondary">
        <iframe src="https://openweathermap.org/weathermap?basemap=map&cities=true&layer=temperature&lat=-22.8042&lon=-47.0668&zoom=5" title="Mapa de Temperatura OpenWeatherMap"></iframe>
    </div>
    <div id="iframe-terrabrasilis" class="iframe-container iframe-secondary">
        <iframe src="https://terrabrasilis.dpi.inpe.br/app/map/deforestation?hl=pt_br" title="Mapa TerraBrasilis"></iframe>
    </div>
    <div id="iframe-sea-level" class="iframe-container iframe-secondary">
        <iframe src="https://coastal.climatecentral.org/embed/map/10/-43.3654/-22.7935/?theme=water_level&map_type=water_level_above_mhhw&basemap=roadmap&contiguous=true&elevation_model=best_available&water_level=1.0&water_unit=m" title="Climate Central | Land below 1.0 meters of water"></iframe>
    </div>

    <script>
        function showIframe(iframeId) {
            // Esconder todos os iframes secundários
            const iframes = document.querySelectorAll('.iframe-secondary');
            iframes.forEach(iframe => {
                iframe.classList.remove('active');
            });

            // Esconder o iframe principal
            document.getElementById('iframe-main').style.display = 'none';

            // Mostrar o iframe selecionado
            const selectedIframe = document.getElementById(iframeId);
            if (selectedIframe) {
                selectedIframe.classList.add('active');
            }
        }
    </script>
</body>
      
    </div>
    
  );
};

export default Home;

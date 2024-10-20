<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no">
    <link href="https://stackpath.bootstrapcdn.com/bootstrap/4.5.2/css/bootstrap.min.css" rel="stylesheet">
    <title>Yvy - Visualização de Mapas e Notícias Ambientais</title>
    <style>
        /* Definir um fundo com gradiente suave de tons de verde */
        body {
            background: linear-gradient(to bottom right, #d8f3dc, #b7e4c7);
            font-family: 'Arial', sans-serif;
            color: #333;
            margin: 0;
            padding: 0;
            min-height: 100vh;
        }

        /* Estilização geral dos contêineres */
        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
        }

        /* Navbar */
        .navbar {
            background-color: #4b7049;
            padding: 10px 20px;
        }

        .navbar-nav {
            margin-left: auto;
            margin-right: auto;
            text-align: center;
        }

        .nav-item {
            margin-left: 15px;
            margin-right: 15px;
        }

        .nav-item a {
            color: #ffffff;
            text-decoration: none;
            padding: 8px 16px;
            font-size: 1rem;
            transition: background-color 0.3s;
        }

        .nav-item a:hover {
            background-color: #3e5940;
            border-radius: 5px;
        }

        /* Ajuste para dispositivos móveis */
        @media (max-width: 992px) {
            .navbar-collapse {
                text-align: center;
            }

            .nav-item {
                margin-bottom: 10px;
            }

            .navbar-collapse.show {
                display: block !important;
            }
        }

        /* Estilos para o botão personalizado */
        .btn-custom {
            background-color: #a9c8a7;
            border-color: #a9c8a7;
            color: #ffffff;
            padding: 10px 20px;
            border-radius: 5px;
            transition: background-color 0.3s, box-shadow 0.3s;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
            margin-bottom: 10px;
        }

        .btn-custom:hover {
            background-color: #8fb98c;
            border-color: #8fb98c;
            box-shadow: 0 6px 8px rgba(0, 0, 0, 0.15);
        }

        /* Links */
        a {
            color: #4b7049;
            text-decoration: none;
            transition: color 0.3s;
        }

        a:hover {
            color: #8fb98c;
            text-decoration: underline;
        }

        /* Títulos */
        h1, h2, h3, h4, h5, h6 {
            color: #4b7049;
            margin-bottom: 20px;
        }

        /* Texto geral */
        p {
            line-height: 1.6;
            margin-bottom: 15px;
        }

        /* Ajustar o tamanho do iframe para ocupar a altura disponível */
        .iframe-container {
            width: 100%;
            height: calc(100vh - 80px);
            justify-content: center;
            align-items: center;
        }

        /* Esconder os iframes secundários por padrão */
        .iframe-secondary {
            display: none;
        }

        /* Mostrar o iframe selecionado */
        .iframe-container.active {
            display: flex;
        }

        iframe {
            width: 100%;
            height: 100%;
            border: none;
        }

        /* Rodapé */
        footer {
            background-color: #4b7049;
            color: #ffffff;
            text-align: center;
            padding: 20px 0;
            position: absolute;
            bottom: 0;
            width: 100%;
        }

        footer a {
            color: #a9c8a7;
        }

        footer a:hover {
            color: #8fb98c;
        }
    </style>
</head>
<body>
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
</html>

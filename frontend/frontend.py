# Frontend (Flask App) - app_frontend.py
import requests
import datetime
import folium
from flask import Flask, render_template
from folium.plugins import HeatMap



# Configuração do Flask
app = Flask(__name__)

# Configurações do backend
BACKEND_URL = "http://backend:5000/data"

@app.route('/')
def home():
    return render_template('index.html')

@app.route('/map')
def map_view():
    # Criar um mapa centrado no Brasil
    folium_map = folium.Map(location=[-15.7801, -47.9292], zoom_start=4)

    # Obter dados do backend
    response = requests.get(BACKEND_URL)
    data = response.json()
    heat_data = []

    for item in data:
        year = datetime.datetime.fromisoformat(item['timestamp']).year
        color_weight = 0
        if year >= 2020:
            color_weight = 0.8  # Vermelho - Desmatamento recente
        elif 2010 <= year < 2020:
            color_weight = 0.6  # Laranja - Desmatamento intermediário
        elif 2000 <= year < 2010:
            color_weight = 0.4  # Amarelo - Desmatamento antigo
        else:
            color_weight = 0.2  # Verde - Área não desmatada

        heat_data.append([item['lat'], item['lon'], color_weight])

    # Adicionar camada de mapa de calor com parâmetros ajustados
    HeatMap(
        heat_data,
        min_opacity=0.3,    # Aumentar a opacidade mínima para tornar mais visível
        max_zoom=10,        # Reduzir o zoom máximo para renderização detalhada
        radius=15,          # Reduzir o raio para menos sobreposição
        blur=50,            # Aumentar o desfoque para suavizar as transições
        max_intensity=0.8   # Reduzir a intensidade máxima para evitar saturação
    ).add_to(folium_map)

    # Renderizar o mapa como HTML
    return folium_map._repr_html_()

if __name__ == "__main__":
    # Rodar o aplicativo Flask
    app.run(host='0.0.0.0', port=5001)


import xml.etree.ElementTree as ET
import pymongo
import datetime
import rasterio
from flask import Flask, render_template
from flask_pymongo import PyMongo
from multiprocessing import Process, cpu_count
import folium
from folium.plugins import HeatMap

# Configuração do Flask
app = Flask(__name__)
app.config["MONGO_URI"] = "mongodb://root:example@mongo:27017/terrabrasilis_data"
mongo = PyMongo(app)

# Função para ler o arquivo QML e extrair a legenda
def parse_qml(file_path):
    tree = ET.parse(file_path)
    root = tree.getroot()
    color_legend = {}
    
    for entry in root.findall(".//paletteEntry"):
        value = entry.get('value')
        color = entry.get('color')
        label = entry.get('label')
        if value and color and label:
            color_legend[int(value)] = {
                'color': color,
                'label': label,
            }
    
    return color_legend

# Função para ler o arquivo TIF e extrair coordenadas
def parse_tif(file_path):
    coordinates = []
    with rasterio.open(file_path) as dataset:
        band1 = dataset.read(1)  # Lê o primeiro canal
        rows, cols = band1.shape

        for row in range(0, rows, 50):  # Reduzir o salto para aumentar o nível de detalhe
            for col in range(0, cols, 50):  # Reduzir o salto para aumentar o nível de detalhe
                value = band1[row, col]
                if value != dataset.nodata:  # Verifica se o valor não é um valor nulo
                    # Converter a posição do pixel para coordenadas geográficas
                    lon, lat = dataset.xy(row, col)
                    coordinates.append({
                        "value": value,
                        "lat": lat,
                        "lon": lon
                    })

    return coordinates

def process_coordinate_batch(args):
    coordinates_batch, color_legend = args
    batch_size = 1000  # Ajuste o tamanho do lote conforme necessário
    batch_data = []
    total_inserted = 0
    total_duplicates = 0

    for coord in coordinates_batch:
        value = coord['value']
        if value in color_legend:
            label = color_legend[value]['label']
            # Extrai o ano do label
            match = re.search(r'(\d{4})', label)
            if match:
                year = int(match.group(1))
            else:
                year = None  # Ano desconhecido
            data = {
               
            }

            batch_data.append(data)

            if len(batch_data) >= batch_size:
                try:
                    result = mongo.db.deforestation_data.insert_many(batch_data, ordered=False)
                    total_inserted += len(result.inserted_ids)
                    print(f"{total_inserted} documentos inseridos no MongoDB.")
                except pymongo.errors.BulkWriteError as e:
                    # Conta o número de erros de chaves duplicadas
                    write_errors = e.details.get('writeErrors', [])
                    total_duplicates += len(write_errors)
                    total_inserted += len(batch_data) - len(write_errors)
                    print(f"{total_inserted} documentos inseridos, {total_duplicates} duplicatas ignoradas.")
                batch_data = []  # Reinicia o batch_data

    # Insere quaisquer dados restantes
    if batch_data:
        try:
            result = mongo.db.deforestation_data.insert_many(batch_data, ordered=False)
            total_inserted += len(result.inserted_ids)
            print(f"{total_inserted} documentos inseridos no MongoDB.")
        except pymongo.errors.BulkWriteError as e:
            write_errors = e.details.get('writeErrors', [])
            total_duplicates += len(write_errors)
            total_inserted += len(batch_data) - len(write_errors)
            print(f"{total_inserted} documentos inseridos, {total_duplicates} duplicatas ignoradas.")

    print(f"Processamento concluído: {total_inserted} inserções, {total_duplicates} duplicatas.")

# Função para dividir o trabalho entre múltiplos processos
def insert_data_to_mongo_parallel(color_legend, coordinates):
    num_processes = max(1, cpu_count() // 2  +  cpu_count() // 3)
    chunk_size = len(coordinates) // num_processes
    coordinate_batches = [coordinates[i * chunk_size: (i + 1) * chunk_size] for i in range(num_processes)]

    with Pool(processes=num_processes) as pool:
        pool.map(process_coordinate_batch, [(batch, color_legend) for batch in coordinate_batches])

# Rotas simples
@app.route('/')
def home():
    return render_template('index.html')

@app.route('/about')
def about():
    return render_template('about.html')

@app.route('/dashboard')
def dashboard():
    data = mongo.db.deforestation_data.find()
    return render_template('dashboard.html', data=data)

@app.route('/map')
def map_view():
    # Criar um mapa centrado no Brasil
    folium_map = folium.Map(location=[-15.7801, -47.9292], zoom_start=4)

    # Obter dados do MongoDB
    data = mongo.db.deforestation_data.find()
    heat_data = []

    for item in data:
        if 'lat' in item and 'lon' in item and 'timestamp' in item:
            year = item['timestamp'].year
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
    # Ler legenda do arquivo QML
    color_legend = parse_qml("prodes_brasil_2023.qml")

    # Ler coordenadas do arquivo TIF
    coordinates = parse_tif("prodes_brasil_2023.tif")

    # Inserir dados da base QML e TIF no MongoDB em paralelo
    insert_data_to_mongo_parallel(color_legend, coordinates)
    
    # Rodar o aplicativo Flask
    app.run(host='0.0.0.0', port=5000)
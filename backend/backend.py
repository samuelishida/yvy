# Backend (Flask API) - app_backend.py
import xml.etree.ElementTree as ET
import pymongo
import datetime
import rasterio
from flask import Flask, jsonify
from flask_pymongo import PyMongo
from multiprocessing import Process, cpu_count

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

# Função para processar cada coordenada e verificar/inserir no MongoDB
def process_coordinate_batch(coordinates_batch, color_legend):
    batch_data = []
    for coord in coordinates_batch:
        value = coord['value']
        if value in color_legend:
            query = {
                "name": color_legend[value]['label'],
                "lat": coord['lat'],
                "lon": coord['lon']
            }
            if mongo.db.deforestation_data.find_one(query) is None:
                data = {
                    "name": color_legend[value]['label'],
                    "clazz": "Desmatamento",
                    "periods": "N/A",
                    "source": "TerraBrasilis",
                    "color": color_legend[value]['color'],
                    "lat": coord['lat'],
                    "lon": coord['lon'],
                    "timestamp": datetime.datetime.now()
                }
                batch_data.append(data)

    if batch_data:
        mongo.db.deforestation_data.insert_many(batch_data)
        print(f"{len(batch_data)} documents inserted into MongoDB.")

# Função para dividir o trabalho entre múltiplos processos
def insert_data_to_mongo_parallel(color_legend, coordinates):
    num_processes = cpu_count()
    chunk_size = len(coordinates) // num_processes
    processes = []

    for i in range(num_processes):
        start = i * chunk_size
        end = None if i == num_processes - 1 else (i + 1) * chunk_size
        coordinates_batch = coordinates[start:end]
        p = Process(target=process_coordinate_batch, args=(coordinates_batch, color_legend))
        processes.append(p)
        p.start()

    for p in processes:
        p.join()

# Rotas simples
@app.route('/')
def home():
    return jsonify({"message": "API do backend de desmatamento"})

@app.route('/data')
def get_data():
    data = mongo.db.deforestation_data.find()
    return jsonify([{
        "name": item["name"],
        "lat": item["lat"],
        "lon": item["lon"],
        "timestamp": item["timestamp"].isoformat()
    } for item in data])

if __name__ == "__main__":
    # Ler legenda do arquivo QML
    color_legend = parse_qml("prodes_brasil_2023.qml")

    # Ler coordenadas do arquivo TIF
    coordinates = parse_tif("prodes_brasil_2023.tif")

    # Inserir dados da base QML e TIF no MongoDB em paralelo
    insert_data_to_mongo_parallel(color_legend, coordinates)
    
    # Rodar o aplicativo Flask
    app.run(host='0.0.0.0', port=5000)

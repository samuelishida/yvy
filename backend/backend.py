# Backend (Flask API) - app_backend.py
import xml.etree.ElementTree as ET
import requests
import datetime
import rasterio
import pymongo
import zipfile
import os
from flask import Flask, jsonify, request, abort
from flask_pymongo import PyMongo
from multiprocessing import Pool, cpu_count
from flask_cors import CORS


# Configuração do Flask
app = Flask(__name__)
CORS(app)
app.config["MONGO_URI"] = "mongodb://root:example@mongo:27017/terrabrasilis_data"
mongo = PyMongo(app)


# Função para baixar e extrair a base de dados do TerraBrasilis, se não estiver presente
def download_and_extract_data():
    tif_file_path = "/app/prodes_brasil_2023.tif"
    qml_file_path = "/app/prodes_brasil_2023.qml"
    zip_file_url = "https://terrabrasilis.dpi.inpe.br/download/dataset/brasil-prodes/raster/prodes_brasil_2023.zip"
    zip_file_path = "/app/prodes_brasil_2023.zip"

    # Verifica se os arquivos TIF e QML já estão presentes
    if not (os.path.isfile(tif_file_path) and os.path.isfile(qml_file_path)):
        print(f"Arquivos {tif_file_path} e {qml_file_path} não encontrados. Baixando e extraindo...")
        # Fazer o download do arquivo ZIP
        response = requests.get(zip_file_url, stream=True)
        if response.status_code == 200:
            with open(zip_file_path, "wb") as zip_file:
                for chunk in response.iter_content(chunk_size=1024):
                    zip_file.write(chunk)

            # Extrair o arquivo ZIP
            with zipfile.ZipFile(zip_file_path, "r") as zip_ref:
                zip_ref.extractall("/app")

            # Remover o arquivo ZIP
            os.remove(zip_file_path)
            print(f"Arquivos {tif_file_path} e {qml_file_path} baixados e extraídos com sucesso.")
        else:
            print(f"Falha ao baixar o arquivo. Status code: {response.status_code}")
    else:
        print(f"Arquivos {tif_file_path} e {qml_file_path} já estão presentes.")

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
def process_coordinate_batch(args):
    coordinates_batch, color_legend = args
    batch_data = []
    for coord in coordinates_batch:
        value = coord['value']
        if value in color_legend:
            data = {
                "name": color_legend[value]['label'],
                "clazz": "Desmatamento",
                "periods": "N/A",
                "source": "TerraBrasilis",
                "color": color_legend[value]['color'],  # Inclui a cor diretamente do color_legend
                "lat": coord['lat'],
                "lon": coord['lon'],
                "timestamp": datetime.datetime.now()
            }
            batch_data.append(data)

    if batch_data:
        operations = []
        for data in batch_data:
            operations.append(
                pymongo.UpdateOne(
                    {"name": data["name"], "lat": data["lat"], "lon": data["lon"]},
                    {"$setOnInsert": data},
                    upsert=True
                )
            )
        if operations:
            mongo.db.deforestation_data.bulk_write(operations, ordered=False)
        print(f"{len(batch_data)} documents processed and upserted into MongoDB.")


# Função para dividir o trabalho entre múltiplos processos
def insert_data_to_mongo_parallel(color_legend, coordinates):
    num_processes = max(1, cpu_count() // 2 + 2)
    chunk_size = len(coordinates) // num_processes
    coordinate_batches = [coordinates[i * chunk_size: (i + 1) * chunk_size] for i in range(num_processes)]
    
    with Pool(processes=num_processes) as pool:
        pool.map(process_coordinate_batch, [(batch, color_legend) for batch in coordinate_batches])

# Rotas simples
@app.route('/')
def home():
    return jsonify({"message": "API do backend de desmatamento"})

@app.route('/data')
def get_data():
    try:
        ne_lat = float(request.args.get('ne_lat', None))
        ne_lng = float(request.args.get('ne_lng', None))
        sw_lat = float(request.args.get('sw_lat', None))
        sw_lng = float(request.args.get('sw_lng', None))
    except (TypeError, ValueError):
        return abort(400, description="Invalid or missing query parameters. Please provide valid 'ne_lat', 'ne_lng', 'sw_lat', and 'sw_lng'.")

    query = {
        "lat": {"$lte": ne_lat, "$gte": sw_lat},
        "lon": {"$lte": ne_lng, "$gte": sw_lng}
    }

    data = mongo.db.deforestation_data.find(query).limit(1000)  # Limit to 1000 items per request
    return jsonify([{
        "name": item["name"],
        "lat": item["lat"],
        "lon": item["lon"],
        "color": item["color"],
        "timestamp": item["timestamp"].isoformat()
    } for item in data])


if __name__ == "__main__":
    # Baixar e extrair os arquivos TIF e QML, se necessário
    download_and_extract_data()

    # Ler legenda do arquivo QML
    color_legend = parse_qml("/app/prodes_brasil_2023.qml")

    # Ler coordenadas do arquivo TIF
    coordinates = parse_tif("/app/prodes_brasil_2023.tif")

    # Verificar se o MongoDB já possui dados inseridos
    existing_count = mongo.db.deforestation_data.count_documents({})
    if existing_count == 0:
        # Inserir dados da base QML e TIF no MongoDB em paralelo
        insert_data_to_mongo_parallel(color_legend, coordinates)
    else:
        print(f"MongoDB já contém {existing_count} documentos. Nenhuma inserção adicional necessária.")
    
    # Rodar o aplicativo Flask
    app.run(host='0.0.0.0', port=5000)
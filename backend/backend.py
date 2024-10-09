# Backend (Flask API) - app_backend.py
import xml.etree.ElementTree as ET
import requests
import datetime
import rasterio
import pymongo
import zipfile
import os
import re
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

        for row in range(0, rows, 50):  # Ajuste o passo conforme necessário
            for col in range(0, cols, 50):
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
                "name": label,
                "clazz": "Desmatamento",
                "periods": year,
                "source": "TerraBrasilis",
                "color": color_legend[value]['color'],
                "lat": coord['lat'],
                "lon": coord['lon'],
                "timestamp": datetime.datetime.now()
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

# Rota principal
@app.route('/')
def home():
    return jsonify({"message": "API do backend de desmatamento"})

# Rota para obter os dados
@app.route('/data')
def get_data():
    # Recupera os parâmetros de consulta, se houver
    ne_lat = request.args.get('ne_lat', None)
    ne_lng = request.args.get('ne_lng', None)
    sw_lat = request.args.get('sw_lat', None)
    sw_lng = request.args.get('sw_lng', None)

    query = {}

    if ne_lat and ne_lng and sw_lat and sw_lng:
        try:
            ne_lat = float(ne_lat)
            ne_lng = float(ne_lng)
            sw_lat = float(sw_lat)
            sw_lng = float(sw_lng)
            # Cria a query para filtrar os dados com base nos parâmetros fornecidos
            query = {
                "lat": {"$lte": ne_lat, "$gte": sw_lat},
                "lon": {"$lte": ne_lng, "$gte": sw_lng}
            }
        except (TypeError, ValueError):
            return abort(400, description="Parâmetros de consulta inválidos. Forneça 'ne_lat', 'ne_lng', 'sw_lat' e 'sw_lng' válidos.")

    # Consulta o MongoDB
    data_cursor = mongo.db.deforestation_data.find(query)
    data_records = list(data_cursor)

    # Converte os dados para o formato adequado para JSON
    return jsonify([{
        "name": item.get("name"),
        "lat": item.get("lat"),
        "lon": item.get("lon"),
        "color": item.get("color"),
        "timestamp": item.get("timestamp").isoformat() if item.get("timestamp") else None,
        "periods": item.get("periods"),
        "source": item.get("source")
    } for item in data_records])

if __name__ == "__main__":
    # Baixar e extrair os arquivos TIF e QML, se necessário
    download_and_extract_data()

    # mongo.db.deforestation_data.drop_index('name_lat_lon_index')

    # Criar o índice composto antes de inserir os dados
    print("Criando índice nos campos 'name', 'lat' e 'lon'...")
    mongo.db.deforestation_data.create_index(
        [("name", pymongo.ASCENDING), ("lat", pymongo.ASCENDING), ("lon", pymongo.ASCENDING)],
        name="name_lat_lon_index",
        unique=True
    )
    print("Índice criado com sucesso.")

    # Ler legenda do arquivo QML
    color_legend = parse_qml("/app/prodes_brasil_2023.qml")

    # Ler coordenadas do arquivo TIF
    coordinates = parse_tif("/app/prodes_brasil_2023.tif")

    # Inserir dados no MongoDB em paralelo
    insert_data_to_mongo_parallel(color_legend, coordinates)

    # Rodar o aplicativo Flask
    app.run(host='0.0.0.0', port=5000)

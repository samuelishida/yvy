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
app.config["MONGO_URI"] = "mongodb://root:example@mongo:27017/yvy_data"
mongo = PyMongo(app)


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

# Rota principal
@app.route('/')
def home():
    return jsonify({"message": "API do backend"})


if __name__ == "__main__":

    # Inserir dados no MongoDB em paralelo
    # insert_data_to_mongo_parallel(color_legend, coordinates)

    # Rodar o aplicativo Flask
    app.run(host='0.0.0.0', port=5000)
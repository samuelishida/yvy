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




# Rota principal
@app.route('/')
def home():
    return jsonify({"message": "API do backend"})


if __name__ == "__main__":

    # Inserir dados no MongoDB em paralelo
    # insert_data_to_mongo_parallel(color_legend, coordinates)

    # Rodar o aplicativo Flask
    app.run(host='0.0.0.0', port=5000)
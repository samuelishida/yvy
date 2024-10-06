import xml.etree.ElementTree as ET
import pymongo
import datetime
from flask import Flask, render_template
from flask_pymongo import PyMongo

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
            # Adicionando coordenadas fictícias para visualização (para demonstrar)
            color_legend[int(value)] = {
                'color': color,
                'label': label,
                'lat': -15.7801 + (int(value) % 5) * 0.5,  # Latitude fictícia
                'lon': -47.9292 + (int(value) % 5) * 0.5   # Longitude fictícia
            }
    
    return color_legend

# Inserir dados da base QML no MongoDB
def insert_qml_data_to_mongo(color_legend):
    for value, info in color_legend.items():
        data = {
            "name": info['label'],
            "clazz": "Desmatamento",
            "periods": "N/A",
            "source": "TerraBrasilis",
            "color": info['color'],
            "lat": info['lat'],
            "lon": info['lon'],
            "timestamp": datetime.datetime.now()
        }
        mongo.db.deforestation_data.insert_one(data)
    print("Data from QML inserted into MongoDB.")

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
    # Converter ObjectId para string para evitar problemas de serialização
    data = mongo.db.deforestation_data.find()
    data_list = []
    for item in data:
        item['_id'] = str(item['_id'])
        data_list.append(item)
    return render_template('map.html', data=data_list)

if __name__ == "__main__":
    # Ler legenda do arquivo QML
    color_legend = parse_qml("prodes_brasil_2023.qml")

    # Inserir dados da base QML no MongoDB
    insert_qml_data_to_mongo(color_legend)
    
    # Rodar o aplicativo Flask
    app.run(host='0.0.0.0', port=5000)

import requests
import datetime
import folium
from flask import Flask, render_template

# Configuração do Flask
app = Flask(__name__)

# Configurações do backend
BACKEND_URL = "http://backend:5000/data"

@app.route('/')
def home():
    return render_template('index.html')

@app.route('/map')
def map_view():
    
    # Embed TerraBrasilis map using iframe
    iframe = "<iframe src='https://terrabrasilis.dpi.inpe.br/app/map/deforestation?hl=en' width='100%' height='600' style='border:none;'></iframe>"

    # Create the folium map for overlaying additional data
    
    map_html = iframe
    return render_template('map.html', iframe=iframe, map_html=map_html)

if __name__ == "__main__":
    # Run the Flask app
    app.run(host='0.0.0.0', port=5001)
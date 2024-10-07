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
    # Example coordinates centered around Brasília, Brazil
    ne_lat = -15.0  # Northeast latitude
    ne_lng = -47.0  # Northeast longitude
    sw_lat = -16.0  # Southwest latitude
    sw_lng = -48.0  # Southwest longitude

    # Create the map centered on Brasília, Brazil
    folium_map = folium.Map(location=[-15.7801, -47.9292], zoom_start=4)

    # Fetch data from the backend
    url = f"{BACKEND_URL}?ne_lat={ne_lat}&ne_lng={ne_lng}&sw_lat={sw_lat}&sw_lng={sw_lng}"
    
    try:
        response = requests.get(url)
        if response.status_code == 200:
            data = response.json()
        else:
            print(f"Error: Received {response.status_code} from backend")
            data = []
    except requests.exceptions.RequestException as e:
        print(f"Error: Could not connect to backend. Details: {e}")
        data = []

    # Add circle markers to the map
    for item in data:
        year = datetime.datetime.fromisoformat(item['timestamp']).year

        # Determine the color based on the year
        color = ''
        if year >= 2020:
            color = 'orange'  # Transparent orange for recent data
        elif 2010 <= year < 2020:
            color = 'yellow'
        elif 2000 <= year < 2010:
            color = 'green'
        else:
            color = 'darkgreen'

        folium.CircleMarker(
            location=(item['lat'], item['lon']),
            radius=7,
            color=color,
            fill=True,
            fill_color=color,
            fill_opacity=0.6
        ).add_to(folium_map)

    # Render the map as HTML
    map_html = folium_map._repr_html_()
    return render_template('map.html', map_html=map_html)


if __name__ == "__main__":
    # Rodar o aplicativo Flask
    app.run(host='0.0.0.0', port=5001)


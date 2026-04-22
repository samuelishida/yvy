import datetime
import logging
import os

import requests


logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO").upper())
logger = logging.getLogger("yvy.integrations")


def insert_data_to_mongo(data, source):
    logger.info("Fetched data from %s at %s", source, datetime.datetime.now(datetime.UTC).isoformat())
    logger.debug("Payload from %s: %s", source, data)


def get_openweathermap_data(api_key, city):
    url = f"https://api.openweathermap.org/data/2.5/weather?q={city}&appid={api_key}"
    response = requests.get(url, timeout=30)
    if response.status_code == 200:
        insert_data_to_mongo(response.json(), "OpenWeatherMap")
    else:
        logger.error("Failed to fetch OpenWeatherMap data: %s", response.status_code)


def get_waqi_data(api_key, city):
    url = f"https://api.waqi.info/feed/{city}/?token={api_key}"
    response = requests.get(url, timeout=30)
    if response.status_code == 200:
        insert_data_to_mongo(response.json(), "WAQI")
    else:
        logger.error("Failed to fetch WAQI data: %s", response.status_code)


def get_nasa_earthdata_data(api_key, start_date, end_date, lon, lat):
    url = (
        "https://api.nasa.gov/planetary/earth/assets"
        f"?lon={lon}&lat={lat}&begin={start_date}&end={end_date}&api_key={api_key}"
    )
    response = requests.get(url, timeout=30)
    if response.status_code == 200:
        insert_data_to_mongo(response.json(), "NASA EarthData")
    else:
        logger.error("Failed to fetch NASA EarthData: %s", response.status_code)


def create_geostore(geojson, api_key):
    url = "https://data-api.globalforestwatch.org/geostore"
    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key,
    }
    payload = {"geometry": geojson}
    response = requests.post(url, headers=headers, json=payload, timeout=30)
    data = response.json()
    if response.status_code in [200, 201]:
        geostore_id = data.get("data", {}).get("gfw_geostore_id")
        if geostore_id:
            logger.info("Geostore created successfully.")
            return geostore_id

        logger.error("The gfw_geostore_id key was not found in the response.")
        return None

    logger.error("Failed to create geostore: %s - %s", response.status_code, response.text)
    return None


def get_iqair_data(api_key, city, state, country):
    url = f"https://api.airvisual.com/v2/city?city={city}&state={state}&country={country}&key={api_key}"
    response = requests.get(url, timeout=30)
    if response.status_code == 200:
        insert_data_to_mongo(response.json(), "IQAir AirVisual")
    else:
        logger.error("Failed to fetch IQAir data: %s", response.status_code)


def get_global_forest_watch_data(api_key, geometry):
    geostore_id = create_geostore(geometry, api_key)
    if not geostore_id:
        logger.error("Failed to create geostore. Skipping data fetch.")
        return

    dataset_name = "umd_tree_cover_loss"
    dataset_version = "v1.8"
    url = f"https://data-api.globalforestwatch.org/dataset/{dataset_name}/{dataset_version}/statistics"
    headers = {
        "x-api-key": api_key,
        "Content-Type": "application/json",
    }
    payload = {"geostore_id": geostore_id}

    try:
        response = requests.post(url, headers=headers, json=payload, timeout=30)
        response.raise_for_status()
        insert_data_to_mongo(response.json(), "Global Forest Watch")
        logger.info("Global Forest Watch data fetched successfully.")
    except requests.exceptions.RequestException as error:
        logger.error("Failed to fetch Global Forest Watch data: %s", error)


def list_gfw_datasets(api_key):
    url = "https://data-api.globalforestwatch.org/datasets"
    headers = {"x-api-key": api_key}

    try:
        response = requests.get(url, headers=headers, timeout=30)
        response.raise_for_status()
        datasets = response.json().get("data", [])
        for dataset in datasets:
            dataset_id = dataset.get("id")
            attributes = dataset.get("attributes", {})
            title = attributes.get("title", "No Title")
            description = attributes.get("description", "No Description")
            versions = attributes.get("versions", [])
            logger.info("Dataset %s (%s): %s | versions=%s", title, dataset_id, description, versions)
    except requests.exceptions.RequestException as error:
        logger.error("Failed to list datasets: %s", error)


def require_env(name):
    value = os.getenv(name, "").strip()
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def consolidate_data():
    openweathermap_api_key = require_env("OPENWEATHERMAP_API_KEY")
    global_forest_watch_api_key = require_env("GFW_API_KEY")

    waqi_api_key = os.getenv("WAQI_API_KEY", "").strip()
    nasa_api_key = os.getenv("NASA_API_KEY", "").strip()
    iqair_api_key = os.getenv("IQAIR_API_KEY", "").strip()

    city = os.getenv("CITY", "Sao Paulo")
    state = os.getenv("STATE", "Sao Paulo")
    country = os.getenv("COUNTRY", "Brazil")
    start_date = os.getenv("START_DATE", "2022-01-01")
    end_date = os.getenv("END_DATE", "2022-12-31")
    lon = float(os.getenv("LON", "-46.6333"))
    lat = float(os.getenv("LAT", "-23.5505"))

    sao_paulo_geojson = {
        "type": "Polygon",
        "coordinates": [
            [
                [-46.8261, -24.0087],
                [-46.3652, -24.0087],
                [-46.3652, -23.3567],
                [-46.8261, -23.3567],
                [-46.8261, -24.0087],
            ]
        ],
    }

    get_openweathermap_data(openweathermap_api_key, city)
    list_gfw_datasets(global_forest_watch_api_key)
    get_global_forest_watch_data(global_forest_watch_api_key, sao_paulo_geojson)

    if waqi_api_key:
        get_waqi_data(waqi_api_key, city)
    if nasa_api_key:
        get_nasa_earthdata_data(nasa_api_key, start_date, end_date, lon, lat)
    if iqair_api_key:
        get_iqair_data(iqair_api_key, city, state, country)


if __name__ == "__main__":
    consolidate_data()

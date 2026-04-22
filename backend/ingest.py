import datetime
import logging
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from multiprocessing import cpu_count
from urllib.parse import quote_plus
from xml.etree import ElementTree as ET
import zipfile

import httpx
from dotenv import load_dotenv
from pymongo import MongoClient, UpdateOne

load_dotenv()

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO").upper())
logger = logging.getLogger("yvy.ingest")


def build_mongo_uri():
    explicit_uri = os.getenv("MONGO_URI", "").strip()
    if explicit_uri:
        return explicit_uri

    database = os.getenv("MONGO_DATABASE", "terrabrasilis_data")
    host = os.getenv("MONGO_HOST", "mongo")
    port = os.getenv("MONGO_PORT", "27017")
    app_username = os.getenv("MONGO_APP_USERNAME", "").strip()
    app_password = os.getenv("MONGO_APP_PASSWORD", "").strip()
    root_username = os.getenv("MONGO_ROOT_USERNAME", "").strip()
    root_password = os.getenv("MONGO_ROOT_PASSWORD", "").strip()

    if app_username and app_password:
        return (
            f"mongodb://{quote_plus(app_username)}:{quote_plus(app_password)}"
            f"@{host}:{port}/{database}?authSource={database}"
        )

    if root_username and root_password:
        return (
            f"mongodb://{quote_plus(root_username)}:{quote_plus(root_password)}"
            f"@{host}:{port}/{database}?authSource=admin"
        )

    return f"mongodb://{host}:{port}/{database}"


def download_and_extract_data():
    tif_file_path = "/app/prodes_brasil_2023.tif"
    qml_file_path = "/app/prodes_brasil_2023.qml"
    zip_file_url = "https://terrabrasilis.dpi.inpe.br/download/dataset/brasil-prodes/raster/prodes_brasil_2023.zip"
    zip_file_path = "/app/prodes_brasil_2023.zip"

    if not (os.path.isfile(tif_file_path) and os.path.isfile(qml_file_path)):
        logger.info("Dataset files not found. Downloading archive.")
        with httpx.Client(timeout=120) as client:
            with client.stream("GET", zip_file_url) as resp:
                if resp.status_code == 200:
                    with open(zip_file_path, "wb") as zip_file:
                        for chunk in resp.iter_bytes(chunk_size=1024):
                            zip_file.write(chunk)
                    with zipfile.ZipFile(zip_file_path, "r") as zip_ref:
                        zip_ref.extractall("/app")
                    os.remove(zip_file_path)
                    logger.info("Dataset archive downloaded successfully.")
                else:
                    logger.error("Failed to download dataset archive. Status: %s", resp.status_code)
    else:
        logger.info("Dataset files already available locally.")


def parse_qml(file_path):
    tree = ET.parse(file_path)
    root = tree.getroot()
    color_legend = {}

    for entry in root.findall(".//paletteEntry"):
        value = entry.get("value")
        color = entry.get("color")
        label = entry.get("label")
        if value and color and label:
            color_legend[int(value)] = {
                "color": color,
                "label": label,
            }

    return color_legend


def parse_tif(file_path):
    import rasterio

    coordinates = []
    with rasterio.open(file_path) as dataset:
        band1 = dataset.read(1)
        rows, cols = band1.shape

        for row in range(0, rows, 50):
            for col in range(0, cols, 50):
                value = band1[row, col]
                if value != dataset.nodata:
                    lon, lat = dataset.xy(row, col)
                    coordinates.append({
                        "value": value,
                        "lat": lat,
                        "lon": lon,
                    })

    return coordinates


def process_coordinate_batch(args):
    coordinates_batch, color_legend, mongo_uri, mongo_database = args
    client = MongoClient(mongo_uri)
    db = client[mongo_database]
    batch_data = []
    for coord in coordinates_batch:
        value = coord["value"]
        if value in color_legend:
            data = {
                "name": color_legend[value]["label"],
                "clazz": "Desmatamento",
                "periods": "N/A",
                "source": "TerraBrasilis",
                "color": color_legend[value]["color"],
                "lat": coord["lat"],
                "lon": coord["lon"],
                "timestamp": datetime.datetime.now(datetime.UTC),
            }
            batch_data.append(data)

    if batch_data:
        operations = [
            UpdateOne(
                {"name": d["name"], "lat": d["lat"], "lon": d["lon"]},
                {"$setOnInsert": d},
                upsert=True,
            )
            for d in batch_data
        ]
        if operations:
            db.deforestation_data.bulk_write(operations, ordered=False)
        logger.info("Batch documents upserted: %d", len(batch_data))
    client.close()


def split_into_batches(items, batch_count):
    if not items:
        return []
    batch_count = max(1, min(batch_count, len(items)))
    chunk_size = (len(items) + batch_count - 1) // batch_count
    return [items[i:i + chunk_size] for i in range(0, len(items), chunk_size)]


def insert_data_to_mongo_parallel(color_legend, coordinates):
    num_processes = max(1, cpu_count() // 2 + 2)
    coordinate_batches = split_into_batches(coordinates, num_processes)
    if not coordinate_batches:
        logger.info("Skipping ingestion: no coordinates to process.")
        return

    mongo_uri = build_mongo_uri()
    mongo_database = os.getenv("MONGO_DATABASE", "terrabrasilis_data")
    with ThreadPoolExecutor(max_workers=len(coordinate_batches)) as executor:
        list(executor.map(process_coordinate_batch, [(batch, color_legend, mongo_uri, mongo_database) for batch in coordinate_batches]))


def main():
    logger.info("Starting ingestion process.", extra={"event": "ingest_start"})
    download_and_extract_data()
    color_legend = parse_qml("/app/prodes_brasil_2023.qml")
    coordinates = parse_tif("/app/prodes_brasil_2023.tif")

    mongo_uri = build_mongo_uri()
    mongo_database = os.getenv("MONGO_DATABASE", "terrabrasilis_data")
    client = MongoClient(mongo_uri)
    db = client[mongo_database]
    existing_count = db.deforestation_data.count_documents({})
    client.close()

    if existing_count == 0:
        insert_data_to_mongo_parallel(color_legend, coordinates)
        logger.info("Ingestion completed.", extra={"event": "ingest_complete"})
    else:
        logger.info(
            "MongoDB already contains documents. No ingestion necessary.",
            extra={"event": "ingest_skipped", "details": {"documents": existing_count}},
        )


if __name__ == "__main__":
    main()
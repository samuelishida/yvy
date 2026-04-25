"""Ingest TerraBrasilis data into SQLite (replaces MongoDB ingest)."""
import asyncio
import datetime
import logging
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from multiprocessing import cpu_count
from xml.etree import ElementTree as ET
import zipfile

import httpx
from dotenv import load_dotenv

import db_sqlite

load_dotenv()

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO").upper())
logger = logging.getLogger("yvy.ingest")


def download_and_extract_data():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    tif_file_path = os.path.join(script_dir, "prodes_brasil_2023.tif")
    qml_file_path = os.path.join(script_dir, "prodes_brasil_2023.qml")
    zip_file_url = "https://terrabrasilis.dpi.inpe.br/download/dataset/brasil-prodes/raster/prodes_brasil_2023.zip"
    zip_file_path = os.path.join(script_dir, "prodes_brasil_2023.zip")

    if not (os.path.isfile(tif_file_path) and os.path.isfile(qml_file_path)):
        logger.info("Dataset files not found. Downloading archive.")
        with httpx.Client(timeout=120) as client:
            with client.stream("GET", zip_file_url) as resp:
                if resp.status_code == 200:
                    with open(zip_file_path, "wb") as zip_file:
                        for chunk in resp.iter_bytes(chunk_size=1024):
                            zip_file.write(chunk)
                    with zipfile.ZipFile(zip_file_path, "r") as zip_ref:
                        zip_ref.extractall(script_dir)
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
    coordinates_batch, color_legend = args
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
                "timestamp": datetime.datetime.now(datetime.UTC).isoformat(),
            }
            batch_data.append(data)

    if batch_data:
        asyncio.run(db_sqlite.bulk_upsert_deforestation(batch_data))
        logger.info("Batch documents upserted: %d", len(batch_data))


def split_into_batches(items, batch_count):
    if not items:
        return []
    batch_count = max(1, min(batch_count, len(items)))
    chunk_size = (len(items) + batch_count - 1) // batch_count
    return [items[i:i + chunk_size] for i in range(0, len(items), chunk_size)]


def insert_data_parallel(color_legend, coordinates):
    num_processes = max(1, cpu_count() // 2 + 2)
    coordinate_batches = split_into_batches(coordinates, num_processes)
    if not coordinate_batches:
        logger.info("Skipping ingestion: no coordinates to process.")
        return

    with ThreadPoolExecutor(max_workers=len(coordinate_batches)) as executor:
        list(executor.map(process_coordinate_batch, [(batch, color_legend) for batch in coordinate_batches]))


async def main():
    logger.info("Starting ingestion process.", extra={"event": "ingest_start"})
    await db_sqlite.init_db()
    download_and_extract_data()
    color_legend = parse_qml("prodes_brasil_2023.qml")
    coordinates = parse_tif("prodes_brasil_2023.tif")

    existing_count = (await db_sqlite.get_stats())["deforestation"]
    logger.info("Existing deforestation records: %d", existing_count)

    if existing_count == 0:
        logger.info("Ingesting %d coordinates into SQLite...", len(coordinates))
        insert_data_parallel(color_legend, coordinates)
        final_count = (await db_sqlite.get_stats())["deforestation"]
        logger.info("Ingestion complete. Total records: %d", final_count)
    else:
        logger.info("Data already ingested. Skipping.")


if __name__ == "__main__":
    asyncio.run(main())

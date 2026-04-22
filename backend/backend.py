# Backend (Flask API) - app_backend.py
import datetime
import json
import logging
import os
import sys
import time
import xml.etree.ElementTree as ET
import zipfile
from concurrent.futures import ThreadPoolExecutor
from contextlib import suppress
from collections import defaultdict, deque
from secrets import compare_digest
from threading import Lock
from urllib.parse import quote_plus

import requests
from dotenv import load_dotenv
from flask import Flask, jsonify, request, abort
from flask_pymongo import PyMongo
from multiprocessing import cpu_count
from flask_cors import CORS

# Load .env for local development (ignored in git)
load_dotenv()


BRAZIL_BOUNDS = {
    "min_lat": -34.0,
    "max_lat": 5.5,
    "min_lon": -74.0,
    "max_lon": -34.0,
}
MAX_RESULTS = int(os.getenv("MAX_RESULTS_PER_REQUEST", "1000"))
RATE_LIMIT_REQUESTS = int(os.getenv("RATE_LIMIT_REQUESTS", "60"))
RATE_LIMIT_WINDOW_SECONDS = int(os.getenv("RATE_LIMIT_WINDOW_SECONDS", "60"))
AUTH_REQUIRED = os.getenv("AUTH_REQUIRED", "1") == "1"
API_KEY = os.getenv("API_KEY", "").strip()
_RATE_LIMIT_BUCKETS = defaultdict(deque)
_RATE_LIMIT_LOCK = Lock()


class JsonFormatter(logging.Formatter):
    def format(self, record):
        payload = {
            "timestamp": datetime.datetime.now(datetime.UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        if hasattr(record, "event"):
            payload["event"] = record.event
        if hasattr(record, "path"):
            payload["path"] = record.path
        if hasattr(record, "status_code"):
            payload["status_code"] = record.status_code
        if hasattr(record, "remote_addr"):
            payload["remote_addr"] = record.remote_addr
        if hasattr(record, "details"):
            payload["details"] = record.details
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, ensure_ascii=True)


def configure_logger(name):
    logger = logging.getLogger(name)
    if logger.handlers:
        return logger

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    logger.addHandler(handler)
    logger.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())
    logger.propagate = False
    return logger


logger = configure_logger("yvy.backend")


def build_security_headers():
    return {
        "X-Content-Type-Options": "nosniff",
        "X-Frame-Options": "DENY",
        "Referrer-Policy": "strict-origin-when-cross-origin",
        "Permissions-Policy": "geolocation=(), microphone=(), camera=(), bluetooth=()",
        "Content-Security-Policy": (
            "default-src 'self'; "
            "img-src 'self' data: https://tile.openstreetmap.org https://*.tile.openstreetmap.org; "
            "style-src 'self' 'unsafe-inline' https://stackpath.bootstrapcdn.com https://cdn.jsdelivr.net https://unpkg.com; "
            "script-src 'self' 'unsafe-inline' https://code.jquery.com https://cdn.jsdelivr.net https://unpkg.com; "
            "font-src 'self' https://stackpath.bootstrapcdn.com; "
            "connect-src 'self'; "
            "frame-ancestors 'none'; "
            "base-uri 'self'; "
            "form-action 'self'"
        ),
    }


def parse_cors_origins():
    raw_origins = os.getenv("CORS_ORIGINS", "http://localhost:5001,http://127.0.0.1:5001")
    origins = [origin.strip() for origin in raw_origins.split(",") if origin.strip()]
    return origins or ["http://localhost:5001", "http://127.0.0.1:5001"]


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


def validate_coordinate(name, value, minimum, maximum):
    if not minimum <= value <= maximum:
        abort(400, description=f"{name} must be between {minimum} and {maximum}.")


def clamp_bbox_to_brazil(ne_lat, ne_lng, sw_lat, sw_lng):
    clamped_ne_lat = min(ne_lat, BRAZIL_BOUNDS["max_lat"])
    clamped_ne_lng = min(ne_lng, BRAZIL_BOUNDS["max_lon"])
    clamped_sw_lat = max(sw_lat, BRAZIL_BOUNDS["min_lat"])
    clamped_sw_lng = max(sw_lng, BRAZIL_BOUNDS["min_lon"])

    if clamped_ne_lat <= clamped_sw_lat or clamped_ne_lng <= clamped_sw_lng:
        return None

    return clamped_ne_lat, clamped_ne_lng, clamped_sw_lat, clamped_sw_lng


def split_into_batches(items, batch_count):
    if not items:
        return []

    batch_count = max(1, min(batch_count, len(items)))
    chunk_size = (len(items) + batch_count - 1) // batch_count
    return [items[index:index + chunk_size] for index in range(0, len(items), chunk_size)]


def get_client_ip():
    forwarded_for = request.headers.get("X-Forwarded-For", "")
    if forwarded_for:
        return forwarded_for.split(",")[0].strip()
    return request.remote_addr or "unknown"


def enforce_api_auth():
    if not AUTH_REQUIRED:
        return

    if not API_KEY:
        logger.error(
            "API key authentication is enabled but API_KEY is missing.",
            extra={"event": "api_auth_misconfigured", "path": request.path, "status_code": 503},
        )
        abort(503, description="API authentication is not configured.")

    provided_key = request.headers.get("X-API-Key", "").strip()
    if not provided_key:
        auth_header = request.headers.get("Authorization", "")
        if auth_header.startswith("Bearer "):
            provided_key = auth_header.removeprefix("Bearer ").strip()

    if not provided_key or not compare_digest(provided_key, API_KEY):
        logger.warning(
            "Rejected unauthorized API request.",
            extra={
                "event": "api_auth_failed",
                "path": request.path,
                "status_code": 401,
                "remote_addr": get_client_ip(),
            },
        )
        abort(401, description="A valid API key is required.")


def enforce_rate_limit():
    client_ip = get_client_ip()
    now = time.time()

    with _RATE_LIMIT_LOCK:
        bucket = _RATE_LIMIT_BUCKETS[client_ip]
        while bucket and now - bucket[0] >= RATE_LIMIT_WINDOW_SECONDS:
            bucket.popleft()

        if len(bucket) >= RATE_LIMIT_REQUESTS:
            logger.warning(
                "Rate limit exceeded.",
                extra={
                    "event": "rate_limit_exceeded",
                    "path": request.path,
                    "status_code": 429,
                    "remote_addr": client_ip,
                    "details": {
                        "limit": RATE_LIMIT_REQUESTS,
                        "window_seconds": RATE_LIMIT_WINDOW_SECONDS,
                    },
                },
            )
            abort(429, description="Rate limit exceeded. Please retry later.")

        bucket.append(now)


# Configuração do Flask
app = Flask(__name__)
CORS(app, resources={r"/*": {"origins": parse_cors_origins()}})
app.config["MONGO_URI"] = build_mongo_uri()
mongo = PyMongo(app)


@app.before_request
def start_request_timer():
    request._start_time = time.perf_counter()


@app.after_request
def add_security_headers(response):
    for header_name, header_value in build_security_headers().items():
        response.headers.setdefault(header_name, header_value)

    duration_ms = None
    with suppress(Exception):
        duration_ms = round((time.perf_counter() - request._start_time) * 1000, 2)

    logger.info(
        "Handled backend request.",
        extra={
            "event": "http_request",
            "path": request.path,
            "status_code": response.status_code,
            "remote_addr": get_client_ip(),
            "details": {
                "method": request.method,
                "duration_ms": duration_ms,
            },
        },
    )
    return response


# Endpoint de saúde para health checks
@app.route('/health')
def health():
    return jsonify({"status": "healthy", "timestamp": datetime.datetime.now(datetime.UTC).isoformat()})


# Error handlers
@app.errorhandler(404)
def not_found(error):
    return jsonify({"error": "Not found", "message": str(error)}), 404

@app.errorhandler(400)
def bad_request(error):
    return jsonify({"error": "Bad request", "message": str(error)}), 400

@app.errorhandler(401)
def unauthorized(error):
    return jsonify({"error": "Unauthorized", "message": str(error)}), 401

@app.errorhandler(429)
def rate_limited(error):
    return jsonify({"error": "Too many requests", "message": str(error)}), 429

@app.errorhandler(503)
def service_unavailable(error):
    return jsonify({"error": "Service unavailable", "message": str(error)}), 503

@app.errorhandler(500)
def internal_error(error):
    return jsonify({"error": "Internal server error"}), 500


# Função para baixar e extrair a base de dados do TerraBrasilis, se não estiver presente
def download_and_extract_data():
    tif_file_path = "/app/prodes_brasil_2023.tif"
    qml_file_path = "/app/prodes_brasil_2023.qml"
    zip_file_url = "https://terrabrasilis.dpi.inpe.br/download/dataset/brasil-prodes/raster/prodes_brasil_2023.zip"
    zip_file_path = "/app/prodes_brasil_2023.zip"

    # Verifica se os arquivos TIF e QML já estão presentes
    if not (os.path.isfile(tif_file_path) and os.path.isfile(qml_file_path)):
        logger.info(
            "Dataset files not found. Downloading archive.",
            extra={"event": "dataset_download_start", "details": {"archive_url": zip_file_url}},
        )
        # Fazer o download do arquivo ZIP
        response = requests.get(zip_file_url, stream=True, timeout=120)
        if response.status_code == 200:
            with open(zip_file_path, "wb") as zip_file:
                for chunk in response.iter_content(chunk_size=1024):
                    zip_file.write(chunk)

            # Extrair o arquivo ZIP
            with zipfile.ZipFile(zip_file_path, "r") as zip_ref:
                zip_ref.extractall("/app")

            # Remover o arquivo ZIP
            os.remove(zip_file_path)
            logger.info(
                "Dataset archive downloaded successfully.",
                extra={"event": "dataset_download_complete", "details": {"target_dir": "/app"}},
            )
        else:
            logger.error(
                "Failed to download dataset archive.",
                extra={
                    "event": "dataset_download_failed",
                    "status_code": response.status_code,
                    "details": {"archive_url": zip_file_url},
                },
            )
    else:
        logger.info(
            "Dataset files already available locally.",
            extra={"event": "dataset_already_present", "details": {"target_dir": "/app"}},
        )

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
    # Import rasterio lazily to avoid requiring it during test imports
    coordinates = []
    try:
        import rasterio
    except Exception:
        raise

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
        # Import pymongo lazily to avoid requiring it for tests that mock the DB
        import pymongo
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
        logger.info(
            "Batch documents upserted into MongoDB.",
            extra={"event": "mongo_bulk_upsert", "details": {"documents": len(batch_data)}},
        )


# Função para dividir o trabalho entre múltiplos processos
def insert_data_to_mongo_parallel(color_legend, coordinates):
    num_processes = max(1, cpu_count() // 2 + 2)
    coordinate_batches = split_into_batches(coordinates, num_processes)
    if not coordinate_batches:
        logger.info(
            "Skipping ingestion because there are no coordinates to process.",
            extra={"event": "mongo_ingest_skipped_empty"},
        )
        return

    # Threaded batching avoids forking an inherited Mongo client.
    with ThreadPoolExecutor(max_workers=len(coordinate_batches)) as executor:
        list(executor.map(process_coordinate_batch, [(batch, color_legend) for batch in coordinate_batches]))

# Rotas simples
@app.route('/')
def home():
    return jsonify({"message": "API do backend de desmatamento"})


@app.route('/api/news', methods=['GET'])
def get_news():
    enforce_rate_limit()
    
    try:
        page = int(request.args.get('page', 1))
        page_size = int(request.args.get('page_size', 20))
    except (TypeError, ValueError):
        page = 1
        page_size = 20
    
    from news import get_news as fetch_news, fetch_and_save_news
    
    if page == 1:
        fetch_and_save_news()
    
    articles = fetch_news(page, page_size)
    
    return jsonify(articles)


@app.route('/api/news/refresh', methods=['POST'])
def refresh_news():
    enforce_rate_limit()
    
    from news import fetch_and_save_news
    fetch_and_save_news()
    
    return jsonify({"status": "refreshed"})


@app.route('/data')
def get_data():
    enforce_rate_limit()
    enforce_api_auth()

    try:
        ne_lat = float(request.args.get('ne_lat', None))
        ne_lng = float(request.args.get('ne_lng', None))
        sw_lat = float(request.args.get('sw_lat', None))
        sw_lng = float(request.args.get('sw_lng', None))
    except (TypeError, ValueError):
        return abort(400, description="Invalid or missing query parameters. Please provide valid 'ne_lat', 'ne_lng', 'sw_lat', and 'sw_lng'.")

    # Validate bounding box
    if ne_lat is None or ne_lng is None or sw_lat is None or sw_lng is None:
        return abort(400, description="All parameters (ne_lat, ne_lng, sw_lat, sw_lng) are required.")
    
    if ne_lat <= sw_lat or ne_lng <= sw_lng:
        return abort(400, description="Invalid bounding box: ne_lat must be > sw_lat and ne_lng must be > sw_lng.")

    validate_coordinate("ne_lat", ne_lat, -90.0, 90.0)
    validate_coordinate("sw_lat", sw_lat, -90.0, 90.0)
    validate_coordinate("ne_lng", ne_lng, -180.0, 180.0)
    validate_coordinate("sw_lng", sw_lng, -180.0, 180.0)

    clamped_bbox = clamp_bbox_to_brazil(ne_lat, ne_lng, sw_lat, sw_lng)
    if clamped_bbox is None:
        return jsonify([])

    ne_lat, ne_lng, sw_lat, sw_lng = clamped_bbox

    query = {
        "lat": {"$lte": ne_lat, "$gte": sw_lat},
        "lon": {"$lte": ne_lng, "$gte": sw_lng}
    }

    data = mongo.db.deforestation_data.find(query).limit(MAX_RESULTS)
    return jsonify([{
        "name": item["name"],
        "lat": item["lat"],
        "lon": item["lon"],
        "color": item["color"],
        "clazz": item.get("clazz", "Desmatamento"),
        "periods": item.get("periods", "N/A"),
        "source": item.get("source", "TerraBrasilis"),
        "timestamp": item["timestamp"].isoformat()
    } for item in data])


if __name__ == "__main__":
    # In development you can enable the local dev server with DEV=1
    # Heavy ingestion is disabled by default. To run ingestion, use the separate ingest script.
    if os.getenv("DEV", "0") == "1":
        app.run(host='0.0.0.0', port=5000)

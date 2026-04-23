import asyncio
import csv
import datetime
import ipaddress
import io
import json
import logging
import os
import sys
import time
import xml.etree.ElementTree as ET
import zipfile
from collections import defaultdict, deque
from concurrent.futures import ThreadPoolExecutor
from contextlib import suppress
from multiprocessing import cpu_count
from secrets import compare_digest
from threading import Lock
from urllib.parse import quote_plus

import httpx
import pymongo
import redis.asyncio as aioredis
from dotenv import load_dotenv
from motor.motor_asyncio import AsyncIOMotorClient
from quart import Quart, request, abort, jsonify
from quart_cors import cors

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
FIRMS_MAP_KEY = os.getenv("FIRMS_MAP_KEY", "").strip()
FIRMS_SYNC_INTERVAL_HOURS = int(os.getenv("FIRMS_SYNC_INTERVAL_HOURS", "24"))
FIRMS_DAY_RANGE = int(os.getenv("FIRMS_DAY_RANGE", "3"))
FIRMS_BBOX = "-74,-34,-34,5.5"
FIRMS_SOURCE = os.getenv("FIRMS_SOURCE", "VIIRS_SNPP_NRT")
FIRE_TTL_DAYS = int(os.getenv("FIRE_TTL_DAYS", "90"))
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


_TRUSTED_NETWORKS = _parse_trusted_networks if False else None


def _parse_trusted_networks():
    raw = os.getenv("TRUSTED_PROXIES", "")
    networks = []
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        try:
            networks.append(ipaddress.ip_network(item, strict=False))
        except ValueError:
            logger.warning("Invalid CIDR in TRUSTED_PROXIES, ignoring: %s", item)
    return networks


_TRUSTED_NETWORKS = _parse_trusted_networks()


def _is_trusted_proxy(ip_str):
    if not _TRUSTED_NETWORKS:
        return False
    try:
        addr = ipaddress.ip_address(ip_str)
        return any(addr in net for net in _TRUSTED_NETWORKS)
    except ValueError:
        return False


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
                "remote_addr": request.remote_addr,
            },
        )
        abort(401, description="A valid API key is required.")


async def enforce_rate_limit():
    client_ip = request.remote_addr or "unknown"

    if _is_trusted_proxy(client_ip) and request.headers.get("X-Forwarded-For"):
        ips = [ip.strip() for ip in request.headers.get("X-Forwarded-For", "").split(",") if ip.strip()]
        for ip in ips:
            if not _is_trusted_proxy(ip):
                client_ip = ip
                break

    now = time.time()
    request_count = None
    try:
        key = f"rate_limit:{client_ip}"
        pipe = redis_client.pipeline()
        await pipe.zremrangebyscore(key, 0, now - RATE_LIMIT_WINDOW_SECONDS)
        await pipe.zcard(key)
        await pipe.zadd(key, {str(now): now})
        await pipe.expire(key, RATE_LIMIT_WINDOW_SECONDS)
        results = await pipe.execute()
        request_count = results[1]
    except Exception:
        with _RATE_LIMIT_LOCK:
            window = _RATE_LIMIT_BUCKETS[client_ip]
            while window and window[0] < now - RATE_LIMIT_WINDOW_SECONDS:
                window.popleft()
            request_count = len(window)
            window.append(now)

    if request_count >= RATE_LIMIT_REQUESTS:
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


app = Quart(__name__)
app = cors(app, allow_origin=parse_cors_origins())

MONGO_URI = build_mongo_uri()
MONGO_DATABASE = os.getenv("MONGO_DATABASE", "terrabrasilis_data")
motor_client = AsyncIOMotorClient(MONGO_URI)
mongo_db = motor_client[MONGO_DATABASE]

REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379/0")
redis_client = aioredis.from_url(REDIS_URL, socket_connect_timeout=5, socket_timeout=5)


@app.before_serving
async def startup():
    asyncio.get_event_loop().create_task(_fires_sync_loop())


@app.after_serving
async def shutdown():
    motor_client.close()
    await redis_client.close()


async def _fetch_firms_data():
    if not FIRMS_MAP_KEY:
        logger.warning("FIRMS_MAP_KEY not configured, skipping fire data sync.", extra={"event": "firms_skip_no_key"})
        return 0

    url = f"https://firms.modaps.eosdis.nasa.gov/api/area/csv/{FIRMS_MAP_KEY}/{FIRMS_SOURCE}/{FIRMS_BBOX}/{FIRMS_DAY_RANGE}"
    logger.info("Fetching FIRMS fire data.", extra={"event": "firms_fetch_start", "details": {"url": url}})

    try:
        async with httpx.AsyncClient(timeout=60) as client:
            resp = await client.get(url)
            if resp.status_code != 200:
                logger.error("FIRMS API returned non-200.", extra={"event": "firms_fetch_failed", "status_code": resp.status_code})
                return 0

            text = resp.text
    except Exception as exc:
        logger.error("FIRMS fetch exception.", extra={"event": "firms_fetch_error", "details": {"error": str(exc)}})
        return 0

    reader = csv.DictReader(io.StringIO(text))
    operations = []
    count = 0
    for row in reader:
        try:
            lat = float(row.get("latitude", 0))
            lon = float(row.get("longitude", 0))
            confidence = row.get("confidence", "low").strip().lower()
            acq_date = row.get("acq_date", "")
            acq_time = row.get("acq_time", "")
            satellite = row.get("satellite", "")
            bright_ti4 = float(row.get("bright_ti4", 0) or 0)
        except (ValueError, TypeError):
            continue

        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            continue

        doc = {
            "lat": lat,
            "lon": lon,
            "confidence": confidence,
            "acq_date": acq_date,
            "acq_time": acq_time,
            "satellite": satellite,
            "bright_ti4": bright_ti4,
            "source": "NASA_FIRMS_VIIRS_SNPP",
            "ingested_at": datetime.datetime.now(datetime.UTC),
        }
        operations.append(
            pymongo.UpdateOne(
                {"lat": lat, "lon": lon, "acq_date": acq_date},
                {"$setOnInsert": doc},
                upsert=True,
            )
        )
        count += 1

    if operations:
        from pymongo import UpdateOne as _UO
        batch_size = 500
        for i in range(0, len(operations), batch_size):
            batch = operations[i:i + batch_size]
            await mongo_db.fire_data.bulk_write(batch, ordered=False)

    try:
        await redis_client.set("fires:last_sync", datetime.datetime.now(datetime.UTC).isoformat())
    except Exception:
        pass

    logger.info("FIRMS sync complete.", extra={"event": "firms_sync_complete", "details": {"records": count}})
    return count


async def _fires_sync_loop():
    await asyncio.sleep(10)

    while True:
        try:
            should_sync = True
            try:
                last_sync_str = await redis_client.get("fires:last_sync")
                if last_sync_str:
                    last_sync = datetime.datetime.fromisoformat(last_sync_str.decode())
                    elapsed_hours = (datetime.datetime.now(datetime.UTC) - last_sync).total_seconds() / 3600
                    if elapsed_hours < FIRMS_SYNC_INTERVAL_HOURS:
                        should_sync = False
                        logger.info("FIRMS sync not due yet.", extra={"event": "firms_sync_skip", "details": {"hours_since_last": round(elapsed_hours, 1)}})
            except Exception:
                pass

            if should_sync:
                await _fetch_firms_data()

            await asyncio.sleep(FIRMS_SYNC_INTERVAL_HOURS * 3600)
        except Exception as exc:
            logger.error("FIRMS sync loop error.", extra={"event": "firms_sync_loop_error", "details": {"error": str(exc)}})
            await asyncio.sleep(3600)


@app.route("/api/fires")
async def get_fires():
    await enforce_rate_limit()
    enforce_api_auth()

    try:
        ne_lat = float(request.args.get("ne_lat", 5.5))
        ne_lng = float(request.args.get("ne_lng", -34.0))
        sw_lat = float(request.args.get("sw_lat", -34.0))
        sw_lng = float(request.args.get("sw_lng", -74.0))
    except (TypeError, ValueError):
        abort(400, description="Invalid query parameters for /api/fires.")

    query = {
        "lat": {"$lte": ne_lat, "$gte": sw_lat},
        "lon": {"$lte": ne_lng, "$gte": sw_lng},
    }

    cursor = mongo_db.fire_data.find(query).limit(MAX_RESULTS)
    if hasattr(cursor, "to_list"):
        data = await cursor.to_list(length=MAX_RESULTS)
    else:
        data = list(cursor)

    last_sync = None
    try:
        last_sync_raw = await redis_client.get("fires:last_sync")
        if last_sync_raw:
            last_sync = last_sync_raw.decode() if isinstance(last_sync_raw, bytes) else last_sync_raw
    except Exception:
        pass

    return jsonify({
        "fires": [{
            "lat": item["lat"],
            "lon": item["lon"],
            "confidence": item["confidence"],
            "acq_date": item["acq_date"],
            "acq_time": item.get("acq_time", ""),
            "satellite": item.get("satellite", ""),
            "bright_ti4": item.get("bright_ti4", 0),
        } for item in data],
        "count": len(data),
        "last_sync": last_sync,
    })


@app.route("/api/fires/sync", methods=["POST"])
async def sync_fires():
    enforce_api_auth()
    await enforce_rate_limit()

    count = await _fetch_firms_data()
    return jsonify({"status": "synced", "records": count})


@app.before_request
async def start_request_timer():
    request._start_time = time.perf_counter()


@app.after_request
async def add_security_headers(response):
    for header_name, header_value in build_security_headers().items():
        response.headers.setdefault(header_name, header_value)

    duration_ms = None
    with suppress(Exception):
        duration_ms = round((time.perf_counter() - request._start_time) * 1000, 2)

    remote_addr = request.remote_addr or "unknown"
    if _is_trusted_proxy(remote_addr) and request.headers.get("X-Forwarded-For"):
        ips = [ip.strip() for ip in request.headers.get("X-Forwarded-For", "").split(",") if ip.strip()]
        for ip in ips:
            if not _is_trusted_proxy(ip):
                remote_addr = ip
                break

    logger.info(
        "Handled backend request.",
        extra={
            "event": "http_request",
            "path": request.path,
            "status_code": response.status_code,
            "remote_addr": remote_addr,
            "details": {
                "method": request.method,
                "duration_ms": duration_ms,
            },
        },
    )
    return response


@app.route("/health")
async def health():
    return jsonify({"status": "healthy", "timestamp": datetime.datetime.now(datetime.UTC).isoformat()})


@app.errorhandler(404)
async def not_found(error):
    return jsonify({"error": "Not found", "message": str(error)}), 404


@app.errorhandler(400)
async def bad_request(error):
    return jsonify({"error": "Bad request", "message": str(error)}), 400


@app.errorhandler(401)
async def unauthorized(error):
    return jsonify({"error": "Unauthorized", "message": str(error)}), 401


@app.errorhandler(429)
async def rate_limited(error):
    return jsonify({"error": "Too many requests", "message": str(error)}), 429


@app.errorhandler(503)
async def service_unavailable(error):
    return jsonify({"error": "Service unavailable", "message": str(error)}), 503


@app.errorhandler(500)
async def internal_error(error):
    return jsonify({"error": "Internal server error"}), 500


def download_and_extract_data():
    tif_file_path = "/app/prodes_brasil_2023.tif"
    qml_file_path = "/app/prodes_brasil_2023.qml"
    zip_file_url = "https://terrabrasilis.dpi.inpe.br/download/dataset/brasil-prodes/raster/prodes_brasil_2023.zip"
    zip_file_path = "/app/prodes_brasil_2023.zip"

    if not (os.path.isfile(tif_file_path) and os.path.isfile(qml_file_path)):
        logger.info(
            "Dataset files not found. Downloading archive.",
            extra={"event": "dataset_download_start", "details": {"archive_url": zip_file_url}},
        )
        with httpx.Client(timeout=120) as client:
            with client.stream("GET", zip_file_url) as resp:
                if resp.status_code == 200:
                    with open(zip_file_path, "wb") as zip_file:
                        for chunk in resp.iter_bytes(chunk_size=1024):
                            zip_file.write(chunk)
                    with zipfile.ZipFile(zip_file_path, "r") as zip_ref:
                        zip_ref.extractall("/app")
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
                            "status_code": resp.status_code,
                            "details": {"archive_url": zip_file_url},
                        },
                    )
    else:
        logger.info(
            "Dataset files already available locally.",
            extra={"event": "dataset_already_present", "details": {"target_dir": "/app"}},
        )


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
    try:
        import rasterio
    except Exception:
        raise

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
    from pymongo import UpdateOne

    coordinates_batch, color_legend, mongo_uri, mongo_database = args
    from pymongo import MongoClient as SyncMongoClient

    client = SyncMongoClient(mongo_uri)
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
        operations = []
        for data in batch_data:
            operations.append(
                UpdateOne(
                    {"name": data["name"], "lat": data["lat"], "lon": data["lon"]},
                    {"$setOnInsert": data},
                    upsert=True,
                )
            )
        if operations:
            db.deforestation_data.bulk_write(operations, ordered=False)
        logger.info(
            "Batch documents upserted into MongoDB.",
            extra={"event": "mongo_bulk_upsert", "details": {"documents": len(batch_data)}},
        )
    client.close()


def insert_data_to_mongo_parallel(color_legend, coordinates):
    num_processes = max(1, cpu_count() // 2 + 2)
    coordinate_batches = split_into_batches(coordinates, num_processes)
    if not coordinate_batches:
        logger.info(
            "Skipping ingestion because there are no coordinates to process.",
            extra={"event": "mongo_ingest_skipped_empty"},
        )
        return

    mongo_uri = build_mongo_uri()
    mongo_database = os.getenv("MONGO_DATABASE", "terrabrasilis_data")
    with ThreadPoolExecutor(max_workers=len(coordinate_batches)) as executor:
        list(executor.map(process_coordinate_batch, [(batch, color_legend, mongo_uri, mongo_database) for batch in coordinate_batches]))


@app.route("/")
async def home():
    return jsonify({"message": "API do backend de desmatamento"})


@app.route("/api/news", methods=["GET"])
async def get_news():
    await enforce_rate_limit()
    enforce_api_auth()

    try:
        page = int(request.args.get("page", 1))
        page_size = int(request.args.get("page_size", 20))
    except (TypeError, ValueError):
        abort(400, description="Invalid 'page' or 'page_size' parameters.")

    if page < 1:
        abort(400, description="'page' must be >= 1.")
    if page_size < 1 or page_size > 100:
        abort(400, description="'page_size' must be between 1 and 100.")

    from news import get_news as fetch_news, fetch_and_save_news

    if page == 1:
        await fetch_and_save_news(mongo_db)

    articles = await fetch_news(mongo_db, page, page_size)
    return jsonify(articles)


@app.route("/api/news/refresh", methods=["POST"])
async def refresh_news():
    if AUTH_REQUIRED:
        enforce_api_auth()
    await enforce_rate_limit()

    from news import fetch_and_save_news
    await fetch_and_save_news(mongo_db)

    return jsonify({"status": "refreshed"})


WAQI_TOKEN = os.getenv("WAQI_TOKEN", "demo")
OPENWEATHER_APPID = os.getenv("OPENWEATHER_APPID", "")


@app.route("/api/weather/air-quality")
async def get_air_quality():
    await enforce_rate_limit()
    station = request.args.get("station", "brasilia")
    url = f"https://api.waqi.info/feed/{station}/?token={WAQI_TOKEN}"
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(url)
            data = resp.json()
            if data.get("status") == "ok":
                d = data["data"]
                return jsonify({
                    "aqi": d.get("aqi"),
                    "pm25": d.get("iaqi", {}).get("pm25", {}).get("v"),
                    "humidity": d.get("iaqi", {}).get("h", {}).get("v"),
                })
            return jsonify({"aqi": None})
    except Exception:
        return jsonify({"aqi": None})


@app.route("/api/weather/temperature")
async def get_temperature():
    await enforce_rate_limit()
    lat = request.args.get("lat", "-14.235")
    lon = request.args.get("lon", "-51.925")
    if not OPENWEATHER_APPID:
        return jsonify({"temp": None})
    url = f"https://api.openweathermap.org/data/2.5/weather?lat={lat}&lon={lon}&appid={OPENWEATHER_APPID}&units=metric"
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(url)
            data = resp.json()
            if data.get("main"):
                return jsonify({
                    "temp": data["main"].get("temp"),
                    "feels_like": data["main"].get("feels_like"),
                    "city": data.get("name", ""),
                })
            return jsonify({"temp": None})
    except Exception:
        return jsonify({"temp": None})


@app.route("/api/data")
async def get_data():
    await enforce_rate_limit()
    enforce_api_auth()

    try:
        ne_lat = float(request.args.get("ne_lat", None))
        ne_lng = float(request.args.get("ne_lng", None))
        sw_lat = float(request.args.get("sw_lat", None))
        sw_lng = float(request.args.get("sw_lng", None))
    except (TypeError, ValueError):
        abort(400, description="Invalid or missing query parameters. Please provide valid 'ne_lat', 'ne_lng', 'sw_lat', and 'sw_lng'.")

    if ne_lat is None or ne_lng is None or sw_lat is None or sw_lng is None:
        abort(400, description="All parameters (ne_lat, ne_lng, sw_lat, sw_lng) are required.")

    if ne_lat <= sw_lat or ne_lng <= sw_lng:
        abort(400, description="Invalid bounding box: ne_lat must be > sw_lat and ne_lng must be > sw_lng.")

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
        "lon": {"$lte": ne_lng, "$gte": sw_lng},
    }

    cursor = mongo_db.deforestation_data.find(query).limit(MAX_RESULTS)
    if hasattr(cursor, "to_list"):
        data = await cursor.to_list(length=MAX_RESULTS)
    else:
        data = list(cursor)
    return jsonify([{
        "name": item["name"],
        "lat": item["lat"],
        "lon": item["lon"],
        "color": item["color"],
        "clazz": item.get("clazz", "Desmatamento"),
        "periods": item.get("periods", "N/A"),
        "source": item.get("source", "TerraBrasilis"),
        "timestamp": item["timestamp"].isoformat(),
    } for item in data])


def _shutdown_handler(signum, frame):
    logger.info("Received shutdown signal (%s). Exiting gracefully...", signum, extra={"event": "shutdown_signal", "details": {"signal": signum}})
    sys.exit(0)


import signal
signal.signal(signal.SIGTERM, _shutdown_handler)
signal.signal(signal.SIGINT, _shutdown_handler)


if __name__ == "__main__":
    if os.getenv("DEV", "0") == "1":
        app.run(host="0.0.0.0", port=5000)
import asyncio
import csv
import datetime
from datetime import timezone
import gzip
import ipaddress
import io
import json
import logging
import os
import sys
import time
from collections import defaultdict, deque
from contextlib import suppress
from secrets import compare_digest
from threading import Lock

import httpx
import redis.asyncio as aioredis
from dotenv import load_dotenv
from quart import Quart, request, abort, jsonify, current_app
from quart_cors import cors

import db_sqlite
import biome_lookup
import alerts as alert_module
import indigenous_lands_lookup
import conservation_units_lookup

load_dotenv()

# Redis cache TTL (seconds)
CACHE_TTL_DEFAULT  = 300   # 5 min
CACHE_TTL_FIRMS    = 60    # 1 min (frequently updated)
CACHE_TTL_WEATHER  = 900   # 15 min
CACHE_TTL_DATA     = 900   # 15 min

def _load_json_file(filename: str) -> bytes:
    path = os.path.join(os.path.dirname(__file__), filename)
    try:
        with open(path, "rb") as f:
            return f.read()
    except Exception:
        return b"{}"

_INDIGENOUS_DATA   = _load_json_file("indigenous_lands.json")
_CONSERVATION_DATA = _load_json_file("conservation_units.json")

BRAZIL_BOUNDS = {
    "min_lat": -34.0,
    "max_lat": 5.5,
    "min_lon": -74.0,
    "max_lon": -34.0,
}
MAX_RESULTS = int(os.getenv("MAX_RESULTS_PER_REQUEST", "10000"))
RATE_LIMIT_REQUESTS = int(os.getenv("RATE_LIMIT_REQUESTS", "60"))
RATE_LIMIT_WINDOW_SECONDS = int(os.getenv("RATE_LIMIT_WINDOW_SECONDS", "60"))
AUTH_REQUIRED = os.getenv("AUTH_REQUIRED", "1") == "1"
API_KEY = os.getenv("API_KEY", "").strip()
NEWS_SYNC_INTERVAL_MINUTES = int(os.getenv("NEWS_SYNC_INTERVAL_MINUTES", "15"))
FIRMS_MAP_KEY = os.getenv("FIRMS_MAP_KEY", "").strip()
FIRMS_SYNC_INTERVAL_HOURS = int(os.getenv("FIRMS_SYNC_INTERVAL_HOURS", "4"))
FIRMS_DAY_RANGE = int(os.getenv("FIRMS_DAY_RANGE", "3"))
FIRMS_BBOX = "-74,-34,-34,5.5"  # Brazil only (legacy)
GLOBAL_BBOXES = [
    "-180,-90,-90,90",   # Americas
    "-90,-90,0,90",      # Atlantic/Africa
    "0,-90,90,90",       # Europe/Asia/Africa
    "90,-90,180,90",     # Asia/Pacific
]
FIRMS_SOURCE = os.getenv("FIRMS_SOURCE", "VIIRS_SNPP_NRT")
FIRE_TTL_DAYS = int(os.getenv("FIRE_TTL_DAYS", "90"))
_RATE_LIMIT_BUCKETS = defaultdict(deque)
_RATE_LIMIT_LOCK = Lock()

# In-memory news response cache (_news_cache[key] = (timestamp, articles))
_news_cache: dict[str, tuple[float, list[dict]]] = {}
_NEWS_CACHE_TTL_SECONDS = 60 * 5  # 5 minutes server-side

# Background tasks
_news_sync_task: asyncio.Task | None = None
_fires_sync_task: asyncio.Task | None = None
_alerts_sync_task: asyncio.Task | None = None

# Shared HTTP client — created at startup, closed at shutdown
_http_client: httpx.AsyncClient | None = None


class JsonFormatter(logging.Formatter):
    def format(self, record):
        payload = {
            "timestamp": datetime.datetime.now(timezone.utc).isoformat(),
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


_CACHE_CONTROL = {
    "/api/fires":               "public, max-age=60",
    "/api/biomes":              "public, max-age=60",
    "/api/alerts":              "public, max-age=1800",
    "/api/data":                "public, max-age=900",
    "/api/indigenous-lands":   "public, max-age=86400",
    "/api/conservation-units": "public, max-age=86400",
    "/api/weather/air-quality": "public, max-age=900",
    "/api/weather/temperature": "public, max-age=900",
}

_SECURITY_HEADERS = {
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

REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379/0")
redis_client: aioredis.Redis | None = None


async def cache_get(key: str):
    """Get value from Redis cache. Returns decoded string or None."""
    if not redis_client:
        return None
    try:
        val = await redis_client.get(key)
        if val is not None and isinstance(val, bytes):
            val = val.decode()
        return val
    except Exception:
        # Redis unavailable - skip cache
        return None


async def cache_set(key: str, value, ttl: int = CACHE_TTL_DEFAULT):
    """Set value in Redis cache with TTL."""
    if not redis_client:
        return
    try:
        await redis_client.setex(key, ttl, value)
    except Exception:
        # Redis unavailable - skip cache
        pass


async def cache_delete(pattern: str):
    """Delete cache keys matching pattern using SCAN (production-safe)."""
    if not redis_client:
        return
    try:
        keys = []
        async for key in redis_client.scan_iter(match=pattern, count=100):
            keys.append(key)
        if keys:
            await redis_client.delete(*keys)
    except Exception:
        # Redis unavailable - skip
        pass


@app.before_serving
async def startup():
    global redis_client, _news_sync_task, _fires_sync_task, _alerts_sync_task, _http_client
    _http_client = httpx.AsyncClient(timeout=30.0)
    await db_sqlite.init_db()
    logger.info("SQLite connection verified.", extra={"event": "sqlite_connect_ok"})

    # Load biome boundaries for point-in-polygon classification
    try:
        biome_lookup.load_biomes()
    except Exception as e:
        logger.warning("Failed to load biome data – biome lookup disabled: %s", e, exc_info=True)

    # Load indigenous lands and conservation units for alert generation
    try:
        indigenous_lands_lookup.load_indigenous_lands()
    except Exception as e:
        logger.warning("Failed to load indigenous lands data: %s", e)

    try:
        conservation_units_lookup.load_conservation_units()
    except Exception as e:
        logger.warning("Failed to load conservation units data: %s", e)

    # Try Redis connection (optional)
    try:
        redis_client = aioredis.from_url(REDIS_URL, socket_connect_timeout=5, socket_timeout=5)
        await redis_client.ping()
        logger.info("Redis connected.", extra={"event": "redis_connect_ok"})
    except Exception as e:
        redis_client = None
        logger.warning(f"Redis unavailable - caching disabled. Error: {e}", extra={"event": "redis_connect_failed"})

    _fires_sync_task = asyncio.create_task(_fires_sync_loop())
    _news_sync_task = asyncio.create_task(_news_sync_loop())
    _alerts_sync_task = asyncio.create_task(_alerts_sync_loop())


@app.after_serving
async def shutdown():
    global _http_client
    await db_sqlite.close_db()
    if redis_client:
        await redis_client.close()
    if _http_client:
        await _http_client.aclose()
        _http_client = None
    from news_sqlite import close_http_client
    await close_http_client()
    global _news_sync_task, _fires_sync_task, _alerts_sync_task
    for task in (_news_sync_task, _fires_sync_task, _alerts_sync_task):
        if task:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass


async def _fetch_firms_data(global_sync: bool = False):
    if not FIRMS_MAP_KEY:
        logger.warning("FIRMS_MAP_KEY not configured, skipping fire data sync.", extra={"event": "firms_skip_no_key"})
        return 0

    bboxes = GLOBAL_BBOXES if global_sync else [FIRMS_BBOX]
    all_docs = []
    total_count = 0

    for bbox in bboxes:
        url = f"https://firms.modaps.eosdis.nasa.gov/api/area/csv/{FIRMS_MAP_KEY}/{FIRMS_SOURCE}/{bbox}/{FIRMS_DAY_RANGE}"
        logger.info("Fetching FIRMS fire data.", extra={"event": "firms_fetch_start", "details": {"url": url, "global": global_sync}})

        try:
            resp = await _http_client.get(url, timeout=60.0)
            if resp.status_code != 200:
                logger.error("FIRMS API returned non-200.", extra={"event": "firms_fetch_failed", "status_code": resp.status_code})
                continue
            text = resp.text
        except Exception as exc:
            logger.error("FIRMS fetch exception.", extra={"event": "firms_fetch_error", "details": {"error": str(exc)}})
            continue

        reader = csv.DictReader(io.StringIO(text))
        docs = []
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

            docs.append({
                "lat": lat,
                "lon": lon,
                "confidence": confidence,
                "acq_date": acq_date,
                "acq_time": acq_time,
                "satellite": satellite,
                "bright_ti4": bright_ti4,
                "source": "NASA_FIRMS_VIIRS_SNPP",
                "ingested_at": datetime.datetime.now(timezone.utc).isoformat(),
            })
            count += 1

        if docs:
            await db_sqlite.bulk_upsert_fires(docs)
        total_count += count

    # Update sync timestamp
    await cache_set("fires:last_sync", datetime.datetime.now(timezone.utc).isoformat(), ttl=CACHE_TTL_DEFAULT * 12)
    
    # Invalidate fires cache
    await cache_delete("fires:*")
    logger.debug("Fires cache invalidated")

    # Refresh alert cache after new fire data arrives
    try:
        await _refresh_alerts_cache()
    except Exception as exc:
        logger.warning("Alert cache refresh failed after FIRMS sync: %s", exc)

    logger.info("FIRMS sync complete.", extra={"event": "firms_sync_complete", "details": {"records": total_count, "global": global_sync}})
    return total_count


async def _refresh_alerts_cache() -> dict:
    """Recompute all alerts, store in cache, and return the result."""
    fires = await db_sqlite.find_fires(
        sw_lat=BRAZIL_BOUNDS["min_lat"], ne_lat=BRAZIL_BOUNDS["max_lat"],
        sw_lng=BRAZIL_BOUNDS["min_lon"], ne_lng=BRAZIL_BOUNDS["max_lon"],
        limit=MAX_RESULTS,
    )
    result = await alert_module.generate_all_alerts(fires, _http_client, WAQI_TOKEN)
    await cache_set("alerts:all", json.dumps(result), ttl=CACHE_TTL_FIRMS * 30)
    logger.debug("Alerts cache refreshed: %d alerts", result["count"])
    return result


async def _alerts_sync_loop():
    await asyncio.sleep(60)
    while True:
        try:
            await _refresh_alerts_cache()
        except Exception as exc:
            logger.error("Alerts sync loop error: %s", exc)
        await asyncio.sleep(1800)  # 30 minutes


async def _fires_sync_loop():
    await asyncio.sleep(10)

    while True:
        try:
            should_sync = True
            try:
                last_sync_str = await cache_get("fires:last_sync")
                if last_sync_str:
                    last_sync = datetime.datetime.fromisoformat(last_sync_str)
                    elapsed_hours = (datetime.datetime.now(datetime.timezone.utc) - last_sync).total_seconds() / 3600
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


async def _news_sync_loop():
    from news_sqlite import fetch_and_save_news  # import once before loop
    await asyncio.sleep(15)
    while True:
        try:
            await fetch_and_save_news()
            _news_cache.clear()
            logger.info("News sync complete.", extra={"event": "news_sync_complete"})
        except Exception as exc:
            logger.error("News sync error.", extra={"event": "news_sync_loop_error", "details": {"error": str(exc)}})
        await asyncio.sleep(NEWS_SYNC_INTERVAL_MINUTES * 60)


@app.route("/api/fires")
async def get_fires():
    enforce_api_auth()
    await enforce_rate_limit()

    ne_lat = request.args.get("ne_lat")
    ne_lng = request.args.get("ne_lng")
    sw_lat = request.args.get("sw_lat")
    sw_lng = request.args.get("sw_lng")

    # Build cache key from bbox
    cache_key = f"fires:{ne_lat or 'global'}:{ne_lng or ''}:{sw_lat or ''}:{sw_lng or ''}"
    
    # Try cache first
    cached = await cache_get(cache_key)
    if cached:
        logger.debug(f"Cache hit: {cache_key}")
        return jsonify(json.loads(cached))

    if ne_lat and ne_lng and sw_lat and sw_lng:
        try:
            ne_lat = float(ne_lat)
            ne_lng = float(ne_lng)
            sw_lat = float(sw_lat)
            sw_lng = float(sw_lng)
        except (TypeError, ValueError):
            abort(400, description="Invalid coordinates.")
        if ne_lat <= sw_lat or ne_lng <= sw_lng:
            abort(400, description="Invalid bbox.")
    else:
        sw_lat, ne_lat, sw_lng, ne_lng = -90.0, 90.0, -180.0, 180.0

    data = await db_sqlite.find_fires(sw_lat, ne_lat, sw_lng, ne_lng, limit=MAX_RESULTS)
    last_sync = await cache_get("fires:last_sync")
    
    response = {"fires": data, "last_sync": last_sync}
    
    # Cache response
    await cache_set(cache_key, json.dumps(response), CACHE_TTL_FIRMS)
    logger.debug(f"Cache set: {cache_key}")
    
    return jsonify(response)


@app.route("/api/admin/firms/sync", methods=["POST"])
async def trigger_firms_sync():
    """Manual trigger for FIRMS data sync. Requires API key auth."""
    enforce_api_auth()
    await enforce_rate_limit()
    
    logger.info("Manual FIRMS sync triggered.", extra={"event": "firms_manual_trigger"})
    count = await _fetch_firms_data()
    
    last_sync = await cache_get("fires:last_sync")
    
    return jsonify({
        "status": "success",
        "message": f"FIRMS sync completed. {count} records processed.",
        "records": count,
        "last_sync": last_sync
    })


@app.route("/api/fires/sync", methods=["POST"])
async def sync_fires():
    enforce_api_auth()
    await enforce_rate_limit()

    global_sync = request.args.get("global", "0") == "1"
    count = await _fetch_firms_data(global_sync=global_sync)
    return jsonify({"status": "synced", "records": count, "global": global_sync})


@app.before_request
async def start_request_timer():
    request._start_time = time.perf_counter()


@app.after_request
async def add_security_headers(response):
    for header_name, header_value in _SECURITY_HEADERS.items():
        response.headers.setdefault(header_name, header_value)

    # Cache-Control per endpoint
    cc = _CACHE_CONTROL.get(request.path)
    if cc and response.status_code == 200:
        response.headers.setdefault("Cache-Control", cc)

    # Gzip compression for JSON responses > 1 KB
    accept_enc = request.headers.get("Accept-Encoding", "")
    if (
        "gzip" in accept_enc
        and response.status_code == 200
        and "json" in (response.content_type or "")
        and not response.headers.get("Content-Encoding")
    ):
        data = await response.get_data()
        if len(data) > 1024:
            compressed = gzip.compress(data, compresslevel=6)
            response.set_data(compressed)
            response.headers["Content-Encoding"] = "gzip"
            response.headers["Content-Length"] = str(len(compressed))

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
    return jsonify({"status": "healthy", "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat()})


@app.route("/api/biomes")
async def get_biomes():
    """Return fire counts per biome using IBGE shapefile + FIRMS data."""
    enforce_api_auth()
    await enforce_rate_limit()

    # Try cache first
    cached = await cache_get("biomes:all")
    if cached:
        return jsonify(json.loads(cached))

    # Get all fires from Brazil bounds
    fires = await db_sqlite.find_fires(
        sw_lat=-34.0, ne_lat=5.5, sw_lng=-74.0, ne_lng=-34.0,
        limit=MAX_RESULTS
    )

    result = biome_lookup.classify_fires(fires)

    last_sync = await cache_get("fires:last_sync")
    response = {"biomes": result, "total_fires": len(fires), "last_sync": last_sync}

    await cache_set("biomes:all", json.dumps(response), CACHE_TTL_FIRMS)
    return jsonify(response)


@app.route("/api/alerts")
async def get_alerts():
    """Return active environmental alerts (fires, air quality, PRODES)."""
    enforce_api_auth()
    await enforce_rate_limit()

    cached = await cache_get("alerts:all")
    if cached:
        return jsonify(json.loads(cached))

    result = await _refresh_alerts_cache()
    return jsonify(result)


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


@app.route("/")
async def home():
    return jsonify({"message": "API do backend de desmatamento"})


@app.route("/api/news", methods=["GET"])
async def get_news():
    enforce_api_auth()
    await enforce_rate_limit()

    try:
        page = int(request.args.get("page", 1))
        page_size = int(request.args.get("page_size", 20))
        lang = request.args.get("lang", "pt").strip().lower()
    except (TypeError, ValueError):
        abort(400, description="Invalid 'page' or 'page_size' parameters.")

    if page < 1:
        abort(400, description="'page' must be >= 1.")
    if page_size < 1 or page_size > 100:
        abort(400, description="'page_size' must be between 1 and 100.")
    if lang not in ("pt", "en"):
        lang = "pt"

    cache_key = f"news_{lang}_{page}_{page_size}"
    now = time.time()
    cached = _news_cache.get(cache_key)
    if cached and now - cached[0] < _NEWS_CACHE_TTL_SECONDS:
        response = jsonify(cached[1])
        response.headers["Cache-Control"] = "public, max-age=300"
        return response

    from news_sqlite import get_news as fetch_news
    articles = await fetch_news(page, page_size, lang=lang)
    _news_cache[cache_key] = (now, articles)
    response = jsonify(articles)
    response.headers["Cache-Control"] = "public, max-age=300"
    return response


@app.route("/api/news/refresh", methods=["POST"])
async def refresh_news():
    if AUTH_REQUIRED:
        enforce_api_auth()
    await enforce_rate_limit()

    from news_sqlite import fetch_and_save_news
    await fetch_and_save_news()
    _news_cache.clear()

    return jsonify({"status": "refreshed"})


@app.route("/api/news/repair", methods=["POST"])
async def repair_news():
    """Manually trigger repair of corrupted MyMemory translations. Requires API key."""
    enforce_api_auth()
    await enforce_rate_limit()

    from news_sqlite import repair_all_bad_translations
    result = await repair_all_bad_translations(limit=500)
    _news_cache.clear()

    return jsonify({"status": "repair_complete", **result})


WAQI_TOKEN = os.getenv("WAQI_TOKEN", "demo")

# Reverse geocoding cache: {lat,lon: city_name}
_reverse_geo_cache = {}
_REVERSE_GEO_TTL = 3600  # 1 hour cache


async def reverse_geocode(lat: float, lon: float) -> str:
    """Get city name from coordinates using Nominatim (OpenStreetMap)."""
    key = f"{lat:.4f},{lon:.4f}"
    cached = _reverse_geo_cache.get(key)
    if cached and cached["expires"] > time.time():
        return cached["city"]

    try:
        url = "https://nominatim.openstreetmap.org/reverse"
        params = {
            "lat": lat, "lon": lon, "format": "json", "zoom": 10, "accept-language": "pt",
        }
        headers = {"User-Agent": "YvyApp/1.0 (environmental-monitoring)"}
        resp = await _http_client.get(url, params=params, headers=headers, timeout=5.0)
        data = resp.json()
        address = data.get("address", {})
        city = (
            address.get("city")
            or address.get("town")
            or address.get("village")
            or address.get("municipality")
            or address.get("state")
            or "Brasil"
        )
        _reverse_geo_cache[key] = {"city": city, "expires": time.time() + _REVERSE_GEO_TTL}
        return city
    except Exception:
        return "Brasil"


@app.route("/api/weather/air-quality")
async def get_air_quality():
    await enforce_rate_limit()
    lat = request.args.get("lat")
    lon = request.args.get("lon")
    station = request.args.get("station", "")

    cache_key = f"weather:aqi:{round(float(lat),1)}:{round(float(lon),1)}" if lat and lon else "weather:aqi:brasil"
    cached = await cache_get(cache_key)
    if cached:
        return current_app.response_class(cached, mimetype="application/json")

    if not station and lat and lon:
        station = f"@{lat},{lon}"
    elif not station:
        station = "brasilia"
    fallback = "brasilia"
    try:
        url = f"https://api.waqi.info/feed/{station}/?token={WAQI_TOKEN}"
        resp = await _http_client.get(url, timeout=10.0)
        data = resp.json()
        result = None
        if data.get("status") == "ok":
            d = data["data"]
            city = await reverse_geocode(float(lat), float(lon)) if lat and lon else "Brasil"
            result = {"aqi": d.get("aqi"), "pm25": d.get("iaqi", {}).get("pm25", {}).get("v"), "humidity": d.get("iaqi", {}).get("h", {}).get("v"), "city": city}
        elif station != fallback:
            resp2 = await _http_client.get(f"https://api.waqi.info/feed/{fallback}/?token={WAQI_TOKEN}", timeout=10.0)
            data2 = resp2.json()
            if data2.get("status") == "ok":
                d = data2["data"]
                city = await reverse_geocode(float(lat), float(lon)) if lat and lon else "Brasil"
                result = {"aqi": d.get("aqi"), "pm25": d.get("iaqi", {}).get("pm25", {}).get("v"), "humidity": d.get("iaqi", {}).get("h", {}).get("v"), "city": city}
        if result:
            body = json.dumps(result)
            await cache_set(cache_key, body, ttl=CACHE_TTL_WEATHER)
            return current_app.response_class(body, mimetype="application/json")
        return jsonify({"aqi": None})
    except Exception:
        return jsonify({"aqi": None})


@app.route("/api/weather/temperature")
async def get_temperature():
    await enforce_rate_limit()
    lat = request.args.get("lat", "-14.235")
    lon = request.args.get("lon", "-51.925")

    cache_key = f"weather:temp:{round(float(lat),1)}:{round(float(lon),1)}"
    cached = await cache_get(cache_key)
    if cached:
        return current_app.response_class(cached, mimetype="application/json")

    url = (
        f"https://api.open-meteo.com/v1/forecast"
        f"?latitude={lat}&longitude={lon}"
        f"&current=temperature_2m,relative_humidity_2m,apparent_temperature,wind_speed_10m,wind_direction_10m"
        f"&wind_speed_unit=kmh&timezone=America/Sao_Paulo"
    )
    try:
        resp = await _http_client.get(url, timeout=10.0)
        data = resp.json()
        current = data.get("current", {})
        if current:
            city = await reverse_geocode(float(lat), float(lon))
            result = {
                "temp": current.get("temperature_2m"),
                "feels_like": current.get("apparent_temperature"),
                "humidity": current.get("relative_humidity_2m"),
                "wind_speed": current.get("wind_speed_10m"),
                "wind_direction": current.get("wind_direction_10m"),
                "city": city,
            }
            body = json.dumps(result)
            await cache_set(cache_key, body, ttl=CACHE_TTL_WEATHER)
            return current_app.response_class(body, mimetype="application/json")
        return jsonify({"temp": None})
    except Exception:
        return jsonify({"temp": None})


@app.route("/api/indigenous-lands")
async def get_indigenous_lands():
    await enforce_rate_limit()
    return current_app.response_class(_INDIGENOUS_DATA, mimetype="application/json")


@app.route("/api/conservation-units")
async def get_conservation_units():
    await enforce_rate_limit()
    return current_app.response_class(_CONSERVATION_DATA, mimetype="application/json")


@app.errorhandler(Exception)
async def handle_exception(error):
    logger.error("Unhandled exception.", extra={"event": "unhandled_exception", "details": {"error": str(error)}}, exc_info=True)
    return jsonify({"error": "Internal server error"}), 500


@app.route("/api/data")
async def get_data():
    enforce_api_auth()
    await enforce_rate_limit()

    ne_lat = request.args.get("ne_lat")
    ne_lng = request.args.get("ne_lng")
    sw_lat = request.args.get("sw_lat")
    sw_lng = request.args.get("sw_lng")

    if ne_lat and ne_lng and sw_lat and sw_lng:
        try:
            ne_lat = float(ne_lat)
            ne_lng = float(ne_lng)
            sw_lat = float(sw_lat)
            sw_lng = float(sw_lng)
        except (TypeError, ValueError):
            abort(400, description="Invalid coordinates.")
        if ne_lat <= sw_lat or ne_lng <= sw_lng:
            abort(400, description="Invalid bbox.")
        validate_coordinate("ne_lat", ne_lat, -90.0, 90.0)
        validate_coordinate("sw_lat", sw_lat, -90.0, 90.0)
        validate_coordinate("ne_lng", ne_lng, -180.0, 180.0)
        validate_coordinate("sw_lng", sw_lng, -180.0, 180.0)
        clamped_bbox = clamp_bbox_to_brazil(ne_lat, ne_lng, sw_lat, sw_lng)
        if clamped_bbox is None:
            return jsonify([])
        ne_lat, ne_lng, sw_lat, sw_lng = clamped_bbox
    else:
        sw_lat, ne_lat, sw_lng, ne_lng = -90.0, 90.0, -180.0, 180.0

    data_cache_key = f"data:{round(sw_lat,1)}:{round(ne_lat,1)}:{round(sw_lng,1)}:{round(ne_lng,1)}"
    cached_data = await cache_get(data_cache_key)
    if cached_data:
        return current_app.response_class(cached_data, mimetype="application/json")

    data = await db_sqlite.find_deforestation(sw_lat, ne_lat, sw_lng, ne_lng, limit=MAX_RESULTS)
    records_list = [{
        "name": item["name"],
        "lat": item["lat"],
        "lon": item["lon"],
        "color": item["color"],
        "clazz": item.get("clazz", "Desmatamento"),
        "periods": item.get("periods", "N/A"),
        "source": item.get("source", "TerraBrasilis"),
        "timestamp": item.get("timestamp", ""),
    } for item in data]
    body = json.dumps(records_list)
    await cache_set(data_cache_key, body, ttl=CACHE_TTL_DATA)
    return current_app.response_class(body, mimetype="application/json")


def _shutdown_handler(signum, frame):
    logger.info("Received shutdown signal (%s). Exiting gracefully...", signum, extra={"event": "shutdown_signal", "details": {"signal": signum}})
    sys.exit(0)


if __name__ == "__main__":
    import signal
    signal.signal(signal.SIGTERM, _shutdown_handler)
    signal.signal(signal.SIGINT, _shutdown_handler)
    if os.getenv("DEV", "0") == "1":
        app.run(host="0.0.0.0", port=5000)
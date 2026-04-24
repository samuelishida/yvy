# Frontend (Flask App) - app_frontend.py
import datetime
import json
import logging
import os
import sys
import time
from contextlib import suppress

from dotenv import load_dotenv
import requests
from flask import Flask, has_request_context, jsonify, render_template, request

load_dotenv()

# Configurações do backend (base URL)
BACKEND_URL = os.getenv("BACKEND_URL", "http://backend:5000")
DEFAULT_DASHBOARD_BOUNDS = {
    "ne_lat": -10.0,
    "ne_lng": -34.0,
    "sw_lat": -34.0,
    "sw_lng": -74.0,
}
DEFAULT_MAP_BOUNDS = {
    "ne_lat": -15.0,
    "ne_lng": -47.0,
    "sw_lat": -16.0,
    "sw_lng": -48.0,
}
API_KEY = os.getenv("API_KEY", "").strip()


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
        if hasattr(record, "details"):
            payload["details"] = record.details
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


logger = configure_logger("yvy.frontend")


def build_security_headers():
    return {
        "X-Content-Type-Options": "nosniff",
        "X-Frame-Options": "DENY",
        "Referrer-Policy": "strict-origin-when-cross-origin",
        "Permissions-Policy": "geolocation=(), microphone=(), camera=()",
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


def build_backend_headers():
    headers = {}
    if API_KEY:
        headers["X-API-Key"] = API_KEY

    if has_request_context():
        headers["X-Forwarded-For"] = request.headers.get("X-Forwarded-For", request.remote_addr or "")

    return headers


def fetch_backend_data(params):
    response = requests.get(
        f"{BACKEND_URL}/data",
        params=params,
        headers=build_backend_headers(),
        timeout=15,
    )
    response.raise_for_status()
    return response.json()


def enrich_map_point(item):
    timestamp = item.get("timestamp")
    display_color = item.get("color", "#308703")
    heat_weight = 0.5

    if timestamp:
        try:
            year = datetime.datetime.fromisoformat(timestamp).year
            if year >= 2020:
                display_color = "orange"
                heat_weight = 0.8
            elif 2010 <= year < 2020:
                display_color = "yellow"
                heat_weight = 0.6
            elif 2000 <= year < 2010:
                display_color = "green"
                heat_weight = 0.4
            else:
                display_color = "darkgreen"
                heat_weight = 0.2
        except ValueError:
            logger.warning(
                "Invalid timestamp received for map point.",
                extra={"event": "map_point_invalid_timestamp", "details": {"timestamp": timestamp}},
            )

    enriched = dict(item)
    enriched["display_color"] = display_color
    enriched["heat_weight"] = heat_weight
    return enriched


# Configuração do Flask
app = Flask(__name__)


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
        "Handled frontend request.",
        extra={
            "event": "http_request",
            "path": request.path,
            "status_code": response.status_code,
            "details": {
                "method": request.method,
                "duration_ms": duration_ms,
            },
        },
    )
    return response


@app.route('/health')
def health():
    return jsonify({"status": "healthy", "timestamp": datetime.datetime.now(datetime.UTC).isoformat()})

@app.route('/')
def home():
    return render_template('index.html')

@app.route('/dashboard')
def dashboard():
    try:
        data = fetch_backend_data(DEFAULT_DASHBOARD_BOUNDS)
    except requests.exceptions.RequestException as error:
        logger.warning(
            "Failed to fetch dashboard data from backend.",
            extra={"event": "dashboard_fetch_failed", "details": {"error": str(error)}},
        )
        data = []

    return render_template('dashboard.html', data=data)


@app.route('/api/data')
def proxy_data():
    params = {
        key: request.args.get(key)
        for key in ("ne_lat", "ne_lng", "sw_lat", "sw_lng")
        if request.args.get(key) is not None
    }

    try:
        return jsonify(fetch_backend_data(params))
    except requests.exceptions.HTTPError as error:
        response = error.response
        status_code = response.status_code if response is not None else 502
        if response is not None:
            try:
                payload = response.json()
            except ValueError:
                payload = {"error": "Bad gateway", "message": response.text}
        else:
            payload = {"error": "Bad gateway", "message": str(error)}
        logger.warning(
            "Backend rejected proxied data request.",
            extra={"event": "proxy_data_failed", "status_code": status_code, "path": request.path},
        )
        return jsonify(payload), status_code
    except requests.exceptions.RequestException as error:
        logger.error(
            "Could not connect to backend for proxied data request.",
            extra={
                "event": "proxy_backend_unavailable",
                "status_code": 502,
                "path": request.path,
                "details": {"error": str(error)},
            },
        )
        return jsonify({"error": "Bad gateway", "message": "Could not reach the backend service."}), 502


@app.route('/map')
def map_view():
    initial_data = []
    map_error = None

    try:
        initial_data = [enrich_map_point(item) for item in fetch_backend_data(DEFAULT_MAP_BOUNDS)]
    except requests.exceptions.RequestException as error:
        logger.warning(
            "Failed to fetch initial map data from backend.",
            extra={"event": "map_fetch_failed", "details": {"error": str(error)}},
        )
        map_error = "Nao foi possivel carregar os dados iniciais do mapa."

    return render_template('map.html', initial_data=initial_data, map_error=map_error)


@app.errorhandler(404)
def not_found(_error):
    return render_template('error.html', code=404, title="Pagina nao encontrada", message="A rota solicitada nao existe."), 404


@app.errorhandler(500)
def internal_error(_error):
    return render_template('error.html', code=500, title="Erro interno", message="Ocorreu um erro inesperado."), 500


if __name__ == "__main__":
    app.run(host='0.0.0.0', port=5001)

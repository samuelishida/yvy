import os
import sys

import pytest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import frontend as fe


@pytest.fixture()
def client():
    fe.app.config["TESTING"] = True
    return fe.app.test_client()


def test_health_returns_200(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.get_json()["status"] == "healthy"


def test_home_returns_200(client):
    response = client.get("/")
    assert response.status_code == 200
    assert b"Bem-vindo" in response.data


def test_security_headers_present(client):
    response = client.get("/")
    assert response.headers["X-Content-Type-Options"] == "nosniff"
    assert response.headers["X-Frame-Options"] == "DENY"
    assert "default-src" in response.headers["Content-Security-Policy"]


def test_404_uses_custom_error_page(client):
    response = client.get("/does-not-exist")
    assert response.status_code == 404
    assert b"404" in response.data


def test_dashboard_renders_when_backend_unavailable(client, monkeypatch):
    def _raise(*_args, **_kwargs):
        raise fe.requests.exceptions.RequestException("backend unavailable")

    monkeypatch.setattr(fe, "fetch_backend_data", _raise)
    response = client.get("/dashboard")
    assert response.status_code == 200
    assert b"Dados de Desmatamento" in response.data


def test_map_renders_bootstrapped_points(client, monkeypatch):
    monkeypatch.setattr(
        fe,
        "fetch_backend_data",
        lambda *_args, **_kwargs: [
            {
                "name": "Ponto de teste",
                "lat": -15.5,
                "lon": -47.5,
                "color": "#ff9600",
                "clazz": "Desmatamento",
                "source": "TerraBrasilis",
                "timestamp": "2023-01-01T00:00:00",
            }
        ],
    )
    response = client.get("/map")
    assert response.status_code == 200
    assert b"Ponto de teste" in response.data

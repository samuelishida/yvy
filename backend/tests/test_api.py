import os
import sys
import datetime
import asyncio
import mongomock
import pytest
import pytest_asyncio

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import backend as bk


@pytest.fixture(autouse=True)
def reset_db():
    client = mongomock.MongoClient()
    bk.mongo_db = type("DB", (), {})()
    bk.mongo_db.deforestation_data = client["terrabrasilis_data"]["deforestation_data"]
    bk.mongo_db.news = client["terrabrasilis_data"]["news"]
    bk.mongo_db.fire_data = client["terrabrasilis_data"]["fire_data"]
    previous_auth_required = bk.AUTH_REQUIRED
    previous_api_key = bk.API_KEY
    previous_rate_limit_requests = bk.RATE_LIMIT_REQUESTS
    previous_rate_limit_window = bk.RATE_LIMIT_WINDOW_SECONDS
    previous_max_results = bk.MAX_RESULTS
    bk.AUTH_REQUIRED = False
    bk.API_KEY = "test-api-key"
    bk.RATE_LIMIT_REQUESTS = 60
    bk.RATE_LIMIT_WINDOW_SECONDS = 60
    bk.MAX_RESULTS = 1000
    bk._RATE_LIMIT_BUCKETS.clear()
    yield
    bk.AUTH_REQUIRED = previous_auth_required
    bk.API_KEY = previous_api_key
    bk.RATE_LIMIT_REQUESTS = previous_rate_limit_requests
    bk.RATE_LIMIT_WINDOW_SECONDS = previous_rate_limit_window
    bk.MAX_RESULTS = previous_max_results
    bk._RATE_LIMIT_BUCKETS.clear()
    client.close()


@pytest_asyncio.fixture
async def api():
    bk.app.config["TESTING"] = True
    async with bk.app.test_client() as client:
        yield client


def _insert_doc(lat, lon, name="test-area", color="#000000", days_ago=0):
    ts = datetime.datetime.now(datetime.UTC) - datetime.timedelta(days=days_ago)
    bk.mongo_db.deforestation_data.insert_one({
        "name": name, "lat": lat, "lon": lon,
        "color": color, "timestamp": ts,
    })


class TestHome:
    @pytest.mark.asyncio
    async def test_returns_200(self, api):
        resp = await api.get("/")
        assert resp.status_code == 200

    @pytest.mark.asyncio
    async def test_response_is_json(self, api):
        resp = await api.get("/")
        assert resp.content_type.startswith("application/json")

    @pytest.mark.asyncio
    async def test_response_has_message(self, api):
        data = await api.get("/")
        body = await data.get_json()
        assert isinstance(body, dict)
        assert "message" in body

    @pytest.mark.asyncio
    async def test_security_headers_present(self, api):
        resp = await api.get("/")
        assert resp.headers.get("X-Content-Type-Options") == "nosniff"
        assert resp.headers.get("X-Frame-Options") == "DENY"
        assert "default-src" in resp.headers.get("Content-Security-Policy", "")


class TestDataValidation:
    @pytest.mark.asyncio
    async def test_missing_all_params_returns_400(self, api):
        resp = await api.get("/api/data")
        assert resp.status_code == 400

    @pytest.mark.asyncio
    async def test_missing_single_param_returns_400(self, api):
        resp = await api.get("/api/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0")
        assert resp.status_code == 400

    @pytest.mark.asyncio
    async def test_non_numeric_param_returns_400(self, api):
        resp = await api.get("/api/data?ne_lat=abc&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0")
        assert resp.status_code == 400

    @pytest.mark.asyncio
    async def test_empty_bbox_returns_empty_list(self, api):
        resp = await api.get("/api/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0")
        assert resp.status_code == 200
        body = await resp.get_json()
        assert body == []


class TestDataQuery:
    @pytest.mark.asyncio
    async def test_returns_doc_inside_bbox(self, api):
        _insert_doc(lat=-15.5, lon=-47.5)
        resp = await api.get("/api/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0")
        assert resp.status_code == 200
        items = await resp.get_json()
        assert isinstance(items, list)
        assert len(items) == 1
        assert items[0]["name"] == "test-area"

    @pytest.mark.asyncio
    async def test_excludes_doc_outside_bbox(self, api):
        _insert_doc(lat=-10.0, lon=-40.0)
        resp = await api.get("/api/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0")
        body = await resp.get_json()
        assert body == []

    @pytest.mark.asyncio
    async def test_response_shape(self, api):
        _insert_doc(lat=-15.5, lon=-47.5, color="#FF0000")
        resp = await api.get("/api/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0")
        items = await resp.get_json()
        item = items[0]
        assert set(item.keys()) == {"name", "lat", "lon", "color", "clazz", "periods", "source", "timestamp"}
        assert item["lat"] == -15.5
        assert item["lon"] == -47.5
        assert item["color"] == "#FF0000"

    @pytest.mark.asyncio
    async def test_timestamp_is_iso_string(self, api):
        _insert_doc(lat=-15.5, lon=-47.5)
        resp = await api.get("/api/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0")
        items = await resp.get_json()
        datetime.datetime.fromisoformat(items[0]["timestamp"])

    @pytest.mark.asyncio
    async def test_multiple_docs_all_returned(self, api):
        for i in range(5):
            _insert_doc(lat=-15.5 - i * 0.05, lon=-47.5, name=f"area-{i}")
        resp = await api.get("/api/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0")
        items = await resp.get_json()
        assert len(items) == 5

    @pytest.mark.asyncio
    async def test_only_docs_inside_bbox_returned(self, api):
        _insert_doc(lat=-15.5, lon=-47.5, name="inside")
        _insert_doc(lat=-10.0, lon=-40.0, name="outside")
        resp = await api.get("/api/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0")
        items = await resp.get_json()
        names = [i["name"] for i in items]
        assert "inside" in names
        assert "outside" not in names

    @pytest.mark.asyncio
    async def test_boundary_coords_included(self, api):
        _insert_doc(lat=-15.0, lon=-47.0, name="ne-corner")
        _insert_doc(lat=-16.0, lon=-48.0, name="sw-corner")
        resp = await api.get("/api/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0")
        items = await resp.get_json()
        names = [i["name"] for i in items]
        assert "ne-corner" in names
        assert "sw-corner" in names

    @pytest.mark.asyncio
    async def test_limit_not_exceeded(self, api):
        for i in range(1005):
            _insert_doc(lat=-15.5, lon=-47.5 - i * 0.0001, name=f"area-{i}")
        resp = await api.get("/api/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-50.0")
        items = await resp.get_json()
        assert len(items) <= 1000

    @pytest.mark.asyncio
    async def test_bbox_clamp_does_not_expand_query(self, api):
        _insert_doc(lat=-15.5, lon=-47.5, name="inside")
        _insert_doc(lat=-15.5, lon=-60.0, name="outside")
        resp = await api.get("/api/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0")
        items = await resp.get_json()
        names = [i["name"] for i in items]
        assert "inside" in names
        assert "outside" not in names


class TestDataSecurity:
    @pytest.mark.asyncio
    async def test_missing_api_key_returns_401(self, api):
        bk.AUTH_REQUIRED = True
        resp = await api.get("/api/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0")
        assert resp.status_code == 401

    @pytest.mark.asyncio
    async def test_valid_api_key_returns_200(self, api):
        bk.AUTH_REQUIRED = True
        _insert_doc(lat=-15.5, lon=-47.5)
        resp = await api.get(
            "/api/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0",
            headers={"X-API-Key": "test-api-key"},
        )
        assert resp.status_code == 200

    @pytest.mark.asyncio
    async def test_rate_limit_returns_429(self, api):
        bk.RATE_LIMIT_REQUESTS = 1
        bk.RATE_LIMIT_WINDOW_SECONDS = 60
        first = await api.get("/api/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0")
        second = await api.get("/api/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0")
        assert first.status_code == 200
        assert second.status_code == 429


class TestNews:
    @pytest.mark.asyncio
    async def test_get_news_without_auth_when_required_returns_401(self, api):
        bk.AUTH_REQUIRED = True
        resp = await api.get("/api/news")
        assert resp.status_code == 401

    @pytest.mark.asyncio
    async def test_get_news_with_valid_api_key_returns_200(self, api):
        bk.AUTH_REQUIRED = True
        resp = await api.get(
            "/api/news",
            headers={"X-API-Key": "test-api-key"},
        )
        assert resp.status_code == 200
        assert resp.content_type.startswith("application/json")

    @pytest.mark.asyncio
    async def test_refresh_news_without_auth_when_required_returns_401(self, api):
        bk.AUTH_REQUIRED = True
        resp = await api.post("/api/news/refresh")
        assert resp.status_code == 401

    @pytest.mark.asyncio
    async def test_refresh_news_with_valid_api_key_returns_200(self, api):
        bk.AUTH_REQUIRED = True
        resp = await api.post(
            "/api/news/refresh",
            headers={"X-API-Key": "test-api-key"},
        )
        assert resp.status_code == 200

    @pytest.mark.asyncio
    async def test_get_news_invalid_page_returns_400(self, api):
        resp = await api.get("/api/news?page=abc")
        assert resp.status_code == 400

    @pytest.mark.asyncio
    async def test_get_news_negative_page_returns_400(self, api):
        resp = await api.get("/api/news?page=-1")
        assert resp.status_code == 400

    @pytest.mark.asyncio
    async def test_get_news_large_page_size_returns_400(self, api):
        resp = await api.get("/api/news?page_size=200")
        assert resp.status_code == 400


class TestBatchingHelpers:
    def test_split_into_batches_handles_small_input(self):
        batches = bk.split_into_batches([1, 2], 8)
        assert batches == [[1], [2]]

    def test_split_into_batches_keeps_all_items(self):
        batches = bk.split_into_batches(list(range(5)), 2)
        flattened = [item for batch in batches for item in batch]
        assert flattened == [0, 1, 2, 3, 4]


def _insert_fire(lat, lon, confidence="nominal", acq_date="2025-01-15", satellite="N", bright_ti4=330.0):
    bk.mongo_db.fire_data.insert_one({
        "lat": lat,
        "lon": lon,
        "confidence": confidence,
        "acq_date": acq_date,
        "acq_time": "1200",
        "satellite": satellite,
        "bright_ti4": bright_ti4,
        "source": "NASA_FIRMS_VIIRS_SNPP",
        "ingested_at": datetime.datetime.now(datetime.UTC),
    })


class TestFiresGet:
    @pytest.mark.asyncio
    async def test_empty_fires_returns_empty_list(self, api):
        resp = await api.get("/api/fires?ne_lat=5.5&ne_lng=-34&sw_lat=-34&sw_lng=-74")
        assert resp.status_code == 200
        body = await resp.get_json()
        assert body["fires"] == []
        assert body["count"] == 0

    @pytest.mark.asyncio
    async def test_returns_fires_inside_bbox(self, api):
        _insert_fire(lat=-15.5, lon=-47.5)
        resp = await api.get("/api/fires?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0")
        assert resp.status_code == 200
        body = await resp.get_json()
        assert body["count"] == 1
        assert body["fires"][0]["lat"] == -15.5
        assert body["fires"][0]["lon"] == -47.5
        assert body["fires"][0]["confidence"] == "nominal"

    @pytest.mark.asyncio
    async def test_excludes_fires_outside_bbox(self, api):
        _insert_fire(lat=-10.0, lon=-40.0)
        resp = await api.get("/api/fires?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0")
        body = await resp.get_json()
        assert body["count"] == 0

    @pytest.mark.asyncio
    async def test_fire_response_shape(self, api):
        _insert_fire(lat=-15.5, lon=-47.5, confidence="high", bright_ti4=340.5)
        resp = await api.get("/api/fires?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0")
        body = await resp.get_json()
        fire = body["fires"][0]
        expected_keys = {"lat", "lon", "confidence", "acq_date", "acq_time", "satellite", "bright_ti4"}
        assert set(fire.keys()) == expected_keys
        assert fire["confidence"] == "high"
        assert fire["bright_ti4"] == 340.5

    @pytest.mark.asyncio
    async def test_multiple_confidence_levels(self, api):
        _insert_fire(lat=-15.5, lon=-47.5, confidence="nominal")
        _insert_fire(lat=-15.6, lon=-47.6, confidence="low")
        _insert_fire(lat=-15.7, lon=-47.7, confidence="high")
        resp = await api.get("/api/fires?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0")
        body = await resp.get_json()
        assert body["count"] == 3
        confidences = {f["confidence"] for f in body["fires"]}
        assert confidences == {"nominal", "low", "high"}

    @pytest.mark.asyncio
    async def test_default_bbox_returns_fires(self, api):
        _insert_fire(lat=-15.5, lon=-47.5)
        resp = await api.get("/api/fires")
        body = await resp.get_json()
        assert body["count"] == 1

    @pytest.mark.asyncio
    async def test_invalid_params_returns_400(self, api):
        resp = await api.get("/api/fires?ne_lat=abc&ne_lng=-47&sw_lat=-16&sw_lng=-48")
        assert resp.status_code == 400

    @pytest.mark.asyncio
    async def test_limit_respected(self, api):
        for i in range(1005):
            _insert_fire(lat=-15.5, lon=-47.5 - i * 0.0001)
        resp = await api.get("/api/fires?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-50.0")
        body = await resp.get_json()
        assert body["count"] <= 1000


class TestFiresGetSecurity:
    @pytest.mark.asyncio
    async def test_missing_api_key_returns_401(self, api):
        bk.AUTH_REQUIRED = True
        resp = await api.get("/api/fires?ne_lat=5.5&ne_lng=-34&sw_lat=-34&sw_lng=-74")
        assert resp.status_code == 401

    @pytest.mark.asyncio
    async def test_valid_api_key_returns_200(self, api):
        bk.AUTH_REQUIRED = True
        _insert_fire(lat=-15.5, lon=-47.5)
        resp = await api.get(
            "/api/fires?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0",
            headers={"X-API-Key": "test-api-key"},
        )
        assert resp.status_code == 200


class TestFiresSync:
    @pytest.mark.asyncio
    async def test_sync_without_api_key_returns_401(self, api):
        bk.AUTH_REQUIRED = True
        resp = await api.post("/api/fires/sync")
        assert resp.status_code == 401

    @pytest.mark.asyncio
    async def test_sync_without_firms_key_returns_empty(self, api):
        previous_firms_key = bk.FIRMS_MAP_KEY
        bk.FIRMS_MAP_KEY = ""
        resp = await api.post("/api/fires/sync", headers={"X-API-Key": "test-api-key"})
        assert resp.status_code == 200
        body = await resp.get_json()
        assert body["status"] == "synced"
        assert body["records"] == 0
        bk.FIRMS_MAP_KEY = previous_firms_key


class TestFireConstants:
    def test_firms_sync_interval_is_24h(self):
        assert bk.FIRMS_SYNC_INTERVAL_HOURS == 24
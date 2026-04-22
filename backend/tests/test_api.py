import os
import sys
import datetime
import mongomock
import pytest

# Ensure the backend module (backend.py) in the parent folder is importable when pytest
# is run from the tests directory or project root.
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import backend as bk


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def reset_db():
    """Create a fresh in-memory MongoDB for every test."""
    client = mongomock.MongoClient()
    bk.mongo = type('M', (), {})()
    bk.mongo.db = client['terrabrasilis_data']
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


@pytest.fixture()
def api():
    bk.app.config['TESTING'] = True
    return bk.app.test_client()


def _insert_doc(lat, lon, name='test-area', color='#000000', days_ago=0):
    ts = datetime.datetime.now(datetime.UTC) - datetime.timedelta(days=days_ago)
    bk.mongo.db.deforestation_data.insert_one({
        'name': name, 'lat': lat, 'lon': lon,
        'color': color, 'timestamp': ts,
    })


# ---------------------------------------------------------------------------
# Home endpoint
# ---------------------------------------------------------------------------

class TestHome:
    def test_returns_200(self, api):
        resp = api.get('/')
        assert resp.status_code == 200

    def test_response_is_json(self, api):
        resp = api.get('/')
        assert resp.content_type.startswith('application/json')

    def test_response_has_message(self, api):
        data = api.get('/').get_json()
        assert isinstance(data, dict)
        assert 'message' in data

    def test_security_headers_present(self, api):
        resp = api.get('/')
        assert resp.headers['X-Content-Type-Options'] == 'nosniff'
        assert resp.headers['X-Frame-Options'] == 'DENY'
        assert 'default-src' in resp.headers['Content-Security-Policy']


# ---------------------------------------------------------------------------
# /data — validation
# ---------------------------------------------------------------------------

class TestDataValidation:
    def test_missing_all_params_returns_400(self, api):
        assert api.get('/data').status_code == 400

    def test_missing_single_param_returns_400(self, api):
        assert api.get('/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0').status_code == 400

    def test_non_numeric_param_returns_400(self, api):
        assert api.get('/data?ne_lat=abc&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0').status_code == 400

    def test_empty_bbox_returns_empty_list(self, api):
        resp = api.get('/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0')
        assert resp.status_code == 200
        assert resp.get_json() == []


# ---------------------------------------------------------------------------
# /data — query results
# ---------------------------------------------------------------------------

class TestDataQuery:
    def test_returns_doc_inside_bbox(self, api):
        _insert_doc(lat=-15.5, lon=-47.5)
        resp = api.get('/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0')
        assert resp.status_code == 200
        items = resp.get_json()
        assert isinstance(items, list)
        assert len(items) == 1
        assert items[0]['name'] == 'test-area'

    def test_excludes_doc_outside_bbox(self, api):
        _insert_doc(lat=-10.0, lon=-40.0)  # outside [-16, -15] x [-48, -47]
        resp = api.get('/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0')
        assert resp.get_json() == []

    def test_response_shape(self, api):
        _insert_doc(lat=-15.5, lon=-47.5, color='#FF0000')
        item = api.get('/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0').get_json()[0]
        assert set(item.keys()) == {'name', 'lat', 'lon', 'color', 'clazz', 'periods', 'source', 'timestamp'}
        assert item['lat'] == -15.5
        assert item['lon'] == -47.5
        assert item['color'] == '#FF0000'

    def test_timestamp_is_iso_string(self, api):
        _insert_doc(lat=-15.5, lon=-47.5)
        item = api.get('/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0').get_json()[0]
        # Should parse without raising
        datetime.datetime.fromisoformat(item['timestamp'])

    def test_multiple_docs_all_returned(self, api):
        for i in range(5):
            _insert_doc(lat=-15.5 - i * 0.05, lon=-47.5, name=f'area-{i}')
        items = api.get('/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0').get_json()
        assert len(items) == 5

    def test_only_docs_inside_bbox_returned(self, api):
        _insert_doc(lat=-15.5, lon=-47.5, name='inside')
        _insert_doc(lat=-10.0, lon=-40.0, name='outside')
        items = api.get('/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0').get_json()
        names = [i['name'] for i in items]
        assert 'inside' in names
        assert 'outside' not in names

    def test_boundary_coords_included(self, api):
        # Docs exactly on bbox boundary should be included
        _insert_doc(lat=-15.0, lon=-47.0, name='ne-corner')
        _insert_doc(lat=-16.0, lon=-48.0, name='sw-corner')
        items = api.get('/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0').get_json()
        names = [i['name'] for i in items]
        assert 'ne-corner' in names
        assert 'sw-corner' in names

    def test_limit_not_exceeded(self, api):
        for i in range(1005):
            _insert_doc(lat=-15.5, lon=-47.5 - i * 0.0001, name=f'area-{i}')
        items = api.get('/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-50.0').get_json()
        assert len(items) <= 1000

    def test_bbox_clamp_does_not_expand_query(self, api):
        _insert_doc(lat=-15.5, lon=-47.5, name='inside')
        _insert_doc(lat=-15.5, lon=-60.0, name='outside')
        items = api.get('/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0').get_json()
        names = [i['name'] for i in items]
        assert 'inside' in names
        assert 'outside' not in names


class TestDataSecurity:
    def test_missing_api_key_returns_401(self, api):
        bk.AUTH_REQUIRED = True
        resp = api.get('/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0')
        assert resp.status_code == 401

    def test_valid_api_key_returns_200(self, api):
        bk.AUTH_REQUIRED = True
        _insert_doc(lat=-15.5, lon=-47.5)
        resp = api.get(
            '/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0',
            headers={'X-API-Key': 'test-api-key'},
        )
        assert resp.status_code == 200

    def test_rate_limit_returns_429(self, api):
        bk.RATE_LIMIT_REQUESTS = 1
        bk.RATE_LIMIT_WINDOW_SECONDS = 60
        first = api.get('/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0')
        second = api.get('/data?ne_lat=-15.0&ne_lng=-47.0&sw_lat=-16.0&sw_lng=-48.0')
        assert first.status_code == 200
        assert second.status_code == 429


class TestBatchingHelpers:
    def test_split_into_batches_handles_small_input(self):
        batches = bk.split_into_batches([1, 2], 8)
        assert batches == [[1], [2]]

    def test_split_into_batches_keeps_all_items(self):
        batches = bk.split_into_batches(list(range(5)), 2)
        flattened = [item for batch in batches for item in batch]
        assert flattened == [0, 1, 2, 3, 4]

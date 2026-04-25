"""Unit tests for db_sqlite.py."""
import asyncio
import os
import tempfile
from datetime import datetime, timezone

import pytest

import db_sqlite


@pytest.fixture
def tmp_db_path():
    with tempfile.TemporaryDirectory() as tmpdir:
        path = os.path.join(tmpdir, "test.db")
        old_path = db_sqlite.DB_PATH
        db_sqlite.DB_PATH = path
        db_sqlite._pool = None
        yield path
        db_sqlite.DB_PATH = old_path
        db_sqlite._pool = None


@pytest.fixture
async def db(tmp_db_path):
    await db_sqlite.init_db()
    yield
    await db_sqlite.close_db()


@pytest.mark.asyncio
async def test_init_db_creates_tables(db):
    async with db_sqlite._get_conn() as conn:
        cursor = await conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        )
        tables = {row[0] for row in await cursor.fetchall()}
    assert "fire_data" in tables
    assert "deforestation_data" in tables
    assert "news" in tables


@pytest.mark.asyncio
async def test_bulk_upsert_and_find_fires(db):
    docs = [
        {
            "lat": -10.5,
            "lon": -55.0,
            "confidence": "high",
            "acq_date": "2024-01-01",
            "acq_time": "12:00",
            "satellite": "NPP",
            "bright_ti4": 350.0,
            "source": "NASA_FIRMS_VIIRS_SNPP",
            "ingested_at": datetime.now(timezone.utc).isoformat(),
        },
        {
            "lat": -11.0,
            "lon": -56.0,
            "confidence": "low",
            "acq_date": "2024-01-02",
            "acq_time": "13:00",
            "satellite": "NPP",
            "bright_ti4": 300.0,
            "source": "NASA_FIRMS_VIIRS_SNPP",
            "ingested_at": datetime.now(timezone.utc).isoformat(),
        },
    ]
    count = await db_sqlite.bulk_upsert_fires(docs)
    assert count == 2

    results = await db_sqlite.find_fires(-12, -10, -57, -54)
    assert len(results) == 2
    lats = {r["lat"] for r in results}
    assert -10.5 in lats
    assert -11.0 in lats


@pytest.mark.asyncio
async def test_find_fires_with_bbox_filter(db):
    docs = [
        {
            "lat": -10.0,
            "lon": -50.0,
            "confidence": "high",
            "acq_date": "2024-01-01",
            "acq_time": "12:00",
            "satellite": "NPP",
            "bright_ti4": 350.0,
            "source": "NASA_FIRMS_VIIRS_SNPP",
            "ingested_at": datetime.now(timezone.utc).isoformat(),
        },
    ]
    await db_sqlite.bulk_upsert_fires(docs)

    results = await db_sqlite.find_fires(-12, -11, -51, -49)
    assert len(results) == 0

    results = await db_sqlite.find_fires(-11, -9, -51, -49)
    assert len(results) == 1


@pytest.mark.asyncio
async def test_prune_old_fires(db):
    old = datetime(2023, 1, 1, tzinfo=timezone.utc).isoformat()
    new = datetime.now(timezone.utc).isoformat()
    docs = [
        {
            "lat": -10.0,
            "lon": -50.0,
            "confidence": "high",
            "acq_date": "2023-01-01",
            "acq_time": "12:00",
            "satellite": "NPP",
            "bright_ti4": 350.0,
            "source": "NASA_FIRMS_VIIRS_SNPP",
            "ingested_at": old,
        },
        {
            "lat": -11.0,
            "lon": -51.0,
            "confidence": "high",
            "acq_date": "2024-06-01",
            "acq_time": "12:00",
            "satellite": "NPP",
            "bright_ti4": 350.0,
            "source": "NASA_FIRMS_VIIRS_SNPP",
            "ingested_at": new,
        },
    ]
    await db_sqlite.bulk_upsert_fires(docs)
    deleted = await db_sqlite.prune_old_fires(days=365)
    assert deleted == 1

    results = await db_sqlite.find_fires(-12, -9, -52, -49)
    assert len(results) == 1
    assert results[0]["lat"] == -11.0


@pytest.mark.asyncio
async def test_upsert_and_get_news(db):
    article = {
        "url": "https://example.com/news/1",
        "title": "Test News",
        "description": "A test article",
        "publishedAt": datetime.now(timezone.utc).isoformat(),
        "source_name": "Example",
        "urlToImage": "https://example.com/img.jpg",
        "content": "Full content here",
    }
    await db_sqlite.upsert_news(article)

    page = await db_sqlite.get_news_page(page=1, page_size=10)
    assert len(page) == 1
    assert page[0]["title"] == "Test News"


@pytest.mark.asyncio
async def test_has_recent_news(db):
    old = datetime(2023, 1, 1, tzinfo=timezone.utc).isoformat()
    article = {
        "url": "https://example.com/news/old",
        "title": "Old News",
        "description": "Old article",
        "publishedAt": old,
        "source_name": "Example",
    }
    await db_sqlite.upsert_news(article)
    assert await db_sqlite.has_recent_news(minutes=15) is False

    new_article = {
        "url": "https://example.com/news/new",
        "title": "New News",
        "description": "New article",
        "publishedAt": datetime.now(timezone.utc).isoformat(),
        "source_name": "Example",
    }
    await db_sqlite.upsert_news(new_article)
    assert await db_sqlite.has_recent_news(minutes=15) is True


@pytest.mark.asyncio
async def test_bulk_upsert_deforestation(db):
    docs = [
        {
            "name": "Amazonia",
            "clazz": "Desmatamento",
            "periods": "2024",
            "source": "TerraBrasilis",
            "color": "#FF0000",
            "lat": -10.0,
            "lon": -55.0,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        },
    ]
    count = await db_sqlite.bulk_upsert_deforestation(docs)
    assert count == 1

    results = await db_sqlite.find_deforestation(-11, -9, -56, -54)
    assert len(results) == 1
    assert results[0]["name"] == "Amazonia"


@pytest.mark.asyncio
async def test_get_stats(db):
    await db_sqlite.bulk_upsert_fires([
        {
            "lat": -10.0,
            "lon": -50.0,
            "confidence": "high",
            "acq_date": "2024-01-01",
            "acq_time": "12:00",
            "satellite": "NPP",
            "bright_ti4": 350.0,
            "source": "NASA_FIRMS_VIIRS_SNPP",
            "ingested_at": datetime.now(timezone.utc).isoformat(),
        },
    ])
    await db_sqlite.upsert_news({
        "url": "https://example.com/news/1",
        "title": "Test",
        "publishedAt": datetime.now(timezone.utc).isoformat(),
    })

    stats = await db_sqlite.get_stats()
    assert stats["fires"] == 1
    assert stats["deforestation"] == 0
    assert stats["news"] == 1

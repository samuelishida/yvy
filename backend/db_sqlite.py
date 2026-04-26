"""SQLite async database layer replacing MongoDB for Yvy backend.

Tables:
- fire_data: NASA FIRMS fire detections
- deforestation_data: TerraBrasilis PRODES points
- news: cached news articles
"""
from __future__ import annotations

import asyncio
import datetime
import json
import logging
import os
from contextlib import asynccontextmanager
from typing import Any

import aiosqlite

logger = logging.getLogger(__name__)

DB_PATH = os.getenv("SQLITE_PATH", os.path.join(os.path.dirname(__file__), "data", "yvy.db"))

# Schema ------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS fire_data (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    lat REAL NOT NULL,
    lon REAL NOT NULL,
    confidence TEXT,
    acq_date TEXT,
    acq_time TEXT,
    satellite TEXT,
    bright_ti4 REAL,
    source TEXT,
    ingested_at TEXT,
    UNIQUE(lat, lon, acq_date)
);

CREATE TABLE IF NOT EXISTS deforestation_data (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT,
    clazz TEXT DEFAULT 'Desmatamento',
    periods TEXT DEFAULT 'N/A',
    source TEXT DEFAULT 'TerraBrasilis',
    color TEXT,
    lat REAL,
    lon REAL,
    timestamp TEXT
);

CREATE TABLE IF NOT EXISTS news (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    url TEXT UNIQUE NOT NULL,
    title TEXT,
    description TEXT,
    title_en TEXT,
    description_en TEXT,
    publishedAt TEXT,
    source_name TEXT,
    urlToImage TEXT,
    content TEXT,
    ingested_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_fire_lat ON fire_data(lat);
CREATE INDEX IF NOT EXISTS idx_fire_lon ON fire_data(lon);
CREATE INDEX IF NOT EXISTS idx_fire_acq_date ON fire_data(acq_date);
CREATE INDEX IF NOT EXISTS idx_def_lat ON deforestation_data(lat);
CREATE INDEX IF NOT EXISTS idx_def_lon ON deforestation_data(lon);
CREATE INDEX IF NOT EXISTS idx_news_published ON news(publishedAt);
"""

_pool: asyncio.Queue[aiosqlite.Connection] | None = None
_pool_size = 5


async def _create_connection() -> aiosqlite.Connection:
    conn = await aiosqlite.connect(DB_PATH)
    conn.row_factory = aiosqlite.Row
    await conn.execute("PRAGMA journal_mode=WAL")
    await conn.execute("PRAGMA synchronous=NORMAL")
    await conn.execute("PRAGMA cache_size=-64000")  # 64MB
    await conn.execute("PRAGMA temp_store=MEMORY")
    return conn


async def _migrate_news_table() -> None:
    """Add missing columns and backfill defaults (SQLite migration)."""
    async with _get_conn() as conn:
        for col in ("title_en", "description_en", "ingested_at"):
            try:
                await conn.execute(f"ALTER TABLE news ADD COLUMN {col} TEXT")
                logger.info("Migration: added %s to news", col)
            except Exception:
                pass
        # Backfill ingested_at for existing rows so has_recent_news works
        try:
            await conn.execute("UPDATE news SET ingested_at = publishedAt WHERE ingested_at IS NULL AND publishedAt IS NOT NULL")
        except Exception:
            pass
        await conn.commit()


async def init_db() -> None:
    """Create tables and connection pool."""
    global _pool
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)

    # Run schema in single connection
    conn = await _create_connection()
    await conn.executescript(SCHEMA)
    await conn.commit()
    await conn.close()

    # Build pool
    _pool = asyncio.Queue(maxsize=_pool_size)
    for _ in range(_pool_size):
        await _pool.put(await _create_connection())
    logger.info("SQLite initialized at %s", DB_PATH)

    # Migrate existing tables
    await _migrate_news_table()


async def close_db() -> None:
    """Close all pooled connections."""
    global _pool
    if _pool is None:
        return
    while not _pool.empty():
        conn = await _pool.get()
        await conn.close()
    _pool = None


@asynccontextmanager
async def _get_conn():
    if _pool is None:
        raise RuntimeError("DB not initialized. Call init_db() first.")
    conn = await _pool.get()
    try:
        yield conn
    finally:
        await _pool.put(conn)


# Fire data ---------------------------------------------------------------

async def upsert_fire(doc: dict[str, Any]) -> None:
    async with _get_conn() as conn:
        await conn.execute(
            """
            INSERT INTO fire_data (lat, lon, confidence, acq_date, acq_time,
                                   satellite, bright_ti4, source, ingested_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(lat, lon, acq_date) DO UPDATE SET
                confidence=excluded.confidence,
                acq_time=excluded.acq_time,
                satellite=excluded.satellite,
                bright_ti4=excluded.bright_ti4,
                source=excluded.source,
                ingested_at=excluded.ingested_at
            """,
            (
                doc["lat"], doc["lon"], doc.get("confidence"),
                doc.get("acq_date"), doc.get("acq_time"),
                doc.get("satellite"), doc.get("bright_ti4"),
                doc.get("source"), doc.get("ingested_at"),
            ),
        )
        await conn.commit()


async def bulk_upsert_fires(docs: list[dict[str, Any]]) -> int:
    if not docs:
        return 0
    async with _get_conn() as conn:
        await conn.executemany(
            """
            INSERT INTO fire_data (lat, lon, confidence, acq_date, acq_time,
                                   satellite, bright_ti4, source, ingested_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(lat, lon, acq_date) DO UPDATE SET
                confidence=excluded.confidence,
                acq_time=excluded.acq_time,
                satellite=excluded.satellite,
                bright_ti4=excluded.bright_ti4,
                source=excluded.source,
                ingested_at=excluded.ingested_at
            """,
            [
                (
                    d["lat"], d["lon"], d.get("confidence"),
                    d.get("acq_date"), d.get("acq_time"),
                    d.get("satellite"), d.get("bright_ti4"),
                    d.get("source"), d.get("ingested_at"),
                )
                for d in docs
            ],
        )
        await conn.commit()
    return len(docs)


async def find_fires(
    sw_lat: float, ne_lat: float, sw_lng: float, ne_lng: float, limit: int = 1000
) -> list[dict[str, Any]]:
    async with _get_conn() as conn:
        cursor = await conn.execute(
            """
            SELECT lat, lon, confidence, acq_date, acq_time,
                   satellite, bright_ti4
            FROM fire_data
            WHERE lat >= ? AND lat <= ? AND lon >= ? AND lon <= ?
            ORDER BY acq_date DESC, lat, lon
            LIMIT ?
            """,
            (sw_lat, ne_lat, sw_lng, ne_lng, limit),
        )
        rows = await cursor.fetchall()
        return [dict(r) for r in rows]


async def prune_old_fires(days: int = 90) -> int:
    cutoff = (datetime.datetime.now(datetime.timezone.utc) -
              datetime.timedelta(days=days)).isoformat()
    async with _get_conn() as conn:
        cursor = await conn.execute(
            "DELETE FROM fire_data WHERE ingested_at < ?", (cutoff,)
        )
        await conn.commit()
        return cursor.rowcount


# Deforestation data ------------------------------------------------------

async def upsert_deforestation(doc: dict[str, Any]) -> None:
    async with _get_conn() as conn:
        await conn.execute(
            """
            INSERT INTO deforestation_data (name, clazz, periods, source,
                                            color, lat, lon, timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT DO NOTHING
            """,
            (
                doc.get("name"), doc.get("clazz", "Desmatamento"),
                doc.get("periods", "N/A"), doc.get("source", "TerraBrasilis"),
                doc.get("color"), doc["lat"], doc["lon"],
                doc.get("timestamp"),
            ),
        )
        await conn.commit()


async def bulk_upsert_deforestation(docs: list[dict[str, Any]]) -> int:
    if not docs:
        return 0
    async with _get_conn() as conn:
        await conn.executemany(
            """
            INSERT INTO deforestation_data (name, clazz, periods, source,
                                            color, lat, lon, timestamp)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT DO NOTHING
            """,
            [
                (
                    d.get("name"), d.get("clazz", "Desmatamento"),
                    d.get("periods", "N/A"), d.get("source", "TerraBrasilis"),
                    d.get("color"), d["lat"], d["lon"],
                    d.get("timestamp"),
                )
                for d in docs
            ],
        )
        await conn.commit()
    return len(docs)


async def find_deforestation(
    sw_lat: float, ne_lat: float, sw_lng: float, ne_lng: float, limit: int = 1000
) -> list[dict[str, Any]]:
    async with _get_conn() as conn:
        cursor = await conn.execute(
            """
            SELECT name, clazz, periods, source, color, lat, lon, timestamp
            FROM deforestation_data
            WHERE lat >= ? AND lat <= ? AND lon >= ? AND lon <= ?
            LIMIT ?
            """,
            (sw_lat, ne_lat, sw_lng, ne_lng, limit),
        )
        rows = await cursor.fetchall()
        return [dict(r) for r in rows]


# News --------------------------------------------------------------------

async def upsert_news(article: dict[str, Any]) -> None:
    ingested = article.get("ingested_at") or datetime.datetime.now(datetime.timezone.utc).isoformat()
    async with _get_conn() as conn:
        await conn.execute(
            """
            INSERT INTO news (url, title, description, title_en, description_en, publishedAt,
                              source_name, urlToImage, content, ingested_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(url) DO UPDATE SET
                title=excluded.title,
                description=excluded.description,
                title_en=COALESCE(excluded.title_en, news.title_en),
                description_en=COALESCE(excluded.description_en, news.description_en),
                publishedAt=excluded.publishedAt,
                source_name=excluded.source_name,
                urlToImage=excluded.urlToImage,
                content=excluded.content,
                ingested_at=excluded.ingested_at
            """,
            (
                article.get("url"), article.get("title"),
                article.get("description"), article.get("title_en"),
                article.get("description_en"), article.get("publishedAt"),
                article.get("source", {}).get("name") if isinstance(article.get("source"), dict) else article.get("source"),
                article.get("urlToImage"), article.get("content"),
                ingested,
            ),
        )
        await conn.commit()


async def bulk_upsert_news(articles: list[dict[str, Any]]) -> int:
    if not articles:
        return 0
    async with _get_conn() as conn:
        await conn.executemany(
            """
            INSERT INTO news (url, title, description, title_en, description_en, publishedAt,
                              source_name, urlToImage, content, ingested_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(url) DO UPDATE SET
                title=excluded.title,
                description=excluded.description,
                title_en=COALESCE(excluded.title_en, news.title_en),
                description_en=COALESCE(excluded.description_en, news.description_en),
                publishedAt=excluded.publishedAt,
                source_name=excluded.source_name,
                urlToImage=excluded.urlToImage,
                content=excluded.content,
                ingested_at=excluded.ingested_at
            """,
            [
                (
                    a.get("url"), a.get("title"),
                    a.get("description"), a.get("title_en"),
                    a.get("description_en"), a.get("publishedAt"),
                    a.get("source", {}).get("name") if isinstance(a.get("source"), dict) else a.get("source"),
                    a.get("urlToImage"), a.get("content"),
                    a.get("ingested_at") or datetime.datetime.now(datetime.timezone.utc).isoformat(),
                )
                for a in articles
            ],
        )
        await conn.commit()
    return len(articles)


async def get_news_page(
    page: int = 1, page_size: int = 20, lang: str = "pt"
) -> list[dict[str, Any]]:
    skip = (page - 1) * page_size
    async with _get_conn() as conn:
        cursor = await conn.execute(
            """
            SELECT url, title, description, title_en, description_en, publishedAt,
                   source_name, urlToImage, content, ingested_at
            FROM news
            ORDER BY publishedAt DESC
            LIMIT ? OFFSET ?
            """,
            (page_size, skip),
        )
        rows = await cursor.fetchall()
        return [
            {
                "url": r["url"],
                "title": r["title"],
                "description": r["description"],
                "title_en": r["title_en"],
                "description_en": r["description_en"],
                "publishedAt": r["publishedAt"],
                "source": {"name": r["source_name"]} if r["source_name"] else {},
                "urlToImage": r["urlToImage"],
                "content": r["content"],
                "ingested_at": r["ingested_at"],
            }
            for r in rows
        ]


async def has_recent_news(minutes: int = 15) -> bool:
    cutoff = (datetime.datetime.now(datetime.timezone.utc) -
              datetime.timedelta(minutes=minutes)).isoformat()
    async with _get_conn() as conn:
        cursor = await conn.execute(
            "SELECT COUNT(*) FROM news WHERE ingested_at >= ?", (cutoff,)
        )
        row = await cursor.fetchone()
        return row[0] > 0


async def count_news() -> int:
    async with _get_conn() as conn:
        cursor = await conn.execute("SELECT COUNT(*) FROM news")
        row = await cursor.fetchone()
        return row[0]


# Stats / health ------------------------------------------------------------

async def get_stats() -> dict[str, int]:
    async with _get_conn() as conn:
        fire_count = (await (await conn.execute("SELECT COUNT(*) FROM fire_data")).fetchone())[0]
        def_count = (await (await conn.execute("SELECT COUNT(*) FROM deforestation_data")).fetchone())[0]
        news_count = (await (await conn.execute("SELECT COUNT(*) FROM news")).fetchone())[0]
    return {"fires": fire_count, "deforestation": def_count, "news": news_count}

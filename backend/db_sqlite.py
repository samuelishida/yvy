"""SQLite async database layer with JSONB support for Yvy backend.

Tables use a hybrid approach:
- Scalar columns for heavily-queried fields (lat, lon, dates, url)
- JSONB BLOB column (`data`) for flexible/extensible fields

SQLite 3.45.0+ stores JSONB as binary BLOB, ~5-10% smaller than text JSON,
with faster json_extract() operations on the binary format.
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
    acq_date TEXT,
    ingested_at TEXT,
    data BLOB,
    UNIQUE(lat, lon, acq_date)
);

CREATE TABLE IF NOT EXISTS deforestation_data (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    lat REAL,
    lon REAL,
    data BLOB
);

CREATE TABLE IF NOT EXISTS news (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    url TEXT UNIQUE NOT NULL,
    publishedAt TEXT,
    ingested_at TEXT,
    data BLOB
);

CREATE INDEX IF NOT EXISTS idx_fire_lat ON fire_data(lat);
CREATE INDEX IF NOT EXISTS idx_fire_lon ON fire_data(lon);
CREATE INDEX IF NOT EXISTS idx_fire_acq_date ON fire_data(acq_date);
CREATE INDEX IF NOT EXISTS idx_def_lat ON deforestation_data(lat);
CREATE INDEX IF NOT EXISTS idx_def_lon ON deforestation_data(lon);
CREATE INDEX IF NOT EXISTS idx_news_published ON news(publishedAt);
CREATE INDEX IF NOT EXISTS idx_news_ingested ON news(ingested_at);
CREATE INDEX IF NOT EXISTS idx_fire_confidence ON fire_data(json_extract(data, '$.confidence'));
CREATE INDEX IF NOT EXISTS idx_def_name ON deforestation_data(json_extract(data, '$.name'));
CREATE INDEX IF NOT EXISTS idx_news_source ON news(json_extract(data, '$.source_name'));
"""

_pool: asyncio.Queue[aiosqlite.Connection] | None = None
_pool_size = 7


def _encode_jsonb(obj: dict[str, Any]) -> bytes:
    """Encode a dict to JSON bytes for storage in a JSONB BLOB column.

    SQLite's jsonb() function converts text JSON to binary JSONB at INSERT time
    via the `jsonb(?)` SQL expression. We pass UTF-8 JSON text and let SQLite
    handle the conversion.
    """
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def _decode_jsonb(blob: bytes | None) -> dict[str, Any]:
    """Decode a JSONB BLOB back to a Python dict.

    SQLite's jsonb() stores data in a binary format that is NOT valid UTF-8.
    To read it back, we use json(data) in SQL queries to convert JSONB to
    text JSON before Python receives it. This function is a fallback for
    cases where raw BLOB is received.
    """
    if blob is None:
        return {}
    if isinstance(blob, dict):
        return blob
    if isinstance(blob, str):
        return json.loads(blob)
    if isinstance(blob, bytes):
        # Binary JSONB format — cannot decode directly as UTF-8.
        # Try UTF-8 decode (works if stored as plain text JSON, not jsonb()).
        try:
            return json.loads(blob.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            logger.warning("Cannot decode binary JSONB directly — use json(data) in SQL queries")
            return {}
    return {}


async def _check_sqlite_version(conn: aiosqlite.Connection) -> bool:
    """Verify SQLite supports JSONB (>= 3.45.0)."""
    cursor = await conn.execute("SELECT sqlite_version()")
    row = await cursor.fetchone()
    version_str = row[0]
    parts = version_str.split(".")
    major, minor = int(parts[0]), int(parts[1])
    patch = int(parts[2]) if len(parts) > 2 else 0
    version_num = major * 10000 + minor * 100 + patch
    if version_num < 34500:
        logger.warning("SQLite %s does not support JSONB (need >= 3.45.0). Falling back to text JSON.", version_str)
        return False
    logger.info("SQLite %s — JSONB supported", version_str)
    return True


async def _create_connection() -> aiosqlite.Connection:
    conn = await aiosqlite.connect(DB_PATH)
    conn.row_factory = aiosqlite.Row
    await conn.execute("PRAGMA journal_mode=WAL")
    await conn.execute("PRAGMA synchronous=NORMAL")
    await conn.execute("PRAGMA cache_size=-8000")   # 8MB per connection
    await conn.execute("PRAGMA temp_store=MEMORY")
    await conn.execute("PRAGMA mmap_size=0")        # disable mmap on low-RAM VM
    return conn


async def _rebuild_tables_to_jsonb() -> None:
    """Rebuild tables from legacy flat-column schema to JSONB schema.

    This is a destructive migration: it creates new tables, copies data
    using jsonb() to convert text fields to binary JSONB, then swaps tables.
    Called only when legacy columns are detected during init_db().
    """
    async with _get_conn() as conn:
        # --- fire_data ---
        cursor = await conn.execute("PRAGMA table_info(fire_data)")
        columns = {row[1] for row in await cursor.fetchall()}

        if "confidence" in columns:
            logger.info("Rebuilding fire_data table to JSONB schema...")
            await conn.executescript("""
                CREATE TABLE IF NOT EXISTS fire_data_new (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    lat REAL NOT NULL,
                    lon REAL NOT NULL,
                    acq_date TEXT,
                    ingested_at TEXT,
                    data BLOB,
                    UNIQUE(lat, lon, acq_date)
                );
            """)
            await conn.commit()

            # Copy data row by row using jsonb() for conversion
            cursor = await conn.execute("""
                SELECT id, lat, lon, acq_date, ingested_at,
                       confidence, acq_time, satellite, bright_ti4, source
                FROM fire_data
            """)
            rows = await cursor.fetchall()
            for row in rows:
                data_json = json.dumps({
                    "confidence": row["confidence"],
                    "acq_time": row["acq_time"],
                    "satellite": row["satellite"],
                    "bright_ti4": row["bright_ti4"],
                    "source": row["source"],
                }, separators=(",", ":"), ensure_ascii=False)
                await conn.execute(
                    "INSERT INTO fire_data_new (id, lat, lon, acq_date, ingested_at, data) VALUES (?, ?, ?, ?, ?, jsonb(?))",
                    (row["id"], row["lat"], row["lon"], row["acq_date"], row["ingested_at"], data_json),
                )
            await conn.commit()

            await conn.execute("DROP TABLE fire_data")
            await conn.execute("ALTER TABLE fire_data_new RENAME TO fire_data")
            await conn.executescript("""
                CREATE INDEX IF NOT EXISTS idx_fire_lat ON fire_data(lat);
                CREATE INDEX IF NOT EXISTS idx_fire_lon ON fire_data(lon);
                CREATE INDEX IF NOT EXISTS idx_fire_acq_date ON fire_data(acq_date);
                CREATE INDEX IF NOT EXISTS idx_fire_confidence ON fire_data(json_extract(data, '$.confidence'));
            """)
            await conn.commit()
            logger.info("fire_data rebuilt with JSONB schema (%d rows)", len(rows))

        # --- deforestation_data ---
        cursor = await conn.execute("PRAGMA table_info(deforestation_data)")
        columns = {row[1] for row in await cursor.fetchall()}

        if "name" in columns:
            logger.info("Rebuilding deforestation_data table to JSONB schema...")
            await conn.executescript("""
                CREATE TABLE IF NOT EXISTS deforestation_data_new (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    lat REAL,
                    lon REAL,
                    data BLOB
                );
            """)
            await conn.commit()

            cursor = await conn.execute("""
                SELECT id, lat, lon, name, clazz, periods, source, color, timestamp
                FROM deforestation_data
            """)
            rows = await cursor.fetchall()
            for row in rows:
                data_json = json.dumps({
                    "name": row["name"],
                    "clazz": row["clazz"],
                    "periods": row["periods"],
                    "source": row["source"],
                    "color": row["color"],
                    "timestamp": row["timestamp"],
                }, separators=(",", ":"), ensure_ascii=False)
                await conn.execute(
                    "INSERT INTO deforestation_data_new (id, lat, lon, data) VALUES (?, ?, ?, jsonb(?))",
                    (row["id"], row["lat"], row["lon"], data_json),
                )
            await conn.commit()

            await conn.execute("DROP TABLE deforestation_data")
            await conn.execute("ALTER TABLE deforestation_data_new RENAME TO deforestation_data")
            await conn.executescript("""
                CREATE INDEX IF NOT EXISTS idx_def_lat ON deforestation_data(lat);
                CREATE INDEX IF NOT EXISTS idx_def_lon ON deforestation_data(lon);
                CREATE INDEX IF NOT EXISTS idx_def_name ON deforestation_data(json_extract(data, '$.name'));
            """)
            await conn.commit()
            logger.info("deforestation_data rebuilt with JSONB schema (%d rows)", len(rows))

        # --- news ---
        cursor = await conn.execute("PRAGMA table_info(news)")
        columns = {row[1] for row in await cursor.fetchall()}

        if "title" in columns:
            logger.info("Rebuilding news table to JSONB schema...")
            await conn.executescript("""
                CREATE TABLE IF NOT EXISTS news_new (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    url TEXT UNIQUE NOT NULL,
                    publishedAt TEXT,
                    ingested_at TEXT,
                    data BLOB
                );
            """)
            await conn.commit()

            cursor = await conn.execute("""
                SELECT id, url, publishedAt, ingested_at,
                       title, description, title_en, description_en,
                       source_name, urlToImage, content
                FROM news
            """)
            rows = await cursor.fetchall()
            for row in rows:
                data_json = json.dumps({
                    "title": row["title"],
                    "description": row["description"],
                    "title_en": row["title_en"],
                    "description_en": row["description_en"],
                    "source_name": row["source_name"],
                    "urlToImage": row["urlToImage"],
                    "content": row["content"],
                }, separators=(",", ":"), ensure_ascii=False)
                ingested = row["ingested_at"] or row["publishedAt"]
                await conn.execute(
                    "INSERT INTO news_new (id, url, publishedAt, ingested_at, data) VALUES (?, ?, ?, ?, jsonb(?))",
                    (row["id"], row["url"], row["publishedAt"], ingested, data_json),
                )
            await conn.commit()

            await conn.execute("DROP TABLE news")
            await conn.execute("ALTER TABLE news_new RENAME TO news")
            await conn.executescript("""
                CREATE INDEX IF NOT EXISTS idx_news_published ON news(publishedAt);
                CREATE INDEX IF NOT EXISTS idx_news_ingested ON news(ingested_at);
                CREATE INDEX IF NOT EXISTS idx_news_source ON news(json_extract(data, '$.source_name'));
            """)
            await conn.commit()
            logger.info("news rebuilt with JSONB schema (%d rows)", len(rows))


async def _migrate_news_table() -> None:
    """Add missing columns and backfill defaults (SQLite migration).

    For JSONB schema, ensures the data column exists.
    """
    async with _get_conn() as conn:
        cursor = await conn.execute("PRAGMA table_info(news)")
        columns = {row[1] for row in await cursor.fetchall()}

        # JSONB schema — ensure data column exists
        if "data" not in columns:
            await conn.execute("ALTER TABLE news ADD COLUMN data BLOB")
            logger.info("Migration: added data BLOB to news")
            await conn.commit()

        # Ensure ingested_at column exists
        if "ingested_at" not in columns:
            await conn.execute("ALTER TABLE news ADD COLUMN ingested_at TEXT")
            logger.info("Migration: added ingested_at to news")
            await conn.commit()

        # Backfill ingested_at from publishedAt
        try:
            await conn.execute("UPDATE news SET ingested_at = publishedAt WHERE ingested_at IS NULL AND publishedAt IS NOT NULL")
            await conn.commit()
        except Exception:
            pass


async def init_db() -> None:
    """Create tables and connection pool. Auto-migrates legacy schema to JSONB."""
    global _pool
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)

    # Check if we need to migrate from legacy schema
    needs_migration = False
    if os.path.exists(DB_PATH):
        try:
            conn = await aiosqlite.connect(DB_PATH)
            conn.row_factory = aiosqlite.Row
            cursor = await conn.execute("PRAGMA table_info(fire_data)")
            columns = {row[1] for row in await cursor.fetchall()}
            if "confidence" in columns:
                needs_migration = True
            await conn.close()
        except Exception:
            pass

    if needs_migration:
        logger.info("Legacy flat-column schema detected — rebuilding tables to JSONB...")
        # Connect and migrate
        conn = await _create_connection()
        await _check_sqlite_version(conn)
        await conn.close()

        # Build pool so _rebuild_tables_to_jsonb can use it
        _pool = asyncio.Queue(maxsize=_pool_size)
        for _ in range(_pool_size):
            await _pool.put(await _create_connection())

        await _rebuild_tables_to_jsonb()

        # Drain and rebuild pool after schema change
        while not _pool.empty():
            c = await _pool.get()
            await c.close()
        _pool = None

    # Create tables (no-op if they exist with JSONB schema)
    conn = await _create_connection()
    await _check_sqlite_version(conn)
    await conn.executescript(SCHEMA)
    await conn.commit()
    await conn.close()

    # Build pool
    _pool = asyncio.Queue(maxsize=_pool_size)
    for _ in range(_pool_size):
        await _pool.put(await _create_connection())
    logger.info("SQLite initialized at %s (JSONB schema)", DB_PATH)

    # Run any remaining migrations
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
    data = _encode_jsonb({
        "confidence": doc.get("confidence"),
        "acq_time": doc.get("acq_time"),
        "satellite": doc.get("satellite"),
        "bright_ti4": doc.get("bright_ti4"),
        "source": doc.get("source"),
    })
    async with _get_conn() as conn:
        await conn.execute(
            """
            INSERT INTO fire_data (lat, lon, acq_date, ingested_at, data)
            VALUES (?, ?, ?, ?, jsonb(?))
            ON CONFLICT(lat, lon, acq_date) DO UPDATE SET
                ingested_at=excluded.ingested_at,
                data=jsonb(excluded.data)
            """,
            (
                doc["lat"], doc["lon"], doc.get("acq_date"),
                doc.get("ingested_at"), data,
            ),
        )
        await conn.commit()


async def bulk_upsert_fires(docs: list[dict[str, Any]]) -> int:
    if not docs:
        return 0
    rows = [
        (
            d["lat"], d["lon"], d.get("acq_date"),
            d.get("ingested_at"),
            _encode_jsonb({
                "confidence": d.get("confidence"),
                "acq_time": d.get("acq_time"),
                "satellite": d.get("satellite"),
                "bright_ti4": d.get("bright_ti4"),
                "source": d.get("source"),
            }),
        )
        for d in docs
    ]
    async with _get_conn() as conn:
        await conn.executemany(
            """
            INSERT INTO fire_data (lat, lon, acq_date, ingested_at, data)
            VALUES (?, ?, ?, ?, jsonb(?))
            ON CONFLICT(lat, lon, acq_date) DO UPDATE SET
                ingested_at=excluded.ingested_at,
                data=jsonb(excluded.data)
            """,
            rows,
        )
        await conn.commit()
    return len(docs)


async def find_fires(
    sw_lat: float, ne_lat: float, sw_lng: float, ne_lng: float, limit: int = 1000
) -> list[dict[str, Any]]:
    async with _get_conn() as conn:
        cursor = await conn.execute(
            """
            SELECT lat, lon, acq_date, ingested_at, json(data) AS data_json
            FROM fire_data
            WHERE lat >= ? AND lat <= ? AND lon >= ? AND lon <= ?
            ORDER BY acq_date DESC, lat, lon
            LIMIT ?
            """,
            (sw_lat, ne_lat, sw_lng, ne_lng, limit),
        )
        rows = await cursor.fetchall()
        result = []
        for r in rows:
            d = json.loads(r["data_json"]) if r["data_json"] else {}
            result.append({
                "lat": r["lat"],
                "lon": r["lon"],
                "confidence": d.get("confidence"),
                "acq_date": r["acq_date"],
                "acq_time": d.get("acq_time"),
                "satellite": d.get("satellite"),
                "bright_ti4": d.get("bright_ti4"),
            })
        return result


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
    data = _encode_jsonb({
        "name": doc.get("name"),
        "clazz": doc.get("clazz", "Desmatamento"),
        "periods": doc.get("periods", "N/A"),
        "source": doc.get("source", "TerraBrasilis"),
        "color": doc.get("color"),
        "timestamp": doc.get("timestamp"),
    })
    async with _get_conn() as conn:
        await conn.execute(
            """
            INSERT INTO deforestation_data (lat, lon, data)
            VALUES (?, ?, jsonb(?))
            ON CONFLICT DO NOTHING
            """,
            (doc["lat"], doc["lon"], data),
        )
        await conn.commit()


async def bulk_upsert_deforestation(docs: list[dict[str, Any]]) -> int:
    if not docs:
        return 0
    rows = [
        (
            d["lat"], d["lon"],
            _encode_jsonb({
                "name": d.get("name"),
                "clazz": d.get("clazz", "Desmatamento"),
                "periods": d.get("periods", "N/A"),
                "source": d.get("source", "TerraBrasilis"),
                "color": d.get("color"),
                "timestamp": d.get("timestamp"),
            }),
        )
        for d in docs
    ]
    async with _get_conn() as conn:
        await conn.executemany(
            """
            INSERT INTO deforestation_data (lat, lon, data)
            VALUES (?, ?, jsonb(?))
            ON CONFLICT DO NOTHING
            """,
            rows,
        )
        await conn.commit()
    return len(docs)


async def find_deforestation(
    sw_lat: float, ne_lat: float, sw_lng: float, ne_lng: float, limit: int = 1000
) -> list[dict[str, Any]]:
    async with _get_conn() as conn:
        cursor = await conn.execute(
            """
            SELECT lat, lon, json(data) AS data_json
            FROM deforestation_data
            WHERE lat >= ? AND lat <= ? AND lon >= ? AND lon <= ?
            LIMIT ?
            """,
            (sw_lat, ne_lat, sw_lng, ne_lng, limit),
        )
        rows = await cursor.fetchall()
        result = []
        for r in rows:
            d = json.loads(r["data_json"]) if r["data_json"] else {}
            result.append({
                "name": d.get("name"),
                "clazz": d.get("clazz", "Desmatamento"),
                "periods": d.get("periods", "N/A"),
                "source": d.get("source", "TerraBrasilis"),
                "color": d.get("color"),
                "lat": r["lat"],
                "lon": r["lon"],
                "timestamp": d.get("timestamp"),
            })
        return result


# News --------------------------------------------------------------------

async def upsert_news(article: dict[str, Any]) -> None:
    ingested = article.get("ingested_at") or datetime.datetime.now(datetime.timezone.utc).isoformat()
    source_obj = article.get("source")
    source_name = source_obj.get("name") if isinstance(source_obj, dict) else article.get("source")

    data = _encode_jsonb({
        "title": article.get("title"),
        "description": article.get("description"),
        "title_en": article.get("title_en"),
        "description_en": article.get("description_en"),
        "source_name": source_name,
        "urlToImage": article.get("urlToImage"),
        "content": article.get("content"),
    })

    async with _get_conn() as conn:
        await conn.execute(
            """
            INSERT INTO news (url, publishedAt, ingested_at, data)
            VALUES (?, ?, ?, jsonb(?))
            ON CONFLICT(url) DO UPDATE SET
                publishedAt=excluded.publishedAt,
                ingested_at=excluded.ingested_at,
                data=jsonb(excluded.data)
            """,
            (article.get("url"), article.get("publishedAt"), ingested, data),
        )
        await conn.commit()


async def bulk_upsert_news(articles: list[dict[str, Any]]) -> int:
    if not articles:
        return 0
    rows = []
    for a in articles:
        source_obj = a.get("source")
        source_name = source_obj.get("name") if isinstance(source_obj, dict) else a.get("source")
        ingested = a.get("ingested_at") or datetime.datetime.now(datetime.timezone.utc).isoformat()
        data = _encode_jsonb({
            "title": a.get("title"),
            "description": a.get("description"),
            "title_en": a.get("title_en"),
            "description_en": a.get("description_en"),
            "source_name": source_name,
            "urlToImage": a.get("urlToImage"),
            "content": a.get("content"),
        })
        rows.append((a.get("url"), a.get("publishedAt"), ingested, data))

    async with _get_conn() as conn:
        await conn.executemany(
            """
            INSERT INTO news (url, publishedAt, ingested_at, data)
            VALUES (?, ?, ?, jsonb(?))
            ON CONFLICT(url) DO UPDATE SET
                publishedAt=excluded.publishedAt,
                ingested_at=excluded.ingested_at,
                data=jsonb(excluded.data)
            """,
            rows,
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
            SELECT url, publishedAt, ingested_at, json(data) AS data_json
            FROM news
            ORDER BY publishedAt DESC
            LIMIT ? OFFSET ?
            """,
            (page_size, skip),
        )
        rows = await cursor.fetchall()
        result = []
        for r in rows:
            d = json.loads(r["data_json"]) if r["data_json"] else {}
            result.append({
                "url": r["url"],
                "title": d.get("title"),
                "description": d.get("description"),
                "title_en": d.get("title_en"),
                "description_en": d.get("description_en"),
                "publishedAt": r["publishedAt"],
                "source": {"name": d.get("source_name")} if d.get("source_name") else {},
                "urlToImage": d.get("urlToImage"),
                "content": d.get("content"),
                "ingested_at": r["ingested_at"],
            })
        return result


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


# Direct JSONB field access helpers (for news_sqlite.py) -------------------

async def get_news_fields_by_urls(urls: list[str], fields: list[str]) -> dict[str, dict[str, Any]]:
    """Fetch specific fields from news data JSONB by URLs.

    Returns {url: {field: value, ...}} for found URLs.
    Uses json_extract() which works transparently on both text JSON and binary JSONB.
    """
    if not urls:
        return {}
    placeholders = ",".join("?" for _ in urls)
    extract_cols = ", ".join(f"json_extract(data, '$.{f}') AS {f}" for f in fields)
    query = f"SELECT url, {extract_cols} FROM news WHERE url IN ({placeholders})"
    async with _get_conn() as conn:
        cursor = await conn.execute(query, urls)
        rows = await cursor.fetchall()
    result = {}
    for r in rows:
        result[r["url"]] = {f: r[f] for f in fields}
    return result


async def update_news_fields(url: str, updates: dict[str, Any]) -> None:
    """Update specific fields in a news article's JSONB data.

    Reads current data, merges updates, and writes back as JSONB.
    """
    async with _get_conn() as conn:
        cursor = await conn.execute(
            "SELECT json(data) AS data_json FROM news WHERE url = ?", (url,)
        )
        row = await cursor.fetchone()
        if not row or not row["data_json"]:
            return

        current = json.loads(row["data_json"])
        current.update(updates)

        await conn.execute(
            "UPDATE news SET data = jsonb(?) WHERE url = ?",
            (_encode_jsonb(current), url),
        )
        await conn.commit()


async def clear_news_fields(urls: list[str], fields: list[str]) -> None:
    """Set specific JSONB fields to NULL for given URLs."""
    if not urls:
        return
    async with _get_conn() as conn:
        for url in urls:
            cursor = await conn.execute(
                "SELECT json(data) AS data_json FROM news WHERE url = ?", (url,)
            )
            row = await cursor.fetchone()
            if not row or not row["data_json"]:
                continue
            current = json.loads(row["data_json"])
            for field in fields:
                current.pop(field, None)
            await conn.execute(
                "UPDATE news SET data = jsonb(?) WHERE url = ?",
                (_encode_jsonb(current), url),
            )
        await conn.commit()

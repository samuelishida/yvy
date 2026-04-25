"""Manual SQLite tests using built-in sqlite3 (no pytest, no aiosqlite needed).

This validates the schema and queries used by db_sqlite.py.
"""
import sqlite3
import tempfile
import os
from datetime import datetime, timezone

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
    publishedAt TEXT,
    source_name TEXT,
    urlToImage TEXT,
    content TEXT
);

CREATE INDEX IF NOT EXISTS idx_fire_lat ON fire_data(lat);
CREATE INDEX IF NOT EXISTS idx_fire_lon ON fire_data(lon);
CREATE INDEX IF NOT EXISTS idx_fire_acq_date ON fire_data(acq_date);
CREATE INDEX IF NOT EXISTS idx_def_lat ON deforestation_data(lat);
CREATE INDEX IF NOT EXISTS idx_def_lon ON deforestation_data(lon);
CREATE INDEX IF NOT EXISTS idx_news_published ON news(publishedAt);
"""


def test_schema():
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        path = f.name
    try:
        conn = sqlite3.connect(path)
        conn.executescript(SCHEMA)
        cursor = conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
        tables = {row[0] for row in cursor.fetchall()}
        assert "fire_data" in tables
        assert "deforestation_data" in tables
        assert "news" in tables
        conn.close()
        print("PASS: schema creates all tables")
    finally:
        os.unlink(path)


def test_fire_insert_and_query():
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        path = f.name
    try:
        conn = sqlite3.connect(path)
        conn.executescript(SCHEMA)

        now = datetime.now(timezone.utc).isoformat()
        conn.execute(
            """INSERT INTO fire_data (lat, lon, confidence, acq_date, acq_time,
               satellite, bright_ti4, source, ingested_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (-10.5, -55.0, "high", "2024-01-01", "12:00", "NPP", 350.0,
             "NASA_FIRMS_VIIRS_SNPP", now),
        )
        conn.commit()

        cursor = conn.execute(
            """SELECT lat, lon, confidence, acq_date, acq_time,
               satellite, bright_ti4
               FROM fire_data
               WHERE lat >= ? AND lat <= ? AND lon >= ? AND lon <= ?
               LIMIT ?""",
            (-11, -9, -56, -54, 1000),
        )
        rows = [dict(zip([c[0] for c in cursor.description], row))
                for row in cursor.fetchall()]
        assert len(rows) == 1
        assert rows[0]["lat"] == -10.5
        conn.close()
        print("PASS: fire insert + bbox query")
    finally:
        os.unlink(path)


def test_fire_unique_constraint():
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        path = f.name
    try:
        conn = sqlite3.connect(path)
        conn.executescript(SCHEMA)
        conn.execute(
            "INSERT INTO fire_data (lat, lon, acq_date) VALUES (?, ?, ?)",
            (-10.0, -50.0, "2024-01-01"),
        )
        conn.commit()
        try:
            conn.execute(
                "INSERT INTO fire_data (lat, lon, acq_date) VALUES (?, ?, ?)",
                (-10.0, -50.0, "2024-01-01"),
            )
            conn.commit()
            assert False, "Should have raised IntegrityError"
        except sqlite3.IntegrityError:
            pass
        conn.close()
        print("PASS: fire unique constraint (lat, lon, acq_date)")
    finally:
        os.unlink(path)


def test_news_insert_and_query():
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        path = f.name
    try:
        conn = sqlite3.connect(path)
        conn.executescript(SCHEMA)

        now = datetime.now(timezone.utc).isoformat()
        conn.execute(
            """INSERT INTO news (url, title, description, publishedAt,
               source_name, urlToImage, content)
               VALUES (?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(url) DO UPDATE SET
               title=excluded.title,
               description=excluded.description,
               publishedAt=excluded.publishedAt,
               source_name=excluded.source_name,
               urlToImage=excluded.urlToImage,
               content=excluded.content""",
            ("https://example.com/1", "Test", "Desc", now,
             "Example", "https://img.jpg", "Content"),
        )
        conn.commit()

        cursor = conn.execute(
            "SELECT * FROM news ORDER BY publishedAt DESC LIMIT ? OFFSET ?",
            (10, 0),
        )
        rows = [dict(zip([c[0] for c in cursor.description], row))
                for row in cursor.fetchall()]
        assert len(rows) == 1
        assert rows[0]["title"] == "Test"

        # Test has_recent_news logic
        fifteen_min_ago = (datetime.now(timezone.utc) - __import__(
            'datetime').timedelta(minutes=15)).isoformat()
        cursor = conn.execute(
            "SELECT COUNT(*) FROM news WHERE publishedAt >= ?",
            (fifteen_min_ago,),
        )
        assert cursor.fetchone()[0] == 1
        conn.close()
        print("PASS: news insert + query + recent check")
    finally:
        os.unlink(path)


def test_deforestation_insert_and_query():
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        path = f.name
    try:
        conn = sqlite3.connect(path)
        conn.executescript(SCHEMA)

        now = datetime.now(timezone.utc).isoformat()
        conn.execute(
            """INSERT INTO deforestation_data (name, clazz, periods, source,
               color, lat, lon, timestamp)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            ("Amazonia", "Desmatamento", "2024", "TerraBrasilis",
             "#FF0000", -10.0, -55.0, now),
        )
        conn.commit()

        cursor = conn.execute(
            """SELECT name, clazz, periods, source, color, lat, lon
               FROM deforestation_data
               WHERE lat >= ? AND lat <= ? AND lon >= ? AND lon <= ?
               LIMIT ?""",
            (-11, -9, -56, -54, 1000),
        )
        rows = [dict(zip([c[0] for c in cursor.description], row))
                for row in cursor.fetchall()]
        assert len(rows) == 1
        assert rows[0]["name"] == "Amazonia"
        conn.close()
        print("PASS: deforestation insert + bbox query")
    finally:
        os.unlink(path)


def test_stats():
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        path = f.name
    try:
        conn = sqlite3.connect(path)
        conn.executescript(SCHEMA)

        conn.execute(
            "INSERT INTO fire_data (lat, lon, acq_date) VALUES (?, ?, ?)",
            (-10.0, -50.0, "2024-01-01"),
        )
        conn.execute(
            "INSERT INTO news (url, title, publishedAt) VALUES (?, ?, ?)",
            ("https://example.com/1", "Test",
             datetime.now(timezone.utc).isoformat()),
        )
        conn.commit()

        fire_count = conn.execute(
            "SELECT COUNT(*) FROM fire_data").fetchone()[0]
        def_count = conn.execute(
            "SELECT COUNT(*) FROM deforestation_data").fetchone()[0]
        news_count = conn.execute(
            "SELECT COUNT(*) FROM news").fetchone()[0]

        assert fire_count == 1
        assert def_count == 0
        assert news_count == 1
        conn.close()
        print("PASS: stats counts")
    finally:
        os.unlink(path)


def test_prune_old_fires():
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        path = f.name
    try:
        conn = sqlite3.connect(path)
        conn.executescript(SCHEMA)

        old = "2023-01-01T12:00:00+00:00"
        new = datetime.now(timezone.utc).isoformat()
        conn.execute(
            "INSERT INTO fire_data (lat, lon, acq_date, ingested_at) VALUES (?, ?, ?, ?)",
            (-10.0, -50.0, "2023-01-01", old),
        )
        conn.execute(
            "INSERT INTO fire_data (lat, lon, acq_date, ingested_at) VALUES (?, ?, ?, ?)",
            (-11.0, -51.0, "2024-06-01", new),
        )
        conn.commit()

        cutoff = (datetime.now(timezone.utc) - __import__(
            'datetime').timedelta(days=365)).isoformat()
        cursor = conn.execute(
            "DELETE FROM fire_data WHERE ingested_at < ?", (cutoff,))
        conn.commit()
        assert cursor.rowcount == 1

        remaining = conn.execute(
            "SELECT COUNT(*) FROM fire_data").fetchone()[0]
        assert remaining == 1
        conn.close()
        print("PASS: prune old fires")
    finally:
        os.unlink(path)


if __name__ == "__main__":
    test_schema()
    test_fire_insert_and_query()
    test_fire_unique_constraint()
    test_news_insert_and_query()
    test_deforestation_insert_and_query()
    test_stats()
    test_prune_old_fires()
    print("\n=== ALL TESTS PASSED ===")

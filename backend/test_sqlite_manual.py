"""Manual SQLite tests using built-in sqlite3 (no pytest, no aiosqlite needed).

This validates the JSONB schema and queries used by db_sqlite.py.
Requires SQLite >= 3.45.0 for jsonb() support.
"""
import sqlite3
import json
import tempfile
import os
from datetime import datetime, timezone

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


def _check_sqlite_version():
    """Verify SQLite supports JSONB (>= 3.45.0)."""
    version = sqlite3.sqlite_version
    parts = version.split(".")
    major, minor, patch = int(parts[0]), int(parts[1]), int(parts[2]) if len(parts) > 2 else 0
    version_num = major * 10000 + minor * 100 + patch
    if version_num < 34500:
        print(f"WARNING: SQLite {version} does not support JSONB (need >= 3.45.0)")
        print("Tests will use text JSON fallback instead of jsonb()")
        return False
    print(f"SQLite {version} — JSONB supported")
    return True


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
        conn.row_factory = sqlite3.Row
        conn.executescript(SCHEMA)

        now = datetime.now(timezone.utc).isoformat()
        data_json = json.dumps({
            "confidence": "high",
            "acq_time": "12:00",
            "satellite": "NPP",
            "bright_ti4": 350.0,
            "source": "NASA_FIRMS_VIIRS_SNPP",
        }, separators=(",", ":"))
        conn.execute(
            """INSERT INTO fire_data (lat, lon, acq_date, ingested_at, data)
               VALUES (?, ?, ?, ?, jsonb(?))""",
            (-10.5, -55.0, "2024-01-01", now, data_json),
        )
        conn.commit()

        cursor = conn.execute(
            """SELECT lat, lon, acq_date, ingested_at,
                      json_extract(data, '$.confidence') AS confidence,
                      json_extract(data, '$.acq_time') AS acq_time,
                      json_extract(data, '$.satellite') AS satellite,
                      json_extract(data, '$.bright_ti4') AS bright_ti4
               FROM fire_data
               WHERE lat >= ? AND lat <= ? AND lon >= ? AND lon <= ?
               LIMIT ?""",
            (-11, -9, -56, -54, 1000),
        )
        rows = cursor.fetchall()
        assert len(rows) == 1
        row = rows[0]
        assert row["lat"] == -10.5
        assert row["lon"] == -55.0
        assert row["confidence"] == "high"
        assert row["acq_time"] == "12:00"
        assert row["satellite"] == "NPP"
        assert row["bright_ti4"] == 350.0
        conn.close()
        print("PASS: fire insert + bbox query (JSONB)")
    finally:
        os.unlink(path)


def test_fire_unique_constraint():
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        path = f.name
    try:
        conn = sqlite3.connect(path)
        conn.executescript(SCHEMA)
        data_json = json.dumps({"confidence": "low"}, separators=(",", ":"))
        conn.execute(
            "INSERT INTO fire_data (lat, lon, acq_date, data) VALUES (?, ?, ?, jsonb(?))",
            (-10.0, -50.0, "2024-01-01", data_json),
        )
        conn.commit()
        try:
            conn.execute(
                "INSERT INTO fire_data (lat, lon, acq_date, data) VALUES (?, ?, ?, jsonb(?))",
                (-10.0, -50.0, "2024-01-01", data_json),
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
        data_json = json.dumps({
            "title": "Test",
            "description": "Desc",
            "title_en": None,
            "description_en": None,
            "source_name": "Example",
            "urlToImage": "https://img.jpg",
            "content": "Content",
        }, separators=(",", ":"))
        conn.execute(
            """INSERT INTO news (url, publishedAt, ingested_at, data)
               VALUES (?, ?, ?, jsonb(?))
               ON CONFLICT(url) DO UPDATE SET
               publishedAt=excluded.publishedAt,
               ingested_at=excluded.ingested_at,
               data=jsonb(excluded.data)""",
            ("https://example.com/1", now, now, data_json),
        )
        conn.commit()

        cursor = conn.execute(
            "SELECT url, publishedAt, ingested_at, json(data) AS data_json FROM news ORDER BY publishedAt DESC LIMIT ? OFFSET ?",
            (10, 0),
        )
        rows = cursor.fetchall()
        assert len(rows) == 1
        data = json.loads(rows[0][3])
        assert data["title"] == "Test"
        assert data["source_name"] == "Example"

        # Test has_recent_news logic
        fifteen_min_ago = (datetime.now(timezone.utc) - __import__(
            'datetime').timedelta(minutes=15)).isoformat()
        cursor = conn.execute(
            "SELECT COUNT(*) FROM news WHERE ingested_at >= ?",
            (fifteen_min_ago,),
        )
        assert cursor.fetchone()[0] == 1
        conn.close()
        print("PASS: news insert + query + recent check (JSONB)")
    finally:
        os.unlink(path)


def test_deforestation_insert_and_query():
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        path = f.name
    try:
        conn = sqlite3.connect(path)
        conn.executescript(SCHEMA)

        now = datetime.now(timezone.utc).isoformat()
        data_json = json.dumps({
            "name": "Amazonia",
            "clazz": "Desmatamento",
            "periods": "2024",
            "source": "TerraBrasilis",
            "color": "#FF0000",
            "timestamp": now,
        }, separators=(",", ":"))
        conn.execute(
            "INSERT INTO deforestation_data (lat, lon, data) VALUES (?, ?, jsonb(?))",
            (-10.0, -55.0, data_json),
        )
        conn.commit()

        cursor = conn.execute(
            """SELECT lat, lon, json(data) AS data_json
               FROM deforestation_data
               WHERE lat >= ? AND lat <= ? AND lon >= ? AND lon <= ?
               LIMIT ?""",
            (-11, -9, -56, -54, 1000),
        )
        rows = cursor.fetchall()
        assert len(rows) == 1
        data = json.loads(rows[0][2])
        assert data["name"] == "Amazonia"
        assert data["color"] == "#FF0000"
        conn.close()
        print("PASS: deforestation insert + bbox query (JSONB)")
    finally:
        os.unlink(path)


def test_stats():
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        path = f.name
    try:
        conn = sqlite3.connect(path)
        conn.executescript(SCHEMA)

        data_json = json.dumps({"confidence": "low"}, separators=(",", ":"))
        conn.execute(
            "INSERT INTO fire_data (lat, lon, acq_date, data) VALUES (?, ?, ?, jsonb(?))",
            (-10.0, -50.0, "2024-01-01", data_json),
        )
        news_data = json.dumps({"title": "Test"}, separators=(",", ":"))
        conn.execute(
            "INSERT INTO news (url, publishedAt, data) VALUES (?, ?, jsonb(?))",
            ("https://example.com/1", datetime.now(timezone.utc).isoformat(), news_data),
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
        print("PASS: stats counts (JSONB)")
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
        data_json = json.dumps({"confidence": "low"}, separators=(",", ":"))
        conn.execute(
            "INSERT INTO fire_data (lat, lon, acq_date, ingested_at, data) VALUES (?, ?, ?, ?, jsonb(?))",
            (-10.0, -50.0, "2023-01-01", old, data_json),
        )
        conn.execute(
            "INSERT INTO fire_data (lat, lon, acq_date, ingested_at, data) VALUES (?, ?, ?, ?, jsonb(?))",
            (-11.0, -51.0, "2024-06-01", new, data_json),
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
        print("PASS: prune old fires (JSONB)")
    finally:
        os.unlink(path)


def test_json_extract_on_jsonb():
    """Test that json_extract works on JSONB BLOB columns."""
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        path = f.name
    try:
        conn = sqlite3.connect(path)
        conn.executescript(SCHEMA)

        data_json = json.dumps({"confidence": "high", "satellite": "NPP"}, separators=(",", ":"))
        conn.execute(
            "INSERT INTO fire_data (lat, lon, acq_date, data) VALUES (?, ?, ?, jsonb(?))",
            (-10.0, -50.0, "2024-01-01", data_json),
        )
        conn.commit()

        # json_extract should work on JSONB BLOB
        cursor = conn.execute(
            "SELECT json_extract(data, '$.confidence') FROM fire_data WHERE lat = ?",
            (-10.0,),
        )
        result = cursor.fetchone()[0]
        assert result == "high", f"Expected 'high', got {result}"

        # Expression index should work
        cursor = conn.execute(
            "SELECT COUNT(*) FROM fire_data WHERE json_extract(data, '$.confidence') = ?",
            ("high",),
        )
        assert cursor.fetchone()[0] == 1

        conn.close()
        print("PASS: json_extract on JSONB BLOB")
    finally:
        os.unlink(path)


def test_jsonb_migration_from_legacy():
    """Test migrating from legacy flat-column schema to JSONB schema."""
    LEGACY_SCHEMA = """
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
    """

    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        path = f.name
    try:
        # Create legacy DB
        conn = sqlite3.connect(path)
        conn.executescript(LEGACY_SCHEMA)
        now = datetime.now(timezone.utc).isoformat()
        conn.execute(
            """INSERT INTO fire_data (lat, lon, confidence, acq_date, acq_time,
               satellite, bright_ti4, source, ingested_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (-10.5, -55.0, "high", "2024-01-01", "12:00", "NPP", 350.0,
             "NASA_FIRMS_VIIRS_SNPP", now),
        )
        conn.commit()

        # Verify legacy data
        cursor = conn.execute("SELECT confidence FROM fire_data")
        assert cursor.fetchone()[0] == "high"

        # Migrate to JSONB schema
        conn.executescript("""
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
        conn.commit()

        # Copy data using jsonb()
        cursor = conn.execute("SELECT id, lat, lon, acq_date, ingested_at, confidence, acq_time, satellite, bright_ti4, source FROM fire_data")
        for row in cursor.fetchall():
            data_json = json.dumps({
                "confidence": row[5],
                "acq_time": row[6],
                "satellite": row[7],
                "bright_ti4": row[8],
                "source": row[9],
            }, separators=(",", ":"))
            conn.execute(
                "INSERT INTO fire_data_new (id, lat, lon, acq_date, ingested_at, data) VALUES (?, ?, ?, ?, ?, jsonb(?))",
                (row[0], row[1], row[2], row[3], row[4], data_json),
            )
        conn.commit()

        conn.execute("DROP TABLE fire_data")
        conn.execute("ALTER TABLE fire_data_new RENAME TO fire_data")
        conn.commit()

        # Verify migrated data using json() to convert JSONB to text
        cursor = conn.execute("SELECT lat, lon, acq_date, json(data) AS data_json FROM fire_data")
        row = cursor.fetchone()
        assert row[0] == -10.5
        data = json.loads(row[3])
        assert data["confidence"] == "high"
        assert data["satellite"] == "NPP"

        conn.close()
        print("PASS: JSONB migration from legacy schema")
    finally:
        os.unlink(path)


if __name__ == "__main__":
    _check_sqlite_version()
    test_schema()
    test_fire_insert_and_query()
    test_fire_unique_constraint()
    test_news_insert_and_query()
    test_deforestation_insert_and_query()
    test_stats()
    test_prune_old_fires()
    test_json_extract_on_jsonb()
    test_jsonb_migration_from_legacy()
    print("\n=== ALL TESTS PASSED ===")

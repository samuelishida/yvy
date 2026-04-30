#!/usr/bin/env python3
"""Migrate Yvy SQLite database from legacy flat-column schema to JSONB schema.

This script:
1. Checks SQLite version (needs >= 3.45.0 for jsonb())
2. Detects legacy schema (columns like 'confidence' in fire_data)
3. Creates new tables with JSONB BLOB columns
4. Migrates data using jsonb() for binary conversion
5. Swaps tables and recreates indexes
6. Runs VACUUM to reclaim space

Usage:
    python migrate_to_jsonb.py [--db PATH] [--dry-run] [--vacuum]

Options:
    --db PATH     Path to SQLite database (default: backend/data/yvy.db)
    --dry-run     Show what would be migrated without making changes
    --vacuum      Run VACUUM after migration to reclaim disk space
"""

# Monkey-patch sqlite3 with pysqlite3-binary (bundled SQLite 3.45+)
# so we get JSONB support even on systems with older SQLite (e.g. Ubuntu 22.04).
import sys
try:
    import pysqlite3 as sqlite3_fallback
    if sqlite3_fallback.sqlite_version_info >= (3, 45, 0):
        sys.modules["sqlite3"] = sqlite3_fallback
    else:
        raise ImportError(f"pysqlite3 SQLite {sqlite3_fallback.sqlite_version} < 3.45.0")
except ImportError:
    pass  # Fall back to stdlib sqlite3 — will fail version check if too old

import argparse
import json
import os
import shutil
import sqlite3
import sys
import time

DEFAULT_DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "yvy.db")


def check_sqlite_version(conn):
    """Verify SQLite supports JSONB (>= 3.45.0)."""
    version_str = conn.execute("SELECT sqlite_version()").fetchone()[0]
    parts = version_str.split(".")
    major, minor = int(parts[0]), int(parts[1])
    patch = int(parts[2]) if len(parts) > 2 else 0
    version_num = major * 10000 + minor * 100 + patch

    print(f"SQLite version: {version_str}")
    if version_num < 34500:
        print(f"ERROR: SQLite {version_str} does not support JSONB (need >= 3.45.0)")
        print("Please upgrade SQLite or use a Python with a newer built-in sqlite3.")
        sys.exit(1)

    print(f"✓ SQLite {version_str} supports JSONB")
    return version_str


def detect_legacy_schema(conn):
    """Check if the database has legacy flat-column tables."""
    tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()}

    legacy = {}
    if "fire_data" in tables:
        cols = {row[1] for row in conn.execute("PRAGMA table_info(fire_data)").fetchall()}
        if "confidence" in cols:
            legacy["fire_data"] = True

    if "deforestation_data" in tables:
        cols = {row[1] for row in conn.execute("PRAGMA table_info(deforestation_data)").fetchall()}
        if "name" in cols:
            legacy["deforestation_data"] = True

    if "news" in tables:
        cols = {row[1] for row in conn.execute("PRAGMA table_info(news)").fetchall()}
        if "title" in cols:
            legacy["news"] = True

    return legacy


def get_row_counts(conn):
    """Get row counts for all tables."""
    counts = {}
    for table in ("fire_data", "deforestation_data", "news"):
        try:
            counts[table] = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        except Exception:
            counts[table] = 0
    return counts


def migrate_fire_data(conn, dry_run=False):
    """Migrate fire_data from flat columns to JSONB."""
    # Check if already migrated
    cols = {row[1] for row in conn.execute("PRAGMA table_info(fire_data)").fetchall()}
    if "confidence" not in cols:
        print("  fire_data: already JSONB schema, skipping")
        return 0

    count = conn.execute("SELECT COUNT(*) FROM fire_data").fetchone()[0]
    print(f"  fire_data: migrating {count} rows from flat columns to JSONB...")

    if dry_run:
        print(f"  [DRY RUN] Would migrate {count} rows")
        return count

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

    cursor = conn.execute("""
        SELECT id, lat, lon, acq_date, ingested_at,
               confidence, acq_time, satellite, bright_ti4, source
        FROM fire_data
    """)
    rows = cursor.fetchall()
    migrated = 0
    for row in rows:
        data_json = json.dumps({
            "confidence": row[5],
            "acq_time": row[6],
            "satellite": row[7],
            "bright_ti4": row[8],
            "source": row[9],
        }, separators=(",", ":"), ensure_ascii=False)
        conn.execute(
            "INSERT INTO fire_data_new (id, lat, lon, acq_date, ingested_at, data) VALUES (?, ?, ?, ?, ?, jsonb(?))",
            (row[0], row[1], row[2], row[3], row[4], data_json),
        )
        migrated += 1

    conn.execute("DROP TABLE fire_data")
    conn.execute("ALTER TABLE fire_data_new RENAME TO fire_data")
    conn.executescript("""
        CREATE INDEX IF NOT EXISTS idx_fire_lat ON fire_data(lat);
        CREATE INDEX IF NOT EXISTS idx_fire_lon ON fire_data(lon);
        CREATE INDEX IF NOT EXISTS idx_fire_acq_date ON fire_data(acq_date);
        CREATE INDEX IF NOT EXISTS idx_fire_confidence ON fire_data(json_extract(data, '$.confidence'));
    """)
    conn.commit()
    print(f"  fire_data: migrated {migrated} rows ✓")
    return migrated


def migrate_deforestation_data(conn, dry_run=False):
    """Migrate deforestation_data from flat columns to JSONB."""
    cols = {row[1] for row in conn.execute("PRAGMA table_info(deforestation_data)").fetchall()}
    if "name" not in cols:
        print("  deforestation_data: already JSONB schema, skipping")
        return 0

    count = conn.execute("SELECT COUNT(*) FROM deforestation_data").fetchone()[0]
    print(f"  deforestation_data: migrating {count} rows from flat columns to JSONB...")

    if dry_run:
        print(f"  [DRY RUN] Would migrate {count} rows")
        return count

    conn.executescript("""
        CREATE TABLE IF NOT EXISTS deforestation_data_new (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            lat REAL,
            lon REAL,
            data BLOB
        );
    """)
    conn.commit()

    cursor = conn.execute("""
        SELECT id, lat, lon, name, clazz, periods, source, color, timestamp
        FROM deforestation_data
    """)
    rows = cursor.fetchall()
    migrated = 0
    for row in rows:
        data_json = json.dumps({
            "name": row[3],
            "clazz": row[4],
            "periods": row[5],
            "source": row[6],
            "color": row[7],
            "timestamp": row[8],
        }, separators=(",", ":"), ensure_ascii=False)
        conn.execute(
            "INSERT INTO deforestation_data_new (id, lat, lon, data) VALUES (?, ?, ?, jsonb(?))",
            (row[0], row[1], row[2], data_json),
        )
        migrated += 1

    conn.execute("DROP TABLE deforestation_data")
    conn.execute("ALTER TABLE deforestation_data_new RENAME TO deforestation_data")
    conn.executescript("""
        CREATE INDEX IF NOT EXISTS idx_def_lat ON deforestation_data(lat);
        CREATE INDEX IF NOT EXISTS idx_def_lon ON deforestation_data(lon);
        CREATE INDEX IF NOT EXISTS idx_def_name ON deforestation_data(json_extract(data, '$.name'));
    """)
    conn.commit()
    print(f"  deforestation_data: migrated {migrated} rows ✓")
    return migrated


def migrate_news(conn, dry_run=False):
    """Migrate news from flat columns to JSONB."""
    cols = {row[1] for row in conn.execute("PRAGMA table_info(news)").fetchall()}
    if "title" not in cols:
        print("  news: already JSONB schema, skipping")
        return 0

    count = conn.execute("SELECT COUNT(*) FROM news").fetchone()[0]
    print(f"  news: migrating {count} rows from flat columns to JSONB...")

    if dry_run:
        print(f"  [DRY RUN] Would migrate {count} rows")
        return count

    conn.executescript("""
        CREATE TABLE IF NOT EXISTS news_new (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url TEXT UNIQUE NOT NULL,
            publishedAt TEXT,
            ingested_at TEXT,
            data BLOB
        );
    """)
    conn.commit()

    cursor = conn.execute("""
        SELECT id, url, publishedAt, ingested_at,
               title, description, title_en, description_en,
               source_name, urlToImage, content
        FROM news
    """)
    rows = cursor.fetchall()
    migrated = 0
    for row in rows:
        data_json = json.dumps({
            "title": row[4],
            "description": row[5],
            "title_en": row[6],
            "description_en": row[7],
            "source_name": row[8],
            "urlToImage": row[9],
            "content": row[10],
        }, separators=(",", ":"), ensure_ascii=False)
        ingested = row[3] or row[2]  # ingested_at or publishedAt
        conn.execute(
            "INSERT INTO news_new (id, url, publishedAt, ingested_at, data) VALUES (?, ?, ?, ?, jsonb(?))",
            (row[0], row[1], row[2], ingested, data_json),
        )
        migrated += 1

    conn.execute("DROP TABLE news")
    conn.execute("ALTER TABLE news_new RENAME TO news")
    conn.executescript("""
        CREATE INDEX IF NOT EXISTS idx_news_published ON news(publishedAt);
        CREATE INDEX IF NOT EXISTS idx_news_ingested ON news(ingested_at);
        CREATE INDEX IF NOT EXISTS idx_news_source ON news(json_extract(data, '$.source_name'));
    """)
    conn.commit()
    print(f"  news: migrated {migrated} rows ✓")
    return migrated


def verify_migration(conn):
    """Verify the migration was successful by checking schema and data integrity."""
    print("\n--- Verification ---")

    # Check fire_data schema
    cols = {row[1] for row in conn.execute("PRAGMA table_info(fire_data)").fetchall()}
    assert "data" in cols, "fire_data missing 'data' column"
    assert "confidence" not in cols, "fire_data still has legacy 'confidence' column"
    print("  fire_data: ✓ JSONB schema")

    # Check deforestation_data schema
    cols = {row[1] for row in conn.execute("PRAGMA table_info(deforestation_data)").fetchall()}
    assert "data" in cols, "deforestation_data missing 'data' column"
    assert "name" not in cols, "deforestation_data still has legacy 'name' column"
    print("  deforestation_data: ✓ JSONB schema")

    # Check news schema
    cols = {row[1] for row in conn.execute("PRAGMA table_info(news)").fetchall()}
    assert "data" in cols, "news missing 'data' column"
    assert "title" not in cols, "news still has legacy 'title' column"
    print("  news: ✓ JSONB schema")

    # Verify data integrity
    fire_count = conn.execute("SELECT COUNT(*) FROM fire_data").fetchone()[0]
    def_count = conn.execute("SELECT COUNT(*) FROM deforestation_data").fetchone()[0]
    news_count = conn.execute("SELECT COUNT(*) FROM news").fetchone()[0]
    print(f"\n  Row counts: fires={fire_count}, deforestation={def_count}, news={news_count}")

    # Spot-check JSONB data (use json() to convert BLOB to text)
    if fire_count > 0:
        row = conn.execute("SELECT json(data) FROM fire_data LIMIT 1").fetchone()
        data = json.loads(row[0])
        assert "confidence" in data, "fire_data JSONB missing 'confidence' key"
        print(f"  fire_data sample: {data}")

    if def_count > 0:
        row = conn.execute("SELECT json(data) FROM deforestation_data LIMIT 1").fetchone()
        data = json.loads(row[0])
        assert "name" in data, "deforestation_data JSONB missing 'name' key"
        print(f"  deforestation_data sample: {data}")

    if news_count > 0:
        row = conn.execute("SELECT json(data) FROM news LIMIT 1").fetchone()
        data = json.loads(row[0])
        assert "title" in data, "news JSONB missing 'title' key"
        print(f"  news sample: {data}")

    print("\n✓ All verifications passed!")


def main():
    parser = argparse.ArgumentParser(description="Migrate Yvy SQLite to JSONB schema")
    parser.add_argument("--db", default=DEFAULT_DB_PATH, help="Path to SQLite database")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be migrated without making changes")
    parser.add_argument("--vacuum", action="store_true", help="Run VACUUM after migration")
    args = parser.parse_args()

    db_path = os.path.abspath(args.db)
    print(f"Database: {db_path}")

    if not os.path.exists(db_path):
        print(f"ERROR: Database file not found: {db_path}")
        sys.exit(1)

    # Create backup
    if not args.dry_run:
        backup_path = f"{db_path}.backup.{int(time.time())}"
        print(f"Creating backup: {backup_path}")
        shutil.copy2(db_path, backup_path)
        print(f"✓ Backup created")

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row

    # Check SQLite version
    check_sqlite_version(conn)

    # Detect legacy schema
    print("\n--- Detecting schema ---")
    legacy = detect_legacy_schema(conn)
    if not legacy:
        print("No legacy tables found. Database is already using JSONB schema.")
        conn.close()
        return

    counts = get_row_counts(conn)
    for table, is_legacy in legacy.items():
        status = "NEEDS MIGRATION" if is_legacy else "OK"
        print(f"  {table}: {status} ({counts.get(table, 0)} rows)")

    # Migrate
    print("\n--- Migrating ---")
    total_migrated = 0

    if "fire_data" in legacy:
        total_migrated += migrate_fire_data(conn, dry_run=args.dry_run)

    if "deforestation_data" in legacy:
        total_migrated += migrate_deforestation_data(conn, dry_run=args.dry_run)

    if "news" in legacy:
        total_migrated += migrate_news(conn, dry_run=args.dry_run)

    print(f"\nTotal rows migrated: {total_migrated}")

    # Verify
    if not args.dry_run:
        verify_migration(conn)

    # VACUUM
    if args.vacuum and not args.dry_run:
        print("\n--- Running VACUUM ---")
        conn.execute("VACUUM")
        print("✓ VACUUM complete")

    conn.close()

    # Show file sizes
    db_size = os.path.getsize(db_path)
    print(f"\nDatabase size: {db_size / 1024 / 1024:.2f} MB")

    if args.dry_run:
        print("\n[DRY RUN] No changes were made to the database.")
    else:
        print("\n✓ Migration complete!")


if __name__ == "__main__":
    main()
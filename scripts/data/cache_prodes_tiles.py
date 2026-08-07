#!/usr/bin/env python3
"""Pre-fetch PRODES WMS tiles for Brazil and cache to SQLite.

Reads deforestation point lat/lon from yvy.db, computes which XYZ tiles
each point falls in at each zoom level, fetches those tiles from the
TerraBrasilis WMS, and stores the PNG blobs in tiles_prodes.db.

Usage:
    python scripts/data/cache_prodes_tiles.py [--min-zoom N] [--max-zoom N] [--workers N]

Options:
    --min-zoom N     Lowest zoom to pre-fetch (default: 4)
    --max-zoom N     Highest zoom to pre-fetch (default: 10)
    --workers N      Concurrent HTTP workers (default: 6)
    --db PATH        Override tiles_prodes.db path
    --deforest-db P  Override yvy.db path
"""

import sys
import os
import math
import sqlite3
import argparse
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from threading import Lock

try:
    import requests
except ImportError:
    print("ERROR: Missing requests. Install with: pip install requests", file=sys.stderr)
    sys.exit(1)

WMS_URL = "https://terrabrasilis.dpi.inpe.br/geoserver/prodes-brasil-nb/prodes_brasil/wms"
WMS_PARAMS_BASE = {
    "SERVICE": "WMS",
    "VERSION": "1.1.1",
    "REQUEST": "GetMap",
    "LAYERS": "prodes_brasil",
    "FORMAT": "image/png",
    "TRANSPARENT": "TRUE",
    "SRS": "EPSG:4326",
    "WIDTH": "256",
    "HEIGHT": "256",
}


def tile_to_bbox(z, x, y):
    """XYZ tile -> WGS84 (lon_min, lat_min, lon_max, lat_max)."""
    n = 2 ** z
    lon_min = x / n * 360 - 180
    lon_max = (x + 1) / n * 360 - 180
    lat_max = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))
    lat_min = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (y + 1) / n))))
    return lon_min, lat_min, lon_max, lat_max


def latlon_to_tile(lat, lon, z):
    """lat/lon -> (x, y) tile at zoom z."""
    n = 2 ** z
    x = int((lon + 180) / 360 * n)
    lat_rad = math.radians(lat)
    y = int((1 - math.log(math.tan(lat_rad) + 1 / math.cos(lat_rad)) / math.pi) / 2 * n)
    return max(0, min(n - 1, x)), max(0, min(n - 1, y))


def init_tiles_db(path):
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=NORMAL")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS tiles (
            z INTEGER NOT NULL,
            x INTEGER NOT NULL,
            y INTEGER NOT NULL,
            data BLOB NOT NULL,
            content_type TEXT DEFAULT 'image/png',
            fetched_at TEXT NOT NULL,
            PRIMARY KEY (z, x, y)
        )
    """)
    conn.commit()
    return conn


def fetch_tile(z, x, y, session):
    lon_min, lat_min, lon_max, lat_max = tile_to_bbox(z, x, y)
    params = {
        **WMS_PARAMS_BASE,
        "BBOX": f"{lon_min:.6f},{lat_min:.6f},{lon_max:.6f},{lat_max:.6f}",
    }
    resp = session.get(WMS_URL, params=params, timeout=30)
    resp.raise_for_status()
    ct = resp.headers.get("Content-Type", "")
    if "image" not in ct:
        return None
    return resp.content


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--min-zoom",    type=int, default=4)
    parser.add_argument("--max-zoom",    type=int, default=10)
    parser.add_argument("--workers",     type=int, default=6)
    parser.add_argument("--db",          default=None, help="Override tiles_prodes.db path")
    parser.add_argument("--deforest-db", default=None, help="Override yvy.db path")
    args = parser.parse_args()

    script_dir   = os.path.dirname(os.path.abspath(__file__))
    project_dir  = os.path.dirname(script_dir)
    data_dir     = os.path.join(project_dir, "backend-lua", "data")
    tiles_db_path   = args.db or os.path.join(data_dir, "tiles_prodes.db")
    deforest_db_path = args.deforest_db

    if not deforest_db_path:
        for candidate in [os.path.join(data_dir, "yvy.db"),
                          os.path.join(data_dir, "deforestation.db")]:
            if os.path.exists(candidate):
                deforest_db_path = candidate
                break

    if not deforest_db_path or not os.path.exists(deforest_db_path):
        print("ERROR: Deforestation DB not found. Use --deforest-db PATH", file=sys.stderr)
        sys.exit(1)

    print(f"Deforestation DB : {deforest_db_path}")
    print(f"Tiles DB         : {tiles_db_path}")
    print(f"Zoom range       : {args.min_zoom} - {args.max_zoom}")
    print(f"Workers          : {args.workers}")

    print("\nReading PRODES lat/lon from DB...")
    src = sqlite3.connect(deforest_db_path)
    points = src.execute("SELECT lat, lon FROM deforestation_data").fetchall()
    src.close()
    print(f"  {len(points):,} points")

    print("\nComputing tile sets per zoom...")
    tile_sets = {}
    for z in range(args.min_zoom, args.max_zoom + 1):
        tiles = set()
        for lat, lon in points:
            tiles.add(latlon_to_tile(lat, lon, z))
        tile_sets[z] = tiles
        print(f"  z{z}: {len(tiles):,} tiles")

    total = sum(len(t) for t in tile_sets.values())
    print(f"\nTotal tiles : {total:,}")

    tiles_conn = init_tiles_db(tiles_db_path)
    cached = set(tiles_conn.execute("SELECT z, x, y FROM tiles").fetchall())
    print(f"Already cached: {len(cached):,}")

    work = [(z, x, y) for z, tiles in tile_sets.items()
            for (x, y) in tiles if (z, x, y) not in cached]
    print(f"To fetch      : {len(work):,}\n")

    if not work:
        print("All tiles already cached.")
        tiles_conn.close()
        return

    db_lock = Lock()
    batch   = []
    BATCH   = 100
    done = saved = skipped = errors = 0
    t0 = time.time()

    def flush(b):
        with db_lock:
            tiles_conn.executemany(
                "INSERT OR REPLACE INTO tiles (z,x,y,data,content_type,fetched_at) "
                "VALUES (?,?,?,'image/png',datetime('now'))",
                [(z, x, y) for z, x, y, _ in b],
            )
            # Re-insert with BLOB data (executemany can't mix types easily)
            for z, x, y, data in b:
                tiles_conn.execute(
                    "INSERT OR REPLACE INTO tiles (z,x,y,data,content_type,fetched_at) "
                    "VALUES (?,?,?,?,?,datetime('now'))",
                    (z, x, y, data, "image/png"),
                )
            tiles_conn.commit()

    def fetch_one(item):
        z, x, y = item
        sess = requests.Session()
        sess.headers["User-Agent"] = "Yvy/1.0 tile-cache"
        data = fetch_tile(z, x, y, sess)
        return z, x, y, data

    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(fetch_one, t): t for t in work}
        for fut in as_completed(futs):
            done += 1
            try:
                z, x, y, data = fut.result()
                if data:
                    with db_lock:
                        tiles_conn.execute(
                            "INSERT OR REPLACE INTO tiles (z,x,y,data,content_type,fetched_at) "
                            "VALUES (?,?,?,?,?,datetime('now'))",
                            (z, x, y, data, "image/png"),
                        )
                        if done % BATCH == 0:
                            tiles_conn.commit()
                    saved += 1
                else:
                    skipped += 1
            except Exception as e:
                errors += 1

            if done % 200 == 0 or done == len(work):
                elapsed = time.time() - t0
                rate = done / elapsed if elapsed > 0 else 0
                eta  = (len(work) - done) / rate if rate > 0 else 0
                print(
                    f"  {done:,}/{len(work):,} ({done/len(work)*100:.0f}%)"
                    f"  saved={saved:,}  skipped={skipped}  errors={errors}"
                    f"  {rate:.0f} t/s  ETA {eta:.0f}s",
                    flush=True,
                )

    tiles_conn.commit()
    total_cached = tiles_conn.execute("SELECT COUNT(*) FROM tiles").fetchone()[0]
    size_mb = os.path.getsize(tiles_db_path) / 1e6
    print(f"\nDone. {total_cached:,} tiles in DB -> {tiles_db_path}  ({size_mb:.1f} MB)")
    tiles_conn.close()


if __name__ == "__main__":
    main()

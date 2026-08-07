#!/usr/bin/env python3
"""Download Cerrado vegetation types → raster XYZ tiles (WMS proxy).

Plan: terrabrasilis-integration, Inc 9. Fetches Cerrado vegetation tiles from
the TerraBrasilis GeoServer WMS (`vegetation-cerrado:vegetation_types`, spec
§3.5) — one GetMap request per tile, the server renders — and caches the PNGs
into tiles_cerrado_veg.db (backend for GET /api/tiles/cerrado-veg).

Offline dev tool — never on the prod VM / copas loop (cold-cache invariant).

The polygon WFS layer has ~2.35M features, so local rendering is infeasible;
the WMS proxy is the supported path. Zoom is bounded to z6–z9 (the Cerrado
extent only — tiles fully outside the biome are skipped, so the real count is
~1.6k, not the ~104k of a Brazil-wide sweep). The full z6–z12 range would be
millions of requests even via WMS.

Usage:
    python3 scripts/data/download_cerrado_veg.py
    python3 scripts/data/download_cerrado_veg.py --min-zoom 6 --max-zoom 9 --workers 8
    python3 scripts/data/download_cerrado_veg.py --out backend-lua/data/tiles_cerrado_veg.db
"""
import argparse
import math
import os
import sqlite3
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from threading import Lock

try:
    import requests
except ImportError:
    print("ERROR: Missing requests. Install with: pip install requests", file=sys.stderr)
    sys.exit(1)

WMS_URL = "https://terrabrasilis.dpi.inpe.br/geoserver/vegetation-cerrado/wms"
WMS_PARAMS_BASE = {
    "SERVICE": "WMS",
    "VERSION": "1.1.1",
    "REQUEST": "GetMap",
    "LAYERS": "vegetation_types",
    "FORMAT": "image/png",
    "TRANSPARENT": "TRUE",
    "SRS": "EPSG:4326",
    "WIDTH": "256",
    "HEIGHT": "256",
}

# Generous Cerrado biome bounds (lon_min, lat_min, lon_max, lat_max). Tiles
# fully outside are skipped to avoid thousands of transparent fetches.
CERRADO_BBOX = (-63.0, -26.0, -38.0, 0.0)


def tile_to_bbox(z, x, y):
    """XYZ tile -> WGS84 (lon_min, lat_min, lon_max, lat_max)."""
    n = 2 ** z
    lon_min = x / n * 360 - 180
    lon_max = (x + 1) / n * 360 - 180
    lat_max = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))
    lat_min = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (y + 1) / n))))
    return lon_min, lat_min, lon_max, lat_max


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
    if "image" not in resp.headers.get("Content-Type", ""):
        return None
    return resp.content


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--min-zoom", type=int, default=6)
    parser.add_argument("--max-zoom", type=int, default=9)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--out", default=None, help="Override tiles_cerrado_veg.db path")
    parser.add_argument("--bbox", default=None, metavar="LONMIN,LATMIN,LONMAX,LATMAX",
                        help="Override Cerrado bounding box (default: generous biome box)")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(os.path.dirname(script_dir))
    out_db = args.out or os.path.join(repo_root, "backend-lua", "data", "tiles_cerrado_veg.db")
    lon_min, lat_min, lon_max, lat_max = (
        tuple(map(float, args.bbox.split(","))) if args.bbox else CERRADO_BBOX
    )

    print(f"Tiles DB   : {out_db}")
    print(f"Zoom range : {args.min_zoom} - {args.max_zoom}")
    print(f"Workers    : {args.workers}")
    print(f"BBox       : lon {lon_min}..{lon_max}, lat {lat_min}..{lat_max}")

    # Enumerate tiles intersecting the bbox, per zoom.
    work = []
    for z in range(args.min_zoom, args.max_zoom + 1):
        n = 2 ** z
        tiles = []
        for x in range(n):
            x_lon_min = x / n * 360 - 180
            x_lon_max = (x + 1) / n * 360 - 180
            if x_lon_max < lon_min or x_lon_min > lon_max:
                continue
            for y in range(n):
                _, t_lat_min, _, t_lat_max = tile_to_bbox(z, x, y)
                if t_lat_max < lat_min or t_lat_min > lat_max:
                    continue
                tiles.append((z, x, y))
        work.extend(tiles)
        print(f"  z{z}: {len(tiles):,} tiles")

    print(f"\nTotal tiles : {len(work):,}")

    conn = init_tiles_db(out_db)
    cached = set(conn.execute("SELECT z, x, y FROM tiles").fetchall())
    print(f"Already cached: {len(cached):,}")

    todo = [t for t in work if t not in cached]
    print(f"To fetch      : {len(todo):,}\n")

    if not todo:
        print("All tiles already cached.")
        conn.close()
        return

    db_lock = Lock()
    done = saved = errors = 0
    t0 = time.time()

    def fetch_one(item):
        z, x, y = item
        sess = requests.Session()
        sess.headers["User-Agent"] = "Yvy/1.0 tile-cache"
        data = fetch_tile(z, x, y, sess)
        return z, x, y, data

    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(fetch_one, t): t for t in todo}
        for fut in as_completed(futs):
            done += 1
            try:
                z, x, y, data = fut.result()
                if data:
                    with db_lock:
                        conn.execute(
                            "INSERT OR REPLACE INTO tiles (z,x,y,data,content_type,fetched_at) "
                            "VALUES (?,?,?,?,?,?)",
                            (z, x, y, data, "image/png",
                             datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")),
                        )
                        if done % 100 == 0:
                            conn.commit()
                    saved += 1
            except Exception:
                errors += 1

            if done % 200 == 0 or done == len(todo):
                elapsed = time.time() - t0
                rate = done / elapsed if elapsed > 0 else 0
                eta = (len(todo) - done) / rate if rate > 0 else 0
                print(
                    f"  {done:,}/{len(todo):,} ({done/len(todo)*100:.0f}%)"
                    f"  saved={saved:,}  errors={errors}"
                    f"  {rate:.0f} t/s  ETA {eta:.0f}s",
                    flush=True,
                )

    conn.commit()
    total = conn.execute("SELECT COUNT(*) FROM tiles").fetchone()[0]
    size_mb = os.path.getsize(out_db) / 1e6
    print(f"\nDone. {total:,} tiles in DB -> {out_db}  ({size_mb:.1f} MB)")
    conn.close()


if __name__ == "__main__":
    main()

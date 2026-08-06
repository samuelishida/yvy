#!/usr/bin/env python3
"""Render CAR (Cadastro Ambiental Rural) polygons to raster XYZ tiles.

Reads car.db (car_data + car_rtree, JSONB geometry) and rasterizes the
imóvel polygons into 256x256 PNG tiles stored in tiles_car.db — the data
backend for GET /api/tiles/car (see .plans/car-overlay/plan.md, Inc 1).

Offline, dev-run tool (never on the prod VM / copas loop): rasterizing
8.4M imóveis is CPU-heavy and only needs re-running when car.db is rebuilt.

Design notes (from plan review):
  - Fill is rendered OPAQUE (alpha 255); the frontend TileLayer opacity
    (0.5) is the single transparency control. No alpha baked into tiles —
    avoids the double-alpha (~25% effective) trap and keeps overlaps from
    double-darkening.
  - Low zoom (z <= fill_max_zoom) emits a uniform opaque fill for any tile
    an imóvel bbox touches (no polygon decode) — big CPU saver, CAR region
    is ~continuous at those zooms.
  - Higher zooms: RTree bbox-intersect → decode only candidates via
    json(geom) → ray-cast-free raster fill, with a bounded LRU memoizing
    decoded geometry by id (an imóvel spanning many tiles is decoded once).
  - Resumable: tiles already present in the output DB are skipped.

Usage:
    python3 scripts/render_car_tiles.py [--min-zoom 6] [--max-zoom 12]
        [--car-db backend-lua/data/car/car.db]
        [--out backend-lua/data/tiles_car.db]
        [--fill "#a3e635"] [--fill-max-zoom 7] [--self-test]
"""

import sys
import os
import math
import json
import sqlite3
import argparse
import time
from collections import OrderedDict
from concurrent.futures import ProcessPoolExecutor, as_completed

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("ERROR: Missing Pillow. Install with: pip install pillow", file=sys.stderr)
    sys.exit(1)

# Brazil bounds (clamp helper only — car_rtree bboxes already cover Brazil).
BR_LAT_MIN, BR_LAT_MAX, BR_LON_MIN, BR_LON_MAX = -34.0, 5.5, -74.0, -34.0


def tile_to_bbox(z, x, y):
    """XYZ tile -> WGS84 (lon_min, lat_min, lon_max, lat_max).

    Same formula as backend-lua/app/routes/tiles.lua:48-56.
    """
    n = 2 ** z
    lon_min = x / n * 360 - 180
    lon_max = (x + 1) / n * 360 - 180
    lat_max = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))
    lat_min = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (y + 1) / n))))
    return lon_min, lat_min, lon_max, lat_max


# Web mercator is undefined at the poles; SICAR dumps can contain degenerate
# bboxes (lat exactly ±90) whose tan+sec cancels to a tiny negative, blowing up
# math.log. Clamp before computing (returned x/y are already clamped to the map).
MERC_LAT_CLAMP = 89.9


def latlon_to_tile(lat, lon, z):
    """lat/lon -> (x, y) tile at zoom z (slippy-map).

    Same formula as scripts/cache_prodes_tiles.py:58-65.
    """
    n = 2 ** z
    x = int((lon + 180) / 360 * n)
    lat = max(-MERC_LAT_CLAMP, min(MERC_LAT_CLAMP, lat))
    lat_rad = math.radians(lat)
    y = int((1 - math.log(math.tan(lat_rad) + 1 / math.cos(lat_rad)) / math.pi) / 2 * n)
    return max(0, min(n - 1, x)), max(0, min(n - 1, y))


def lonlat_to_tile_px(lon, lat, z, x, y):
    """lon/lat -> pixel coords within tile (z,x,y), 256px tiles."""
    n = 2 ** z
    wx = (lon + 180) / 360 * n * 256
    lat = max(-MERC_LAT_CLAMP, min(MERC_LAT_CLAMP, lat))
    lat_rad = math.radians(lat)
    wy = (1 - math.log(math.tan(lat_rad) + 1 / math.cos(lat_rad)) / math.pi) / 2 * n * 256
    return wx - x * 256, wy - y * 256


def bbox_to_tile_range(z, lon_min, lat_min, lon_max, lat_max):
    """BBox -> inclusive tile range ((x0, y0), (x1, y1)) at zoom z."""
    x0, y_top = latlon_to_tile(lat_max, lon_min, z)   # north-west corner
    x1, y_bot = latlon_to_tile(lat_min, lon_max, z)   # south-east corner
    return (min(x0, x1), min(y_top, y_bot)), (max(x0, x1), max(y_top, y_bot))


def parse_fill(hex_color):
    """'#a3e635' -> (r, g, b)."""
    h = hex_color.lstrip("#")
    if len(h) != 6:
        raise ValueError(f"invalid --fill {hex_color!r}; use #rrggbb")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def open_car_db(path):
    if not os.path.exists(path):
        print(f"ERROR: car.db not found at {path} (use --car-db)", file=sys.stderr)
        sys.exit(1)
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA query_only=ON")
    return conn


def init_out_db(path):
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=OFF")          # bulk load
    conn.execute("PRAGMA cache_size=-200000")
    conn.execute("PRAGMA temp_store=MEMORY")
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


def covered_tiles(car_db, z):
    """Set of (x, y) tiles at zoom z that any car_rtree bbox touches."""
    n = 2 ** z
    tiles = set()
    cur = car_db.execute(
        "SELECT minLon, minLat, maxLon, maxLat FROM car_rtree"
    )
    for min_lon, min_lat, max_lon, max_lat in cur:
        (x0, y0), (x1, y1) = bbox_to_tile_range(z, min_lon, min_lat, max_lon, max_lat)
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                tiles.add((x, y))
    return tiles


def uniform_tile(rgb):
    """256x256 PNG, opaque fill, as bytes."""
    img = Image.new("RGBA", (256, 256), (*rgb, 255))
    buf = io_bytes(img)
    return buf


def io_bytes(img):
    import io
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


def decode_geometry(geom_text):
    """json(geom) text -> list of rings (each ring = list of [lon, lat] pairs)."""
    geom = json.loads(geom_text)
    if not isinstance(geom, dict) or "coordinates" not in geom:
        return None
    if geom.get("type") == "Polygon":
        polys = [geom["coordinates"]]
    elif geom.get("type") == "MultiPolygon":
        polys = geom["coordinates"]
    else:
        return None
    rings = []
    for poly in polys:
        for ring in poly:
            rings.append([[float(pt[0]), float(pt[1])] for pt in ring])
    return rings if rings else None


class LruDict(OrderedDict):
    """OrderedDict with a size cap, evicting oldest on insert."""

    def __init__(self, maxsize=8000):
        super().__init__()
        self.maxsize = maxsize

    def get(self, key, default=None):
        if key in self:
            self.move_to_end(key)
            return super().get(key, default)
        return default

    def put(self, key, value):
        if key in self:
            self.move_to_end(key)
        self[key] = value
        if len(self) > self.maxsize:
            self.popitem(last=False)


RTREE_INTERSECT_SQL = (
    "SELECT id, minLon, maxLon, minLat, maxLat FROM car_rtree "
    "WHERE maxLon >= ? AND minLon <= ? AND maxLat >= ? AND minLat <= ?"
)
GET_GEOM_SQL = "SELECT id, json(geom) AS g FROM car_data WHERE id IN (%s)"


def _bbox_px_size(lon_min, lat_min, lon_max, lat_max, z, x, y):
    """Pixel width/height of a bbox within tile (z,x,y), 256px tiles."""
    x0, y0 = lonlat_to_tile_px(lon_min, lat_max, z, x, y)
    x1, y1 = lonlat_to_tile_px(lon_max, lat_min, z, x, y)
    return abs(x1 - x0), abs(y1 - y0)


def render_tile(car_db, z, x, y, rgb, fill_max_zoom, geom_cache, min_px=0.0):
    """Render one tile. Returns PNG bytes, or None if the canvas is empty."""
    if z <= fill_max_zoom:
        return uniform_tile(rgb)

    lon_min, lat_min, lon_max, lat_max = tile_to_bbox(z, x, y)

    # 1. Candidate imóveis whose bbox intersects this tile.
    cands = car_db.execute(RTREE_INTERSECT_SQL, (lon_min, lon_max, lat_min, lat_max)).fetchall()
    if not cands:
        return None

    # 1b. Sub-pixel skip: imóveis whose bbox maps to < min_px in both dims
    #     can't contribute a visible pixel (big decode saver at z8+).
    if min_px > 0:
        ids = [
            rid for (rid, c_lon_min, c_lon_max, c_lat_min, c_lat_max) in cands
            if min(_bbox_px_size(c_lon_min, c_lat_min, c_lon_max, c_lat_max, z, x, y)) >= min_px
        ]
    else:
        ids = [r[0] for r in cands]
    if not ids:
        return None

    # 2. Decode geometry for candidates (chunked, memoized per worker).
    rings_list = []
    for i in range(0, len(ids), 500):
        chunk = ids[i:i + 500]
        placeholders = ",".join("?" * len(chunk))
        rows = car_db.execute(GET_GEOM_SQL % placeholders, chunk).fetchall()
        for rid, geom_text in rows:
            rings = geom_cache.get(rid)
            if rings is None:
                if geom_text:
                    rings = decode_geometry(geom_text)
                if rings is None:
                    continue
                geom_cache.put(rid, rings)
            rings_list.append(rings)

    if not rings_list:
        return None

    # 3. Rasterize (opaque fill; CSS layer opacity handles transparency).
    img = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    for rings in rings_list:
        for ring in rings:
            pts = [lonlat_to_tile_px(lon, lat, z, x, y) for lon, lat in ring]
            draw.polygon(pts, fill=(*rgb, 255))
    return io_bytes(img)


def _render_worker(args):
    """Worker: render a chunk of tiles in a subprocess (own car.db read conn).
    Returns [(x, y, png), ...]."""
    car_db_path, z, rgb, fill_max_zoom, min_px, tiles = args
    car_db = open_car_db(car_db_path)
    geom_cache = LruDict()
    out = []
    for x, y in tiles:
        png = render_tile(car_db, z, x, y, rgb, fill_max_zoom, geom_cache, min_px)
        if png is not None:
            out.append((x, y, png))
    car_db.close()
    return out


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--min-zoom", type=int, default=6)
    parser.add_argument("--max-zoom", type=int, default=12)
    parser.add_argument("--car-db", default=None, help="Override car.db path")
    parser.add_argument("--out", default=None, help="Override tiles_car.db path")
    parser.add_argument("--fill", default="#a3e635", help="Overlay color #rrggbb")
    parser.add_argument("--fill-max-zoom", type=int, default=7,
                        help="Zoom <= this uses uniform fill (no polygon decode)")
    parser.add_argument("--workers", type=int, default=None,
                        help="Render worker processes (default: min(16, cpu_count))")
    parser.add_argument("--min-px", type=float, default=0.5,
                        help="Skip imóveis whose bbox is smaller than this many pixels")
    parser.add_argument("--self-test", action="store_true",
                        help="Assert tile math round-trips, then exit")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return

    script_dir = os.path.dirname(os.path.abspath(__file__))
    data_dir = os.path.join(os.path.dirname(script_dir), "backend-lua", "data")
    car_db_path = args.car_db or os.path.join(data_dir, "car", "car.db")
    out_path = args.out or os.path.join(data_dir, "tiles_car.db")

    if args.min_zoom < 0 or args.max_zoom < args.min_zoom or args.max_zoom > 16:
        print("ERROR: invalid zoom range (0 <= min <= max <= 16)", file=sys.stderr)
        sys.exit(1)

    rgb = parse_fill(args.fill)
    print(f"car.db        : {car_db_path}")
    print(f"tiles_car.db  : {out_path}")
    print(f"zoom range    : {args.min_zoom} - {args.max_zoom}")
    print(f"fill          : #{''.join(f'{c:02x}' for c in rgb)} (opaque; layer opacity applies)")
    print(f"fill-max-zoom : {args.fill_max_zoom}")

    car_db = open_car_db(car_db_path)
    n_imoveis = car_db.execute("SELECT COUNT(*) FROM car_data").fetchone()[0]
    print(f"imóveis       : {n_imoveis:,}")

    out = init_out_db(out_path)
    cached = set(out.execute("SELECT z, x, y FROM tiles").fetchall())
    print(f"already cached: {len(cached):,}", flush=True)

    workers = args.workers or min(16, (os.cpu_count() or 4))
    print(f"workers       : {workers}", flush=True)

    total = 0
    t_all = time.time()
    CHUNK = 200
    for z in range(args.min_zoom, args.max_zoom + 1):
        t0 = time.time()
        tiles = covered_tiles(car_db, z)
        work = sorted((x, y) for (x, y) in tiles if (z, x, y) not in cached)
        if not work:
            print(f"z{z}: tudo cacheado ({len(tiles):,} cobertos)", flush=True)
            continue
        chunks = [work[i:i + CHUNK] for i in range(0, len(work), CHUNK)]
        rendered = 0
        with ProcessPoolExecutor(max_workers=workers) as ex:
            futures = [
                ex.submit(_render_worker,
                          (car_db_path, z, rgb, args.fill_max_zoom, args.min_px, chunk))
                for chunk in chunks
            ]
            for fut in as_completed(futures):
                for x, y, png in fut.result():
                    out.execute(
                        "INSERT OR REPLACE INTO tiles (z,x,y,data,content_type,fetched_at) "
                        "VALUES (?,?,?,?,'image/png',datetime('now'))",
                        (z, x, y, png),
                    )
                    rendered += 1
                out.commit()
        total += rendered
        print(f"z{z}: {rendered:,} tiles em {time.time() - t0:.1f}s "
              f"({len(tiles):,} cobertos, {workers} workers)", flush=True)

    out.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    out.execute("PRAGMA optimize")
    out.commit()
    out.close()
    car_db.close()
    print(f"\ndone: {total:,} tiles -> {out_path} em {time.time() - t_all:.1f}s", flush=True)


def self_test():
    """Pin the tile math duplicated across Python/Lua (tile_to_bbox ↔ latlon_to_tile)."""
    import random
    random.seed(42)
    failures = 0
    for z in range(0, 14):
        n = 2 ** z
        for _ in range(500):
            lon = random.uniform(-74, -34)
            lat = random.uniform(-34, 5.5)
            x, y = latlon_to_tile(lat, lon, z)
            lon_min, lat_min, lon_max, lat_max = tile_to_bbox(z, x, y)
            if not (lon_min <= lon <= lon_max and lat_min <= lat <= lat_max):
                print(f"FAIL z{z}: point ({lat},{lon}) not in tile ({x},{y}) "
                      f"bbox ({lon_min},{lat_min},{lon_max},{lat_max})")
                failures += 1
            # Center of a tile must round-trip back to the same tile.
            cx, cy = (lon_min + lon_max) / 2, (lat_min + lat_max) / 2
            if latlon_to_tile(cy, cx, z) != (x, y):
                print(f"FAIL z{z}: tile center ({cy},{cx}) -> {latlon_to_tile(cy, cx, z)} != ({x},{y})")
                failures += 1
    if failures:
        print(f"self-test FAILED: {failures} mismatches", file=sys.stderr)
        sys.exit(1)
    print("self-test OK: tile math round-trips (tile_to_bbox ↔ latlon_to_tile)")


if __name__ == "__main__":
    main()

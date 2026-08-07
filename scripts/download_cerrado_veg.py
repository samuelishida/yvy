#!/usr/bin/env python3
"""Download Cerrado vegetation types → raster XYZ tiles.

Plan: terrabrasilis-integration, Inc 9. Fetches the Cerrado vegetation polygon
layer from the TerraBrasilis GeoServer WFS (spec §3.4, `vegetation-cerrado:
vegetation_types`) and renders colored polygon tiles into tiles_cerrado_veg.db
(backend for GET /api/tiles/cerrado-veg).

Offline dev tool — never on the prod VM / copas loop (cold-cache invariant).

Usage:
    python3 scripts/download_cerrado_veg.py
    python3 scripts/download_cerrado_veg.py --workspace vegetation-cerrado --layer vegetation_types
    python3 scripts/download_cerrado_veg.py --out backend-lua/data/tiles_cerrado_veg.db --min-zoom 6 --max-zoom 12
"""
import argparse
import io
import json
import math
import os
import sqlite3
import sys
import time
from datetime import datetime, timezone

import requests
from PIL import Image, ImageDraw

BASE = "https://terrabrasilis.dpi.inpe.br/geoserver/{ws}/ows"
PAGE = 10000
UA = "Mozilla/5.0 (X11; Linux x86_64) Yvy/1.0"

# Tipo de vegetação → RGBA (exemplos; ajuste às classes reais do layer)
VEG_COLORS = {
    "formacao_florestal": (34, 139, 34, 255),
    "formacao_savânica": (189, 183, 107, 255),
    "formacao_campestre": (238, 232, 170, 255),
    "floresta_estacional": (46, 125, 50, 255),
    "agropecuaria": (241, 196, 15, 255),
    "area_urbana": (120, 144, 156, 255),
    "corpo_dagua": (0, 188, 212, 255),
    "outros": (176, 190, 197, 255),
}


def tile_to_bbox(z, x, y):
    n = 2 ** z
    lon_min = x / n * 360 - 180
    lon_max = (x + 1) / n * 360 - 180
    lat_max = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))
    lat_min = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (y + 1) / n))))
    return lon_min, lat_min, lon_max, lat_max


def _project(lon, lat, z, x, y, size=256):
    """Web-mercator → pixel no tile."""
    n = 2 ** z
    px = (lon + 180.0) / 360.0 * n
    lat_r = math.radians(lat)
    py = (1.0 - math.asinh(math.tan(lat_r)) / math.pi) / 2.0 * n
    return (px - x) * size, (py - y) * size


def fetch_veg(ws: str, layer: str) -> list:
    features = []
    start = 0
    while True:
        params = {
            "service": "WFS", "version": "1.1.0", "request": "GetFeature",
            "typeName": f"{ws}:{layer}", "outputFormat": "application/json",
            "maxFeatures": str(PAGE), "startIndex": str(start),
        }
        r = requests.get(BASE.format(ws=ws), params=params, timeout=180, headers={"User-Agent": UA})
        r.raise_for_status()
        page = r.json().get("features", [])
        features.extend(page)
        print(f"  page {start // PAGE + 1} -> +{len(page)} (total {len(features)})", flush=True)
        if len(page) < PAGE:
            break
        start += PAGE
        time.sleep(0.3)
    return features


def render_tile(features, z, x, y):
    """Desenha polígonos de vegetação no tile → PNG RGBA."""
    lon_min, lat_min, lon_max, lat_max = tile_to_bbox(z, x, y)
    img = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    count = 0
    for f in features:
        geom = f.get("geometry")
        if not geom:
            continue
        props = f.get("properties") or {}
        name = None
        for col in ("classe", "class_name", "nome", "tipo", "label", "name"):
            if props.get(col):
                name = props[col]
                break
        color = VEG_COLORS.get(str(name).lower().replace(" ", "_"), VEG_COLORS["outros"])

        # BBox pré-filtro (raster draw rápido)
        coords = geom.get("coordinates") or []
        if geom.get("type") == "Polygon":
            coords = [coords]
        for poly in coords:
            rings = poly if poly and isinstance(poly[0], list) else [poly]
            for ring in rings:
                pts = [(_project(c[0], c[1], z, x, y)) for c in ring]
                # só desenha se o polígono toca o tile
                if any(-10 <= px <= 266 and -10 <= py <= 266 for px, py in pts):
                    draw.polygon(pts, fill=color)
                    count += 1
    return img if count else None


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--workspace", default="vegetation-cerrado")
    ap.add_argument("--layer", default="vegetation_types")
    ap.add_argument("--out", default=os.path.join("backend-lua", "data", "tiles_cerrado_veg.db"))
    ap.add_argument("--min-zoom", type=int, default=6)
    ap.add_argument("--max-zoom", type=int, default=12)
    args = ap.parse_args()

    print("fetching vegetation features...")
    features = fetch_veg(args.workspace, args.layer)
    if not features:
        print("ERROR: no features fetched", file=sys.stderr)
        sys.exit(1)

    out_db = args.out
    conn = sqlite3.connect(out_db)
    conn.execute("""CREATE TABLE IF NOT EXISTS tiles (
        z INTEGER NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL,
        data BLOB NOT NULL, content_type TEXT DEFAULT 'image/png',
        fetched_at TEXT NOT NULL, PRIMARY KEY (z, x, y))""")
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    br_lat_min, br_lat_max, br_lon_min, br_lon_max = -34.0, 5.5, -74.0, -34.0
    done = 0
    for z in range(args.min_zoom, args.max_zoom + 1):
        n = 2 ** z
        for x in range(n):
            lon_min = x / n * 360 - 180
            lon_max = (x + 1) / n * 360 - 180
            if lon_max < br_lon_min or lon_min > br_lon_max:
                continue
            for y in range(n):
                _, lat_min, _, lat_max = tile_to_bbox(z, x, y)
                if lat_max < br_lat_min or lat_min > br_lat_max:
                    continue
                if conn.execute("SELECT 1 FROM tiles WHERE z=? AND x=? AND y=?", (z, x, y)).fetchone():
                    continue
                img = render_tile(features, z, x, y)
                if img is None:
                    continue
                buf = io.BytesIO()
                img.save(buf, format="PNG")
                conn.execute("INSERT OR REPLACE INTO tiles (z,x,y,data,content_type,fetched_at) VALUES (?,?,?,?,?,?)",
                             (z, x, y, buf.getvalue(), "image/png", now))
                done += 1
                if done % 500 == 0:
                    conn.commit()
                    print(f"  z{z}: {done} tiles...", flush=True)
        conn.commit()
        print(f"  zoom {z} done ({done} total)", flush=True)
    conn.commit()
    conn.close()
    print(f"done: {done} tiles -> {out_db}")


if __name__ == "__main__":
    main()

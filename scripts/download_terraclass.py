#!/usr/bin/env python3
"""Download TerraClass / Vegetação Secundária raster → raster XYZ tiles.

Plan: terrabrasilis-integration, Inc 9. TerraClass (Amazônia, ~30m) is a
multi-billion-pixel raster — point-based SQLite is infeasible, so we render
precomputed PNG tiles (same cold-cache pattern as tiles_car.db / tiles_prodes.db).

Output: tiles_terraclass.db with key (z, x, y, layer) — one DB, two datasets:
  layer="terraclass"     → classes de uso do solo
  layer="veg_secundaria" → vegetação secundária (residual/regrowth, spec §5 P3)

Usage:
    python3 scripts/download_terraclass.py
    python3 scripts/download_terraclass.py --tif path/to/terraclass.tif --layer terraclass
    python3 scripts/download_terraclass.py --out backend-lua/data/tiles_terraclass.db --min-zoom 6 --max-zoom 12

NOTE: the TerraClass download URL is not pinned in the spec — locate the
current raster on TerraBrasilis /downloads/ (or BiomasBR) on first run and
either pass --tif or hardcode it below.
"""
import argparse
import os
import sqlite3
import sys
import math
from datetime import datetime, timezone

try:
    import rasterio
    import numpy as np
    from PIL import Image
except ImportError:
    print("ERROR: need rasterio + numpy + pillow (see scripts/requirements.txt)", file=sys.stderr)
    sys.exit(1)

# TerraClass class → RGBA (exemplos; ajuste à legenda QML real do raster)
CLASS_COLORS = {
    1: (46, 125, 50, 255),     # floresta
    3: (121, 85, 72, 255),     # pastagem
    4: (241, 196, 15, 255),    # agricultura
    5: (158, 157, 36, 255),    # mosaico
    12: (255, 87, 34, 255),    # regeneração com pasto
    15: (0, 188, 212, 255),    # água
    19: (120, 144, 156, 255),  # não observado / outros
}

# Lookup de 256 cores indexado por valor de classe (classe 0 = transparente).
_PALETTE = np.zeros((256, 4), dtype=np.uint8)
for cls, color in CLASS_COLORS.items():
    _PALETTE[cls] = color


def tile_to_bbox(z, x, y):
    n = 2 ** z
    lon_min = x / n * 360 - 180
    lon_max = (x + 1) / n * 360 - 180
    lat_max = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * y / n))))
    lat_min = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (y + 1) / n))))
    return lon_min, lat_min, lon_max, lat_max


def render_tile(src, z, x, y):
    """Rasteriza a janela do tile do GeoTIFF para um PNG RGBA."""
    from rasterio.windows import from_bounds
    lon_min, lat_min, lon_max, lat_max = tile_to_bbox(z, x, y)
    if lon_min >= lon_max or lat_min >= lat_max:
        return None
    try:
        window = from_bounds(lon_min, lat_min, lon_max, lat_max, transform=src.transform)
    except Exception:
        return None
    if window.width <= 0 or window.height <= 0 or window.width > 10000 or window.height > 10000:
        return None
    # Leitura nativa (espera-se raster WGS84/EPSG:4674, como o PRODES). Rasters
    # em outra projeção precisariam de reprojeção (fora do escopo inicial).
    data = src.read(1, window=window, boundless=True)
    data = data.astype("uint8")

    # Vectorizado: mapa de cores indexado por classe → RGBA → PNG
    rgba = _PALETTE[data]
    img = Image.fromarray(rgba, "RGBA")
    return img


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--tif", default=None, help="TerraClass GeoTIFF (auto-tenta local)")
    ap.add_argument("--layer", default="terraclass", choices=["terraclass", "veg_secundaria"])
    ap.add_argument("--out", default=os.path.join("backend-lua", "data", "tiles_terraclass.db"))
    ap.add_argument("--min-zoom", type=int, default=6)
    ap.add_argument("--max-zoom", type=int, default=12)
    ap.add_argument("--fill-max-zoom", type=int, default=7)
    args = ap.parse_args()

    tif = args.tif
    if not tif:
        for cand in ("backend-lua/data/terraclass/terraclass.tif",
                     "backend-lua/data/terraclass/veg_secundaria.tif",
                     "/opt/yvy/backend-lua/data/terraclass/terraclass.tif"):
            if os.path.exists(cand):
                tif = cand
                break
    if not tif:
        print("ERROR: no TerraClass raster found — pass --tif", file=sys.stderr)
        sys.exit(1)

    out_db = args.out
    conn = sqlite3.connect(out_db)
    conn.execute("""CREATE TABLE IF NOT EXISTS tiles (
        z INTEGER NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL, layer TEXT NOT NULL,
        data BLOB NOT NULL, content_type TEXT DEFAULT 'image/png',
        fetched_at TEXT NOT NULL, PRIMARY KEY (z, x, y, layer))""")
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    with rasterio.open(tif) as src:
        # Bounds do Brasil (clamp)
        br_lat_min, br_lat_max, br_lon_min, br_lon_max = -34.0, 5.5, -74.0, -34.0
        done = 0
        for z in range(args.min_zoom, args.max_zoom + 1):
            n = 2 ** z
            for x in range(n):
                # filtra eixos X fora do Brasil
                lon_min = x / n * 360 - 180
                lon_max = (x + 1) / n * 360 - 180
                if lon_max < br_lon_min or lon_min > br_lon_max:
                    continue
                for y in range(n):
                    _, lat_min, _, lat_max = tile_to_bbox(z, x, y)
                    if lat_max < br_lat_min or lat_min > br_lat_max:
                        continue
                    # resumable: pula tiles já gravados
                    if conn.execute("SELECT 1 FROM tiles WHERE z=? AND x=? AND y=? AND layer=?",
                                    (z, x, y, args.layer)).fetchone():
                        continue
                    img = render_tile(src, z, x, y)
                    if img is None:
                        continue
                    import io
                    buf = io.BytesIO()
                    img.save(buf, format="PNG")
                    conn.execute("INSERT OR REPLACE INTO tiles (z,x,y,layer,data,content_type,fetched_at) VALUES (?,?,?,?,?,?,?)",
                                 (z, x, y, args.layer, buf.getvalue(), "image/png", now))
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

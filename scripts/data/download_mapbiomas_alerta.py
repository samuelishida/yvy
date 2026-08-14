#!/usr/bin/env python3
"""Download MapBiomas Alerta deforestation alerts → mapbiomas_alerta.db.

The MapBiomas Alerta platform (plataforma.alerta.mapbiomas.org) publishes a
SINGLE national shapefile of validated deforestation alerts (polygons +
attributes) at a stable public URL (no login). Unlike Sinaflor (CKAN) there is
no per-state CKAN package. This script mirrors the `download_sinaflor_auth.py`
pipeline shape (download → normalize → dedicated SQLite DB → atomic swap) but
with the MapBiomas Alerta source.

Flow: download the national shapefile → normalize columns → resolve CAR code
(spatial fallback against the local car.db, offline, never in the Lua loop) →
write a dedicated SQLite DB atomically.

Live schema notes (verified 2026-08-13 against the real national shapefile —
see .agents/common-mistakes/common-mistakes.md #4):
- The shapefile is a ZIP containing `dashboard_alerts-shapefile.shp` (+ .dbf,
  .prj, .shx). CRS is EPSG:4674 (SIRGAS 2000).
- Columns (uppercase): `CODEALERTA` (int), `FONTE` (str), `BIOMA` (str),
  `ESTADO` (str, e.g. "MATO GROSSO"), `MUNICIPIO` (str), `AREAHA` (float),
  `ANODETEC` (float, detection year), `DATADETEC` (date), `DTPUBLI` (date),
  `VPRESSAO` (str), plus a Polygon geometry.
- `codealerta` is the canonical alert code; `data_deteccao` is the detection
  date; `data_publicacao` is the publication date.
- The geometry is a polygon; we derive the bbox (minLon/maxLon/minLat/maxLat)
  for RTree queries and store the raw geometry WKT as a blob.
- The MapBiomas alerts do NOT carry a CAR code; the spatial fallback
  (lat/lon centroid → CAR polygon via local car.db) is the PRIMARY path.

The DB file itself is the success marker: it is written to `<out>.tmp` and
atomically `os.replace`d only after a fully successful import, so a failed run
leaves the previous DB (and its mtime) intact. `sync-mapbiomas.sh` re-runs this
when the DB mtime is older than 7 days.

Usage:
    python3 scripts/data/download_mapbiomas_alerta.py                # default window (2 anos)
    python3 scripts/data/download_mapbiomas_alerta.py --today 2026-08-13  # override clock (tests)
    python3 scripts/data/download_mapbiomas_alerta.py --force        # re-download even with recent DB
    python3 scripts/data/download_mapbiomas_alerta.py --window 365  # keep alerts with ano_det >= today - window
    python3 scripts/data/download_mapbiomas_alerta.py --states MT PA
    python3 scripts/data/download_mapbiomas_alerta.py --out backend-lua/data/mapbiomas/mapbiomas_alerta.db
"""
import argparse
import json
import os
import re
import sqlite3
import sys
import time
import zipfile
from datetime import date
from pathlib import Path

import pandas as pd
import requests

UA = "Mozilla/5.0 (X11; Linux x86_64) Yvy/1.0"
BATCH = 1000

# Stable public URL of the national MapBiomas Alerta shapefile (no login).
# Overridable via env MAPBIOMAS_ALERTA_URL for tests/backup mirrors.
SHAPEFILE_URL = ("https://storage.googleapis.com/alerta-public/dashboard/"
                 "downloads/dashboard_alerts-shapefile.zip")


def _norm_col(s):
    return re.sub(r"[^a-z0-9]", "", str(s).lower())


def _find_column(df, aliases):
    """First existing column among aliases, case/punctuation-insensitive."""
    norm = {_norm_col(c): c for c in df.columns}
    for a in aliases:
        key = _norm_col(a)
        if key in norm:
            return norm[key]
    return None


def _parse_date(value):
    """ISO `YYYY-MM-DD` → `YYYY-MM-DD` or None (accepts date/datetime)."""
    if value is None:
        return None
    v = str(value).strip()
    if not v:
        return None
    m = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})", v[:10])
    if m:
        y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if 1 <= mo <= 12 and 1 <= d <= 31:
            return "{:04d}-{:02d}-{:02d}".format(y, mo, d)
    return None


def _parse_float(value):
    """Parse a decimal with dot or comma separator; None on garbage."""
    if value is None:
        return None
    v = str(value).strip().replace(" ", "")
    if not v:
        return None
    if "," in v and "." not in v:
        v = v.replace(",", ".")
    try:
        return float(v)
    except ValueError:
        return None


def download_shapefile(url, dest):
    """Stream the national shapefile ZIP to `dest`, retrying with backoff."""
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    for attempt in range(3):
        try:
            with requests.get(url, stream=True, timeout=300,
                              headers={"User-Agent": UA}) as r:
                r.raise_for_status()
                with open(part, "wb") as f:
                    for chunk in r.iter_content(chunk_size=1 << 20):
                        if chunk:
                            f.write(chunk)
            break
        except Exception:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)
    os.replace(part, dest)
    return dest


def extract_shapefile(zip_path, workdir):
    """Extract a national shapefile ZIP; return the .shp path.

    Detects ZIP by magic bytes (`PK\\x03\\x04`), never by extension. Selects the
    `.shp` member (ignores the `__MACOSX` metadata that ships in the archive).
    Fails loudly if no `.shp` member is found.
    """
    zip_path = Path(zip_path)
    with open(zip_path, "rb") as f:
        magic = f.read(2)
    if magic != b"PK":
        raise RuntimeError("{}: not a ZIP archive".format(zip_path))

    workdir = Path(workdir)
    workdir.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as z:
        shp_names = [n for n in z.namelist() if n.lower().endswith(".shp")]
        if not shp_names:
            raise RuntimeError("{}: zip contains no .shp member".format(zip_path))
        # Prefer the top-level member (not the __MACOSX metadata copy).
        top = [n for n in shp_names if not n.startswith("__MACOSX")]
        shp = (top or shp_names)[0]
        base = Path(shp).stem
        for n in z.namelist():
            if n.startswith("__MACOSX"):
                continue
            if Path(n).stem == base:
                z.extract(n, workdir)
    return workdir / shp


def read_alerts(shp_path):
    """Read the national shapefile → DataFrame of canonical alert columns.

    Uses geopandas to load geometry and derive each alert's bbox and centroid.
    Returns (df, has_geom). Fails loudly if geopandas is unavailable (the bbox
    geometry is REQUIRED for the runtime RTree lookup).
    """
    import geopandas as gpd
    gdf = gpd.read_file(str(shp_path))
    df = gdf.drop(columns=["geometry"]).copy()

    # bbox per alert (minLon, maxLon, minLat, maxLat) + centroid lat/lon.
    bounds = gdf.geometry.bounds
    df["_minlon"] = bounds["minx"]
    df["_maxlon"] = bounds["maxx"]
    df["_minlat"] = bounds["miny"]
    df["_maxlat"] = bounds["maxy"]
    df["_clon"] = (bounds["minx"] + bounds["maxx"]) / 2
    df["_clat"] = (bounds["miny"] + bounds["maxy"]) / 2
    df["_geom_wkt"] = gdf.geometry.to_wkt()
    return df, True


def normalize(df, today, window_days, states, has_geom):
    """Map the shapefile DataFrame to canonical columns and apply filters.

    Returns (out, dropped) where `dropped` is a dict of drop-reason counts.
    """
    col = lambda aliases: _find_column(df, aliases)  # noqa: E731
    code_col = col(["codealerta", "alert_code", "cod_alerta", "id"])
    source_col = col(["fonte", "source"])
    area_col = col(["areaha", "area_ha", "area"])
    biome_col = col(["bioma", "biome"])
    state_col = col(["estado", "state", "uf"])
    city_col = col(["municipio", "city", "municipality"])
    ano_col = col(["anodetec", "ano_det", "ano", "year"])
    det_col = col(["datadetec", "data_deteccao", "data_det"])
    pub_col = col(["dtpubli", "data_publicacao", "data_pub"])

    out = pd.DataFrame()
    out["alert_code"] = (df[code_col].astype(str).str.strip()
                         if code_col else "")
    out["source"] = (df[source_col].astype(str).str.strip()
                     if source_col else "")
    out["area_ha"] = (df[area_col].map(_parse_float) if area_col else None)
    out["biome"] = (df[biome_col].astype(str).str.strip() if biome_col else "")
    out["state"] = (df[state_col].astype(str).str.strip().str.upper()
                    if state_col else "")
    out["city"] = (df[city_col].astype(str).str.strip() if city_col else "")
    out["ano_det"] = (df[ano_col].map(_parse_float) if ano_col else None)
    out["data_deteccao"] = (df[det_col].map(_parse_date) if det_col else None)
    out["data_publicacao"] = (df[pub_col].map(_parse_date) if pub_col else None)

    if has_geom:
        out["lat"] = pd.to_numeric(df["_clat"], errors="coerce")
        out["lon"] = pd.to_numeric(df["_clon"], errors="coerce")
        out["geom"] = df["_geom_wkt"].astype(str)
        out["bbox"] = [
            json.dumps([minlon, maxlon, minlat, maxlat])
            if minlon == minlon else None  # NaN guard
            for minlon, maxlon, minlat, maxlat in zip(
                df["_minlon"], df["_maxlon"], df["_minlat"], df["_maxlat"])
        ]
    else:
        out["lat"] = None
        out["lon"] = None
        out["geom"] = ""
        out["bbox"] = None

    dropped = {}

    before = len(out)
    out = out[out["alert_code"] != ""]
    dropped["sem_codigo"] = before - len(out)

    if ano_col:
        before = len(out)
        out["ano_det"] = out["ano_det"].fillna(0).astype(int)
        cutoff = today.year - window_days // 365
        out = out[out["ano_det"] >= cutoff]
        dropped["fora_da_janela"] = before - len(out)

    if states:
        state_set = {s.strip().upper() for s in states if s.strip()}
        before = len(out)
        out = out[out["state"].isin(state_set)]
        dropped["uf_filtrada"] = before - len(out)

    return out.reset_index(drop=True), dropped


def resolve_car(df, car_db_path, enable_spatial=True):
    """Fill `cod_imovel`: spatial fallback (lat/lon → CAR polygon).

    MapBiomas alerts do not carry a CAR column, so the spatial fallback against
    the local car.db is the ONLY path. Returns (out, counts). When car.db is
    unavailable the rows are left without cod_imovel (dropped downstream with a
    logged count — never crashes).
    """
    out = df.copy()
    out["cod_imovel"] = ""

    car_col = _find_column(df, ["cod_imovel", "nro_car", "car_code"])
    if car_col:
        out["cod_imovel"] = df[car_col].astype(str).str.strip().str.upper()
    explicit = out["cod_imovel"] != ""

    need = (~explicit) & out["lon"].notna() & out["lat"].notna()
    counts = {"explicit_car": int(explicit.sum()),
              "spatial_needed": int(need.sum()), "spatial_resolved": 0}

    if counts["spatial_needed"] == 0 or not enable_spatial:
        return out, counts
    if not car_db_path or not os.path.exists(car_db_path):
        print("WARN: car.db not found at {} — spatial resolve skipped; rows "
              "without explicit CAR will be dropped".format(car_db_path))
        return out, counts

    conn = sqlite3.connect("file:{}?mode=ro".format(car_db_path), uri=True,
                           timeout=60)
    conn.execute("PRAGMA busy_timeout=60000")
    try:
        for idx in out.index[need]:
            code = classify_point(conn, float(out.at[idx, "lon"]),
                                  float(out.at[idx, "lat"]))
            if code:
                out.at[idx, "cod_imovel"] = code
                counts["spatial_resolved"] += 1
    finally:
        conn.close()
    return out, counts


def classify_point(car_conn, lon, lat):
    """CAR cod_imovel of the largest-area property containing (lon, lat), or None.

    Mirrors backend-lua `car_lookup.classify_point`: RTree bbox candidates →
    decode only those → shapely point-in-polygon → match of LARGEST AREA.
    """
    rows = car_conn.execute(
        "SELECT id FROM car_rtree WHERE minLon<=? AND maxLon>=? AND minLat<=? "
        "AND maxLat>=?",
        (lon, lon, lat, lat)).fetchall()
    if not rows:
        return None
    ids = [r[0] for r in rows]
    ph = ",".join("?" * len(ids))
    best, best_area = None, -1.0
    # car.db stores geometry as a msgpack blob; SQLite's json(geom) converts it
    # to GeoJSON text (same as car_lookup.lua:34). Never json.loads the raw blob.
    for r in car_conn.execute(
        "SELECT cod_imovel, area, json(geom) AS g FROM car_data WHERE id IN ({})".format(ph),
        ids):
        g = r[2]
        if not g:
            continue
        try:
            from shapely.geometry import Point, shape
            geom = shape(json.loads(g))
        except Exception:
            continue
        try:
            contains = geom.contains(Point(lon, lat))
        except Exception:  # noqa: BLE001 - invalid geometry → not contained
            contains = False
        if contains:
            area = float(r[1] or 0)
            if area > best_area:
                best_area = area
                best = r[0]
    return str(best).upper() if best else None


def write_db(df, out_path):
    """Write `mapbiomas_alerta.db` atomically via `<out>.tmp` + os.replace.

    A fresh single-file DB (DELETE journal mode): the runtime opens it with a
    `query_only=ON` handle, and the whole-file swap (like car.db) is safe under
    an existing reader. Only a fully-successful import replaces the target, so
    the DB file's mtime is the "marker after success" (common-mistake #5).
    """
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = out_path.with_name(out_path.name + ".tmp")
    conn = sqlite3.connect(tmp)
    try:
        conn.execute("PRAGMA journal_mode=DELETE")
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS alerts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                alert_code TEXT UNIQUE,
                source TEXT,
                area_ha REAL,
                biome TEXT,
                state TEXT,
                city TEXT,
                ano_det INTEGER,
                data_deteccao TEXT,
                data_publicacao TEXT,
                cod_imovel TEXT,
                geom BLOB,
                bbox TEXT
            );
            CREATE TABLE IF NOT EXISTS alerts_rtree (
                id INTEGER PRIMARY KEY,
                minLon REAL, maxLon REAL, minLat REAL, maxLat REAL
            );
        """)
        cols = ["alert_code", "source", "area_ha", "biome", "state", "city",
                "ano_det", "data_deteccao", "data_publicacao", "cod_imovel",
                "geom", "bbox"]
        rows = list(df[cols].itertuples(index=False, name=None))
        sql = ("INSERT INTO alerts "
               "(alert_code, source, area_ha, biome, state, city, ano_det, "
               "data_deteccao, data_publicacao, cod_imovel, geom, bbox) "
               "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)")
        rtree_sql = ("INSERT INTO alerts_rtree (id, minLon, maxLon, minLat, "
                     "maxLat) VALUES (?,?,?,?,?)")
        for i in range(0, len(rows), BATCH):
            chunk = rows[i:i + BATCH]
            conn.executemany(sql, chunk)
            for j, r in enumerate(chunk):
                # r[11] is the `bbox` JSON string (minLon, maxLon, minLat, maxLat).
                if r[11]:
                    try:
                        b = json.loads(r[11])
                        conn.execute(rtree_sql,
                                     (i + j + 1, b[0], b[1], b[2], b[3]))
                    except Exception:
                        pass
        conn.commit()
        conn.execute("CREATE INDEX IF NOT EXISTS idx_alerts_ano "
                     "ON alerts(ano_det)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_alerts_cod_imovel "
                     "ON alerts(cod_imovel)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_alerts_rtree_id "
                     "ON alerts_rtree(id)")
        conn.commit()
        conn.execute("VACUUM")
        conn.commit()
    finally:
        conn.close()
    os.replace(tmp, out_path)
    return len(rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--window", type=int, default=730,
                    help="keep alerts with ano_det >= today - window/365 (days)")
    ap.add_argument("--today", default=None,
                    help="ISO date to anchor the window (deterministic tests)")
    ap.add_argument("--force", action="store_true",
                    help="re-download even when the DB is younger than 7 days")
    ap.add_argument("--states", nargs="*", default=None,
                    help="state filter (ex: MT PA)")
    ap.add_argument("--no-car-resolve", action="store_true",
                    help="skip the spatial CAR fallback")
    ap.add_argument("--url", default=None,
                    help="override the national shapefile URL")
    ap.add_argument("--out",
                    default="backend-lua/data/mapbiomas/mapbiomas_alerta.db")
    args = ap.parse_args()

    today = date.fromisoformat(args.today) if args.today else date.today()
    out = Path(args.out)

    # Freshness guard: the DB mtime is the success marker; skip when recent.
    if out.exists() and not args.force:
        age_days = (time.time() - out.stat().st_mtime) / 86400
        if age_days < 7:
            print("mapbiomas_alerta.db is {:.1f} days old — skipping download "
                  "(use --force to re-download)".format(age_days))
            return 0

    car_db_path = os.environ.get("CAR_DB_PATH") or "backend-lua/data/car/car.db"
    url = args.url or os.environ.get("MAPBIOMAS_ALERTA_URL") or SHAPEFILE_URL

    workdir = Path("/tmp/yvy_mapbiomas_work")
    zip_dest = workdir / "alerts.zip"

    print("[download] {}".format(url))
    download_shapefile(url, zip_dest)
    print("[extract] {}".format(zip_dest))
    shp_path = extract_shapefile(zip_dest, workdir)
    print("[read] {}".format(shp_path))

    df, has_geom = read_alerts(shp_path)
    norm, dropped = normalize(df, today, args.window, args.states, has_geom)
    print("[normalize] {} rows (drops: {})".format(len(norm), dropped))

    combined, car_counts = resolve_car(norm, car_db_path,
                                       enable_spatial=not args.no_car_resolve)
    before = len(combined)
    kept = combined[combined["cod_imovel"] != ""]
    no_car = before - len(kept)

    n = write_db(kept, out)
    print("\n=== mapbiomas_alerta.db written to {} ===".format(out))
    print("rows: {} (drops: {}; rows without cod_imovel dropped: {})".format(
        n, dropped, no_car))
    print("car resolve: {}".format(car_counts))
    print("marker (db mtime): {}".format(
        date.fromtimestamp(out.stat().st_mtime)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - top-level abort without marker
        print("ERROR: {} — no DB written (previous mapbiomas_alerta.db, if any, "
              "is intact)".format(exc), file=sys.stderr)
        sys.exit(1)

#!/usr/bin/env python3
"""Download IBAMA embargo terms (CKAN) → embargo.db.

The `embargo` factor (weight 0.20) in `risk_score.lua` has never been fed —
`ctx.embargo` is always nil. This script ingests IBAMA embargo terms from the
public open-data portal `dadosabertos.ibama.gov.br` (CKAN) into a dedicated
SQLite DB, resolving each embargo to a CAR property via the spatial fallback
(centroid → CAR polygon), mirroring `download_sinaflor_auth.py`.

Pre-flight (verified 2026-08-13, see shape.md): the `fiscalizacao-termo-de-
embargo` package has a `GEOM_AREA_EMBARGADA` WKT polygon column + centroid
`NUM_LONGITUDE_TAD`/`NUM_LATITUDE_TAD`. There is NO `cod_imovel` column, so
matching is spatial (centroid → CAR polygon), like the sinaflor fallback.

Flow: discover the package via CKAN at runtime (never hardcode ids) → download
the main CSV resource (ZIP-aware) → normalize → resolve CAR code (offline,
never in the Lua loop) → write a dedicated SQLite DB atomically.

The DB file itself is the success marker: it is written to `<out>.tmp` and
atomically `os.replace`d only after a fully successful import, so a failed run
leaves the previous DB (and its mtime) intact (common-mistake #5).

Usage:
    python3 scripts/data/download_embargo.py                # default: 2 anos (730d)
    python3 scripts/data/download_embargo.py --window 365    # 1 ano
    python3 scripts/data/download_embargo.py --today 2026-08-13  # override do relógio (testes)
    python3 scripts/data/download_embargo.py --force         # re-download mesmo com DB recente
    python3 scripts/data/download_embargo.py --no-car-resolve
    python3 scripts/data/download_embargo.py --out backend-lua/data/embargo/embargo.db
"""
import argparse
import json
import os
import re
import sqlite3
import sys
import time
import zipfile
from datetime import date, timedelta
from pathlib import Path

import pandas as pd
import requests
from shapely import wkt
from shapely.geometry import Point, shape

CKAN_API = "https://dadosabertos.ibama.gov.br/api/3/action"
UA = "Mozilla/5.0 (X11; Linux x86_64) Yvy/1.0"
BATCH = 1000

# The embargo package name (discovered at runtime, never hardcoded id).
EMBARGO_PACKAGE = "fiscalizacao-termo-de-embargo"

# SIT_CANCELADO values that mean the embargo is NOT active.
# N = active, S = cancelled. SIT_DESEMBARGO = S means the area was released.
DROP_CANCELADO = {"S"}


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


def _ckan_get_json(url, params):
    for attempt in range(3):
        try:
            r = requests.get(url, params=params, timeout=60, headers={"User-Agent": UA})
            r.raise_for_status()
            data = r.json()
            if not data.get("success"):
                raise ValueError("CKAN error: {}".format(data.get("error")))
            return data
        except Exception:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def ckan_package(package_name):
    """Fetch a CKAN package by name; fail loudly if missing."""
    data = _ckan_get_json(CKAN_API + "/package_show", {"id": package_name})
    return data["result"]


def ckan_resource_url(package, keyword="termo_embargo_csv"):
    """First CSV resource whose name/url matches the main data file.

    The package has many CSV resources (itens, coordenadas, anexos, ...). We
    want the main `termo_embargo_csv.zip` (the embargo terms themselves).
    """
    res = package.get("resources") or []
    for r in res:
        if (r.get("format") or "").upper() != "CSV":
            continue
        name = (r.get("name") or "").lower()
        url = (r.get("url") or "").lower()
        if keyword in name or keyword in url:
            return r["url"]
    # Fallback: first CSV that is not a metadata/auxiliary file.
    for r in res:
        if (r.get("format") or "").upper() != "CSV":
            continue
        name = (r.get("name") or "").lower()
        if "metadados" not in name and "itens" not in name and "coordenadas" not in name:
            return r["url"]
    raise RuntimeError(
        "package {}: no main CSV resource found — upstream schema changed "
        "(see common-mistake #4)".format(package.get("name"))
    )


def download_csv(url, dest):
    """Stream a resource to `dest`, retrying with backoff. ZIP-aware."""
    dest = Path(dest)
    part = dest.with_name(dest.name + ".part")
    for attempt in range(3):
        try:
            with requests.get(url, stream=True, timeout=180,
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

    with open(part, "rb") as f:
        magic = f.read(4)
    if magic[:2] == b"PK":
        with zipfile.ZipFile(part) as z:
            csv_names = [n for n in z.namelist() if n.lower().endswith(".csv")]
            if not csv_names:
                raise RuntimeError("{}: zip contains no CSV member".format(url))
            with open(dest, "wb") as f:
                f.write(z.read(csv_names[0]))
        part.unlink(missing_ok=True)
    else:
        os.replace(part, dest)
    return dest


def detect_sep(path):
    with open(path, newline="", encoding="utf-8-sig") as f:
        header = f.readline()
    return ";" if header.count(";") >= header.count(",") else ","


def _parse_date(value):
    """ISO `YYYY-MM-DD` (optionally with a time component) or `DD/MM/YYYY` → `YYYY-MM-DD` or None."""
    if value is None:
        return None
    v = str(value).strip()
    if not v:
        return None
    # ISO with optional time: `YYYY-MM-DD` or `YYYY-MM-DD HH:MM:SS`.
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})(?:[ T].*)?$", v)
    if m:
        y, mo, d = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if 1 <= mo <= 12 and 1 <= d <= 31:
            return "{:04d}-{:02d}-{:02d}".format(y, mo, d)
    m = re.fullmatch(r"(\d{2})[/-](\d{2})[/-](\d{2,4})", v)
    if m:
        d, mo, y = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if len(str(y)) == 2:
            y = 2000 + y if y <= 69 else 1900 + y
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


def normalize(df, today, window_days):
    """Map the raw embargo CSV to canonical columns and apply filters.

    Returns (out, dropped) where `dropped` is a dict of drop-reason counts.
    """
    col = lambda aliases: _find_column(df, aliases)  # noqa: E731
    num_col = col(["NUM_TAD"])
    data_col = col(["DAT_EMBARGO"])
    situ_col = col(["SIT_CANCELADO"])
    desembargo_col = col(["SIT_DESEMBARGO"])
    mun_col = col(["MUNICIPIO"])
    uf_col = col(["UF"])
    lat_col = col(["NUM_LATITUDE_TAD"])
    lon_col = col(["NUM_LONGITUDE_TAD"])
    geom_col = col(["GEOM_AREA_EMBARGADA"])
    area_col = col(["QTD_AREA_EMBARGADA"])

    out = pd.DataFrame()
    out["numero"] = df[num_col].astype(str).str.strip() if num_col else ""
    out["data"] = df[data_col].map(_parse_date) if data_col else None
    out["situacao"] = df[situ_col].astype(str).str.strip() if situ_col else ""
    out["desembargo"] = df[desembargo_col].astype(str).str.strip() if desembargo_col else ""
    out["municipio"] = df[mun_col].astype(str).str.strip() if mun_col else ""
    out["uf"] = df[uf_col].astype(str).str.strip().str.upper() if uf_col else ""
    out["lat"] = df[lat_col].map(_parse_float) if lat_col else None
    out["lon"] = df[lon_col].map(_parse_float) if lon_col else None
    out["geom"] = df[geom_col].astype(str).str.strip() if geom_col else ""
    out["area_ha"] = df[area_col].map(_parse_float) if area_col else None

    dropped = {}

    before = len(out)
    out = out[~out["situacao"].isin(DROP_CANCELADO)]
    dropped["cancelado"] = before - len(out)

    before = len(out)
    out = out[out["desembargo"] != "S"]
    dropped["desembargado"] = before - len(out)

    before = len(out)
    out = out[out["numero"] != ""]
    dropped["sem_numero"] = before - len(out)

    # Window filter on the embargo date.
    cutoff = (today - timedelta(days=window_days)).isoformat()
    before = len(out)
    out = out[out["data"].notna() & (out["data"] >= cutoff)]
    dropped["fora_da_janela"] = before - len(out)

    return out.reset_index(drop=True), dropped


def classify_point(car_conn, lon, lat):
    """CAR cod_imovel of the largest-area property containing (lon, lat), or None.

    Mirrors backend-lua `car_lookup.classify_point`: RTree bbox candidates →
    decode only those → shapely point-in-polygon → match of LARGEST AREA.
    """
    rows = car_conn.execute(
        "SELECT id FROM car_rtree WHERE minLon<=? AND maxLon>=? AND minLat<=? AND maxLat>=?",
        (lon, lon, lat, lat)).fetchall()
    if not rows:
        return None
    ids = [r[0] for r in rows]
    ph = ",".join("?" * len(ids))
    best, best_area = None, -1.0
    for r in car_conn.execute(
        "SELECT cod_imovel, area, json(geom) AS g FROM car_data WHERE id IN ({})".format(ph),
        ids):
        g = r[2]
        if not g:
            continue
        try:
            geom = shape(json.loads(g))
        except Exception:
            continue
        if geom.contains(Point(lon, lat)):
            area = float(r[1] or 0)
            if area > best_area:
                best_area = area
                best = r[0]
    return str(best).upper() if best else None


def resolve_car(df, car_db_path, enable_spatial=True):
    """Fill `cod_imovel` via the spatial fallback (centroid → CAR polygon).

    The embargo dataset has no explicit CAR column, so the spatial fallback is
    the PRIMARY (and only) path. When car.db is unavailable, rows are left
    without cod_imovel (dropped downstream with a logged count — never crashes).
    Returns (out, counts).
    """
    out = df.copy()
    out["cod_imovel"] = ""
    need = out["lat"].notna() & out["lon"].notna()
    counts = {"spatial_needed": int(need.sum()), "spatial_resolved": 0}

    if counts["spatial_needed"] == 0 or not enable_spatial:
        return out, counts
    if not car_db_path or not os.path.exists(car_db_path):
        print("WARN: car.db not found at {} — spatial resolve skipped; rows "
              "without explicit CAR will be dropped".format(car_db_path))
        return out, counts

    conn = sqlite3.connect("file:{}?mode=ro".format(car_db_path), uri=True, timeout=60)
    conn.execute("PRAGMA busy_timeout=60000")
    try:
        for idx in out.index[need]:
            code = classify_point(conn, float(out.at[idx, "lon"]), float(out.at[idx, "lat"]))
            if code:
                out.at[idx, "cod_imovel"] = code
                counts["spatial_resolved"] += 1
    finally:
        conn.close()
    return out, counts


def write_db(df, out_path):
    """Write `embargo.db` atomically via `<out>.tmp` + os.replace.

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
            CREATE TABLE IF NOT EXISTS embargoes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                numero TEXT,
                data TEXT,
                situacao TEXT,
                municipio TEXT,
                uf TEXT,
                cod_imovel TEXT,
                geom BLOB,
                bbox TEXT
            );
            CREATE TABLE IF NOT EXISTS embargoes_rtree (
                id INTEGER PRIMARY KEY,
                minLon REAL, maxLon REAL, minLat REAL, maxLat REAL
            );
        """)
        cols = ["numero", "data", "situacao", "municipio", "uf", "cod_imovel",
                "geom", "bbox"]
        # Dedupe by (numero, cod_imovel): one embargo term can have multiple
        # polygons/areas, but `has_active_embargo` only needs existence per CAR.
        rows = list(df[cols].itertuples(index=False, name=None))
        seen = set()
        deduped = []
        for r in rows:
            key = (str(r[0]), str(r[5]))
            if key in seen:
                continue
            seen.add(key)
            deduped.append(r)
        rows = deduped
        sql = ("INSERT INTO embargoes "
               "(numero, data, situacao, municipio, uf, cod_imovel, geom, bbox) "
               "VALUES (?,?,?,?,?,?,?,?)")
        rtree_sql = ("INSERT INTO embargoes_rtree (id, minLon, maxLon, minLat, "
                     "maxLat) VALUES (?,?,?,?,?)")
        for i in range(0, len(rows), BATCH):
            chunk = rows[i:i + BATCH]
            conn.executemany(sql, chunk)
            for j, r in enumerate(chunk):
                # r[6] is the WKT geom; r[7] is the bbox JSON string.
                if r[7]:
                    try:
                        b = json.loads(r[7])
                        conn.execute(rtree_sql,
                                     (i + j + 1, b[0], b[1], b[2], b[3]))
                    except Exception:
                        pass
        conn.commit()
        conn.execute("CREATE INDEX IF NOT EXISTS idx_embargo_cod "
                     "ON embargoes(cod_imovel)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_embargo_rtree_id "
                     "ON embargoes_rtree(id)")
        conn.commit()
        conn.execute("VACUUM")
        conn.commit()
    finally:
        conn.close()
    os.replace(tmp, out_path)
    return len(rows)


def _geom_bbox(wkt_str):
    """Bbox (minLon, maxLon, minLat, maxLat) of a WKT geometry, or None."""
    if not wkt_str:
        return None
    try:
        geom = shape(wkt.loads(wkt_str))
    except Exception:
        return None
    if geom.is_empty:
        return None
    minx, miny, maxx, maxy = geom.bounds
    return [minx, maxx, miny, maxy]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--window", type=int, default=730,
                    help="keep embargoes with DAT_EMBARGO >= today - window (days)")
    ap.add_argument("--today", default=None,
                    help="ISO date to anchor the window (deterministic tests)")
    ap.add_argument("--force", action="store_true",
                    help="re-download even when the DB is younger than 7 days")
    ap.add_argument("--no-car-resolve", action="store_true",
                    help="skip the spatial CAR fallback")
    ap.add_argument("--out", default="backend-lua/data/embargo/embargo.db")
    args = ap.parse_args()

    today = date.fromisoformat(args.today) if args.today else date.today()
    out = Path(args.out)

    # Freshness guard: the DB mtime is the success marker; skip when recent.
    if out.exists() and not args.force:
        age_days = (time.time() - out.stat().st_mtime) / 86400
        if age_days < 7:
            print("embargo.db is {:.1f} days old — skipping download "
                  "(use --force to re-download)".format(age_days))
            return 0

    car_db_path = os.environ.get("CAR_DB_PATH") or "backend-lua/data/car/car.db"

    pkg = ckan_package(EMBARGO_PACKAGE)
    url = ckan_resource_url(pkg)
    dest = Path("/tmp/yvy_embargo.csv")
    print("downloading {} -> {}".format(url, dest))
    download_csv(url, dest)
    df = pd.read_csv(dest, sep=detect_sep(dest), encoding="utf-8-sig",
                     dtype=str, low_memory=False)
    norm, dropped = normalize(df, today, args.window)
    print("{} rows after normalize (drops: {})".format(len(norm), dropped))

    # Derive bbox from the WKT geometry for the RTree.
    norm["bbox"] = norm["geom"].map(_geom_bbox)
    norm["bbox"] = norm["bbox"].map(lambda b: json.dumps(b) if b else None)

    norm, car_counts = resolve_car(norm, car_db_path,
                                   enable_spatial=not args.no_car_resolve)

    before = len(norm)
    kept = norm[norm["cod_imovel"] != ""]
    no_car = before - len(kept)

    n = write_db(kept, out)
    print("\n=== embargo.db written to {} ===".format(out))
    print("rows: {} (drops: {}; rows without cod_imovel dropped: {})".format(
        n, dropped, no_car))
    print("car resolve: {}".format(car_counts))
    print("marker (db mtime): {}".format(date.fromtimestamp(out.stat().st_mtime)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - top-level abort without marker
        print("ERROR: {} — no DB written (previous embargo.db, if any, "
              "is intact)".format(exc), file=sys.stderr)
        sys.exit(1)

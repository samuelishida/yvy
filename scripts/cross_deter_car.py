#!/usr/bin/env python3
"""Cross DETER × CAR (+ fires + PRODES) → deter_car_alerts.

Two passes (plan: terrabrasilis-integration, Inc 3):

- **Pass 1 (DETER-driven → maximo/alto):** recent DETER polygons (deter_polygons)
  × CAR polygons (car.db) → one row per affected property.
    - `maximo` = FIRMS + DETER no mesmo CAR em ≤7 dias (Cenário C)
    - `alto`   = DETER sem fogo associado (Cenário A)
- **Pass 2 (fire-driven → medio/baixo):** fires without a recent DETER on the
  property (Cenário B).
    - `medio` = fire on already-deforested area (PRODES dYYYY at the point)
    - `baixo` = fire on native vegetation (no PRODES nearby)

Uses Shapely `intersects()`/`intersection()` for correct polygon-polygon ops
(replaces the Lua ray-cast). Runs detached (nightly cron), after
`download_deter_wfs.py`. car.db is queried read-only via its RTree.

Usage:
    python3 scripts/cross_deter_car.py --days 7
    python3 scripts/cross_deter_car.py --db /opt/yvy/backend-lua/data/yvy.db --car-db /opt/yvy/backend-lua/data/car/car.db --days 7
"""
import argparse
import json
import os
import sqlite3
import sys
from datetime import date, datetime, timedelta, timezone

import geopandas as gpd
import pandas as pd
from shapely.geometry import Point, shape
from shapely.strtree import STRtree

PAD = 0.0003          # ~30m em graus (PRODES 30m, checagem de proximidade)
RTree_CAND_LIMIT = 5000


def deter_db_path() -> str:
    p = os.environ.get("SQLITE_PATH")
    if p:
        return p
    return os.path.join("backend-lua", "data", "yvy.db")


def default_car_db_path() -> str:
    p = os.environ.get("CAR_DB_PATH")
    if p:
        return p
    return os.path.join("backend-lua", "data", "car", "car.db")


def _decode(geom_json):
    try:
        return shape(json.loads(geom_json))
    except Exception:
        return None


def load_deter_recent(db_path: str, days: int):
    """Recent DETER polygons as a GeoDataFrame (view_date, classname, uf, ...)."""
    cutoff = (date.today() - timedelta(days=days)).isoformat()
    conn = sqlite3.connect(db_path, timeout=60)
    conn.execute("PRAGMA busy_timeout=60000")
    df = pd.read_sql_query(
        """SELECT id, classname, view_date, uf, municipality, mun_geocod, area_km2,
                  json(geom) AS geom_json
           FROM deter_polygons WHERE view_date >= ? AND geom IS NOT NULL""",
        conn, params=(cutoff,))
    conn.close()
    if df.empty:
        return None
    geoms = [_decode(g) for g in df["geom_json"]]
    df = df.drop(columns=["geom_json"])
    df["geometry"] = geoms
    df = df[df["geometry"].notna()]
    return gpd.GeoDataFrame(df, crs="EPSG:4326") if not df.empty else None


def load_recent_fires(db_path: str, days: int):
    cutoff = (date.today() - timedelta(days=days)).isoformat()
    conn = sqlite3.connect(db_path, timeout=60)
    conn.execute("PRAGMA busy_timeout=60000")
    rows = conn.execute(
        """SELECT lat, lon, acq_date FROM fire_data
           WHERE acq_date >= ? AND lat IS NOT NULL AND lon IS NOT NULL
           ORDER BY acq_date""", (cutoff,)).fetchall()
    conn.close()
    return [{"lat": r[0], "lon": r[1], "acq_date": r[2]} for r in rows]


def car_ids_in_bbox(car_conn, minx, miny, maxx, maxy, limit=RTree_CAND_LIMIT):
    rows = car_conn.execute(
        """SELECT id FROM car_rtree
           WHERE minLon <= ? AND maxLon >= ? AND minLat <= ? AND maxLat >= ?
           LIMIT ?""",
        (maxx, minx, maxy, miny, limit)).fetchall()
    return [r[0] for r in rows]


def load_car_by_ids(car_conn, ids):
    if not ids:
        return None
    ph = ",".join("?" * len(ids))
    df = pd.read_sql_query(
        f"""SELECT id, cod_imovel, uf, municipio, area, json(geom) AS g
            FROM car_data WHERE id IN ({ph})""",
        car_conn, params=list(ids))
    if df.empty:
        return None
    geoms = [_decode(g) for g in df["g"]]
    df = df.drop(columns=["g"])
    df["geometry"] = geoms
    df = df[df["geometry"].notna()]
    return gpd.GeoDataFrame(df, crs="EPSG:4326") if not df.empty else None


def cross_fire_data(car_geom, deter_date, fires_conn):
    """Fires inside the CAR polygon ±7 days of the DETER date."""
    minx, miny, maxx, maxy = car_geom.bounds
    d0 = date.fromisoformat(deter_date)
    start = (d0 - timedelta(days=7)).isoformat()
    end = (d0 + timedelta(days=7)).isoformat()
    rows = fires_conn.execute(
        """SELECT lat, lon, acq_date FROM fire_data
           WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?
             AND acq_date BETWEEN ? AND ?""",
        (miny, maxy, minx, maxx, start, end)).fetchall()
    count = 0
    dates = []
    for lat, lon, ad in rows:
        if car_geom.contains(Point(lon, lat)):
            count += 1
            dates.append(ad)
    return count, sorted(dates)


def has_prodes_nearby(db_conn, lon, lat):
    """True if a PRODES d* pixel is within ~30m of (lon, lat)."""
    row = db_conn.execute(
        """SELECT 1 FROM deforestation_data
           WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?
             AND json_extract(data, '$.name') LIKE 'd%' LIMIT 1""",
        (lat - PAD, lat + PAD, lon - PAD, lon + PAD)).fetchone()
    return row is not None


def write_alerts(db_path: str, rows: list):
    if not rows:
        print("  no alerts to write")
        return 0
    conn = sqlite3.connect(db_path, timeout=60)
    conn.execute("PRAGMA busy_timeout=60000")
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    sql = """INSERT INTO deter_car_alerts
             (cod_imovel, classname, view_date, uf, municipio, area_afetada_ha,
              fire_count, fire_dates, severity, ingested_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(cod_imovel, classname, view_date) DO UPDATE SET
               uf=excluded.uf, municipio=excluded.municipio,
               area_afetada_ha=excluded.area_afetada_ha,
               fire_count=excluded.fire_count, fire_dates=excluded.fire_dates,
               severity=excluded.severity, ingested_at=excluded.ingested_at"""
    for i in range(0, len(rows), 1000):
        batch = []
        for r in rows[i:i + 1000]:
            batch.append((
                r["cod_imovel"], r["classname"], r["view_date"], r.get("uf"),
                r.get("municipio"), r.get("area_afetada_ha"),
                r.get("fire_count", 0), json.dumps(r.get("fire_dates", []), ensure_ascii=False),
                r["severity"], now,
            ))
        conn.executemany(sql, batch)
        conn.commit()
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.close()
    return len(rows)


def run_pass1(deter_gdf, car_db_path, fires_db_path) -> list:
    """DETER polygons × CAR → one row per (property, class, date) (maximo/alto)."""
    if deter_gdf is None or deter_gdf.empty:
        return []
    car_conn = sqlite3.connect(f"file:{car_db_path}?mode=ro", uri=True, timeout=60)
    car_conn.execute("PRAGMA busy_timeout=60000")
    fires_conn = sqlite3.connect(f"file:{fires_db_path}?mode=ro", uri=True, timeout=60)
    fires_conn.execute("PRAGMA busy_timeout=60000")

    acc = {}  # (cod_imovel, classname, view_date) -> row (sum area, max severity)
    for _, det in deter_gdf.iterrows():
        minx, miny, maxx, maxy = det.geometry.bounds
        ids = car_ids_in_bbox(car_conn, minx, miny, maxx, maxy)
        if not ids:
            continue
        car_gdf = load_car_by_ids(car_conn, ids)
        if car_gdf is None:
            continue
        for _, car in car_gdf.iterrows():
            if not det.geometry.intersects(car.geometry):
                continue
            inter = det.geometry.intersection(car.geometry)
            area_ha = inter.area / 10000.0
            key = (car["cod_imovel"], det["classname"], det["view_date"])
            entry = acc.get(key)
            if entry is None:
                fcount, fdates = cross_fire_data(car.geometry, det["view_date"], fires_conn)
                acc[key] = {
                    "cod_imovel": car["cod_imovel"], "classname": det["classname"],
                    "view_date": det["view_date"], "uf": car.get("uf"),
                    "municipio": car.get("municipio"), "area_afetada_ha": area_ha,
                    "fire_count": fcount, "fire_dates": fdates,
                    "severity": "maximo" if fcount > 0 else "alto",
                }
            else:
                # same property+class+date: sum area, upgrade severity
                entry["area_afetada_ha"] += area_ha
                if entry["severity"] != "maximo" and entry["fire_count"] > 0:
                    entry["severity"] = "maximo"
    car_conn.close()
    fires_conn.close()
    rows = list(acc.values())
    for r in rows:
        r["area_afetada_ha"] = round(r["area_afetada_ha"], 2)
    print(f"  pass1: {len(rows)} CAR alerts (maximo/alto)")
    return rows


def run_pass2(db_path, car_db_path, days) -> list:
    """Fires × CAR without recent DETER → medio/baixo rows."""
    fires = load_recent_fires(db_path, days)
    if not fires:
        return []
    car_conn = sqlite3.connect(f"file:{car_db_path}?mode=ro", uri=True, timeout=60)
    car_conn.execute("PRAGMA busy_timeout=60000")
    db_conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=60)
    db_conn.execute("PRAGMA busy_timeout=60000")

    # Recent DETER spatial index to skip properties that Pass 1 already handled
    deter_gdf = load_deter_recent(db_path, days)
    deter_tree = STRtree(list(deter_gdf.geometry)) if deter_gdf is not None and not deter_gdf.empty else None

    # Map fire → CAR property (rtree point query + contains)
    fire_by_prop = {}  # cod_imovel -> {uf, municipio, fires: [(lat, lon, acq_date)]}
    prop_geom = {}     # cod_imovel -> geometry
    for f in fires:
        lon, lat = f["lon"], f["lat"]
        ids = car_ids_in_bbox(car_conn, lon, lat, lon, lat)
        if not ids:
            continue
        car_gdf = load_car_by_ids(car_conn, ids)
        if car_gdf is None:
            continue
        for _, car in car_gdf.iterrows():
            if car.geometry.contains(Point(lon, lat)):
                prop = fire_by_prop.setdefault(car["cod_imovel"], {"uf": car.get("uf"), "municipio": car.get("municipio"), "fires": []})
                prop["fires"].append((lat, lon, f["acq_date"]))
                prop_geom.setdefault(car["cod_imovel"], car.geometry)
                break  # one property per fire point (largest match ok)

    rows = []
    for cod, prop in fire_by_prop.items():
        geom = prop_geom[cod]
        # Skip properties with a recent DETER — Pass 1 owns them
        if deter_tree is not None and deter_tree.query(geom.bounds).tolist():
            skip = False
            for idx in deter_tree.query(geom.bounds).tolist():
                if geom.intersects(deter_gdf.geometry.iloc[idx]):
                    skip = True
                    break
            if skip:
                continue
        dates = sorted({f[2] for f in prop["fires"]})
        latest = dates[-1]
        # medio if any fire sits on PRODES d*, else baixo
        severity = "baixo"
        for (lat, lon, _) in prop["fires"]:
            if has_prodes_nearby(db_conn, lon, lat):
                severity = "medio"
                break
        rows.append({
            "cod_imovel": cod, "classname": "FIRMS", "view_date": latest,
            "uf": prop.get("uf"), "municipio": prop.get("municipio"),
            "area_afetada_ha": 0.0, "fire_count": len(prop["fires"]),
            "fire_dates": dates, "severity": severity,
        })
    car_conn.close()
    db_conn.close()
    print(f"  pass2: {len(rows)} fire-driven alerts (medio/baixo)")
    return rows


def run_daily(db_path: str, car_db_path: str, days: int):
    print(f"=== cross_deter_car ({date.today().isoformat()}, days={days}) ===", flush=True)
    # Pass 1 needs DETER; Pass 2 (fire-driven medio/baixo) runs regardless.
    deter_gdf = load_deter_recent(db_path, days)
    if deter_gdf is None or deter_gdf.empty:
        print("  no recent DETER polygons — Pass 1 no-op (Pass 2 still runs)", flush=True)
        pass1 = []
    else:
        pass1 = run_pass1(deter_gdf, car_db_path, db_path)
    pass2 = run_pass2(db_path, car_db_path, days)
    all_rows = pass1 + pass2
    n = write_alerts(db_path, all_rows)
    print(f"  wrote {n} deter_car_alerts rows", flush=True)
    return n


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", default=None, help="yvy.db path (override SQLITE_PATH)")
    ap.add_argument("--car-db", default=None, help="car.db path (override CAR_DB_PATH)")
    ap.add_argument("--days", type=int, default=7)
    args = ap.parse_args()

    db_path = args.db or deter_db_path()
    car_path = args.car_db or default_car_db_path()
    if not os.path.exists(db_path):
        print(f"ERROR: yvy.db not found: {db_path}", file=sys.stderr)
        sys.exit(1)
    if not os.path.exists(car_path):
        print(f"ERROR: car.db not found: {car_path}", file=sys.stderr)
        sys.exit(1)
    run_daily(db_path, car_path, args.days)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Compute effective deforestation area per CAR property → area_efetiva.db.

The risk score's `deforestation` factor currently uses the TOTAL area of a
MapBiomas alert (`recent_alerts`), even when that alert crosses 2+ CARs. This
script precomputes, for each (alert, CAR) pair, the **effective area** of the
alert that actually falls inside that property, plus the fraction of the alert
it represents. The runtime lookup (`area_efetiva_lookup.lua`) reads this DB
read-only; the score uses `area_efetiva_ha` when present.

Pattern (plan: car-risk-expansion, Inc 1): mirrors `cross_deter_car.py` —
Shapely `intersection()` in an equal-area CRS (EPSG:5880, fallback UTM 23S),
offline, into a dedicated SQLite DB with atomic `os.replace` swap + a version
marker written only after success (common-mistake #5).

Inputs:
- `mapbiomas_alerta.db` (MAPBIOMAS_DB_PATH): `alerts` with `geom` (WKT blob),
  `bbox`, `area_ha`, `cod_imovel`.
- `car.db` (CAR_DB_PATH): `car_data` with `geom` (GeoJSON JSONB) + `car_rtree`.

Output: `area_efetiva.db` with table
    area_efetiva(alert_code, cod_imovel, area_efetiva_ha REAL, fracao REAL,
                 version_key TEXT)
+ indexes on (alert_code) and (cod_imovel). One row per (alert, CAR) pair.

Usage:
    python3 scripts/data/compute_area_efetiva.py                # all alerts
    python3 scripts/data/compute_area_efetiva.py --window 365    # alerts last 365d
    python3 scripts/data/compute_area_efetiva.py --today 2026-08-13  # deterministic tests
    python3 scripts/data/compute_area_efetiva.py --force         # recompute even if fresh
    python3 scripts/data/compute_area_efetiva.py --out /tmp/area_efetiva.db
"""
import argparse
import json
import os
import sqlite3
import sys
import time
from datetime import date, timedelta
from pathlib import Path

import geopandas as gpd
import pandas as pd
import shapely
from shapely.geometry import shape
from shapely.strtree import STRtree

# STRtree.query(geom) in shapely 2.x takes a geometry object (not a bbox
# tuple). Fail loudly on 1.x instead of silently misbehaving.
if shapely.__version__.split(".")[0] != "2":
    raise RuntimeError(
        f"compute_area_efetiva.py requires shapely 2.x (found {shapely.__version__}); "
        "install shapely>=2.0 (see scripts/requirements.txt)"
    )

BATCH = 1000
RTREE_PAGE_SIZE = 5000


def default_mapbiomas_db_path() -> str:
    p = os.environ.get("MAPBIOMAS_DB_PATH")
    if p:
        return p
    return os.path.join("backend-lua", "data", "mapbiomas", "mapbiomas_alerta.db")


def default_car_db_path() -> str:
    p = os.environ.get("CAR_DB_PATH")
    if p:
        return p
    return os.path.join("backend-lua", "data", "car", "car.db")


def _decode_geojson(geom_json):
    try:
        return shape(json.loads(geom_json))
    except Exception:
        return None


def _decode_wkt(wkt):
    if not wkt:
        return None
    try:
        return shapely.wkt.loads(wkt)
    except Exception:
        return None


def to_equal_area(gdf):
    """Reproject a GeoDataFrame to an equal-area CRS for real-hectare areas.

    EPSG:4326 areas are square degrees, not hectares. Prefer EPSG:5880
    (SIRGAS 2000 / Brazil Polyconic); fall back to EPSG:32723 (UTM 23S) if
    5880 is unavailable in the installed PROJ. Aborts on total failure.
    """
    last = None
    for crs in ("EPSG:5880", "EPSG:32723"):
        try:
            return gdf.to_crs(crs)
        except Exception as exc:  # noqa: BLE001 - try next fallback CRS
            last = exc
    raise RuntimeError(
        "equal-area reprojection failed (tried EPSG:5880 and EPSG:32723): "
        f"{last}"
    ) from last


def load_alerts(db_path: str, window_days: int, today: date):
    """Alerts with geometry as a GeoDataFrame (alert_code, cod_imovel, area_ha).

    The window cutoff is anchored to `today` (not the real clock) so a
    `--today` run is deterministic for tests.
    """
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=60)
    conn.execute("PRAGMA busy_timeout=60000")
    if window_days and window_days > 0:
        cutoff = (today - timedelta(days=window_days)).isoformat()
        df = pd.read_sql_query(
            """SELECT alert_code, cod_imovel, area_ha, geom, bbox
               FROM alerts
               WHERE geom IS NOT NULL AND geom != ''
                 AND (data_deteccao >= ? OR data_deteccao IS NULL)""",
            conn, params=(cutoff,))
    else:
        df = pd.read_sql_query(
            """SELECT alert_code, cod_imovel, area_ha, geom, bbox
               FROM alerts
               WHERE geom IS NOT NULL AND geom != ''""",
            conn)
    conn.close()
    if df.empty:
        return None
    geoms = [_decode_wkt(g) for g in df["geom"]]
    df = df.drop(columns=["geom"])
    df["geometry"] = geoms
    df = df[df["geometry"].notna()]
    return gpd.GeoDataFrame(df, crs="EPSG:4326") if not df.empty else None


def car_ids_in_bbox(car_conn, minx, miny, maxx, maxy, page_size=RTREE_PAGE_SIZE):
    """All CAR ids whose RTree bbox overlaps the query box (paginated, no cap).

    A single `LIMIT` would silently truncate candidate sets; instead page over
    the results (ORDER BY id for stable OFFSET) until a short page is returned.
    """
    ids = []
    start = 0
    while True:
        rows = car_conn.execute(
            """SELECT id FROM car_rtree
               WHERE minLon <= ? AND maxLon >= ? AND minLat <= ? AND maxLat >= ?
               ORDER BY id LIMIT ? OFFSET ?""",
            (maxx, minx, maxy, miny, page_size, start)).fetchall()
        ids.extend(r[0] for r in rows)
        if len(rows) < page_size:
            break
        start += page_size
    return ids


def load_car_by_ids(car_conn, ids):
    if not ids:
        return None
    ph = ",".join("?" * len(ids))
    df = pd.read_sql_query(
        f"""SELECT id, cod_imovel, json(geom) AS g
            FROM car_data WHERE id IN ({ph})""",
        car_conn, params=list(ids))
    if df.empty:
        return None
    geoms = [_decode_geojson(g) for g in df["g"]]
    df = df.drop(columns=["g"])
    df["geometry"] = geoms
    df = df[df["geometry"].notna()]
    return gpd.GeoDataFrame(df, crs="EPSG:4326") if not df.empty else None


def intersect_pair(alert_geom_ea, car_geom_ea):
    """Effective area (ha) + fraction of the alert inside the CAR.

    Both geometries are already in an equal-area CRS. Returns
    (area_efetiva_ha, fracao) or (None, None) when they don't intersect.
    """
    if not alert_geom_ea.intersects(car_geom_ea):
        return None, None
    inter = alert_geom_ea.intersection(car_geom_ea)
    if inter.is_empty:
        return None, None
    inter_area_ha = inter.area / 10000.0
    alert_area_ha = alert_geom_ea.area / 10000.0
    if alert_area_ha <= 0:
        return None, None
    fracao = inter_area_ha / alert_area_ha
    return round(inter_area_ha, 2), round(fracao, 4)


def build_db(rows, out_path, version_key):
    """Write `area_efetiva.db` atomically via `<out>.tmp` + os.replace.

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
            CREATE TABLE IF NOT EXISTS area_efetiva (
                alert_code TEXT NOT NULL,
                cod_imovel TEXT NOT NULL,
                area_efetiva_ha REAL,
                fracao REAL,
                version_key TEXT,
                PRIMARY KEY (alert_code, cod_imovel)
            );
        """)
        sql = ("INSERT OR REPLACE INTO area_efetiva "
               "(alert_code, cod_imovel, area_efetiva_ha, fracao, version_key) "
               "VALUES (?,?,?,?,?)")
        for i in range(0, len(rows), BATCH):
            conn.executemany(sql, rows[i:i + BATCH])
        conn.commit()
        conn.execute("CREATE INDEX IF NOT EXISTS idx_area_efetiva_alert "
                     "ON area_efetiva(alert_code)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_area_efetiva_car "
                     "ON area_efetiva(cod_imovel)")
        conn.commit()
        conn.execute("VACUUM")
        conn.commit()
    finally:
        conn.close()
    os.replace(tmp, out_path)
    return len(rows)


def write_version_marker(version_str, out_path):
    """Write the version marker file after a successful compute.

    Mirrors the `data/prodes_version` pattern (common-mistake #5): the marker
    is written ONLY after the DB swap succeeds, so a failed run leaves the
    previous marker (and DB) intact. The Ansible service exports
    `AREA_EFETIVA_VERSION` from this file; `risk_precompute.current_version_key`
    includes it so a recompute invalidates cached scores.
    """
    marker = Path(out_path).with_name("area_efetiva.version")
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(version_str.strip() + "\n", encoding="utf-8")
    return marker


def run_compute(mapbiomas_db_path, car_db_path, out_path, window_days, today):
    """Cross alerts × CAR → area_efetiva rows. Returns (rows, version_str)."""
    version_str = today.isoformat().replace("-", "")
    alerts = load_alerts(mapbiomas_db_path, window_days, today)
    if alerts is None or alerts.empty:
        print("  no alerts with geometry — writing empty area_efetiva.db")
        build_db([], out_path, version_str)
        write_version_marker(version_str, out_path)
        return 0, version_str

    car_conn = sqlite3.connect(f"file:{car_db_path}?mode=ro", uri=True, timeout=60)
    car_conn.execute("PRAGMA busy_timeout=60000")

    alerts_ea = to_equal_area(alerts)
    rows = []
    skipped = 0
    for (_, alert), (_, alert_ea) in zip(alerts.iterrows(), alerts_ea.iterrows()):
        minx, miny, maxx, maxy = alert.geometry.bounds
        ids = car_ids_in_bbox(car_conn, minx, miny, maxx, maxy)
        if not ids:
            skipped += 1
            continue
        car_gdf = load_car_by_ids(car_conn, ids)
        if car_gdf is None:
            skipped += 1
            continue
        car_ea = to_equal_area(car_gdf)
        for (_, car), (_, car_ea_row) in zip(car_gdf.iterrows(), car_ea.iterrows()):
            area_ha, fracao = intersect_pair(alert_ea.geometry, car_ea_row.geometry)
            if area_ha is None:
                skipped += 1
                continue
            rows.append((
                str(alert["alert_code"]),
                str(car["cod_imovel"]).upper(),
                area_ha,
                fracao,
                version_str,
            ))
    car_conn.close()
    print(f"  {len(rows)} (alert, CAR) pairs; {skipped} skipped (no geometry/intersection)")
    n = build_db(rows, out_path, version_str)
    write_version_marker(version_str, out_path)
    print(f"  wrote {n} area_efetiva rows to {out_path}")
    return n, version_str


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--window", type=int, default=0,
                    help="only alerts with data_deteccao >= today - window (days); 0 = all-time")
    ap.add_argument("--today", default=None,
                    help="ISO date to anchor the version marker (deterministic tests)")
    ap.add_argument("--force", action="store_true",
                    help="recompute even when the DB is younger than 7 days")
    ap.add_argument("--mapbiomas-db", default=None,
                    help="mapbiomas_alerta.db path (override MAPBIOMAS_DB_PATH)")
    ap.add_argument("--car-db", default=None,
                    help="car.db path (override CAR_DB_PATH)")
    ap.add_argument("--out", default="backend-lua/data/area_efetiva/area_efetiva.db")
    args = ap.parse_args()

    today = date.fromisoformat(args.today) if args.today else date.today()
    out = Path(args.out)

    # Freshness guard: the DB mtime is the success marker; skip when recent.
    if out.exists() and not args.force:
        age_days = (time.time() - out.stat().st_mtime) / 86400
        if age_days < 7:
            print("area_efetiva.db is {:.1f} days old — skipping compute "
                  "(use --force to recompute)".format(age_days))
            return 0

    mapbiomas_db = args.mapbiomas_db or default_mapbiomas_db_path()
    car_db = args.car_db or default_car_db_path()
    if not os.path.exists(mapbiomas_db):
        print(f"ERROR: mapbiomas_alerta.db not found: {mapbiomas_db}", file=sys.stderr)
        sys.exit(1)
    if not os.path.exists(car_db):
        print(f"ERROR: car.db not found: {car_db}", file=sys.stderr)
        sys.exit(1)

    n, version = run_compute(mapbiomas_db, car_db, out, args.window, today)
    print(f"=== area_efetiva.db written to {out} (version {version}) ===")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - top-level abort without marker
        print(f"ERROR: {exc} — no DB written (previous area_efetiva.db, if any, "
              "is intact)", file=sys.stderr)
        sys.exit(1)

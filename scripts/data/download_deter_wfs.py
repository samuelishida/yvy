#!/usr/bin/env python3
"""Download DETER alert polygons from the TerraBrasilis GeoServer WFS.

Stores native WFS attributes as scalar columns in `deter_polygons` and the
MultiPolygon geometry as JSON TEXT (`geom`) — Python's sqlite3 may link SQLite
< 3.45 without `jsonb()`, and Lua `json()`/`json_extract()` read TEXT fine.

FIRST STEP (verify before relying on this): run DescribeFeatureType on the
layer and confirm the incremental filter field — `view_date` vs
`published_date`/`revised_date`:
    https://terrabrasilis.dpi.inpe.br/geoserver/deter-amz/ows?service=WFS&version=1.1.0&request=DescribeFeatureType&typeName=deter-amz:deter_amz
`run_incremental()` filters on `view_date` (spec §3.2); if the live layer uses
a different field, update CQL_FILTER below.

Usage:
    python3 scripts/data/download_deter_wfs.py --days 1
    python3 scripts/data/download_deter_wfs.py --full                 # full history
    python3 scripts/data/download_deter_wfs.py --workspace deter-cerrado-nb --layer deter_cerrado --days 7
"""
import argparse
import json
import os
import sqlite3
import sys
import time
from datetime import date, timedelta
from datetime import datetime, timezone

import requests
from shapely.geometry import shape

DEFAULT_WS = "deter-amz"
DEFAULT_LAYER = "deter_amz"
PAGE = 10000  # GeoServer caps responses ~10k features (same as download_car_wfs.py)
BASE = "https://terrabrasilis.dpi.inpe.br/geoserver/{ws}/ows"
CQL_FILTER_TMPL = "view_date >= '{start}' AND view_date <= '{end}'"
UA = "Mozilla/5.0 (X11; Linux x86_64) Yvy/1.0"


def deter_db_path() -> str:
    p = os.environ.get("SQLITE_PATH")
    if p:
        return p
    return os.path.join("backend-lua", "data", "yvy.db")


def fetch_page(ws: str, layer: str, start_date: str, end_date: str, start: int) -> list:
    params = {
        "service": "WFS", "version": "1.1.0", "request": "GetFeature",
        "typeName": f"{ws}:{layer}", "outputFormat": "application/json",
        "maxFeatures": str(PAGE), "startIndex": str(start),
        "CQL_FILTER": CQL_FILTER_TMPL.format(start=start_date, end=end_date),
    }
    for attempt in range(3):
        try:
            r = requests.get(BASE.format(ws=ws), params=params, timeout=180,
                             headers={"User-Agent": UA})
            r.raise_for_status()
            data = r.json()
            # Reject non-FeatureCollection pages loudly — never silently
            # truncate (e.g. a WFS error/exception document parsed as JSON).
            if not isinstance(data, dict) or data.get("type") != "FeatureCollection" \
                    or not isinstance(data.get("features"), list):
                raise ValueError(
                    f"Expected FeatureCollection from {ws}:{layer} "
                    f"(got type={data.get('type') if isinstance(data, dict) else type(data).__name__!r}); "
                    "refusing to truncate silently"
                )
            return data["features"]
        except Exception as exc:  # retry with backoff
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)

def _num(v):
    try:
        if v is None:
            return None
        return float(v)
    except (TypeError, ValueError):
        return None

def _area_km2(props):
    """DETER area_km2: areatotalkm, else areauckm + areamunkm, else None.

    `deter-amz:deter_amz` carries no `areatotalkm`, so area falls back to the
    sum of UC + municipality areas (each defaulting to 0). If all three fields
    are absent → None: we never fabricate a value (caller warns + stores NULL).
    """
    v = _num(props.get("areatotalkm"))
    if v is not None:
        return v
    uc = _num(props.get("areauckm"))
    mun = _num(props.get("areamunkm"))
    if uc is None and mun is None:
        return None
    return (uc or 0) + (mun or 0)

def to_sqlite(features: list, db_path: str) -> int:
    """Insert DETER polygons into deter_polygons.

    Idempotent per view_date: rows for a downloaded date are replaced (the
    daily DETER set is fully fetched, so a re-run must not duplicate).
    """
    if not features:
        return 0

    conn = sqlite3.connect(db_path, timeout=60)
    conn.execute("PRAGMA busy_timeout=60000")
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    sql = """INSERT OR REPLACE INTO deter_polygons
        (classname, view_date, uf, municipality, mun_geocod, area_km2, uc,
         areauckm, areamunkm, publish_month, sensor, satellite,
         min_lat, min_lon, max_lat, max_lon, geom, ingested_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"""

    rows = []
    dates = set()
    missing_area = 0
    for f in features:
        props = f.get("properties") or {}
        geom = f.get("geometry")
        if not geom:
            continue
        try:
            bounds = shape(geom).bounds  # (minx, miny, maxx, maxy) = (lon, lat)
        except Exception:
            continue
        vd = props.get("view_date")
        if vd:
            dates.add(vd)
        area_km2 = _area_km2(props)
        if area_km2 is None:
            missing_area += 1
        rows.append((
            props.get("classname"), vd, props.get("uf"),
            props.get("municipality"), props.get("mun_geocod"),
            area_km2, props.get("uc") or None,
            _num(props.get("areauckm")), _num(props.get("areamunkm")),
            props.get("publish_month"), props.get("sensor"), props.get("satellite"),
            bounds[1], bounds[0], bounds[3], bounds[2],
            json.dumps(geom), now,
        ))
    if missing_area:
        print(f"  WARN {missing_area} feature(s) have no area fields "
              "(areatotalkm/areauckm/areamunkm all missing) -> area_km2 stored NULL",
              file=sys.stderr)

    # Delete the downloaded dates first so a re-run replaces rather than duplicates
    for vd in dates:
        conn.execute("DELETE FROM deter_polygons WHERE view_date = ?", (vd,))

    for i in range(0, len(rows), 1000):  # batch + checkpoint (R4: WAL single writer)
        conn.executemany(sql, rows[i:i + 1000])
        conn.commit()
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.close()
    return len(rows)


def last_view_date(db_path: str):
    conn = sqlite3.connect(db_path, timeout=30)
    try:
        row = conn.execute("SELECT MAX(view_date) FROM deter_polygons").fetchone()
        return row[0] if row else None
    finally:
        conn.close()


def run_incremental(db_path: str, ws: str = DEFAULT_WS, layer: str = DEFAULT_LAYER,
                    days: int = 1) -> int:
    last = last_view_date(db_path)
    end = date.today().isoformat()
    if last:
        start = last  # inclusive: re-fetch today's date + any gap
    else:
        start = (date.today() - timedelta(days=days)).isoformat()

    features = []
    start_idx = 0
    while True:
        page = fetch_page(ws, layer, start, end, start_idx)
        features.extend(page)
        print(f"  {ws}:{layer} {start}..{end} page {start_idx // PAGE + 1} -> +{len(page)} (total {len(features)})", flush=True)
        if len(page) < PAGE:
            break
        start_idx += PAGE
        time.sleep(0.3)  # be polite to the public server

    n = to_sqlite(features, db_path)
    print(f"  inserted {n} DETER polygons into {db_path}", flush=True)
    return n


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--days", type=int, default=1, help="days of history on cold start")
    ap.add_argument("--full", action="store_true", help="fetch full history (from 2016)")
    ap.add_argument("--workspace", default=DEFAULT_WS)
    ap.add_argument("--layer", default=DEFAULT_LAYER)
    ap.add_argument("--db", default=None, help="override SQLite path")
    args = ap.parse_args()

    db_path = args.db or deter_db_path()
    if not os.path.exists(db_path):
        print(f"ERROR: DB not found: {db_path}", file=sys.stderr)
        sys.exit(1)

    if args.full:
        # Full history: DETER Amazônia from ~2016. Paginate per year to keep
        # CQL responses bounded.
        total = 0
        for year in range(2016, date.today().year + 1):
            features = []
            start_idx = 0
            while True:
                page = fetch_page(args.workspace, args.layer, f"{year}-01-01", f"{year}-12-31", start_idx)
                features.extend(page)
                if len(page) < PAGE:
                    break
                start_idx += PAGE
                time.sleep(0.3)
            total += to_sqlite(features, db_path)
            print(f"  {year}: {len(features)} features", flush=True)
        print(f"done: {total} total")
    else:
        run_incremental(db_path, args.workspace, args.layer, args.days)


if __name__ == "__main__":
    main()

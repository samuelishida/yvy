#!/usr/bin/env python3
"""Download AMS layers (fire-spreading-risk + active-fire-today) → ams_risk.

Plan: terrabrasilis-integration, Inc 11. Fetches from TerraBrasilis GeoServer
workspaces `ams1h`/`ams2`/`ams3` (spec §3.3) and writes to the `ams_risk` table.

FIRST STEP (verify before relying on this): run DescribeFeatureType on each AMS
layer and map the real risk attribute to `risk_level`:
    https://terrabrasilis.dpi.inpe.br/geoserver/<ws>/ows?service=WFS&version=1.1.0&request=DescribeFeatureType&typeName=<ws>:<layer>
The spec documents `view_date, viewed_at, satelite, municipio, biome, geocode`
but NOT the risk field name — map RISK_FIELDS below from the live schema.

Usage:
    python3 scripts/download_ams_wfs.py
    python3 scripts/download_ams_wfs.py --workspaces ams2 ams3
    python3 scripts/download_ams_wfs.py --db /opt/yvy/backend-lua/data/yvy.db
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

DEFAULT_WS = ["ams1h", "ams2", "ams3"]
PAGE = 10000
BASE = "https://terrabrasilis.dpi.inpe.br/geoserver/{ws}/ows"
RISK_FIELDS = ["risk", "risk_level", "classe", "class", "nivel", "severity"]
UA = "Mozilla/5.0 (X11; Linux x86_64) Yvy/1.0"


def deter_db_path() -> str:
    p = os.environ.get("SQLITE_PATH")
    if p:
        return p
    return os.path.join("backend-lua", "data", "yvy.db")


def _num(v):
    try:
        return float(v) if v is not None else None
    except (TypeError, ValueError):
        return None


def fetch(ws: str, layer: str, start: int) -> list:
    params = {
        "service": "WFS", "version": "1.1.0", "request": "GetFeature",
        "typeName": f"{ws}:{layer}", "outputFormat": "application/json",
        "maxFeatures": str(PAGE), "startIndex": str(start),
    }
    for attempt in range(3):
        try:
            r = requests.get(BASE.format(ws=ws), params=params, timeout=180, headers={"User-Agent": UA})
            r.raise_for_status()
            return r.json().get("features", [])
        except Exception:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def to_sqlite(features: list, db_path: str) -> int:
    if not features:
        return 0
    conn = sqlite3.connect(db_path, timeout=60)
    conn.execute("PRAGMA busy_timeout=60000")
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    sql = """INSERT OR REPLACE INTO ams_risk
        (view_date, viewed_at, satelite, municipio, biome, geocode, layer, risk_level,
         min_lat, min_lon, max_lat, max_lon, geom, ingested_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)"""

    rows = []
    dates = set()
    for f in features:
        props = f.get("properties") or {}
        geom = f.get("geometry")
        if not geom:
            continue
        try:
            bounds = shape(geom).bounds
        except Exception:
            continue
        vd = props.get("view_date")
        if vd:
            dates.add(vd)
        risk = None
        for k in RISK_FIELDS:
            if props.get(k) is not None:
                risk = str(props[k])
                break
        rows.append((
            vd, props.get("viewed_at"), props.get("satelite") or props.get("satelite"),
            props.get("municipio"), props.get("biome"), props.get("geocode"),
            props.get("layer") or (f.get("id") or "unknown"), risk,
            bounds[1], bounds[0], bounds[3], bounds[2],
            json.dumps(geom), now,
        ))

    # Replace the downloaded dates (daily layers replace the previous day)
    for vd in dates:
        conn.execute("DELETE FROM ams_risk WHERE view_date = ?", (vd,))
    for i in range(0, len(rows), 1000):
        conn.executemany(sql, rows[i:i + 1000])
        conn.commit()
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.close()
    return len(rows)


def run(ws_list, db_path):
    total = 0
    for ws in ws_list:
        for layer in ("fire-spreading-risk", "active-fire-today"):
            try:
                features = []
                start = 0
                while True:
                    page = fetch(ws, layer, start)
                    features.extend(page)
                    if len(page) < PAGE:
                        break
                    start += PAGE
                    time.sleep(0.3)
                n = to_sqlite(features, db_path)
                print(f"  {ws}:{layer} -> {n} rows", flush=True)
                total += n
            except Exception as exc:
                print(f"  WARN {ws}:{layer} failed: {exc}", file=sys.stderr)
    print(f"done: {total} ams_risk rows into {db_path}")
    return total


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--workspaces", nargs="*", default=DEFAULT_WS)
    ap.add_argument("--db", default=None, help="override SQLite path")
    args = ap.parse_args()

    db_path = args.db or deter_db_path()
    if not os.path.exists(db_path):
        print(f"ERROR: DB not found: {db_path}", file=sys.stderr)
        sys.exit(1)
    run(args.workspaces, db_path)


if __name__ == "__main__":
    main()

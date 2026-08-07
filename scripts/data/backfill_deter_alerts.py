#!/usr/bin/env python3
"""Backfill / roll up DETER daily aggregates into `deter_alerts`.

Two sources, one table (spec P1 — DETER agregado diário por geocod×classe×data):

1. `backfill_from_dashboard(json_path, db_path)` — historical backfill from the
   dashboard JSON (deter-amazon-daily.json, ~88k rows GeoJSON). Each feature
   properties: `b`=mun_geocod, `c`=classname, `d`/`e`=area km² (equal in the
   2026-08-07 sample — `d` is stored as area_km2), `g`=view_date, `h`=uf,
   `i`=municipality name. Idempotent: `ON CONFLICT DO NOTHING` fills only days
   with no `deter_alerts` row, so it never overwrites polygon-derived areas.

2. `rollup_to_deter_alerts(db_path)` — upserts the last N days of
   `deter_polygons` (summed per mun_geocod×classname×view_date) into
   `deter_alerts`. Polygon-derived rollup WINS for recent days (DO UPDATE).

Usage:
    python3 scripts/data/backfill_deter_alerts.py --backfill deter-amazon-daily.json
    python3 scripts/data/backfill_deter_alerts.py --rollup --days 3
"""
import argparse
import json
import os
import sqlite3
from datetime import date, timedelta
from datetime import datetime, timezone


def deter_db_path() -> str:
    p = os.environ.get("SQLITE_PATH")
    if p:
        return p
    return os.path.join("backend-lua", "data", "yvy.db")


def backfill_from_dashboard(json_path: str, db_path: str) -> int:
    with open(json_path, "r", encoding="utf-8") as f:
        data = json.load(f)
    features = data.get("features", []) if isinstance(data, dict) else data

    conn = sqlite3.connect(db_path, timeout=60)
    conn.execute("PRAGMA busy_timeout=60000")
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    sql = """INSERT INTO deter_alerts (mun_geocod, municipality, classname, view_date, area_km2, uf, ingested_at)
             VALUES (?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(mun_geocod, classname, view_date) DO NOTHING"""

    rows = []
    for f in features:
        p = f.get("properties") or {}
        geocod = p.get("b")
        cls = p.get("c")
        vd = p.get("g")
        area = p.get("d")
        uf = p.get("h")
        municipality = p.get("i")
        if not geocod or not cls or not vd:
            continue
        try:
            area = float(area)
        except (TypeError, ValueError):
            area = 0.0
        rows.append((str(geocod), municipality, str(cls), str(vd), area, uf, now))

    inserted = 0
    for i in range(0, len(rows), 1000):
        cur = conn.executemany(sql, rows[i:i + 1000])
        conn.commit()
        inserted += cur.rowcount
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.close()
    print(f"backfill: {inserted} new deter_alerts rows (of {len(rows)} in JSON)")
    return inserted


def rollup_to_deter_alerts(db_path: str, days: int = 3) -> int:
    conn = sqlite3.connect(db_path, timeout=60)
    conn.execute("PRAGMA busy_timeout=60000")
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    cutoff = (date.today() - timedelta(days=days)).isoformat()

    sql = """INSERT INTO deter_alerts (mun_geocod, municipality, classname, view_date, area_km2, uf, ingested_at)
             SELECT mun_geocod, MAX(municipality), classname, view_date, SUM(area_km2), MAX(uf), ?
             FROM deter_polygons
             WHERE view_date >= ? AND mun_geocod IS NOT NULL AND classname IS NOT NULL
             GROUP BY mun_geocod, classname, view_date
             ON CONFLICT(mun_geocod, classname, view_date)
             DO UPDATE SET municipality = excluded.municipality, area_km2 = excluded.area_km2, uf = excluded.uf, ingested_at = excluded.ingested_at"""
    cur = conn.execute(sql, (now, cutoff))
    conn.commit()
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.close()
    print(f"rollup: upserted {cur.rowcount} deter_alerts rows (last {days}d of polygons)")
    return cur.rowcount


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--backfill", metavar="JSON", help="path to deter-amazon-daily.json")
    ap.add_argument("--rollup", action="store_true", help="roll up recent deter_polygons")
    ap.add_argument("--days", type=int, default=3)
    ap.add_argument("--db", default=None, help="override SQLite path")
    args = ap.parse_args()

    db_path = args.db or deter_db_path()
    if args.backfill:
        backfill_from_dashboard(args.backfill, db_path)
    if args.rollup:
        rollup_to_deter_alerts(db_path, args.days)
    if not args.backfill and not args.rollup:
        ap.print_help()


if __name__ == "__main__":
    main()

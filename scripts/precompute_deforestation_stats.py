#!/usr/bin/env python3
"""Precompute deforestation area by territory (Inc 7).

Offline daily job: spatial join of `deforestation_data` (PRODES points, ~2M in
the DB) against municipality / UC / TI polygons, aggregated by territory ×
year, written as JSON blobs into `lookup_data` (`def_stats:<tipo>:<year>` and
`:all`). The Lua routes read only these blobs — no live spatial join in the
copas loop.

Area per point = 0.09 ha (30m PRODES pixel) = 0.0009 km². Class/year parsed
from `data.name` (QML label, `dYYYY`/`rYYYY` — no structured column).

Usage:
    python3 scripts/precompute_deforestation_stats.py --db backend-lua/data/yvy.db
"""
import argparse
import json
import os
import sqlite3
from datetime import datetime, timezone

import geopandas as gpd
from shapely.geometry import shape

PIXEL_KM2 = 0.0009  # 30m x 30m PRODES
DATA_DIR = os.path.join("backend-lua", "data")
FILES = {
    "municipio": "municipalities.geojson",
    "uc": "conservation_units.json",
    "ti": "indigenous_lands.json",
}


def load_territories(kind: str):
    """GeoDataFrame com {key, nome, uf?, ...} + geometry."""
    path = os.path.join(DATA_DIR, FILES[kind])
    if not os.path.exists(path):
        print(f"  SKIP {kind}: {path} not found (run download_aux_layers.py first)")
        return None
    gdf = gpd.read_file(path)
    if gdf.empty:
        return None

    if kind == "municipio":
        gdf = gdf.rename(columns={gdf.columns[0]: "key", gdf.columns[1]: "nome"})
        for col in ("geocodigo", "geocod", "cod_ibge", "codmunicipio"):
            if col in gdf.columns:
                gdf["key"] = gdf[col].astype(str)
                break
        if "nome" not in gdf.columns:
            gdf["nome"] = gdf["key"]
        gdf["uf"] = gdf.get("uf") or gdf.get("sigla_uf") or gdf.get("estado") or None
    elif kind == "uc":
        for col in ("nome", "name"):
            if col in gdf.columns:
                gdf["nome"] = gdf[col]
                break
        gdf["key"] = gdf["nome"]
        gdf["categoria"] = gdf.get("categoria")
        gdf["grupo"] = gdf.get("grupo")
    elif kind == "ti":
        for col in ("terrai_nom", "nome", "name"):
            if col in gdf.columns:
                gdf["nome"] = gdf[col]
                break
        gdf["key"] = gdf["nome"]
        gdf["etnia_nome"] = gdf.get("etnia_nome")

    gdf["geometry"] = gpd.GeoSeries([shape(g) for g in gdf.geometry])
    gdf = gdf[gdf.geometry.notna() & ~gdf.geometry.is_empty]
    return gdf


def read_deforestation(db_path: str):
    import re
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=60)
    rows = conn.execute(
        """SELECT lat, lon, json_extract(data, '$.name') AS name
           FROM deforestation_data WHERE lat IS NOT NULL AND lon IS NOT NULL""").fetchall()
    conn.close()
    points = []
    for lat, lon, name in rows:
        mm = re.match(r"^([dr])(\d{4})$", name or "")
        if mm:
            points.append({"lat": lat, "lon": lon, "year": int(mm.group(2)), "type": mm.group(1)})
    return points


def aggregate(kind: str, ter_gdf, points):
    """Área por território × ano (e total all)."""
    if ter_gdf is None or not points:
        return {}
    sindex = ter_gdf.sindex
    # Buckets: por ano
    from collections import defaultdict
    per_year = defaultdict(lambda: defaultdict(float))  # year -> key -> km2
    meta = {}
    for i, row in ter_gdf.iterrows():
        meta[row["key"]] = row

    for p in points:
        hits = list(sindex.intersection((p["lon"], p["lat"], p["lon"], p["lat"])))
        for idx in hits:
            geom = ter_gdf.geometry.iloc[idx]
            if geom.contains((p["lon"], p["lat"])):
                key = ter_gdf["key"].iloc[idx]
                per_year[p["year"]][key] += PIXEL_KM2
                break  # first containing territory (ANY containment, edge case)

    result = {}
    years = sorted(per_year.keys())
    for y in years + ["all"]:
        items = []
        if y == "all":
            merged = defaultdict(float)
            for yy in years:
                for k, v in per_year[yy].items():
                    merged[k] += v
            buckets = merged
        else:
            buckets = per_year[y]
        for key, area in buckets.items():
            m = meta.get(key)
            item = {"key": key, "area_km2": round(area, 2), "year": y}
            if kind == "municipio":
                item["nome"] = m.get("nome") if m is not None else key
                item["uf"] = m.get("uf") if m is not None else None
            elif kind == "uc":
                item["nome"] = m.get("nome") if m is not None else key
                item["categoria"] = m.get("categoria") if m is not None else None
                item["grupo"] = m.get("grupo") if m is not None else None
            elif kind == "ti":
                item["nome"] = m.get("nome") if m is not None else key
                item["etnia_nome"] = m.get("etnia_nome") if m is not None else None
            items.append(item)
        result[str(y)] = {"items": items, "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    return result


def write_lookup(conn, key: str, blob: dict):
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    conn.execute(
        "INSERT INTO lookup_data (key, data, updated_at) VALUES (?, ?, ?) "
        "ON CONFLICT(key) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at",
        (key, json.dumps(blob), now))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", default=os.path.join("backend-lua", "data", "yvy.db"))
    ap.add_argument("--kinds", nargs="*", default=["municipio", "uc", "ti"])
    args = ap.parse_args()

    points = read_deforestation(args.db)
    print(f"deforestation points: {len(points)}")

    conn = sqlite3.connect(args.db, timeout=60)
    conn.execute("PRAGMA busy_timeout=60000")
    conn.execute("PRAGMA journal_mode=WAL")

    for kind in args.kinds:
        ter = load_territories(kind)
        if ter is None:
            print(f"  SKIP {kind}: no layer")
            continue
        agg = aggregate(kind, ter, points)
        for period, blob in agg.items():
            write_lookup(conn, f"def_stats:{kind}:{period}", blob)
            print(f"  def_stats:{kind}:{period} -> {len(blob['items'])} itens")
    conn.commit()
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.close()
    print("done")


if __name__ == "__main__":
    main()

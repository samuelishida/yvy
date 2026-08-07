#!/usr/bin/env python3
"""Download AMS fire layers (fire-spreading-risk + active-fire-today) → ams_risk.

Plan: terrabrasilis-fixes, Inc 4. Discovers fire layers per workspace via
GetCapabilities (ams1h/ams3 carry fire layers; ams2 exposes only
municipalities_border) and writes to the `ams_risk` table under `ws:layer`.

LAYER SCHEMA (DescribeFeatureType verified live 2026-08-07):
  - ams1h:fire-spreading-risk + ams3:fire-spreading-risk = POLYGONs,
    attrs: id, biome, geocode, geom, municipality, view_date. NO risk attribute.
  - ams1h:active-fire-today + ams3:active-fire-today = POINTs,
    attrs: id, biome, municipio, satelite, view_date, viewed_at. NO risk attribute.
  => risk_level is presence-based (see derive_risk) and intentionally constant
     per layer; there is no risk field upstream to map.

Usage:
    python3 scripts/data/download_ams_wfs.py
    python3 scripts/data/download_ams_wfs.py --workspaces ams2 ams3
    python3 scripts/data/download_ams_wfs.py --db /opt/yvy/backend-lua/data/yvy.db
"""
import argparse
import json
import os
import re
import sqlite3
import sys
import time
from datetime import datetime, timezone

import requests
from shapely.geometry import shape

DEFAULT_WS = ["ams1h", "ams2", "ams3"]
PAGE = 10000
BASE = "https://terrabrasilis.dpi.inpe.br/geoserver/{ws}/ows"
UA = "Mozilla/5.0 (X11; Linux x86_64) Yvy/1.0"

# DescribeFeatureType verified 2026-08-07 — neither `fire-spreading-risk` nor
# `active-fire-today` carries a risk attribute, so risk_level is presence-based
# and intentionally constant per layer. This map is the single place to extend
# if real risk tiers appear upstream. Unknown layers fall back to UNKNOWN_RISK.
RISK_BY_LAYER = {
    "fire-spreading-risk": "high",
    "active-fire-today": "high",
}
UNKNOWN_RISK = "medium"


def derive_risk(layer_name: str) -> str:
    """Presence-based risk for an AMS layer (constant per layer, see module doc).

    Never returns None: an unknown layer logs a warning and falls back to
    UNKNOWN_RISK so `risk_level` is never NULL in ams_risk.
    """
    risk = RISK_BY_LAYER.get(layer_name)
    if risk is None:
        print(f"  WARN unknown AMS layer {layer_name!r}: "
              f"defaulting risk_level to {UNKNOWN_RISK!r}", file=sys.stderr)
        return UNKNOWN_RISK
    return risk


def _get_capabilities(ws: str, scheme: str) -> str:
    url = f"{scheme}://terrabrasilis.dpi.inpe.br/geoserver/{ws}/ows"
    params = {"service": "WFS", "version": "2.0.0", "request": "GetCapabilities"}
    r = requests.get(url, params=params, timeout=60, headers={"User-Agent": UA})
    r.raise_for_status()
    return r.text


def discover_workspace_layers(ws: str) -> list:
    """Layers in workspace `ws` whose name contains 'fire' (GetCapabilities).

    Parses `<Name>ws:layer</Name>` entries — this auto-selects
    `fire-spreading-risk` + `active-fire-today` in ams1h/ams3 and excludes
    `dummy` / `cs_*_view` / `last_date` / `municipalities_border` (no 'fire'
    keyword). A workspace with no fire layers returns [] so the caller can skip
    it gracefully (ams2 only exposes municipalities_border). GetCapabilities
    over https that fails with a TLS/cert error is retried once over http.
    """
    xml = None
    last_exc = None
    for scheme in ("https", "http"):
        try:
            xml = _get_capabilities(ws, scheme)
            break
        except requests.exceptions.SSLError as exc:
            last_exc = exc  # https TLS/cert failure → retry once over http
        except requests.exceptions.RequestException:
            raise  # non-TLS HTTP failure: no downgrade, propagate
    if xml is None:
        raise RuntimeError(f"GetCapabilities failed for workspace {ws!r} "
                           "(https and http)") from last_exc

    layers = []
    for name in re.findall(r"<Name>([^<]+)</Name>", xml):
        ws_part, sep, layer_part = name.partition(":")
        if sep and ws_part == ws and "fire" in layer_part:
            layers.append(layer_part)
    return sorted(set(layers))


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
            data = r.json()
            # Reject non-FeatureCollection pages loudly — never silently
            # truncate (e.g. a WFS error/exception document parsed as JSON).
            if not isinstance(data, dict) or data.get("type") != "FeatureCollection" \
                    or not isinstance(data.get("features"), list):
                raise ValueError(
                    f"Expected FeatureCollection from {ws}:{layer} "
                    f"(got type={data.get('type') if isinstance(data, dict) else type(data).__name__!r}); "
                    "refusing to ingest a truncated/error page"
                )
            return data["features"]
        except Exception:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def to_sqlite(features: list, db_path: str, ws: str, layer: str) -> int:
    """Insert AMS features into ams_risk under the `ws:layer` layer name.

    Idempotent per (view_date, layer): rows for a downloaded date are replaced,
    but ONLY for this layer — sibling layers sharing the same view_date are
    untouched. All DELETE + INSERT for this layer run in a single transaction so
    a mid-run failure can't leave a day half-wiped.
    """
    if not features:
        return 0
    conn = sqlite3.connect(db_path, timeout=60)
    conn.execute("PRAGMA busy_timeout=60000")
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    ws_layer = f"{ws}:{layer}"
    risk_level = derive_risk(layer)

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
            print(f"  WARN skip {ws_layer} feature without geometry", file=sys.stderr)
            continue
        try:
            bounds = shape(geom).bounds  # (minx, miny, maxx, maxy) = (lon, lat)
        except Exception:
            print(f"  WARN skip {ws_layer} feature with unparsable geometry", file=sys.stderr)
            continue
        vd = props.get("view_date")
        if vd:
            dates.add(vd)
        rows.append((
            vd, props.get("viewed_at"), props.get("satelite"),
            props.get("municipio"), props.get("biome"), props.get("geocode"),
            ws_layer, risk_level,
            bounds[1], bounds[0], bounds[3], bounds[2],
            json.dumps(geom), now,
        ))

    conn.execute("BEGIN")
    try:
        for vd in dates:
            # (a) this layer's rows for the affected dates (new-style ws:layer)
            conn.execute("DELETE FROM ams_risk WHERE view_date = ? AND layer = ?", (vd, ws_layer))
            # (b) one-time legacy cleanup: old rows stored the feature id
            #     (no ':') with NULL risk_level — remove for these dates so they
            #     can't linger next to the new ws:layer rows.
            conn.execute("DELETE FROM ams_risk WHERE view_date = ? AND layer NOT LIKE '%:%'", (vd,))
        for i in range(0, len(rows), 1000):
            conn.executemany(sql, rows[i:i + 1000])
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.close()
    return len(rows)


def run(ws_list: list, db_path: str) -> int:
    total = 0
    for ws in ws_list:
        try:
            layers = discover_workspace_layers(ws)
        except Exception as exc:
            print(f"  WARN {ws}: layer discovery failed: {exc}", file=sys.stderr)
            continue
        if not layers:
            print(f"  {ws}: no fire layers found (skipping)", flush=True)
            continue
        print(f"  {ws}: discovered fire layers: {', '.join(layers)}", flush=True)
        for layer in layers:
            try:
                features = []
                start = 0
                while True:
                    page = fetch(ws, layer, start)
                    features.extend(page)
                    if len(page) < PAGE:
                        break
                    start += PAGE
                    time.sleep(0.3)  # be polite to the public server
                n = to_sqlite(features, db_path, ws, layer)
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

#!/usr/bin/env python3
"""Download territorial polygon layers for deforestation stats (Inc 7).

The repo ships `states_brazil.geojson`, `conservation_units.json` and
`indigenous_lands.json` but NO municipality polygons — by-municipality stats
are impossible without this layer. This script fetches:
  - `municipalities_<biome>` (TerraBrasilis WFS, spec §3.4) → municipalities.geojson
  - refreshed UC/TI polygons → conservation_units.json / indigenous_lands.json
    (same names the Lua lookups read from backend-lua/data/)

Usage:
    python3 scripts/data/download_aux_layers.py                      # default biomes amz+cerrado
    python3 scripts/data/download_aux_layers.py --biomes amz cerrado caatinga
    python3 scripts/data/download_aux_layers.py --workspace auxiliary-data --layer municipalities_amz
"""
import argparse
import json
import os
import sys
import time

import requests

BASE = "https://terrabrasilis.dpi.inpe.br/geoserver/{ws}/ows"
PAGE = 10000
UA = "Mozilla/5.0 (X11; Linux x86_64) Yvy/1.0"
OUT_DIR = os.path.join("backend-lua", "data")

# Workspace/layer padrão — VERIFIQUE com DescribeFeatureType na primeira execução
# (a spec §3.4 lista `municipalities_<biome>`; o workspace pode ser auxiliary-data).
DEFAULT_BIOMES = ["amz", "cerrado"]


def fetch(ws: str, layer: str, biome: str) -> list:
    features = []
    start = 0
    while True:
        params = {
            "service": "WFS", "version": "1.1.0", "request": "GetFeature",
            "typeName": f"{ws}:{layer}_{biome}", "outputFormat": "application/json",
            "maxFeatures": str(PAGE), "startIndex": str(start),
        }
        r = requests.get(BASE.format(ws=ws), params=params, timeout=180,
                         headers={"User-Agent": UA})
        r.raise_for_status()
        page = r.json().get("features", [])
        features.extend(page)
        print(f"  {layer}_{biome}: page {start // PAGE + 1} -> +{len(page)} (total {len(features)})", flush=True)
        if len(page) < PAGE:
            break
        start += PAGE
        time.sleep(0.3)
    return features


def save(name: str, features: list) -> str:
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name)
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"type": "FeatureCollection", "features": features}, f)
    print(f"  wrote {path} ({len(features)} features, {os.path.getsize(path) / 1e6:.1f} MB)")
    return path


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--workspace", default="auxiliary-data")
    ap.add_argument("--biomes", nargs="*", default=DEFAULT_BIOMES)
    ap.add_argument("--municipalities-only", action="store_true", help="skip UC/TI refresh")
    args = ap.parse_args()

    # 1. Municípios (concatena biomas)
    all_mun = []
    for biome in args.biomes:
        feats = fetch(args.workspace, "municipalities", biome)
        all_mun.extend(feats)
        print(f"  biome {biome}: {len(feats)} municípios", flush=True)
    if all_mun:
        save("municipalities.geojson", all_mun)
    else:
        print("WARNING: no municipality features fetched — check layer name via DescribeFeatureType", file=sys.stderr)

    # 2. UC/TI refresh (a partir do GeoServer territorial; se falhar, mantém os
    #    arquivos existentes do repo — as rotas de stats só precisam de municípios novos)
    if not args.municipalities_only:
        for layer, out_name in (("conservation_units", "conservation_units.json"),
                                ("indigenous_lands", "indigenous_lands.json")):
            try:
                feats = fetch(args.workspace, layer, "br")
                if feats:
                    save(out_name, feats)
            except Exception as exc:
                print(f"WARNING: {layer} refresh failed ({exc}) — keeping existing file", file=sys.stderr)


if __name__ == "__main__":
    main()

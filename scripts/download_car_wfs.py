#!/usr/bin/env python3
"""Download CAR property perimeters (Perímetros dos imóveis) from the SICAR GeoServer WFS.

The official SHP downloads at consultapublica.car.gov.br are captcha-gated, but the
CAR GeoServer (https://geoserver.car.gov.br/geoserver/sicar/wfs) exposes the SAME
data as `sicar:sicar_imoveis_<uf>` via WFS GetFeature — scriptable, no captcha,
outputFormat=application/json (GeoJSON). The server caps responses at 10,000
features, so we page with startIndex until a short page arrives.

Usage:
    python3 scripts/download_car_wfs.py RO                # one state
    python3 scripts/download_car_wfs.py RO MT PA          # several
    python3 scripts/download_car_wfs.py --all             # all 27 UFs

Output: backend-lua/data/car/<UF>.json — a GeoJSON FeatureCollection with the
fields: cod_imovel (CAR code), status_imovel, dat_criacao, area (ha), condicao,
uf, municipio, cod_municipio_ibge, m_fiscal, tipo_imovel. This matches the input
format that car_lookup.lua (plan: fire-nature-classify, Inc 6) consumes.
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

BASE = "https://geoserver.car.gov.br/geoserver/sicar/wfs"
PAGE = 10000  # server maxFeatures cap
STATES = "ac al am ap ba ce df es go ma mg ms mt pa pb pe pi pr rj rn ro rr rs sc se sp to".split()
OUT_DIR = os.path.join("backend-lua", "data", "car")


def fetch(uf: str, start: int) -> dict:
    q = urllib.parse.urlencode({
        "service": "WFS", "version": "1.1.0", "request": "GetFeature",
        "typeName": f"sicar:sicar_imoveis_{uf}",
        "startIndex": str(start), "maxFeatures": str(PAGE),
        "outputFormat": "application/json",
    })
    req = urllib.request.Request(f"{BASE}?{q}", headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64)"})
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.load(r)


def download(uf: str) -> int:
    feats = []
    start = 0
    while True:
        page = fetch(uf, start)
        page_feats = page.get("features", [])
        feats.extend(page_feats)
        print(f"  {uf}: page {start // PAGE + 1} -> +{len(page_feats)} (total {len(feats)})", flush=True)
        if len(page_feats) < PAGE:
            break
        start += PAGE
        time.sleep(0.4)  # be polite to the public server

    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, f"{uf.upper()}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"type": "FeatureCollection", "features": feats}, f)
    size_mb = os.path.getsize(path) / 1e6
    print(f"{uf}: {len(feats)} imóveis -> {path} ({size_mb:.1f} MB)", flush=True)
    return len(feats)


def main() -> None:
    args = [a.lower() for a in sys.argv[1:]]
    if "--all" in args:
        targets = STATES
    elif args:
        targets = [a for a in args if a in STATES]
        missing = [a for a in args if a not in STATES]
        if missing:
            print(f"ignoring unknown UFs: {missing}", file=sys.stderr)
    else:
        print(__doc__)
        sys.exit(1)

    if not targets:
        sys.exit("no valid UFs given")

    total = 0
    for uf in targets:
        t0 = time.time()
        total += download(uf)
        print(f"  ({time.time() - t0:.1f}s)", flush=True)
    print(f"done: {len(targets)} estados, {total} imóveis em {OUT_DIR}")


if __name__ == "__main__":
    main()

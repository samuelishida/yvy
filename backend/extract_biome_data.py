#!/usr/bin/env python3
"""Convert bioma.shp to biome_data.json.

Run once (from backend/):
    python extract_biome_data.py

Reads:  data/bioma.shp
Writes: biome_data.json
"""
from __future__ import annotations

import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from biome_lookup import _read_shp_polygons, BIOME_COLORS

SHP = os.path.join(os.path.dirname(__file__), "data", "bioma.shp")
OUT = os.path.join(os.path.dirname(__file__), "biome_data.json")
TOLERANCE = 0.05  # ~5 km Douglas-Peucker tolerance

# Order confirmed by bounding-box centroid analysis (no .dbf in this file)
SHAPE_NAMES = [
    "Amazônia",       # shape 0: centroid lon=-58.5 lat=-5.5
    "Caatinga",       # shape 1: centroid lon=-39.8 lat=-9.4
    "Cerrado",        # shape 2: centroid lon=-50.8 lat=-13.5
    "Pampa",          # shape 3: centroid lon=-53.7 lat=-30.9
    "Pantanal",       # shape 4: centroid lon=-57.1 lat=-18.8
    "Mata Atlântica", # shape 5: centroid lon=-42.3 lat=-16.9
]


def _rdp(pts: list, tol: float) -> list:
    if len(pts) <= 2:
        return list(pts)
    x0, y0 = pts[0]
    xn, yn = pts[-1]
    dx, dy = xn - x0, yn - y0
    denom = math.hypot(dx, dy) or 1e-10
    dmax, idx = 0.0, 0
    for i in range(1, len(pts) - 1):
        xi, yi = pts[i]
        d = abs(dy * xi - dx * yi + xn * y0 - yn * x0) / denom
        if d > dmax:
            dmax, idx = d, i
    if dmax > tol:
        return _rdp(pts[: idx + 1], tol)[:-1] + _rdp(pts[idx:], tol)
    return [pts[0], pts[-1]]


def _rdp_ring(ring: list, tol: float) -> list:
    """Simplify a closed polygon ring (handles first==last closing point)."""
    pts = list(ring)
    # Strip closing point so RDP sees an open polyline
    if len(pts) > 1 and pts[0][0] == pts[-1][0] and pts[0][1] == pts[-1][1]:
        pts = pts[:-1]
    simp = _rdp(pts, tol) if len(pts) > 2 else pts
    if len(simp) < 3:
        return []
    return simp + [simp[0]]  # re-close


def main() -> None:
    if not os.path.exists(SHP):
        sys.exit(f"Shapefile not found: {SHP}")

    polygons = _read_shp_polygons(SHP)
    print(f"Loaded {len(polygons)} shapes from {SHP}")

    result: dict[str, dict] = {}
    total_raw = 0

    for i, rings in enumerate(polygons):
        name = SHAPE_NAMES[i] if i < len(SHAPE_NAMES) else f"Biome_{i}"
        simplified_rings = []
        for ring in rings:
            pts = list(ring)  # (lon, lat) tuples from _read_shp_polygons
            total_raw += len(pts)
            simp = _rdp_ring(pts, TOLERANCE)
            if len(simp) >= 3:
                simplified_rings.append([[round(x, 4), round(y, 4)] for x, y in simp])

        if simplified_rings:
            result[name] = {
                "color": BIOME_COLORS.get(name, ""),
                "rings": simplified_rings,
            }

    total_simp = sum(sum(len(r) for r in v["rings"]) for v in result.values())
    print(f"Points: {total_raw:,} -> {total_simp:,} ({100 * total_simp // total_raw}% kept)")
    for name in SHAPE_NAMES:
        if name in result:
            pts = sum(len(r) for r in result[name]["rings"])
            print(f"  {name}: {len(result[name]['rings'])} ring(s), {pts} pts")

    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, separators=(",", ":"))
    print(f"\nWritten: {OUT} ({os.path.getsize(OUT) // 1024} KB)")


if __name__ == "__main__":
    main()

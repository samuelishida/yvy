"""Biome point-in-polygon lookup using pre-computed biome_data.json.

Generate the data file once with:
    python extract_biome_data.py
"""
from __future__ import annotations

import json
import logging
import os

from _geo import point_in_ring

logger = logging.getLogger(__name__)

DATA_FILE = os.path.join(os.path.dirname(__file__), "biome_data.json")

BIOME_ORDER = ["Amazônia", "Cerrado", "Caatinga", "Mata Atlântica", "Pantanal", "Pampa"]

BIOME_COLORS: dict[str, str] = {
    "Amazônia":       "linear-gradient(90deg,#ef4444,#f97316)",
    "Cerrado":        "linear-gradient(90deg,#fb923c,#fbbf24)",
    "Caatinga":       "linear-gradient(90deg,#fbbf24,#facc15)",
    "Mata Atlântica": "linear-gradient(90deg,#a78bfa,#c4b5fd)",
    "Pantanal":       "linear-gradient(90deg,#2dd4ff,#67e8f9)",
    "Pampa":          "linear-gradient(90deg,#4ade80,#86efac)",
}

# Flat list of (biome_name, ring) — each ring is an independent polygon [[lon,lat],...]
_biome_rings: list[tuple[str, list]] = []
# Resolved colors from JSON (overrides hardcoded if present)
_biome_colors: dict[str, str] = {}


def load_biomes() -> None:
    global _biome_rings, _biome_colors
    if not os.path.exists(DATA_FILE):
        logger.warning("biome_data.json not found — biome lookup disabled")
        return
    with open(DATA_FILE, encoding="utf-8") as f:
        data = json.load(f)
    _biome_rings = []
    _biome_colors = {}
    for name in BIOME_ORDER:
        biome = data.get(name)
        if not biome:
            logger.warning("Biome '%s' missing in biome_data.json", name)
            continue
        color = biome.get("color") or BIOME_COLORS.get(name, "")
        _biome_colors[name] = color
        for ring in biome.get("rings", []):
            _biome_rings.append((name, ring))
    logger.info("Loaded %d biome rings for %d biomes", len(_biome_rings), len(_biome_colors))


def classify_point(lat: float, lon: float) -> str | None:
    for name, ring in _biome_rings:
        if point_in_ring(lon, lat, ring):
            return name
    return None


def classify_fires(fires: list[dict]) -> list[dict]:
    if not _biome_rings:
        return []
    counts: dict[str, int] = {b: 0 for b in BIOME_ORDER}
    total = 0
    for fire in fires:
        lat = fire.get("lat")
        lon = fire.get("lon")
        if lat is None or lon is None:
            continue
        biome = classify_point(float(lat), float(lon))
        if biome and biome in counts:
            counts[biome] += 1
            total += 1
    result = []
    for bname in BIOME_ORDER:
        c = counts[bname]
        pct = round(c / total * 100, 1) if total > 0 else 0
        result.append({
            "name": bname,
            "count": c,
            "pct": pct,
            "color": _biome_colors.get(bname, BIOME_COLORS.get(bname, "")),
        })
    return result

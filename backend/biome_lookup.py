"""Biome lookup using hardcoded IBGE boundaries.

Uses pre-extracted and simplified biome boundaries for fast point-in-polygon
classification. This avoids slow shapefile parsing at startup (~10x faster).
"""
from __future__ import annotations

import json
import logging
import os

logger = logging.getLogger(__name__)

# Biome colours matching the frontend palette
BIOME_COLORS: dict[str, str] = {
    "Amazônia":  "linear-gradient(90deg,#ef4444,#f97316)",
    "Cerrado":   "linear-gradient(90deg,#fb923c,#fbbf24)",
    "Caatinga":  "linear-gradient(90deg,#fbbf24,#facc15)",
    "Mata Atlântica": "linear-gradient(90deg,#a78bfa,#c4b5fd)",
    "Pantanal":  "linear-gradient(90deg,#2dd4ff,#67e8f9)",
    "Pampa":     "linear-gradient(90deg,#4ade80,#86efac)",
}

# Ordered biome list for consistent output
BIOME_ORDER = ["Amazônia", "Cerrado", "Caatinga", "Mata Atlântica", "Pantanal", "Pampa"]

# In-memory biome polygons: list of (name, [rings]) where each ring is list of (lon, lat)
_biome_polygons: list[tuple[str, list[list[tuple[float, float]]]]] = []


# ── Load biome data from JSON ──────────────────────────────────────────────

def _load_biome_data_from_json() -> dict[str, list]:
    """Load biome boundaries from biome_data.json.
    
    Returns:
        Dict mapping biome name -> list of geometries (each geometry is list of rings,
        each ring is list of [lon, lat] coordinate pairs).
    """
    data_file = os.path.join(os.path.dirname(__file__), "biome_data.json")
    
    if not os.path.exists(data_file):
        logger.warning("biome_data.json not found at %s – biome lookup disabled", data_file)
        return {}
    
    try:
        with open(data_file, "r", encoding="utf-8") as f:
            data = json.load(f)
        logger.info("Loaded biome data from %s", data_file)
        return data
    except Exception as e:
        logger.warning("Failed to load biome_data.json: %s", e)
        return {}


# ── Point-in-polygon (ray casting) ──────────────────────────────────────

def _point_in_ring(px: float, py: float, ring: list[tuple[float, float]]) -> bool:
    """Ray-casting algorithm for point-in-polygon."""
    n = len(ring)
    if n < 3:
        return False
    
    inside = False
    j = n - 1
    for i in range(n):
        xi, yi = ring[i]
        xj, yj = ring[j]
        if ((yi > py) != (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi):
            inside = not inside
        j = i
    return inside


def _point_in_polygon(px: float, py: float, rings: list[list[tuple[float, float]]]) -> bool:
    """Check if point is inside polygon (first ring = exterior, rest = holes)."""
    if not rings:
        return False
    # Must be inside exterior ring
    if not _point_in_ring(px, py, rings[0]):
        return False
    # Must not be inside any hole
    for hole in rings[1:]:
        if _point_in_ring(px, py, hole):
            return False
    return True


# ── Public API ────────────────────────────────────────────────────────────

def load_biomes() -> None:
    """Load IBGE biome boundaries from JSON into memory."""
    global _biome_polygons
    
    data = _load_biome_data_from_json()
    if not data:
        logger.warning("No biome data loaded – biome lookup disabled")
        return
    
    _biome_polygons = []
    loaded_count = 0
    
    for bname in BIOME_ORDER:
        if bname not in data:
            logger.debug("Biome '%s' not found in data", bname)
            continue
        
        # Each entry in data[bname] is a geometry (list of rings)
        # Each ring is a list of [lon, lat] coordinate pairs
        for geom in data[bname]:
            # Convert list-of-lists to list-of-tuples for faster lookups
            rings = []
            for ring in geom:
                ring_tuples = [(float(lon), float(lat)) for lon, lat in ring]
                rings.append(ring_tuples)
            
            _biome_polygons.append((bname, rings))
            loaded_count += 1
    
    logger.info("Loaded %d biome polygon(s) for %d biome(s)", 
                loaded_count, len(set(b for b, _ in _biome_polygons)))


def classify_point(lat: float, lon: float) -> str | None:
    """Return biome name for a given lat/lon, or None if not in any biome."""
    for bname, geom in _biome_polygons:
        if _point_in_polygon(lon, lat, geom):
            return bname
    return None


def classify_fires(fires: list[dict]) -> list[dict]:
    """Classify a list of fire points by biome.

    Returns a list of dicts with counts per biome:
    [{"name": "Amazônia", "count": 1234, "pct": 45.2, "color": "..."}, ...]
    """
    if not _biome_polygons:
        # Return empty counts for all biomes
        return [
            {
                "name": bname,
                "count": 0,
                "pct": 0,
                "color": BIOME_COLORS.get(bname, "linear-gradient(90deg,#888,#aaa)"),
            }
            for bname in BIOME_ORDER
        ]

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
        if total > 0:
            pct = round(c / total * 100, 1)
        else:
            pct = 0
        result.append({
            "name": bname,
            "count": c,
            "pct": pct,
            "color": BIOME_COLORS.get(bname, "linear-gradient(90deg,#888,#aaa)"),
        })

    return result

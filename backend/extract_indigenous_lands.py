"""
Convert FUNAI tis_poligonais shapefile to indigenous_lands.json.

Usage:
    python extract_indigenous_lands.py [path/to/tis_poligonais.shp]

Default shapefile path: data/tis_poligonais.shp
Output:             indigenous_lands.json
"""
import json
import math
import sys
import os

try:
    import shapefile
except ImportError:
    sys.exit("Install pyshp first:  python -m pip install pyshp")


TOLERANCE = 0.02   # ~2km — keeps shape fidelity while reducing point count
PRECISION = 4      # decimal places (~11m)


def _perp_distance(point, start, end):
    """Perpendicular distance from point to line segment (start→end)."""
    x0, y0 = point
    x1, y1 = start
    x2, y2 = end
    dx, dy = x2 - x1, y2 - y1
    if dx == 0 and dy == 0:
        return math.hypot(x0 - x1, y0 - y1)
    t = ((x0 - x1) * dx + (y0 - y1) * dy) / (dx * dx + dy * dy)
    t = max(0.0, min(1.0, t))
    return math.hypot(x0 - (x1 + t * dx), y0 - (y1 + t * dy))


def douglas_peucker(points, tolerance):
    """Ramer–Douglas–Peucker simplification (list of (x, y) tuples)."""
    if len(points) < 3:
        return points
    max_dist = 0.0
    index = 0
    for i in range(1, len(points) - 1):
        d = _perp_distance(points[i], points[0], points[-1])
        if d > max_dist:
            max_dist, index = d, i
    if max_dist > tolerance:
        left = douglas_peucker(points[:index + 1], tolerance)
        right = douglas_peucker(points[index:], tolerance)
        return left[:-1] + right
    return [points[0], points[-1]]


def shape_to_rings(shape, tolerance=TOLERANCE):
    """Convert a pyshp shape to a list of rings [[lon, lat], ...]."""
    pts = shape.points
    parts = list(shape.parts) + [len(pts)]
    rings = []
    for i in range(len(parts) - 1):
        ring_pts = pts[parts[i]:parts[i + 1]]
        simplified = douglas_peucker(list(ring_pts), tolerance)
        if len(simplified) < 4:
            continue
        rings.append([[round(x, PRECISION), round(y, PRECISION)] for x, y in simplified])
    return rings


STATE_NAMES = {
    "AC": "Acre", "AL": "Alagoas", "AM": "Amazonas", "AP": "Amapá",
    "BA": "Bahia", "CE": "Ceará", "DF": "Distrito Federal", "ES": "Espírito Santo",
    "GO": "Goiás", "MA": "Maranhão", "MG": "Minas Gerais", "MS": "Mato Grosso do Sul",
    "MT": "Mato Grosso", "PA": "Pará", "PB": "Paraíba", "PE": "Pernambuco",
    "PI": "Piauí", "PR": "Paraná", "RJ": "Rio de Janeiro", "RN": "Rio Grande do Norte",
    "RO": "Rondônia", "RR": "Roraima", "RS": "Rio Grande do Sul", "SC": "Santa Catarina",
    "SE": "Sergipe", "SP": "São Paulo", "TO": "Tocantins",
}


def extract(shp_path, out_path):
    sf = shapefile.Reader(shp_path, encoding="latin1")
    result = {}
    skipped = 0

    for shape_rec in sf.iterShapeRecords():
        rec = shape_rec.record
        name = rec["terrai_nom"].strip()
        state_abbr = rec["uf_sigla"].strip()
        municipality = rec["municipio_"].strip()

        if not name:
            skipped += 1
            continue

        rings = shape_to_rings(shape_rec.shape)
        if not rings:
            skipped += 1
            continue

        state_name = STATE_NAMES.get(state_abbr, state_abbr)

        if name in result:
            result[name]["rings"].extend(rings)
        else:
            result[name] = {
                "rings": rings,
                "state_abbr": state_abbr,
                "state_name": state_name,
                "municipality": municipality,
            }

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, separators=(",", ":"))

    total_pts = sum(
        sum(len(r) for r in v["rings"]) for v in result.values()
    )
    print(f"Wrote {len(result)} TIs ({skipped} skipped) to {out_path}")
    print(f"Total polygon points: {total_pts:,}")


if __name__ == "__main__":
    shp = sys.argv[1] if len(sys.argv) > 1 else os.path.join("data", "tis_poligonais.shp")
    out = sys.argv[2] if len(sys.argv) > 2 else "indigenous_lands.json"
    extract(shp, out)

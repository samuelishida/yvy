"""
Convert ICMBio limite_ucs_federais shapefile to conservation_units.json.

Usage:
    python extract_conservation_units.py [path/to/shp] [output.json]

Default shapefile: data/icmbio/limite_ucs_federais_032026_a2.shp
Output:           conservation_units.json
"""
import json
import math
import os
import sys

try:
    import shapefile
except ImportError:
    sys.exit("Install pyshp first:  python -m pip install pyshp")


TOLERANCE = 0.03   # ~3km — UCs tend to be larger than TIs
PRECISION = 4


def _perp_distance(point, start, end):
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

CATEGORY_EN = {
    "PARNA": "National Park",
    "REBIO": "Biological Reserve",
    "ESEC": "Ecological Station",
    "FLONA": "National Forest",
    "RESEX": "Extractive Reserve",
    "RDS":   "Sustainable Dev. Reserve",
    "APA":   "Environmental Protection Area",
    "ARIE":  "Relevant Ecological Interest Area",
    "MONA":  "Natural Monument",
    "REVIS": "Wildlife Refuge",
    "RPPN":  "Private Natural Heritage Reserve",
}


def _primary_state(uf_str):
    """Extract first state from strings like 'PA/AP' or 'AM'."""
    if not uf_str:
        return ""
    return uf_str.strip().split("/")[0].split(",")[0].strip()[:2]


def _short_name(full_name, category):
    """Strip redundant category prefix from the full UC name."""
    full = full_name.strip().upper()
    cat = category.strip().upper()
    # Common long prefixes to strip
    for prefix in [
        f"PARQUE NACIONAL", "RESERVA BIOLÓGICA", "ESTAÇÃO ECOLÓGICA",
        "FLORESTA NACIONAL", "RESERVA EXTRATIVISTA", "RESERVA DE DESENVOLVIMENTO SUSTENTÁVEL",
        "ÁREA DE PROTEÇÃO AMBIENTAL", "ÁREA DE RELEVANTE INTERESSE ECOLÓGICO",
        "MONUMENTO NATURAL", "REFÚGIO DE VIDA SILVESTRE", "RESERVA PARTICULAR DO PATRIMÔNIO NATURAL",
    ]:
        if full.startswith(prefix):
            remainder = full[len(prefix):].strip(" DO DA DE DOS DAS ").strip()
            return remainder.title() if remainder else full_name.strip()
    return full_name.strip()


def extract(shp_path, out_path):
    sf = shapefile.Reader(shp_path, encoding="UTF-8")
    result = {}
    skipped = 0

    for shape_rec in sf.iterShapeRecords():
        rec = shape_rec.record
        full_name = rec["nomeuc"].strip()
        category = rec["siglacateg"].strip()
        group = rec["grupouc"].strip()      # PI (Proteção Integral) or US (Uso Sustentável)
        uf_raw = rec["ufabrang"].strip()

        if not full_name:
            skipped += 1
            continue

        rings = shape_to_rings(shape_rec.shape)
        if not rings:
            skipped += 1
            continue

        state_abbr = _primary_state(uf_raw)
        state_name = STATE_NAMES.get(state_abbr, state_abbr)
        short = _short_name(full_name, category)

        key = f"{category} {short}" if short and short.upper() not in full_name.upper()[:len(short) + 5] else full_name.strip()

        if key in result:
            result[key]["rings"].extend(rings)
        else:
            result[key] = {
                "rings": rings,
                "full_name": full_name,
                "category": category,
                "group": group,
                "state_abbr": state_abbr,
                "state_name": state_name,
                "states": uf_raw,
            }

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, separators=(",", ":"))

    total_pts = sum(sum(len(r) for r in v["rings"]) for v in result.values())
    print(f"Wrote {len(result)} UCs ({skipped} skipped) to {out_path}")
    print(f"Total polygon points: {total_pts:,}")


if __name__ == "__main__":
    default_shp = os.path.join("data", "icmbio", "limite_ucs_federais_032026_a2.shp")
    shp = sys.argv[1] if len(sys.argv) > 1 else default_shp
    out = sys.argv[2] if len(sys.argv) > 2 else "conservation_units.json"
    extract(shp, out)

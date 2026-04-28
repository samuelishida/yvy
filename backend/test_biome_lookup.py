"""Unit tests for biome_lookup.py."""
import pytest

import biome_lookup


# ── Test point-in-polygon (pure logic, no I/O) ──────────────────────────

class TestPointInRing:
    """Test the ray-casting point-in-ring algorithm."""

    def test_point_inside_square(self):
        ring = [(0, 0), (10, 0), (10, 10), (0, 10), (0, 0)]
        assert biome_lookup._point_in_ring(5, 5, ring) is True

    def test_point_outside_square(self):
        ring = [(0, 0), (10, 0), (10, 10), (0, 10), (0, 0)]
        assert biome_lookup._point_in_ring(15, 15, ring) is False

    def test_point_on_edge(self):
        ring = [(0, 0), (10, 0), (10, 10), (0, 10), (0, 0)]
        result = biome_lookup._point_in_ring(5, 0, ring)
        assert isinstance(result, bool)

    def test_point_in_triangle(self):
        ring = [(0, 0), (10, 0), (5, 10), (0, 0)]
        assert biome_lookup._point_in_ring(5, 3, ring) is True
        assert biome_lookup._point_in_ring(15, 5, ring) is False


class TestPointInPolygon:
    """Test point-in-polygon with holes."""

    def test_no_holes(self):
        exterior = [(0, 0), (10, 0), (10, 10), (0, 10), (0, 0)]
        assert biome_lookup._point_in_polygon(5, 5, [exterior]) is True

    def test_with_hole(self):
        exterior = [(0, 0), (10, 0), (10, 10), (0, 10), (0, 0)]
        hole = [(3, 3), (7, 3), (7, 7), (3, 7), (3, 3)]
        assert biome_lookup._point_in_polygon(5, 5, [exterior, hole]) is False
        assert biome_lookup._point_in_polygon(1, 1, [exterior, hole]) is True

    def test_empty_rings(self):
        assert biome_lookup._point_in_polygon(5, 5, []) is False


class TestClassifyPoint:
    """Test biome classification with in-memory polygons."""

    def test_no_polygons_loaded(self):
        biome_lookup._biome_polygons = []
        assert biome_lookup.classify_point(0, 0) is None

    def test_with_loaded_polygons(self):
        amazon = [(-70, -10), (-50, -10), (-50, 0), (-70, 0), (-70, -10)]
        cerrado = [(-55, -25), (-45, -25), (-45, -15), (-55, -15), (-55, -25)]
        biome_lookup._biome_polygons = [
            ("Amazônia", [amazon]),
            ("Cerrado", [cerrado]),
        ]
        assert biome_lookup.classify_point(-5, -60) == "Amazônia"
        assert biome_lookup.classify_point(-20, -50) == "Cerrado"
        assert biome_lookup.classify_point(50, 100) is None


class TestClassifyFires:
    """Test fire classification by biome."""

    def test_classify_fires_empty(self):
        biome_lookup._biome_polygons = []
        result = biome_lookup.classify_fires([])
        # Should return entry for all 6 biomes with 0 counts
        assert len(result) == 6
        assert all(b["count"] == 0 for b in result)

    def test_classify_fires_with_data(self):
        amazon = [(-70, -10), (-50, -10), (-50, 0), (-70, 0), (-70, -10)]
        cerrado = [(-55, -25), (-45, -25), (-45, -15), (-55, -15), (-55, -25)]
        biome_lookup._biome_polygons = [
            ("Amazônia", [amazon]),
            ("Cerrado", [cerrado]),
        ]
        fires = [
            {"lat": -5, "lon": -60},   # Amazônia
            {"lat": -5, "lon": -60},   # Amazônia
            {"lat": -20, "lon": -50},  # Cerrado
            {"lat": 50, "lon": 100},   # outside
        ]
        result = biome_lookup.classify_fires(fires)
        assert len(result) == 6  # all 6 biomes in BIOME_ORDER
        am = next(r for r in result if r["name"] == "Amazônia")
        ce = next(r for r in result if r["name"] == "Cerrado")
        assert am["count"] == 2
        assert ce["count"] == 1
        assert am["pct"] == pytest.approx(66.7, abs=0.1)
        assert ce["pct"] == pytest.approx(33.3, abs=0.1)

    def test_classify_fires_missing_coords(self):
        biome_lookup._biome_polygons = [
            ("Amazônia", [[(-70, -10), (-50, -10), (-50, 0), (-70, 0), (-70, -10)]]),
        ]
        fires = [
            {"lat": -5, "lon": -60},
            {"lat": None, "lon": -60},
            {"lat": -5},
        ]
        result = biome_lookup.classify_fires(fires)
        am = next(r for r in result if r["name"] == "Amazônia")
        assert am["count"] == 1


class TestLoadBiomes:
    """Test JSON-based biome loading."""

    def test_load_biomes_from_json(self):
        """Load biomes from the JSON data file."""
        biome_lookup._biome_polygons = []
        biome_lookup.load_biomes()
        assert len(biome_lookup._biome_polygons) > 0
        names = set(n for n, _ in biome_lookup._biome_polygons)
        assert "Amazônia" in names
        assert "Cerrado" in names
        assert "Pantanal" in names
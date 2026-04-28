"""Shared point-in-polygon utilities (ray-casting algorithm)."""
from __future__ import annotations


def point_in_ring(px: float, py: float, ring: list) -> bool:
    n = len(ring)
    inside = False
    j = n - 1
    for i in range(n):
        xi, yi = ring[i][0], ring[i][1]
        xj, yj = ring[j][0], ring[j][1]
        if ((yi > py) != (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi):
            inside = not inside
        j = i
    return inside


def point_in_polygon(px: float, py: float, rings: list) -> bool:
    """First ring = exterior, remaining = holes."""
    if not rings:
        return False
    if not point_in_ring(px, py, rings[0]):
        return False
    for hole in rings[1:]:
        if point_in_ring(px, py, hole):
            return False
    return True

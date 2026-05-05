-- geo.lua — Point-in-polygon utilities (ray-casting algorithm)
-- Port of backend/_geo.py

local _M = {}

function _M.point_in_ring(px, py, ring)
    """Return true if point (px, py) is inside a polygon ring.
    ring: array of {lon, lat} pairs, e.g. {{-50, -10}, {-51, -11}, ...}
    Uses the ray-casting (even-odd rule) algorithm.
    """
    local n = #ring
    if n < 3 then return false end

    local inside = false
    local j = n
    for i = 1, n do
        local xi, yi = ring[i][1], ring[i][2]
        local xj, yj = ring[j][1], ring[j][2]

        if ((yi > py) ~= (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi) then
            inside = not inside
        end
        j = i
    end
    return inside
end

function _M.point_in_polygon(px, py, rings)
    """Return true if point is inside a polygon (first ring = exterior, rest = holes).
    rings: array of rings, each ring is {{lon, lat}, ...}
    """
    if not rings or #rings == 0 then
        return false
    end

    -- Must be inside exterior ring
    if not _M.point_in_ring(px, py, rings[1]) then
        return false
    end

    -- Must NOT be inside any hole
    for i = 2, #rings do
        if _M.point_in_ring(px, py, rings[i]) then
            return false
        end
    end

    return true
end

return _M

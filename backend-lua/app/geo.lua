local _M = {}

function _M.point_in_ring(px, py, ring)
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
    if not rings or #rings == 0 then
        return false
    end

    if not _M.point_in_ring(px, py, rings[1]) then
        return false
    end

    for i = 2, #rings do
        if _M.point_in_ring(px, py, rings[i]) then
            return false
        end
    end

    return true
end

return _M

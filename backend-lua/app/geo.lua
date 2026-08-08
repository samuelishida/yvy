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

-- Quantos dos 4 cantos do bbox {min_lon, min_lat, max_lon, max_lat} caem dentro
-- do polígono (rings). Usado pelo scan DETER×UC/TI para detectar cortes grandes
-- que cruzam a borda de uma área protegida irregular (o teste de centroide
-- sozinho os perde quando o centro cai num entalhe/concavidade).
function _M.bbox_corner_hits(rings, bbox)
    if not rings or not bbox then return 0 end
    local corners = {
        { bbox.min_lon, bbox.min_lat },
        { bbox.max_lon, bbox.min_lat },
        { bbox.min_lon, bbox.max_lat },
        { bbox.max_lon, bbox.max_lat },
    }
    local hits = 0
    for _, c in ipairs(corners) do
        if _M.point_in_polygon(c[1], c[2], rings) then hits = hits + 1 end
    end
    return hits
end

return _M

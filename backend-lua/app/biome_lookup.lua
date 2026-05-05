-- biome_lookup.lua — Biome point-in-polygon lookup
-- Port of backend/biome_lookup.py
-- Loads biome_data.json at init time

local geo   = require("app.geo")
local cjson = require("cjson")

local _M = {}

local BIOME_ORDER = {"Amazônia", "Cerrado", "Caatinga", "Mata Atlântica", "Pantanal", "Pampa"}

local BIOME_COLORS = {
    ["Amazônia"]       = "linear-gradient(90deg,#ef4444,#f97316)",
    ["Cerrado"]        = "linear-gradient(90deg,#fb923c,#fbbf24)",
    ["Caatinga"]       = "linear-gradient(90deg,#fbbf24,#facc15)",
    ["Mata Atlântica"] = "linear-gradient(90deg,#a78bfa,#c4b5fd)",
    ["Pantanal"]       = "linear-gradient(90deg,#2dd4ff,#67e8f9)",
    ["Pampa"]          = "linear-gradient(90deg,#4ade80,#86efac)",
}

-- Flat list of {name, ring} — each ring is {{lon, lat}, ...}
local biome_rings = {}
local biome_colors = {}

function _M.load_biomes()
    local data_file = os.getenv("BIOME_DATA_PATH") or "/opt/yvy/backend-lua/data/biome_data.json"

    -- Try multiple paths
    local paths = {
        data_file,
        "/opt/yvy/backend-lua/data/biome_data.json",
        "/opt/yvy/data/biome_data.json",
        "data/biome_data.json",
    }

    local data = nil
    for _, p in ipairs(paths) do
        local f = io.open(p, "r")
        if f then
            data = f:read("*a")
            f:close()
            break
        end
    end

    if not data then
        ngx.log(ngx.WARN, "biome_data.json not found — biome lookup disabled")
        return
    end

    local ok, parsed = pcall(cjson.decode, data)
    if not ok then
        ngx.log(ngx.WARN, "Failed to parse biome_data.json")
        return
    end

    biome_rings = {}
    biome_colors = {}

    for _, name in ipairs(BIOME_ORDER) do
        local biome = parsed[name]
        if biome then
            local color = biome.color or BIOME_COLORS[name] or ""
            biome_colors[name] = color
            local rings = biome.rings
            if rings then
                for _, ring in ipairs(rings) do
                    biome_rings[#biome_rings + 1] = {name = name, ring = ring}
                end
            end
        end
    end

    ngx.log(ngx.INFO, "Loaded ", #biome_rings, " biome rings for ", #biome_colors, " biomes")
end

function _M.classify_point(lat, lon)
    for _, entry in ipairs(biome_rings) do
        if geo.point_in_ring(lon, lat, entry.ring) then
            return entry.name
        end
    end
    return nil
end

function _M.classify_fires(fires)
    if #biome_rings == 0 then
        return {}
    end

    local counts = {}
    for _, b in ipairs(BIOME_ORDER) do
        counts[b] = 0
    end

    local total = 0
    for _, fire in ipairs(fires) do
        local lat = tonumber(fire.lat)
        local lon = tonumber(fire.lon)
        if lat and lon then
            local biome = _M.classify_point(lat, lon)
            if biome and counts[biome] then
                counts[biome] = counts[biome] + 1
                total = total + 1
            end
        end
    end

    local result = {}
    for _, bname in ipairs(BIOME_ORDER) do
        local c = counts[bname]
        local pct = 0
        if total > 0 then
            pct = math.floor(c / total * 1000 + 0.5) / 10  -- round to 1 decimal
        end
        result[#result + 1] = {
            name = bname,
            count = c,
            pct = pct,
            color = biome_colors[bname] or BIOME_COLORS[bname] or "",
        }
    end
    return result
end

return _M

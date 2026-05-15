-- biome_lookup.lua — Biome point-in-polygon lookup
-- Port of backend/biome_lookup.py
-- Loads from DB (JSONB) first; ingests from biome_data.json if missing

local env    = require("app.env")
local db     = require("app.db")
local geo    = require("app.geo")
local cjson  = require("cjson")
local logger = require("app.logger")

local _M = {}

local LOOKUP_KEY = "biome_data"

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

local function _build_from_parsed(parsed)
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
end

function _M.load_biomes()
    -- Try DB first
    local cached = db.get_lookup_data(LOOKUP_KEY)
    if cached then
        _build_from_parsed(cached)
        logger.info("Loaded ", #biome_rings, " biome rings from DB for ", #biome_colors, " biomes")
        return
    end

    -- Fallback: ingest from JSON file
    local data_file = env.get("BIOME_DATA_PATH") or "/opt/yvy/backend-lua/data/biome_data.json"
    local paths = {
        data_file,
        "/opt/yvy/backend-lua/data/biome_data.json",
        "/opt/yvy/data/biome_data.json",
        "data/biome_data.json",
        "../backend/biome_data.json",
    }

    local resolved = env.first_existing(paths)
    local data = nil
    if resolved then
        local f = io.open(resolved, "r")
        if f then
            data = f:read("*a")
            f:close()
        end
    end

    if not data then
        logger.warn("biome_data.json not found — biome lookup disabled")
        return
    end

    local ok, parsed = pcall(cjson.decode, data)
    if not ok then
        logger.warn("Failed to parse biome_data.json")
        return
    end

    _build_from_parsed(parsed)

    -- Persist to DB as JSONB
    db.set_lookup_data(LOOKUP_KEY, parsed)
    logger.info("Loaded ", #biome_rings, " biome rings from file for ", #biome_colors, " biomes (saved to DB)")
end

function _M.classify_point(lon, lat)
    for _, entry in ipairs(biome_rings) do
        if geo.point_in_ring(lon, lat, entry.ring) then
            return entry.name
        end
    end
    return nil
end

function _M.get_geojson()
    if #biome_rings == 0 then
        return { type = "FeatureCollection", features = {} }
    end
    local features = {}
    for _, entry in ipairs(biome_rings) do
        features[#features + 1] = {
            type = "Feature",
            properties = { name = entry.name },
            geometry = { type = "Polygon", coordinates = { entry.ring } }
        }
    end
    return { type = "FeatureCollection", features = features }
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
            local biome = _M.classify_point(lon, lat)
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

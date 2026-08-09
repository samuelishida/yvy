-- conservation_units_lookup.lua — UC ICMBio point-in-polygon lookup
-- Port of backend/conservation_units_lookup.py
-- Loads from DB (JSONB) first; ingests from conservation_units.json if missing

local env    = require("app.env")
local db     = require("app.db")
local geo    = require("app.geo")
local cjson  = require("cjson")
local logger = require("app.logger")

local _M = {}

local LOOKUP_KEY = "conservation_units"

local units = {}

-- Bounding box do anel externo — prefilter barato antes do ray-cast caro.
-- Mesma convenção da TI (indigenous_lands_lookup): {min_lon, min_lat, max_lon,
-- max_lat} (lon-first). Um swap lat/lon aqui quebra o overlap CAR×UC/TI e o
-- scan DETER em silêncio.
local function compute_bounds(rings)
    local outer = rings and rings[1]
    if not outer or #outer == 0 then
        return { -180, -90, 180, 90 }
    end
    local min_lon, min_lat, max_lon, max_lat = math.huge, math.huge, -math.huge, -math.huge
    for _, pt in ipairs(outer) do
        local lon, lat = pt[1], pt[2]
        if lon < min_lon then min_lon = lon end
        if lon > max_lon then max_lon = lon end
        if lat < min_lat then min_lat = lat end
        if lat > max_lat then max_lat = lat end
    end
    return { min_lon, min_lat, max_lon, max_lat }
end

local function _build_from_parsed(parsed)
    units = {}
    for name, meta in pairs(parsed) do
        if name ~= "_updated_at" and type(meta) == "table" then
            local rings = meta.rings
            local clean_meta = {}
            for k, v in pairs(meta) do
                if k ~= "rings" then
                    clean_meta[k] = v
                end
            end
            units[#units + 1] = {name = name, meta = clean_meta, rings = rings, bounds = compute_bounds(rings)}
        end
    end
end

function _M.load_conservation_units()
    -- Try DB first
    local cached = db.get_lookup_data(LOOKUP_KEY)
    if cached then
        _build_from_parsed(cached)
        logger.info("Loaded ", #units, " conservation unit polygons from DB")
        return
    end

    -- Fallback: ingest from JSON file
    local paths = {
        env.get("CONSERVATION_UNITS_PATH") or "",
        "/opt/yvy/backend-lua/data/conservation_units.json",
        "/opt/yvy/data/conservation_units.json",
        "data/conservation_units.json",
        "../backend/conservation_units.json",
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
        logger.warn("conservation_units.json not found — UC lookup disabled")
        return
    end

    local ok, parsed = pcall(cjson.decode, data)
    if not ok then
        logger.warn("Failed to parse conservation_units.json")
        return
    end

    _build_from_parsed(parsed)

    -- Persist to DB as JSONB
    db.set_lookup_data(LOOKUP_KEY, parsed)
    logger.info("Loaded ", #units, " conservation unit polygons from file (saved to DB)")
end

function _M.count() return #units end
function _M.units() return units end

function _M.classify_point(lon, lat)
    for _, entry in ipairs(units) do
        -- Bbox-reject barato antes do ray-cast (mesmo padrão da TI)
        local b = entry.bounds
        if lon >= b[1] and lon <= b[3] and lat >= b[2] and lat <= b[4]
           and geo.point_in_polygon(lon, lat, entry.rings) then
            local result = {name = entry.name}
            for k, v in pairs(entry.meta) do
                result[k] = v
            end
            return result
        end
    end
    return nil
end

-- Candidatos cujo bounds sobrepõe a caixa (lon-first: min_lon, min_lat, max_lon,
-- max_lat). Usado pelo overlap CAR×UC/TI (routes/car.lua) e pelo scan DETER
-- (tools/deter_protected_alerts.lua). O bbox do CAR é superconjunto do polígono,
-- então nenhuma UC sobreposta ao imóvel pode escapar da seleção.
function _M.candidates_in_bbox(min_lon, min_lat, max_lon, max_lat)
    local result = {}
    for _, entry in ipairs(units) do
        local b = entry.bounds
        if b[1] <= max_lon and b[3] >= min_lon and b[2] <= max_lat and b[4] >= min_lat then
            result[#result + 1] = {
                name = entry.name,
                category = entry.meta.category,
                full_name = entry.meta.full_name,
                rings = entry.rings,
                bounds = b,
            }
        end
    end
    return result
end

return _M

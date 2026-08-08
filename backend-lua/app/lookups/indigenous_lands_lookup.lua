-- indigenous_lands_lookup.lua — TI point-in-polygon lookup
-- Port of backend/indigenous_lands_lookup.py
-- Loads from DB (JSONB) first; ingests from indigenous_lands.json if missing

local env    = require("app.env")
local db     = require("app.db")
local geo    = require("app.geo")
local cjson  = require("cjson")
local logger = require("app.logger")

local _M = {}

local LOOKUP_KEY = "indigenous_lands"

-- List of {name, meta, rings, bounds}
local lands = {}

-- Bounding box of the outer ring, used as a cheap reject before the expensive
-- point-in-polygon ray-cast. rings[1] is the outer ring (see geo.point_in_polygon).
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
    lands = {}
    for name, meta in pairs(parsed) do
        if name ~= "_updated_at" and type(meta) == "table" then
            local rings = meta.rings
            local clean_meta = {}
            for k, v in pairs(meta) do
                if k ~= "rings" then
                    clean_meta[k] = v
                end
            end
            lands[#lands + 1] = {name = name, meta = clean_meta, rings = rings, bounds = compute_bounds(rings)}
        end
    end
end

function _M.load_indigenous_lands()
    -- Try DB first
    local cached = db.get_lookup_data(LOOKUP_KEY)
    if cached then
        _build_from_parsed(cached)
        logger.info("Loaded ", #lands, " indigenous land polygons from DB")
        return
    end

    -- Fallback: ingest from JSON file
    local paths = {
        env.get("INDIGENOUS_LANDS_PATH") or "",
        "/opt/yvy/backend-lua/data/indigenous_lands.json",
        "/opt/yvy/data/indigenous_lands.json",
        "data/indigenous_lands.json",
        "../backend/indigenous_lands.json",
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
        logger.warn("indigenous_lands.json not found — TI lookup disabled")
        return
    end

    local ok, parsed = pcall(cjson.decode, data)
    if not ok then
        logger.warn("Failed to parse indigenous_lands.json")
        return
    end

    _build_from_parsed(parsed)

    -- Persist to DB as JSONB
    db.set_lookup_data(LOOKUP_KEY, parsed)
    logger.info("Loaded ", #lands, " indigenous land polygons from file (saved to DB)")
end

function _M.count() return #lands end

function _M.classify_point(lon, lat)
    for _, entry in ipairs(lands) do
        -- Cheap bounding-box reject first: most fire points are nowhere near
        -- any TI polygon, so skip the ray-cast for them entirely.
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

-- Candidatos cujo bounds sobrepõe a caixa (lon-first). Mesmo uso da UC:
-- overlap CAR×TI (routes/car.lua) e scan DETER (tools/deter_protected_alerts.lua).
function _M.candidates_in_bbox(min_lon, min_lat, max_lon, max_lat)
    local result = {}
    for _, entry in ipairs(lands) do
        local b = entry.bounds
        if b[1] <= max_lon and b[3] >= min_lon and b[2] <= max_lat and b[4] >= min_lat then
            result[#result + 1] = { name = entry.name, rings = entry.rings, bounds = b }
        end
    end
    return result
end

return _M

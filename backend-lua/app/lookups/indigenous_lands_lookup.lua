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

-- List of {name, meta, rings}
local lands = {}

local function _build_from_parsed(parsed)
    lands = {}
    for name, meta in pairs(parsed) do
        local rings = meta.rings
        local clean_meta = {}
        for k, v in pairs(meta) do
            if k ~= "rings" then
                clean_meta[k] = v
            end
        end
        lands[#lands + 1] = {name = name, meta = clean_meta, rings = rings}
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

function _M.classify_point(lon, lat)
    for _, entry in ipairs(lands) do
        if geo.point_in_polygon(lon, lat, entry.rings) then
            local result = {name = entry.name}
            for k, v in pairs(entry.meta) do
                result[k] = v
            end
            return result
        end
    end
    return nil
end

return _M

-- conservation_units_lookup.lua — UC ICMBio point-in-polygon lookup
-- Port of backend/conservation_units_lookup.py

local env    = require("app.env")
local geo    = require("app.geo")
local cjson  = require("cjson")
local logger = require("app.logger")

local _M = {}

local units = {}

function _M.load_conservation_units()
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

    units = {}
    for name, meta in pairs(parsed) do
        local rings = meta.rings
        local clean_meta = {}
        for k, v in pairs(meta) do
            if k ~= "rings" then
                clean_meta[k] = v
            end
        end
        units[#units + 1] = {name = name, meta = clean_meta, rings = rings}
    end

    logger.info("Loaded ", #units, " conservation unit polygons")
end

function _M.classify_point(lon, lat)
    for _, entry in ipairs(units) do
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

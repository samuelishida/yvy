-- indigenous_lands_lookup.lua — TI point-in-polygon lookup
-- Port of backend/indigenous_lands_lookup.py

local geo   = require("app.geo")
local cjson = require("cjson")

local _M = {}

-- List of {name, meta, rings}
local lands = {}

function _M.load_indigenous_lands()
    local paths = {
        os.getenv("INDIGENOUS_LANDS_PATH") or "",
        "/opt/yvy/backend-lua/data/indigenous_lands.json",
        "/opt/yvy/data/indigenous_lands.json",
        "data/indigenous_lands.json",
    }

    local data = nil
    for _, p in ipairs(paths) do
        if p ~= "" then
            local f = io.open(p, "r")
            if f then
                data = f:read("*a")
                f:close()
                break
            end
        end
    end

    if not data then
        ngx.log(ngx.WARN, "indigenous_lands.json not found — TI lookup disabled")
        return
    end

    local ok, parsed = pcall(cjson.decode, data)
    if not ok then
        ngx.log(ngx.WARN, "Failed to parse indigenous_lands.json")
        return
    end

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

    ngx.log(ngx.INFO, "Loaded ", #lands, " indigenous land polygons")
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

-- deforestation.lua — /api/data
-- Baremetal Lua version

local db    = require("app.db")
local auth  = require("app.auth")
local rl    = require("app.rate_limit")
local redis = require("app.redis")
local cjson = require("cjson")

local _M = {}

local BRAZIL_BOUNDS = {min_lat = -34.0, max_lat = 5.5, min_lon = -74.0, max_lon = -34.0}
local MAX_RESULTS = tonumber(os.getenv("MAX_RESULTS_PER_REQUEST") or "10000")

local function clamp_bbox_to_brazil(ne_lat, ne_lng, sw_lat, sw_lng)
    local c_ne_lat = math.min(ne_lat, BRAZIL_BOUNDS.max_lat)
    local c_ne_lng = math.min(ne_lng, BRAZIL_BOUNDS.max_lon)
    local c_sw_lat = math.max(sw_lat, BRAZIL_BOUNDS.min_lat)
    local c_sw_lng = math.max(sw_lng, BRAZIL_BOUNDS.min_lon)
    if c_ne_lat <= c_sw_lat or c_ne_lng <= c_sw_lng then return nil end
    return c_ne_lat, c_ne_lng, c_sw_lat, c_sw_lng
end

function _M.get_data(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local args = ctx.req.args
    local ne_lat = args.ne_lat; local ne_lng = args.ne_lng
    local sw_lat = args.sw_lat; local sw_lng = args.sw_lng

    if ne_lat and ne_lng and sw_lat and sw_lng then
        ne_lat = tonumber(ne_lat); ne_lng = tonumber(ne_lng)
        sw_lat = tonumber(sw_lat); sw_lng = tonumber(sw_lng)
        if not ne_lat or not ne_lng or not sw_lat or not sw_lng then
            ctx:error(400, "Invalid coordinates."); return
        end
        if ne_lat <= sw_lat or ne_lng <= sw_lng then
            ctx:error(400, "Invalid bbox."); return
        end
        local clamped = clamp_bbox_to_brazil(ne_lat, ne_lng, sw_lat, sw_lng)
        if not clamped then ctx:send(200, "[]"); return end
        ne_lat, ne_lng, sw_lat, sw_lng = clamped[1], clamped[2], clamped[3], clamped[4]
    else
        sw_lat, ne_lat, sw_lng, ne_lng = -90, 90, -180, 180
    end

    local cache_key = string.format("data:%.1f:%.1f:%.1f:%.1f", sw_lat, ne_lat, sw_lng, ne_lng)
    local cached = redis.get(cache_key)
    if cached then ctx:send(200, cached); return end

    local data = db.find_deforestation(sw_lat, ne_lat, sw_lng, ne_lng, MAX_RESULTS)
    local records = {}
    for _, item in ipairs(data) do
        records[#records + 1] = {
            name = item.name, lat = item.lat, lon = item.lon, color = item.color,
            clazz = item.clazz or "Desmatamento", periods = item.periods or "N/A",
            source = item.source or "TerraBrasilis", timestamp = item.timestamp or "",
        }
    end

    local body = cjson.encode(records)
    redis.set(cache_key, body, 900)
    ctx:send(200, body)
end

return _M


-- deforestation_stats.lua — /api/deforestation/historical
-- Serves INPE PRODES annual Amazônia Legal totals from a static JSON.

local env    = require("app.env")
local auth   = require("app.middleware.auth")
local rl     = require("app.middleware.rate_limit")
local redis  = require("app.redis")
local logger = require("app.logger")

local _M = {}

local CACHE_KEY = "deforestation:historical"
local CACHE_TTL = 86400  -- 24h

local _cached_body
local _cached_etag

local function djb2_hex(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + string.byte(s, i)) % 4294967296
    end
    return string.format("%08x", h)
end

local function load_body()
    if _cached_body then return _cached_body, _cached_etag end

    local cached = redis.get(CACHE_KEY)
    if cached then
        _cached_body = cached
        _cached_etag = '"' .. djb2_hex(cached) .. '"'
        return _cached_body, _cached_etag
    end

    local paths = {
        "backend-lua/data/prodes_historical.json",
        "data/prodes_historical.json",
        "/opt/yvy/backend-lua/data/prodes_historical.json",
        "../backend-lua/data/prodes_historical.json",
    }
    local override = env.get("PRODES_HISTORICAL_PATH")
    if override and override ~= "" then table.insert(paths, 1, override) end
    local resolved = env.first_existing(paths)
    if not resolved then
        logger.warn("prodes_historical.json not found")
        return nil, nil
    end

    local f = io.open(resolved, "r")
    if not f then return nil, nil end
    local body = f:read("*a")
    f:close()

    _cached_body = body
    _cached_etag = '"' .. djb2_hex(body) .. '"'
    redis.set(CACHE_KEY, body, CACHE_TTL)
    return _cached_body, _cached_etag
end

function _M.get_historical(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local body, etag = load_body()
    if not body then
        ctx:json(503, {error = "PRODES historical data unavailable"})
        return
    end

    ctx:set_header("Cache-Control", "public, max-age=3600")
    ctx:set_header("ETag", etag)
    local inm = ctx.req.headers and ctx.req.headers["if-none-match"]
    if inm and inm == etag then
        ctx:send(304, "")
        return
    end
    ctx:send(200, body)
end

return _M

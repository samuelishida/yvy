#!/usr/bin/env lua
-- main.lua — Yvy backend entry point (baremetal Lua)
-- Starts the HTTP server with all routes registered
-- Usage: lua main.lua

-- Add project root to package path
local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. package.path

local env = require("app.env")

-- Try multiple .env locations
env.load_dotenv(".env")
env.load_dotenv("../.env")
env.load_dotenv(script_dir .. "../.env")

local server = require("app.server")
local init   = require("app.init")
local logger = require("app.logger")

-- ── Register routes ──────────────────────────────────────────────────────

local fires               = require("app.routes.fires")
local deforestation       = require("app.routes.deforestation")
local deforestation_stats = require("app.routes.deforestation_stats")
local biomes              = require("app.routes.biomes")
local weather       = require("app.routes.weather")
local news          = require("app.routes.news")
local alerts        = require("app.routes.alerts")
local tiles         = require("app.routes.tiles")
local auth          = require("app.middleware.auth")
local rl            = require("app.middleware.rate_limit")
local db            = require("app.db")
local redis         = require("app.redis")
local state_lookup  = require("app.lookups.state_lookup")
local cjson         = require("cjson")

local function read_json_file(candidates)
    local path = env.first_existing(candidates)
    if not path then
        return "{}"
    end

    local file = io.open(path, "r")
    if not file then
        return "{}"
    end

    local data = file:read("*a")
    file:close()
    return data or "{}"
end

local function read_lookup_json(key, candidates)
    local data = db.get_lookup_data(key)
    if data then
        data._updated_at = nil
        return cjson.encode(data)
    end
    return read_json_file(candidates)
end

-- ── GeoJSON helpers (pre-transform + ETag + 3-decimal coord precision) ──

local function round3(n)
    if type(n) ~= "number" then return n end
    return math.floor(n * 1000 + 0.5) / 1000
end

-- DJB2 rolling hash; Lua-5.1-safe (mod each step under 2^53 precision)
local function djb2_hex(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + string.byte(s, i)) % 4294967296
    end
    return string.format("%08x", h)
end

-- Convert raw {name = {rings, ...}} map → GeoJSON FeatureCollection
local function bounds_to_geojson(raw)
    local features = {}
    for name, d in pairs(raw) do
        if type(d) == "table" and type(d.rings) == "table" then
            local coords = {}
            for _, ring in ipairs(d.rings) do
                local outer = {}
                for _, pt in ipairs(ring) do
                    outer[#outer + 1] = { round3(pt[1]), round3(pt[2]) }
                end
                coords[#coords + 1] = { outer }
            end
            features[#features + 1] = {
                type = "Feature",
                properties = {
                    name = name,
                    state_abbr = d.state_abbr,
                    municipality = d.municipality,
                    category = d.category,
                    full_name = d.full_name,
                },
                geometry = { type = "MultiPolygon", coordinates = coords },
            }
        end
    end
    return { type = "FeatureCollection", features = features }
end

local function build_lookup_geojson(redis_key, lookup_key, candidates)
    local body = redis.get(redis_key .. ":body")
    local etag = redis.get(redis_key .. ":etag")
    if body and etag then return body, etag end

    local raw_json = read_lookup_json(lookup_key, candidates)
    local ok, raw = pcall(cjson.decode, raw_json)
    if not ok or type(raw) ~= "table" then
        etag = '"' .. djb2_hex(raw_json) .. '"'
        return raw_json, etag
    end
    raw._updated_at = nil
    local fc = bounds_to_geojson(raw)
    body = cjson.encode(fc)
    etag = '"' .. djb2_hex(body) .. '"'
    redis.set(redis_key .. ":body", body, 86400)
    redis.set(redis_key .. ":etag", etag, 86400)
    return body, etag
end

local function serve_geo_lookup(ctx, redis_key, lookup_key, candidates)
    if not rl.enforce(ctx) then return end
    local body, etag = build_lookup_geojson(redis_key, lookup_key, candidates)
    ctx:set_header("Cache-Control", "public, max-age=3600")
    ctx:set_header("ETag", etag)
    local inm = ctx.req.headers and ctx.req.headers["if-none-match"]
    if inm and inm == etag then
        ctx:send(304, "")
        return
    end
    ctx:send(200, body)
end

-- Health checks
server.route("GET", "/health", function(ctx)
    ctx:json(200, {status = "healthy", timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")})
end)

server.route("GET", "/api/health", function(ctx)
    ctx:json(200, {status = "healthy", timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")})
end)

-- Root
server.route("GET", "/", function(ctx)
    ctx:json(200, {message = "API do backend de desmatamento (Lua baremetal)"})
end)

-- Fires
server.route("GET", "/api/fires", fires.get_fires)
server.route("GET", "/api/fires/timeseries", fires.get_fires_timeseries)
server.route("GET", "/api/fires/by-state", fires.get_fires_by_state)
server.route("GET", "/api/fires/state-sparklines", fires.get_fires_state_sparklines)
server.route("GET", "/api/fires/protected-share", fires.get_protected_share)
server.route("POST", "/api/fires/sync", fires.sync_fires)
server.route("POST", "/api/admin/firms/sync", fires.admin_firms_sync)
server.route("POST", "/api/admin/fires/classify", function(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end
    local version = tonumber(ctx.req.args.version) or 0
    local started = fires.trigger_fire_classification(version)
    ctx:json(200, {started = started, version = version})
end)

-- Deforestation data
server.route("GET", "/api/data", deforestation.get_data)

-- PRODES historical (annual INPE totals)
server.route("GET", "/api/deforestation/historical", deforestation_stats.get_historical)

-- Territorial deforestation stats (plan: terrabrasilis-integration, Inc 7)
server.route("GET", "/api/deforestation/stats/by-municipality", function(ctx)
    local ds = require("app.routes.deforestation_stats")
    ds.get_by_municipality(ctx)
end)
server.route("GET", "/api/deforestation/stats/by-uc", function(ctx)
    local ds = require("app.routes.deforestation_stats")
    ds.get_by_uc(ctx)
end)
server.route("GET", "/api/deforestation/stats/by-ti", function(ctx)
    local ds = require("app.routes.deforestation_stats")
    ds.get_by_ti(ctx)
end)

-- PRODES tiles (WMS proxy/cache)
server.route("GET", "/api/tiles/prodes", tiles.get_tile)

-- CAR tiles (precomputed raster overlay — Inc 2, .plans/car-overlay)
server.route("GET", "/api/tiles/car", tiles.get_tile_car)

-- TerraClass + Vegetação Secundária tiles (plan: terrabrasilis-integration, Inc 9)
server.route("GET", "/api/tiles/terraclass", tiles.get_tile_terraclass)

-- Cerrado vegetation tiles (Inc 9)
server.route("GET", "/api/tiles/cerrado-veg", tiles.get_tile_cerrado_veg)

-- CAR point lookup (clique-para-inspecionar do overlay)
server.route("GET", "/api/car/lookup", function(ctx)
    local car_routes = require("app.routes.car")
    car_routes.get_lookup(ctx)
end)

-- CAR property PRODES verification by receipt (plan: terrabrasilis-integration, Inc 12)
-- Router matches EXACT paths — query params, no :param support.
server.route("GET", "/api/car/prodes", function(ctx)
    local car_routes = require("app.routes.car")
    car_routes.get_prodes_status(ctx)
end)
server.route("GET", "/api/car/summary", function(ctx)
    local car_routes = require("app.routes.car")
    car_routes.get_summary(ctx)
end)

-- DETER alerts (plan: terrabrasilis-integration, Inc 2/3)
server.route("GET", "/api/deter/polygons", function(ctx)
    local deter = require("app.routes.deter")
    deter.get_polygons(ctx)
end)
server.route("GET", "/api/deter/stats", function(ctx)
    local deter = require("app.routes.deter")
    deter.get_stats(ctx)
end)
server.route("GET", "/api/deter/car-alerts", function(ctx)
    local deter = require("app.routes.deter")
    deter.get_car_alerts(ctx)
end)

-- AMS fire-spreading-risk overlay (plan: terrabrasilis-integration, Inc 11)
server.route("GET", "/api/ams/risk", function(ctx)
    local ams = require("app.routes.ams")
    ams.get_risk(ctx)
end)
server.route("GET", "/api/ams/active", function(ctx)
    local ams = require("app.routes.ams")
    ams.get_active(ctx)
end)

-- Biomes
server.route("GET", "/api/biomes", biomes.get_biomes)

-- Biome boundaries GeoJSON (for map highlight)
server.route("GET", "/api/biome-boundaries", function(ctx)
    if not rl.enforce(ctx) then return end
    local cached = redis.get("biome:boundaries")
    if cached then
        ctx:set_header("Cache-Control", "public, max-age=3600")
        ctx:send(200, cached)
        return
    end
    local bl = require("app.lookups.biome_lookup")
    local ok, geojson = pcall(bl.get_geojson)
    if not ok then ctx:json(500, {error = "biome data unavailable"}); return end
    local body = cjson.encode(geojson)
    redis.set("biome:boundaries", body, 3600)
    ctx:set_header("Cache-Control", "public, max-age=3600")
    ctx:send(200, body)
end)

-- Alerts
server.route("GET", "/api/alerts", function(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local cached = redis.get("alerts:all")
    if cached and not cached:find('"alerts"%s*:%s*{}') then
        ctx:set_header("Cache-Control", "public, max-age=300")
        ctx:send(200, cached)
        return
    end
    if cached then redis.delete("alerts:all") end

    local alerts_mod = require("app.routes.alerts")
    local fires_data = db.find_fires(-34.0, 5.5, -74.0, -34.0, 10000)
    local result = alerts_mod.generate_all_alerts(fires_data, nil, os.getenv("WAQI_TOKEN"))
    local body = cjson.encode(result)
    redis.set("alerts:all", body, 1800)
    ctx:set_header("Cache-Control", "public, max-age=300")
    ctx:send(200, body)
end)

-- TI at-risk (top indigenous lands with recent fires)
-- The point-in-polygon compute is CPU-heavy (~77s on a cold cache for ~19k
-- recent fires x 547 TI polygons) and the backend is a single-threaded copas
-- loop, so a synchronous compute would block EVERY other request (incl. news).
-- The compute therefore runs in a detached subprocess (tools/warm_ti_at_risk.lua)
-- that writes the result to Redis. This route only reads Redis and serves a
-- last-known-good (stale) copy while a refresh is in flight — it never blocks.
server.route("GET", "/api/fires/ti-at-risk", function(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local days = tonumber(ctx.req.args.days) or 7
    local limit = tonumber(ctx.req.args.limit) or 10
    local cache_key = "fires:ti_at_risk:" .. days .. ":" .. limit
    local stale_key = cache_key .. ":stale"

    local cached = redis.get(cache_key)
    if cached then
        ctx:set_header("Cache-Control", "public, max-age=300")
        ctx:send(200, cached)
        return
    end

    -- Cold path: serve last-known-good immediately + refresh in background.
    local body = redis.get(stale_key)
    if not body then
        body = cjson.encode({ days = days, limit = limit, count = 0, lands = {} })
    end
    fires.trigger_ti_at_risk_refresh(days, limit)
    ctx:set_header("Cache-Control", "public, max-age=30")
    ctx:send(200, body)
end)

-- Fire nature classification stats (por classe e por estado)
server.route("GET", "/api/fires/nature-stats", function(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local args = ctx.req.args or {}
    local days = tonumber(args.days) or 7
    if days < 1 then days = 1 end
    if days > 3650 then days = 3650 end
    local state = type(args.state) == "string" and args.state ~= "" and args.state:upper() or nil

    if state then
        local found = false
        for _, uf in ipairs(state_lookup.list_ufs()) do
            if uf == state then found = true break end
        end
        if not found then
            ctx:json(400, {error = "invalid state"})
            return
        end
    end

    local cache_key = "fires:nature:" .. days .. (state and (":" .. state) or "")
    local cached = redis.get(cache_key)
    if cached then
        ctx:set_header("Cache-Control", "public, max-age=300")
        ctx:send(200, cached)
        return
    end

    local body = cjson.encode(fires.get_fire_nature_stats(days, state))
    redis.set(cache_key, body, 300)
    ctx:set_header("Cache-Control", "public, max-age=300")
    ctx:send(200, body)
end)

-- News
server.route("GET", "/api/news", news.get_news)
server.route("POST", "/api/news/refresh", news.refresh_news)
server.route("POST", "/api/news/repair", news.repair_news)
server.route("POST", "/api/admin/news/sync", news.admin_news_sync)

-- Weather
server.route("GET", "/api/weather",             weather.get_weather)
server.route("GET", "/api/weather/air-quality", weather.get_air_quality)
server.route("GET", "/api/weather/temperature", weather.get_temperature)

-- Indigenous lands (pre-transformed GeoJSON, ETag-cached)
server.route("GET", "/api/indigenous-lands", function(ctx)
    serve_geo_lookup(ctx, "lookup:indigenous_lands_geo", "indigenous_lands", {
        script_dir .. "data/indigenous_lands.json",
        script_dir .. "../backend/indigenous_lands.json",
        "data/indigenous_lands.json",
        "../backend/indigenous_lands.json",
    })
end)

-- Conservation units (pre-transformed GeoJSON, ETag-cached)
server.route("GET", "/api/conservation-units", function(ctx)
    serve_geo_lookup(ctx, "lookup:conservation_units_geo", "conservation_units", {
        script_dir .. "data/conservation_units.json",
        script_dir .. "../backend/conservation_units.json",
        "data/conservation_units.json",
        "../backend/conservation_units.json",
    })
end)

-- Stats
server.route("GET", "/api/stats", function(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end
    local cached = redis.get("stats:all")
    if cached then
        ctx:set_header("Cache-Control", "public, max-age=60")
        ctx:send(200, cached)
        return
    end
    local body = cjson.encode(db.get_stats())
    redis.set("stats:all", body, 60)
    ctx:set_header("Cache-Control", "public, max-age=60")
    ctx:send(200, body)
end)

-- ── Startup ──────────────────────────────────────────────────────────────

init.startup()
init.start_background_tasks()

logger.info("Starting Yvy HTTP server...")
server.start()

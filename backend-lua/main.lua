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

local fires         = require("app.routes.fires")
local deforestation = require("app.routes.deforestation")
local biomes        = require("app.routes.biomes")
local weather       = require("app.routes.weather")
local news          = require("app.routes.news")
local alerts        = require("app.routes.alerts")
local auth          = require("app.middleware.auth")
local rl            = require("app.middleware.rate_limit")
local db            = require("app.db")
local redis         = require("app.redis")
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
server.route("POST", "/api/fires/sync", fires.sync_fires)
server.route("POST", "/api/admin/firms/sync", fires.admin_firms_sync)

-- Deforestation
server.route("GET", "/api/data", deforestation.get_data)

-- Biomes
server.route("GET", "/api/biomes", biomes.get_biomes)

-- Alerts
server.route("GET", "/api/alerts", function(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local cached = redis.get("alerts:all")
    if cached then ctx:send(200, cached); return end

    local alerts_mod = require("app.routes.alerts")
    local fires_data = db.find_fires(-34.0, 5.5, -74.0, -34.0, 10000)
    local result = alerts_mod.generate_all_alerts(fires_data, nil, os.getenv("WAQI_TOKEN"))
    local body = cjson.encode(result)
    redis.set("alerts:all", body, 1800)
    ctx:send(200, body)
end)

-- News
server.route("GET", "/api/news", news.get_news)
server.route("POST", "/api/news/refresh", news.refresh_news)
server.route("POST", "/api/news/repair", news.repair_news)
server.route("POST", "/api/admin/news/sync", news.admin_news_sync)

-- Weather
server.route("GET", "/api/weather/air-quality", weather.get_air_quality)
server.route("GET", "/api/weather/temperature", weather.get_temperature)

-- Indigenous lands
server.route("GET", "/api/indigenous-lands", function(ctx)
    if not rl.enforce(ctx) then return end
    ctx:send(200, read_json_file({
        script_dir .. "data/indigenous_lands.json",
        script_dir .. "../backend/indigenous_lands.json",
        "data/indigenous_lands.json",
        "../backend/indigenous_lands.json",
    }))
end)

-- Conservation units
server.route("GET", "/api/conservation-units", function(ctx)
    if not rl.enforce(ctx) then return end
    ctx:send(200, read_json_file({
        script_dir .. "data/conservation_units.json",
        script_dir .. "../backend/conservation_units.json",
        "data/conservation_units.json",
        "../backend/conservation_units.json",
    }))
end)

-- Stats
server.route("GET", "/api/stats", function(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end
    ctx:json(200, db.get_stats())
end)

-- ── Startup ──────────────────────────────────────────────────────────────

init.startup()
init.start_background_tasks()

logger.info("Starting Yvy HTTP server...")
server.start()

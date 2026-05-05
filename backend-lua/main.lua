#!/usr/bin/env lua
-- main.lua — Yvy backend entry point (baremetal Lua)
-- Starts the HTTP server with all routes registered
-- Usage: lua main.lua

-- Add project root to package path
local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
package.path = script_dir .. "?.lua;" .. script_dir .. "?/init.lua;" .. package.path

-- Load .env file
local function load_dotenv(path)
    local f = io.open(path, "r")
    if not f then return end
    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" and not line:match("^#") then
            local key, value = line:match("^([%w_]+)%s*=%s*(.*)$")
            if key then
                value = value:gsub('^"', ""):gsub('"$', ""):gsub("^'", ""):gsub("'$", "")
                value = value:match("^(.-)%s*#") or value
                os.setenv(key, value)
            end
        end
    end
    f:close()
end

-- Try multiple .env locations
load_dotenv(".env")
load_dotenv("../.env")
load_dotenv(script_dir .. "../.env")

local server = require("app.server")
local init   = require("app.init")
local logger = require("app.logger")

-- ── Register routes ──────────────────────────────────────────────────────

local fires         = require("app.fires")
local deforestation = require("app.deforestation")
local biomes        = require("app.biomes")
local weather       = require("app.weather")
local news          = require("app.news")
local auth          = require("app.auth")
local rl            = require("app.rate_limit")
local db            = require("app.db")
local redis         = require("app.redis")
local cjson         = require("cjson")

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

    local alerts_mod = require("app.alerts")
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
    local f = io.open(script_dir .. "data/indigenous_lands.json", "r")
    if f then ctx:send(200, f:read("*a")); f:close()
    else ctx:send(200, "{}") end
end)

-- Conservation units
server.route("GET", "/api/conservation-units", function(ctx)
    if not rl.enforce(ctx) then return end
    local f = io.open(script_dir .. "data/conservation_units.json", "r")
    if f then ctx:send(200, f:read("*a")); f:close()
    else ctx:send(200, "{}") end
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

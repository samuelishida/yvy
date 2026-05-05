-- init.lua — Startup initialization for Yvy backend (baremetal)
-- Loads all lookup data, initializes DB, starts background tasks via copas

local db          = require("app.db")
local biome       = require("app.biome_lookup")
local ti          = require("app.indigenous_lands_lookup")
local uc          = require("app.conservation_units_lookup")
local ingest      = require("app.ingest")
local fires_mod   = require("app.fires")
local news_mod    = require("app.news")
local alerts_mod  = require("app.alerts")
local redis       = require("app.redis")
local http_client = require("app.http_client")
local cjson       = require("cjson")
local logger      = require("app.logger")
local socket      = require("socket")

local _M = {}

-- ── Background sync intervals ────────────────────────────────────────────

local FIRMS_SYNC_INTERVAL = tonumber(os.getenv("FIRMS_SYNC_INTERVAL_HOURS") or "4") * 3600
local NEWS_SYNC_INTERVAL  = tonumber(os.getenv("NEWS_SYNC_INTERVAL_MINUTES") or "15") * 60
local ALERTS_SYNC_INTERVAL = 1800  -- 30 minutes

-- ── Startup ──────────────────────────────────────────────────────────────

function _M.startup()
    logger.info("=== Yvy Backend (Lua baremetal) Starting ===")

    -- Initialize database
    db.init_db()

    -- Load biome boundaries
    local ok, err = pcall(biome.load_biomes)
    if not ok then
        logger.warn("Failed to load biome data: " .. tostring(err))
    end

    -- Load indigenous lands
    ok, err = pcall(ti.load_indigenous_lands)
    if not ok then
        logger.warn("Failed to load indigenous lands data: " .. tostring(err))
    end

    -- Load conservation units
    ok, err = pcall(uc.load_conservation_units)
    if not ok then
        logger.warn("Failed to load conservation units data: " .. tostring(err))
    end

    -- Run PRODES ingestion (if CSV available)
    ok, err = pcall(ingest.run)
    if not ok then
        logger.warn("PRODES ingestion failed: " .. tostring(err))
    end

    logger.info("=== Yvy Backend Ready ===")
end

-- ── Background tasks (simple sleep-loop coroutines) ──────────────────────

local function fires_sync_loop()
    socket.sleep(10)  -- initial delay
    while true do
        logger.info("Background FIRMS sync starting")
        pcall(fires_mod.fetch_firms_data, false)
        socket.sleep(FIRMS_SYNC_INTERVAL)
    end
end

local function news_sync_loop()
    socket.sleep(15)
    while true do
        logger.info("Background news sync starting")
        pcall(news_mod.fetch_and_save_news)
        socket.sleep(NEWS_SYNC_INTERVAL)
    end
end

local function alerts_sync_loop()
    socket.sleep(60)
    while true do
        logger.info("Background alerts refresh starting")
        pcall(function()
            local fires = db.find_fires(-34.0, 5.5, -74.0, -34.0, 10000)
            local result = alerts_mod.generate_all_alerts(fires, nil, os.getenv("WAQI_TOKEN"))
            redis.set("alerts:all", cjson.encode(result), 1800)
            logger.info("Alerts cache refreshed: " .. result.count .. " alerts")
        end)
        socket.sleep(ALERTS_SYNC_INTERVAL)
    end
end

function _M.start_background_tasks()
    -- Spawn background coroutines (cooperative multitasking via copas)
    -- These run in the same process; socket.sleep yields to copas
    coroutine.wrap(fires_sync_loop)()
    coroutine.wrap(news_sync_loop)()
    coroutine.wrap(alerts_sync_loop)()
end

return _M


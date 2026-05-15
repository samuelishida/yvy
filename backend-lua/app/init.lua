-- init.lua — Startup initialization for Yvy backend (baremetal)
-- Loads all lookup data, initializes DB, starts background tasks via copas

require("app.env")
local db          = require("app.db")
local biome       = require("app.lookups.biome_lookup")
local ti          = require("app.lookups.indigenous_lands_lookup")
local uc          = require("app.lookups.conservation_units_lookup")
local ingest      = require("app.ingest")
local fires_mod   = require("app.routes.fires")
local news_mod    = require("app.routes.news")
local alerts_mod  = require("app.routes.alerts")
local redis       = require("app.redis")
local http_client = require("app.http_client")
local cjson       = require("cjson")
local logger      = require("app.logger")
local copas       = require("copas")

local _M = {}

-- ── Background sync intervals ────────────────────────────────────────────

local FIRMS_SYNC_INTERVAL = tonumber(os.getenv("FIRMS_SYNC_INTERVAL_HOURS") or "4") * 3600
local NEWS_SYNC_INTERVAL  = tonumber(os.getenv("NEWS_SYNC_INTERVAL_MINUTES") or "15") * 60
local ALERTS_SYNC_INTERVAL = 1800  -- 30 minutes
local STATS_PREWARM_INTERVAL = 60  -- 1 minute
local BIOMES_PREWARM_INTERVAL = 300  -- 5 minutes
local NEWS_PREWARM_INTERVAL = 300  -- 5 minutes

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
    copas.sleep(10)
    while true do
        logger.info("Background FIRMS sync starting")
        pcall(fires_mod.fetch_firms_data, false)
        copas.sleep(FIRMS_SYNC_INTERVAL)
    end
end

local function news_sync_loop()
    copas.sleep(15)
    while true do
        logger.info("Background news sync starting")
        pcall(news_mod.fetch_and_save_news)
        copas.sleep(NEWS_SYNC_INTERVAL)
    end
end

local function alerts_sync_loop()
    copas.sleep(60)
    while true do
        logger.info("Background alerts refresh starting")
        pcall(function()
            local fires = db.find_fires(-34.0, 5.5, -74.0, -34.0, 10000)
            local result = alerts_mod.generate_all_alerts(fires, nil, os.getenv("WAQI_TOKEN"))
            redis.set("alerts:all", cjson.encode(result), 1800)
            logger.info("Alerts cache refreshed: " .. result.count .. " alerts")
        end)
        copas.sleep(ALERTS_SYNC_INTERVAL)
    end
end

local function stats_prewarm_loop()
    copas.sleep(5)
    while true do
        pcall(function()
            local body = cjson.encode(db.get_stats())
            redis.set("stats:all", body, STATS_PREWARM_INTERVAL + 30)
        end)
        copas.sleep(STATS_PREWARM_INTERVAL)
    end
end

local function biomes_prewarm_loop()
    local biome_lookup = require("app.lookups.biome_lookup")
    local MAX_RESULTS = tonumber(os.getenv("MAX_RESULTS_PER_REQUEST") or "10000")
    copas.sleep(20)
    while true do
        pcall(function()
            local fires = db.find_fires(-34.0, 5.5, -74.0, -34.0, MAX_RESULTS)
            local result = biome_lookup.classify_fires(fires)
            local last_sync = redis.get("fires:last_sync")
            local body = cjson.encode({biomes = result, total_fires = #fires, last_sync = last_sync})
            redis.set("biomes:all", body, BIOMES_PREWARM_INTERVAL + 60)
        end)
        copas.sleep(BIOMES_PREWARM_INTERVAL)
    end
end

local function news_prewarm_loop()
    copas.sleep(30)
    while true do
        pcall(function()
            -- Pre-warm hot pages: page 1 small (10) and medium (20) for PT and EN
            local combos = {
                -- page_size 5: prewarm first 4 pages (covers ~20 articles of lazy scroll)
                {"pt", 1, 5}, {"pt", 2, 5}, {"pt", 3, 5}, {"pt", 4, 5},
                {"en", 1, 5}, {"en", 2, 5}, {"en", 3, 5}, {"en", 4, 5},
                -- legacy page sizes
                {"pt", 1, 10}, {"pt", 1, 20},
                {"en", 1, 10}, {"en", 1, 20},
            }
            for _, combo in ipairs(combos) do
                local lang, page, page_size = combo[1], combo[2], combo[3]
                local key = "news:" .. lang .. ":" .. page .. ":" .. page_size
                if not redis.get(key) then
                    local articles = db.get_news_page(page, page_size, lang)
                    if articles and #articles > 0 then
                        redis.set(key, cjson.encode(articles), 300)
                    end
                end
            end
        end)
        copas.sleep(NEWS_PREWARM_INTERVAL)
    end
end

function _M.start_background_tasks()
    copas.addthread(fires_sync_loop)
    copas.addthread(news_sync_loop)
    copas.addthread(alerts_sync_loop)
    copas.addthread(stats_prewarm_loop)
    copas.addthread(biomes_prewarm_loop)
    copas.addthread(news_prewarm_loop)
end

return _M


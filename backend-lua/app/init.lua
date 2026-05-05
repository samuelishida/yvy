-- init.lua — Startup initialization for Yvy backend
-- Called from init_by_lua_block in nginx.conf
-- Loads all lookup data, initializes DB, starts background timers

local db          = require("app.db")
local biome       = require("app.biome_lookup")
local ti          = require("app.indigenous_lands_lookup")
local uc          = require("app.conservation_units_lookup")
local ingest      = require("app.ingest")
local fires_mod   = require("app.fires")
local news_mod    = require("app.news")
local alerts_mod  = require("app.alerts")
local redis       = require("app.redis")
local http        = require("resty.http")
local cjson       = require("cjson")

local _M = {}

-- ── Background sync intervals ────────────────────────────────────────────

local FIRMS_SYNC_INTERVAL = tonumber(os.getenv("FIRMS_SYNC_INTERVAL_HOURS") or "4") * 3600
local NEWS_SYNC_INTERVAL  = tonumber(os.getenv("NEWS_SYNC_INTERVAL_MINUTES") or "15") * 60
local ALERTS_SYNC_INTERVAL = 1800  -- 30 minutes

-- ── Startup ──────────────────────────────────────────────────────────────

function _M.startup()
    ngx.log(ngx.INFO, "=== Yvy Backend (Lua/OpenResty) Starting ===")

    -- Initialize database
    db.init_db()

    -- Load biome boundaries
    local ok, err = pcall(biome.load_biomes)
    if not ok then
        ngx.log(ngx.WARN, "Failed to load biome data: ", err)
    end

    -- Load indigenous lands
    ok, err = pcall(ti.load_indigenous_lands)
    if not ok then
        ngx.log(ngx.WARN, "Failed to load indigenous lands data: ", err)
    end

    -- Load conservation units
    ok, err = pcall(uc.load_conservation_units)
    if not ok then
        ngx.log(ngx.WARN, "Failed to load conservation units data: ", err)
    end

    -- Run PRODES ingestion (if CSV available)
    ok, err = pcall(ingest.run)
    if not ok then
        ngx.log(ngx.WARN, "PRODES ingestion failed: ", err)
    end

    ngx.log(ngx.INFO, "=== Yvy Backend Ready ===")
end

-- ── Background timers ────────────────────────────────────────────────────

function _M.start_background_tasks()
    -- FIRMS sync (every N hours)
    local function fires_timer(premature)
        if premature then return end
        ngx.log(ngx.INFO, "Background FIRMS sync starting")
        pcall(fires_mod.fetch_firms_data, false)
        -- Reschedule
        ngx.timer.at(FIRMS_SYNC_INTERVAL, fires_timer)
    end
    ngx.timer.at(10, fires_timer)  -- Start after 10s

    -- News sync (every N minutes)
    local function news_timer(premature)
        if premature then return end
        ngx.log(ngx.INFO, "Background news sync starting")
        pcall(news_mod.fetch_and_save_news)
        ngx.timer.at(NEWS_SYNC_INTERVAL, news_timer)
    end
    ngx.timer.at(15, news_timer)  -- Start after 15s

    -- Alerts refresh (every 30 minutes)
    local function alerts_timer(premature)
        if premature then return end
        ngx.log(ngx.INFO, "Background alerts refresh starting")
        pcall(function()
            local fires = db.find_fires(-34.0, 5.5, -74.0, -34.0, 10000)
            local httpc = http.new()
            httpc:set_timeout(30000)
            local result = alerts_mod.generate_all_alerts(fires, httpc, os.getenv("WAQI_TOKEN"))
            httpc:close()
            redis.set("alerts:all", cjson.encode(result), 1800)
            ngx.log(ngx.INFO, "Alerts cache refreshed: ", result.count, " alerts")
        end)
        ngx.timer.at(ALERTS_SYNC_INTERVAL, alerts_timer)
    end
    ngx.timer.at(60, alerts_timer)  -- Start after 60s
end

return _M

-- tools/news_sync.lua — detached subprocess that runs the full news sync:
-- fetch RSS sources → dedupe → enrich images → translate → upsert → repair.
--
-- WHY: the backend is a single-threaded copas loop. News sync does BLOCKING
-- HTTPS (8+ RSS sources, up to 40 image-enrichment fetches, MyMemory
-- translation) via io.popen(curl)/socket, none of which yields to copas. When
-- run inline it froze the whole API — a first-use /api/news request took
-- ~27s waiting on a sync. The news_sync_loop and admin endpoints therefore
-- spawn this script detached (nohup ... &). The event loop never blocks.
--
-- Usage: lua5.1 tools/news_sync.lua [force]
--   force = 1  → bypass the recent-news guard and always re-fetch/translate.

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local backend_dir = script_dir:gsub("[\\/]tools[\\/]$", "/")
package.path = backend_dir .. "?.lua;" .. backend_dir .. "?/init.lua;" .. package.path

local env = require("app.env")
env.load_dotenv(backend_dir .. "../.env")
env.load_dotenv(backend_dir .. ".env")

local db      = require("app.db")
local redis   = require("app.redis")
local cjson   = require("cjson")
local logger  = require("app.logger")

local force = (arg and arg[1] == "1")

db.init_db()

local news_mod = require("app.routes.news")

local t0 = os.time()
local ok, result_or_err = pcall(function()
    return news_mod.fetch_and_save_news({ force = force })
end)

if ok then
    local count = 0
    if type(result_or_err) == "table" then
        count = #result_or_err
    end
    -- Mark last sync so the news_sync_loop skips the next cycle.
    redis.set("news:last_sync", os.date("!%Y-%m-%dT%H:%M:%SZ"), 1800)
    logger.info(string.format(
        "News sync complete (subprocess): %d articles in %ds",
        count, os.time() - t0))
    print(cjson.encode({ ok = true, count = count, seconds = os.time() - t0 }))
    os.exit(0)
else
    logger.error("News sync (subprocess) failed: " .. tostring(result_or_err))
    print(cjson.encode({ ok = false, error = tostring(result_or_err), seconds = os.time() - t0 }))
    os.exit(1)
end

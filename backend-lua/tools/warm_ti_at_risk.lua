-- tools/warm_ti_at_risk.lua — detached subprocess that computes the
-- /api/fires/ti-at-risk payload and writes it to Redis.
--
-- WHY: the backend is a single-threaded copas loop. The point-in-polygon
-- pass over ~19k recent fires x 547 TI polygons takes ~77s on a cold cache,
-- and running it inline would block EVERY other request (news, tiles, ...).
-- The HTTP route therefore spawns this script detached (nohup ... &) and the
-- result is handed back to the server via Redis — the event loop never blocks.
--
-- Usage: lua5.1 tools/warm_ti_at_risk.lua [days] [limit]

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local backend_dir = script_dir:gsub("[\\/]tools[\\/]$", "/")
package.path = backend_dir .. "?.lua;" .. backend_dir .. "?/init.lua;" .. package.path

local env = require("app.env")
env.load_dotenv(backend_dir .. "../.env")
env.load_dotenv(backend_dir .. ".env")

local db    = require("app.db")
local redis = require("app.redis")
local ti    = require("app.lookups.indigenous_lands_lookup")
local fires = require("app.routes.fires")

local days  = tonumber(arg and arg[1]) or 7
local limit = tonumber(arg and arg[2]) or 10
local cache_key = "fires:ti_at_risk:" .. days .. ":" .. limit

-- Skip if a fresh value is already cached (the prewarm loop may fire while
-- the 600s TTL is still active).
if redis.get(cache_key) then
    os.exit(0)
end

db.init_db()
ti.load_indigenous_lands()

local body = fires.compute_ti_at_risk(days, limit)
redis.set(cache_key, body, 600)
-- Keep a last-known-good copy so the route can serve stale data while a
-- refresh is in flight (7-day TTL).
redis.set(cache_key .. ":stale", body, 604800)

io.stderr:write("ti-at-risk warmed: " .. cache_key .. "\n")

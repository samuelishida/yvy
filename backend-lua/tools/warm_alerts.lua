-- tools/warm_alerts.lua — detached subprocess that computes the /api/alerts
-- payload and writes it to Redis.
--
-- WHY: the backend is a single-threaded copas loop. find_fires (10k rows) +
-- generate_all_alerts (TI/UC point-in-polygon, clustering, DETER/PRODES/PM2.5)
-- takes ~0.8s, and running it inline (route cache-miss or the 30-min sync
-- loop) blocked EVERY other request while it ran. Mirrors
-- tools/warm_ti_at_risk.lua — the HTTP route serves cached/stale payloads
-- from Redis and spawns THIS script detached (nohup ... &) when a refresh is
-- due, so the event loop never blocks. Plan: tile-corruption-biome-speed.
--
-- Redis keys written:
--   alerts:all       — current payload (TTL 1800s)
--   alerts:all:stale — last-known-good for the cold route path (TTL 7d)
--   alerts:last_sync — ISO-8601 UTC marker; init.lua gates the next refresh
--                      on its age (ALERTS_SYNC_INTERVAL, 30min)
-- Release of the spawn lock (alerts:refresh:lock) happens here on success so
-- a fresh refresh can start immediately; the lock's TTL (1800s) is only the
-- crash backstop.
--
-- Usage: lua5.1 tools/warm_alerts.lua

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local backend_dir = script_dir:gsub("[\\/]tools[\\/]$", "/")
package.path = backend_dir .. "?.lua;" .. backend_dir .. "?/init.lua;" .. package.path

local env    = require("app.env")
env.load_dotenv(backend_dir .. "../.env")
env.load_dotenv(backend_dir .. ".env")

local db     = require("app.db")
local redis  = require("app.redis")
local ti     = require("app.lookups.indigenous_lands_lookup")
local uc     = require("app.lookups.conservation_units_lookup")
local alerts = require("app.routes.alerts")
local cjson  = require("cjson")

db.init_db()
ti.load_indigenous_lands()
uc.load_conservation_units()

local fires = db.find_fires(-34.0, 5.5, -74.0, -34.0, 10000)
local ok, result = pcall(alerts.generate_all_alerts, fires, nil, os.getenv("WAQI_TOKEN"))

if not ok then
    -- Crash backstop (review N1): liberar o lock SEMPRE. Com pcall, uma
    -- exceção aqui (lookup vazio, redis parcial, ...) não deixa
    -- alerts:refresh:lock zumbi por 30min — o próximo trigger roda na
    -- próxima janela. O TTL (1800s) continua cobrindo o caso de kill -9.
    redis.delete("alerts:refresh:lock")
    io.stderr:write("alerts warm FAILED: " .. tostring(result) .. "\n")
    os.exit(1)
end

local body = cjson.encode(result)

redis.set("alerts:all", body, 1800)
-- Last-known-good copy so the route can serve stale data while a refresh is
-- in flight (7-day TTL).
redis.set("alerts:all:stale", body, 604800)
redis.set("alerts:last_sync", os.date("!%Y-%m-%dT%H:%M:%SZ"), 3600)
redis.delete("alerts:refresh:lock")  -- done — next spawn can take the lock

io.stderr:write("alerts warmed: " .. tostring(result.count) .. " alerts (stale 7d)\n")

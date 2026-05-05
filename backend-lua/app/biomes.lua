-- biomes.lua — /api/biomes
-- Baremetal Lua version

local db           = require("app.db")
local auth         = require("app.auth")
local rl           = require("app.rate_limit")
local redis        = require("app.redis")
local biome_lookup = require("app.biome_lookup")
local cjson        = require("cjson")

local _M = {}

local MAX_RESULTS = tonumber(os.getenv("MAX_RESULTS_PER_REQUEST") or "10000")

function _M.get_biomes(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local cached = redis.get("biomes:all")
    if cached then ctx:send(200, cached); return end

    local fires = db.find_fires(-34.0, 5.5, -74.0, -34.0, MAX_RESULTS)
    local result = biome_lookup.classify_fires(fires)
    local last_sync = redis.get("fires:last_sync")

    local response = cjson.encode({biomes = result, total_fires = #fires, last_sync = last_sync})
    redis.set("biomes:all", response, 60)
    ctx:send(200, response)
end

return _M


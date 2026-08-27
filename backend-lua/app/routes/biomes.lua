-- biomes.lua — /api/biomes
-- Baremetal Lua version
--
-- Plan: tile-corruption-biome-speed — o card "Focos por bioma" virou um
-- agregado SQL sobre a coluna $.biome persistida (db.count_fires_by_biome_
-- window, ~0.16s) em vez de find_fires + classify_fires inline (~1.5s, que
-- bloqueava o event loop copas a cada cache miss de 60s e no prewarm de 5min).
-- O shape da resposta NÃO muda: array de 6 entries na ordem BIOME_ORDER
-- (com zeros), pct sobre o total classificado, total_fires = rows da janela
-- (incl. sem bioma), last_sync.

require("app.env")
local db           = require("app.db")
local auth         = require("app.middleware.auth")
local rl           = require("app.middleware.rate_limit")
local redis        = require("app.redis")
local biome_lookup = require("app.lookups.biome_lookup")
local cjson        = require("cjson")

local _M = {}

local MAX_RESULTS = tonumber(os.getenv("MAX_RESULTS_PER_REQUEST") or "10000")
local BR_SW_LAT, BR_NE_LAT, BR_SW_LNG, BR_NE_LNG = -34.0, 5.5, -74.0, -34.0

-- Monta o body JSON de /api/biomes a partir do agregado SQL. Usado pela rota
-- E pelo prewarm loop (init.lua) — um único lugar para o shape.
function _M.compute_biomes_payload()
    -- load_biomes é idempotente e barato quando lookup_data já está no DB —
    -- mas só garantimos o load se o layer ainda estiver vazio (primeira
    -- chamada sem startup ainda). Sem re-read por request.
    if biome_lookup.loaded_count() == 0 then
        biome_lookup.load_biomes()
    end

    local counts, total = db.count_fires_by_biome_window(BR_SW_LAT, BR_NE_LAT, BR_SW_LNG, BR_NE_LNG, MAX_RESULTS)

    local unattributed = counts[""] or 0
    local classified = total - unattributed

    local biomes = {}
    for _, name in ipairs(biome_lookup.biome_order()) do
        local count = counts[name] or 0
        local pct = 0
        if classified > 0 then
            pct = math.floor(count / classified * 1000 + 0.5) / 10  -- round to 1 decimal
        end
        biomes[#biomes + 1] = {
            name = name,
            count = count,
            pct = pct,
            color = biome_lookup.color_for(name),
        }
    end

    local last_sync = redis.get("fires:last_sync")
    return cjson.encode({biomes = biomes, total_fires = total, last_sync = last_sync})
end

function _M.get_biomes(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local cached = redis.get("biomes:all")
    if cached and not cached:find('"biomes"%s*:%s*{}') then
        ctx:set_header("Cache-Control", "public, max-age=60")
        ctx:send(200, cached)
        return
    end
    if cached then redis.delete("biomes:all") end

    local response = _M.compute_biomes_payload()
    redis.set("biomes:all", response, 60)
    ctx:set_header("Cache-Control", "public, max-age=60")
    ctx:send(200, response)
end

return _M

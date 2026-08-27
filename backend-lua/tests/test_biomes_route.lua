-- test_biomes_route.lua — /api/biomes via aggregate SQL (plan:
-- tile-corruption-biome-speed).
--
-- O endpoint deixou de usar find_fires + classify_fires inline (~1.5s, que
-- bloqueava o event loop copas) e passou a usar a coluna $.biome persistida
-- (db.count_fires_by_biome_window, ~0.16s). Este teste cobre:
--   • o aggregate SQL (janela com LIMIT espelhando find_fires, '' normalizado)
--   • a rota: shape idêntico ao antigo — ARRAY de 6 entries em BIOME_ORDER
--     (zeros inclusos), pct sobre o total classificado, total_fires = rows da
--     janela (incluindo sem bioma), last_sync
--   • cache Redis (hit + guard de formato antigo de objeto)
--   • DB vazio → 6 zeros, total_fires=0
-- Redis stubado (common-mistakes #2); fixtures clock-relative (common-mistakes
-- #1); mesmas coordenadas validadas de test_fires_by_biome.lua.

local env = require("app.env")
local cjson = require("cjson")
local sqlite3 = require("lsqlite3")

local tmp_yvy_db = "./yvy_biomes_route_" .. tostring(os.time()) .. ".db"
env.set("SQLITE_PATH", tmp_yvy_db)
package.loaded["app.db"] = nil
package.loaded["app.routes.biomes"] = nil
package.loaded["app.lookups.biome_lookup"] = nil

local db_mod          = require("app.db")
local biomes_routes   = require("app.routes.biomes")
local biome_lookup    = require("app.lookups.biome_lookup")
local redis           = require("app.redis")

dofile("tests/helpers.lua")

-- ── Redis stub (memória) + restore no teardown ────────────────────────────

local store = {}
local original_redis = {
    get = redis.get, set = redis.set, delete = redis.delete,
    check_rate_limit = redis.check_rate_limit,
}
redis.get = function(k) return store[k] end
redis.set = function(k, v) store[k] = v end
redis.delete = function(k) store[k] = nil end
redis.check_rate_limit = function() return false end

-- População dos fixtures (idempotente via ON CONFLICT). Extraída do setup()
-- para os testes que MODIFICAM a fire_data (esvaziam a tabela) poderem
-- restaurar o invariant — sem depender de ordem de execução do busted.
local function seed_fixtures()
    -- 3 focos na Amazônia (Manaus), 2 no Cerrado (Brasília), 1 em terra
    -- fora do Brasil (La Pampa, AR — dentro do bbox BR, sem bioma → ''
    -- testando a normalização NULL/''). O bbox original (-34, 5.5, -74,
    -- -34) não cobre o oceano Atlântico (lon > -34) — ponto de oceano aqui
    -- seria EXCLUÍDO pela janela, não um caso de ''.
    db_mod.bulk_upsert_fires({
        { lat = -3.10, lon = -60.02, acq_date = days_ago(1), ingested_at = days_ago(1) .. "T00:00:00Z", state = "AM" },
        { lat = -3.11, lon = -60.03, acq_date = days_ago(2), ingested_at = days_ago(2) .. "T00:00:00Z", state = "AM" },
        { lat = -3.12, lon = -60.04, acq_date = days_ago(3), ingested_at = days_ago(3) .. "T00:00:00Z", state = "AM" },
        { lat = -15.79, lon = -47.90, acq_date = days_ago(1), ingested_at = days_ago(1) .. "T00:00:00Z", state = "DF" },
        { lat = -15.80, lon = -47.91, acq_date = days_ago(2), ingested_at = days_ago(2) .. "T00:00:00Z", state = "DF" },
        { lat = -33.8, lon = -60.0, acq_date = days_ago(1), ingested_at = days_ago(1) .. "T00:00:00Z", state = "" }, -- fora do BR → biome ''
    })
    -- backfill de biome manual (o loop de produção faz o mesmo)
    local batch = db_mod.iter_fires_for_biome_backfill(100)
    assert.are_equal(6, #batch)
    for _, row in ipairs(batch) do
        local name = biome_lookup.classify_point(row.lon, row.lat)
        if name then
            db_mod.update_fire_biome(row.id, name)
        else
            db_mod.mark_fire_biome_unattributable(row.id)
        end
    end
end

describe("biomes route (aggregate SQL)", function()
    setup(function()
        db_mod.init_db()
        biome_lookup.load_biomes()
        assert.is_true(biome_lookup.loaded_count() > 0, "biome layer loaded")
        seed_fixtures()
    end)

    teardown(function()
        db_mod.close_db()
        for _, p in ipairs({ tmp_yvy_db, tmp_yvy_db .. "-wal", tmp_yvy_db .. "-shm" }) do
            os.remove(p)
        end
        redis.get, redis.set, redis.delete, redis.check_rate_limit =
            original_redis.get, original_redis.set, original_redis.delete, original_redis.check_rate_limit
        store = {}
    end)

    it("aggregate SQL: janela espelhando find_fires, '' normalizado", function()
        local counts, total = db_mod.count_fires_by_biome_window(-34, 5.5, -74, -34, 10000)
        assert.are_equal(6, total)        -- rows da janela (INCL sem bioma)
        assert.are_equal(3, counts["Amazônia"])
        assert.are_equal(2, counts["Cerrado"])
        assert.are_equal(1, counts[""])   -- fora do BR → '' (NULL normalizado)
        assert.is_nil(counts["Pampa"])    -- ausente → 0 na resposta via BIOME_ORDER
    end)

    it("rota: array de 6 biomas em BIOME_ORDER, pct sobre classificados", function()
        local ctx = fake_ctx({})
        biomes_routes.get_biomes(ctx)
        assert.are_equal(200, ctx.status)

        local body = cjson.decode(ctx.body)
        assert.are_equal(6, #body.biomes)
        assert.are_equal("Amazônia", body.biomes[1].name)
        assert.are_equal("Pampa", body.biomes[6].name)

        local by_name = {}
        for _, b in ipairs(body.biomes) do by_name[b.name] = b end
        assert.are_equal(3, by_name["Amazônia"].count)
        assert.are_equal(2, by_name["Cerrado"].count)
        assert.are_equal(0, by_name["Pampa"].count)        -- zero incluído
        assert.are_equal(60.0, by_name["Amazônia"].pct)    -- 3/5 classificados
        assert.are_equal(40.0, by_name["Cerrado"].pct)
        assert.are_equal(0, by_name["Pampa"].pct)
        assert.are_equal(6, body.total_fires)              -- janela (incl oceano)
        assert.is_true(#by_name["Amazônia"].color > 0)
        assert.is_true(#by_name["Pampa"].color > 0)
        assert.are_equal("public, max-age=60", ctx.headers["Cache-Control"])
    end)

    it("rota: cache hit serve biomes:all", function()
        store["biomes:all"] = '{"biomes":[],"total_fires":42,"last_sync":null}'
        local ctx = fake_ctx({})
        biomes_routes.get_biomes(ctx)
        assert.are_equal(200, ctx.status)
        assert.are_equal(42, cjson.decode(ctx.body).total_fires)
    end)

    it("rota: cache em formato antigo de objeto vazio → recompute", function()
        store["biomes:all"] = '{"biomes":{},"total_fires":0,"last_sync":null}'
        local ctx = fake_ctx({})
        biomes_routes.get_biomes(ctx)
        local body = cjson.decode(ctx.body)
        assert.are_equal(6, #body.biomes)
        assert.are_equal(6, body.total_fires)
    end)

    it("compute_biomes_payload: last_sync vem do redis (usado pelo prewarm)", function()
        store["fires:last_sync"] = "2026-08-27T00:00:00Z"
        store["biomes:all"] = nil
        local body = cjson.decode(biomes_routes.compute_biomes_payload())
        assert.are_equal("2026-08-27T00:00:00Z", body.last_sync)
        assert.are_equal(6, #body.biomes)
        store["fires:last_sync"] = nil
    end)

    it("DB sem focos → 6 zeros e total_fires=0 (restaura o invariant ao fim)", function()
        local conn = sqlite3.open(tmp_yvy_db)
        conn:exec("DELETE FROM fire_data")
        conn:close()

        store["biomes:all"] = nil
        local ctx = fake_ctx({})
        biomes_routes.get_biomes(ctx)
        assert.are_equal(200, ctx.status)
        local body = cjson.decode(ctx.body)
        assert.are_equal(0, body.total_fires)
        assert.are_equal(6, #body.biomes)
        for _, b in ipairs(body.biomes) do
            assert.are_equal(0, b.count)
            assert.are_equal(0, b.pct)
        end

        -- Este teste esvaziou a tabela — re-semeia para não quebrar a
        -- invariant dos demais testes caso a ordem de execução mude.
        seed_fixtures()
    end)
end)

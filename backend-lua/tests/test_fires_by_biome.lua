-- test_fires_by_biome.lua — /api/fires/by-biome (plan: dashboard-enhancement, Inc 4)
--
-- Cobre o agregado por bioma persistido em $.biome (com filtro days/state),
-- o backfill de biome (iter/update/mark) e a rota (cache por days/state,
-- validação). Redis stubado; fixtures com days_ago(n) (common-mistakes #1).

local env = require("app.env")
local cjson = require("cjson")

local tmp_yvy_db = "./yvy_fires_by_biome_" .. tostring(os.time()) .. ".db"
env.set("SQLITE_PATH", tmp_yvy_db)
package.loaded["app.db"] = nil
package.loaded["app.routes.fires"] = nil
package.loaded["app.lookups.biome_lookup"] = nil

local db_mod = require("app.db")
local fires_routes = require("app.routes.fires")
local biome_lookup = require("app.lookups.biome_lookup")
local redis = require("app.redis")

dofile("tests/helpers.lua")

local written_keys = {}
local original_get, original_set = redis.get, redis.set
redis.get = function() return nil end
redis.set = function(key) written_keys[#written_keys + 1] = key end

teardown(function()
    redis.get, redis.set = original_get, original_set
end)

describe("fires by biome", function()
    setup(function()
        redis.delete("rate_limit:127.0.0.1")
        db_mod.init_db()
        biome_lookup.load_biomes()
        -- 3 focos na Amazônia (Manaus), 2 no Cerrado (Brasília), 1 no oceano
        db_mod.bulk_upsert_fires({
            { lat = -3.10, lon = -60.02, acq_date = days_ago(1), ingested_at = days_ago(1) .. "T00:00:00Z", state = "AM" },
            { lat = -3.11, lon = -60.03, acq_date = days_ago(2), ingested_at = days_ago(2) .. "T00:00:00Z", state = "AM" },
            { lat = -3.12, lon = -60.04, acq_date = days_ago(3), ingested_at = days_ago(3) .. "T00:00:00Z", state = "AM" },
            { lat = -15.79, lon = -47.90, acq_date = days_ago(1), ingested_at = days_ago(1) .. "T00:00:00Z", state = "DF" },
            { lat = -15.80, lon = -47.91, acq_date = days_ago(2), ingested_at = days_ago(2) .. "T00:00:00Z", state = "DF" },
            { lat = -20.0, lon = -30.0, acq_date = days_ago(1), ingested_at = days_ago(1) .. "T00:00:00Z", state = "" }, -- oceano
        })
        -- backfill: classifica os pontos do interior; oceano → não-classificável
        local batch = db_mod.iter_fires_for_biome_backfill(100)
        assert.are_equal(6, #batch)
        for _, row in ipairs(batch) do
            local name = biome_lookup.classify_point(row.lon, row.lat)
            if name then db_mod.update_fire_biome(row.id, name) else db_mod.mark_fire_biome_unattributable(row.id) end
        end
    end)

    teardown(function()
        db_mod.close_db()
        os.remove(tmp_yvy_db)
        os.remove(tmp_yvy_db .. "-wal")
        os.remove(tmp_yvy_db .. "-shm")
    end)

    it("db aggregation counts per biome with honest shares", function()
        local biomes, total = db_mod.get_fires_by_biome(7, nil)
        assert.are_equal(5, total)  -- oceano sem bioma fica fora
        assert.are_equal(2, #biomes)
        local by_name = {}
        for _, b in ipairs(biomes) do by_name[b.name] = b end
        assert.are_equal(3, by_name["Amazônia"].count)
        assert.are_equal(2, by_name["Cerrado"].count)
        assert.are_equal(60.0, by_name["Amazônia"].pct)
        assert.are_equal(40.0, by_name["Cerrado"].pct)
    end)

    it("db aggregation honors the state filter", function()
        local biomes, total = db_mod.get_fires_by_biome(7, "DF")
        assert.are_equal(2, total)
        assert.are_equal(1, #biomes)
        assert.are_equal("Cerrado", biomes[1].name)
        assert.are_equal(2, biomes[1].count)
    end)

    it("backfill is idempotent and marks the ocean as unattributable", function()
        -- todos os 6 já foram processados → nenhum pendente
        local remaining = db_mod.iter_fires_for_biome_backfill(100)
        assert.are_equal(0, #remaining)

        local cov = db_mod.count_fires_by_biome_present()
        assert.are_equal(6, cov.total)
        assert.are_equal(1, cov.unattributed)  -- só o oceano
    end)

    it("route returns biomes + total", function()
        local ctx = _G.fake_ctx({ days = "7" })
        fires_routes.get_by_biome(ctx)
        assert.are_equal(200, ctx.status)
        local body = cjson.decode(ctx.body)
        assert.are_equal(5, body.total)
        assert.are_equal(2, #body.biomes)
    end)

    it("route filters by state", function()
        local ctx = _G.fake_ctx({ days = "7", state = "DF" })
        fires_routes.get_by_biome(ctx)
        assert.are_equal(200, ctx.status)
        local body = cjson.decode(ctx.body)
        assert.are_equal(2, body.total)
        assert.are_equal("Cerrado", body.biomes[1].name)
    end)

    it("route rejects invalid days and state", function()
        local ctx_days = _G.fake_ctx({ days = "0" })
        fires_routes.get_by_biome(ctx_days)
        assert.are_equal(400, ctx_days.status)

        local ctx_days2 = _G.fake_ctx({ days = "999" })
        fires_routes.get_by_biome(ctx_days2)
        assert.are_equal(400, ctx_days2.status)

        local ctx_state = _G.fake_ctx({ days = "7", state = "XX" })
        fires_routes.get_by_biome(ctx_state)
        assert.are_equal(400, ctx_state.status)
        assert.are_equal("invalid state", ctx_state.body.error)
    end)

    it("route caches per (days, state)", function()
        local before = #written_keys
        local ctx = _G.fake_ctx({ days = "7" })
        fires_routes.get_by_biome(ctx)
        local ctx_df = _G.fake_ctx({ days = "7", state = "DF" })
        fires_routes.get_by_biome(ctx_df)
        local seen_all, seen_df = false, false
        for i = before + 1, #written_keys do
            if written_keys[i] == "fires:bybiome:7:all" then seen_all = true end
            if written_keys[i] == "fires:bybiome:7:DF" then seen_df = true end
        end
        assert.is_true(seen_all)
        assert.is_true(seen_df)
    end)
end)

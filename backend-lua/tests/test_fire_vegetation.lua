-- test_fire_vegetation.lua — Crossing fogo × vegetação (plan: terrabrasilis-integration, Inc 8)
--
-- Fixture: pontos PRODES conhecidos (d2024, r2014) num yvy.db temporário;
-- verifica get_fire_vegetation_context (single) e get_vegetation_context_batch.

local env = require("app.env")
local sqlite3 = require("lsqlite3")

local tmp_yvy_db = "./yvy_veg_" .. tostring(os.time()) .. ".db"
env.set("SQLITE_PATH", tmp_yvy_db)
package.loaded["app.db"] = nil
local db_mod = require("app.db")

describe("fire vegetation", function()
    setup(function()
        db_mod.init_db()
        db_mod.bulk_upsert_deforestation({
            { lat = -10.0, lon = -55.0, name = "d2024" },  -- desmatado 2024
            { lat = -12.0, lon = -57.0, name = "r2014" },  -- regeneração 2014
            { lat = -14.0, lon = -52.0, name = "7 d2007" },  -- rótulo real c/ prefixo de contagem (d)
            { lat = -16.0, lon = -50.0, name = "64 r2024" }, -- rótulo real c/ prefixo de contagem (r)
            { lat = -18.0, lon = -48.0, name = "banana" },   -- rótulo fora do padrão
        })
    end)

    teardown(function()
        db_mod.close_db()
        os.remove(tmp_yvy_db)
        os.remove(tmp_yvy_db .. "-wal")
        os.remove(tmp_yvy_db .. "-shm")
    end)

    describe("get_fire_vegetation_context", function()
        it("marks fire on a d* pixel as deforested_<year>", function()
            local ctx = db_mod.get_fire_vegetation_context(-10.0, -55.0)
            assert.are_equal("deforested_2024", ctx.status)
            assert.are_equal(2024, ctx.year)
            assert.are_equal("d2024", ctx.class_name)
        end)

        it("marks fire on an r* pixel as regrowth_<year>", function()
            local ctx = db_mod.get_fire_vegetation_context(-12.0, -57.0)
            assert.are_equal("regrowth_2014", ctx.status)
        end)

        it("marks fire far from any PRODES point as native", function()
            local ctx = db_mod.get_fire_vegetation_context(-30.0, -50.0)
            assert.are_equal("native", ctx.status)
        end)

        it("parses count-prefixed PRODES label (7 d2007)", function()
            local ctx = db_mod.get_fire_vegetation_context(-14.0, -52.0)
            assert.are_equal("deforested_2007", ctx.status)
            assert.are_equal(2007, ctx.year)
            assert.are_equal("7 d2007", ctx.class_name)
        end)

        it("parses count-prefixed PRODES label (64 r2024)", function()
            local ctx = db_mod.get_fire_vegetation_context(-16.0, -50.0)
            assert.are_equal("regrowth_2024", ctx.status)
            assert.are_equal(2024, ctx.year)
        end)

        it("does not crash on an unparseable label", function()
            local ctx = db_mod.get_fire_vegetation_context(-18.0, -48.0)
            assert.are_equal("unknown", ctx.status)
        end)
    end)

    describe("get_vegetation_context_batch", function()
        it("assigns context per fire in one batch", function()
            local fires = {
                { lat = -10.0, lon = -55.0 },  -- d2024
                { lat = -12.0, lon = -57.0 },  -- r2014
                { lat = -30.0, lon = -50.0 },  -- native
            }
            local map = db_mod.get_vegetation_context_batch(-34, 5.5, -74, -34, fires)
            assert.are_equal("deforested_2024", map[1].status)
            assert.are_equal("regrowth_2014", map[2].status)
            assert.are_equal("native", map[3].status)
        end)

        it("batch handles count-prefixed and unparseable labels without crashing", function()
            local fires = {
                { lat = -14.0, lon = -52.0 },  -- "7 d2007"  → deforested_2007
                { lat = -16.0, lon = -50.0 },  -- "64 r2024" → regrowth_2024
                { lat = -18.0, lon = -48.0 },  -- "banana"   → unknown (não derruba o lote)
            }
            local map = db_mod.get_vegetation_context_batch(-34, 5.5, -74, -34, fires)
            assert.is_table(map)
            assert.are_equal("deforested_2007", map[1].status)
            assert.are_equal("regrowth_2024", map[2].status)
            assert.are_equal("unknown", map[3].status)
        end)
    end)
end)

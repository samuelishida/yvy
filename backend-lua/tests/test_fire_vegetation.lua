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
    end)
end)

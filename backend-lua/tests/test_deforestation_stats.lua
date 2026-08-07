-- test_deforestation_stats.lua — Stats territoriais de desmatamento (plan: terrabrasilis-integration, Inc 7)
--
-- As rotas leem blobs pré-computados de lookup_data (def_stats:<tipo>:<year>).
-- Testa com fixtures: filtro por ano/uf, ordenação por área, limit, year
-- inválido → 400, e precomputed:false quando o blob não existe.

local env = require("app.env")
local sqlite3 = require("lsqlite3")

local tmp_yvy_db = "./yvy_def_stats_" .. tostring(os.time()) .. ".db"
env.set("SQLITE_PATH", tmp_yvy_db)
package.loaded["app.db"] = nil
package.loaded["app.routes.deforestation_stats"] = nil

local db_mod = require("app.db")
local ds_routes = require("app.routes.deforestation_stats")

local function fake_ctx(args)
    return {
        req = { args = args or {}, remote_addr = "127.0.0.1", headers = {} },
        status = nil, body = nil, content_type = nil, headers = {},
        json = function(self, status, data) self.status = status; self.body = data end,
        error = function(self, status, msg) self.status = status; self.body = { error = msg } end,
        send = function(self, status, body, ct) self.status = status; self.body = body; self.content_type = ct end,
        set_header = function(self, k, v) self.headers[k] = v end,
    }
end

describe("deforestation_stats", function()
    setup(function()
        db_mod.init_db()
        db_mod.set_lookup_data("def_stats:municipio:2024", {
            items = {
                { key = "1500602", nome = "Altamira", uf = "PA", area_km2 = 120.5, year = 2024 },
                { key = "1100304", nome = "Vilhena", uf = "RO", area_km2 = 95.0, year = 2024 },
                { key = "5103403", nome = "Cuiabá", uf = "MT", area_km2 = 210.0, year = 2024 },
            },
        })
        db_mod.set_lookup_data("def_stats:municipio:all", {
            items = {
                { key = "1500602", nome = "Altamira", uf = "PA", area_km2 = 900.0, year = "all" },
            },
        })
    end)

    teardown(function()
        db_mod.close_db()
        os.remove(tmp_yvy_db)
        os.remove(tmp_yvy_db .. "-wal")
        os.remove(tmp_yvy_db .. "-shm")
    end)

    describe("get_by_municipality", function()
        it("returns items sorted by area desc with uf filter and limit", function()
            local ctx = fake_ctx({ year = "2024", uf = "PA", limit = 5 })
            ds_routes.get_by_municipality(ctx)
            assert.are_equal(200, ctx.status)
            assert.is_true(ctx.body.precomputed)
            assert.are_equal(1, ctx.body.total)
            assert.are_equal("Altamira", ctx.body.items[1].nome)
            assert.are_equal(120.5, ctx.body.items[1].area_km2)
        end)

        it("aggregates all years when year=all", function()
            local ctx = fake_ctx({ year = "all" })
            ds_routes.get_by_municipality(ctx)
            assert.are_equal(200, ctx.status)
            assert.are_equal(900.0, ctx.body.items[1].area_km2)
        end)

        it("returns 400 for invalid year", function()
            local ctx = fake_ctx({ year = "1999" })
            ds_routes.get_by_municipality(ctx)
            assert.are_equal(400, ctx.status)
        end)

        it("returns precomputed:false when blob missing", function()
            local ctx = fake_ctx({ year = "2020" })
            ds_routes.get_by_municipality(ctx)
            assert.are_equal(200, ctx.status)
            assert.is_false(ctx.body.precomputed)
            assert.are_equal(0, #ctx.body.items)
        end)
    end)
end)

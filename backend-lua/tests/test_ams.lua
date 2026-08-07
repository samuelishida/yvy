-- test_ams.lua — AMS overlay (plan: terrabrasilis-integration, Inc 11)
--
-- Insere camadas AMS (fire-spreading-risk polígono + active-fire-today ponto)
-- num yvy.db temporário via SQL (mimando o writer Python) e testa
-- db.get_ams_risk/get_ams_risk_at + as rotas /api/ams/risk e /api/ams/active.

local env = require("app.env")
local sqlite3 = require("lsqlite3")
local cjson = require("cjson")

local tmp_yvy_db = "./yvy_ams_" .. tostring(os.time()) .. ".db"
env.set("SQLITE_PATH", tmp_yvy_db)
package.loaded["app.db"] = nil
package.loaded["app.routes.ams"] = nil

local db_mod = require("app.db")
local ams_routes = require("app.routes.ams")

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

describe("ams", function()
    setup(function()
        db_mod.init_db()
        local db = sqlite3.open(tmp_yvy_db)
        local stmt = db:prepare([[
            INSERT INTO ams_risk
                (view_date, viewed_at, satelite, municipio, biome, geocode, layer, risk_level,
                 min_lat, min_lon, max_lat, max_lon, geom, ingested_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        local rows = {
            -- polígono de risco em (-11..-10, -61..-60), nível ALTO
            { "2026-08-06", "2026-08-06T12:00:00Z", "GOES-16", "Vilhena", "Amazônia", "1100304",
              "fire-spreading-risk", "ALTO", -11.0, -61.0, -10.0, -60.0,
              cjson.encode({ type = "MultiPolygon", coordinates = { { { { -61, -11 }, { -60, -11 }, { -60, -10 }, { -61, -10 }, { -61, -11 } } } } }),
              "2026-08-07T00:00:00Z" },
            -- ponto ativo em (-10.5, -60.5)
            { "2026-08-06", "2026-08-06T14:00:00Z", "GOES-16", "Vilhena", "Amazônia", "1100304",
              "active-fire-today", nil, -10.5, -60.5, -10.5, -60.5,
              cjson.encode({ type = "Point", coordinates = { -60.5, -10.5 } }),
              "2026-08-07T00:00:00Z" },
        }
        for _, r in ipairs(rows) do
            stmt:reset()
            for i = 1, 14 do stmt:bind(i, r[i]) end
            stmt:step()
        end
        stmt:finalize()
        db:close()
    end)

    teardown(function()
        db_mod.close_db()
        os.remove(tmp_yvy_db)
        os.remove(tmp_yvy_db .. "-wal")
        os.remove(tmp_yvy_db .. "-shm")
    end)

    describe("db.get_ams_risk", function()
        it("returns risk polygons in the bbox", function()
            local rows = db_mod.get_ams_risk(-20, 0, -70, -50, 7)
            assert.are_equal(2, #rows)
            local layers = {}
            for _, r in ipairs(rows) do layers[r.layer] = true end
            assert.is_true(layers["fire-spreading-risk"])
            assert.is_true(layers["active-fire-today"])
        end)
    end)

    describe("db.get_ams_risk_at", function()
        it("finds the nearest risk level for a fire point", function()
            local risk = db_mod.get_ams_risk_at(-10.5, -60.5)
            assert.is_not_nil(risk)
            assert.are_equal("ALTO", risk.risk_level)
            assert.are_equal("2026-08-06", risk.view_date)
        end)

        it("returns nil far from any risk polygon", function()
            local risk = db_mod.get_ams_risk_at(-30.0, -50.0)
            assert.is_nil(risk)
        end)
    end)

    describe("routes /api/ams/*", function()
        it("GET /api/ams/risk returns only fire-spreading-risk polygons", function()
            local ctx = fake_ctx({ sw_lat = -20, ne_lat = 0, sw_lng = -70, ne_lng = -50, days = 7 })
            ams_routes.get_risk(ctx)
            assert.are_equal(200, ctx.status)
            assert.are_equal(1, ctx.body.count)
            assert.are_equal("ALTO", ctx.body.polygons[1].risk_level)
            assert.are_equal("Vilhena", ctx.body.polygons[1].municipio)
        end)

        it("GET /api/ams/active returns point features", function()
            local ctx = fake_ctx({ sw_lat = -20, ne_lat = 0, sw_lng = -70, ne_lng = -50 })
            ams_routes.get_active(ctx)
            assert.are_equal(200, ctx.status)
            assert.are_equal(1, ctx.body.count)
            assert.are_equal(-10.5, ctx.body.points[1].lat)
            assert.are_equal(-60.5, ctx.body.points[1].lon)
        end)

        it("rejects invalid bbox", function()
            local ctx = fake_ctx({ sw_lat = 0, ne_lat = -20, sw_lng = -70, ne_lng = -50 })
            ams_routes.get_risk(ctx)
            assert.are_equal(400, ctx.status)
        end)
    end)
end)

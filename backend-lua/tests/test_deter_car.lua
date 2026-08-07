-- test_deter_car.lua — Alertas DETER × CAR (plan: terrabrasilis-integration, Inc 3)
--
-- O cruzamento espacial acontece no Python (scripts/cross_deter_car.py, via
-- Shapely/geopandas — executado na VM). Este teste cobre a camada Lua que
-- consome deter_car_alerts: db.get_car_alerts, db.get_car_alert_stats e a rota
-- /api/deter/car-alerts (ctx fake, remote_addr=127.0.0.1).

local env = require("app.env")
local sqlite3 = require("lsqlite3")
local cjson = require("cjson")

local tmp_yvy_db = "./yvy_deter_car_" .. tostring(os.time()) .. ".db"
env.set("SQLITE_PATH", tmp_yvy_db)
package.loaded["app.db"] = nil
package.loaded["app.routes.deter"] = nil

local db_mod = require("app.db")
local deter_routes = require("app.routes.deter")

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

describe("deter car alerts", function()
    setup(function()
        db_mod.init_db()
        local db = sqlite3.open(tmp_yvy_db)
        local stmt = db:prepare([[
            INSERT INTO deter_car_alerts
                (cod_imovel, classname, view_date, uf, municipio, area_afetada_ha,
                 fire_count, fire_dates, severity, ingested_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        local rows = {
            -- Pass 1: DETER + fogo → maximo
            { "RO-1", "DESMATAMENTO_VEG", "2026-08-06", "RO", "Vilhena", 12.5, 3,
              '["2026-08-01","2026-08-05"]', "maximo", "2026-08-07T00:00:00Z" },
            -- Pass 1: DETER sem fogo → alto
            { "MT-1", "MINERACAO", "2026-08-05", "MT", "Cuiabá", 4.0, 0, "[]", "alto", "2026-08-07T00:00:00Z" },
            -- Pass 2: fogo sem DETER em área desmatada → medio
            { "PA-7", "FIRMS", "2026-08-04", "PA", "Altamira", 0.0, 2, '["2026-08-03","2026-08-04"]', "medio", "2026-08-07T00:00:00Z" },
            -- Pass 2: fogo sem DETER em vegetação nativa → baixo
            { "AM-3", "FIRMS", "2026-08-03", "AM", "Manaus", 0.0, 1, '["2026-08-03"]', "baixo", "2026-08-07T00:00:00Z" },
            -- fora da janela (7d)
            { "RO-9", "DEGRADACAO", "2026-06-01", "RO", "Velho", 1.0, 0, "[]", "alto", "2026-06-02T00:00:00Z" },
        }
        for _, r in ipairs(rows) do
            stmt:reset()
            for i = 1, 10 do stmt:bind(i, r[i]) end
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

    describe("db.get_car_alerts", function()
        it("returns alerts within the days window with pagination", function()
            local res = db_mod.get_car_alerts(nil, nil, nil, 7, 1, 20)
            assert.are_equal(4, res.total)
            assert.are_equal(4, #res.alerts)
            assert.are_equal(1, res.page)
        end)

        it("filters by severity", function()
            local res = db_mod.get_car_alerts(nil, nil, "maximo", 7, 1, 20)
            assert.are_equal(1, res.total)
            assert.are_equal("RO-1", res.alerts[1].cod_imovel)
            assert.are_equal("maximo", res.alerts[1].severity)
        end)

        it("filters by uf", function()
            local res = db_mod.get_car_alerts("MT", nil, nil, 7, 1, 20)
            assert.are_equal(1, res.total)
            assert.are_equal("MT-1", res.alerts[1].cod_imovel)
        end)

        it("decodes fire_dates JSON array", function()
            local res = db_mod.get_car_alerts(nil, nil, "maximo", 7, 1, 20)
            local dates = res.alerts[1].fire_dates
            assert.are_equal(2, #dates)
            assert.are_equal("2026-08-01", dates[1])
        end)

        it("orders by severity (maximo first)", function()
            local res = db_mod.get_car_alerts(nil, nil, nil, 7, 1, 20)
            assert.are_equal("maximo", res.alerts[1].severity)
            assert.are_equal("alto", res.alerts[2].severity)
            assert.are_equal("medio", res.alerts[3].severity)
            assert.are_equal("baixo", res.alerts[4].severity)
        end)

        it("paginates", function()
            local res = db_mod.get_car_alerts(nil, nil, nil, 7, 2, 2)
            assert.are_equal(4, res.total)
            assert.are_equal(2, #res.alerts)
            assert.are_equal(2, res.page)
        end)
    end)

    describe("db.get_car_alert_stats", function()
        it("counts total, by_severity, by_uf", function()
            local s = db_mod.get_car_alert_stats(7)
            assert.are_equal(4, s.total)
            local sev = {}
            for _, x in ipairs(s.by_severity) do sev[x.severity] = x.count end
            assert.are_equal(1, sev["maximo"])
            assert.are_equal(1, sev["medio"])
            assert.are_equal(1, sev["baixo"])
            local ufs = {}
            for _, x in ipairs(s.by_uf) do ufs[x.uf] = x.count end
            assert.are_equal(1, ufs["RO"])
            assert.are_equal(1, ufs["AM"])
        end)
    end)

    describe("routes /api/deter/car-alerts", function()
        it("returns paginated alerts", function()
            local ctx = fake_ctx({ days = 7, page = 1, page_size = 20 })
            deter_routes.get_car_alerts(ctx)
            assert.are_equal(200, ctx.status)
            assert.are_equal(4, ctx.body.total)
            assert.are_equal(4, #ctx.body.alerts)
        end)

        it("filters by severity query param", function()
            local ctx = fake_ctx({ days = 7, severity = "medio" })
            deter_routes.get_car_alerts(ctx)
            assert.are_equal(200, ctx.status)
            assert.are_equal(1, ctx.body.total)
            assert.are_equal("PA-7", ctx.body.alerts[1].cod_imovel)
        end)
    end)
end)

-- test_deter.lua — DETER (plan: terrabrasilis-integration, Inc 2)
--
-- Insere polígonos DETER num yvy.db temporário diretamente via SQL (mimando o
-- writer Python: geom como JSON TEXT) + linhas em deter_alerts, e testa
-- db.get_deter_polygons/get_deter_stats/get_deter_alerts + as rotas
-- /api/deter/polygons e /api/deter/stats (ctx fake, remote_addr=127.0.0.1).

local env = require("app.env")
local sqlite3 = require("lsqlite3")
local cjson = require("cjson")

local tmp_yvy_db = "./yvy_deter_" .. tostring(os.time()) .. ".db"
env.set("SQLITE_PATH", tmp_yvy_db)
package.loaded["app.db"] = nil
package.loaded["app.routes.deter"] = nil

local db_mod = require("app.db")
local deter_routes = require("app.routes.deter")
local redis = require("app.redis")

dofile("tests/helpers.lua")

-- Rotas passam a cachear em Redis (plan: dashboard-enhancement, Inc 5) —
-- stub get/set para não depender de Redis vivo. get→nil = miss sempre.
local written_keys = {}
local original_get, original_set = redis.get, redis.set
redis.get = function() return nil end
redis.set = function(key) written_keys[#written_keys + 1] = key end

teardown(function()
    redis.get, redis.set = original_get, original_set
end)

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

-- Um MultiPolygon simples no formato GeoJSON (JSON TEXT, como o writer Python).
local function poly_geojson(min_lon, min_lat, max_lon, max_lat)
    return cjson.encode({
        type = "MultiPolygon",
        coordinates = { { { { min_lon, min_lat }, { max_lon, min_lat }, { max_lon, max_lat }, { min_lon, max_lat }, { min_lon, min_lat } } } },
    })
end

describe("deter", function()
    setup(function()
        db_mod.init_db()
        local db = sqlite3.open(tmp_yvy_db)
        local sql = [[
            INSERT INTO deter_polygons
                (classname, view_date, uf, municipality, mun_geocod, area_km2, uc,
                 areauckm, areamunkm, publish_month, sensor, satellite,
                 min_lat, min_lon, max_lat, max_lon, geom, ingested_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]]
        local stmt = db:prepare(sql)
        local rows = {
            -- dentro do bbox de teste (lat -20..0, lon -60..-40)
            { "DESMATAMENTO_VEG", days_ago(1), "RO", "Vilhena", "1100304", 5.0, "UC A", 1.0, 3.0, string.sub(days_ago(1), 1, 7), "VIIRS", "S-NPP",
              -11.0, -61.0, -10.0, -60.0, poly_geojson(-61, -11, -60, -10), os.date("!%Y-%m-%dT00:00:00Z", os.time()) },
            { "MINERACAO", days_ago(1), "RO", "Vilhena", "1100304", 3.0, nil, nil, nil, string.sub(days_ago(1), 1, 7), "VIIRS", "S-NPP",
              -12.0, -60.0, -11.0, -59.0, poly_geojson(-60, -12, -59, -11), os.date("!%Y-%m-%dT00:00:00Z", os.time()) },
            -- fora do bbox (lat/south bem abaixo)
            { "DEGRADACAO", days_ago(2), "MT", "Cuiabá", "5103403", 2.0, nil, nil, nil, string.sub(days_ago(2), 1, 7), "VIIRS", "S-NPP",
              -25.0, -60.0, -24.0, -59.0, poly_geojson(-60, -25, -59, -24), os.date("!%Y-%m-%dT00:00:00Z", os.time()) },
        }
        for _, r in ipairs(rows) do
            for i = 1, #r do
                if r[i] == nil then r[i] = "" end
            end
            stmt:reset()
            for i = 1, 18 do stmt:bind(i, r[i]) end
            stmt:step()
        end
        stmt:finalize()
        db:close()

        -- deter_alerts (histórico agregado)
        local db2 = sqlite3.open(tmp_yvy_db)
        local ins = db2:prepare([[
            INSERT INTO deter_alerts (mun_geocod, municipality, classname, view_date, area_km2, uf, ingested_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        ]])
        local alerts = {
            { "1100304", "Vilhena", "DESMATAMENTO_VEG", days_ago(1), 8.0, "RO", os.date("!%Y-%m-%dT00:00:00Z", os.time()) },
            { "1100304", "Vilhena", "MINERACAO", days_ago(1), 3.0, "RO", os.date("!%Y-%m-%dT00:00:00Z", os.time()) },
            { "5103403", "Cuiabá", "DEGRADACAO", days_ago(120), 42.0, "MT", days_ago(120) .. "T00:00:00Z" }, -- fora da janela de 30d
        }
        for _, a in ipairs(alerts) do
            ins:reset()
            for i = 1, 7 do ins:bind(i, a[i]) end
            ins:step()
        end
        ins:finalize()
        db2:close()

        -- deter_car_alerts (para get_car_alert_stats / rota car-alert-stats)
        local db3 = sqlite3.open(tmp_yvy_db)
        local car_ins = db3:prepare([[
            INSERT INTO deter_car_alerts
                (cod_imovel, classname, view_date, uf, municipio, area_afetada_ha,
                 fire_count, fire_dates, severity, ingested_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        local car_rows = {
            { "RO-0001", "DESMATAMENTO_VEG", days_ago(1), "RO", "Vilhena", 12.0, 3, cjson.encode({"a","b","c"}), "alto", os.date("!%Y-%m-%dT00:00:00Z", os.time()) },
            { "RO-0002", "MINERACAO", days_ago(1), "RO", "Vilhena", 4.0, 1, cjson.encode({"a"}), "baixo", os.date("!%Y-%m-%dT00:00:00Z", os.time()) },
            { "MT-0001", "DEGRADACAO", days_ago(2), "MT", "Cuiabá", 30.0, 5, cjson.encode({"a","b","c","d","e"}), "maximo", os.date("!%Y-%m-%dT00:00:00Z", os.time()) },
        }
        for _, c in ipairs(car_rows) do
            car_ins:reset()
            for i = 1, 10 do car_ins:bind(i, c[i]) end
            car_ins:step()
        end
        car_ins:finalize()
        db3:close()
    end)

    teardown(function()
        db_mod.close_db()
        os.remove(tmp_yvy_db)
        os.remove(tmp_yvy_db .. "-wal")
        os.remove(tmp_yvy_db .. "-shm")
    end)

    describe("db.get_deter_polygons", function()
        it("returns polygons overlapping the bbox within the day window", function()
            local polys = db_mod.get_deter_polygons(-20, 0, -60, -40, 30, 100)
            assert.are_equal(2, #polys)  -- DEGRADACAO fora do bbox fica de fora
            local has_veg, has_min = false, false
            for _, p in ipairs(polys) do
                if p.classname == "DESMATAMENTO_VEG" then
                    has_veg = true
                    assert.are_equal("RO", p.uf)
                    assert.are_equal(5.0, p.area_km2)
                    assert.is_not_nil(p.geom)  -- geom decodificada
                    assert.is_not_nil(p.bbox)
                elseif p.classname == "MINERACAO" then
                    has_min = true
                end
            end
            assert.is_true(has_veg and has_min)
        end)

        it("applies the days filter", function()
            -- janela de 1 dia inclui days_ago(1) mas não days_ago(2)
            local polys = db_mod.get_deter_polygons(-20, 0, -60, -40, 1, 100)
            for _, p in ipairs(polys) do
                assert.are_equal(days_ago(1), p.view_date)
            end
        end)
    end)

    describe("db.get_deter_stats", function()
        it("aggregates total, by_class, by_uf, by_day, by_municipality", function()
            local s = db_mod.get_deter_stats(30)
            -- total soma TODOS os polígonos na janela de 30d (sem filtro de
            -- bbox): 5 + 3 + 2 = 10
            assert.is_true(math.abs(s.total_km2 - 10.0) < 0.001)
            local names = {}
            for _, c in ipairs(s.by_class) do names[#names + 1] = c.name end
            assert.is_true(names[1] == "DESMATAMENTO_VEG" or names[1] == "DEGRADACAO")
            assert.is_true(#s.by_uf >= 1)
            assert.is_true(#s.by_day >= 1)
            assert.is_true(#s.by_municipality >= 1)
        end)
    end)

    describe("db.get_deter_alerts", function()
        it("filters by days window", function()
            local rows = db_mod.get_deter_alerts(nil, nil, 30)
            assert.are_equal(2, #rows)  -- a de days_ago(120) fica fora
        end)

        it("filters by classname", function()
            local rows = db_mod.get_deter_alerts(nil, "MINERACAO", 30)
            assert.are_equal(1, #rows)
            assert.are_equal("MINERACAO", rows[1].classname)
        end)
    end)

    describe("routes /api/deter/*", function()
        it("GET /api/deter/polygons returns bbox polygons", function()
            local ctx = fake_ctx({ sw_lat = -20, ne_lat = 0, sw_lng = -60, ne_lng = -40, days = 30 })
            deter_routes.get_polygons(ctx)
            assert.are_equal(200, ctx.status)
            assert.are_equal(2, ctx.body.count)
        end)

        it("GET /api/deter/polygons rejects invalid bbox", function()
            local ctx = fake_ctx({ sw_lat = 0, ne_lat = -20, sw_lng = -60, ne_lng = -40 })
            deter_routes.get_polygons(ctx)
            assert.are_equal(400, ctx.status)
        end)

        it("GET /api/deter/polygons rejects invalid limit (Inc 10)", function()
            local ctx = fake_ctx({ sw_lat = -20, ne_lat = 0, sw_lng = -60, ne_lng = -40, limit = -1 })
            deter_routes.get_polygons(ctx)
            assert.are_equal(400, ctx.status)
            assert.are_equal("invalid limit", ctx.body.error)
        end)

        it("GET /api/deter/stats returns aggregate", function()
            local ctx = fake_ctx({ days = 30 })
            deter_routes.get_stats(ctx)
            assert.are_equal(200, ctx.status)
            local body = cjson.decode(ctx.body)  -- rota agora envia via ctx:send
            assert.is_not_nil(body.total_km2)
            assert.is_not_nil(body.by_municipality)
        end)

        it("GET /api/deter/stats filters by uf (Inc 5)", function()
            local ctx = fake_ctx({ days = 30, uf = "RO" })
            deter_routes.get_stats(ctx)
            assert.are_equal(200, ctx.status)
            local body = cjson.decode(ctx.body)
            assert.is_true(math.abs(body.total_km2 - 8.0) < 0.001)  -- 5 + 3 (RO)
            assert.are_equal(1, #body.by_uf)
            assert.are_equal("RO", body.by_uf[1].uf)
            assert.is_true(math.abs(body.by_uf[1].km2 - body.total_km2) < 0.001)
        end)

        it("GET /api/deter/stats rejects invalid uf (Inc 5)", function()
            local ctx = fake_ctx({ days = 30, uf = "XX" })
            deter_routes.get_stats(ctx)
            assert.are_equal(400, ctx.status)
            assert.are_equal("invalid uf", ctx.body.error)
        end)

        it("GET /api/deter/stats caches per (days, uf) (Inc 5)", function()
            local before = #written_keys
            local ctx = fake_ctx({ days = 30 })
            deter_routes.get_stats(ctx)
            local ctx_ro = fake_ctx({ days = 30, uf = "RO" })
            deter_routes.get_stats(ctx_ro)
            assert.are_equal(200, ctx_ro.status)
            local seen_all, seen_ro = false, false
            for i = before + 1, #written_keys do
                if written_keys[i] == "deter:stats:30:all" then seen_all = true end
                if written_keys[i] == "deter:stats:30:RO" then seen_ro = true end
            end
            assert.is_true(seen_all)
            assert.is_true(seen_ro)
        end)

        it("GET /api/deter/car-alert-stats returns + filters by uf (Inc 5)", function()
            local ctx = fake_ctx({ days = 7 })
            deter_routes.get_car_alert_stats(ctx)
            assert.are_equal(200, ctx.status)
            local body = cjson.decode(ctx.body)
            assert.are_equal(3, body.total)

            local ctx_ro = fake_ctx({ days = 7, uf = "RO" })
            deter_routes.get_car_alert_stats(ctx_ro)
            local body_ro = cjson.decode(ctx_ro.body)
            assert.are_equal(2, body_ro.total)
            assert.are_equal(1, #body_ro.by_uf)

            local ctx_bad = fake_ctx({ days = 7, uf = "XX" })
            deter_routes.get_car_alert_stats(ctx_bad)
            assert.are_equal(400, ctx_bad.status)
            assert.are_equal("invalid uf", ctx_bad.body.error)
        end)
    end)
end)

-- test_car_prodes.lua — Verificação PRODES por recibo CAR (plan: terrabrasilis-integration, Inc 12)
--
-- Cria um car.db temporário (fixture) + um yvy.db temporário com pontos PRODES
-- conhecidos (d*/r* no data.name), re-require dos módulos apontando para eles e
-- testa: car_lookup.get_by_cod_imovel, db.get_deforestation_in_bbox e a rota
-- /api/car/prodes (ctx fake, remote_addr=127.0.0.1 → auth passa; Redis down → sem cache).

local env = require("app.env")
local sqlite3 = require("lsqlite3")
local cjson = require("cjson")

local tmp_car_db = "./yvy_car_prodes_" .. tostring(os.time()) .. ".db"
local tmp_yvy_db = "./yvy_prodes_" .. tostring(os.time()) .. ".db"
local FIXTURE = "./tests/fixtures/car_sample.json"

env.set("CAR_DB_PATH", tmp_car_db)
env.set("SQLITE_PATH", tmp_yvy_db)
package.loaded["app.lookups.car_lookup"] = nil
package.loaded["app.routes.car"] = nil
package.loaded["app.db"] = nil

local car_import = require("app.car_import")
local car_lookup = require("app.lookups.car_lookup")
local car_routes = require("app.routes.car")
local db_mod = require("app.db")
local redis = require("app.redis")

local empty_car_routes = nil

-- Fake ctx espelhando a API de ctx (server.lua:290-315).
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

describe("car prodes", function()
    setup(function()
        -- car.db via mesmo ETL de produção
        local conn = sqlite3.open(tmp_car_db)
        conn:exec("PRAGMA journal_mode=WAL")
        car_import.create_schema(conn)
        local n = car_import.import_file(conn, FIXTURE)
        assert.are_equal(3, n)
        conn:close()

        -- yvy.db (cria deforestation_data)
        db_mod.init_db()

        -- Pontos PRODES: 2 d* + 1 r* dentro do RO-1 (lat -11..-10, lon -61..-60),
        -- 1 d* fora de qualquer polígono.
        db_mod.bulk_upsert_deforestation({
            { lat = -10.5, lon = -60.5, name = "d2020" },
            { lat = -10.3, lon = -60.2, name = "d2024" },
            { lat = -10.1, lon = -60.1, name = "r2014" },
            { lat = -30.0, lon = -50.0, name = "d2024" },
        })

        car_lookup.load_car()

        -- Flush any Redis cache left by previous runs — the fixture cod_imovel
        -- keys are stable across runs, so a stale cache would serve 0.2 / true
        -- instead of a fresh computation.
        redis.delete("car:prodes:RO-1")
        redis.delete("car:prodes:RO-2")
        redis.delete("car:prodes:MT-1")
    end)

    teardown(function()
        -- Inc 12: limpa as chaves Redis também em falha (não vaza car:prodes:*).
        redis.delete("car:prodes:RO-1")
        redis.delete("car:prodes:RO-2")
        redis.delete("car:prodes:MT-1")
        db_mod.close_db()
        os.remove(tmp_car_db)
        os.remove(tmp_car_db .. "-wal")
        os.remove(tmp_car_db .. "-shm")
        os.remove(tmp_yvy_db)
        os.remove(tmp_yvy_db .. "-wal")
        os.remove(tmp_yvy_db .. "-shm")
    end)

    describe("car_lookup.get_by_cod_imovel", function()
        it("looks up by receipt with uppercase normalization", function()
            local prop = car_lookup.get_by_cod_imovel("ro-1")
            assert.is_not_nil(prop)
            assert.are_equal("RO-1", prop.id)
            assert.are_equal("RO", prop.uf)
            assert.are_equal(100.0, prop.area_ha)
            assert.is_not_nil(prop.bbox)
            assert.is_true(prop.bbox.min_lon <= -61 and prop.bbox.max_lon >= -60)
            assert.is_true(prop.bbox.min_lat <= -11 and prop.bbox.max_lat >= -10)
        end)

        it("returns nil for unknown receipt", function()
            assert.is_nil(car_lookup.get_by_cod_imovel("RO-999"))
        end)
    end)

    describe("db.get_deforestation_in_bbox", function()
        it("decodes class/year/type from data.name", function()
            local pts = db_mod.get_deforestation_in_bbox(-11, -10, -61, -60)
            assert.are_equal(3, #pts)
            local has_d2020, has_d2024, has_r2014 = false, false, false
            for _, p in ipairs(pts) do
                if p.class_name == "d2020" then has_d2020 = true end
                if p.class_name == "d2024" then has_d2024 = true end
                if p.class_name == "r2014" then has_r2014 = true end
            end
            assert.is_true(has_d2020 and has_d2024 and has_r2014)
        end)
    end)

    describe("routes /api/car/prodes", function()
        it("returns PRODES status for a property with deforestation", function()
            local ctx = fake_ctx({ cod_imovel = "RO-1" })
            car_routes.get_prodes_status(ctx)
            assert.are_equal(200, ctx.status)
            local data = ctx.body.data
            assert.is_true(data.found)
            assert.is_true(data.has_prodes)
            assert.is_true(math.abs(data.prodes_area_ha - 0.18) < 0.001)  -- 2 pixels * 0.09 ha
            assert.is_true(data.regrowth)
            assert.are_equal(2, #data.years)
            assert.are_equal(2020, data.years[1])
            assert.are_equal(2024, data.years[2])
            assert.is_false(data.cached)
        end)

        it("counts only d* for has_prodes (regrowth separate)", function()
            -- MT-1 (lat -13..-12, lon -55..-54) não contém nenhum ponto PRODES
            -- da fixture → has_prodes false. (RO-2 contém RO-1 na fixture — não usar.)
            local ctx = fake_ctx({ cod_imovel = "MT-1" })
            car_routes.get_prodes_status(ctx)
            assert.are_equal(200, ctx.status)
            assert.is_false(ctx.body.data.has_prodes)
        end)

        it("unknown receipt → 200 + found:false + reason:not_found", function()
            local ctx = fake_ctx({ cod_imovel = "RO-999" })
            car_routes.get_prodes_status(ctx)
            assert.are_equal(200, ctx.status)
            assert.is_false(ctx.body.found)
            assert.are_equal("not_found", ctx.body.reason)
        end)

        it("corrupt cached payload → fresh query (no 500)", function()
            redis.set("car:prodes:RO-1", "not-json{{{")
            local ctx = fake_ctx({ cod_imovel = "RO-1" })
            car_routes.get_prodes_status(ctx)
            assert.are_equal(200, ctx.status)
            assert.is_true(ctx.body.ok)
            assert.is_false(ctx.body.cached)  -- payload corrompido tratado como miss
            assert.is_true(ctx.body.data.found)
            assert.is_true(math.abs(ctx.body.data.prodes_area_ha - 0.18) < 0.001)
        end)

        it("returns 400 when cod_imovel missing", function()
            local ctx = fake_ctx({})
            car_routes.get_prodes_status(ctx)
            assert.are_equal(400, ctx.status)
        end)
    end)
end)

-- MUST-FIX 2 (plan terrabrasilis-fixes): CAR não ingerido ≠ recibo inexistente.
-- Com car.db vazio, is_loaded() == false → 200 + reason:car_unavailable + note
-- (não é um 404, e o reason não é "not_found"). Roda depois do describe principal
-- para não atrapalhar o car.db da fixture (re-require aponta p/ o db vazio).
describe("car prodes: CAR não ingerido (car.db vazio)", function()
    local empty_car_db = "./yvy_car_empty_" .. tostring(os.time()) .. ".db"

    setup(function()
        -- car.db VAZIO (schema sem imóveis) → is_loaded() false
        local conn = sqlite3.open(empty_car_db)
        conn:exec("PRAGMA journal_mode=WAL")
        car_import.create_schema(conn)
        conn:close()

        env.set("CAR_DB_PATH", empty_car_db)
        package.loaded["app.lookups.car_lookup"] = nil
        package.loaded["app.routes.car"] = nil
        empty_car_routes = require("app.routes.car")
        require("app.lookups.car_lookup").load_car()

        -- Redis é compartilhado/live neste arquivo: o describe principal já
        -- cacheou RO-1/RO-2/MT-1 — sem flush, a rota serviria o cache e nunca
        -- chegaria no ramo car_unavailable.
        redis.delete("car:prodes:RO-1")
        redis.delete("car:prodes:RO-2")
        redis.delete("car:prodes:MT-1")
    end)

    teardown(function()
        os.remove(empty_car_db)
        os.remove(empty_car_db .. "-wal")
        os.remove(empty_car_db .. "-shm")
    end)

    it("receipt com CAR não ingerido → 200 + reason:car_unavailable + note", function()
        local ctx = fake_ctx({ cod_imovel = "RO-1" })
        empty_car_routes.get_prodes_status(ctx)
        assert.are_equal(200, ctx.status)
        assert.is_false(ctx.body.found)
        assert.are_equal("car_unavailable", ctx.body.reason)
        assert.are_equal("CAR unavailable", ctx.body.note)
    end)
end)

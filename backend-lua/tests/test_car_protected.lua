-- test_car_protected.lua — Sobreposição CAR × UC/TI (plan: protected-area-crossing, Inc 1)
--
-- car.db temporário (fixture car_sample.json) + yvy.db temporário com lookup_data
-- de UC/TI (map-shape, mesmo formato dos arquivos de produção), re-require dos
-- módulos apontando para eles e teste da rota /api/car/protected-overlap:
-- status suspeito/ok/indeterminado, not_found e o caminho de cache Redis.
--
-- Redis: 127.0.0.1 é isento de rate-limit (is_private_ip) e o auth confia em
-- remote_addr=127.0.0.1 → as chamadas passam sem tocar no rate limiter. As chaves
-- de cache gravadas são limpas no teardown (common-mistakes #2).

local env = require("app.env")
local sqlite3 = require("lsqlite3")
local cjson = require("cjson")

dofile("tests/helpers.lua")

local tmp_car_db = "./yvy_car_protected_" .. tostring(os.time()) .. ".db"
local tmp_yvy_db = "./yvy_protected_" .. tostring(os.time()) .. ".db"
local FIXTURE = "./tests/fixtures/car_sample.json"

env.set("CAR_DB_PATH", tmp_car_db)
env.set("SQLITE_PATH", tmp_yvy_db)
package.loaded["app.lookups.car_lookup"] = nil
package.loaded["app.lookups.conservation_units_lookup"] = nil
package.loaded["app.lookups.indigenous_lands_lookup"] = nil
package.loaded["app.routes.car"] = nil
package.loaded["app.db"] = nil

local car_import = require("app.car_import")
local db_mod = require("app.db")
local car_routes = require("app.routes.car")
local redis = require("app.redis")

-- Fixtures em map-shape (mesmo formato dos arquivos conservação/indígenas):
-- RESEX Teste cobre RO-1 (lat -11..-10, lon -61..-60); Terra Teste cobre RO-2
-- (lat -11.5..-9.5, lon -61.5..-59.5). MT-1 fica fora de tudo.
local UC_FIXTURE = {
    ["RESEX Teste"] = {
        rings = { { { -61, -11 }, { -60, -11 }, { -60, -10 }, { -61, -10 }, { -61, -11 } } },
        category = "RESEX",
        full_name = "Reserva Extrativista Teste",
    },
}
local TI_FIXTURE = {
    ["Terra Teste"] = {
        rings = { { { -61.5, -11.5 }, { -59.5, -11.5 }, { -59.5, -9.5 }, { -61.5, -9.5 }, { -61.5, -11.5 } } },
    },
}

local function call_route(cod)
    local ctx = fake_ctx({ cod_imovel = cod })
    car_routes.get_protected_overlap(ctx)
    return ctx
end

describe("car protected overlap", function()
    setup(function()
        -- car.db via mesmo ETL de produção
        local conn = sqlite3.open(tmp_car_db)
        conn:exec("PRAGMA journal_mode=WAL")
        car_import.create_schema(conn)
        local n = car_import.import_file(conn, FIXTURE)
        assert.are_equal(3, n)
        conn:close()

        -- yvy.db com lookup_data de UC/TI (o lookup lê do DB primeiro)
        db_mod.init_db()
        db_mod.set_lookup_data("conservation_units", UC_FIXTURE)
        db_mod.set_lookup_data("indigenous_lands", TI_FIXTURE)

        redis.delete("rate_limit:127.0.0.1")
    end)

    teardown(function()
        redis.delete("car:protected:RO-1")
        redis.delete("car:protected:RO-2")
        redis.delete("car:protected:MT-1")
        for _, f in ipairs({ tmp_car_db, tmp_car_db .. "-wal", tmp_car_db .. "-shm",
                             tmp_yvy_db, tmp_yvy_db .. "-wal", tmp_yvy_db .. "-shm" }) do
            os.remove(f)
        end
    end)

    it("flags a property fully inside a UC as suspeito", function()
        local ctx = call_route("RO-1")
        assert.are_equal(200, ctx.status)
        local data = ctx.body.data
        assert.is_true(data.found)
        assert.are_equal("suspeito", data.status)
        assert.is_true(data.sampled > 0, "sampled should be > 0")
        local hit
        for _, o in ipairs(data.overlaps) do
            if o.type == "uc" and o.name == "RESEX Teste" then hit = o end
        end
        assert.is_not_nil(hit)
        assert.is_true(hit.overlap_pct >= 99, "expected >=99, got " .. tostring(hit.overlap_pct))
        assert.are_equal("RESEX", hit.category)
    end)

    it("flags a property fully inside a TI as suspeito", function()
        local ctx = call_route("RO-2")
        assert.are_equal(200, ctx.status)
        local data = ctx.body.data
        assert.is_true(data.found)
        assert.are_equal("suspeito", data.status)
        local hit
        for _, o in ipairs(data.overlaps) do
            if o.type == "ti" and o.name == "Terra Teste" then hit = o end
        end
        assert.is_not_nil(hit)
        assert.is_true(hit.overlap_pct >= 99, "expected >=99, got " .. tostring(hit.overlap_pct))
    end)

    it("returns ok with no overlaps for a property outside", function()
        local ctx = call_route("MT-1")
        assert.are_equal(200, ctx.status)
        local data = ctx.body.data
        assert.is_true(data.found)
        assert.are_equal("ok", data.status)
        assert.are_equal(0, #data.overlaps)
    end)

    it("returns not_found for unknown cod", function()
        local ctx = call_route("XX-999")
        assert.are_equal(200, ctx.status)
        assert.is_false(ctx.body.found)
        assert.are_equal("not_found", ctx.body.reason)
    end)

    it("serves from Redis cache on the decode-guard path", function()
        -- Stub de redis.get (padrão test_fires_routes): payload pré-encodeado
        -- retorna cached:true sem recomputar.
        local orig_get = redis.get
        redis.get = function(key)
            if key == "car:protected:MT-1" then
                return cjson.encode({ cod_imovel = "MT-1", found = true, status = "ok", overlaps = {} })
            end
            return nil
        end
        local ctx = call_route("MT-1")
        redis.get = orig_get
        assert.are_equal(200, ctx.status)
        assert.is_true(ctx.body.cached)
        assert.are_equal("ok", ctx.body.data.status)
    end)
end)

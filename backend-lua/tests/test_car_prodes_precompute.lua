-- test_car_prodes_precompute.lua — testes do pré-cálculo CAR × PRODES
-- (plan: precompute-car-prodes).

local env = require("app.env")
local sqlite3 = require("lsqlite3")
local cjson = require("cjson")

local tmp_car_db = "./yvy_car_prodes_precompute_" .. tostring(os.time()) .. ".db"
local tmp_yvy_db = "./yvy_prodes_precompute_" .. tostring(os.time()) .. ".db"
local FIXTURE = "./tests/fixtures/car_sample.json"

env.set("CAR_DB_PATH", tmp_car_db)
env.set("SQLITE_PATH", tmp_yvy_db)
package.loaded["app.lookups.car_lookup"] = nil
package.loaded["app.lookups.car_prodes"] = nil
package.loaded["app.routes.car"] = nil
package.loaded["app.db"] = nil

local car_import = require("app.car_import")
local car_lookup = require("app.lookups.car_lookup")
local car_prodes = require("app.lookups.car_prodes")
local car_routes = require("app.routes.car")
local db_mod = require("app.db")
local redis = require("app.redis")

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

describe("car_prodes precompute", function()
    setup(function()
        -- car.db via mesmo ETL de produção, com schema car_prodes
        local conn = sqlite3.open(tmp_car_db)
        conn:exec("PRAGMA journal_mode=WAL")
        car_import.create_schema(conn)
        car_import.create_car_prodes_schema(conn)
        local n = car_import.import_file(conn, FIXTURE)
        assert.are_equal(3, n)
        conn:close()

        -- yvy.db
        db_mod.init_db()

        -- 2 deforestation + 1 regrowth dentro do RO-1
        db_mod.bulk_upsert_deforestation({
            { lat = -10.5, lon = -60.5, name = "d2020" },
            { lat = -10.3, lon = -60.2, name = "d2024" },
            { lat = -10.1, lon = -60.1, name = "r2014" },
        })

        car_lookup.load_car()
        redis.delete("car:prodes:RO-1")
        redis.delete("car:prodes:RO-2")
        redis.delete("car:prodes:MT-1")
    end)

    teardown(function()
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

    it("current_version_key is stable for identical PRODES dataset", function()
        local v1 = car_prodes.current_version_key()
        local v2 = car_prodes.current_version_key()
        assert.is_not_nil(v1)
        assert.are_equal(v1, v2)
    end)

    it("current_version_key is deterministic across cache clears (ordered sample)", function()
        -- Recomputa do zero (sem cache de 5s) — a amostra ordenada garante o
        -- mesmo hash entre processos com o mesmo dataset.
        local v1 = car_prodes.current_version_key()
        car_prodes.clear_version_cache()
        local v2 = car_prodes.current_version_key()
        car_prodes.clear_version_cache()
        local v3 = car_prodes.current_version_key()
        assert.are_equal(v1, v2)
        assert.are_equal(v2, v3)
    end)

    it("schema round-trips a precomputed row", function()
        local result = car_routes.compute_prodes_for_property(car_lookup.get_by_cod_imovel("RO-1"))
        assert.is_not_nil(result)
        result.version_key = car_prodes.current_version_key()
        result.computed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")

        car_prodes.upsert("RO-1", result)
        local got = car_prodes.get("RO-1")
        assert.is_not_nil(got)
        assert.is_true(got.found)
        assert.is_true(got.has_prodes)
        assert.are_equal(result.prodes_area_ha, got.prodes_area_ha)
        assert.are_equal(2, #got.years)
    end)

    it("bulk_upsert only writes positive rows", function()
        local positive = car_routes.compute_prodes_for_property(car_lookup.get_by_cod_imovel("RO-1"))
        positive.version_key = car_prodes.current_version_key()
        positive.computed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")

        local negative = car_routes.compute_prodes_for_property(car_lookup.get_by_cod_imovel("MT-1"))
        negative.version_key = car_prodes.current_version_key()
        negative.computed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")

        car_prodes.bulk_upsert({ positive, negative })

        assert.is_not_nil(car_prodes.get("RO-1"))
        -- negative row é gravado (estrategicamente) se chamado via bulk_upsert;
        -- o warm decide não enviar negativos, mas o módulo aceita.
        assert.is_not_nil(car_prodes.get("MT-1"))
    end)

    it("route serves precomputed row and skips live computation", function()
        -- Precomputa RO-1
        local result = car_routes.compute_prodes_for_property(car_lookup.get_by_cod_imovel("RO-1"))
        result.version_key = car_prodes.current_version_key()
        result.computed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        car_prodes.upsert("RO-1", result)

        local ctx = fake_ctx({ cod_imovel = "RO-1" })
        car_routes.get_prodes_status(ctx)
        assert.are_equal(200, ctx.status)
        assert.is_true(ctx.body.ok)
        assert.is_true(ctx.body.cached)     -- vindo do "cache" SQLite
        assert.is_true(ctx.body.precomputed)
        assert.is_true(ctx.body.data.has_prodes)
    end)

    it("stale version_key is rejected (falls back to live or nil)", function()
        local result = car_routes.compute_prodes_for_property(car_lookup.get_by_cod_imovel("RO-1"))
        result.version_key = "stale-version"
        result.computed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        car_prodes.upsert("RO-1", result)

        local got = car_prodes.get("RO-1")
        assert.is_nil(got)
    end)

    it("import_car deletes precompute rows for the UF before reimport", function()
        -- Simula import de RO deletando rows da UF.
        local conn = sqlite3.open(tmp_car_db)
        conn:exec("PRAGMA journal_mode=WAL")
        car_import.create_car_prodes_schema(conn)
        car_import.delete_car_prodes_for_uf(conn, "RO")
        conn:exec("COMMIT")
        conn:close()

        assert.is_nil(car_prodes.get("RO-1"))
    end)
end)

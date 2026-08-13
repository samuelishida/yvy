-- test_car_geometry.lua — rota /api/car/geometry (plan: car-highlight, Inc 3)
--
-- Constrói um car.db temporário (fixture car_sample.json, 3 imóveis), aponta
-- CAR_DB_PATH para ele, re-require dos módulos e testa o handler get_geometry
-- com um ctx fake (remote_addr=127.0.0.1 → auth passa; rate_limit com Redis
-- down → não limita). A rota não usa Redis, então não há risco de vazamento.
--
-- Nota: o bbox retornado vem do car_rtree quando populado; se o fixture não
-- tiver rtree, cai no fallback geom_bbox (varredura das coordenadas). O
-- car_import cria o rtree, então este teste exercita o caminho indexado.

local env = require("app.env")
local sqlite3 = require("lsqlite3")
local cjson = require("cjson")

local tmp_car_db = "./yvy_car_geometry_" .. tostring(os.time()) .. ".db"
local FIXTURE = "./tests/fixtures/car_sample.json"

-- Env ANTES de carregar módulos que cacheiam paths no load.
env.set("CAR_DB_PATH", tmp_car_db)
package.loaded["app.lookups.car_lookup"] = nil
package.loaded["app.routes.car"] = nil

local car_import = require("app.car_import")
local car_routes = require("app.routes.car")

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

local build_ok, build_err = pcall(function()
    local conn = sqlite3.open(tmp_car_db)
    conn:exec("PRAGMA journal_mode=WAL")
    car_import.create_schema(conn)
    local n = car_import.import_file(conn, FIXTURE)
    if n ~= 3 then error("fixture should insert 3 imóveis, got " .. tostring(n)) end
    conn:close()
end)

describe("car geometry route", function()
    setup(function()
        if not build_ok then error("fixture build failed: " .. tostring(build_err)) end
    end)

    teardown(function()
        for _, p in ipairs({ tmp_car_db, tmp_car_db .. "-wal", tmp_car_db .. "-shm" }) do
            os.remove(p)
        end
    end)

    describe("/api/car/geometry", function()
        it("imóvel existente → found=true com geom (Polygon) e bbox válido", function()
            local ctx = fake_ctx({ cod_imovel = "MT-1" })
            car_routes.get_geometry(ctx)
            assert.are_equal(200, ctx.status)
            assert.is_true(ctx.body.found)
            assert.are_equal("MT-1", ctx.body.cod_imovel)
            -- geom é texto GeoJSON decodificável com type Polygon
            assert.is_string(ctx.body.geom)
            assert.is_true(#ctx.body.geom > 0)
            local ok, geom = pcall(cjson.decode, ctx.body.geom)
            assert.is_true(ok, "geom deve ser JSON válido")
            assert.are_equal("Polygon", geom.type)
            -- bbox com as 4 chaves e ordem correta
            local b = ctx.body.bbox
            assert.is_not_nil(b)
            assert.is_true(b.min_lon < b.max_lon)
            assert.is_true(b.min_lat < b.max_lat)
        end)

        it("cod_imovel inexistente → found=false, reason=not_found (status 200)", function()
            local ctx = fake_ctx({ cod_imovel = "XX-9999" })
            car_routes.get_geometry(ctx)
            assert.are_equal(200, ctx.status)
            assert.is_false(ctx.body.found)
            assert.are_equal("not_found", ctx.body.reason)
        end)

        it("cod_imovel vazio → 400", function()
            local ctx = fake_ctx({ cod_imovel = "" })
            car_routes.get_geometry(ctx)
            assert.are_equal(400, ctx.status)
        end)

        it("sem cod_imovel → 400", function()
            local ctx = fake_ctx({})
            car_routes.get_geometry(ctx)
            assert.are_equal(400, ctx.status)
        end)
    end)
end)

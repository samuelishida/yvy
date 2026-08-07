-- test_car_routes.lua — rotas /api/car/lookup e /api/tiles/car (fake ctx)
--
-- Constrói um car.db temporário (fixture) + um tiles_car.db temporário com um
-- tile, aponta CAR_DB_PATH/CAR_TILES_DB para eles, re-require dos módulos e
-- testa os handlers com um ctx fake (remote_addr=127.0.0.1 → auth passa;
-- rate_limit com Redis down → não limita).

local env = require("app.env")
local sqlite3 = require("lsqlite3")
local cjson = require("cjson")

local tmp_car_db = "./yvy_car_route_" .. tostring(os.time()) .. ".db"
local tmp_tiles_db = "./yvy_tiles_route_" .. tostring(os.time()) .. ".db"
local FIXTURE = "./tests/fixtures/car_sample.json"

-- Env ANTES de carregar módulos que cacheiam paths no load.
env.set("CAR_DB_PATH", tmp_car_db)
env.set("CAR_TILES_DB", tmp_tiles_db)
package.loaded["app.lookups.car_lookup"] = nil
package.loaded["app.routes.tiles"] = nil
package.loaded["app.routes.car"] = nil

local car_import = require("app.car_import")
local car_routes = require("app.routes.car")
local tiles_routes = require("app.routes.tiles")

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
    -- car.db (mesmo ETL de produção)
    local conn = sqlite3.open(tmp_car_db)
    conn:exec("PRAGMA journal_mode=WAL")
    car_import.create_schema(conn)
    local n = car_import.import_file(conn, FIXTURE)
    if n ~= 3 then error("fixture should insert 3 imóveis, got " .. tostring(n)) end
    conn:close()

    -- tiles_car.db com 1 tile (z=1,x=0,y=0)
    local t = sqlite3.open(tmp_tiles_db)
    t:exec([[CREATE TABLE IF NOT EXISTS tiles (
        z INTEGER NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL,
        data BLOB NOT NULL, content_type TEXT DEFAULT 'image/png',
        fetched_at TEXT NOT NULL, PRIMARY KEY (z, x, y))]])
    local ins = t:prepare("INSERT OR REPLACE INTO tiles (z,x,y,data,content_type,fetched_at) VALUES (?,?,?,?,?,?)")
    ins:bind(1, 1); ins:bind(2, 0); ins:bind(3, 0)
    ins:bind_blob(4, "TILE-BYTES")
    ins:bind(5, "image/png"); ins:bind(6, os.date("!%Y-%m-%dT00:00:00Z", os.time()))
    ins:step(); ins:finalize()
    t:close()
end)

describe("car routes", function()
    setup(function()
        if not build_ok then error("fixture build failed: " .. tostring(build_err)) end
    end)

    teardown(function()
        for _, p in ipairs({ tmp_car_db, tmp_car_db .. "-wal", tmp_car_db .. "-shm",
                             tmp_tiles_db, tmp_tiles_db .. "-wal", tmp_tiles_db .. "-shm" }) do
            os.remove(p)
        end
    end)

    describe("/api/car/lookup", function()
        it("ponto dentro de imóvel único → imovel", function()
            local ctx = fake_ctx({ lat = "-12.5", lon = "-54.5" })  -- MT-1
            car_routes.get_lookup(ctx)
            assert.are_equal(200, ctx.status)
            assert.are_equal("MT-1", ctx.body.imovel.id)
            assert.are_equal("MT", ctx.body.imovel.uf)
        end)
        it("sobreposição → maior área vence (RO-2 500ha > RO-1 100ha)", function()
            local ctx = fake_ctx({ lat = "-10.5", lon = "-60.5" })  -- dentro de RO-1 E RO-2
            car_routes.get_lookup(ctx)
            assert.are_equal(200, ctx.status)
            assert.are_equal("RO-2", ctx.body.imovel.id)
        end)
        it("ponto fora de qualquer imóvel → imovel null (JSON null)", function()
            local ctx = fake_ctx({ lat = "-20", lon = "-40" })
            car_routes.get_lookup(ctx)
            assert.are_equal(200, ctx.status)
            assert.are_equal(cjson.null, ctx.body.imovel)
        end)
        it("lat/lon não-numérico → 400", function()
            local ctx = fake_ctx({ lat = "abc", lon = "-54.5" })
            car_routes.get_lookup(ctx)
            assert.are_equal(400, ctx.status)
        end)
        it("sem lat/lon → 400", function()
            local ctx = fake_ctx({})
            car_routes.get_lookup(ctx)
            assert.are_equal(400, ctx.status)
        end)
    end)

    describe("/api/tiles/car", function()
        it("tile presente → 200 image/png com o blob", function()
            local ctx = fake_ctx({ z = "1", x = "0", y = "0" })
            tiles_routes.get_tile_car(ctx)
            assert.are_equal(200, ctx.status)
            assert.are_equal("image/png", ctx.content_type)
            assert.are_equal("TILE-BYTES", ctx.body)
        end)
        it("tile ausente → 200 com EMPTY_PNG (transparente)", function()
            local ctx = fake_ctx({ z = "1", x = "5", y = "5" })
            tiles_routes.get_tile_car(ctx)
            assert.are_equal(200, ctx.status)
            assert.are_equal("image/png", ctx.content_type)
            assert.is_not_nil(ctx.body)
            assert.is_true(#ctx.body > 0)
        end)
        it("sem z/x/y → 400", function()
            local ctx = fake_ctx({})
            tiles_routes.get_tile_car(ctx)
            assert.are_equal(400, ctx.status)
        end)
    end)
end)

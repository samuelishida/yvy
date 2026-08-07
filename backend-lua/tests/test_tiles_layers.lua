-- test_tiles_layers.lua — /api/tiles/cerrado-veg (plan: terrabrasilis-integration, Inc 9)
--
-- Constrói tiles_cerrado_veg.db (chave z,x,y), aponta CERRADO_VEG_TILES_DB,
-- re-require do módulo e testa com ctx fake: tile exato; miss → transparente.

local env = require("app.env")
local sqlite3 = require("lsqlite3")

local tmp_cerrado_db = "./yvy_tiles_cerrado_" .. tostring(os.time()) .. ".db"

env.set("CERRADO_VEG_TILES_DB", tmp_cerrado_db)
package.loaded["app.routes.tiles"] = nil
local tiles_routes = require("app.routes.tiles")

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

-- tiles_cerrado_veg.db (chave z,x,y)
local c = sqlite3.open(tmp_cerrado_db)
c:exec([[CREATE TABLE IF NOT EXISTS tiles (
    z INTEGER NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL,
    data BLOB NOT NULL, content_type TEXT DEFAULT 'image/png',
    fetched_at TEXT NOT NULL, PRIMARY KEY (z, x, y))]])
local cin = c:prepare("INSERT OR REPLACE INTO tiles (z,x,y,data,content_type,fetched_at) VALUES (?,?,?,?,?,?)")
cin:bind(1, 6); cin:bind(2, 10); cin:bind(3, 20)
cin:bind_blob(4, "CV-BYTES"); cin:bind(5, "image/png"); cin:bind(6, os.date("!%Y-%m-%dT00:00:00Z", os.time()))
cin:step(); cin:finalize()
c:close()

describe("tiles layers", function()
    teardown(function()
        os.remove(tmp_cerrado_db)
        os.remove(tmp_cerrado_db .. "-wal")
        os.remove(tmp_cerrado_db .. "-shm")
    end)

    describe("/api/tiles/cerrado-veg", function()
        it("serves the exact tile", function()
            local ctx = fake_ctx({ z = 6, x = 10, y = 20 })
            tiles_routes.get_tile_cerrado_veg(ctx)
            assert.are_equal(200, ctx.status)
            assert.are_equal("CV-BYTES", ctx.body)
        end)

        it("returns transparent PNG on miss", function()
            local ctx = fake_ctx({ z = 6, x = 99, y = 99 })
            tiles_routes.get_tile_cerrado_veg(ctx)
            assert.are_equal(200, ctx.status)
            assert.are_equal("image/png", ctx.content_type)
        end)
    end)
end)

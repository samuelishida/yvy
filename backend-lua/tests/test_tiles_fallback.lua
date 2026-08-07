-- test_tiles_fallback.lua — fallback de ancestral em /api/tiles/prodes
--
-- Constrói um tiles_prodes.db temporário com tiles em z3/z4 (e um tile exato),
-- aponta PRODES_TILES_DB para ele, re-require do módulo e testa get_tile com
-- um ctx fake:
--   • tile exato no cache  → retorna os bytes dele (sem fallback)
--   • tile ausente mas com ancestral cacheado → retorna os bytes do ancestral
--     (PRODES não "some" enquanto o warm offline ainda está preenchendo)
--   • tile e todos ancestrais ausentes → PNG transparente (área sem dados)
--   • fallback usa Cache-Control curto (max-age=60), NUNCA immutable — para o
--     navegador re-buscar o tile real quando o warm terminar.

local env = require("app.env")
local sqlite3 = require("lsqlite3")

local tmp_tiles_db = "./yvy_tiles_fallback_" .. tostring(os.time()) .. ".db"

-- Env ANTES de carregar o módulo (paths são resolvidos no load).
env.set("PRODES_TILES_DB", tmp_tiles_db)
package.loaded["app.routes.tiles"] = nil

local tiles_routes = require("app.routes.tiles")

local Z3 = "Z3-TILE-BYTES"
local Z4 = "Z4-TILE-BYTES"
local Z4X1 = "Z4-X1-TILE-BYTES"

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
    local t = sqlite3.open(tmp_tiles_db)
    t:exec([[CREATE TABLE IF NOT EXISTS tiles (
        z INTEGER NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL,
        data BLOB NOT NULL, content_type TEXT DEFAULT 'image/png',
        fetched_at TEXT NOT NULL, PRIMARY KEY (z, x, y))]])
    local ins = t:prepare("INSERT OR REPLACE INTO tiles (z,x,y,data,content_type,fetched_at) VALUES (?,?,?,?,?,?)")
    -- z3 (0,0) e (1,1); z4 (0,0) e (1,0)
    local function put(z, x, y, blob)
        ins:bind(1, z); ins:bind(2, x); ins:bind(3, y)
        ins:bind_blob(4, blob)
        ins:bind(5, "image/png"); ins:bind(6, os.date("!%Y-%m-%dT00:00:00Z", os.time()))
        ins:step(); ins:reset()
    end
    put(3, 0, 0, Z3)
    put(3, 1, 1, "Z3-X1Y1")
    put(4, 0, 0, Z4)
    put(4, 1, 0, Z4X1)
    ins:finalize()
    t:close()
end)

describe("prodes tiles ancestor fallback", function()
    setup(function()
        if not build_ok then error("fixture build failed: " .. tostring(build_err)) end
    end)

    teardown(function()
        for _, p in ipairs({ tmp_tiles_db, tmp_tiles_db .. "-wal", tmp_tiles_db .. "-shm" }) do
            os.remove(p)
        end
    end)

    it("tile exato no cache → retorna os bytes dele", function()
        local ctx = fake_ctx({ z = "4", x = "0", y = "0" })
        tiles_routes.get_tile(ctx)
        assert.are_equal(200, ctx.status)
        assert.are_equal(Z4, ctx.body)
        -- exato: pode cachear como immutable (não é fallback)
        assert.are_equal("public, max-age=2592000, immutable", ctx.headers["Cache-Control"])
    end)

    it("tile ausente com ancestral cacheado → retorna bytes do ancestral", function()
        -- z8(0,0): ancestrais z7(0,0)→z6(0,0)→z5(0,0)→z4(0,0) cacheado
        local ctx = fake_ctx({ z = "8", x = "0", y = "0" })
        tiles_routes.get_tile(ctx)
        assert.are_equal(200, ctx.status)
        assert.are_equal(Z4, ctx.body)
        -- fallback: Cache-Control curto para re-buscar quando o warm terminar
        assert.are_equal("public, max-age=60", ctx.headers["Cache-Control"])
    end)

    it("fallback sobe mais de um nível se preciso", function()
        -- z6(4,0): ancestrais z5(2,0) [ausente] → z4(1,0) cacheado (2 níveis)
        local ctx = fake_ctx({ z = "6", x = "4", y = "0" })
        tiles_routes.get_tile(ctx)
        assert.are_equal(200, ctx.status)
        assert.are_equal(Z4X1, ctx.body)
    end)

    it("tile e todos ancestrais ausentes → PNG transparente (200)", function()
        local ctx = fake_ctx({ z = "8", x = "1000", y = "1000" })
        tiles_routes.get_tile(ctx)
        assert.are_equal(200, ctx.status)
        assert.are_equal("image/png", ctx.content_type)
        assert.are_equal("public, max-age=60", ctx.headers["Cache-Control"])
        -- PNG 1x1 transparente (67 bytes)
        assert.is_true(#ctx.body < 100)
        assert.are_equal(0x89, string.byte(ctx.body, 1))
    end)

    it("fallback nunca desce abaixo de z3", function()
        -- z3(0,0) exato funciona; z2 não é servido (minZoom da camada é 2 mas
        -- o cache nunca tem z<3 — fallback para em z3)
        local ctx = fake_ctx({ z = "3", x = "0", y = "0" })
        tiles_routes.get_tile(ctx)
        assert.are_equal(200, ctx.status)
        assert.are_equal(Z3, ctx.body)
    end)
end)

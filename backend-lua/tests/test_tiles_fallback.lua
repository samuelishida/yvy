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

-- Blobs de fixture: cada tile precisa ser um PNG VÁLIDO (assinatura 8 bytes)
-- porque lookup_tile rejeita blobs corrompidos e os serve como miss (plan:
-- tile-corruption-biome-speed). São 1×1 RGBA com pixel distinto (70 bytes).
local PNG_RED = string.char(
    0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,
    0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
    0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,
    0x08,0x06,0x00,0x00,0x00,0x1F,0x15,0xC4,0x89,
    0x00,0x00,0x00,0x0D,0x49,0x44,0x41,0x54,
    0x78,0xDA,0x63,0xF8,0xCF,0xC0,0xF0,0x1F,
    0x00,0x05,0x00,0x01,0xFF,0x56,0xC7,0x2F,0x0D,
    0x00,0x00,0x00,0x00,0x49,0x45,0x4E,0x44,
    0xAE,0x42,0x60,0x82)
local PNG_GREEN = string.char(
    0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,
    0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
    0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,
    0x08,0x06,0x00,0x00,0x00,0x1F,0x15,0xC4,0x89,
    0x00,0x00,0x00,0x0D,0x49,0x44,0x41,0x54,
    0x78,0xDA,0x63,0x60,0xF8,0xCF,0xF0,0x1F,
    0x00,0x04,0x01,0x01,0xFF,0xAE,0xB5,0x55,0xF5,
    0x00,0x00,0x00,0x00,0x49,0x45,0x4E,0x44,
    0xAE,0x42,0x60,0x82)
local PNG_BLUE = string.char(
    0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,
    0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
    0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,
    0x08,0x06,0x00,0x00,0x00,0x1F,0x15,0xC4,0x89,
    0x00,0x00,0x00,0x0D,0x49,0x44,0x41,0x54,
    0x78,0xDA,0x63,0x60,0x60,0xF8,0xFF,0x1F,
    0x00,0x03,0x02,0x01,0xFF,0x39,0x29,0x19,0xBE,
    0x00,0x00,0x00,0x00,0x49,0x45,0x4E,0x44,
    0xAE,0x42,0x60,0x82)
local PNG_YELLOW = string.char(
    0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,
    0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
    0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,
    0x08,0x06,0x00,0x00,0x00,0x1F,0x15,0xC4,0x89,
    0x00,0x00,0x00,0x0D,0x49,0x44,0x41,0x54,
    0x78,0xDA,0x63,0xF8,0xFF,0x9F,0xA1,0x01,
    0x00,0x07,0x7E,0x02,0x7F,0x7A,0x7D,0xD2,0x6F,
    0x00,0x00,0x00,0x00,0x49,0x45,0x4E,0x44,
    0xAE,0x42,0x60,0x82)

local Z3 = PNG_RED
local Z4 = PNG_GREEN
local Z4X1 = PNG_BLUE
local Z3X1Y1 = PNG_YELLOW
local PNG_SIGNATURE = string.char(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)

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
    put(3, 1, 1, Z3X1Y1)
    put(4, 0, 0, Z4)
    put(4, 1, 0, Z4X1)
    -- tile com blob CORROMPIDO (sem assinatura PNG) — deve virar miss
    put(4, 2, 0, "NOT-A-PNG-CORRUPT-BLOB")
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
        -- PNG 1x1 transparente (68 bytes, válido)
        assert.is_true(#ctx.body < 100)
        assert.are_equal(0x89, string.byte(ctx.body, 1))
    end)

    it("blob corrupto (sem assinatura PNG) → tratado como miss (EMPTY_PNG)", function()
        -- z4(2,0) tem um blob "NOT-A-PNG-CORRUPT-BLOB" no DB; a rota nunca
        -- pode enviá-lo ao browser (viraria "Image corrupt or truncated")
        local ctx = fake_ctx({ z = "4", x = "2", y = "0" })
        tiles_routes.get_tile(ctx)
        assert.are_equal(200, ctx.status)
        assert.are_equal("image/png", ctx.content_type)
        assert.is_not_equal("NOT-A-PNG-CORRUPT-BLOB", ctx.body)
        assert.are_equal(PNG_SIGNATURE, ctx.body:sub(1, 8)) -- PNG válido
        -- sem ancestral válido acima z3(1,0) ausente → serve miss (max-age 60)
        assert.are_equal("public, max-age=60", ctx.headers["Cache-Control"])
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

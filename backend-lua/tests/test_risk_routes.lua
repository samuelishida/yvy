-- test_risk_routes.lua — rotas /api/risk/batch (POST CSV raw, GET progresso,
-- CSV inválido → 400) e /api/risk/supplier (Inc 6). Fake ctx.
dofile("tests/helpers.lua")
local env = require("app.env")
local sqlite3 = require("lsqlite3")
local cjson = require("cjson")

local tmp_risk_db = "./yvy_risk_route_" .. tostring(os.time()) .. ".db"
local tmp_suppliers_db = "./yvy_suppliers_route_" .. tostring(os.time()) .. ".db"

env.set("RISK_DB_PATH", tmp_risk_db)
env.set("SUPPLIERS_DB_PATH", tmp_suppliers_db)
package.loaded["app.lookups.risk_precompute"] = nil
package.loaded["app.lookups.supplier_monitor"] = nil
package.loaded["app.routes.risk"] = nil

local risk_routes = require("app.routes.risk")
local risk_precompute = require("app.lookups.risk_precompute")
local supplier_monitor = require("app.lookups.supplier_monitor")
local redis = require("app.redis")

-- Fake ctx espelhando a API de ctx (server.lua:290-315).
local function fake_ctx(args, body)
    return {
        req = { args = args or {}, remote_addr = "127.0.0.1", headers = {}, body = body or "" },
        status = nil, body = nil, content_type = nil, headers = {},
        json = function(self, status, data) self.status = status; self.body = data end,
        error = function(self, status, msg) self.status = status; self.body = { error = msg } end,
        send = function(self, status, body, ct) self.status = status; self.body = body; self.content_type = ct end,
        set_header = function(self, k, v) self.headers[k] = v end,
    }
end

describe("risk routes", function()
    setup(function()
        risk_precompute.ensure_schema(risk_precompute._offline_conn())
        supplier_monitor.ensure_schema(supplier_monitor._offline_conn())
    end)

    teardown(function()
        -- Limpa as chaves Redis do batch (common-mistake §2): o post_batch
        -- grava risk:batch:<id> no Redis compartilhado.
        redis.delete_pattern("risk:batch:*")
        os.remove(tmp_risk_db)
        os.remove(tmp_risk_db .. "-wal")
        os.remove(tmp_risk_db .. "-shm")
        os.remove(tmp_suppliers_db)
        os.remove(tmp_suppliers_db .. "-wal")
        os.remove(tmp_suppliers_db .. "-shm")
    end)

    it("POST /api/risk/batch rejects empty body", function()
        local ctx = fake_ctx({}, "")
        risk_routes.post_batch(ctx)
        assert.are_equal(400, ctx.status)
    end)

    it("POST /api/risk/batch rejects CSV with no data rows", function()
        local ctx = fake_ctx({}, "cnpj,cod_imovel,lat,lon,nome\n")
        risk_routes.post_batch(ctx)
        assert.are_equal(400, ctx.status)
    end)

    it("POST /api/risk/batch rejects a row with no identifier", function()
        local ctx = fake_ctx({}, "cnpj,cod_imovel,lat,lon,nome\n,,,,\n")
        risk_routes.post_batch(ctx)
        assert.are_equal(400, ctx.status)
    end)

    it("POST /api/risk/batch accepts valid CSV and returns batch_id", function()
        local csv = "cnpj,cod_imovel,lat,lon,nome\n12345678000199,RO-1,-10.5,-60.5,Fornecedor A\n"
        local ctx = fake_ctx({}, csv)
        risk_routes.post_batch(ctx)
        assert.are_equal(202, ctx.status)
        assert.is_not_nil(ctx.body.batch_id)
        assert.are_equal("running", ctx.body.status)
    end)

    it("GET /api/risk/batch returns 404 for unknown batch", function()
        local ctx = fake_ctx({ id = "nope" })
        risk_routes.get_batch(ctx)
        assert.are_equal(404, ctx.status)
    end)

    it("POST /api/risk/supplier saves a supplier", function()
        local ctx = fake_ctx({}, cjson.encode({ cnpj = "12.345.678/0001-99", nome = "Fornecedor B" }))
        risk_routes.post_supplier(ctx)
        assert.are_equal(200, ctx.status)
        local s = supplier_monitor.get_supplier("12345678000199")
        assert.is_not_nil(s)
        assert.are_equal("Fornecedor B", s.nome)
    end)

    it("GET /api/risk/suppliers lists suppliers", function()
        local ctx = fake_ctx({})
        risk_routes.get_suppliers(ctx)
        assert.are_equal(200, ctx.status)
        assert.is_true(#ctx.body.suppliers >= 1)
    end)
end)

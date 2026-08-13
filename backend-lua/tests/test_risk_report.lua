-- test_risk_report.lua — rota GET /api/risk/report (async 202 + status +
-- download). O spawn do renderer é mockado (sem subprocesso real).
dofile("tests/helpers.lua")
local env = require("app.env")
local sqlite3 = require("lsqlite3")

local tmp_risk_db = "./yvy_risk_report_" .. tostring(os.time()) .. ".db"
env.set("RISK_DB_PATH", tmp_risk_db)
package.loaded["app.lookups.risk_precompute"] = nil
package.loaded["app.routes.risk"] = nil

local risk_routes = require("app.routes.risk")
local risk_precompute = require("app.lookups.risk_precompute")
local risk_score = require("app.risk_score")
local redis = require("app.redis")

-- Stub Redis (common-mistake §2): get→nil = miss; set grava num map local.
local redis_state = {}
local original_get, original_set = redis.get, redis.set
redis.get = function(key) return redis_state[key] end
redis.set = function(key, value, ttl) redis_state[key] = value end

-- Mock do spawn: não lança subprocesso; retorna um report_id determinístico
-- (único por run, para não colidir com arquivos /tmp de runs anteriores).
local MOCK_REPORT_ID = "r" .. tostring(os.time()) .. "_67890"
local spawned = nil
local original_spawn = risk_routes.spawn_report
risk_routes.spawn_report = function(property_id, context_json)
    spawned = { property_id = property_id, context_json = context_json }
    return MOCK_REPORT_ID
end

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

-- Cria um marker sidecar .done/.fail em /tmp para o report_id mockado.
local function write_marker(suffix)
    local f = io.open("/tmp/yvy_risk_report_" .. MOCK_REPORT_ID .. suffix, "w")
    f:write("ok\n")
    f:close()
end
local function remove_markers()
    os.remove("/tmp/yvy_risk_report_" .. MOCK_REPORT_ID .. ".done")
    os.remove("/tmp/yvy_risk_report_" .. MOCK_REPORT_ID .. ".fail")
    os.remove("/tmp/yvy_risk_report_" .. MOCK_REPORT_ID .. ".pdf")
end

describe("risk report", function()
    setup(function()
        risk_precompute.ensure_schema(risk_precompute._offline_conn())
        local res = risk_score.score({ cod_imovel = "RO-1" }, {
            deforestation = 1.0, protected_overlap = 1.0,
        })
        risk_precompute.upsert("RO-1", res)
    end)

    teardown(function()
        redis.get, redis.set = original_get, original_set
        risk_routes.spawn_report = original_spawn
        remove_markers()
        os.remove(tmp_risk_db)
        os.remove(tmp_risk_db .. "-wal")
        os.remove(tmp_risk_db .. "-shm")
    end)

    it("GET /api/risk/report returns 400 when id missing", function()
        local ctx = fake_ctx({})
        risk_routes.get_report(ctx)
        assert.are_equal(400, ctx.status)
    end)

    it("GET /api/risk/report returns 404 when score not found", function()
        local ctx = fake_ctx({ id = "NOPE-1" })
        risk_routes.get_report(ctx)
        assert.are_equal(404, ctx.status)
    end)

    it("GET /api/risk/report returns 202 + report_id (async)", function()
        local ctx = fake_ctx({ id = "RO-1" })
        risk_routes.get_report(ctx)
        assert.are_equal(202, ctx.status)
        assert.are_equal("running", ctx.body.status)
        assert.are_equal(MOCK_REPORT_ID, ctx.body.report_id)
        assert.is_not_nil(spawned)
        assert.are_equal("RO-1", spawned.property_id)
    end)

    it("GET /api/risk/report/status returns running while no marker", function()
        redis_state["risk:report:" .. MOCK_REPORT_ID] = "running"
        local ctx = fake_ctx({ id = MOCK_REPORT_ID })
        risk_routes.get_report_status(ctx)
        assert.are_equal(200, ctx.status)
        assert.are_equal("running", ctx.body.status)
    end)

    it("GET /api/risk/report/status returns ready when .done marker exists", function()
        remove_markers()
        redis_state["risk:report:" .. MOCK_REPORT_ID] = "running"
        write_marker(".done")
        local ctx = fake_ctx({ id = MOCK_REPORT_ID })
        risk_routes.get_report_status(ctx)
        assert.are_equal(200, ctx.status)
        assert.are_equal("ready", ctx.body.status)
        assert.are_equal("/api/risk/report/download?id=" .. MOCK_REPORT_ID, ctx.body.url)
        -- O estado Redis foi flipado para ready.
        assert.are_equal("ready", redis_state["risk:report:" .. MOCK_REPORT_ID])
    end)

    it("GET /api/risk/report/status returns failed when .fail marker exists", function()
        remove_markers()
        redis_state["risk:report:" .. MOCK_REPORT_ID] = "running"
        write_marker(".fail")
        local ctx = fake_ctx({ id = MOCK_REPORT_ID })
        risk_routes.get_report_status(ctx)
        assert.are_equal(200, ctx.status)
        assert.are_equal("failed", ctx.body.status)
        assert.are_equal("failed", redis_state["risk:report:" .. MOCK_REPORT_ID])
    end)

    it("GET /api/risk/report/status returns 400 when id missing", function()
        local ctx = fake_ctx({})
        risk_routes.get_report_status(ctx)
        assert.are_equal(400, ctx.status)
    end)

    it("GET /api/risk/report/status returns 404 for invalid report_id", function()
        local ctx = fake_ctx({ id = "../../etc/passwd" })
        risk_routes.get_report_status(ctx)
        assert.are_equal(404, ctx.status)
    end)

    it("GET /api/risk/report/download serves the PDF", function()
        local f = io.open("/tmp/yvy_risk_report_" .. MOCK_REPORT_ID .. ".pdf", "wb")
        f:write("%PDF-1.4 test")
        f:close()
        local ctx = fake_ctx({ id = MOCK_REPORT_ID })
        risk_routes.get_report_download(ctx)
        assert.are_equal(200, ctx.status)
        assert.are_equal("application/pdf", ctx.content_type)
        assert.are_equal("%PDF-1.4 test", ctx.body)
        assert.are_equal('attachment; filename="yvy_risk_report_' .. MOCK_REPORT_ID .. '.pdf"',
            ctx.headers["Content-Disposition"])
    end)

    it("GET /api/risk/report/download returns 404 when PDF missing", function()
        remove_markers()  -- garante que o PDF do teste anterior não existe
        local ctx = fake_ctx({ id = MOCK_REPORT_ID })
        risk_routes.get_report_download(ctx)
        assert.are_equal(404, ctx.status)
    end)

    it("GET /api/risk/report/download returns 404 for invalid report_id", function()
        local ctx = fake_ctx({ id = "x; rm -rf /" })
        risk_routes.get_report_download(ctx)
        assert.are_equal(404, ctx.status)
    end)
end)

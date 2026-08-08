-- test_dashboard_summary.lua — /api/dashboard/summary (plan: dashboard-enhancement, Inc 3)
--
-- KPIs período-a-período. Redis stubado (get→nil = miss sempre; set registra a
-- key); rate_limit:127.0.0.1 limpo no setup. As fixtures usam days_ago(n) para
-- janelas relativas ao relógio (common-mistakes #1).
--
-- A rota envia o corpo pré-serializado via ctx:send (padrão das rotas com
-- cache em Redis), então ctx.body é um STRING JSON — o helper body_of decodifica.

local env = require("app.env")
local sqlite3 = require("lsqlite3")
local cjson = require("cjson")

local tmp_yvy_db = "./yvy_dash_summary_" .. tostring(os.time()) .. ".db"
env.set("SQLITE_PATH", tmp_yvy_db)
package.loaded["app.db"] = nil
package.loaded["app.routes.dashboard"] = nil
package.loaded["app.routes.deforestation_stats"] = nil

local db_mod = require("app.db")
local dash = require("app.routes.dashboard")
local redis = require("app.redis")

dofile("tests/helpers.lua")

local written_keys = {}
local original_get, original_set = redis.get, redis.set
redis.get = function() return nil end
redis.set = function(key) written_keys[#written_keys + 1] = key end

teardown(function()
    redis.get, redis.set = original_get, original_set
end)

local function body_of(ctx)
    if type(ctx.body) == "string" then
        return cjson.decode(ctx.body)
    end
    return ctx.body
end

-- Semeia `count` dias consecutivos a partir de start_day (days_ago), um fogo
-- por dia.
local function seed_range(start_day, count, state)
    local docs = {}
    for i = 0, count - 1 do
        docs[#docs + 1] = {
            lat = -10.5 + i * 0.001, lon = -60.5 + i * 0.001,
            acq_date = days_ago(start_day + i),
            ingested_at = days_ago(start_day + i) .. "T00:00:00Z",
            state = state,
        }
    end
    db_mod.bulk_upsert_fires(docs)
end

-- Marca nature nas linhas com acq_date exato (os fixtures têm 1 fogo/dia).
local function set_nature(acq_date, nature)
    local db = sqlite3.open(tmp_yvy_db)
    db:exec("UPDATE fire_data SET nature='" .. nature .. "' WHERE acq_date='" .. acq_date .. "'")
    db:close()
end

describe("dashboard summary — happy path", function()
    setup(function()
        redis.delete("rate_limit:127.0.0.1")
        db_mod.init_db()
        -- janela atual (days=7): days_ago(0..6); janela anterior: days_ago(7..13)
        seed_range(0, 7, "MT")
        seed_range(7, 7, "MT")
        -- nature: crime nos 2 dias mais recentes, natural nos 5 restantes
        set_nature(days_ago(0), "crime")
        set_nature(days_ago(1), "crime")
        for i = 2, 6 do set_nature(days_ago(i), "natural") end
    end)

    teardown(function()
        db_mod.close_db()
        os.remove(tmp_yvy_db)
        os.remove(tmp_yvy_db .. "-wal")
        os.remove(tmp_yvy_db .. "-shm")
    end)

    it("returns fires current/previous + delta + complete", function()
        local ctx = fake_ctx({days = "7"})
        dash.get_summary(ctx)
        assert.are_equal(200, ctx.status)
        local body = body_of(ctx)
        assert.are_equal(7, body.days)
        assert.is_string(body.generated_at)
        assert.are_equal(7, body.kpis.fires.current)
        assert.are_equal(7, body.kpis.fires.previous)
        assert.are_equal(0.0, body.kpis.fires.delta_pct)
        assert.is_true(body.kpis.fires.complete)
    end)

    it("breaks nature KPIs by class", function()
        local ctx = fake_ctx({days = "7"})
        dash.get_summary(ctx)
        local body = body_of(ctx)
        assert.are_equal(2, body.kpis.crime.current)
        assert.are_equal(5, body.kpis.natural.current)
        assert.are_equal(0, body.kpis.unclassified.current)
        assert.are_equal(7, body.kpis.fires.current)
    end)

    it("caches per (days, state)", function()
        local before = #written_keys
        local ctx = fake_ctx({days = "7"})
        dash.get_summary(ctx)
        local ctx_pa = fake_ctx({days = "7", state = "PA"})
        dash.get_summary(ctx_pa)
        assert.are_equal(200, ctx_pa.status)
        local k1, k2 = "dashboard:summary:7:all", "dashboard:summary:7:PA"
        local seen_k1, seen_k2 = false, false
        for i = before + 1, #written_keys do
            if written_keys[i] == k1 then seen_k1 = true end
            if written_keys[i] == k2 then seen_k2 = true end
        end
        assert.is_true(seen_k1)
        assert.is_true(seen_k2)
    end)
end)

describe("dashboard summary — validation and empty", function()
    setup(function()
        redis.delete("rate_limit:127.0.0.1")
        db_mod.init_db()
        -- só janela atual (previous vazio) → delta nil + complete false
        seed_range(0, 3, "MT")
    end)

    teardown(function()
        db_mod.close_db()
        os.remove(tmp_yvy_db)
        os.remove(tmp_yvy_db .. "-wal")
        os.remove(tmp_yvy_db .. "-shm")
    end)

    it("previous=0 → delta_pct nil, not infinity", function()
        local ctx = fake_ctx({days = "7"})
        dash.get_summary(ctx)
        assert.are_equal(200, ctx.status)
        local body = body_of(ctx)
        assert.are_equal(3, body.kpis.fires.current)
        assert.are_equal(0, body.kpis.fires.previous)
        assert.is_nil(body.kpis.fires.delta_pct)
        assert.is_false(body.kpis.fires.complete)  -- cobertura curta
    end)

    it("rejects invalid days", function()
        local ctx0 = fake_ctx({days = "0"})
        dash.get_summary(ctx0)
        assert.are_equal(400, ctx0.status)
        assert.are_equal("invalid days", ctx0.body.error)

        local ctx999 = fake_ctx({days = "999"})
        dash.get_summary(ctx999)
        assert.are_equal(400, ctx999.status)
    end)

    it("rejects invalid state", function()
        local ctx = fake_ctx({days = "7", state = "XX"})
        dash.get_summary(ctx)
        assert.are_equal(400, ctx.status)
        assert.are_equal("invalid state", ctx.body.error)
    end)

    it("empty DETER → available false, status 200", function()
        local ctx = fake_ctx({days = "7"})
        dash.get_summary(ctx)
        assert.are_equal(200, ctx.status)
        local body = body_of(ctx)
        assert.is_false(body.kpis.deter_km2.available)
        assert.is_nil(body.kpis.deter_km2.current)
        assert.are_equal("deter", body.sources[2].id)
        assert.is_false(body.sources[2].available)
    end)

    it("includes prodes_latest when the historical JSON exists", function()
        local ctx = fake_ctx({days = "7"})
        dash.get_summary(ctx)
        assert.are_equal(200, ctx.status)
        local body = body_of(ctx)
        if body.kpis.prodes_latest ~= nil then
            assert.is_number(body.kpis.prodes_latest.year)
            assert.is_number(body.kpis.prodes_latest.km2)
        end
    end)
end)

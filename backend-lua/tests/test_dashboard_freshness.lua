-- test_dashboard_freshness.lua — /api/dashboard/freshness (plan: dashboard-enhancement, Inc 8)
--
-- Ingestão por fonte + cobertura de atributos. Redis stubado; fixtures com
-- days_ago(n) (common-mistakes #1).

local env = require("app.env")
local sqlite3 = require("lsqlite3")
local cjson = require("cjson")

local tmp_yvy_db = "./yvy_dash_freshness_" .. tostring(os.time()) .. ".db"
env.set("SQLITE_PATH", tmp_yvy_db)
package.loaded["app.db"] = nil
package.loaded["app.routes.dashboard"] = nil

local db_mod = require("app.db")
local dash = require("app.routes.dashboard")
local redis = require("app.redis")

dofile("tests/helpers.lua")

local original_get, original_set = redis.get, redis.set
redis.get = function() return nil end
redis.set = function() end

teardown(function()
    redis.get, redis.set = original_get, original_set
end)

local function body_of(ctx)
    if type(ctx.body) == "string" then return cjson.decode(ctx.body) end
    return ctx.body
end

describe("dashboard freshness", function()
    setup(function()
        redis.delete("rate_limit:127.0.0.1")
        db_mod.init_db()
        -- 2 focos: 1 com state/UF e biome, 1 sem state (oceano) e sem biome
        db_mod.bulk_upsert_fires({
            { lat = -3.10, lon = -60.02, acq_date = days_ago(1), ingested_at = days_ago(1) .. "T00:00:00Z", state = "AM" },
            { lat = -20.0, lon = -30.0, acq_date = days_ago(1), ingested_at = days_ago(1) .. "T00:00:00Z" },
        })
        -- atribui biome a um dos focos
        local db = sqlite3.open(tmp_yvy_db)
        db:exec("UPDATE fire_data SET nature='crime' WHERE acq_date='" .. days_ago(1) .. "' AND lat=-3.10")
        db:close()
        local batch = db_mod.iter_fires_for_biome_backfill(100)
        local biome = require("app.lookups.biome_lookup")
        biome.load_biomes()
        for _, row in ipairs(batch) do
            local name = biome.classify_point(row.lon, row.lat)
            if name then db_mod.update_fire_biome(row.id, name) else db_mod.mark_fire_biome_unattributable(row.id) end
        end
    end)

    teardown(function()
        db_mod.close_db()
        os.remove(tmp_yvy_db)
        os.remove(tmp_yvy_db .. "-wal")
        os.remove(tmp_yvy_db .. "-shm")
    end)

    it("reports DETER/AMS/CAR as unavailable when tables are empty", function()
        local ctx = fake_ctx()
        dash.get_freshness(ctx)
        assert.are_equal(200, ctx.status)
        local body = body_of(ctx)
        assert.is_string(body.generated_at)
        local by_id = {}
        for _, s in ipairs(body.sources) do by_id[s.id] = s end
        assert.is_true(by_id.firms.available)
        assert.is_false(by_id.deter.available)
        assert.is_nil(by_id.deter.last_ingested_at)
        assert.are_equal(0, by_id.deter.rows)
        assert.is_false(by_id.ams.available)
        assert.is_false(by_id.deter_car.available)
    end)

    it("computes attribution coverage without dividing by zero", function()
        local ctx = fake_ctx()
        dash.get_freshness(ctx)
        local body = body_of(ctx)
        -- 1 de 2 com state real (o outro é ''/oceano) → 0.5
        assert.are_equal(0.5, body.coverage.state_pct)
        -- 1 de 2 com biome → 0.5
        assert.are_equal(0.5, body.coverage.biome_pct)
        -- 1 de 2 classificada como nature → 0.5
        assert.are_equal(0.5, body.coverage.nature_pct)
    end)

    it("reports fires row count and freshness timestamp", function()
        local ctx = fake_ctx()
        dash.get_freshness(ctx)
        local body = body_of(ctx)
        local firms
        for _, s in ipairs(body.sources) do if s.id == "firms" then firms = s end end
        assert.are_equal(2, firms.rows)
        assert.is_not_nil(firms.last_ingested_at)
    end)
end)

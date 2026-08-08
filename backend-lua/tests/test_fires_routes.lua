-- test_fires_routes.lua — rotas /api/fires (plan: terrabrasilis-fixes, Inc 9)
--
-- yvy.db temporário com focos (FIRMS + BDQ); Redis stubado (captura cache
-- keys — sem conexão real necessária neste arquivo).
-- A rota acessa redis via require("app.redis"); sobrescrevendo get/set no
-- módulo, capturamos os cache keys que a rota gera (get → nil = miss sempre,
-- set → registra a key). rate_limit/auth usam o Redis real (PONG) e passam
-- para remote_addr=127.0.0.1 com poucas requests.

local env = require("app.env")
local sqlite3 = require("lsqlite3")
local cjson = require("cjson")

local tmp_yvy_db = "./yvy_fires_routes_" .. tostring(os.time()) .. ".db"
env.set("SQLITE_PATH", tmp_yvy_db)
package.loaded["app.db"] = nil
package.loaded["app.routes.fires"] = nil

local db_mod = require("app.db")
local fires_routes = require("app.routes.fires")
local redis = require("app.redis")

dofile("tests/helpers.lua")

-- Redis stub: cache miss sempre; captura as keys escritas.
local written_keys = {}
local original_get, original_set = redis.get, redis.set
redis.get = function() return nil end
redis.set = function(key) written_keys[#written_keys + 1] = key end

describe("fires routes", function()
    setup(function()
        -- Redis é live/shared neste ambiente: o bucket rate_limit:127.0.0.1
        -- acumula entradas de runs anteriores dentro da janela de 60s e faria
        -- estas requests autenticadas virarem 429 (flake). Limpa antes.
        redis.delete("rate_limit:127.0.0.1")

        db_mod.init_db()
        db_mod.bulk_upsert_fires({
            { lat = -10.5, lon = -60.5, acq_date = days_ago(1), ingested_at = days_ago(1) .. "T00:00:00Z",
              confidence = "high", satellite = "NPP", source = "NASA_FIRMS_VIIRS_SNPP", state = "RO" },
            { lat = -10.4, lon = -60.6, acq_date = days_ago(1), ingested_at = days_ago(1) .. "T00:00:00Z",
              confidence = "high", satellite = "NPP", source = "BDQ", state = "RO" },
        })
    end)

    teardown(function()
        db_mod.close_db()
        redis.get, redis.set = original_get, original_set
        os.remove(tmp_yvy_db)
        os.remove(tmp_yvy_db .. "-wal")
        os.remove(tmp_yvy_db .. "-shm")
    end)

    describe("source canonicalization", function()
        it("rejects invalid source (?source=ams) with 400", function()
            local ctx = _G.fake_ctx({ source = "ams" })
            fires_routes.get_fires(ctx)
            assert.are_equal(400, ctx.status)
            assert.are_equal("invalid source", ctx.body.error)
        end)

        it("accepts only empty/firms/bdqueimadas source", function()
            for _, s in ipairs({ nil, "", "firms", "bdqueimadas" }) do
                local ctx = _G.fake_ctx(s and { source = s } or {})
                fires_routes.get_fires(ctx)
                assert.are_equal(200, ctx.status, "source=" .. tostring(s) .. " should pass")
            end
        end)

        it("distinct cache keys for firms vs bdqueimadas", function()
            written_keys = {}
            local ctx_a = _G.fake_ctx({ source = "firms" })
            fires_routes.get_fires(ctx_a)
            local ctx_b = _G.fake_ctx({ source = "bdqueimadas" })
            fires_routes.get_fires(ctx_b)
            assert.are_equal(2, #written_keys)
            assert.is_not_equal(written_keys[1], written_keys[2])
            assert.is_true(written_keys[1]:find(":firms$") ~= nil, written_keys[1])
            assert.is_true(written_keys[2]:find(":bdqueimadas$") ~= nil, written_keys[2])
        end)
    end)

    describe("bbox range-clamp", function()
        it("clamps out-of-range coords instead of rejecting", function()
            -- ne_lat=95→90, ne_lng=200→180, sw_lat=-95→-90, sw_lng=-200→-180
            local ctx = _G.fake_ctx({ ne_lat = "95", ne_lng = "200", sw_lat = "-95", sw_lng = "-200" })
            fires_routes.get_fires(ctx)
            assert.are_equal(200, ctx.status)
        end)

        it("still rejects an invalid bbox after clamping (ne <= sw)", function()
            local ctx = _G.fake_ctx({ ne_lat = "5", ne_lng = "60", sw_lat = "10", sw_lng = "50" })
            fires_routes.get_fires(ctx)
            assert.are_equal(400, ctx.status)
        end)
    end)

    describe("state sparklines (plan: dashboard-enhancement, Inc 5)", function()
        it("returns per-state series with non-nil dates", function()
            local ctx = _G.fake_ctx({ days = 7 })
            fires_routes.get_fires_state_sparklines(ctx)
            assert.are_equal(200, ctx.status)
            local body = cjson.decode(ctx.body)
            assert.are_equal(7, body.days)
            assert.is_not_nil(body.sparklines)
            local found = false
            for st, series in pairs(body.sparklines) do
                if st == "RO" then
                    found = true
                    assert.is_true(#series >= 1)
                    for _, pt in ipairs(series) do
                        assert.is_not_nil(pt.date, "sparkline point must carry a date")
                        assert.is_number(pt.count)
                    end
                end
            end
            assert.is_true(found, "RO should appear in sparklines")
        end)

        it("clamps days to [1, 90] and caches per days", function()
            written_keys = {}
            local ctx0 = _G.fake_ctx({ days = 0 })
            fires_routes.get_fires_state_sparklines(ctx0)
            assert.are_equal(200, ctx0.status)
            local body0 = cjson.decode(ctx0.body)
            assert.are_equal(1, body0.days)

            local ctx999 = _G.fake_ctx({ days = 999 })
            fires_routes.get_fires_state_sparklines(ctx999)
            assert.are_equal(200, ctx999.status)
            local body999 = cjson.decode(ctx999.body)
            assert.are_equal(90, body999.days)

            local seen1, seen90 = false, false
            for _, k in ipairs(written_keys) do
                if k == "fires:sparklines:1" then seen1 = true end
                if k == "fires:sparklines:90" then seen90 = true end
            end
            assert.is_true(seen1 and seen90)
        end)
    end)
end)

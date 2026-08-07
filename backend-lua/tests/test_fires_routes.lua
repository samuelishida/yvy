-- test_fires_routes.lua — rotas /api/fires (plan: terrabrasilis-fixes, Inc 9)
--
-- yvy.db temporário com focos (FIRMS + BDQ) e um polígono ams_risk; Redis
-- stubado (captura cache keys — sem conexão real necessária neste arquivo).
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

        -- ams_risk: polígono de risco ALTO em (-11..-10, -61..-60) — cobre os 2 focos
        local db = sqlite3.open(tmp_yvy_db)
        local stmt = db:prepare([[
            INSERT INTO ams_risk
                (view_date, viewed_at, satelite, municipio, biome, geocode, layer, risk_level,
                 min_lat, min_lon, max_lat, max_lon, geom, ingested_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        stmt:bind(1, days_ago(1)); stmt:bind(2, days_ago(1) .. "T12:00:00Z")
        stmt:bind(3, "GOES-16"); stmt:bind(4, "Vilhena"); stmt:bind(5, "Amazônia"); stmt:bind(6, "1100304")
        stmt:bind(7, "fire-spreading-risk"); stmt:bind(8, "ALTO")
        stmt:bind(9, -11.0); stmt:bind(10, -61.0); stmt:bind(11, -10.0); stmt:bind(12, -60.0)
        stmt:bind(13, cjson.encode({ type = "MultiPolygon", coordinates = { { { { -61, -11 }, { -60, -11 }, { -60, -10 }, { -61, -10 }, { -61, -11 } } } } }))
        stmt:bind(14, os.date("!%Y-%m-%dT00:00:00Z", os.time()))
        stmt:step(); stmt:finalize()
        db:close()
    end)

    teardown(function()
        db_mod.close_db()
        redis.get, redis.set = original_get, original_set
        os.remove(tmp_yvy_db)
        os.remove(tmp_yvy_db .. "-wal")
        os.remove(tmp_yvy_db .. "-shm")
    end)

    describe("source/ams canonicalization", function()
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

        it("rejects junk ams value with 400", function()
            local ctx = _G.fake_ctx({ ams = "banana" })
            fires_routes.get_fires(ctx)
            assert.are_equal(400, ctx.status)
            assert.are_equal("invalid ams", ctx.body.error)
        end)

        it("accepts canonical ams values (true/1 → on; false/0/absent → off)", function()
            local ok_ctx = _G.fake_ctx({ ams = "true" })
            fires_routes.get_fires(ok_ctx)
            assert.are_equal(200, ok_ctx.status)
            local ok1 = _G.fake_ctx({ ams = "1" })
            fires_routes.get_fires(ok1)
            assert.are_equal(200, ok1.status)
            local off = _G.fake_ctx({ ams = "false" })
            fires_routes.get_fires(off)
            assert.are_equal(200, off.status)
            local off0 = _G.fake_ctx({ ams = "0" })
            fires_routes.get_fires(off0)
            assert.are_equal(200, off0.status)
        end)

        it("distinct cache keys for firms vs bdqueimadas (com ams=true)", function()
            written_keys = {}
            local ctx_a = _G.fake_ctx({ source = "firms", ams = "true" })
            fires_routes.get_fires(ctx_a)
            local ctx_b = _G.fake_ctx({ source = "bdqueimadas", ams = "true" })
            fires_routes.get_fires(ctx_b)
            assert.are_equal(2, #written_keys)
            assert.is_not_equal(written_keys[1], written_keys[2])
            assert.is_true(written_keys[1]:find(":firms:ams$") ~= nil, written_keys[1])
            assert.is_true(written_keys[2]:find(":bdqueimadas:ams$") ~= nil, written_keys[2])
        end)

        it("no bare …:ams key exists — invalid ?source=ams never reaches the cache", function()
            written_keys = {}
            -- ?source=ams é inválido: 400 e NADA é escrito no cache (não pode
            -- colidir com ?ams=true, que é o único caminho que gera o sufixo :ams).
            local ctx_bad = _G.fake_ctx({ source = "ams" })
            fires_routes.get_fires(ctx_bad)
            assert.are_equal(400, ctx_bad.status)
            assert.are_equal(0, #written_keys, "invalid source must not write a cache key")

            -- ?ams=true sozinho gera o sufixo :ams só via a flag (sem segmento
            -- de source "ams" na frente).
            local ctx_ok = _G.fake_ctx({ ams = "true" })
            fires_routes.get_fires(ctx_ok)
            assert.are_equal(200, ctx_ok.status)
            assert.are_equal(1, #written_keys)
            assert.is_true(written_keys[1]:find(":ams$") ~= nil, written_keys[1])
            assert.is_true(written_keys[1]:find(":ams:ams") == nil, "no 'ams' source token: " .. written_keys[1])
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

    describe("ams batch (N+1 fix)", function()
        it("attaches AMS via one get_ams_risk_batch, never get_ams_risk_at", function()
            local calls = 0
            local orig = db_mod.get_ams_risk_at
            db_mod.get_ams_risk_at = function() calls = calls + 1; return { risk_level = "STUB" } end

            local ctx = _G.fake_ctx({ ams = "true" })
            fires_routes.get_fires(ctx)

            db_mod.get_ams_risk_at = orig
            assert.are_equal(0, calls, "get_ams_risk_at must not be called (N+1 removed)")
            assert.are_equal(200, ctx.status)

            local body = cjson.decode(ctx.body)
            assert.are_equal(2, #body.fires)
            -- ambos os focos estão dentro do polígono ALTO → ams preenchido
            assert.is_not_nil(body.fires[1].ams)
            assert.is_not_nil(body.fires[2].ams)
            assert.are_equal("ALTO", body.fires[1].ams.risk_level)
            assert.are_equal("ALTO", body.fires[2].ams.risk_level)
        end)

        it("leaves f.ams nil when no polygon covers the fire", function()
            -- foco longe do polígono AMS (fora do Brasil default? não: -30,-50 está
            -- dentro do bbox Brasil; ams_risk só cobre -11..-10/-61..-60)
            db_mod.bulk_upsert_fires({
                { lat = -30.0, lon = -50.0, acq_date = days_ago(1), ingested_at = days_ago(1) .. "T00:00:00Z",
                  confidence = "high", satellite = "NPP", source = "NASA_FIRMS_VIIRS_SNPP", state = "SP" },
            })
            local ctx = _G.fake_ctx({ ams = "true" })
            fires_routes.get_fires(ctx)
            assert.are_equal(200, ctx.status)
            local body = cjson.decode(ctx.body)
            local far
            for _, f in ipairs(body.fires) do
                if f.lat == -30.0 then far = f end
            end
            assert.is_not_nil(far)
            assert.is_nil(far.ams)
        end)
    end)
end)

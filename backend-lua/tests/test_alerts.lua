-- test_alerts.lua — Tests for alerts.lua
--
-- REQUER Redis em execução (app/redis.lua conecta de verdade; CI fornece
-- redis:7). Escreve `alerts:deter_protected` e limpa via after_each (sucesso
-- E falha) para não vazar chaves de 24h (Inc 12).

local alerts = require("app.routes.alerts")
local redis = require("app.redis")
local cjson = require("cjson")

dofile("tests/helpers.lua")
local D = days_ago(1)  -- fixture "ontem" (Inc 2/12: nada de datas absolutas)

describe("alerts", function()
    describe("generate_all_alerts", function()
        it("returns a table with alerts and count", function()
            local fires = {
                {
                    lat = -10.0, lon = -55.0, confidence = "high",
                    acq_date = "2024-06-01", acq_time = "1200",
                },
                {
                    lat = -10.1, lon = -55.1, confidence = "high",
                    acq_date = "2024-06-01", acq_time = "1205",
                },
                {
                    lat = -10.2, lon = -55.2, confidence = "high",
                    acq_date = "2024-06-01", acq_time = "1210",
                },
                {
                    lat = -10.3, lon = -55.3, confidence = "high",
                    acq_date = "2024-06-01", acq_time = "1215",
                },
                {
                    lat = -10.4, lon = -55.4, confidence = "high",
                    acq_date = "2024-06-01", acq_time = "1220",
                },
            }

            local result = alerts.generate_all_alerts(fires, nil, "demo")
            assert.is_not_nil(result.alerts)
            assert.is_not_nil(result.count)
            assert.is_true(type(result.alerts) == "table")
            assert.is_true(type(result.count) == "number")
        end)

        it("caps alerts at MAX_ALERTS (20)", function()
            -- Generate many fires that would create many alerts
            local fires = {}
            for i = 1, 200 do
                fires[i] = {
                    lat = -10.0 + (i * 0.01),
                    lon = -55.0 + (i * 0.01),
                    confidence = "high",
                    acq_date = "2024-06-01",
                    acq_time = "1200",
                }
            end

            local result = alerts.generate_all_alerts(fires, nil, "demo")
            assert.is_true(result.count <= 20)
        end)
    end)

    describe("deter_protected (Inc 6)", function()
        -- Inc 12: limpa a chave mesmo quando uma assertion falha (não vaza 24h).
        after_each(function()
            redis.delete("alerts:deter_protected")
        end)

        it("includes deter_protected entries from Redis with tiered tick", function()
            redis.set("alerts:deter_protected", cjson.encode({
                { id = "deter_protected_1", type = "deter_protected", territory_type = "uc",
                  territory_name = "UC Jamanxim", area_ha = 45.2, classname = "DESMATAMENTO_VEG",
                  view_date = D, meta = "UC Jamanxim · 45.2 ha DETER",
                  state = "DESMATAMENTO_VEG · " .. D, center = { -8, -55 }, radius_km = 5, ts = "12:00" },
                { id = "deter_protected_2", type = "deter_protected", territory_type = "ti",
                  territory_name = "TI X", area_ha = 5.0, classname = "CICATRIZ_DE_QUEIMADA",
                  view_date = D, meta = "TI X · 5.0 ha DETER",
                  state = "CICATRIZ_DE_QUEIMADA · " .. D, center = { -9, -56 }, radius_km = 5, ts = "12:00" },
            }), 86400)

            local result = alerts.generate_all_alerts({}, nil, "demo")
            local det = {}
            for _, a in ipairs(result.alerts) do
                if a.type == "deter_protected" then det[#det + 1] = a end
            end
            assert.are_equal(2, #det)

            local by_id = {}
            for _, a in ipairs(det) do by_id[a.id] = a end
            -- DESMATAMENTO_VEG → crit; CICATRIZ_DE_QUEIMADA → warn (R6)
            assert.are_equal("crit", by_id["deter_protected_1"].tick)
            assert.are_equal("warn", by_id["deter_protected_2"].tick)
            redis.delete("alerts:deter_protected")
        end)

        it("treats >50 ha as crit regardless of class", function()
            redis.set("alerts:deter_protected", cjson.encode({
                { id = "deter_protected_3", type = "deter_protected", territory_type = "uc",
                  territory_name = "UC Y", area_ha = 80.0, classname = "DEGRADACAO",
                  view_date = D, meta = "UC Y · 80.0 ha DETER",
                  state = "DEGRADACAO · " .. D, center = { -8, -55 }, radius_km = 5, ts = "12:00" },
            }), 86400)

            local result = alerts.generate_all_alerts({}, nil, "demo")
            local found
            for _, a in ipairs(result.alerts) do
                if a.type == "deter_protected" and a.id == "deter_protected_3" then found = a end
            end
            assert.is_not_nil(found)  -- Inc 12: falha alto e claro se a entrada sumiu (não-vacuoso)
            assert.are_equal("crit", found.tick)
        end)

        it("ticks by the MAX severity class in the full classes list (Inc 10)", function()
            redis.set("alerts:deter_protected", cjson.encode({
                { id = "deter_protected_10", type = "deter_protected", territory_type = "uc",
                  territory_name = "UC Z", area_ha = 10.0,
                  classes = { "DEGRADACAO", "MINERACAO" },
                  view_date = D, meta = "UC Z · 10.0 ha DETER",
                  state = "DETER · " .. D, center = { -8, -55 }, radius_km = 5, ts = "12:00" },
            }), 86400)

            local result = alerts.generate_all_alerts({}, nil, "demo")
            local found
            for _, a in ipairs(result.alerts) do
                if a.type == "deter_protected" and a.id == "deter_protected_10" then found = a end
            end
            assert.is_not_nil(found)
            -- MINERACAO é a classe de maior severidade em {DEGRADACAO, MINERACAO} → crit
            assert.are_equal("crit", found.tick)
            redis.delete("alerts:deter_protected")
        end)

        it("legacy rows without classes still tick by classname (Inc 10)", function()
            redis.set("alerts:deter_protected", cjson.encode({
                { id = "deter_protected_11", type = "deter_protected", territory_type = "uc",
                  territory_name = "UC W", area_ha = 10.0, classname = "DEGRADACAO",
                  view_date = D, meta = "UC W · 10.0 ha DETER",
                  state = "DEGRADACAO · " .. D, center = { -8, -55 }, radius_km = 5, ts = "12:00" },
            }), 86400)

            local result = alerts.generate_all_alerts({}, nil, "demo")
            local found
            for _, a in ipairs(result.alerts) do
                if a.type == "deter_protected" and a.id == "deter_protected_11" then found = a end
            end
            assert.is_not_nil(found)
            -- sem `classes` → fallback `classname` (DEGRADACAO, não-crit) → warn
            assert.are_equal("warn", found.tick)
            redis.delete("alerts:deter_protected")
        end)
    end)
end)

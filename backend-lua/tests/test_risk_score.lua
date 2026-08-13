-- test_risk_score.lua — motor de score de risco (fatores, níveis, recomendação,
-- dados ausentes → neutro, resolve_property_id para as 3 chaves de entrada).
dofile("tests/helpers.lua")
local env = require("app.env")
local sqlite3 = require("lsqlite3")

local tmp_db = "./yvy_risk_test_" .. tostring(os.time()) .. ".db"
env.set("RISK_DB_PATH", tmp_db)

package.loaded["app.risk_score"] = nil
package.loaded["app.lookups.risk_precompute"] = nil
local risk_score = require("app.risk_score")
local risk_precompute = require("app.lookups.risk_precompute")

describe("risk_score", function()
    it("scores high when deforestation + protected overlap are high", function()
        local res = risk_score.score({ cod_imovel = "RO-1" }, {
            deforestation = 1.0,
            protected_overlap = 1.0,
            embargo = 1.0,
            car_status = "suspenso",
            fires = 20,
        })
        assert.is_true(res.score >= 70, "expected high score, got " .. res.score)
        assert.are_equal("alto", res.level)
        assert.is_true(#res.factors >= 5)
    end)

    it("scores low when no risk factors", function()
        local res = risk_score.score({ cod_imovel = "MT-1" }, {
            deforestation = 0.0,
            protected_overlap = 0.0,
            embargo = 0.0,
            car_status = "ativo",
            fires = 0,
        })
        assert.is_true(res.score < 40, "expected low score, got " .. res.score)
        assert.are_equal("baixo", res.level)
    end)

    it("distinguishes no-evidence (score 0) from low risk", function()
        local no_evidence = risk_score.score({ cod_imovel = "X-1" }, {})
        assert.are_equal(0, no_evidence.score)
        assert.are_equal(1, no_evidence.evidence_gap)
        assert.is_true(no_evidence.recommendation:find("Sem evidência", 1, true) ~= nil)
    end)

    it("missing data → neutral factor, never crash", function()
        local res = risk_score.score({ cod_imovel = "Y-1" }, { deforestation = nil })
        assert.is_true(type(res.score) == "number")
        assert.is_true(type(res.level) == "string")
        assert.is_true(type(res.recommendation) == "string")
    end)

    it("resolve_property_id prefers cod_imovel, then cnpj, then lat:lon", function()
        assert.are_equal("RO-1", risk_score.resolve_property_id({ cod_imovel = "ro-1", cnpj = "123" }))
        assert.are_equal("12345678000199", risk_score.resolve_property_id({ cnpj = "12.345.678/0001-99" }))
        assert.are_equal("-10.50000:-60.50000", risk_score.resolve_property_id({ lat = -10.5, lon = -60.5 }))
        assert.are_equal("", risk_score.resolve_property_id({}))
    end)

    it("derives deforestation factor from recent_alerts", function()
        local res = risk_score.score({ cod_imovel = "RO-2" }, {
            recent_alerts = { { area_ha = 100 }, { area_ha = 50 } },
        })
        assert.is_true(res.score > 0, "expected positive score from alerts")
    end)

    it("uses area_efetiva_ha when present (Inc 3)", function()
        -- Mesmos alertas, mas com área efetiva menor (alerta cruza 2+ CARs).
        local total = risk_score.score({ cod_imovel = "RO-3" }, {
            recent_alerts = { { area_ha = 100 } },
        })
        local efetiva = risk_score.score({ cod_imovel = "RO-3" }, {
            recent_alerts = { { area_ha = 100 } },
            area_efetiva_ha = 40,
        })
        -- Área efetiva < área total → fator menor (ou igual), nunca maior.
        assert.is_true(efetiva.score <= total.score,
            "expected area_efetiva score <= total score, got " .. efetiva.score
            .. " vs " .. total.score)
        assert.is_true(efetiva.score > 0, "expected positive score from area efetiva")
    end)

    it("falls back to recent_alerts when area_efetiva_ha absent (Inc 3)", function()
        local with_total = risk_score.score({ cod_imovel = "RO-4" }, {
            recent_alerts = { { area_ha = 100 } },
        })
        local no_efetiva = risk_score.score({ cod_imovel = "RO-4" }, {
            recent_alerts = { { area_ha = 100 } },
            area_efetiva_ha = nil,
        })
        -- Sem area_efetiva_ha → usa área total (mesmo score, sem regressão).
        assert.are_equal(with_total.score, no_efetiva.score)
    end)

    it("area_efetiva_ha = area total (fracao 1) → mesmo score (sem regressão)", function()
        local total = risk_score.score({ cod_imovel = "RO-5" }, {
            recent_alerts = { { area_ha = 50 } },
        })
        local fracao1 = risk_score.score({ cod_imovel = "RO-5" }, {
            recent_alerts = { { area_ha = 50 } },
            area_efetiva_ha = 50,
        })
        assert.are_equal(total.score, fracao1.score)
    end)
end)

describe("risk_precompute", function()
    setup(function()
        risk_precompute.ensure_schema(risk_precompute._offline_conn())
    end)

    teardown(function()
        os.remove(tmp_db)
        os.remove(tmp_db .. "-wal")
        os.remove(tmp_db .. "-shm")
    end)

    it("upsert + get round-trips a score", function()
        local res = risk_score.score({ cod_imovel = "RO-1" }, {
            deforestation = 1.0, protected_overlap = 1.0,
        })
        local ok = risk_precompute.upsert("RO-1", res)
        assert.is_true(ok)
        local got = risk_precompute.get("RO-1")
        assert.is_not_nil(got)
        assert.are_equal(res.score, got.score)
        assert.are_equal("alto", got.level)
    end)

    it("get returns nil for unknown property", function()
        assert.is_nil(risk_precompute.get("NOPE-1"))
    end)

    it("bulk_upsert writes multiple rows", function()
        local rows = {}
        for i = 1, 3 do
            local pid = "BULK-" .. i
            local res = risk_score.score({ cod_imovel = pid }, {})
            rows[#rows + 1] = {
                property_id = pid,
                score = res.score,
                level = res.level,
                recommendation = res.recommendation,
                factors = res.factors,
                version_key = risk_precompute.current_version_key(),
                computed_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            }
        end
        local n = risk_precompute.bulk_upsert(rows)
        assert.are_equal(3, n)
        assert.is_not_nil(risk_precompute.get("BULK-1"))
    end)

    it("version key changes when the area_efetiva marker file changes (Inc 2)", function()
        -- Aponta o marker para um arquivo temporário e verifica que o
        -- version_key reflete o conteúdo (recomputo invalida scores).
        local marker = "./yvy_area_efetiva_version_" .. tostring(os.time()) .. ".version"
        env.set("AREA_EFETIVA_VERSION_FILE", marker)
        package.loaded["app.lookups.risk_precompute"] = nil
        local rp = require("app.lookups.risk_precompute")

        local f = io.open(marker, "w")
        f:write("20260813\n")
        f:close()
        local v1 = rp.current_version_key()

        f = io.open(marker, "w")
        f:write("20260814\n")
        f:close()
        local v2 = rp.current_version_key()

        assert.are_not_equal(v1, v2, "version key should change when marker changes")

        os.remove(marker)
        env.set("AREA_EFETIVA_VERSION_FILE", nil)
        package.loaded["app.lookups.risk_precompute"] = nil
        risk_precompute = require("app.lookups.risk_precompute")
    end)
end)

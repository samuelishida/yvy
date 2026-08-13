-- test_risk_score.lua — motor de score de risco (pilares Severity/Legality/
-- Evidence + Confidence + UNKNOWN, recomendação, dados ausentes → neutro,
-- resolve_property_id para as 3 chaves de entrada).
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
    it("scores high when severity + legality are high", function()
        local res = risk_score.score({ cod_imovel = "RO-1" }, {
            recent_alerts = { { area_ha = 3000, ano_det = 2026 } },
            embargo = 1.0,
            protected_overlap = 1.0,
        })
        assert.is_true(res.score >= 70, "expected high score, got " .. res.score)
        assert.are_equal("alto", res.level)
        assert.is_true(#res.factors >= 3)
        assert.is_not_nil(res.pillars)
        assert.is_not_nil(res.confidence)
        assert.are_equal(0, res.unknown)
    end)

    it("scores low when no risk factors", function()
        local res = risk_score.score({ cod_imovel = "MT-1" }, {
            recent_alerts = { { area_ha = 0, ano_det = 2026 } },
            embargo = 0.0,
            protected_overlap = 0.0,
        })
        assert.is_true(res.score < 40, "expected low score, got " .. res.score)
        assert.are_equal("baixo", res.level)
    end)

    it("no evidence → UNKNOWN (not 0/baixo)", function()
        local no_evidence = risk_score.score({ cod_imovel = "X-1" }, {})
        assert.are_equal("unknown", no_evidence.level)
        assert.are_equal(1, no_evidence.unknown)
        assert.are_equal(1, no_evidence.evidence_gap)
        assert.are_equal(0, no_evidence.score)
        assert.are_equal(0, no_evidence.confidence)
        assert.is_true(no_evidence.recommendation:find("Risco indeterminado", 1, true) ~= nil)
    end)

    it("missing data → neutral factor, never crash", function()
        local res = risk_score.score({ cod_imovel = "Y-1" }, { recent_alerts = nil })
        assert.is_true(type(res.score) == "number")
        assert.is_true(type(res.level) == "string")
        assert.is_true(type(res.recommendation) == "string")
        assert.is_true(type(res.pillars) == "table")
        assert.is_true(type(res.confidence) == "number")
    end)

    it("resolve_property_id prefers cod_imovel, then cnpj, then lat:lon", function()
        assert.are_equal("RO-1", risk_score.resolve_property_id({ cod_imovel = "ro-1", cnpj = "123" }))
        assert.are_equal("12345678000199", risk_score.resolve_property_id({ cnpj = "12.345.678/0001-99" }))
        assert.are_equal("-10.50000:-60.50000", risk_score.resolve_property_id({ lat = -10.5, lon = -60.5 }))
        assert.are_equal("", risk_score.resolve_property_id({}))
    end)

    it("derives severity from recent_alerts", function()
        local res = risk_score.score({ cod_imovel = "RO-2" }, {
            recent_alerts = { { area_ha = 100, ano_det = 2026 }, { area_ha = 50, ano_det = 2026 } },
        })
        assert.is_true(res.score > 0, "expected positive score from alerts")
        assert.are_equal("severity", res.factors[1].pillar)
    end)

    it("uses area_efetiva_ha when present (Inc 3)", function()
        -- Mesmos alertas, mas com área efetiva menor (alerta cruza 2+ CARs).
        local total = risk_score.score({ cod_imovel = "RO-3" }, {
            recent_alerts = { { area_ha = 100, ano_det = 2026 } },
        })
        local efetiva = risk_score.score({ cod_imovel = "RO-3" }, {
            recent_alerts = { { area_ha = 100, ano_det = 2026 } },
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
            recent_alerts = { { area_ha = 100, ano_det = 2026 } },
        })
        local no_efetiva = risk_score.score({ cod_imovel = "RO-4" }, {
            recent_alerts = { { area_ha = 100, ano_det = 2026 } },
            area_efetiva_ha = nil,
        })
        -- Sem area_efetiva_ha → usa área total (mesmo score, sem regressão).
        assert.are_equal(with_total.score, no_efetiva.score)
    end)

    it("area_efetiva_ha = area total (fracao 1) → mesmo score (sem regressão)", function()
        local total = risk_score.score({ cod_imovel = "RO-5" }, {
            recent_alerts = { { area_ha = 50, ano_det = 2026 } },
        })
        local fracao1 = risk_score.score({ cod_imovel = "RO-5" }, {
            recent_alerts = { { area_ha = 50, ano_det = 2026 } },
            area_efetiva_ha = 50,
        })
        assert.are_equal(total.score, fracao1.score)
    end)

    it("Legality can invert the headline (authorized < irregular)", function()
        -- Fazenda A: 3000 ha de supressão AUTORIZADA (Sinaflor) → legality baixa.
        local fazenda_a = risk_score.score({ cod_imovel = "A-1" }, {
            recent_alerts = { { area_ha = 3000, ano_det = 2026 } },
            sinaflor_checked = true,
            sinaflor_authorized = true,
        })
        -- Fazenda B: 500 ha IRREGULARES dentro de UC/TI → legality alta.
        local fazenda_b = risk_score.score({ cod_imovel = "B-1" }, {
            recent_alerts = { { area_ha = 500, ano_det = 2026 } },
            protected_overlap = 1.0,
        })
        assert.is_true(fazenda_a.score < fazenda_b.score,
            "expected authorized A < irregular B, got A=" .. fazenda_a.score
            .. " B=" .. fazenda_b.score)
    end)

    it("Sinaflor absence is neutral, never penalizes", function()
        -- checked=false (sem DB) → neutro, não penaliza.
        local no_check = risk_score.score({ cod_imovel = "C-1" }, {
            recent_alerts = { { area_ha = 100, ano_det = 2026 } },
            sinaflor_checked = false,
        })
        -- checked=true mas não autorizado → também neutro.
        local checked_no_auth = risk_score.score({ cod_imovel = "C-2" }, {
            recent_alerts = { { area_ha = 100, ano_det = 2026 } },
            sinaflor_checked = true,
            sinaflor_authorized = false,
        })
        -- Ambos devem ter o mesmo score (Sinaflor não altera nada).
        assert.are_equal(no_check.score, checked_no_auth.score)
    end)

    it("confidence reflects evidence coverage", function()
        -- Só severity alimentado → evidence = 0.55 → confidence 55.
        local sev_only = risk_score.score({ cod_imovel = "D-1" }, {
            recent_alerts = { { area_ha = 100, ano_det = 2026 } },
        })
        assert.are_equal(55, sev_only.confidence)
        assert.are_equal(0.55, sev_only.pillars.evidence)
        -- Severity + legality → evidence = 1.0 → confidence 100.
        local both = risk_score.score({ cod_imovel = "D-2" }, {
            recent_alerts = { { area_ha = 100, ano_det = 2026 } },
            embargo = 1.0,
        })
        assert.are_equal(100, both.confidence)
        assert.are_equal(1.0, both.pillars.evidence)
    end)

    it("headline renormalizes over the fed pillar (single-signal not halved)", function()
        -- Só severity → headline = severity (não 0.55 * severity).
        local sev_only = risk_score.score({ cod_imovel = "E-1" }, {
            recent_alerts = { { area_ha = 5000, ano_det = 2026 } },
        })
        -- severity ≈ 0.84 (área na referência, diluída por count/recency).
        -- Se o headline fosse 0.55*severity, seria ≈ 46; renormalizado é ≈ 84.
        assert.is_true(sev_only.score >= 60,
            "expected renormalized headline (not halved), got " .. sev_only.score)
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
            recent_alerts = { { area_ha = 100, ano_det = 2026 } },
            embargo = 1.0,
        })
        local ok = risk_precompute.upsert("RO-1", res)
        assert.is_true(ok)
        local got = risk_precompute.get("RO-1")
        assert.is_not_nil(got)
        assert.are_equal(res.score, got.score)
        assert.are_equal("alto", got.level)
    end)

    it("upsert + get round-trips pillars/confidence/unknown (Inc 2)", function()
        local res = risk_score.score({ cod_imovel = "RO-6" }, {
            recent_alerts = { { area_ha = 100, ano_det = 2026 } },
            embargo = 1.0,
        })
        local ok = risk_precompute.upsert("RO-6", res)
        assert.is_true(ok)
        local got = risk_precompute.get("RO-6")
        assert.is_not_nil(got)
        assert.are_equal(res.pillars.severity, got.pillars.severity)
        assert.are_equal(res.pillars.legality, got.pillars.legality)
        assert.are_equal(res.pillars.evidence, got.pillars.evidence)
        assert.are_equal(res.confidence, got.confidence)
        assert.are_equal(res.unknown, got.unknown)
        assert.are_equal(res.evidence_gap, got.evidence_gap)
    end)

    it("upsert + get round-trips an UNKNOWN score (Inc 2)", function()
        local res = risk_score.score({ cod_imovel = "RO-7" }, {})
        assert.are_equal("unknown", res.level)
        local ok = risk_precompute.upsert("RO-7", res)
        assert.is_true(ok)
        local got = risk_precompute.get("RO-7")
        assert.is_not_nil(got)
        assert.are_equal("unknown", got.level)
        assert.are_equal(1, got.unknown)
        assert.are_equal(0, got.confidence)
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

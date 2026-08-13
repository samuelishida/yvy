-- test_run_batch_analysis.lua — batch offline (plan: risk-score-pillars, Inc 3).
--
-- Verifica que o build_ctx do run_batch_analysis alimenta os sinais de
-- Legality (protected_overlap + sinaflor_authorized) e que a inversão de
-- Legality está wired através do caminho batch (não só no engine unit).
--
-- Stubs os lookups (car_lookup/mapbiomas/embargo/area_efetiva/
-- car_protected/sinaflor) para não depender de DBs reais. O Redis é stubado
-- (common-mistake §2) para não vazar keys no namespace compartilhado.

dofile("tests/helpers.lua")
local env = require("app.env")
local sqlite3 = require("lsqlite3")

local tmp_db = "./yvy_batch_risk_" .. tostring(os.time()) .. ".db"
env.set("RISK_DB_PATH", tmp_db)

package.loaded["app.risk_score"] = nil
package.loaded["app.lookups.risk_precompute"] = nil
package.loaded["tools.run_batch_analysis"] = nil

local risk_score = require("app.risk_score")
local risk_precompute = require("app.lookups.risk_precompute")
local batch = require("tools.run_batch_analysis")

-- Stub Redis (common-mistake §2): get→nil = miss; set grava num map local.
local redis_state = {}
local redis = require("app.redis")
local original_get, original_set = redis.get, redis.set
redis.get = function(key) return redis_state[key] end
redis.set = function(key, value, ttl) redis_state[key] = value end

-- Stubs dos lookups. Cada um é substituído por uma função determinística.
local car_lookup = require("app.lookups.car_lookup")
local mapbiomas = require("app.lookups.mapbiomas_lookup")
local embargo = require("app.lookups.embargo_lookup")
local area_efetiva = require("app.lookups.area_efetiva_lookup")
local car_protected = require("app.lookups.car_protected_overlap")
local sinaflor = require("app.lookups.sinaflor_lookup")

local orig = {
    car_lookup_load = car_lookup.load_car,
    car_lookup_classify = car_lookup.classify_point,
    mapbiomas_load = mapbiomas.load_mapbiomas,
    mapbiomas_alerts = mapbiomas.get_alerts_by_car,
    embargo_load = embargo.load_embargo,
    embargo_active = embargo.has_active_embargo,
    area_load = area_efetiva.load_area_efetiva,
    area_sum = area_efetiva.sum_by_car,
    prot_get = car_protected.get,
    sinaflor_load = sinaflor.load_sinaflor,
    sinaflor_loaded = sinaflor.is_loaded,
    sinaflor_auth = sinaflor.authorized,
}

-- Alerta MapBiomas canônico (data_deteccao string completa, ano_det int).
local function alert(area, date, year)
    return { area_ha = area, data_deteccao = date, ano_det = year }
end

describe("run_batch_analysis build_ctx (Inc 3)", function()
    setup(function()
        risk_precompute.ensure_schema(risk_precompute._offline_conn())

        -- resolve_cod_imovel: cod_imovel presente → usa direto (sem car_lookup).
        car_lookup.load_car = function() end
        car_lookup.classify_point = function() return nil end

        mapbiomas.load_mapbiomas = function() end
        embargo.load_embargo = function() end
        area_efetiva.load_area_efetiva = function() end
        sinaflor.load_sinaflor = function() end
    end)

    teardown(function()
        redis.get, redis.set = original_get, original_set
        car_lookup.load_car = orig.car_lookup_load
        car_lookup.classify_point = orig.car_lookup_classify
        mapbiomas.load_mapbiomas = orig.mapbiomas_load
        mapbiomas.get_alerts_by_car = orig.mapbiomas_alerts
        embargo.load_embargo = orig.embargo_load
        embargo.has_active_embargo = orig.embargo_active
        area_efetiva.load_area_efetiva = orig.area_load
        area_efetiva.sum_by_car = orig.area_sum
        car_protected.get = orig.prot_get
        sinaflor.load_sinaflor = orig.sinaflor_load
        sinaflor.is_loaded = orig.sinaflor_loaded
        sinaflor.authorized = orig.sinaflor_auth
        os.remove(tmp_db)
        os.remove(tmp_db .. "-wal")
        os.remove(tmp_db .. "-shm")
    end)

    it("feeds protected_overlap and sinaflor_authorized into the ctx", function()
        -- Imóvel com alerta recente, sobreposição UC/TI e autorização Sinaflor.
        mapbiomas.get_alerts_by_car = function(cod)
            return { alert(100, "2026-05-01", 2026) }
        end
        embargo.has_active_embargo = function() return false end
        area_efetiva.sum_by_car = function() return 0 end
        car_protected.get = function(cod)
            return { max_pct = 60, status = "suspeito", threshold = 0.5 }
        end
        sinaflor.is_loaded = function() return true end
        sinaflor.authorized = function(car_prop, acq_date)
            assert.are_equal("2026-05-01", acq_date, "acq_date deve ser a data_deteccao completa")
            return { nro = "ASV-1", modo = "ASV", data_inicio = "2026-01-01", data_fim = "2026-12-31" }
        end

        local res = batch.process_row({ cod_imovel = "RO-1", nome = "Fazenda A" })
        assert.is_true(res.found)
        -- Sinaflor autorizado de-risca → legality baixa → headline menor que
        -- um imóvel irregular com sobreposição e sem autorização.
        assert.is_not_nil(res.pillars)
        assert.is_not_nil(res.confidence)
        assert.are_equal(0, res.unknown)
        -- protected_overlap 60% → legality > 0 (não neutro).
        assert.is_true(res.pillars.legality > 0, "legality deve ser alimentado")
    end)

    it("Legality inversion is wired through the batch path", function()
        -- Fazenda A: 3000 ha autorizados (Sinaflor) → legality baixa.
        mapbiomas.get_alerts_by_car = function(cod)
            return { alert(3000, "2026-05-01", 2026) }
        end
        embargo.has_active_embargo = function() return false end
        area_efetiva.sum_by_car = function() return 0 end
        car_protected.get = function(cod) return nil end
        sinaflor.is_loaded = function() return true end
        sinaflor.authorized = function() return { nro = "ASV-1", modo = "ASV" } end

        local fazenda_a = batch.process_row({ cod_imovel = "A-1", nome = "Fazenda A" })

        -- Fazenda B: 500 ha irregulares dentro de UC/TI, sem autorização.
        mapbiomas.get_alerts_by_car = function(cod)
            return { alert(500, "2026-05-01", 2026) }
        end
        car_protected.get = function(cod)
            return { max_pct = 100, status = "suspeito", threshold = 0.5 }
        end
        sinaflor.authorized = function() return nil end

        local fazenda_b = batch.process_row({ cod_imovel = "B-1", nome = "Fazenda B" })

        assert.is_true(fazenda_a.score < fazenda_b.score,
            "expected authorized A < irregular B through batch, got A="
            .. fazenda_a.score .. " B=" .. fazenda_b.score)
    end)

    it("Sinaflor absence (DB not loaded) is neutral, never penalizes", function()
        mapbiomas.get_alerts_by_car = function(cod)
            return { alert(100, "2026-05-01", 2026) }
        end
        embargo.has_active_embargo = function() return false end
        area_efetiva.sum_by_car = function() return 0 end
        car_protected.get = function(cod) return nil end
        sinaflor.is_loaded = function() return false end  -- sem DB

        local res = batch.process_row({ cod_imovel = "C-1", nome = "Fazenda C" })
        assert.is_true(res.found)
        -- Sem sinaflor → sinaflor_checked=false → neutro; score vem só da
        -- severidade (não é penalizado).
        assert.is_true(res.score > 0, "expected positive score from severity")
    end)
end)

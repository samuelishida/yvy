-- test_fire_classify.lua — pure rule engine for fire-nature classification
local classify = require("app.fire_classify")

local function fire(overrides)
    local f = {
        lon = -61.9, lat = -11.0, state = "RO",
        acq_date = "2026-03-01",
        confidence = "high", bright_ti4 = 360, fire_type = "vegetation",
    }
    if overrides then
        for k, v in pairs(overrides) do f[k] = v end
    end
    return f
end

describe("fire_classify", function()
    describe("is_moratorium", function()
        it("true dentro da janela padrão (jul-out)", function()
            assert.is_true(classify.is_moratorium("RO", "2026-08-15"))
            assert.is_true(classify.is_moratorium(nil, "2026-09-01"))
            assert.is_true(classify.is_moratorium("RO", "2026-07-01"))
            assert.is_true(classify.is_moratorium("RO", "2026-10-31"))
        end)
        it("false fora da janela", function()
            assert.is_false(classify.is_moratorium("RO", "2026-03-01"))
            assert.is_false(classify.is_moratorium("RO", "2026-06-30"))
            assert.is_false(classify.is_moratorium("RO", "2026-11-01"))
        end)
        it("respeita override por estado", function()
            local cfg = { moratorium = { months = {7, 8, 9, 10}, by_state = { RO = {5, 6, 7} } } }
            assert.is_true(classify.is_moratorium("RO", "2026-05-10", cfg))
            assert.is_false(classify.is_moratorium("RO", "2026-08-10", cfg))
            assert.is_true(classify.is_moratorium("MT", "2026-08-10", cfg))  -- default global p/ MT
        end)
        it("acq_date malformado/nil → false (seguro)", function()
            assert.is_false(classify.is_moratorium("RO", "invalido"))
            assert.is_false(classify.is_moratorium("RO", nil))
        end)
    end)

    describe("thermal_weak", function()
        it("confidence string low → fraco", function()
            assert.is_true(classify.thermal_weak("low", 360, "vegetation"))
        end)
        it("confidence numérica baixa → fraco; alta → não", function()
            assert.is_true(classify.thermal_weak(15, 360, "vegetation"))
            assert.is_false(classify.thermal_weak(50, 360, "vegetation"))
        end)
        it("bright_ti4 baixo (< 310K) → fraco mesmo sem tipo industrial", function()
            local cfg = { thermal = {
                confidence_weak = {"low"}, confidence_weak_num = 20,
                bright_ti4_weak = 310, fire_type_industrial = {"other", "industrial"},
                fire_type_industrial_num = {0},
            } }
            assert.is_true(classify.thermal_weak("nominal", 300, "industrial", cfg))
            assert.is_true(classify.thermal_weak("nominal", 300, 0, cfg))
            assert.is_false(classify.thermal_weak("nominal", 340, "industrial", cfg))  -- bright alto
            assert.is_true(classify.thermal_weak("nominal", 300, "vegetation", cfg))    -- BT baixo basta
        end)
        it("nil-safe: bright_ti4 nil → não fraco", function()
            assert.is_false(classify.thermal_weak("nominal", nil, nil))
        end)
        it("default config sem industriais → ramo industrial inativo", function()
            -- Com BT alto, o ramo industrial (inativo no default) não marca fraco
            assert.is_false(classify.thermal_weak("nominal", 340, "industrial"))
            -- BT baixo segue fraco independente do tipo (regra nova)
            assert.is_true(classify.thermal_weak("nominal", 300, "industrial"))
        end)
    end)

    describe("classify_fire", function()
        it("TI + moratória → crime", function()
            local r = classify.classify_fire(fire({acq_date = "2026-08-15"}), { indigenous = "TI X" })
            assert.are_equal("crime", r.nature)
            assert.is_true(r.evidence.moratorium)
            assert.are_equal("TI", r.evidence.territory.tipo)
        end)
        it("UC fora da moratória → crime (evidência moratorium=false)", function()
            local r = classify.classify_fire(fire(), { conservation = "UC Y" })
            assert.are_equal("crime", r.nature)
            assert.is_false(r.evidence.moratorium)
        end)
        it("TI + sinal fraco → crime (TI precede o térmico)", function()
            local r = classify.classify_fire(fire({acq_date = "2026-08-15", confidence = "low", bright_ti4 = 300}), { indigenous = "TI X" })
            assert.are_equal("crime", r.nature)
        end)
        it("CAR + moratória → crime (100% ilegal)", function()
            local r = classify.classify_fire(fire({acq_date = "2026-08-15"}), { car = { name = "Fazenda A", id = "RO-1" } })
            assert.are_equal("crime", r.nature)
            assert.is_true(r.evidence.moratorium)
        end)
        it("CAR fora da moratória + autorização (stub) → permitido", function()
            local cfg = { sinaflor = function() return true end }
            local r = classify.classify_fire(fire(), { car = { name = "F", id = "1" } }, cfg)
            assert.are_equal("permitido", r.nature)
            assert.is_true(r.evidence.authorization)
        end)
        it("CAR fora da moratória sem hook → suspeito", function()
            local r = classify.classify_fire(fire(), { car = { name = "F", id = "1" } })
            assert.are_equal("suspeito", r.nature)
            assert.is_true(r.evidence.no_authorization)
        end)
        it("sem território + moratória → suspeito", function()
            local r = classify.classify_fire(fire({acq_date = "2026-08-15"}), {})
            assert.are_equal("suspeito", r.nature)
        end)
        it("sem território fora da moratória → natural", function()
            local r = classify.classify_fire(fire(), {})
            assert.are_equal("natural", r.nature)
        end)
        it("térmico fraco em terra sem território → natural", function()
            local r = classify.classify_fire(fire({acq_date = "2026-08-15", confidence = "low"}), {})
            assert.are_equal("natural", r.nature)
            assert.is_true(r.evidence.thermal_weak)
        end)
        it("NATURE_VERSION default = 2", function()
            assert.are_equal(2, classify.NATURE_VERSION)
        end)
    end)
end)

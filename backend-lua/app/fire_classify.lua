-- fire_classify.lua — Classificação da NATUREZA de um foco (100% puro, zero I/O)
--
-- Cruzamento é feito pelo chamador (lookups) e injetado via `territory`; esta
-- regra decide a natureza ∈ {crime, suspeito, permitido, natural} + evidência.
--
-- Pipeline (ordem importa):
--   1. TI/UC presente            → crime (máxima severidade; ANTES do térmico —
--                                  sinal fraco em área protegida não é alarme falso)
--   2. térmico fraco             → natural (falso alarme; cobre CAR e terra sem território)
--   3. CAR / área privada        → moratória → crime; senão autorização → permitido; senão suspeito
--   4. sem território            → moratória → suspeito; senão natural
--
-- NATURE_VERSION: versão única da regra (env FIRE_NATURE_VERSION, default 1).
-- Bump manual (ex: 2) quando o CAR importa (Inc 6) ou a config de moratória
-- muda → o backfill reclassifica focos com nature_version < NATURE_VERSION.

require("app.env")

local _M = {}

-- Versão da regra — lida no require; usada pelo backfill (tools/classify_fires.lua)
_M.NATURE_VERSION = tonumber(os.getenv("FIRE_NATURE_VERSION") or "2") or 2

local DEFAULT_CONFIG = {
    thermal = {
        confidence_weak = {"low"},            -- confidence string considerada fraca
        confidence_weak_num = 20,             -- confidence numérica abaixo disso é fraca
        bright_ti4_weak = 310.0,              -- Kelvin; abaixo + tipo industrial = fraco
        -- Valores reais do VIIRS a fixar no Inc 1 (amostra do CSV). Vazio →
        -- ramo industrial inativo (não derruba foco real por engano).
        fire_type_industrial = {},            -- strings ex: {"other","industrial"}
        fire_type_industrial_num = {},        -- numéricos ex: {0}
    },
    moratorium = {
        months = {7, 8, 9, 10},               -- janela padrão jul–out (decreto anual)
        by_state = {},                        -- override: { RO = {7,8,9,10}, ... }
    },
    sinaflor = nil,  -- hook plugável: fn(car_prop, acq_date) -> bool|nil (sem dado → não autorizado)
}

-- Mescla um cfg parcial do usuário sobre DEFAULT_CONFIG (sub-seções thermal/
-- moratorium caem no default quando ausentes; sinaflor etc. são sobrescritos).
local function merge_config(user)
    if not user then return DEFAULT_CONFIG end
    local merged = {}
    for k, v in pairs(DEFAULT_CONFIG) do merged[k] = v end
    if user.thermal then
        merged.thermal = {}
        for k, v in pairs(DEFAULT_CONFIG.thermal) do merged.thermal[k] = v end
        for k, v in pairs(user.thermal) do merged.thermal[k] = v end
    end
    if user.moratorium then
        merged.moratorium = {}
        for k, v in pairs(DEFAULT_CONFIG.moratorium) do merged.moratorium[k] = v end
        for k, v in pairs(user.moratorium) do
            if type(v) == "table" and type(merged.moratorium[k]) == "table" then
                local sub = {}
                for kk, vv in pairs(merged.moratorium[k]) do sub[kk] = vv end
                for kk, vv in pairs(v) do sub[kk] = vv end
                merged.moratorium[k] = sub
            else
                merged.moratorium[k] = v
            end
        end
    end
    for k, v in pairs(user) do
        if k ~= "thermal" and k ~= "moratorium" then
            merged[k] = v
        end
    end
    return merged
end

local function contains(list, v)
    if not list then return false end
    for _, item in ipairs(list) do
        if item == v then return true end
    end
    return false
end

-- Converte "YYYY-MM-DD" (acq_date) em {year, month, day}; nil se malformado.
local function parse_date(acq_date)
    if type(acq_date) ~= "string" then return nil end
    local y, m, d = acq_date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if not y then return nil end
    return { year = tonumber(y), month = tonumber(m), day = tonumber(d) }
end

-- A queima está dentro da janela de moratória/defeso daquele estado (ou global)?
-- Determinístico: parse manual de "YYYY-MM-DD", sem os.date.
function _M.is_moratorium(state_abbr, acq_date, cfg)
    local c = merge_config(cfg)
    local date = parse_date(acq_date)
    if not date then return false end  -- malformado → seguro (não-moratória)

    local months = c.moratorium.by_state[state_abbr] or c.moratorium.months
    return contains(months, date.month)
end

-- Sinal térmico fraco (provável alarme falso: telhado metálico, anomalia
-- industrial isolada)? confidence aceita "low"/"nominal"/"high" OU numérico.
function _M.thermal_weak(confidence, bright_ti4, fire_type, cfg)
    local c = merge_config(cfg)
    local th = c.thermal

    -- Confiança baixa (string ou numérica)
    local weak_conf = false
    if type(confidence) == "number" then
        weak_conf = confidence < (th.confidence_weak_num or 20)
    elseif type(confidence) == "string" then
        weak_conf = contains(th.confidence_weak, confidence:lower())
    end

    -- Tipo industrial/outro (só com valores conhecidos em cfg)
    local industrial = false
    if type(fire_type) == "number" then
        industrial = contains(th.fire_type_industrial_num, fire_type)
    elseif type(fire_type) == "string" and fire_type ~= "" then
        industrial = contains(th.fire_type_industrial, fire_type:lower())
    end

    -- bright_ti4 muito baixo → sempre suspeito de alarme falso.
    -- Queimadas reais (vegetação) têm bright_ti4 320-360K; valores < 310K
    -- são tipicamente telhados metálicos, solo exposto quente, ruído de sensor.
    -- O ramo "industrial" anterior era inalcançável (fire_type_industrial_num
    -- estava vazio → contains({}, 0) sempre false → ~20k falsos alarmes).
    local bt = tonumber(bright_ti4)
    if bt ~= nil and bt < (th.bright_ti4_weak or 310.0) then return true end

    return weak_conf
end

-- Classifica a natureza de um foco.
--   fire      = {lon, lat, acq_date, state, confidence, bright_ti4, fire_type}
--   territory = {indigenous=nil|nome, conservation=nil|nome, car=nil|{name,id}}
--   cfg       = opcional (DEFAULT_CONFIG por padrão)
-- Retorna { nature = "crime"|"suspeito"|"permitido"|"natural", evidence = {...} }
function _M.classify_fire(fire, territory, cfg)
    local c = merge_config(cfg)
    local evidence = {}

    -- 1. TI/UC → crime (máxima severidade; ANTES do térmico)
    if territory and (territory.indigenous or territory.conservation) then
        if territory.indigenous then
            evidence.territory = { tipo = "TI", nome = territory.indigenous }
        else
            evidence.territory = { tipo = "UC", nome = territory.conservation }
        end
        evidence.moratorium = _M.is_moratorium(fire.state, fire.acq_date, c)
        return { nature = "crime", evidence = evidence }
    end

    -- 2. Térmico fraco → natural (falso alarme não vira crime)
    if _M.thermal_weak(fire.confidence, fire.bright_ti4, fire.fire_type, c) then
        evidence.thermal_weak = true
        evidence.reason = "baixo sinal térmico / possível alarme falso"
        return { nature = "natural", evidence = evidence }
    end

    -- 3. CAR / área privada → fila temporal
    if territory and territory.car then
        evidence.car = territory.car
        if _M.is_moratorium(fire.state, fire.acq_date, c) then
            evidence.moratorium = true
            return { nature = "crime", evidence = evidence }  -- 100% ilegal
        end
        local auth = false
        if c.sinaflor then
            auth = c.sinaflor(territory.car, fire.acq_date) or false
        end
        if auth then
            evidence.authorization = true
            return { nature = "permitido", evidence = evidence }
        end
        evidence.no_authorization = true
        -- Inc 4 (plan: terrabrasilis-integration): DETER confirmou desmatamento
        -- na MESMA propriedade em ≤7 dias → suspeito vira crime (Cenário C).
        -- territory.deter é injetado pelo chamador (tools/enrich_fire_deter.lua);
        -- has_deter_nearby=false cobre as linhas Pass-2 (classname="FIRMS", fogo
        -- sem alerta DETER real) — não rotular como crime sem DETER.
        if territory.deter and territory.deter.has_deter_nearby then
            evidence.deter = territory.deter
            return { nature = "crime", evidence = evidence }
        end
        return { nature = "suspeito", evidence = evidence }
    end

    -- 4. Sem território
    if _M.is_moratorium(fire.state, fire.acq_date, c) then
        evidence.moratorium = true
        return { nature = "suspeito", evidence = evidence }
    end

    return { nature = "natural", evidence = evidence }
end

return _M

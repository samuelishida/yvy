-- risk_score.lua — motor de score de risco por-propriedade (puro, sem I/O).
--
-- Camada de decisão empresarial (plan: risk-intelligence, Inc 2). O score é
-- uma tabela de regras com pesos por ICP (não ML): cada fator contribui um
-- peso 0..1 e o score final é 0..100. A função é PURA (sem DB, sem Redis) —
-- testável isoladamente e consumida por precompute, batch API, PDF e monitor.
--
-- Níveis: alto (>=70), medio (>=40), baixo (<40). Score 0 (sem dados) é
-- distinguido de "risco baixo" pelo fator `evidence_gap` (peso 0 quando há
-- dados, peso 1 quando não há evidência → score 0 com level "baixo" mas
-- recommendation que menciona a falta de evidência).

local _M = {}

_M.LEVELS = { alto = "alto", medio = "medio", baixo = "baixo" }

-- Pesos por ICP (0..1). Editável — calibração com decisões reais é fase 2.
-- Cada fator é opcional no ctx; ausente → peso 0 (neutro, nunca crash).
_M.WEIGHTS = {
    deforestation = 0.40,   -- desmatamento recente (MapBiomas Alerta / PRODES)
    protected_overlap = 0.25, -- sobreposição com UC/TI
    embargo = 0.20,        -- embargo (IBAMA)
    car_status = 0.10,     -- status do CAR (ativo/suspenso/ausente)
    fires = 0.05,          -- focos de calor recentes
}

-- Resolve a chave surrogate de uma propriedade a partir das chaves de entrada.
-- `cod_imovel` quando presente, senão `cnpj`, senão `lat:lon` (centroide).
-- Função pura — chamada por run_batch_analysis.lua e scan_supplier_alerts.lua
-- para garantir chave consistente entre batch e monitor.
function _M.resolve_property_id(property)
    if type(property) ~= "table" then return "" end
    local cod = tostring(property.cod_imovel or ""):upper()
    if cod ~= "" then return cod end
    local cnpj = tostring(property.cnpj or ""):gsub("%D", "")
    if cnpj ~= "" then return cnpj end
    local lat = tonumber(property.lat)
    local lon = tonumber(property.lon)
    if lat and lon then
        return string.format("%.5f:%.5f", lat, lon)
    end
    return ""
end

-- Normaliza um valor 0..1 para o intervalo [0,1] (clamp).
local function clamp01(v)
    v = tonumber(v) or 0
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

-- Fator de desmatamento: usa `deforestation` (0..1) do ctx, ou deriva de
-- `recent_alerts` (lista de alertas MapBiomas) quando presente. Quando
-- `ctx.area_efetiva_ha` está presente (Inc 3), usa a área efetiva dentro do
-- imóvel em vez da área total do alerta — o risco real é proporcional à área
-- efetiva, não à área total. A mesma escala logarítmica se aplica (50 ha =
-- referência); como `area_efetiva_ha` ≤ `total_area`, o fator fica menor ou
-- igual (esperado).
local function deforestation_factor(ctx)
    if ctx.deforestation ~= nil then
        return clamp01(ctx.deforestation)
    end
    local alerts = ctx.recent_alerts
    if type(alerts) == "table" and #alerts > 0 then
        local total_area = 0
        for _, a in ipairs(alerts) do
            total_area = total_area + (tonumber(a.area_ha) or 0)
        end
        -- Área efetiva (soma das áreas dos alertas dentro do imóvel) quando
        -- presente; senão cai para a área total do alerta (fallback).
        local area = tonumber(ctx.area_efetiva_ha)
        if area == nil then
            area = total_area
        end
        -- >50 ha recente → fator alto; escala logarítmica suave.
        return clamp01(math.log(1 + area) / math.log(1 + 50))
    end
    -- Sem deforestation explícito e sem alertas → neutro (nil).
    return nil
end

-- Fator de sobreposição com área protegida (UC/TI): 0..1.
-- nil quando não informado (neutro).
local function protected_factor(ctx)
    if ctx.protected_overlap == nil then return nil end
    return clamp01(ctx.protected_overlap)
end

-- Fator de embargo: 0..1 (1 = embargado).
-- nil quando não informado (neutro).
local function embargo_factor(ctx)
    if ctx.embargo == nil then return nil end
    return clamp01(ctx.embargo)
end

-- Fator de status do CAR: 0 (ativo) .. 1 (suspenso/ausente).
-- Quando o status é desconhecido (nil/vazio), retorna nil para que o fator
-- seja neutro (não contribui para o score nem para o evidence_gap).
local function car_status_factor(ctx)
    local status = tostring(ctx.car_status or ""):lower()
    if status == "" then return nil end
    if status == "ativo" or status == "active" then return 0 end
    if status == "suspenso" or status == "suspended" then return 1 end
    if status == "ausente" or status == "missing" then return 0.5 end
    return nil
end

-- Fator de focos de calor recentes: 0..1 (1 = muitos focos).
-- nil quando ctx.fires não foi informado (neutro, não contribui).
local function fires_factor(ctx)
    if ctx.fires == nil then return nil end
    local n = tonumber(ctx.fires) or 0
    if n <= 0 then return 0 end
    return clamp01(math.log(1 + n) / math.log(1 + 20))
end

-- Score 0..100 + level + recommendation + factors.
-- `property` = {cod_imovel, area_ha, uf, municipio}; `ctx` = {deforestation,
-- protected_overlap, embargo, car_status, fires, recent_alerts,
-- area_efetiva_ha}.
function _M.score(property, ctx)
    ctx = ctx or {}
    -- Calcula cada fator; nil = neutro (não contribui para peso nem score).
    local f_def = deforestation_factor(ctx)
    local f_prot = protected_factor(ctx)
    local f_emb = embargo_factor(ctx)
    local f_car = car_status_factor(ctx)
    local f_fires = fires_factor(ctx)

    local factors = {
        { name = "deforestation",     weight = _M.WEIGHTS.deforestation,     value = f_def or 0, active = f_def ~= nil },
        { name = "protected_overlap", weight = _M.WEIGHTS.protected_overlap, value = f_prot or 0, active = f_prot ~= nil },
        { name = "embargo",           weight = _M.WEIGHTS.embargo,           value = f_emb or 0,  active = f_emb ~= nil },
        { name = "car_status",        weight = _M.WEIGHTS.car_status,        value = f_car or 0,  active = f_car ~= nil },
        { name = "fires",             weight = _M.WEIGHTS.fires,             value = f_fires or 0, active = f_fires ~= nil },
    }

    -- Score ponderado SÓ pelos fatores ativos (com dados). Fatores sem dados
    -- não contribuem — o score reflete apenas o risco real observado.
    local total_weight = 0
    local weighted = 0
    for _, f in ipairs(factors) do
        if f.active then
            total_weight = total_weight + f.weight
            weighted = weighted + f.weight * f.value
        end
    end

    -- evidence_gap: distingue "sem evidência" (score 0) de "risco baixo".
    local has_evidence = total_weight > 0
    local evidence_gap = has_evidence and 0 or 1

    local score = 0
    if total_weight > 0 then
        score = math.floor((weighted / total_weight) * 100 + 0.5)
    end
    -- Sem evidência → score 0 (distinto de "risco baixo" com dados).
    if evidence_gap == 1 then
        score = 0
    end

    local level
    if score >= 70 then
        level = _M.LEVELS.alto
    elseif score >= 40 then
        level = _M.LEVELS.medio
    else
        level = _M.LEVELS.baixo
    end

    local recommendation = _M.recommendation(level, evidence_gap, factors)
    return {
        score = score,
        level = level,
        recommendation = recommendation,
        factors = factors,
        evidence_gap = evidence_gap,
    }
end

-- Recomendação textual por nível + evidence_gap.
function _M.recommendation(level, evidence_gap, factors)
    if evidence_gap == 1 then
        return "Sem evidência suficiente — aprofundar due diligence antes de decisão."
    end
    if level == _M.LEVELS.alto then
        return "Risco alto — suspender/condicionar a relação e exigir plano de remediação."
    elseif level == _M.LEVELS.medio then
        return "Risco médio — monitorar de perto e solicitar comprovação de regularidade."
    end
    return "Risco baixo — manter monitoramento de rotina."
end

return _M

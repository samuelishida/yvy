-- risk_score.lua — motor de score de risco por-propriedade (puro, sem I/O).
--
-- Camada de decisão empresarial (plan: risk-score-pillars). O score é uma
-- tabela de regras com pesos por pilar (não ML): cada pilar contribui um
-- peso 0..1 e o score final é 0..100. A função é PURA (sem DB, sem Redis) —
-- testável isoladamente e consumida por precompute, batch API, PDF e monitor.
--
-- Modelo de 3 pilares (plan: risk-score-pillars):
--   * Severity  — "quanto aconteceu" (área, nº de alertas, recência, focos).
--   * Legality  — "quão problemático legalmente" (embargo, sobreposição UC/TI,
--                 autorização Sinaflor). Pode INVERTER a ordem do headline.
--   * Evidence  — "quanto conseguimos afirmar" (cobertura dos sinais
--                 efetivamente alimentados). Confidence = Evidence × 100.
--
-- Níveis: alto (>=70), medio (>=40), baixo (<40), unknown (evidência <
-- threshold). Ausência de evidência é um estado de primeira classe
-- `UNKNOWN / EVIDENCE_GAP`, NÃO `0/baixo` — um CNPJ sem CAR não é "risco
-- baixo", é "não sabemos".
--
-- O headline 0..100 é o blend ponderado de Severity e Legality, renormalizado
-- sobre os pilares alimentados (ex: só severity → headline = severity). O
-- headline é intencionalmente independente de Confidence; a UI sempre pareia
-- `score` + `confidence` para que um 97 com 40% de confiança seja visualmente
-- distinto de um 97 com 95%.

local _M = {}

_M.LEVELS = { alto = "alto", medio = "medio", baixo = "baixo", unknown = "unknown" }

-- Blend do headline: quanto cada pilar contribui para o 0..100.
_M.PILLAR_WEIGHTS = {
    severity = 0.55,
    legality = 0.45,
}

-- Pesos do composto de Severity (sub-fatores do pilar). Editável — calibração
-- com decisões reais é fase 2. Cada sub-fator é opcional no ctx; ausente →
-- não alimenta o pilar (neutro, nunca crash).
_M.SEVERITY_WEIGHTS = {
    area = 0.45,     -- área desmatada (log, ref AREA_REF_HA)
    count = 0.15,    -- nº de alertas (log, ref COUNT_REF)
    recency = 0.25,  -- recência do alerta mais recente (decai com a idade)
    fires = 0.15,    -- focos de calor recentes (log, ref 20)
}

-- Pesos do composto de Legality (sub-fatores do pilar). `unauthorized_suppression`
-- e `car_status` são pesos futuros, NÃO em v1 (sem fonte de dados).
_M.LEGALITY_WEIGHTS = {
    embargo = 0.40,            -- embargo IBAMA
    protected_overlap = 0.30,  -- sobreposição com UC/TI
    sinaflor_authorized = 0.30,-- autorização ASV/AUTESP vigente (de-risca)
}

-- Evidência abaixo deste valor → UNKNOWN / EVIDENCE_GAP. Re-avaliar com
-- histogramas reais de cobertura após o warm de produção.
_M.UNKNOWN_EVIDENCE_THRESHOLD = 0.15

-- Escalas de referência para o composto de Severity (documentadas,
-- calibráveis). A referência de área (5000 ha) cobre a faixa realista de
-- desmatamento por propriedade (0 a ~50.000 ha) sem saturar em 50 ha.
-- A referência de contagem (500 alertas) diferencia propriedades com poucos
-- alertas grandes vs. muitas ocorrências pequenas.
_M.AREA_REF_HA = 5000
_M.COUNT_REF = 500

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

-- Recência do alerta mais recente → 0..1 (1 = ano corrente, decai com a
-- idade). Sem ano → neutro (0.5) para não distorcer o composto.
local function recency_score(alerts)
    local latest_year = nil
    for _, a in ipairs(alerts) do
        local y = tonumber(a.ano_det)
        if y then
            if latest_year == nil or y > latest_year then latest_year = y end
        end
    end
    if latest_year == nil then return 0.5 end
    local current_year = os.date("*t").year
    local age = current_year - latest_year
    if age <= 0 then return 1.0 end
    if age == 1 then return 0.65 end
    if age == 2 then return 0.40 end
    if age == 3 then return 0.22 end
    return 0.10
end

-- Sinais de Severity alimentados (área/count/recency de recent_alerts, fires
-- de ctx.fires). Retorna lista de {id, name, max_weight, value, reason} ou nil
-- se nenhum sinal de severidade foi alimentado.
local function severity_signals(ctx)
    local signals = {}
    local alerts = ctx.recent_alerts
    local has_alerts = type(alerts) == "table" and #alerts > 0

    if has_alerts then
        local total_area = 0
        for _, a in ipairs(alerts) do
            total_area = total_area + (tonumber(a.area_ha) or 0)
        end
        -- Área efetiva dentro do imóvel quando disponível, senão área total.
        local area = tonumber(ctx.area_efetiva_ha)
        if area == nil then area = total_area end
        local count = #alerts

        signals[#signals + 1] = {
            id = "area", name = "Área desmatada",
            max_weight = _M.SEVERITY_WEIGHTS.area,
            value = clamp01(math.log(1 + area) / math.log(1 + _M.AREA_REF_HA)),
            reason = string.format("%.1f ha", area),
        }
        signals[#signals + 1] = {
            id = "count", name = "Nº de alertas",
            max_weight = _M.SEVERITY_WEIGHTS.count,
            value = clamp01(math.log(1 + count) / math.log(1 + _M.COUNT_REF)),
            reason = string.format("%d alertas", count),
        }
        signals[#signals + 1] = {
            id = "recency", name = "Recência",
            max_weight = _M.SEVERITY_WEIGHTS.recency,
            value = recency_score(alerts),
            reason = "recência do alerta mais recente",
        }
    end

    if ctx.fires ~= nil then
        local n = tonumber(ctx.fires) or 0
        signals[#signals + 1] = {
            id = "fires", name = "Focos de calor",
            max_weight = _M.SEVERITY_WEIGHTS.fires,
            value = n <= 0 and 0 or clamp01(math.log(1 + n) / math.log(1 + 20)),
            reason = n <= 0 and "sem focos" or string.format("%d focos", n),
        }
    end

    if #signals == 0 then return nil end
    return signals
end

-- Sinais de Legality alimentados (embargo, protected_overlap, sinaflor).
-- Sinaflor só REDUZ risco quando há autorização vigente; nunca penaliza
-- ausência (sinaflor_checked=false → neutro; checked mas não autorizado →
-- neutro). Retorna lista ou nil se nenhum sinal de legalidade foi alimentado.
local function legality_signals(ctx)
    local signals = {}
    if ctx.embargo ~= nil then
        local v = clamp01(ctx.embargo)
        signals[#signals + 1] = {
            id = "embargo", name = "Embargo IBAMA",
            max_weight = _M.LEGALITY_WEIGHTS.embargo,
            value = v,
            reason = v > 0 and "embargado" or "sem embargo",
        }
    end
    if ctx.protected_overlap ~= nil then
        local v = clamp01(ctx.protected_overlap)
        signals[#signals + 1] = {
            id = "protected_overlap", name = "Sobreposição UC/TI",
            max_weight = _M.LEGALITY_WEIGHTS.protected_overlap,
            value = v,
            reason = string.format("sobreposição %.0f%%", v * 100),
        }
    end
    -- Autorização Sinaflor: só alimenta quando há autorização vigente
    -- (checked=true AND authorized=true). Ausência é neutra, nunca penaliza.
    if ctx.sinaflor_checked == true and ctx.sinaflor_authorized == true then
        signals[#signals + 1] = {
            id = "sinaflor_authorized", name = "Autorização Sinaflor",
            max_weight = _M.LEGALITY_WEIGHTS.sinaflor_authorized,
            value = 0.1,  -- baixo risco legal deste ângulo
            reason = "autorização ASV/AUTESP vigente",
        }
    end
    if #signals == 0 then return nil end
    return signals
end

-- Composto de Severity 0..1 (média ponderada renormalizada dos sinais
-- alimentados). nil quando nenhum sinal de severidade foi alimentado.
local function severity_factor(ctx)
    local signals = severity_signals(ctx)
    if not signals then return nil end
    local total_w = 0
    local weighted = 0
    for _, s in ipairs(signals) do
        total_w = total_w + s.max_weight
        weighted = weighted + s.max_weight * s.value
    end
    return weighted / total_w
end

-- Composto de Legality 0..1 (média ponderada renormalizada dos sinais
-- alimentados). nil quando nenhum sinal de legalidade foi alimentado.
local function legality_factor(ctx)
    local signals = legality_signals(ctx)
    if not signals then return nil end
    local total_w = 0
    local weighted = 0
    for _, s in ipairs(signals) do
        total_w = total_w + s.max_weight
        weighted = weighted + s.max_weight * s.value
    end
    return weighted / total_w
end

-- Evidence 0..1 = cobertura ponderada dos pilares alimentados (soma dos
-- PILLAR_WEIGHTS dos pilares com ao menos um sinal). Igual ao `coverage`
-- legado em v1. Um pilar nil é tratado como peso 0.
local function evidence_score(severity, legality)
    local ev = 0
    if severity ~= nil then ev = ev + _M.PILLAR_WEIGHTS.severity end
    if legality ~= nil then ev = ev + _M.PILLAR_WEIGHTS.legality end
    return ev
end

-- Headline 0..100 = blend ponderado de Severity e Legality, renormalizado
-- sobre os pilares alimentados (ex: só severity → headline = severity), para
-- que uma propriedade de sinal único não seja artificialmente reduzida à
-- metade. Um pilar nil é tratado como peso 0 e os demais renormalizam a 1.0.
local function headline(severity, legality)
    local total_w = 0
    local weighted = 0
    if severity ~= nil then
        total_w = total_w + _M.PILLAR_WEIGHTS.severity
        weighted = weighted + _M.PILLAR_WEIGHTS.severity * severity
    end
    if legality ~= nil then
        total_w = total_w + _M.PILLAR_WEIGHTS.legality
        weighted = weighted + _M.PILLAR_WEIGHTS.legality * legality
    end
    if total_w == 0 then return 0 end
    return math.floor((weighted / total_w) * 100 + 0.5)
end

-- Score 0..100 + level + recommendation + factors + pillars + confidence.
-- `property` = {cod_imovel, area_ha, uf, municipio}; `ctx` = {recent_alerts,
-- area_efetiva_ha, fires, embargo, protected_overlap, sinaflor_checked,
-- sinaflor_authorized}.
function _M.score(property, ctx)
    ctx = ctx or {}
    local sev = severity_factor(ctx)
    local leg = legality_factor(ctx)

    -- factors[]: metadados por sinal para a tabela de evidência. `fed` diz se
    -- o sinal estava disponível; `max_weight` é o peso configurado; `weight` é
    -- a contribuição efetiva (renormalizada dentro do pilar); `reason` explica
    -- "não alimentado" / "autorizado" / "sobreposição x%" etc.
    local factors = {}
    local function append(signals, pillar)
        if not signals then return end
        local total_w = 0
        for _, s in ipairs(signals) do total_w = total_w + s.max_weight end
        for _, s in ipairs(signals) do
            factors[#factors + 1] = {
                id = s.id,
                name = s.name,
                weight = total_w > 0 and (s.max_weight / total_w) or 0,
                max_weight = s.max_weight,
                value = s.value,
                fed = true,
                reason = s.reason,
                pillar = pillar,
            }
        end
    end
    append(severity_signals(ctx), "severity")
    append(legality_signals(ctx), "legality")

    local evidence = evidence_score(sev, leg)
    local confidence = math.floor(evidence * 100 + 0.5)
    local unknown = evidence < _M.UNKNOWN_EVIDENCE_THRESHOLD and 1 or 0
    local evidence_gap = unknown
    local coverage = evidence  -- campo legado, numericamente igual em v1

    local score = 0
    local level
    if unknown == 1 then
        level = _M.LEVELS.unknown
    else
        score = headline(sev, leg)
        if score >= 70 then
            level = _M.LEVELS.alto
        elseif score >= 40 then
            level = _M.LEVELS.medio
        else
            level = _M.LEVELS.baixo
        end
    end

    local recommendation = _M.recommendation(level, evidence_gap, coverage, unknown)
    return {
        score = score,
        level = level,
        recommendation = recommendation,
        factors = factors,
        pillars = {
            severity = sev or 0,
            legality = leg or 0,
            evidence = evidence,
        },
        confidence = confidence,
        coverage = coverage,
        evidence_gap = evidence_gap,
        unknown = unknown,
    }
end

-- Recomendação textual por nível + evidence_gap + coverage + unknown.
-- Quando coverage < 1.0, anexa a cobertura de evidência para transparência
-- na decisão de compliance (ex: "cobertura de evidência: 40%").
function _M.recommendation(level, evidence_gap, coverage, unknown)
    if unknown == 1 or evidence_gap == 1 then
        return "Risco indeterminado — não foi possível vincular a propriedade a um CAR válido / evidência insuficiente."
    end
    local base
    if level == _M.LEVELS.alto then
        base = "Risco alto — suspender/condicionar a relação e exigir plano de remediação."
    elseif level == _M.LEVELS.medio then
        base = "Risco médio — monitorar de perto e solicitar comprovação de regularidade."
    else
        base = "Risco baixo — manter monitoramento de rotina."
    end
    if coverage and coverage < 0.999 then
        base = base .. string.format(" (cobertura de evidência: %d%%)", math.floor(coverage * 100 + 0.5))
    end
    return base
end

return _M

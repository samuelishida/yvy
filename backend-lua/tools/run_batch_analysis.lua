-- tools/run_batch_analysis.lua — subprocess destacado que processa um lote de
-- fornecedores (score por propriedade) e grava progresso em Redis.
--
-- WHY: o backend é um loop copas single-threaded. O score de um lote grande
-- (1.800+ propriedades) é CPU-heavy e bloquearia o loop se rodasse inline. O
-- POST /api/risk/batch dispara este script destacado (nohup ... &) e retorna o
-- batch_id cedo; o GET /api/risk/batch?id=<id> lê o progresso de Redis.
--
-- O CSV do lote é passado via arquivo temporário (path no arg[1]); o resultado
-- por propriedade é gravado em risk.db (risk_precompute.upsert) e o progresso
-- em Redis `risk:batch:<id>`.
--
-- Usage: lua5.1 tools/run_batch_analysis.lua <batch_id> <csv_path>
--
-- Require-ável para testes (padrão deter_protected_alerts.lua): exports
-- process_row e run_batch; quando carregado como módulo (busted), NÃO executa
-- o batch no load.

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local backend_dir = script_dir:gsub("[\\/]tools[\\/]$", "/")
package.path = backend_dir .. "?.lua;" .. backend_dir .. "?/init.lua;" .. package.path

local env = require("app.env")
env.load_dotenv(backend_dir .. "../.env")
env.load_dotenv(backend_dir .. ".env")

local cjson = require("cjson")
local logger = require("app.logger")
local redis = require("app.redis")
local utils = require("app.utils")
local risk_score = require("app.risk_score")
local risk_precompute = require("app.lookups.risk_precompute")
local mapbiomas = require("app.lookups.mapbiomas_lookup")
local embargo = require("app.lookups.embargo_lookup")
local area_efetiva = require("app.lookups.area_efetiva_lookup")
local car_lookup = require("app.lookups.car_lookup")
local car_protected = require("app.lookups.car_protected_overlap")
local sinaflor = require("app.lookups.sinaflor_lookup")

local _M = {}

-- Normaliza uma data "YYYY-MM-DD" estrita. Retorna a string se válida, senão
-- nil. O schema MapBiomas permite data_deteccao NULL; sem uma data válida não
-- há janela de autorização Sinaflor para casar (neutro).
local function normalize_date(s)
    if type(s) ~= "string" then return nil end
    local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return nil end
    return string.format("%s-%s-%s", y, m, d)
end

-- Data de detecção do alerta mais recente (para casar a autorização Sinaflor).
-- Usa data_deteccao (string completa) — o inteiro ano_det (ex: 2026) falharia
-- a comparação lexicográfica de janela. Retorna nil se não houver alerta ou
-- data válida.
local function latest_alert_date(alerts)
    if type(alerts) ~= "table" or #alerts == 0 then return nil end
    -- get_alerts_by_car ordena por ano_det DESC; o primeiro é o mais recente.
    for _, a in ipairs(alerts) do
        local d = normalize_date(a.data_deteccao)
        if d then return d end
    end
    return nil
end

-- Resolve o cod_imovel a partir da propriedade. Se cod_imovel já está
-- presente, usa direto. Se for lat/lon, classifica o ponto via car_lookup
-- (intersecção espacial com o polígono do CAR). CNPJ sem cod_imovel não tem
-- mapeamento direto → retorna nil (score sem evidência espacial).
local function resolve_cod_imovel(property)
    local cod = tostring(property.cod_imovel or ""):upper()
    if cod ~= "" then return cod end
    local lat = tonumber(property.lat)
    local lon = tonumber(property.lon)
    if lat and lon then
        car_lookup.load_car()
        local car = car_lookup.classify_point(lon, lat)
        if car and car.id then
            return tostring(car.id):upper()
        end
    end
    return nil
end

-- Constrói o ctx de score para uma propriedade a partir dos dados MapBiomas
-- disponíveis. Para v1, usa alertas recentes do imóvel (se houver cod_imovel)
-- e defaults neutros para os demais fatores. O fator `embargo` é alimentado
-- via embargo_lookup (Inc 2) — antes era sempre nil. O fator `deforestation`
-- usa `area_efetiva_ha` (Inc 3) quando disponível. Inc 3: alimenta
-- `protected_overlap` (UC/TI) e `sinaflor_authorized`/`sinaflor_checked`
-- (autorização ASV/AUTESP) para tornar o pilar Legality real em produção.
-- Resolve o cod_imovel a partir de lat/lon quando necessário (CNPJ sem CAR
-- não tem mapeamento → score sem evidência).
local function build_ctx(property)
    local ctx = {
        deforestation = nil,
        protected_overlap = nil,
        embargo = nil,
        car_status = nil,
        fires = nil,
        recent_alerts = nil,
        area_efetiva_ha = nil,
        sinaflor_checked = false,
        sinaflor_authorized = false,
    }
    local cod = resolve_cod_imovel(property)
    if cod then
        local alerts = mapbiomas.get_alerts_by_car(cod)
        if #alerts > 0 then
            ctx.recent_alerts = alerts
        end
        -- Embargo ativo → fator 1 (0..1). DB ausente → nil (fator neutro).
        if embargo.has_active_embargo(cod) then
            ctx.embargo = 1
        end
        -- Área efetiva (soma das áreas dos alertas dentro do imóvel). DB
        -- ausente → nil (fallback para recent_alerts no score).
        local sum = area_efetiva.sum_by_car(cod)
        if sum > 0 then
            ctx.area_efetiva_ha = sum
        end
        -- Sobreposição UC/TI: pré-cálculo car_protected_overlap. Ausente
        -- (sem precompute) → nil (neutro).
        local prot = car_protected.get(cod)
        if prot then
            -- max_pct é 0..100; mapeia para 0..1 (clamp). Verificado contra a
            -- superfície de car.lua (max_pct/100 >= OVERLAP_SUSPECT → suspeito).
            ctx.protected_overlap = math.min(1, math.max(0, (prot.max_pct or 0) / 100))
        end
        -- Sinaflor: autorização vigente na data do alerta mais recente
        -- de-risca o desmatamento. Só alimenta quando o DB está carregado e
        -- há uma data válida para casar; ausência é neutra (nunca penaliza).
        if sinaflor.is_loaded() then
            ctx.sinaflor_checked = true
            local acq_date = latest_alert_date(alerts)
            if acq_date then
                local auth = sinaflor.authorized({ id = cod }, acq_date)
                if auth then
                    ctx.sinaflor_authorized = true
                end
            end
        end
    end
    return ctx
end

-- Processa uma linha do CSV → resultado de score. Nunca aborta o lote: uma
-- propriedade sem match retorna {found=false, reason}.
function _M.process_row(row)
    local property = {
        cod_imovel = row.cod_imovel,
        cnpj = row.cnpj,
        lat = tonumber(row.lat),
        lon = tonumber(row.lon),
        nome = row.nome,
    }
    local property_id = risk_score.resolve_property_id(property)
    if property_id == "" then
        return { found = false, reason = "no_identifier" }
    end

    local result = risk_score.score(property, build_ctx(property))
    result.version_key = risk_precompute.current_version_key()
    result.computed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    risk_precompute.upsert(property_id, result)

    -- Área efetiva no payload do resultado (para o frontend exibir a coluna
    -- sem um segundo lookup). Usa o cod_imovel resolvido (lat/lon → CAR).
    -- Nil quando não há dados.
    local cod = resolve_cod_imovel(property)
    local area_efetiva_ha = nil
    if cod then
        local sum = area_efetiva.sum_by_car(cod)
        if sum > 0 then
            area_efetiva_ha = sum
        end
    end

    return {
        found = true,
        property_id = property_id,
        nome = row.nome,
        score = result.score,
        level = result.level,
        recommendation = result.recommendation,
        coverage = result.coverage,
        pillars = result.pillars,
        confidence = result.confidence,
        unknown = result.unknown,
        area_efetiva_ha = area_efetiva_ha,
    }
end

-- Processa o lote inteiro, gravando progresso em Redis.
function _M.run_batch(batch_id, csv_path)
    local f = io.open(csv_path, "r")
    if not f then
        logger.error("run_batch_analysis: csv not found at " .. tostring(csv_path))
        redis.set("risk:batch:" .. batch_id, cjson.encode({ status = "failed", error = "csv_not_found" }), 3600)
        return 0
    end
    local text = f:read("*a")
    f:close()

    -- Carrega os lookups (DBs dedicados) antes de processar o lote. Sem o
    -- load, os lookups retornam vazio e embargo/área efetiva/protected/sinaflor
    -- nunca são alimentados (fatores neutros). car_protected.get abre a
    -- conexão lazy (sem load explícito).
    mapbiomas.load_mapbiomas()
    embargo.load_embargo()
    area_efetiva.load_area_efetiva()
    sinaflor.load_sinaflor()

    local rows = utils.parse_csv(text)
    local total = #rows
    local results = {}
    local processed = 0

    -- Dedup por property_id (common-mistake #3: N+1 é smell; aqui dedup evita
    -- re-score de duplicatas no CSV). Cada linha é processada em pcall: um
    -- lookup malformado (ex: janela Sinaflor com data nil) não pode derrubar
    -- o lote inteiro — a linha vira {found=false, reason="error"} e o resto
    -- segue.
    local seen = {}
    for _, row in ipairs(rows) do
        local pid = risk_score.resolve_property_id({
            cod_imovel = row.cod_imovel,
            cnpj = row.cnpj,
            lat = tonumber(row.lat),
            lon = tonumber(row.lon),
        })
        if pid ~= "" and not seen[pid] then
            seen[pid] = true
            local ok, res = pcall(_M.process_row, row)
            if ok then
                results[#results + 1] = res
            else
                logger.warn("run_batch_analysis: row failed for " .. tostring(pid)
                    .. ": " .. tostring(res))
                results[#results + 1] = {
                    found = false,
                    reason = "error",
                    property_id = pid,
                    nome = row.nome,
                }
            end
        end
        processed = processed + 1
        if processed % 50 == 0 then
            redis.set("risk:batch:" .. batch_id,
                cjson.encode({ status = "running", total = total, processed = processed }),
                3600)
        end
    end

    redis.set("risk:batch:" .. batch_id,
        cjson.encode({ status = "done", total = total, processed = processed, results = results }),
        3600)
    return #results
end

if arg and arg[0] and arg[0]:match("run_batch_analysis%.lua$") then
    local batch_id = arg[1]
    local csv_path = arg[2]
    if not batch_id or not csv_path then
        logger.error("usage: lua5.1 tools/run_batch_analysis.lua <batch_id> <csv_path>")
        os.exit(1)
    end
    -- pcall no topo: qualquer erro (lookup load, CSV malformado, etc.) grava
    -- status "failed" no Redis em vez de deixar o frontend em loop eterno de
    -- polling com {status:"running", processed:0}.
    local ok, n = pcall(_M.run_batch, batch_id, csv_path)
    if not ok then
        logger.error("run_batch_analysis: batch failed: " .. tostring(n))
        redis.set("risk:batch:" .. batch_id,
            cjson.encode({ status = "failed", error = tostring(n) }), 3600)
        os.exit(1)
    end
    os.exit(n >= 0 and 0 or 1)
end

return _M

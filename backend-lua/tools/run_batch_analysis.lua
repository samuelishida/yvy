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

local _M = {}

-- Constrói o ctx de score para uma propriedade a partir dos dados MapBiomas
-- disponíveis. Para v1, usa alertas recentes do imóvel (se houver cod_imovel)
-- e defaults neutros para os demais fatores. O fator `embargo` é alimentado
-- via embargo_lookup (Inc 2) — antes era sempre nil. O fator `deforestation`
-- usa `area_efetiva_ha` (Inc 3) quando disponível.
local function build_ctx(property)
    local ctx = {
        deforestation = nil,
        protected_overlap = nil,
        embargo = nil,
        car_status = nil,
        fires = nil,
        recent_alerts = nil,
        area_efetiva_ha = nil,
    }
    if property.cod_imovel and property.cod_imovel ~= "" then
        local alerts = mapbiomas.get_alerts_by_car(property.cod_imovel)
        if #alerts > 0 then
            ctx.recent_alerts = alerts
        end
        -- Embargo ativo → fator 1 (0..1). DB ausente → nil (fator neutro).
        if embargo.has_active_embargo(property.cod_imovel) then
            ctx.embargo = 1
        end
        -- Área efetiva (soma das áreas dos alertas dentro do imóvel). DB
        -- ausente → nil (fallback para recent_alerts no score).
        local sum = area_efetiva.sum_by_car(property.cod_imovel)
        if sum > 0 then
            ctx.area_efetiva_ha = sum
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
    -- sem um segundo lookup). Nil quando não há dados.
    local area_efetiva_ha = nil
    if property.cod_imovel and property.cod_imovel ~= "" then
        local sum = area_efetiva.sum_by_car(property.cod_imovel)
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
    -- load, os lookups retornam vazio e embargo/área efetiva nunca são
    -- alimentados (fatores neutros).
    mapbiomas.load_mapbiomas()
    embargo.load_embargo()
    area_efetiva.load_area_efetiva()

    local rows = utils.parse_csv(text)
    local total = #rows
    local results = {}
    local processed = 0

    -- Dedup por property_id (common-mistake #3: N+1 é smell; aqui dedup evita
    -- re-score de duplicatas no CSV).
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
            results[#results + 1] = _M.process_row(row)
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
    local n = _M.run_batch(batch_id, csv_path)
    os.exit(n >= 0 and 0 or 1)
end

return _M

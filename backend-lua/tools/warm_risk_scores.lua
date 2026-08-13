-- tools/warm_risk_scores.lua — pré-cálculo offline de scores de risco.
--
-- WHY: o backend é um loop copas single-threaded. O precompute de scores para
-- muitos imóveis (batch de fornecedores) é CPU-heavy e bloquearia o loop se
-- rodasse inline. Este script roda destacado (nohup ... &) e grava em
-- risk.db; a runtime lê via risk_precompute.get.
--
-- Usage:
--   lua5.1 tools/warm_risk_scores.lua [--all] [--limit N]
-- Sem argumento → precompute para os imóveis já presentes em risk.db (recompute
-- de stale). Com --all → varre todos os cod_imovel do car.db (se disponível).
--
-- Require-ável para testes (padrão deter_protected_alerts.lua): exports
-- run_batch e internals; quando carregado como módulo (busted), NÃO executa o
-- batch no load.

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local backend_dir = script_dir:gsub("[\\/]tools[\\/]$", "/")
package.path = backend_dir .. "?.lua;" .. backend_dir .. "?/init.lua;" .. package.path

local env = require("app.env")
env.load_dotenv(backend_dir .. "../.env")
env.load_dotenv(backend_dir .. ".env")

local sqlite3    = require("lsqlite3")
local logger     = require("app.logger")
local redis      = require("app.redis")
local risk_score = require("app.risk_score")
local risk_precompute = require("app.lookups.risk_precompute")
local mapbiomas  = require("app.lookups.mapbiomas_lookup")
local embargo    = require("app.lookups.embargo_lookup")
local area_efetiva = require("app.lookups.area_efetiva_lookup")
local car_protected = require("app.lookups.car_protected_overlap")
local sinaflor   = require("app.lookups.sinaflor_lookup")

local _M = {}
-- Testes setam _skip_redis_invalidation=true para não varrer o namespace
-- risk:* do Redis compartilhado (common-mistake §2).
_M._skip_redis_invalidation = false

local BULK_CHUNK = 500

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

-- Constrói o ctx de score para uma propriedade. O batch (Inc 3) e o monitor
-- (Inc 6) preenchem o ctx com dados reais de MapBiomas/CAR. Para o embargo
-- ter efeito, `build_ctx` consulta `mapbiomas.get_alerts_by_car` (senão
-- `recent_alerts` fica nil e o score sai 0 com evidence_gap=1 — inútil) e
-- `embargo.has_active_embargo` (Inc 2). O fator `deforestation` usa
-- `area_efetiva_ha` (Inc 3) quando disponível. Inc 3: alimenta
-- `protected_overlap` (UC/TI) e `sinaflor_authorized`/`sinaflor_checked`
-- (autorização ASV/AUTESP) para tornar o pilar Legality real em produção.
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
    if property.cod_imovel and property.cod_imovel ~= "" then
        local cod = property.cod_imovel
        local alerts = mapbiomas.get_alerts_by_car(cod)
        if #alerts > 0 then
            ctx.recent_alerts = alerts
        end
        if embargo.has_active_embargo(cod) then
            ctx.embargo = 1
        end
        local sum = area_efetiva.sum_by_car(cod)
        if sum > 0 then
            ctx.area_efetiva_ha = sum
        end
        -- Sobreposição UC/TI: pré-cálculo car_protected_overlap. Ausente
        -- (sem precompute) → nil (neutro).
        local prot = car_protected.get(cod)
        if prot then
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

-- Lista os property_id a recomputar: os já presentes em risk.db (stale) ou,
-- com --all, todos os cod_imovel do car.db.
local function candidate_ids(all)
    local conn = risk_precompute._offline_conn()
    if not conn then return {} end
    local ids = {}
    if all then
        local car_path = env.get("CAR_DB_PATH") or "backend-lua/data/car/car.db"
        local f = io.open(car_path, "r")
        if f then
            f:close()
            local car_conn = sqlite3.open(car_path)
            if car_conn then
                car_conn:exec("PRAGMA query_only=ON")
                for row in car_conn:nrows("SELECT cod_imovel FROM car_data LIMIT 10000") do
                    ids[#ids + 1] = row.cod_imovel
                end
                car_conn:close()
            end
        end
    else
        for row in conn:nrows("SELECT property_id FROM risk_scores") do
            ids[#ids + 1] = row.property_id
        end
    end
    return ids
end

function _M.run_batch(all, limit)
    local lock_key = "risk:precompute:lock"
    if not _M._skip_redis_invalidation then
        if not redis.setnx(lock_key, os.time(), 3600) then
            logger.info("warm_risk_scores: lock held — skipping")
            return 0
        end
    end

    local version_key = risk_precompute.current_version_key()
    local ids = candidate_ids(all)
    if limit and limit > 0 then
        local n = math.min(limit, #ids)
        local out = {}
        for i = 1, n do out[i] = ids[i] end
        ids = out
    end

    -- Carrega os lookups (DBs dedicados) antes de recomputar. Sem o load, os
    -- lookups retornam vazio e embargo/área efetiva/protected/sinaflor nunca
    -- são alimentados. car_protected.get abre a conexão lazy (sem load).
    mapbiomas.load_mapbiomas()
    embargo.load_embargo()
    area_efetiva.load_area_efetiva()
    sinaflor.load_sinaflor()

    local rows = {}
    local total = 0
    for _, pid in ipairs(ids) do
        local property = { cod_imovel = pid }
        local result = risk_score.score(property, build_ctx(property))
        result.version_key = version_key
        result.computed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        rows[#rows + 1] = {
            property_id = pid,
            score = result.score,
            level = result.level,
            recommendation = result.recommendation,
            factors = result.factors,
            pillars = result.pillars,
            confidence = result.confidence,
            coverage = result.coverage,
            evidence_gap = result.evidence_gap,
            unknown = result.unknown,
            version_key = version_key,
            computed_at = result.computed_at,
        }
        if #rows >= BULK_CHUNK then
            total = total + risk_precompute.bulk_upsert(rows)
            rows = {}
        end
    end
    if #rows > 0 then
        total = total + risk_precompute.bulk_upsert(rows)
    end

    if not _M._skip_redis_invalidation then
        redis.set("risk:precompute:last_run", os.date("!%Y-%m-%dT%H:%M:%SZ"), 86400)
        redis.delete(lock_key)
    end
    logger.info("warm_risk_scores: wrote " .. total .. " scores")
    return total
end

if arg and arg[0] and arg[0]:match("warm_risk_scores%.lua$") then
    local all = false
    local limit = nil
    for i = 1, #arg do
        if arg[i] == "--all" then all = true end
        if arg[i] == "--limit" then limit = tonumber(arg[i + 1]) end
    end
    local n = _M.run_batch(all, limit)
    os.exit(n >= 0 and 0 or 1)
end

return _M

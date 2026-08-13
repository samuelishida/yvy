-- area_efetiva_lookup.lua — effective deforestation area per CAR property.
--
-- area_efetiva.db é um SQLite dedicado (AREA_EFETIVA_DB_PATH) gerado OFFLINE
-- pelo scripts/data/compute_area_efetiva.py (nunca tocado pelo loop copas).
-- Cada linha = um par (alert_code, cod_imovel) com a área efetiva do alerta
-- dentro do imóvel (ha) e a fração do alerta que ele representa.
--
-- Runtime: pré-carrega TODAS as linhas em memória (mapa cod_imovel → lista de
-- pares) no load — nunca query por alerta (common-mistake #3, N+1 é smell). O
-- handle `query_only=ON` sobrevive à troca de arquivo por scp/importer entre
-- runs (padrão car_lookup.lua), e `is_loaded()` tem memo de 60s (padrão
-- sinaflor_lookup.lua).

require("app.env")
local env     = require("app.env")
local sqlite3 = require("lsqlite3")
local logger  = require("app.logger")

local _M = {}

-- Resolve o caminho do area_efetiva.db (env AREA_EFETIVA_DB_PATH primeiro,
-- senão padrão com fallback de diretórios, espelhando car_lookup.lua:15-21).
local AREA_EFETIVA_DB_PATH = env.get("AREA_EFETIVA_DB_PATH") or env.first_with_existing_parent({
    "backend-lua/data/area_efetiva/area_efetiva.db",
    "data/area_efetiva/area_efetiva.db",
    "../backend-lua/data/area_efetiva/area_efetiva.db",
    "/opt/yvy/backend-lua/data/area_efetiva/area_efetiva.db",
}) or "backend-lua/data/area_efetiva/area_efetiva.db"

local area_conn = nil
-- Mapa em memória: cod_imovel (UPPERCASE) → { {alert_code, area_efetiva_ha, fracao}, ... }
local by_car = nil
-- Mapa em memória: alert_code → { {cod_imovel, area_efetiva_ha, fracao}, ... }
local by_alert = nil

function _M.db_path()
    return AREA_EFETIVA_DB_PATH
end

-- Carrega o DB + todos os pares em memória. Nil-safe: DB ausente/corrompido
-- não derruba o chamador (o pcall é no chamador; aqui apenas desabilita).
function _M.load_area_efetiva()
    if area_conn then return end
    local f = io.open(AREA_EFETIVA_DB_PATH, "r")
    if not f then
        logger.warn("area_efetiva.db not found at " .. AREA_EFETIVA_DB_PATH
                    .. " — area efetiva lookup disabled")
        return
    end
    f:close()

    -- Read-write handle + PRAGMA query_only=ON (mesmo raciocínio de car.db: um
    -- handle WAL read-only puro cacheado fica stale após checkpoint do importer
    -- offline; query_only=ON mantém o tracking do WAL recusando escrita).
    area_conn = sqlite3.open(AREA_EFETIVA_DB_PATH)
    if not area_conn then
        logger.warn("area_efetiva.db open failed at " .. AREA_EFETIVA_DB_PATH
                    .. " — area efetiva lookup disabled")
        return
    end
    area_conn:exec("PRAGMA query_only=ON")
    area_conn:exec("PRAGMA busy_timeout=5000")
    area_conn:exec("PRAGMA cache_size=-8000")
    area_conn:exec("PRAGMA temp_store=MEMORY")

    by_car = {}
    by_alert = {}
    for row in area_conn:nrows(
        "SELECT alert_code, cod_imovel, area_efetiva_ha, fracao FROM area_efetiva"
    ) do
        local car_key = tostring(row.cod_imovel or row["cod_imovel"] or ""):upper()
        local alert_key = tostring(row.alert_code or row["alert_code"] or "")
        local entry = {
            alert_code = row.alert_code or row["alert_code"],
            cod_imovel = row.cod_imovel or row["cod_imovel"],
            area_efetiva_ha = tonumber(row.area_efetiva_ha) or 0,
            fracao = tonumber(row.fracao) or 0,
        }
        if car_key ~= "" then
            local list = by_car[car_key]
            if not list then
                list = {}
                by_car[car_key] = list
            end
            list[#list + 1] = entry
        end
        if alert_key ~= "" then
            local list = by_alert[alert_key]
            if not list then
                list = {}
                by_alert[alert_key] = list
            end
            list[#list + 1] = entry
        end
    end
    if _M.count() == 0 then
        logger.warn("area_efetiva.db is empty — area efetiva lookup disabled")
    end
end

local loaded_at = 0
local loaded_val = false

-- Memoizado com TTL curto (60s), padrão car_lookup.lua:196. O DB é um cold
-- cache; o TTL curto cobre um import offline concluindo logo após a checagem.
function _M.is_loaded()
    if not area_conn then return false end
    local now = os.time()
    if now - loaded_at < 60 then
        return loaded_val
    end
    loaded_at = now
    loaded_val = _M.count() > 0
    return loaded_val
end

function _M.count()
    if not area_conn then return 0 end
    local n = 0
    for row in area_conn:nrows("SELECT COUNT(*) AS cnt FROM area_efetiva") do
        n = tonumber(row.cnt) or 0
    end
    return n
end

-- Pares de área efetiva de um alerta (alert_code). Retorna lista (pode ser
-- vazia). Cada item = {alert_code, cod_imovel, area_efetiva_ha, fracao}.
function _M.get_by_alert(alert_code)
    if not by_alert then return {} end
    local key = tostring(alert_code or "")
    if key == "" then return {} end
    return by_alert[key] or {}
end

-- Pares de área efetiva de um imóvel CAR (cod_imovel UPPERCASE). Retorna lista
-- (pode ser vazia). Cada item = {alert_code, cod_imovel, area_efetiva_ha,
-- fracao}.
function _M.get_by_car(cod_imovel)
    if not by_car then return {} end
    local key = tostring(cod_imovel or ""):upper()
    if key == "" then return {} end
    return by_car[key] or {}
end

-- Soma das áreas efetivas dos alertas dentro de um imóvel (ha). Retorna 0
-- quando não há dados (o chamador decide se usa fallback para recent_alerts).
function _M.sum_by_car(cod_imovel)
    local pairs = _M.get_by_car(cod_imovel)
    local total = 0
    for _, p in ipairs(pairs) do
        total = total + (tonumber(p.area_efetiva_ha) or 0)
    end
    return total
end

-- Fração de um alerta dentro de um imóvel (0..1), ou nil se o par não existe.
function _M.get_fracao(alert_code, cod_imovel)
    if not by_alert then return nil end
    local alert_key = tostring(alert_code or "")
    local car_key = tostring(cod_imovel or ""):upper()
    if alert_key == "" or car_key == "" then return nil end
    local list = by_alert[alert_key]
    if not list then return nil end
    for _, p in ipairs(list) do
        if tostring(p.cod_imovel or ""):upper() == car_key then
            return tonumber(p.fracao) or 0
        end
    end
    return nil
end

return _M

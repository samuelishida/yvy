-- embargo_lookup.lua — IBAMA embargo lookup (per CAR / coordinate).
--
-- embargo.db é um SQLite dedicado (EMBARGO_DB_PATH) gerado OFFLINE pelo
-- scripts/data/download_embargo.py (nunca tocado pelo loop copas). Cada linha
-- = um termo de embargo com CAR resolvido (cod_imovel UPPERCASE, via fallback
-- espacial lat/lon→polígono no import) + geometria WKT + bbox.
--
-- Runtime: pré-carrega TODAS as linhas em memória (mapa cod_imovel → lista de
-- embargos) no load — nunca query por embargo (common-mistake #3, N+1 é smell).
-- O handle `query_only=ON` sobrevive à troca de arquivo por scp/importer entre
-- runs (padrão car_lookup.lua), e `is_loaded()` tem memo de 60s (padrão
-- sinaflor_lookup.lua).

require("app.env")
local env     = require("app.env")
local sqlite3 = require("lsqlite3")
local logger  = require("app.logger")

local _M = {}

-- Resolve o caminho do embargo.db (env EMBARGO_DB_PATH primeiro, senão padrão
-- com fallback de diretórios, espelhando car_lookup.lua:15-21).
local EMBARGO_DB_PATH = env.get("EMBARGO_DB_PATH") or env.first_with_existing_parent({
    "backend-lua/data/embargo/embargo.db",
    "data/embargo/embargo.db",
    "../backend-lua/data/embargo/embargo.db",
    "/opt/yvy/backend-lua/data/embargo/embargo.db",
}) or "backend-lua/data/embargo/embargo.db"

local embargo_conn = nil
-- Mapa em memória: cod_imovel (UPPERCASE) → { {numero, data, situacao, municipio, uf}, ... }
local by_car = nil

function _M.db_path()
    return EMBARGO_DB_PATH
end

-- Carrega o DB + todos os embargos em memória. Nil-safe: DB ausente/corrompido
-- não derruba o chamador (o pcall é no chamador; aqui apenas desabilita).
function _M.load_embargo()
    if embargo_conn then return end
    local f = io.open(EMBARGO_DB_PATH, "r")
    if not f then
        logger.warn("embargo.db not found at " .. EMBARGO_DB_PATH
                    .. " — embargo lookup disabled")
        return
    end
    f:close()

    -- Read-write handle + PRAGMA query_only=ON (mesmo raciocínio de car.db: um
    -- handle WAL read-only puro cacheado fica stale após checkpoint do importer
    -- offline; query_only=ON mantém o tracking do WAL recusando escrita).
    embargo_conn = sqlite3.open(EMBARGO_DB_PATH)
    if not embargo_conn then
        logger.warn("embargo.db open failed at " .. EMBARGO_DB_PATH
                    .. " — embargo lookup disabled")
        return
    end
    embargo_conn:exec("PRAGMA query_only=ON")
    embargo_conn:exec("PRAGMA busy_timeout=5000")
    embargo_conn:exec("PRAGMA cache_size=-8000")
    embargo_conn:exec("PRAGMA temp_store=MEMORY")

    by_car = {}
    for row in embargo_conn:nrows(
        "SELECT numero, data, situacao, municipio, uf, cod_imovel FROM embargoes"
    ) do
        local key = tostring(row.cod_imovel or row["cod_imovel"] or ""):upper()
        if key ~= "" then
            local entry = {
                numero = row.numero or row["numero"],
                data = row.data or row["data"],
                situacao = row.situacao or row["situacao"],
                municipio = row.municipio or row["municipio"],
                uf = row.uf or row["uf"],
            }
            local list = by_car[key]
            if not list then
                list = {}
                by_car[key] = list
            end
            list[#list + 1] = entry
        end
    end
    if _M.count() == 0 then
        logger.warn("embargo.db is empty — embargo lookup disabled")
    end
end

local loaded_at = 0
local loaded_val = false

-- Memoizado com TTL curto (60s), padrão car_lookup.lua:196. O DB é um cold
-- cache; o TTL curto cobre um import offline concluindo logo após a checagem.
function _M.is_loaded()
    if not embargo_conn then return false end
    local now = os.time()
    if now - loaded_at < 60 then
        return loaded_val
    end
    loaded_at = now
    loaded_val = _M.count() > 0
    return loaded_val
end

function _M.count()
    if not embargo_conn then return 0 end
    local n = 0
    for row in embargo_conn:nrows("SELECT COUNT(*) AS cnt FROM embargoes") do
        n = tonumber(row.cnt) or 0
    end
    return n
end

-- Embargos de um imóvel CAR (cod_imovel UPPERCASE). Retorna lista (pode ser
-- vazia). Cada item = {numero, data, situacao, municipio, uf}.
function _M.get_by_car(cod_imovel)
    if not by_car then return {} end
    local key = tostring(cod_imovel or ""):upper()
    if key == "" then return {} end
    return by_car[key] or {}
end

-- Embargo ativo? True se o imóvel tem ao menos um embargo (o import já filtra
-- cancelados/desembargados). Retorna false quando não há dados.
function _M.has_active_embargo(cod_imovel)
    return #_M.get_by_car(cod_imovel) > 0
end

-- Embargos cujo bbox contém (lon, lat). Usa a RTree para candidatos e
-- decodifica só os que cruzam o ponto. Retorna lista (pode ser vazia).
function _M.get_at(lon, lat)
    if not embargo_conn then return {} end
    lon = tonumber(lon)
    lat = tonumber(lat)
    if not lon or not lat then return {} end

    local rows = {}
    local stmt = embargo_conn:prepare([[
        SELECT e.numero, e.data, e.situacao, e.municipio, e.uf
        FROM embargoes_rtree r JOIN embargoes e ON e.id = r.id
        WHERE r.minLon <= ? AND r.maxLon >= ? AND r.minLat <= ? AND r.maxLat >= ?
        LIMIT 100
    ]])
    if not stmt then return {} end
    stmt:bind(1, lon)
    stmt:bind(2, lon)
    stmt:bind(3, lat)
    stmt:bind(4, lat)
    for row in stmt:nrows() do
        rows[#rows + 1] = {
            numero = row.numero or row["numero"],
            data = row.data or row["data"],
            situacao = row.situacao or row["situacao"],
            municipio = row.municipio or row["municipio"],
            uf = row.uf or row["uf"],
        }
    end
    stmt:finalize()
    return rows
end

return _M

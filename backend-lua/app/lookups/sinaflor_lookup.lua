-- sinaflor_lookup.lua — Sinaflor authorized-burn lookup (ASV/AUTESP → permitido).
--
-- sinaflor_auth.db é um SQLite dedicado (SINAFLOR_DB_PATH) gerado OFFLINE pelo
-- scripts/data/download_sinaflor_auth.py (nunca tocado pelo loop copas). Cada
-- linha = uma autorização com CAR resolvido (cod_imovel UPPERCASE, via NRO_CAR
-- explícito do ASV ou fallback espacial lat/lon→polígono no import).
--
-- Runtime: pré-carrega TODAS as janelas em memória (mapa cod_imovel → janelas)
-- no load — nunca query por foco (common-mistake #3, N+1 é smell). O hook é
-- injetado no `tools/classify_fires.lua` (subprocesso destacado) — cada run
-- carrega o DB fresco, então a troca do arquivo por scp/importer entre runs é
-- inócua. O handle `query_only=ON` sobrevive à troca de arquivo (padrão
-- car_lookup.lua), e `is_loaded()` tem memo de 60s.

require("app.env")
local env     = require("app.env")
local sqlite3 = require("lsqlite3")
local logger  = require("app.logger")

local _M = {}

-- Resolve o caminho do sinaflor_auth.db (env SINAFLOR_DB_PATH primeiro, senão
-- padrão com fallback de diretórios, espelhando car_lookup.lua:15-21).
local SINAFLOR_DB_PATH = env.get("SINAFLOR_DB_PATH") or env.first_with_existing_parent({
    "backend-lua/data/sinaflor/sinaflor_auth.db",
    "data/sinaflor/sinaflor_auth.db",
    "../backend-lua/data/sinaflor/sinaflor_auth.db",
    "/opt/yvy/backend-lua/data/sinaflor/sinaflor_auth.db",
}) or "backend-lua/data/sinaflor/sinaflor_auth.db"

local sinaflor_conn = nil
-- Mapa em memória: cod_imovel (UPPERCASE) → { {inicio, fim, nro, modo}, ... }
local windows = nil

function _M.db_path()
    return SINAFLOR_DB_PATH
end

-- Carrega o DB + todas as janelas em memória. Nil-safe: DB ausente/corrompido
-- não derruba o chamador (o pcall é no chamador; aqui apenas desabilita).
function _M.load_sinaflor()
    if sinaflor_conn then return end
    local f = io.open(SINAFLOR_DB_PATH, "r")
    if not f then
        logger.warn("sinaflor_auth.db not found at " .. SINAFLOR_DB_PATH
                    .. " — Sinaflor lookup disabled")
        return
    end
    f:close()

    -- Read-write handle + PRAGMA query_only=ON (mesmo raciocínio de car.db: um
    -- handle WAL read-only puro cacheado fica stale após checkpoint do importer
    -- offline; query_only=ON mantém o tracking do WAL recusando escrita).
    sinaflor_conn = sqlite3.open(SINAFLOR_DB_PATH)
    if not sinaflor_conn then
        logger.warn("sinaflor_auth.db open failed at " .. SINAFLOR_DB_PATH
                    .. " — Sinaflor lookup disabled")
        return
    end
    sinaflor_conn:exec("PRAGMA query_only=ON")
    sinaflor_conn:exec("PRAGMA busy_timeout=5000")
    sinaflor_conn:exec("PRAGMA cache_size=-8000")
    sinaflor_conn:exec("PRAGMA temp_store=MEMORY")

    windows = {}
    for row in sinaflor_conn:nrows(
        "SELECT cod_imovel, nro_autorizacao, modo, data_inicio, data_fim "
        .. "FROM sinaflor_auth"
    ) do
        local key = tostring(row.cod_imovel or row["cod_imovel"] or ""):upper()
        if key ~= "" then
            local entry = {
                inicio = row.data_inicio or row["data_inicio"],
                fim    = row.data_fim or row["data_fim"] or "9999-12-31",
                nro    = row.nro_autorizacao or row["nro_autorizacao"],
                modo   = row.modo or row["modo"],
            }
            local list = windows[key]
            if not list then
                list = {}
                windows[key] = list
            end
            list[#list + 1] = entry
        end
    end
    if _M.count() == 0 then
        logger.warn("sinaflor_auth.db is empty — Sinaflor lookup disabled")
    end
end

local loaded_at = 0
local loaded_val = false

-- Memoizado com TTL curto (60s), padrão car_lookup.lua:196. O DB é um cold
-- cache; o TTL curto cobre um import offline concluindo logo após a checagem.
function _M.is_loaded()
    if not sinaflor_conn then return false end
    local now = os.time()
    if now - loaded_at < 60 then
        return loaded_val
    end
    loaded_at = now
    loaded_val = _M.count() > 0
    return loaded_val
end

function _M.count()
    if not sinaflor_conn then return 0 end
    local n = 0
    for row in sinaflor_conn:nrows("SELECT COUNT(*) AS cnt FROM sinaflor_auth") do
        n = tonumber(row.cnt) or 0
    end
    return n
end

-- Autorização vigente na data do foco? car_prop é o objeto `territory.car` =
-- {id, name, uf} (retorno de car.classify_point) — NUNCA uma string. A chave do
-- mapa é `tostring(car_prop.id):upper()` (normalização concordante com a junção
-- explícita e com o fallback espacial do import).
--
-- Comparação de datas lexicográfica sobre strings "YYYY-MM-DD". Com várias
-- autorizações ativas na data, retorna a de `data_inicio` mais recente
-- (determinístico — a mais provável de ser a que autoriza a atividade).
-- Retorna {nro, modo, data_inicio, data_fim} ou nil (sem dado → não autorizado).
function _M.authorized(car_prop, acq_date)
    if type(car_prop) ~= "table" then return nil end
    local key = tostring(car_prop.id or ""):upper()
    if key == "" then return nil end
    local list = windows and windows[key]
    if not list or #list == 0 then return nil end
    if type(acq_date) ~= "string" or acq_date == "" then return nil end

    local best
    for _, w in ipairs(list) do
        if acq_date >= w.inicio and acq_date <= w.fim then
            -- `best` é montado com as chaves data_inicio/data_fim (não
            -- inicio/fim); a comparação usa data_inicio para não comparar
            -- com nil quando há 2+ janelas ativas na data.
            if not best or w.inicio > best.data_inicio then
                best = {
                    nro = w.nro,
                    modo = w.modo,
                    data_inicio = w.inicio,
                    data_fim = w.fim,
                }
            end
        end
    end
    return best
end

-- Hook plugável para fire_classify: `fn(car_prop, acq_date) -> auth|false`.
-- Devolve o OBJETO da autorização (não bool) para `evidence.authorization`
-- carregar nro/modo no popup; `false` quando não há dado. Uma linha malformada
-- (ex: janela nil) não derruba o batch inteiro (pcall, common-mistake #3).
function _M.hook()
    return function(car_prop, acq_date)
        local ok, auth = pcall(_M.authorized, car_prop, acq_date)
        if not ok then return false end
        return auth or false
    end
end

return _M

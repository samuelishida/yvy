-- mapbiomas_lookup.lua — MapBiomas Alerta deforestation-alert lookup.
--
-- mapbiomas_alerta.db é um SQLite dedicado (MAPBIOMAS_DB_PATH) gerado OFFLINE
-- pelo scripts/data/download_mapbiomas_alerta.py (nunca tocado pelo loop
-- copas). Cada linha = um alerta de desmatamento validado (polígono + bbox +
-- atributos), com cod_imovel resolvido no import (fallback espacial lat/lon →
-- polígono CAR).
--
-- Runtime: consulta o DB com `PRAGMA query_only=ON` (sobrevive à troca de
-- arquivo por scp/importer entre runs — padrão car_lookup.lua). `is_loaded()`
-- tem memo de 60s (padrão sinaflor_lookup.lua). As queries de bbox usam a
-- tabela RTree `alerts_rtree` para candidatos e paginam com LIMIT (nunca
-- varre o DB inteiro — common-mistake #3/#6).

require("app.env")
local env     = require("app.env")
local sqlite3 = require("lsqlite3")
local cjson   = require("cjson")
local logger  = require("app.logger")

local _M = {}

-- Resolve o caminho do mapbiomas_alerta.db (env MAPBIOMAS_DB_PATH primeiro,
-- senão padrão com fallback de diretórios, espelhando car_lookup.lua:15-21).
local MAPBIOMAS_DB_PATH = env.get("MAPBIOMAS_DB_PATH") or env.first_with_existing_parent({
    "backend-lua/data/mapbiomas/mapbiomas_alerta.db",
    "data/mapbiomas/mapbiomas_alerta.db",
    "../backend-lua/data/mapbiomas/mapbiomas_alerta.db",
    "/opt/yvy/backend-lua/data/mapbiomas/mapbiomas_alerta.db",
}) or "backend-lua/data/mapbiomas/mapbiomas_alerta.db"

local mapbiomas_conn = nil

function _M.db_path()
    return MAPBIOMAS_DB_PATH
end

-- Carrega o DB. Nil-safe: DB ausente/corrompido não derruba o chamador (o
-- pcall é no chamador; aqui apenas desabilita).
function _M.load_mapbiomas()
    if mapbiomas_conn then return end
    local f = io.open(MAPBIOMAS_DB_PATH, "r")
    if not f then
        logger.warn("mapbiomas_alerta.db not found at " .. MAPBIOMAS_DB_PATH
                    .. " — MapBiomas lookup disabled")
        return
    end
    f:close()

    -- Read-write handle + PRAGMA query_only=ON (mesmo raciocínio de car.db: um
    -- handle WAL read-only puro cacheado fica stale após checkpoint do importer
    -- offline; query_only=ON mantém o tracking do WAL recusando escrita).
    mapbiomas_conn = sqlite3.open(MAPBIOMAS_DB_PATH)
    if not mapbiomas_conn then
        logger.warn("mapbiomas_alerta.db open failed at " .. MAPBIOMAS_DB_PATH
                    .. " — MapBiomas lookup disabled")
        return
    end
    mapbiomas_conn:exec("PRAGMA query_only=ON")
    mapbiomas_conn:exec("PRAGMA busy_timeout=5000")
    mapbiomas_conn:exec("PRAGMA cache_size=-8000")
    mapbiomas_conn:exec("PRAGMA temp_store=MEMORY")
end

local loaded_at = 0
local loaded_val = false

-- Memoizado com TTL curto (60s), padrão car_lookup.lua:196. O DB é um cold
-- cache; o TTL curto cobre um import offline concluindo logo após a checagem.
function _M.is_loaded()
    if not mapbiomas_conn then return false end
    local now = os.time()
    if now - loaded_at < 60 then
        return loaded_val
    end
    loaded_at = now
    loaded_val = _M.count() > 0
    return loaded_val
end

function _M.count()
    if not mapbiomas_conn then return 0 end
    local n = 0
    for row in mapbiomas_conn:nrows("SELECT COUNT(*) AS cnt FROM alerts") do
        n = tonumber(row.cnt) or 0
    end
    return n
end

-- Converte uma row do DB no shape canônico de retorno.
local function to_alert(row, include_geom)
    local a = {
        alert_code = row.alert_code or row["alert_code"],
        source = row.source or row["source"],
        area_ha = tonumber(row.area_ha) or 0,
        biome = row.biome or row["biome"],
        state = row.state or row["state"],
        city = row.city or row["city"],
        ano_det = row.ano_det,
        data_deteccao = row.data_deteccao or row["data_deteccao"],
        data_publicacao = row.data_publicacao or row["data_publicacao"],
        cod_imovel = row.cod_imovel or row["cod_imovel"],
        lat = tonumber(row.lat) or 0,
        lon = tonumber(row.lon) or 0,
    }
    -- Geometria WKT (blob) para o mapa estático P5 do laudo (Inc 3). Só é
    -- selecionada quando `include_geom=true` — evita custo de I/O no caminho
    -- comum (batch/monitor não precisam de geometria).
    if include_geom then
        a.geom = row.geom or row["geom"]
    end
    return a
end

-- Alerta com bbox (minLon, maxLon, minLat, maxLat) → centroide aproximado.
-- Usado para o shape de retorno quando o DB não tem lat/lon explícito.
local function centroid_from_bbox(bbox_json)
    local ok, b = pcall(cjson.decode, bbox_json or "[]")
    if not ok or type(b) ~= "table" or #b < 4 then return 0, 0 end
    -- b = {minLon, maxLon, minLat, maxLat} (Lua array, 1-indexed)
    return (b[3] + b[4]) / 2, (b[1] + b[2]) / 2
end

-- Alertas dentro de um bbox (sw_lat, ne_lat, sw_lng, ne_lng), limitado.
-- Usa a RTree para candidatos e decodifica só os que cruzam o bbox.
function _M.get_alerts_in_bbox(sw_lat, ne_lat, sw_lng, ne_lng, limit)
    if not mapbiomas_conn then return {} end
    limit = tonumber(limit) or 100
    if limit < 1 then limit = 1 end
    if limit > 1000 then limit = 1000 end

    local rows = {}
    local stmt = mapbiomas_conn:prepare([[
        SELECT a.alert_code, a.source, a.area_ha, a.biome, a.state, a.city,
               a.ano_det, a.data_deteccao, a.data_publicacao, a.cod_imovel,
               a.bbox
        FROM alerts_rtree r JOIN alerts a ON a.id = r.id
        WHERE r.minLon <= ? AND r.maxLon >= ? AND r.minLat <= ? AND r.maxLat >= ?
        LIMIT ?
    ]])
    if not stmt then return {} end
    stmt:bind(1, ne_lng)
    stmt:bind(2, sw_lng)
    stmt:bind(3, ne_lat)
    stmt:bind(4, sw_lat)
    stmt:bind(5, limit)
    for row in stmt:nrows() do
        local lat, lon = centroid_from_bbox(row.bbox)
        local a = to_alert(row)
        a.lat = lat
        a.lon = lon
        rows[#rows + 1] = a
    end
    stmt:finalize()
    return rows
end

-- Alertas de um imóvel CAR (cod_imovel UPPERCASE). `include_geom=true` inclui
-- a geometria WKT (blob) no retorno — usado pelo laudo P5 (Inc 3).
function _M.get_alerts_by_car(cod_imovel, include_geom)
    if not mapbiomas_conn then return {} end
    local key = tostring(cod_imovel or ""):upper()
    if key == "" then return {} end

    local rows = {}
    local select_geom = include_geom and ", geom" or ""
    local stmt = mapbiomas_conn:prepare([[
        SELECT alert_code, source, area_ha, biome, state, city, ano_det,
               data_deteccao, data_publicacao, cod_imovel, bbox
        ]] .. select_geom .. [[
        FROM alerts WHERE cod_imovel = ?
        ORDER BY ano_det DESC
        LIMIT 200
    ]])
    if not stmt then return {} end
    stmt:bind(1, key)
    for row in stmt:nrows() do
        local lat, lon = centroid_from_bbox(row.bbox)
        local a = to_alert(row, include_geom)
        a.lat = lat
        a.lon = lon
        rows[#rows + 1] = a
    end
    stmt:finalize()
    return rows
end

-- Alertas recentes (data_deteccao >= hoje - days). Usado pelo monitor (Inc 6).
function _M.get_recent_alerts(days)
    if not mapbiomas_conn then return {} end
    days = tonumber(days) or 30
    if days < 1 then days = 1 end
    if days > 365 then days = 365 end
    local cutoff = os.date("!%Y-%m-%d", os.time() - days * 86400)

    local rows = {}
    local stmt = mapbiomas_conn:prepare([[
        SELECT alert_code, source, area_ha, biome, state, city, ano_det,
               data_deteccao, data_publicacao, cod_imovel, bbox
        FROM alerts
        WHERE data_deteccao >= ? OR (data_deteccao IS NULL AND ano_det >= ?)
        ORDER BY data_deteccao DESC
        LIMIT 1000
    ]])
    if not stmt then return {} end
    stmt:bind(1, cutoff)
    stmt:bind(2, tonumber(os.date("!%Y", os.time())) - 1)
    for row in stmt:nrows() do
        local lat, lon = centroid_from_bbox(row.bbox)
        local a = to_alert(row)
        a.lat = lat
        a.lon = lon
        rows[#rows + 1] = a
    end
    stmt:finalize()
    return rows
end

return _M

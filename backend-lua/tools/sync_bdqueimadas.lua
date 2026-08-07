-- tools/sync_bdqueimadas.lua — BdQueimadas (INPE) fire foci sync (detached)
--
-- Fonte complementar ao NASA FIRMS (plan: terrabrasilis-integration, Inc 10).
-- Busca focos do BdQueimadas na API INPE (GeoJSON), converte para fire_data e
-- faz upsert com ON CONFLICT DO NOTHING (dedup por lat,lon,acq_date) — quando o
-- FIRMS já tem o mesmo foco, mantém o FIRMS (maior confiança); o BDQ preenche
-- apenas gaps. source = "INPE_BDQUEIMADAS".
--
-- WHY detached: como os outros tools/ — I/O de rede + escrita em lote fora do
-- loop copas single-threaded. Roda agendado junto do sync FIRMS (~6h).
--
-- API: https://terrabrasilis.dpi.inpe.br/queimadas/api/focos/ (GeoJSON
-- FeatureCollection; propriedades como data_pas/satelite/municipio/uf). O
-- formato pode mudar — faça uma chamada manual e ajuste os mapeamentos abaixo.
-- Override via BDQ_API_URL.
--
-- Usage: lua5.1 tools/sync_bdqueimadas.lua [days]

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local backend_dir = script_dir:gsub("[\\/]tools[\\/]$", "/")
package.path = backend_dir .. "?.lua;" .. backend_dir .. "?/init.lua;" .. package.path

local env = require("app.env")
env.load_dotenv(backend_dir .. "../.env")
env.load_dotenv(backend_dir .. ".env")

local db          = require("app.db")
local redis       = require("app.redis")
local http_client = require("app.http_client")
local state_lookup = require("app.lookups.state_lookup")
local utils       = require("app.utils")
local cjson       = require("cjson")
local logger      = require("app.logger")

local days = tonumber(arg and arg[1]) or 3
local BDQ_API_URL = os.getenv("BDQ_API_URL")
    or "https://terrabrasilis.dpi.inpe.br/queimadas/api/focos/"

db.init_db()
state_lookup.load_states()

-- Mapeia uma feature GeoJSON do BdQueimadas para um doc fire_data.
-- Campos comuns (verifique no payload real): geometry.coordinates = [lon, lat];
-- properties.data_pas (YYYY-MM-DD), satelite, municipio, uf, frp.
local function feature_to_doc(f)
    local geom = f and f.geometry
    if not geom or not geom.coordinates then return nil end
    local lon, lat = tonumber(geom.coordinates[1]), tonumber(geom.coordinates[2])
    if not lon or not lat then return nil end
    local props = f.properties or {}
    local acq_date = props.data_pas or props.data or props.acq_date or ""
    if acq_date == "" then return nil end
    local satelite = props.satelite or props.satellite or ""
    local municipio = props.municipio or props.municipality or ""
    local uf = props.uf or props.state or ""
    local frp = tonumber(props.frp) or 0

    return {
        lat = lat,
        lon = lon,
        confidence = (props.confidence or "nominal"):lower(),
        acq_date = tostring(acq_date),
        acq_time = props.hora or props.acq_time or "",
        satellite = tostring(satelite),
        bright_ti4 = tonumber(props.bright_ti4) or 0,
        fire_type = props.fire_type or "vegetation",
        frp = frp,
        daynight = (props.daynight or "D"):upper(),
        source = "INPE_BDQUEIMADAS",
        state = (uf ~= "") and uf or state_lookup.classify_point(lon, lat),
        ingested_at = utils.now_iso(),
        _municipio = municipio,
    }
end

local function fetch_fires(days_back)
    local params = {}
    if days_back and days_back > 0 then
        params.time = os.date("!%Y-%m-%d", os.time() - days_back * 86400)
    end
    local res, err = http_client.get(BDQ_API_URL, { timeout = 90, query = params })
    if not res then
        return nil, "BDQ API unreachable: " .. tostring(err)
    end
    if res.status ~= 200 then
        return nil, "BDQ API returned " .. res.status
    end
    local ok, data = pcall(cjson.decode, res.body)
    if not ok or type(data) ~= "table" then
        return nil, "BDQ response not JSON (format changed?)"
    end
    local features = data.features or data
    if type(features) ~= "table" then
        return nil, "BDQ response has no features array"
    end
    return features
end

local function run()
    local features, err = fetch_fires(days)
    if not features then
        logger.warn("BdQueimadas sync skipped: " .. tostring(err))
        redis.set("fires:bdq:last_run", cjson.encode({ status = "error", error = err }), 86400)
        return
    end

    local docs = {}
    for _, f in ipairs(features) do
        local d = feature_to_doc(f)
        if d then docs[#docs + 1] = d end
    end

    -- Dedup local por (lat,lon,acq_date) antes do upsert (fonte pode repetir)
    local seen = {}
    local unique = {}
    for _, d in ipairs(docs) do
        local key = string.format("%.3f,%.3f,%s", d.lat, d.lon, d.acq_date)
        if not seen[key] then
            seen[key] = true
            unique[#unique + 1] = d
        end
    end

    local inserted = db.bulk_upsert_fires_keep_first(unique)
    redis.delete_pattern("firescache:*")

    redis.set("fires:bdq:last_run", cjson.encode({
        status = "ok", fetched = #features, docs = #unique, inserted = inserted,
        ran_at = utils.now_iso(),
    }), 86400)
    logger.info("BdQueimadas sync done: " .. #unique .. " focos (FIRMS kept on conflict)")
end

local ok, err = pcall(run)
if not ok then
    logger.error("sync_bdqueimadas failed: " .. tostring(err))
    os.exit(1)
end

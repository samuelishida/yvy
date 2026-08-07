-- tools/sync_bdqueimadas.lua — BdQueimadas (TerraBrasilis WFS) fire foci sync (detached)
--
-- Fonte complementar ao NASA FIRMS (plan: terrabrasilis-fixes, Inc 3). Descobre
-- as camadas de foco de fogo via WFS GetCapabilities do TerraBrasilis GeoServer
-- e faz upsert em fire_data com ON CONFLICT DO NOTHING (dedup por lat,lon,
-- acq_date) — quando o FIRMS já tem o mesmo foco, mantém o FIRMS (maior
-- confiança); o BDQ preenche apenas gaps. source = "bdqueimadas".
--
-- WHY WFS: o endpoint antigo (https://terrabrasilis.dpi.inpe.br/queimadas/api/
-- focos/) é um 404 vivo e a camada `bdqueimadas2:focos` não existe. Os focos de
-- fogo vivem no GeoServer como camadas de PONTO `active-fire-today` nos
-- workspaces `ams1h`/`ams3` (verificado live 2026-08-07). A descoberta roda em
-- runtime, então uma mudança de schema nunca mais mata a integração em silêncio.
--
-- WHY detached: como os outros tools/ — I/O de rede + escrita em lote fora do
-- loop copas single-threaded. Roda agendado junto do sync FIRMS (~6h).
--
-- Usage: lua5.1 tools/sync_bdqueimadas.lua [days]
--   [days] é aceito por compatibilidade de CLI mas não é usado: as camadas
--   `active-fire-today` já são "do dia" (sem filtro temporal na consulta WFS).
--   Overrides: BDQ_WFS_CAPS_URL (GetCapabilities), BDQ_WFS_URL (base GetFeature).

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local backend_dir = script_dir:gsub("[\\/]tools[\\/]$", "/")
package.path = backend_dir .. "?.lua;" .. backend_dir .. "?/init.lua;" .. package.path

local env = require("app.env")
env.load_dotenv(backend_dir .. "../.env")
env.load_dotenv(backend_dir .. ".env")

local db           = require("app.db")
local redis        = require("app.redis")
local http_client  = require("app.http_client")
local state_lookup = require("app.lookups.state_lookup")
local utils        = require("app.utils")
local cjson        = require("cjson")
local logger       = require("app.logger")

local CAPS_URL   = os.getenv("BDQ_WFS_CAPS_URL")
    or "https://terrabrasilis.dpi.inpe.br/geoserver/ows?service=WFS&request=GetCapabilities"
local WFS_BASE   = os.getenv("BDQ_WFS_URL")
    or "https://terrabrasilis.dpi.inpe.br/geoserver"
local PAGE_SIZE  = 10000

-- ── Funções puras (testáveis sem rede) ────────────────────────────────────

-- Normaliza qualquer formato de data para YYYY-MM-DD (aceita "YYYY-MM-DD",
-- "YYYY-MM-DDTHH:MM:SSZ", "YYYY-MM-DD HH:MM:SS", …). Retorna nil se não achar.
local function normalize_acq_date(v)
    if type(v) ~= "string" then return nil end
    local y, m, d = v:match("(%d%d%d%d)%D(%d%d)%D(%d%d)")
    if y and m and d then
        return y .. "-" .. m .. "-" .. d
    end
    return nil
end

-- Extrai HH:MM (e devolve "HHMM", formato usado em fire_data.acq_time) de uma
-- string tipo "14:30" / "2026-08-07T14:30:00Z". Vazio se não houver hora.
local function normalize_acq_time(v)
    if type(v) ~= "string" then return "" end
    local h, mi = v:match("(%d%d):(%d%d)")
    if h and mi then return h .. mi end
    local hhmm = v:match("^(%d%d%d%d)$")
    if hhmm then return hhmm end
    return ""
end

-- Parseia o XML de GetCapabilities (string) → { version, feature_types = {...} }.
-- `feature_types` são os <Name>workspace:camada</Name> dentro de <FeatureTypeList>.
local function parse_capabilities(xml)
    if type(xml) ~= "string" then return { version = "2.0.0", feature_types = {} } end
    local version = xml:match('<wfs:WFS_Capabilities[^>]*version="([^"]+)"')
        or xml:match('<ows:ServiceTypeVersion>([^<]+)</')
        or xml:match('version="([%d.]+)"')
        or "2.0.0"
    local feature_types = {}
    local start = xml:find("<FeatureTypeList>")
    local _, close = xml:find("</FeatureTypeList>", start or 1)
    local section = (start and close) and xml:sub(start, close) or xml
    for name in section:gmatch("<Name>([^<]+)</Name>") do
        feature_types[#feature_types + 1] = name
    end
    return { version = version, feature_types = feature_types }
end

-- Filtra as camadas de foco de FOGO (PONTO) que o BDQ ingere em fire_data.
-- Heurística: workspace começa com "ams" E nome da camada contém "active-fire".
-- Racional: `ams1h:active-fire-today` / `ams3:active-fire-today` são as camadas
-- de ponto de fogo; `fire-spreading-risk` é a camada POLÍGONO do downloader de
-- risco AMS (Inc 4) e NÃO deve ser ingerida como focos. O filtro exclui
-- naturalmente `dummy`, `cs_*_view`, `last_date`, `municipalities_border`.
local function select_fire_layers(feature_types)
    local selected = {}
    for _, ft in ipairs(feature_types or {}) do
        local ws, layer = ft:match("^([^:]+):(.+)$")
        if ws and layer
           and ws:sub(1, 3) == "ams"
           and layer:find("active-fire", 1, true) then
            selected[#selected + 1] = ft
        end
    end
    table.sort(selected)
    return selected
end

-- Mapeia uma feature do WFS (JSON GeoJSON ou GML/XML já parseado) para um doc
-- fire_data. Aceita os campos live verificados por DescribeFeatureType
-- (view_date, geom, satelite, municipio, biome, viewed_at) e os nomes legados
-- do payload antigo (data_hora_gmt, estado, longitude/latitude) — ver
-- http_client/geo: `geometry.coordinates` = [lon, lat].
local function map_feature(f)
    if type(f) ~= "table" then return nil end
    local props = (type(f.properties) == "table") and f.properties or {}

    -- Coordenadas: GeoJSON (geometry.coordinates = [lon, lat]) primeiro; depois
    -- propriedades nomeadas (longitude/latitude — formato GML/legado).
    local lon, lat
    if type(f.geometry) == "table" and type(f.geometry.coordinates) == "table" then
        lon, lat = tonumber(f.geometry.coordinates[1]), tonumber(f.geometry.coordinates[2])
    end
    if not lon or not lat then
        lon = tonumber(props.longitude) or tonumber(props.lon)
        lat = tonumber(props.latitude) or tonumber(props.lat)
    end
    if not lon or not lat then return nil end

    -- acq_date normalizado para YYYY-MM-DD (live `view_date` é xsd:date; o
    -- legado `data_hora_gmt` é datetime completo).
    local acq_date = normalize_acq_date(props.data_hora_gmt)
        or normalize_acq_date(props.view_date)
        or normalize_acq_date(props.data_pas)
        or normalize_acq_date(props.data)
        or normalize_acq_date(props.acq_date)
    if not acq_date then return nil end

    -- uf: `estado` (live) / `uf` / `state`; fallback por point-in-polygon.
    local uf = props.estado or props.uf or props.state or ""
    if type(uf) ~= "string" then uf = "" end
    uf = uf:gsub("^%s+", ""):gsub("%s+$", "")

    return {
        lat = lat,
        lon = lon,
        confidence = (props.confidence or "nominal"):lower(),
        acq_date = acq_date,
        acq_time = normalize_acq_time(props.hora or props.acq_time or props.viewed_at),
        satellite = tostring(props.satelite or props.satellite or ""),
        bright_ti4 = tonumber(props.bright_ti4) or 0,
        fire_type = props.fire_type or "vegetation",
        frp = tonumber(props.frp) or 0,
        daynight = (props.daynight or "D"):upper(),
        source = "bdqueimadas",
        state = (uf ~= "") and uf or state_lookup.classify_point(lon, lat),
        ingested_at = utils.now_iso(),
        _municipio = props.municipio or props.municipality or "",
        _biome = props.biome or "",
    }
end

-- ── Descoberta de camadas (rede) ──────────────────────────────────────────

-- Busca GetCapabilities com fallback https → http (o GeoServer público serve
-- nos dois esquemas; um erro TLS/cert no https não pode abortar a descoberta).
local function fetch_capabilities()
    local scheme = "https"
    local res, err = http_client.get(CAPS_URL, { timeout = 60, retries = 2 })
    if not res and CAPS_URL:sub(1, 8) == "https://" then
        local http_url = "http://" .. CAPS_URL:sub(9)
        logger.warn("BdQueimadas GetCapabilities https failed (" .. tostring(err)
            .. "); retrying over http")
        scheme = "http"
        res, err = http_client.get(http_url, { timeout = 60, retries = 2 })
    end
    if not res then
        return nil, "GetCapabilities unreachable (" .. scheme .. "): " .. tostring(err)
    end
    if res.status ~= 200 then
        return nil, "GetCapabilities returned HTTP " .. res.status
    end
    return { body = res.body, scheme = scheme }
end

-- Descobre as camadas de fogo. GetCapabilities inalcançável → log + exit
-- nonzero (sem run parcial); zero camadas → warn + no-op (decisão no run()).
local function discover_fire_layers()
    local caps, err = fetch_capabilities()
    if not caps then
        logger.error("BdQueimadas sync aborted: " .. tostring(err))
        redis.set("fires:bdq:last_run", cjson.encode({ status = "error", error = err }), 86400)
        os.exit(1)
    end
    local parsed = parse_capabilities(caps.body)
    local layers = select_fire_layers(parsed.feature_types)
    logger.info("BdQueimadas WFS discovery: version=" .. parsed.version
        .. " scheme=" .. caps.scheme
        .. " featureTypes=" .. #parsed.feature_types
        .. " fireLayers=" .. table.concat(layers, ","))
    return layers, parsed.version
end

-- ── Fetch com paginação (rede) ────────────────────────────────────────────

-- Fallback: GetFeature em GML/XML (algum servidor ignora outputFormat=json).
-- Extrai <member> (WFS 2.0) / <featureMember> (WFS 1.1) e as propriedades
-- elementares de cada feature; lê a coordenada de <gml:pos>/<gml:coordinates>.
local function parse_wfs_xml(body)
    if not body:find("FeatureCollection", 1, true) then
        return nil
    end
    local features = {}
    local blocks = {}
    for m in body:gmatch("<[%w:]*member>(.-)</[%w:]*member>") do
        blocks[#blocks + 1] = m
    end
    if #blocks == 0 then
        for m in body:gmatch("<[%w:]*featureMember>(.-)</[%w:]*featureMember>") do
            blocks[#blocks + 1] = m
        end
    end
    for _, blk in ipairs(blocks) do
        local props = {}
        for el, value in blk:gmatch("<([%w:]+)>([^<]*)</[%w:]*%1>") do
            props[el:match(":([^:]+)$") or el] = value
        end
        local pos = blk:match("<gml:pos>([^<]+)</gml:pos>")
            or blk:match("<gml:coordinates[^>]*>([^<]+)</gml:coordinates>")
        if pos then
            local lon_s, lat_s = pos:match("([%d%.%-]+)[%s,]+([%d%.%-]+)")
            if lon_s and lat_s then
                props.longitude = lon_s
                props.latitude = lat_s
            end
        end
        features[#features + 1] = { properties = props }
    end
    return features
end

-- Busca uma página de features da camada a partir de `start` (offset).
-- Versão do GetCapabilities decide a paginação: 2.x usa count/startindex e
-- parseia <member>; 1.x usa maxFeatures/startIndex e parseia <featureMember>.
-- Retorna lista de features ou (nil, err). Página que não é FeatureCollection
-- ou HTTP != 200 → erro alto (o run() aborta; sem truncamento silencioso).
local function fetch_wfs_page(layer, start, version)
    local ws = layer:match("^([^:]+):") or "ams"
    local major = tonumber((version or "2"):match("^(%d+)")) or 2
    local is_v2 = major >= 2

    local params = {
        service = "WFS",
        request = "GetFeature",
        outputFormat = "application/json",
    }
    if is_v2 then
        params.version = version or "2.0.0"
        params.typeNames = layer
        params.count = tostring(PAGE_SIZE)
        params.startindex = tostring(start)
    else
        params.version = version or "1.1.0"
        params.typeName = layer
        params.maxFeatures = tostring(PAGE_SIZE)
        params.startIndex = tostring(start)
    end

    local url = WFS_BASE .. "/" .. ws .. "/ows"
    local res, err = http_client.get(url, { timeout = 120, retries = 3, query = params })
    if not res then
        return nil, "WFS GetFeature unreachable: " .. tostring(err)
    end
    if res.status ~= 200 then
        return nil, "WFS GetFeature " .. layer .. " returned HTTP " .. res.status
    end
    if not res.body or res.body == "" then
        return nil, "WFS GetFeature " .. layer .. " returned empty body"
    end

    local features
    if res.body:sub(1, 1) == "<" then
        local ok, xml_feats = pcall(parse_wfs_xml, res.body)
        if not ok or not xml_feats then
            return nil, "WFS GetFeature " .. layer .. " XML is not a FeatureCollection"
        end
        features = xml_feats
    else
        local ok, data = pcall(cjson.decode, res.body)
        if not ok or type(data) ~= "table" then
            return nil, "WFS GetFeature " .. layer .. " response is not JSON"
        end
        if data.type ~= "FeatureCollection" then
            return nil, "WFS GetFeature " .. layer .. " page is not a FeatureCollection (type="
                .. tostring(data.type) .. ")"
        end
        if type(data.features) ~= "table" then
            return nil, "WFS GetFeature " .. layer .. " FeatureCollection without features"
        end
        features = data.features
    end
    return features
end

-- ── Run ───────────────────────────────────────────────────────────────────

local function run()
    -- Single-flight: sentinela curta no Redis — se outro sync BDQ está rodando,
    -- este sai sem fazer nada (TTL limpa se o processo morrer no meio).
    if not redis.setnx("fires:bdq:syncing", "1", 1800) then
        logger.warn("BdQueimadas sync skipped: another run in progress")
        return
    end

    local layers, version = discover_fire_layers()
    if #layers == 0 then
        logger.warn("BdQueimadas sync skipped: no active-fire layers discovered (no-op)")
        redis.set("fires:bdq:last_run", cjson.encode({
            status = "noop", reason = "no fire layers discovered",
        }), 86400)
        return
    end

    local docs, seen = {}, {}
    local total_pages, total_features = 0, 0
    for _, layer in ipairs(layers) do
        local pages, layer_rows = 0, 0
        local start = 0
        while true do
            local features, ferr = fetch_wfs_page(layer, start, version)
            if not features then
                logger.error("BdQueimadas sync aborted: " .. tostring(ferr))
                redis.set("fires:bdq:last_run", cjson.encode({
                    status = "error", error = ferr, layer = layer,
                }), 86400)
                os.exit(1)
            end
            pages = pages + 1
            for _, f in ipairs(features) do
                local d = map_feature(f)
                if d then
                    -- Dedup local por (lat,lon,acq_date): o mesmo foco pode
                    -- aparecer em ams1h E ams3 (ou repetido na fonte); dupes
                    -- exatos somem aqui, quase-dupes (timestamps distintos)
                    -- ficam — igual ao comportamento FIRMS.
                    local key = string.format("%.3f,%.3f,%s", d.lat, d.lon, d.acq_date)
                    if not seen[key] then
                        seen[key] = true
                        docs[#docs + 1] = d
                    end
                    layer_rows = layer_rows + 1
                end
            end
            if #features < PAGE_SIZE then break end
            start = start + #features
        end
        total_pages = total_pages + pages
        total_features = total_features + layer_rows
        logger.info("BdQueimadas layer " .. layer .. ": " .. pages .. " pages, "
            .. layer_rows .. " mapped features")
    end

    local inserted = db.bulk_upsert_fires_keep_first(docs)
    redis.delete_pattern("firescache:*")

    redis.set("fires:bdq:last_run", cjson.encode({
        status = "ok",
        layers = layers,
        version = version,
        pages = total_pages,
        features = total_features,
        docs = #docs,
        inserted = inserted,
        ran_at = utils.now_iso(),
    }), 86400)
    logger.info("BdQueimadas sync done: " .. #docs .. " focos em " .. total_pages
        .. " páginas de " .. #layers .. " camadas (" .. inserted
        .. " inseridos, FIRMS mantido no conflito)")
end

-- Roda só quando invocado como script (lua5.1 tools/sync_bdqueimadas.lua).
-- Quando `dofile`'d por um teste, expõe as funções puras sem executar o sync.
local invoked_as_script = (type(arg) == "table") and arg[0]
    and arg[0]:match("sync_bdqueimadas%.lua$") ~= nil

if invoked_as_script then
    db.init_db()
    state_lookup.load_states()
    local ok, err = pcall(run)
    if not ok then
        logger.error("sync_bdqueimadas failed: " .. tostring(err))
        os.exit(1)
    end
end

return {
    parse_capabilities  = parse_capabilities,
    select_fire_layers  = select_fire_layers,
    map_feature         = map_feature,
    normalize_acq_date  = normalize_acq_date,
    normalize_acq_time  = normalize_acq_time,
    discover_fire_layers = discover_fire_layers,
    fetch_wfs_page      = fetch_wfs_page,
    parse_wfs_xml       = parse_wfs_xml,
}

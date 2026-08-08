-- state_lookup.lua — Brazilian UF point-in-polygon lookup
-- Loads from data/states_brazil.geojson (IBGE intermediate-quality FeatureCollection).
-- Each feature.properties.codarea is the 2-digit IBGE code; mapped to UF abbreviation here.

local env    = require("app.env")
local geo    = require("app.geo")
local cjson  = require("cjson")
local logger = require("app.logger")

local _M = {}

local IBGE_TO_UF = {
    ["11"] = "RO", ["12"] = "AC", ["13"] = "AM", ["14"] = "RR",
    ["15"] = "PA", ["16"] = "AP", ["17"] = "TO",
    ["21"] = "MA", ["22"] = "PI", ["23"] = "CE", ["24"] = "RN",
    ["25"] = "PB", ["26"] = "PE", ["27"] = "AL", ["28"] = "SE", ["29"] = "BA",
    ["31"] = "MG", ["32"] = "ES", ["33"] = "RJ", ["35"] = "SP",
    ["41"] = "PR", ["42"] = "SC", ["43"] = "RS",
    ["50"] = "MS", ["51"] = "MT", ["52"] = "GO", ["53"] = "DF",
}

local UF_TO_NAME = {
    RO = "Rondônia",       AC = "Acre",          AM = "Amazonas",     RR = "Roraima",
    PA = "Pará",           AP = "Amapá",         TO = "Tocantins",
    MA = "Maranhão",       PI = "Piauí",         CE = "Ceará",        RN = "Rio Grande do Norte",
    PB = "Paraíba",        PE = "Pernambuco",    AL = "Alagoas",      SE = "Sergipe",         BA = "Bahia",
    MG = "Minas Gerais",   ES = "Espírito Santo",RJ = "Rio de Janeiro",SP = "São Paulo",
    PR = "Paraná",         SC = "Santa Catarina",RS = "Rio Grande do Sul",
    MS = "Mato Grosso do Sul", MT = "Mato Grosso", GO = "Goiás",      DF = "Distrito Federal",
}

local UF_REGION = {
    RO="N", AC="N", AM="N", RR="N", PA="N", AP="N", TO="N",
    MA="NE", PI="NE", CE="NE", RN="NE", PB="NE", PE="NE", AL="NE", SE="NE", BA="NE",
    MG="SE", ES="SE", RJ="SE", SP="SE",
    PR="S", SC="S", RS="S",
    MS="CO", MT="CO", GO="CO", DF="CO",
}

-- entries: { {uf, bbox = {min_lon, min_lat, max_lon, max_lat}, polygons = {{outer, hole1, ...}, ...}} }
local entries = {}

local function build_polygons(feature_geom)
    local polys = {}
    if feature_geom.type == "Polygon" then
        polys[#polys + 1] = feature_geom.coordinates
    elseif feature_geom.type == "MultiPolygon" then
        for _, p in ipairs(feature_geom.coordinates) do
            polys[#polys + 1] = p
        end
    end
    return polys
end

local function compute_bbox(polys)
    local min_lon, min_lat = math.huge, math.huge
    local max_lon, max_lat = -math.huge, -math.huge
    for _, poly in ipairs(polys) do
        local outer = poly[1]
        if outer then
            for _, pt in ipairs(outer) do
                local lon, lat = pt[1], pt[2]
                if lon < min_lon then min_lon = lon end
                if lat < min_lat then min_lat = lat end
                if lon > max_lon then max_lon = lon end
                if lat > max_lat then max_lat = lat end
            end
        end
    end
    return {min_lon, min_lat, max_lon, max_lat}
end

function _M.load_states()
    local paths = {
        "backend-lua/data/states_brazil.geojson",
        "data/states_brazil.geojson",
        "/opt/yvy/backend-lua/data/states_brazil.geojson",
        "../backend-lua/data/states_brazil.geojson",
    }
    local override = env.get("STATES_DATA_PATH")
    if override and override ~= "" then table.insert(paths, 1, override) end
    local resolved = env.first_existing(paths)
    if not resolved then
        logger.warn("states_brazil.geojson not found — state lookup disabled")
        return
    end

    local f = io.open(resolved, "r")
    if not f then
        logger.warn("could not open states_brazil.geojson")
        return
    end
    local raw = f:read("*a")
    f:close()

    local ok, fc = pcall(cjson.decode, raw)
    if not ok or type(fc) ~= "table" or fc.type ~= "FeatureCollection" then
        logger.warn("invalid states_brazil.geojson")
        return
    end

    entries = {}
    for _, feature in ipairs(fc.features or {}) do
        local props = feature.properties or {}
        local code = tostring(props.codarea or props.cd_uf or props.CD_UF or "")
        local uf = IBGE_TO_UF[code]
        if uf and feature.geometry then
            local polys = build_polygons(feature.geometry)
            if #polys > 0 then
                entries[#entries + 1] = {
                    uf = uf,
                    bbox = compute_bbox(polys),
                    polygons = polys,
                }
            end
        end
    end

    logger.info("Loaded ", #entries, " state polygon sets")
end

function _M.classify_point(lon, lat)
    if not lat or not lon or #entries == 0 then return nil end
    for _, entry in ipairs(entries) do
        local b = entry.bbox
        if lon >= b[1] and lon <= b[3] and lat >= b[2] and lat <= b[4] then
            for _, poly in ipairs(entry.polygons) do
                if geo.point_in_polygon(lon, lat, poly) then
                    return entry.uf
                end
            end
        end
    end
    return nil
end

function _M.list_ufs()
    local out = {}
    for uf, name in pairs(UF_TO_NAME) do
        out[#out + 1] = { sigla = uf, nome = name, regiao = UF_REGION[uf] }
    end
    table.sort(out, function(a, b) return a.sigla < b.sigla end)
    return out
end

function _M.uf_name(uf) return UF_TO_NAME[uf] end
function _M.uf_region(uf) return UF_REGION[uf] end

-- Nº de conjuntos de polígonos carregados. Usado pelos loops de backfill para
-- não rodar point-in-polygon (e marcar tudo como não-atribuível) quando o
-- layer não carregou — causa raiz dos 40% de focos com state='' vistos em prod.
function _M.loaded_count()
    return #entries
end

return _M

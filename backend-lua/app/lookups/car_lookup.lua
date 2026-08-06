-- car_lookup.lua — CAR (Cadastro Ambiental Rural) point lookup via SQLite RTree.
--
-- car.db é um SQLite dedicado (CAR_DB_PATH) com:
--   car_data  (id, cod_imovel, uf, municipio, area, geom JSONB)
--   car_rtree (índice espacial nativo 2D — query bbox)
-- classificar um ponto: rtree → ids candidatos → decodifica SÓ os candidatos →
-- ray-cast → match de MAIOR ÁREA (sobreposição). Memória baixa (nada de
-- ~0,5GB/estado em RAM como a grade em memória).

require("app.env")
local env     = require("app.env")
local geo     = require("app.geo")
local cjson   = require("cjson")
local sqlite3 = require("lsqlite3")
local logger  = require("app.logger")

local _M = {}

-- Resolve o caminho do car.db (env CAR_DB_PATH primeiro, senão padrão com
-- fallback de diretórios, espelhando db.lua)
local CAR_DB_PATH = env.get("CAR_DB_PATH") or env.first_with_existing_parent({
    "backend-lua/data/car/car.db",
    "data/car/car.db",
    "../backend-lua/data/car/car.db",
    "/opt/yvy/backend-lua/data/car/car.db",
}) or "backend-lua/data/car/car.db"

local car_conn = nil
local RTree_SQL = "SELECT id FROM car_rtree WHERE minLon<=? AND maxLon>=? AND minLat<=? AND maxLat>=?"
local GET_PREFIX = "SELECT cod_imovel, uf, municipio, area, json(geom) AS g FROM car_data WHERE id IN ("

-- Decodifica a geometria JSONB (via json(geom) já em texto) e testa o ponto.
-- GeoJSON usa [lon, lat]; geo.point_in_polygon espera {lon, lat} por vértice.
local function point_in_geojson(lon, lat, geojson_text)
    local ok, geom = pcall(cjson.decode, geojson_text)
    if not ok or type(geom) ~= "table" or not geom.coordinates then return false end

    local polys
    if geom.type == "Polygon" then
        polys = {geom.coordinates}
    elseif geom.type == "MultiPolygon" then
        polys = geom.coordinates
    else
        return false
    end

    for _, poly in ipairs(polys) do
        local rings = {}
        for _, ring in ipairs(poly) do
            local r = {}
            for _, pt in ipairs(ring) do
                r[#r + 1] = {tonumber(pt[1]), tonumber(pt[2])}
            end
            rings[#rings + 1] = r
        end
        if geo.point_in_polygon(lon, lat, rings) then
            return true
        end
    end
    return false
end

function _M.load_car()
    if car_conn then return end
    local f = io.open(CAR_DB_PATH, "r")
    if not f then
        logger.warn("car.db not found at " .. CAR_DB_PATH .. " — CAR lookup disabled")
        return
    end
    f:close()

    -- Open read-write handle + PRAGMA query_only=ON. Same reasoning as
    -- tiles.lua: a pure read-only WAL connection cached long-lived goes
    -- stale across WAL checkpoints by the offline importer ("database disk
    -- image is malformed"). query_only=ON keeps the handle tracking WAL
    -- correctly while SQLite refuses any write — car.db is a cold cache and
    -- the runtime must never write it.
    car_conn = sqlite3.open(CAR_DB_PATH)
    if not car_conn then
        logger.warn("car.db open failed at " .. CAR_DB_PATH .. " — CAR lookup disabled")
        return
    end
    car_conn:exec("PRAGMA query_only=ON")
    car_conn:exec("PRAGMA busy_timeout=5000")
    car_conn:exec("PRAGMA cache_size=-8000")
    car_conn:exec("PRAGMA temp_store=MEMORY")
    car_conn:exec("PRAGMA mmap_size=268435456")  -- leitura pesada
    if _M.count() == 0 then
        logger.warn("car.db is empty — CAR lookup disabled")
    end
end

function _M.count()
    if not car_conn then return 0 end
    local n = 0
    -- iterador nrows só funciona no protocolo `for ... in` (não dá p/ chamar
    -- iter() manualmente no lsqlite3)
    for row in car_conn:nrows("SELECT COUNT(*) AS cnt FROM car_data") do
        n = tonumber(row.cnt) or 0
    end
    return n
end

function _M.classify_point(lon, lat)
    if not car_conn then return nil end
    lon, lat = tonumber(lon), tonumber(lat)
    if not lon or not lat then return nil end

    -- 1. Candidatos via rtree (bbox contém o ponto)
    local ids = {}
    local stmt = car_conn:prepare(RTree_SQL)
    stmt:bind(1, lon)
    stmt:bind(2, lon)
    stmt:bind(3, lat)
    stmt:bind(4, lat)
    for row in stmt:nrows() do
        ids[#ids + 1] = tonumber(row.id)
    end
    stmt:finalize()
    if #ids == 0 then return nil end

    -- 2. Só os candidatos: decodifica geom → ray-cast → match de maior área
    local ph = {}
    for _ = 1, #ids do ph[#ph + 1] = "?" end
    local s2 = car_conn:prepare(GET_PREFIX .. table.concat(ph, ",") .. ")")
    for i, id in ipairs(ids) do s2:bind(i, id) end

    local best
    for row in s2:nrows() do
        local g = row.g or row["g"]
        if g and g ~= "" and point_in_geojson(lon, lat, g) then
            local area = tonumber(row.area) or 0
            if not best or area > best.area then
                best = {
                    id = row.cod_imovel,
                    name = row.municipio,
                    uf = row.uf,
                    area = area,
                }
            end
        end
    end
    s2:finalize()

    if not best then return nil end
    return {id = best.id, name = best.name, uf = best.uf}
end

function _M.is_private(lon, lat)
    return _M.classify_point(lon, lat) ~= nil
end

return _M

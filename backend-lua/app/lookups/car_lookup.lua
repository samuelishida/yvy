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

function _M.db_path()
    return CAR_DB_PATH
end

local car_conn = nil
local RTree_SQL = "SELECT id FROM car_rtree WHERE minLon<=? AND maxLon>=? AND minLat<=? AND maxLat>=?"
local GET_PREFIX = "SELECT cod_imovel, uf, municipio, area, json(geom) AS g FROM car_data WHERE id IN ("

-- Decodifica a geometria JSONB (via json(geom) já em texto) UMA vez.
-- Exposto como _M.decode_geometry (plan: terrabrasilis-integration, Inc 9) para
-- a verificação PRODES por recibo (routes/car.lua) decodificar a geometria do
-- imóvel uma única vez em vez de re-decodificar por candidato (até 50k×).
function _M.decode_geometry(geojson_text)
    if type(geojson_text) ~= "string" or geojson_text == "" then return nil end
    local ok, geom = pcall(cjson.decode, geojson_text)
    if not ok or type(geom) ~= "table" or not geom.coordinates then return nil end
    return geom
end

-- Testa um ponto contra uma geometria JÁ decodificada (Polygon/MultiPolygon).
-- GeoJSON usa [lon, lat]; geo.point_in_polygon espera {lon, lat} por vértice.
local function point_in_geom(lon, lat, geom)
    if type(geom) ~= "table" or type(geom.coordinates) ~= "table" then return false end

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
_M.point_in_geom = point_in_geom

-- Decodifica + testa (backward-compat: classify_point e os testes usam isto).
local function point_in_geojson(lon, lat, geojson_text)
    return point_in_geom(lon, lat, _M.decode_geometry(geojson_text))
end
_M.point_in_geojson = point_in_geojson

-- Bbox (min_lon/min_lat/max_lon/max_lat) de uma geometria GeoJSON decodificada
-- (Polygon ou MultiPolygon). Usado por get_by_cod_imovel para o scan PRODES.
local function geom_bbox(geom)
    if type(geom) ~= "table" or type(geom.coordinates) ~= "table" then return nil end
    local rings = {}
    if geom.type == "Polygon" then
        rings = geom.coordinates
    elseif geom.type == "MultiPolygon" then
        for _, poly in ipairs(geom.coordinates) do
            for _, ring in ipairs(poly) do
                rings[#rings + 1] = ring
            end
        end
    else
        return nil
    end

    local min_lon, min_lat = 1 / 0, 1 / 0
    local max_lon, max_lat = -1 / 0, -1 / 0
    for _, ring in ipairs(rings) do
        for _, pt in ipairs(ring) do
            local lon, lat = tonumber(pt[1]), tonumber(pt[2])
            if lon and lat then
                if lon < min_lon then min_lon = lon end
                if lon > max_lon then max_lon = lon end
                if lat < min_lat then min_lat = lat end
                if lat > max_lat then max_lat = lat end
            end
        end
    end
    if min_lon == 1 / 0 then return nil end
    return { min_lon = min_lon, min_lat = min_lat, max_lon = max_lon, max_lat = max_lat }
end

local RTREE_BBOX_SQL = "SELECT minLon, minLat, maxLon, maxLat FROM car_rtree WHERE id = ? LIMIT 1"
local rtree_missing_logged = false

-- Bbox do imóvel via car_rtree (consulta indexada por id) — evita varrer todas
-- as coordenadas da geometria (geom_bbox) a cada verificação PRODES.
local function rtree_bbox_for(conn, id)
    local stmt = conn:prepare(RTREE_BBOX_SQL)
    if not stmt then return nil end
    stmt:bind(1, id)
    local row
    for r in stmt:nrows() do row = r end
    stmt:finalize()
    if not row then return nil end
    return {
        min_lon = tonumber(row.minLon or row["minLon"]),
        min_lat = tonumber(row.minLat or row["minLat"]),
        max_lon = tonumber(row.maxLon or row["maxLon"]),
        max_lat = tonumber(row.maxLat or row["maxLat"]),
    }
end

-- Lookup de um imóvel pelo número do recibo CAR (cod_imovel UNIQUE).
-- car_import armazena cod_imovel verbatim do SICAR — normalizamos apenas para
-- UPPERCASE (stripping agressivo quebraria o match). Retorna
-- {id, uf, municipio, area_ha, geom (GeoJSON text), bbox} ou nil.
function _M.get_by_cod_imovel(cod_imovel)
    if not car_conn then return nil end
    if type(cod_imovel) ~= "string" or cod_imovel == "" then return nil end
    local code = cod_imovel:upper()

    local stmt = car_conn:prepare(
        "SELECT id, cod_imovel, uf, municipio, area, json(geom) AS g FROM car_data WHERE cod_imovel = ? LIMIT 1"
    )
    if not stmt then return nil end
    stmt:bind(1, code)
    local row
    for r in stmt:nrows() do row = r end
    stmt:finalize()
    if not row or not (row.g or row["g"]) then return nil end

    local g = row.g or row["g"]
    -- Bbox via car_rtree (consulta indexada por id). Se o rtree faltar/estiver
    -- vazio (db antigo), cai na varredura das coordenadas (geom_bbox) — log once.
    local bbox = rtree_bbox_for(car_conn, row.id)
    if not bbox then
        if not rtree_missing_logged then
            rtree_missing_logged = true
            logger.warn("car_rtree unavailable — falling back to geometry walk for CAR bbox")
        end
        local ok, geom = pcall(cjson.decode, g)
        if not ok then return nil end
        bbox = geom_bbox(geom)
        if not bbox then return nil end
    end

    return {
        id = row.cod_imovel,
        uf = row.uf,
        municipio = row.municipio,
        area_ha = tonumber(row.area) or 0,
        geom = g,
        bbox = bbox,
    }
end

local loaded_at = 0
local loaded_val = false

-- Memoizado com TTL curto (60s): evita um COUNT(*) por request. car.db é um
-- cold cache cujo estado não muda no meio do run — o TTL curto cobre o caso
-- de um ingest offline que conclui logo após a primeira checagem.
function _M.is_loaded()
    if not car_conn then return false end
    local now = os.time()
    if now - loaded_at < 60 then
        return loaded_val
    end
    loaded_at = now
    loaded_val = _M.count() > 0
    return loaded_val
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

-- Exposta para car_prodes.lua reutilizar a conexão query-only de runtime.
function _M._read_only_conn()
    return car_conn
end

-- Haversine distance (meters) between two WGS84 points.
local function haversine_m(lat1, lon1, lat2, lon2)
    local r = 6371000 -- Earth radius in meters
    local dlat = math.rad(lat2 - lat1)
    local dlon = math.rad(lon2 - lon1)
    local a = math.sin(dlat / 2) ^ 2
        + math.cos(math.rad(lat1)) * math.cos(math.rad(lat2)) * math.sin(dlon / 2) ^ 2
    local c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return r * c
end

-- Approximate degree deltas for a given east/north distance (meters) at a
-- given latitude. Returned as {dlon, dlat} so callers can grow a WGS84 bbox.
local function meters_to_degrees(lat, meters)
    local lat_rad = math.rad(lat)
    local m_per_deg_lat = 111132.92 - 559.82 * math.cos(2 * lat_rad) + 1.175 * math.cos(4 * lat_rad)
    local m_per_deg_lon = 111412.84 * math.cos(lat_rad) - 93.5 * math.cos(3 * lat_rad)
    return meters / m_per_deg_lon, meters / m_per_deg_lat
end

-- Find the nearest point on a line segment (lat1,lon1)-(lat2,lon2) to the
-- test point (lat,lon). Returns {lat, lon} of the closest point.
local function nearest_point_on_segment(lat, lon, lat1, lon1, lat2, lon2)
    -- Project onto segment using dot product; clamp to endpoints.
    local dx = lon2 - lon1
    local dy = lat2 - lat1
    local len2 = dx * dx + dy * dy
    if len2 == 0 then return {lat = lat1, lon = lon1} end
    local t = math.max(0, math.min(1, ((lon - lon1) * dx + (lat - lat1) * dy) / len2))
    return {lat = lat1 + t * dy, lon = lon1 + t * dx}
end

-- Returns true if the point is inside any interior ring (hole) of the geometry.
local function point_in_any_hole(lon, lat, geom)
    if type(geom) ~= "table" or type(geom.coordinates) ~= "table" then return false end

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
        if #rings > 1 and geo.point_in_ring(lon, lat, rings[1]) then
            for i = 2, #rings do
                if geo.point_in_ring(lon, lat, rings[i]) then
                    return true
                end
            end
        end
    end
    return false
end

-- Distance (meters) from a WGS84 point to the nearest point on the exterior
-- rings of a decoded geometry. Interior rings (holes) are intentionally ignored.
-- This function is used for snapping to the nearest imóvel when the point is
-- outside the polygon; it never scans holes for performance.
local function distance_to_geom_m(lat, lon, geom)
    if type(geom) ~= "table" or type(geom.coordinates) ~= "table" then return nil end

    local polys
    if geom.type == "Polygon" then
        polys = {geom.coordinates}
    elseif geom.type == "MultiPolygon" then
        polys = geom.coordinates
    else
        return nil
    end

    local best = math.huge
    for _, poly in ipairs(polys) do
        for ridx, ring in ipairs(poly) do
            if ridx > 1 then break end -- only exterior ring
            for i = 1, #ring - 1 do
                local pt1 = ring[i]
                local pt2 = ring[i + 1]
                local near = nearest_point_on_segment(
                    lat, lon, tonumber(pt1[2]), tonumber(pt1[1]), tonumber(pt2[2]), tonumber(pt2[1])
                )
                local d = haversine_m(lat, lon, near.lat, near.lon)
                if d < best then best = d end
            end
        end
    end
    return best == math.huge and nil or best
end

-- Exact point-in-polygon CAR lookup (legacy behavior).
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

-- Tolerant point lookup: first tries exact point-in-polygon; if that misses,
-- searches imóveis whose bbox is within `tolerance_m` of the point and returns
-- the one with the smallest distance to its exterior ring, preferring larger
-- area as a tie-breaker. This compensates for rasterization shifts in the CAR
-- overlay tiles. A point inside a hole of a polygon is NOT snapped to that
-- polygon; it may only snap to a different imóvel's exterior ring within range.
function _M.classify_point_with_tolerance(lon, lat, tolerance_m)
    tolerance_m = tonumber(tolerance_m) or 200
    if tolerance_m <= 0 then
        return _M.classify_point(lon, lat)
    end

    -- 1. Try exact first.
    local exact = _M.classify_point(lon, lat)
    if exact then
        exact.source = "exact"
        return exact
    end

    if not car_conn then return nil end
    lon, lat = tonumber(lon), tonumber(lat)
    if not lon or not lat then return nil end

    -- 2. Build a bbox around the point with the requested tolerance.
    local dlon, dlat = meters_to_degrees(lat, tolerance_m)
    local min_lon, max_lon = lon - dlon, lon + dlon
    local min_lat, max_lat = lat - dlat, lat + dlat

    local ids = {}
    local stmt = car_conn:prepare(
        "SELECT id FROM car_rtree WHERE minLon<=? AND maxLon>=? AND minLat<=? AND maxLat>=?"
    )
    stmt:bind(1, max_lon); stmt:bind(2, min_lon)
    stmt:bind(3, max_lat); stmt:bind(4, min_lat)
    for row in stmt:nrows() do
        ids[#ids + 1] = tonumber(row.id)
    end
    stmt:finalize()
    if #ids == 0 then return nil end

    -- 3. Decode candidates. A point inside the exterior ring but inside a hole
    -- is treated as "not in this property" and does not snap to it. Otherwise,
    -- when the point is outside the polygon, the distance to the exterior ring
    -- is computed for snapping. Larger area wins ties within a 0.1 m epsilon.
    local TIE_EPS = 0.1
    local ph = {}
    for _ = 1, #ids do ph[#ph + 1] = "?" end
    local s2 = car_conn:prepare(GET_PREFIX .. table.concat(ph, ",") .. ")")
    for i, id in ipairs(ids) do s2:bind(i, id) end

    local best
    for row in s2:nrows() do
        local g = row.g or row["g"]
        if g and g ~= "" then
            local geom = _M.decode_geometry(g)
            if geom and not point_in_any_hole(lon, lat, geom) then
                -- hole-contained points are not snapped to this property
                local d = distance_to_geom_m(lat, lon, geom)
                if d and d <= tolerance_m then
                    local area = tonumber(row.area) or 0
                    if not best
                        or d < best.distance - TIE_EPS
                        or (math.abs(d - best.distance) <= TIE_EPS and area > best.area) then
                        best = {
                            id = row.cod_imovel,
                            name = row.municipio,
                            uf = row.uf,
                            area = area,
                            distance = d,
                        }
                    end
                end
            end
        end
    end
    s2:finalize()

    if not best then return nil end
    return {id = best.id, name = best.name, uf = best.uf, distance_m = math.floor(best.distance + 0.5), source = "snap"}
end

function _M.is_private(lon, lat)
    return _M.classify_point(lon, lat) ~= nil
end

return _M
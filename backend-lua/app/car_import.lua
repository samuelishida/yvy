-- app/car_import.lua — ETL offline: GeoJSON (FeatureCollection por UF) → car.db
-- (tabelas car_data + car_rtree). Compartilhado por tools/import_car.lua (CLI)
-- e pelos testes (que importam uma fixture num car.db temporário).

local env      = require("app.env")
local sqlite3  = require("lsqlite3")
local cjson    = require("cjson")
local logger   = require("app.logger")

local _M = {}

function _M.car_db_path()
    local custom = env.get("CAR_DB_PATH")
    if custom and custom ~= "" then return custom end
    local backend = (debug.getinfo(1, "S").source or ""):match("@(.*[/\\])app[/\\]")
    return (backend or "") .. "data/car/car.db"
end

function _M.round(n, decimals)
    if type(n) ~= "number" then return n end
    local f = 10 ^ (decimals or 5)  -- ~1m
    return math.floor(n * f + 0.5) / f
end

-- Bbox de um geometry GeoJSON Polygon/MultiPolygon + geometria com coordenadas
-- arredondadas (encolhe o JSONB). Retorna (bbox, geometry_rounded) ou nil.
function _M.prepare_geometry(geom)
    local polys
    if geom.type == "Polygon" then
        polys = {geom.coordinates}
    elseif geom.type == "MultiPolygon" then
        polys = geom.coordinates
    else
        return nil
    end

    local min_lon, min_lat, max_lon, max_lat = math.huge, math.huge, -math.huge, -math.huge
    local rounded_polys = {}
    for _, poly in ipairs(polys) do
        local rp = {}
        for _, ring in ipairs(poly) do
            local rr = {}
            for _, pt in ipairs(ring) do
                local lon, lat = _M.round(pt[1], 5), _M.round(pt[2], 5)
                if lon < min_lon then min_lon = lon end
                if lon > max_lon then max_lon = lon end
                if lat < min_lat then min_lat = lat end
                if lat > max_lat then max_lat = lat end
                rr[#rr + 1] = {lon, lat}
            end
            rp[#rp + 1] = rr
        end
        rounded_polys[#rounded_polys + 1] = rp
    end

    if min_lon == math.huge then return nil end
    local out
    if geom.type == "Polygon" then
        out = {type = "Polygon", coordinates = rounded_polys[1]}
    else
        out = {type = "MultiPolygon", coordinates = rounded_polys}
    end
    return {min_lon, min_lat, max_lon, max_lat}, out
end

function _M.create_schema(conn)
    conn:exec([[
        CREATE TABLE IF NOT EXISTS car_data (
            id INTEGER PRIMARY KEY,
            cod_imovel TEXT UNIQUE NOT NULL,
            uf TEXT NOT NULL,
            municipio TEXT,
            area REAL,
            geom BLOB
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS car_rtree USING rtree(
            id, minLon, maxLon, minLat, maxLat
        );
    ]])
end

-- Importa um arquivo GeoJSON FeatureCollection para car.db (na conexão dada).
-- Retorna o nº de imóveis inseridos (0 em erro/arquivo ausente).
function _M.import_file(conn, path)
    local f = io.open(path, "r")
    if not f then
        logger.warn("CAR file not found: " .. tostring(path))
        return 0
    end
    local data = f:read("*a")
    f:close()

    local ok, fc = pcall(cjson.decode, data)
    if not ok or type(fc) ~= "table" or type(fc.features) ~= "table" then
        logger.warn("CAR file parse failed (skip): " .. tostring(path))
        return 0
    end

    local insert_data = conn:prepare([[
        INSERT INTO car_data (id, cod_imovel, uf, municipio, area, geom)
        VALUES (?,?,?,?,?,jsonb(?))
    ]])
    local insert_rtree = conn:prepare([[
        INSERT INTO car_rtree (id, minLon, maxLon, minLat, maxLat)
        VALUES (?,?,?,?,?)
    ]])

    local n = 0
    local ok2, err = pcall(function()
        conn:exec("BEGIN")
        for _, feature in ipairs(fc.features) do
            local p = feature.properties or {}
            local geom = feature.geometry
            if type(geom) == "table" then
                local bbox, rounded = _M.prepare_geometry(geom)
                if bbox then
                    n = n + 1
                    insert_data:reset()
                    insert_data:bind(1, n)
                    insert_data:bind(2, p.cod_imovel or ("CAR_" .. n))
                    insert_data:bind(3, p.uf or "")
                    insert_data:bind(4, p.municipio or "")
                    insert_data:bind(5, tonumber(p.area) or 0)
                    insert_data:bind(6, cjson.encode(rounded))
                    insert_data:step()
                    insert_rtree:reset()
                    insert_rtree:bind(1, n)
                    insert_rtree:bind(2, bbox[1])
                    insert_rtree:bind(3, bbox[3])
                    insert_rtree:bind(4, bbox[2])
                    insert_rtree:bind(5, bbox[4])
                    insert_rtree:step()
                end
            end
        end
        conn:exec("COMMIT")
    end)
    insert_data:finalize()
    insert_rtree:finalize()

    if not ok2 then
        pcall(function() conn:exec("ROLLBACK") end)
        logger.warn("CAR import failed for " .. tostring(path) .. ": " .. tostring(err))
        return 0
    end

    logger.info("imported " .. tostring(path) .. ": " .. n .. " imóveis")
    return n
end

return _M

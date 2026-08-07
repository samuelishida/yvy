-- app/routes/car.lua — /api/car/lookup (ponto → imóvel CAR)
--
-- Clique-para-inspecionar do overlay CAR (plano .plans/car-overlay, Inc 2).
-- Reusa car_lookup.classify_point (RTree bbox → decode candidatos → ray-cast)
-- e devolve o imóvel sob o ponto, ou null se não houver CAR ali.

require("app.env")
local auth = require("app.middleware.auth")
local rl   = require("app.middleware.rate_limit")
local cjson = require("cjson")

local _M = {}

function _M.get_lookup(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local lat = tonumber(ctx.req.args.lat)
    local lon = tonumber(ctx.req.args.lon)
    if not lat or not lon then
        ctx:error(400, "Missing lat/lon")
        return
    end

    local car = require("app.lookups.car_lookup")
    car.load_car()
    local hit = car.classify_point(lon, lat)   -- {id=cod_imovel, name=municipio, uf} | nil
    ctx:json(200, { imovel = hit or cjson.null })
end

-- ── Verificação PRODES por recibo CAR (plan: terrabrasilis-integration, Inc 12)
--
-- Dado o número do recibo (cod_imovel), resolve o imóvel → bbox (+padding de
-- ~30m para capturar pixels de borda) → get_deforestation_in_bbox → point_in_geojson
-- por candidato → agrega. Área aproximada por pixels (30m PRODES ≈ 0.09 ha/pixel).
-- Resultado cacheado em Redis `car:prodes:<COD>` (TTL 86400) com flag `cached`.

-- Padding ~30m em graus (30m ≈ 0.00027° no equador; 0.0003 cobre margem).
local PAD_DEG = 0.0003
local PIXEL_HA = 0.09  -- pixel PRODES 30m x 30m
local CANDIDATE_LIMIT = 50000

function _M.get_prodes_status(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local cod = ctx.req.args.cod_imovel
    if type(cod) ~= "string" or cod == "" then
        ctx:error(400, "Missing cod_imovel")
        return
    end

    local redis = require("app.redis")
    local cache_key = "car:prodes:" .. cod:upper()
    local cached = redis.get(cache_key)
    if cached then
        local data = cjson.decode(cached)
        data.cached = true
        ctx:json(200, { ok = true, cached = true, data = data })
        return
    end

    local car = require("app.lookups.car_lookup")
    car.load_car()
    if not car.is_loaded() then
        ctx:json(200, { cod_imovel = cod, found = false, note = "CAR unavailable" })
        return
    end

    local prop = car.get_by_cod_imovel(cod)
    if not prop then
        ctx:json(404, { cod_imovel = cod, found = false })
        return
    end

    local bbox = prop.bbox
    local db = require("app.db")
    local points = db.get_deforestation_in_bbox(
        bbox.min_lat - PAD_DEG, bbox.max_lat + PAD_DEG,
        bbox.min_lon - PAD_DEG, bbox.max_lon + PAD_DEG,
        CANDIDATE_LIMIT
    )

    local sampled = #points >= CANDIDATE_LIMIT
    local inside = 0
    local regrowth = false
    local def_count = 0
    local years = {}
    local year_set = {}
    local classes = {}
    local class_key = {}

    for _, p in ipairs(points) do
        if car.point_in_geojson(p.lon, p.lat, prop.geom) then
            inside = inside + 1
            local ck = (p.class_name or "unknown") .. ":" .. (p.type or "")
            if not class_key[ck] then
                class_key[ck] = true
                classes[#classes + 1] = {
                    class_name = p.class_name,
                    year = p.year,
                    type = p.type,
                    count = 0,
                }
            end
            for _, c in ipairs(classes) do
                if (c.class_name or "unknown") .. ":" .. (c.type or "") == ck then
                    c.count = c.count + 1
                end
            end
            if p.type == "deforestation" then
                def_count = def_count + 1
                if p.year and not year_set[p.year] then
                    year_set[p.year] = true
                    years[#years + 1] = p.year
                end
            elseif p.type == "regrowth" then
                regrowth = true
            end
        end
    end

    table.sort(years)

    local prodes_area_ha = def_count * PIXEL_HA
    local property_area_ha = prop.area_ha
    local pct = 0
    if property_area_ha and property_area_ha > 0 then
        pct = math.floor((prodes_area_ha / property_area_ha) * 1000 + 0.5) / 10
    end

    local result = {
        cod_imovel = prop.id,
        found = true,
        has_prodes = def_count > 0,
        prodes_area_ha = math.floor(prodes_area_ha * 100 + 0.5) / 100,
        property_area_ha = property_area_ha,
        pct_deforested = pct,
        years = years,
        classes = classes,
        regrowth = regrowth,
        sampled = sampled,
        cached = false,
        area_estimate = "pixel-based",
        bbox = {
            min_lon = math.floor(bbox.min_lon * 1e5 + 0.5) / 1e5,
            min_lat = math.floor(bbox.min_lat * 1e5 + 0.5) / 1e5,
            max_lon = math.floor(bbox.max_lon * 1e5 + 0.5) / 1e5,
            max_lat = math.floor(bbox.max_lat * 1e5 + 0.5) / 1e5,
        },
    }

    redis.set(cache_key, cjson.encode(result), 86400)
    ctx:json(200, { ok = true, cached = false, data = result })
end

function _M.get_summary(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local cod = ctx.req.args.cod_imovel
    if type(cod) ~= "string" or cod == "" then
        ctx:error(400, "Missing cod_imovel")
        return
    end

    local car = require("app.lookups.car_lookup")
    car.load_car()
    if not car.is_loaded() then
        ctx:json(200, { cod_imovel = cod, found = false, note = "CAR unavailable" })
        return
    end

    local prop = car.get_by_cod_imovel(cod)
    if not prop then
        ctx:json(404, { cod_imovel = cod, found = false })
        return
    end

    ctx:json(200, {
        cod_imovel = prop.id,
        uf = prop.uf,
        municipio = prop.municipio,
        area_ha = prop.area_ha,
    })
end

return _M

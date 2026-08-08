-- app/routes/car.lua — /api/car/lookup (ponto → imóvel CAR)
--
-- Clique-para-inspecionar do overlay CAR (plano .plans/car-overlay, Inc 2).
-- Reusa car_lookup.classify_point (RTree bbox → decode candidatos → ray-cast)
-- e devolve o imóvel sob o ponto, ou null se não houver CAR ali.

require("app.env")
local env        = require("app.env")
local geo        = require("app.geo")
local auth       = require("app.middleware.auth")
local rl         = require("app.middleware.rate_limit")
local cjson      = require("cjson")
local car_lookup = require("app.lookups.car_lookup")

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
        -- (b) decode-guard: payload corrompido no cache → trata como miss
        -- (recomputa e sobrescreve; nunca 500).
        local ok, data = pcall(cjson.decode, cached)
        if ok and type(data) == "table" then
            data.cached = true
            ctx:json(200, { ok = true, cached = true, data = data })
            return
        end
    end

    local car = require("app.lookups.car_lookup")
    car.load_car()
    if not car.is_loaded() then
        ctx:json(200, { cod_imovel = cod, found = false, reason = "car_unavailable", note = "CAR unavailable" })
        return
    end

    local prop = car.get_by_cod_imovel(cod)
    if not prop then
        ctx:json(200, { cod_imovel = cod, found = false, reason = "not_found" })
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
    local regrowth = false
    local def_count = 0
    local years = {}
    local year_set = {}
    local classes = {}
    local class_key = {}
    local class_idx = {}

    -- (c) Decodifica a geometria do imóvel UMA vez e reusa em todos os pontos
    -- (antes: point_in_geojson re-decodificava o JSON por candidato — até 50k×).
    local prop_geom = car.decode_geometry(prop.geom)

    for _, p in ipairs(points) do
        -- (d) bbox-prefilter: descarta pontos fora do bbox exato do imóvel
        -- antes do ray-cast (caro). O scan já vem limitado ao bbox + padding.
        if prop_geom
           and p.lat >= bbox.min_lat and p.lat <= bbox.max_lat
           and p.lon >= bbox.min_lon and p.lon <= bbox.max_lon
           and car.point_in_geom(p.lon, p.lat, prop_geom) then
            local ck = (p.class_name or "unknown") .. ":" .. (p.type or "")
            if not class_key[ck] then
                class_key[ck] = true
                class_idx[ck] = #classes + 1
                classes[class_idx[ck]] = {
                    class_name = p.class_name,
                    year = p.year,
                    type = p.type,
                    count = 0,
                }
            end
            classes[class_idx[ck]].count = classes[class_idx[ck]].count + 1
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

-- ── Sobreposição CAR × UC/TI (plan: protected-area-crossing, Inc 1)
--
-- Dado o recibo (cod_imovel), estima a fração do imóvel que cai dentro de UCs
-- e TIs (Monte-Carlo: grade de pontos dentro do polígono CAR × ray-cast contra
-- os candidatos). Status "suspeito" quando qualquer sobreposição ≥
-- PROTECTED_OVERLAP_SUSPECT (default 0.8 — regra do usuário). Cache Redis
-- `car:protected:<COD>` TTL 86400, igual ao car:prodes:<COD>.

local OVERLAP_SUSPECT = tonumber(env.get("PROTECTED_OVERLAP_SUSPECT", "0.8")) or 0.8
local OVERLAP_SAMPLES = tonumber(env.get("PROTECTED_OVERLAP_SAMPLES", "32")) or 32
local OVERLAP_MAX_SAMPLES = tonumber(env.get("PROTECTED_OVERLAP_MAX_SAMPLES", "128")) or 128
local OVERLAP_MARGIN = 0.05      -- faixa (fração) perto do threshold → refina a grade
local MIN_INTERIOR = 20          -- abaixo disso a estimativa não é confiável
local CACHE_TTL = 86400

-- Estimativa Monte-Carlo: grade samples×samples sobre o bbox do imóvel; conta
-- pontos dentro do polígono CAR (point_in_geom) e, para cada ponto interior,
-- testa os candidatos UC/TI (bbox-reject + ray-cast). O erro escala com a
-- contagem interior (não com o lado da grade) — `sampled` é exposto na resposta.
local function sample_overlap(prop_geom, bbox, uc_candidates, ti_candidates, samples)
    local min_lon, min_lat = bbox.min_lon, bbox.min_lat
    local max_lon, max_lat = bbox.max_lon, bbox.max_lat
    local d_lon, d_lat = max_lon - min_lon, max_lat - min_lat

    local by_key = {}
    local overlaps = {}
    local interior = 0

    for i = 0, samples - 1 do
        local lon = min_lon + (i + 0.5) / samples * d_lon
        for j = 0, samples - 1 do
            local lat = min_lat + (j + 0.5) / samples * d_lat
            if car_lookup.point_in_geom(lon, lat, prop_geom) then
                interior = interior + 1
                for _, cand in ipairs(uc_candidates) do
                    local b = cand.bounds
                    if lon >= b[1] and lon <= b[3] and lat >= b[2] and lat <= b[4]
                       and geo.point_in_polygon(lon, lat, cand.rings) then
                        local k = "uc:" .. cand.name
                        if not by_key[k] then
                            by_key[k] = { type = "uc", name = cand.name, category = cand.category, count = 0 }
                            overlaps[#overlaps + 1] = by_key[k]
                        end
                        by_key[k].count = by_key[k].count + 1
                    end
                end
                for _, cand in ipairs(ti_candidates) do
                    local b = cand.bounds
                    if lon >= b[1] and lon <= b[3] and lat >= b[2] and lat <= b[4]
                       and geo.point_in_polygon(lon, lat, cand.rings) then
                        local k = "ti:" .. cand.name
                        if not by_key[k] then
                            by_key[k] = { type = "ti", name = cand.name, count = 0 }
                            overlaps[#overlaps + 1] = by_key[k]
                        end
                        by_key[k].count = by_key[k].count + 1
                    end
                end
            end
        end
    end

    local max_pct = 0
    for _, c in ipairs(overlaps) do
        local pct = interior > 0 and (c.count / interior) * 100 or 0
        c.overlap_pct = math.floor(pct * 10 + 0.5) / 10
        c.count = nil
        if c.overlap_pct > max_pct then max_pct = c.overlap_pct end
    end
    table.sort(overlaps, function(a, b) return a.overlap_pct > b.overlap_pct end)

    local status = "ok"
    if interior < MIN_INTERIOR then
        status = "indeterminado"
    elseif max_pct / 100 >= OVERLAP_SUSPECT then
        status = "suspeito"
    end

    return { overlaps = overlaps, sampled = interior, status = status, max_pct = max_pct }
end

function _M.get_protected_overlap(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local cod = ctx.req.args.cod_imovel
    if type(cod) ~= "string" or cod == "" then
        ctx:error(400, "Missing cod_imovel")
        return
    end

    local redis = require("app.redis")
    local cache_key = "car:protected:" .. cod:upper()
    local cached = redis.get(cache_key)
    if cached then
        local ok, data = pcall(cjson.decode, cached)
        if ok and type(data) == "table" then
            data.cached = true
            ctx:json(200, { ok = true, cached = true, data = data })
            return
        end
    end

    local car = require("app.lookups.car_lookup")
    car.load_car()
    if not car.is_loaded() then
        ctx:json(200, { cod_imovel = cod, found = false, reason = "car_unavailable", note = "CAR unavailable" })
        return
    end

    local prop = car.get_by_cod_imovel(cod)
    if not prop then
        ctx:json(200, { cod_imovel = cod, found = false, reason = "not_found" })
        return
    end

    local prop_geom = car.decode_geometry(prop.geom)
    if not prop_geom then
        ctx:json(200, { cod_imovel = cod, found = false, reason = "invalid_geometry" })
        return
    end

    -- Lookups UC/TI (idempotentes; pcall para um lookup ausente não derrubar a rota)
    local uc = require("app.lookups.conservation_units_lookup")
    local ti = require("app.lookups.indigenous_lands_lookup")
    pcall(uc.load_conservation_units)
    pcall(ti.load_indigenous_lands)

    -- Seleção por bbox do imóvel = superconjunto do polígono (nada pode escapar)
    local b = prop.bbox
    local uc_candidates = uc.candidates_in_bbox(b.min_lon, b.min_lat, b.max_lon, b.max_lat)
    local ti_candidates = ti.candidates_in_bbox(b.min_lon, b.min_lat, b.max_lon, b.max_lat)

    -- Amostragem adaptativa: refina a grade se o resultado cair na margem do
    -- threshold ou se a contagem interior for baixa (cap PROTECTED_OVERLAP_MAX_SAMPLES)
    local samples = OVERLAP_SAMPLES
    local res
    while samples <= OVERLAP_MAX_SAMPLES do
        res = sample_overlap(prop_geom, prop.bbox, uc_candidates, ti_candidates, samples)
        local near = math.abs(res.max_pct - OVERLAP_SUSPECT * 100) < OVERLAP_MARGIN * 100
        if (not near) and res.sampled >= MIN_INTERIOR then break end
        samples = samples * 2
    end

    local result = {
        cod_imovel = prop.id,
        found = true,
        sampled = res.sampled,
        overlaps = res.overlaps,
        status = res.status,
        threshold = OVERLAP_SUSPECT,
        estimate = "grid-sampling",
        cached = false,
    }
    redis.set(cache_key, cjson.encode(result), CACHE_TTL)
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
        ctx:json(200, { cod_imovel = cod, found = false, reason = "car_unavailable", note = "CAR unavailable" })
        return
    end

    local prop = car.get_by_cod_imovel(cod)
    if not prop then
        ctx:json(200, { cod_imovel = cod, found = false, reason = "not_found" })
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

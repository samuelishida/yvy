-- app/routes/car.lua — /api/car/lookup (ponto → imóvel CAR)
--
-- Clique-para-inspecionar do overlay CAR (plano .plans/car-overlay, Inc 2).
-- Reusa car_lookup.classify_point (RTree bbox → decode candidatos → ray-cast)
-- e devolve o imóvel sob o ponto, ou null se não houver CAR ali.

require("app.env")
local env        = require("app.env")
local geo        = require("app.geo")
local utils      = require("app.utils")
local auth       = require("app.middleware.auth")
local rl         = require("app.middleware.rate_limit")
local cjson      = require("cjson")
local logger     = require("app.logger")
local car_lookup = require("app.lookups.car_lookup")
local car_protected = require("app.lookups.car_protected_overlap")
local car_prodes = require("app.lookups.car_prodes")

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

    -- Tolerance (meters) for click-to-CAR snapping. The raster CAR overlay is
    -- rendered from exact polygons, but small rasterization shifts and the
    -- user's click precision mean a magenta pixel can be a few meters outside
    -- the actual imóvel. Allow up to 2 km snapping on map clicks; the default
    -- for exact callers remains 0. Out-of-range values are clamped rather than
    -- silently falling back to exact mode, so the caller intent is respected.
    local tolerance = tonumber(ctx.req.args.tolerance) or 0
    tolerance = math.max(0, math.min(tolerance, 2000))

    local car = require("app.lookups.car_lookup")
    car.load_car()
    local hit
    if tolerance > 0 then
        hit = car.classify_point_with_tolerance(lon, lat, tolerance)
    else
        hit = car.classify_point(lon, lat)
    end
    ctx:json(200, { imovel = hit or cjson.null })
end

-- ── Verificação PRODES por recibo CAR (plan: terrabrasilis-integration, Inc 12)
--
-- Dado o número do recibo (cod_imovel), resolve o imóvel → bbox (+padding de
-- ~30m para capturar pixels de borda) → get_deforestation_in_bbox → point_in_geojson
-- por candidato → agrega. Área aproximada por pixels (30m PRODES ≈ 0.09 ha/pixel).
-- Resultado cacheado em Redis `car:prodes:<COD>` (TTL 86400) com flag `cached`.

-- Padding ~30m em graus (30m ≈ 0.00027° no equador; 0.0003 cobre margem).
-- Lidos de env para alimentarem o version_key do pré-cálculo car_prodes:
-- mudar qualquer um invalida o cache pré-calculado (plan: precompute-car-prodes).
local PAD_DEG = tonumber(env.get("PRODES_PAD_DEG", "0.0003")) or 0.0003
local PIXEL_HA = tonumber(env.get("PRODES_PIXEL_HA", "0.09")) or 0.09  -- pixel PRODES 30m x 30m
local CANDIDATE_LIMIT = tonumber(env.get("PRODES_CANDIDATE_LIMIT", "50000")) or 50000

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

    -- Fast path: resultado pré-calculado no car.db (plan: precompute-car-prodes).
    -- Só consulta o banco se não houver cache Redis; o cache continua sendo
    -- populado pelo caminho lento abaixo para amortizar futuros misses.
    local cached_row = car_prodes.get(cod)
    if cached_row then
        cached_row.cached = true
        ctx:json(200, { ok = true, cached = true, precomputed = true, data = cached_row })
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

    local result = _M.compute_prodes_for_property(prop)
    if not result then
        ctx:json(200, { cod_imovel = cod, found = false, reason = "not_found" })
        return
    end

    redis.set(cache_key, cjson.encode(result), 86400)
    ctx:json(200, { ok = true, cached = false, data = result })
end

-- Cálculo CAR × PRODES em tempo real. Extraído para reutilização no warm
-- offline e como fallback quando a tabela car_prodes ainda não tem a row.
function _M.compute_prodes_for_property(prop)
    if not prop or not prop.bbox then return nil end

    local bbox = prop.bbox
    local db = require("app.db")
    local points = db.get_deforestation_in_bbox(
        bbox.min_lat - PAD_DEG, bbox.max_lat + PAD_DEG,
        bbox.min_lon - PAD_DEG, bbox.max_lon + PAD_DEG,
        CANDIDATE_LIMIT
    )

    -- Imóveis grandes geram muitos candidatos → ray-cast CPU-bound no event
    -- loop. Loga para observabilidade (cache miss é o cold path).
    if #points > 10000 then
        logger.warn("car/prodes slow path: " .. #points .. " candidates for " .. tostring(prop.id))
    end

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
    local prop_geom = car_lookup.decode_geometry(prop.geom)

    for _, p in ipairs(points) do
        -- (d) bbox-prefilter: descarta pontos fora do bbox exato do imóvel
        -- antes do ray-cast (caro). O scan já vem limitado ao bbox + padding.
        if prop_geom
           and p.lat >= bbox.min_lat and p.lat <= bbox.max_lat
           and p.lon >= bbox.min_lon and p.lon <= bbox.max_lon
           and car_lookup.point_in_geom(p.lon, p.lat, prop_geom) then
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

    return {
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
end

-- ── Sobreposição CAR × UC/TI (plan: protected-area-crossing, Inc 1)
--
-- Dado o recibo (cod_imovel), estima a fração do imóvel que cai dentro de UCs
-- e TIs (Monte-Carlo: grade de pontos dentro do polígono CAR × ray-cast contra
-- os candidatos). Status "suspeito" quando qualquer sobreposição ≥
-- PROTECTED_OVERLAP_SUSPECT (default 0.5 — regra do usuário). Cache Redis
-- `car:protected:<COD>` TTL 86400, igual ao car:prodes:<COD>.

local OVERLAP_SUSPECT = tonumber(env.get("PROTECTED_OVERLAP_SUSPECT", "0.5")) or 0.5
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



-- Re-avalia status a partir de max_pct e do threshold atual. O pré-cálculo
-- guarda o threshold que vigorava no momento; se o operador mudar
-- PROTECTED_OVERLAP_SUSPECT, recalculamos só o rótulo sem refazer Monte-Carlo.
local function reclassify_status(max_pct)
    if max_pct / 100 >= OVERLAP_SUSPECT then
        return "suspeito"
    else
        return "ok"
    end
end

-- Gravação throttled no SQLite para auto-repair. Só a primeira request
-- consegue o lock Redis; as demais retornam sem escrever.
local function throttled_upsert(cod, prop, live_result)
    local min_precompute_ha = tonumber(env.get("PROTECTED_OVERLAP_MIN_AREA_HA", "1.0")) or 1.0
    if (prop.area_ha or 0) < min_precompute_ha then return end
    local lock_key = "car:protected:repair_lock:" .. cod:upper()
    local redis = require("app.redis")
    local got = redis.setnx(lock_key, "1", 300)
    if not got then return end
    pcall(function()
        car_protected.upsert(cod, live_result)
    end)
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

    -- Caminho rápido: se o bbox do imóvel não intersecta nenhuma UC/TI,
    -- não há sobreposição possível. Evita Monte-Carlo para ~97% dos imóveis.
    local uc = require("app.lookups.conservation_units_lookup")
    local ti = require("app.lookups.indigenous_lands_lookup")
    pcall(uc.load_conservation_units)
    pcall(ti.load_indigenous_lands)
    local b = prop.bbox
    local uc_candidates = uc.candidates_in_bbox(b.min_lon, b.min_lat, b.max_lon, b.max_lat)
    local ti_candidates = ti.candidates_in_bbox(b.min_lon, b.min_lat, b.max_lon, b.max_lat)
    if #uc_candidates == 0 and #ti_candidates == 0 then
        local result = {
            cod_imovel = prop.id,
            found = true,
            sampled = 0,
            overlaps = {},
            status = "ok",
            threshold = OVERLAP_SUSPECT,
            max_pct = 0,
            estimate = "bbox-filter",
            cached = false,
            source = "bbox-filter",
        }
        redis.set(cache_key, cjson.encode(result), CACHE_TTL)
        ctx:json(200, { ok = true, cached = false, data = result })
        return
    end

    -- Tentativa de leitura do pré-cálculo (cache permanente no car.db)
    local pre = car_protected.get(cod)
    if pre then
        local age_days = nil
        if pre.computed_at and #pre.computed_at >= 10 then
            local today_utc = os.date("!%Y-%m-%d", os.time())
            age_days = utils.days_between_iso(pre.computed_at, today_utc)
        end
        local current_key = car_protected.current_version_key()
        local stale_days = tonumber(env.get("PROTECTED_OVERLAP_STALE_DAYS", "30")) or 30
        local fresh = (pre.version_key == current_key) and (not age_days or age_days < stale_days)
        if fresh then
            local result = {
                cod_imovel = prop.id,
                found = true,
                sampled = pre.sampled,
                overlaps = pre.overlaps,
                status = reclassify_status(pre.max_pct),
                threshold = OVERLAP_SUSPECT,
                max_pct = pre.max_pct,
                estimate = "grid-sampling",
                cached = false,
                source = "precomputed",
                version_key = pre.version_key,
            }
            redis.set(cache_key, cjson.encode(result), CACHE_TTL)
            ctx:json(200, { ok = true, cached = false, data = result })
            return
        end
    end

    -- Fallback: Monte-Carlo on-the-fly (mesmo algoritmo de antes).
    -- UC/TI já carregados e candidatos já filtrados acima.
    local prop_geom = car.decode_geometry(prop.geom)
    if not prop_geom then
        ctx:json(200, { cod_imovel = cod, found = false, reason = "invalid_geometry" })
        return
    end

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
        max_pct = res.max_pct,
        estimate = "grid-sampling",
        cached = false,
        source = "live",
    }

    redis.set(cache_key, cjson.encode(result), CACHE_TTL)

    -- Auto-repair throttled: imóvel novo ou stale -> grava de volta no SQLite.
    throttled_upsert(cod, prop, result)

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

-- tools/warm_car_protected_overlap.lua — pré-cálculo offline CAR × UC/TI
--
-- Usage:
--   lua5.1 tools/warm_car_protected_overlap.lua [UF]
-- Sem argumento → todas as 27 UFs (sequential; recomenda-se paralelizar por UF
-- no cron com xargs -P ou timers separados).
--
-- Otimização principal (2026-08-08): só pré-calcula imóveis cujo bbox
-- intersecta alguma UC/TI. Para os demais a rota resolve via bbox-filter
-- instantâneo. Isso reduz o trabalho de ~7,3M para ~3% dos imóveis.

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local backend_dir = script_dir:gsub("[\\/]tools[\\/]$", "/")
package.path = backend_dir .. "?.lua;" .. backend_dir .. "?/init.lua;" .. package.path

local env = require("app.env")
env.load_dotenv(backend_dir .. "../.env")
env.load_dotenv(backend_dir .. ".env")

local sqlite3 = require("lsqlite3")
local cjson   = require("cjson")
local logger  = require("app.logger")
local db      = require("app.db")
local car_lookup = require("app.lookups.car_lookup")
local car_protected = require("app.lookups.car_protected_overlap")
local redis   = require("app.redis")
local geo     = require("app.geo")
local ti      = require("app.lookups.indigenous_lands_lookup")
local uc      = require("app.lookups.conservation_units_lookup")

local UFS = {"AC","AL","AM","AP","BA","CE","DF","ES","GO","MA","MG","MS","MT",
             "PA","PB","PE","PI","PR","RJ","RN","RO","RR","RS","SC","SE","SP","TO"}

local OVERLAP_SUSPECT = tonumber(env.get("PROTECTED_OVERLAP_SUSPECT", "0.8")) or 0.8
local MIN_INTERIOR = 20
local MIN_PRECOMPUTE_HA = tonumber(env.get("PROTECTED_OVERLAP_MIN_AREA_HA", "1.0")) or 1.0
local BULK_CHUNK = 500
local ADAPTIVE_MARGIN = 0.20  -- refinar quando max_pct/100 estiver em [threshold-margin, threshold+margin]

-- Backup do car.db ANTES de escrever a tabela nova (SHOULD-FIX #10).
local function backup_if_needed(db_path)
    local f = io.open(db_path, "r")
    if not f then return false end
    f:close()

    local exists = false
    for attempt = 1, 30 do
        local conn = sqlite3.open(db_path)
        if conn then
            conn:exec("PRAGMA busy_timeout=60000")
            local ok = true
            for row in conn:nrows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='car_protected_overlap'") do
                exists = true
            end
            conn:close()
            if ok then break end
        end
        if not exists then
            logger.warn("backup_if_needed: car.db locked, attempt " .. attempt .. "/30; retrying...")
            os.execute("sleep " .. attempt)
        end
    end
    if exists then return true end

    local backup_path = db_path .. ".warm-backup-" .. os.date("!%Y%m%d-%H%M%S")
    logger.info("Backing up car.db before first warm: " .. backup_path)
    local src, err = io.open(db_path, "rb")
    if not src then
        logger.warn("Backup open failed: " .. tostring(err))
        return false
    end
    local dst = io.open(backup_path, "wb")
    if not dst then
        src:close()
        return false
    end
    while true do
        local chunk = src:read(8192)
        if not chunk then break end
        dst:write(chunk)
    end
    src:close()
    dst:close()
    return true
end

-- Estimativa Monte-Carlo otimizada: amostra apenas nas interseções de bbox
-- CAR × cada UC/TI candidato. Isso evita testar pontos do CAR que estão longe
-- de qualquer área protegida, reduzindo drasticamente o trabalho quando o imóvel
-- é grande e a sobreposição é localizada.
local function intersect_bbox(b1, b2)
    local min_lon = math.max(b1.min_lon or b1[1], b2[1])
    local min_lat = math.max(b1.min_lat or b1[2], b2[2])
    local max_lon = math.min(b1.max_lon or b1[3], b2[3])
    local max_lat = math.min(b1.max_lat or b1[4], b2[4])
    if min_lon > max_lon or min_lat > max_lat then return nil end
    return { min_lon = min_lon, min_lat = min_lat, max_lon = max_lon, max_lat = max_lat }
end

local function union_bbox(boxes)
    if #boxes == 0 then return nil end
    local b = boxes[1]
    local min_lon, min_lat, max_lon, max_lat = b.min_lon, b.min_lat, b.max_lon, b.max_lat
    for i = 2, #boxes do
        local c = boxes[i]
        if c.min_lon < min_lon then min_lon = c.min_lon end
        if c.min_lat < min_lat then min_lat = c.min_lat end
        if c.max_lon > max_lon then max_lon = c.max_lon end
        if c.max_lat > max_lat then max_lat = c.max_lat end
    end
    return { min_lon = min_lon, min_lat = min_lat, max_lon = max_lon, max_lat = max_lat }
end

local function sample_overlap_grid(prop_geom, bbox, uc_candidates, ti_candidates, grid)
    local min_lon, min_lat = bbox.min_lon, bbox.min_lat
    local max_lon, max_lat = bbox.max_lon, bbox.max_lat
    local d_lon, d_lat = max_lon - min_lon, max_lat - min_lat

    local by_key = {}
    local overlaps = {}
    local interior = 0

    for i = 0, grid - 1 do
        local lon = min_lon + (i + 0.5) / grid * d_lon
        for j = 0, grid - 1 do
            local lat = min_lat + (j + 0.5) / grid * d_lat
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

    return { overlaps = overlaps, sampled = interior, max_pct = max_pct }
end

-- Amostragem Monte-Carlo adaptativa: começa com grade grossa (16²) e só refina
-- para 32² ou 64² se o resultado estiver na zona de incerteza próxima ao
-- threshold. Isso acelera ~4× imóveis claramente ok/suspeito, mantendo precisão
-- nos casos de fronteira.
local function sample_overlap(prop_geom, bbox, uc_candidates, ti_candidates, samples)
    -- 1) Bbox(s) de interesse = união das interseções CAR × cada candidato.
    local boxes = {}
    for _, cand in ipairs(uc_candidates) do
        local ix = intersect_bbox(bbox, cand.bounds)
        if ix then boxes[#boxes + 1] = ix end
    end
    for _, cand in ipairs(ti_candidates) do
        local ix = intersect_bbox(bbox, cand.bounds)
        if ix then boxes[#boxes + 1] = ix end
    end
    if #boxes == 0 then
        return { overlaps = {}, sampled = 0, status = "ok", max_pct = 0 }
    end

    local ub = union_bbox(boxes)

    -- Ajusta densidade se a união for muito menor que o bbox do CAR.
    local bbox_area = (bbox.max_lon - bbox.min_lon) * (bbox.max_lat - bbox.min_lat)
    local union_area = (ub.max_lon - ub.min_lon) * (ub.max_lat - ub.min_lat)
    if union_area > 0 and bbox_area > 0 and union_area / bbox_area < 0.25 then
        samples = math.min(128, math.floor(samples * 2))
    end

    -- Passo 1: grade grossa.
    local coarse = math.max(16, math.floor(samples / 4))
    local res = sample_overlap_grid(prop_geom, ub, uc_candidates, ti_candidates, coarse)

    -- Passo 2: se estiver na zona crítica, refina com a grade pedida.
    local ratio = res.max_pct / 100
    local lower = math.max(0, OVERLAP_SUSPECT - ADAPTIVE_MARGIN)
    local upper = math.min(1, OVERLAP_SUSPECT + ADAPTIVE_MARGIN)
    if res.sampled >= MIN_INTERIOR and (ratio >= lower and ratio <= upper) then
        res = sample_overlap_grid(prop_geom, ub, uc_candidates, ti_candidates, samples)
    end

    local status = "ok"
    if res.sampled < MIN_INTERIOR then
        status = "indeterminado"
    elseif res.max_pct / 100 >= OVERLAP_SUSPECT then
        status = "suspeito"
    end

    return { overlaps = res.overlaps, sampled = res.sampled, status = status, max_pct = res.max_pct }
end

-- Escolhe o lado da grade conforme área (plan: 1-10ha → 32²; ≥10ha → 64²).
local function samples_for_area(area_ha)
    if area_ha >= 10 then return 64 end
    return 32
end

local function has_candidates(prop)
    local b = prop.bbox
    local uc_candidates = uc.candidates_in_bbox(b.min_lon, b.min_lat, b.max_lon, b.max_lat)
    local ti_candidates = ti.candidates_in_bbox(b.min_lon, b.min_lat, b.max_lon, b.max_lat)
    return (#uc_candidates + #ti_candidates) > 0, uc_candidates, ti_candidates
end

local function process_imovel(prop, version_key)
    local has, uc_candidates, ti_candidates = has_candidates(prop)
    if not has then
        return nil, "bbox-filter"
    end

    local prop_geom = car_lookup.decode_geometry(prop.geom)
    if not prop_geom then
        logger.warn("warm: invalid geometry for " .. tostring(prop.id))
        return nil, "invalid-geom"
    end

    local samples = samples_for_area(prop.area_ha)
    local res = sample_overlap(prop_geom, prop.bbox, uc_candidates, ti_candidates, samples)

    local overlaps_json, ok
    ok, overlaps_json = pcall(cjson.encode, res.overlaps)
    if not ok then
        logger.warn("warm: encode failed for " .. tostring(prop.id) .. ": " .. tostring(overlaps_json))
        return nil, "encode-fail"
    end

    return {
        cod_imovel = prop.id,
        sampled = res.sampled,
        overlaps = res.overlaps,
        status = res.status,
        max_pct = res.max_pct,
        threshold = OVERLAP_SUSPECT,
        version_key = version_key,
        computed_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
end

local function candidate_ids(conn, uf_filter)
    local seen = {}
    local ids = {}
    local base_sql = "SELECT d.cod_imovel FROM car_data d JOIN car_rtree r ON d.id = r.id WHERE d.area >= " .. MIN_PRECOMPUTE_HA
    if uf_filter and uf_filter ~= "" then
        base_sql = base_sql .. " AND d.uf = '" .. uf_filter:upper() .. "'"
    end

    local function add_for_bbox(min_lon, min_lat, max_lon, max_lat)
        local sql = string.format("%s AND r.minLon <= %.12f AND r.maxLon >= %.12f AND r.minLat <= %.12f AND r.maxLat >= %.12f",
            base_sql, max_lon, min_lon, max_lat, min_lat)
        for row in conn:nrows(sql) do
            local cod = row.cod_imovel
            if not seen[cod] then
                seen[cod] = true
                ids[#ids + 1] = cod
            end
        end
    end

    for _, entry in ipairs(uc.units() or {}) do
        local b = entry.bounds
        add_for_bbox(b[1], b[2], b[3], b[4])
    end
    for _, entry in ipairs(ti.lands() or {}) do
        local b = entry.bounds
        add_for_bbox(b[1], b[2], b[3], b[4])
    end

    return ids
end

local function run_batch(uf_filter, alt_db_path)
    local db_path = alt_db_path or car_protected.db_path()
    local f = io.open(db_path, "r")
    if not f then
        logger.error("warm: car.db not found at " .. db_path)
        return 1
    end
    f:close()

    -- Backup é responsabilidade do operador (feito uma vez antes do warm
    -- paralelo). Evita corrida de 15 workers tentando criar backup ao mesmo tempo.
    -- Quando alt_db_path é fornecido, assume-se que o DB já foi preparado.

    db.init_db()
    ti.load_indigenous_lands()
    uc.load_conservation_units()
    car_lookup.load_car()

    if not car_lookup.is_loaded() then
        logger.error("warm: car.db empty or unavailable")
        return 1
    end

    -- Força conexão writable + schema idempotente. Para alt_db_path carregamos
    -- o módulo com CAR_DB_PATH apontando para o clone.
    if alt_db_path then
        env.set("CAR_DB_PATH", alt_db_path)
        package.loaded["app.lookups.car_protected_overlap"] = nil
        car_protected = require("app.lookups.car_protected_overlap")
    end
    car_protected.ensure_schema(sqlite3.open(db_path))

    local version_key = car_protected.current_version_key()
    logger.info("warm: version_key=" .. version_key .. " samples=" .. (env.get("PROTECTED_OVERLAP_SAMPLES", "32") or "32"))

    local conn = sqlite3.open(db_path)
    if not conn then
        logger.error("warm: cannot open car.db for reading")
        return 1
    end

    local ids = candidate_ids(conn, uf_filter)
    local total = #ids
    logger.info("warm: " .. total .. " candidate imóveis to process")

    local processed = 0
    local skipped = 0
    local bbox_filtered = 0
    local row_buffer = {}
    local t0 = os.clock()
    local last_log = t0

    for _, cod in ipairs(ids) do
        local prop = car_lookup.get_by_cod_imovel(cod)
        if not prop or (prop.area_ha or 0) < MIN_PRECOMPUTE_HA then
            skipped = skipped + 1
        else
            local rec, reason = process_imovel(prop, version_key)
            if rec then
                row_buffer[#row_buffer + 1] = rec
                if #row_buffer >= BULK_CHUNK then
                    local n = car_protected.bulk_upsert(row_buffer)
                    processed = processed + n
                    row_buffer = {}
                end
            else
                skipped = skipped + 1
                if reason == "bbox-filter" then
                    bbox_filtered = bbox_filtered + 1
                end
            end
        end

        local now = os.clock()
        if now - last_log >= 10 then
            local elapsed = now - t0
            local done = processed + skipped
            local eta = (done > 0) and (elapsed / done * (total - done)) or 0
            logger.info(string.format("warm: %d/%d processed=%d skipped=%d bbox_filtered=%d elapsed=%.1fs eta=%.1fs",
                done, total, processed, skipped, bbox_filtered, elapsed, eta))
            last_log = now
        end
    end

    if #row_buffer > 0 then
        local n = car_protected.bulk_upsert(row_buffer)
        processed = processed + n
        row_buffer = {}
    end

    conn:close()

    logger.info(string.format("warm: done. processed=%d skipped=%d bbox_filtered=%d", processed, skipped, bbox_filtered))

    -- Invalida cache Redis para forçar próximos requests a usarem SQLite.
    pcall(function()
        redis.delete_pattern("car:protected:*")
        logger.info("warm: invalidated Redis pattern car:protected:*")
    end)

    return 0
end

local uf = arg and arg[1]
local alt_db_path = arg and arg[2]
if uf and #uf > 0 then
    local code = uf:upper()
    local valid = false
    for _, u in ipairs(UFS) do if u == code then valid = true; break end end
    if not valid then
        print("usage: lua5.1 tools/warm_car_protected_overlap.lua [UF] [ALT_DB_PATH]")
        print("UF must be one of: " .. table.concat(UFS, ","))
        os.exit(1)
    end
end

os.exit(run_batch(uf, alt_db_path))

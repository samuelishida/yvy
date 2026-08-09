-- app/lookups/car_prodes.lua — lookup + writer do pré-cálculo
-- CAR × PRODES (plan: precompute-car-prodes).
--
-- A runtime (routes/car.lua) lê resultados prontos via `get`. O warm offline e
-- o import_car são responsáveis por escrever no car.db; a runtime NUNCA deve
-- escrever na tabela. Por isso `get` reusa a conexão query-only de car_lookup,
-- e as funções de escrita (bulk_upsert) abrem uma conexão própria writable
-- quando invocadas por processos offline.

require("app.env")
local env        = require("app.env")
local sqlite3    = require("lsqlite3")
local cjson      = require("cjson")
local car_lookup = require("app.lookups.car_lookup")
local db         = require("app.db")
local logger     = require("app.logger")
local car_import = require("app.car_import")

local _M = {}

local CAR_DB_PATH = car_lookup.db_path and car_lookup.db_path()
    or env.get("CAR_DB_PATH")
    or env.first_with_existing_parent({
        "backend-lua/data/car/car.db",
        "data/car/car.db",
        "../backend-lua/data/car/car.db",
        "/opt/yvy/backend-lua/data/car/car.db",
    })
    or "backend-lua/data/car/car.db"

local writable_conn = nil
local version_cache = nil
local version_cache_ts = 0
local VERSION_TTL_SECONDS = 5  -- evita COUNT/MIN/MAX por request; invalidado por clear_version_cache

-- Hash simples/stable para version_key (mesmo padrão de car_protected_overlap).
local function short_hash(parts)
    local s = table.concat(parts, "|")
    local h = 5381
    for i = 1, #s do
        h = ((h * 33) + s:byte(i)) % 0x100000000
    end
    return string.format("%08x%08x", h, h)
end

-- Hash determinística de uma amostra dos pontos PRODES (até 10k) para
-- detectar reclassificação/movimentação sem full scan. A amostra é ORDENADA
-- por (lat, lon, year, type) ANTES do hash — sem ORDER BY no scan, a ordem das
-- rows do SQLite não é garantida e um version_key instável invalidaria o
-- pré-cálculo a cada processo (plan: precompute-car-prodes).
local function prodes_sample_hash()
    local rows = db.get_deforestation_in_bbox(-90, 90, -180, 180, 10000)
    table.sort(rows, function(a, b)
        if a.lat ~= b.lat then return (a.lat or 0) < (b.lat or 0) end
        if a.lon ~= b.lon then return (a.lon or 0) < (b.lon or 0) end
        if (a.year or 0) ~= (b.year or 0) then return (a.year or 0) < (b.year or 0) end
        return (a.type or "") < (b.type or "")
    end)
    local parts = {}
    for _, r in ipairs(rows) do
        parts[#parts + 1] = string.format("%.5f:%.5f:%s:%s", r.lat or 0, r.lon or 0, tostring(r.year), tostring(r.type))
    end
    -- Adiciona COUNT/MIN/MAX para reduzir colisão se amostra < população
    local stats = db.get_deforestation_stats()
    if stats then
        parts[#parts + 1] = tostring(stats.count or 0)
        parts[#parts + 1] = tostring(stats.min_year or "")
        parts[#parts + 1] = tostring(stats.max_year or "")
    end
    return short_hash(parts)
end

function _M.current_version_key()
    local now = os.time()
    if version_cache and (now - version_cache_ts) < VERSION_TTL_SECONDS then
        return version_cache
    end

    local row = db.get_deforestation_stats()
    local parts = {
        tostring(env.get("PRODES_VERSION", "")),
        tostring(row and row.count or 0),
        tostring(row and row.min_year or ""),
        tostring(row and row.max_year or ""),
        prodes_sample_hash(),
        tostring(tonumber(env.get("PRODES_PAD_DEG", "0.0003")) or 0.0003),
        tostring(tonumber(env.get("PRODES_PIXEL_HA", "0.09")) or 0.09),
        tostring(tonumber(env.get("PRODES_CANDIDATE_LIMIT", "50000")) or 50000),
    }
    version_cache = short_hash(parts)
    version_cache_ts = now
    return version_cache
end

function _M.clear_version_cache()
    version_cache = nil
    version_cache_ts = 0
end

function _M.db_path()
    return CAR_DB_PATH
end

-- Conexão writable singleton. Usada SOMENTE por scripts offline (warm/import).
local function ensure_conn()
    if writable_conn then return writable_conn end
    local f = io.open(CAR_DB_PATH, "r")
    if not f then
        logger.warn("car_prodes: car.db not found at " .. CAR_DB_PATH)
        return nil
    end
    f:close()

    writable_conn = sqlite3.open(CAR_DB_PATH)
    if not writable_conn then
        logger.warn("car_prodes: failed to open " .. CAR_DB_PATH)
        return nil
    end
    writable_conn:exec("PRAGMA journal_mode=WAL")
    writable_conn:exec("PRAGMA synchronous=OFF")
    writable_conn:exec("PRAGMA cache_size=-200000")
    writable_conn:exec("PRAGMA temp_store=MEMORY")
    writable_conn:exec("PRAGMA busy_timeout=60000")
    _M.ensure_schema(writable_conn)
    return writable_conn
end

function _M.ensure_schema(conn)
    local ok = pcall(car_import.create_car_prodes_schema, conn)
    if not ok then
        logger.warn("car_prodes: ensure_schema failed (read-only?) " .. tostring(conn))
    end
end

-- Lê uma row pré-calculada. Retorna tabela decodificada ou nil se ausente,
-- stale ou corrompido. Usa a conexão query-only de car_lookup (runtime-safe).
function _M.get(cod_imovel)
    local conn = car_lookup and car_lookup._read_only_conn and car_lookup._read_only_conn()
    if not conn then
        -- Fallback: abre conexão read-only curta (não reutiliza a query-only
        -- global de car_lookup, mas nunca escreve).
        conn = sqlite3.open(CAR_DB_PATH)
        if not conn then return nil end
        conn:exec("PRAGMA query_only=ON")
        conn:exec("PRAGMA busy_timeout=5000")
    end

    local stmt = conn:prepare([[
        SELECT cod_imovel, found, has_prodes, prodes_area_ha, property_area_ha,
               pct_deforested, years, classes, regrowth, sampled, bbox,
               area_estimate, version_key, computed_at
        FROM car_prodes WHERE cod_imovel = ?
    ]])
    if not stmt then
        if not car_lookup._read_only_conn then conn:close() end
        return nil
    end
    stmt:bind(1, (cod_imovel or ""):upper())
    local row
    for r in stmt:nrows() do row = r end
    stmt:finalize()
    if not car_lookup._read_only_conn then conn:close() end
    if not row then return nil end

    local current_version = _M.current_version_key()
    if row.version_key ~= current_version then
        return nil
    end

    local function safe_json_decode(raw)
        local ok, v = pcall(cjson.decode, raw or "[]")
        if not ok or type(v) ~= "table" then v = {} end
        return v
    end

    return {
        cod_imovel = row.cod_imovel,
        found = (tonumber(row.found) or 0) ~= 0,
        has_prodes = (tonumber(row.has_prodes) or 0) ~= 0,
        prodes_area_ha = tonumber(row.prodes_area_ha) or 0,
        property_area_ha = tonumber(row.property_area_ha) or 0,
        pct_deforested = tonumber(row.pct_deforested) or 0,
        years = safe_json_decode(row.years),
        classes = safe_json_decode(row.classes),
        regrowth = (tonumber(row.regrowth) or 0) ~= 0,
        sampled = (tonumber(row.sampled) or 0) ~= 0,
        bbox = safe_json_decode(row.bbox),
        area_estimate = row.area_estimate or "pixel-based",
        version_key = row.version_key,
        computed_at = row.computed_at,
    }
end

-- Upsert unitário. Não usado na rota runtime; mantido para testes e helpers.
function _M.upsert(cod_imovel, result)
    local conn = ensure_conn()
    if not conn then return false end

    local years_json, classes_json, bbox_json, ok
    ok, years_json = pcall(cjson.encode, result.years)
    if not ok then years_json = "[]" end
    ok, classes_json = pcall(cjson.encode, result.classes)
    if not ok then classes_json = "[]" end
    ok, bbox_json = pcall(cjson.encode, result.bbox)
    if not ok then bbox_json = "{}" end

    local stmt = conn:prepare([[
        INSERT INTO car_prodes
            (cod_imovel, found, has_prodes, prodes_area_ha, property_area_ha,
             pct_deforested, years, classes, regrowth, sampled, bbox,
             area_estimate, version_key, computed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(cod_imovel) DO UPDATE SET
            found=excluded.found,
            has_prodes=excluded.has_prodes,
            prodes_area_ha=excluded.prodes_area_ha,
            property_area_ha=excluded.property_area_ha,
            pct_deforested=excluded.pct_deforested,
            years=excluded.years,
            classes=excluded.classes,
            regrowth=excluded.regrowth,
            sampled=excluded.sampled,
            bbox=excluded.bbox,
            area_estimate=excluded.area_estimate,
            version_key=excluded.version_key,
            computed_at=excluded.computed_at
    ]])
    if not stmt then return false end
    stmt:bind(1, (cod_imovel or ""):upper())
    stmt:bind(2, result.found and 1 or 0)
    stmt:bind(3, result.has_prodes and 1 or 0)
    stmt:bind(4, result.prodes_area_ha or 0)
    stmt:bind(5, result.property_area_ha or 0)
    stmt:bind(6, result.pct_deforested or 0)
    stmt:bind(7, years_json)
    stmt:bind(8, classes_json)
    stmt:bind(9, result.regrowth and 1 or 0)
    stmt:bind(10, result.sampled and 1 or 0)
    stmt:bind(11, bbox_json)
    stmt:bind(12, result.area_estimate or "pixel-based")
    stmt:bind(13, result.version_key or _M.current_version_key())
    stmt:bind(14, result.computed_at or os.date("!%Y-%m-%dT%H:%M:%SZ"))
    local rc = stmt:step()
    stmt:finalize()
    return rc == sqlite3.DONE
end

-- Bulk UPSERT em transação. Usado exclusivamente pelo warm offline.
function _M.bulk_upsert(rows)
    if not rows or #rows == 0 then return 0 end
    local conn = ensure_conn()
    if not conn then return 0 end

    local stmt = conn:prepare([[
        INSERT INTO car_prodes
            (cod_imovel, found, has_prodes, prodes_area_ha, property_area_ha,
             pct_deforested, years, classes, regrowth, sampled, bbox,
             area_estimate, version_key, computed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(cod_imovel) DO UPDATE SET
            found=excluded.found,
            has_prodes=excluded.has_prodes,
            prodes_area_ha=excluded.prodes_area_ha,
            property_area_ha=excluded.property_area_ha,
            pct_deforested=excluded.pct_deforested,
            years=excluded.years,
            classes=excluded.classes,
            regrowth=excluded.regrowth,
            sampled=excluded.sampled,
            bbox=excluded.bbox,
            area_estimate=excluded.area_estimate,
            version_key=excluded.version_key,
            computed_at=excluded.computed_at
    ]])
    if not stmt then return 0 end

    conn:exec("BEGIN")
    local n = 0
    local ok, err = pcall(function()
        for _, r in ipairs(rows) do
            local years_json, classes_json, bbox_json, enc_ok
            enc_ok, years_json = pcall(cjson.encode, r.years or {})
            if not enc_ok then years_json = "[]" end
            enc_ok, classes_json = pcall(cjson.encode, r.classes or {})
            if not enc_ok then classes_json = "[]" end
            enc_ok, bbox_json = pcall(cjson.encode, r.bbox or {})
            if not enc_ok then bbox_json = "{}" end

            stmt:reset()
            stmt:bind(1, (r.cod_imovel or ""):upper())
            stmt:bind(2, (r.found ~= false) and 1 or 0)
            stmt:bind(3, (r.has_prodes == true) and 1 or 0)
            stmt:bind(4, tonumber(r.prodes_area_ha) or 0)
            stmt:bind(5, tonumber(r.property_area_ha) or 0)
            stmt:bind(6, tonumber(r.pct_deforested) or 0)
            stmt:bind(7, years_json)
            stmt:bind(8, classes_json)
            stmt:bind(9, (r.regrowth == true) and 1 or 0)
            stmt:bind(10, (r.sampled == true) and 1 or 0)
            stmt:bind(11, bbox_json)
            stmt:bind(12, r.area_estimate or "pixel-based")
            stmt:bind(13, r.version_key or _M.current_version_key())
            stmt:bind(14, r.computed_at or os.date("!%Y-%m-%dT%H:%M:%SZ"))
            local rc = stmt:step()
            if rc == sqlite3.DONE then
                n = n + 1
            else
                logger.warn("car_prodes bulk_upsert step failed: " .. tostring(conn:errmsg()))
            end
        end
    end)
    stmt:finalize()
    if not ok then
        pcall(function() conn:exec("ROLLBACK") end)
        logger.warn("car_prodes bulk_upsert aborted: " .. tostring(err))
        return n
    end
    conn:exec("COMMIT")
    return n
end

-- Expõe a conexão writable apenas para scripts offline (warm/merge/tests).
function _M._offline_conn()
    return ensure_conn()
end

return _M

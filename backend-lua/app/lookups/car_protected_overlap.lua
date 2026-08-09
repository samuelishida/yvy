-- app/lookups/car_protected_overlap.lua — lookup + writer do pré-cálculo
-- CAR × UC/TI (plan: car-protected-optimize).
--
-- Módulo separado de car_lookup porque precisa de uma conexão writable
-- dedicada ao car.db (sem PRAGMA query_only=ON). A rota runtime lê daqui;
-- o batch offline e o auto-repair escrevem aqui.

require("app.env")
local env      = require("app.env")
local sqlite3  = require("lsqlite3")
local cjson    = require("cjson")
local car_lookup = require("app.lookups.car_lookup")
local logger   = require("app.logger")

local _M = {}

-- Reusa a mesma resolução de path do car_lookup (SHOULD-FIX #6 do plano).
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

-- Hash simples/stable para version_key. Usa DJB2a em hex (deterministico,
-- curto) — o importante e mudar quando as fontes ou os parametros mudam.
-- Nota: luaossl/luacrypto nao sao dependencias do projeto; mantemos puramente
-- em Lua para evitar acrescentar uma libnova.
local function short_hash(parts)
    local s = table.concat(parts, "|")
    local h = 5381
    for i = 1, #s do
        h = ((h * 33) + s:byte(i)) % 0x100000000
    end
    return string.format("%08x%08x", h, h)
end

local version_cache = nil

-- Retorna o stamp canonical da combinação (fontes UC/TI + OVERLAP_SAMPLES).
-- NÃO inclui OVERLAP_SUSPECT, porque status é re-avaliado em runtime.
function _M.current_version_key()
    if version_cache then return version_cache end

    local uc = require("app.lookups.conservation_units_lookup")
    local ti = require("app.lookups.indigenous_lands_lookup")

    local samples = tonumber(env.get("PROTECTED_OVERLAP_SAMPLES", "32")) or 32
    local parts = {
        tostring(samples),
        tostring(uc.count()),
        tostring(ti.count()),
    }
    -- Adiciona bounds de cada UC/TI para detectar mudança de geometria.
    for _, u in ipairs(uc.units() or {}) do
        local b = u.bounds
        parts[#parts + 1] = "uc:" .. (u.name or "") .. ":" .. b[1] .. "," .. b[2] .. "," .. b[3] .. "," .. b[4]
    end
    for _, t in ipairs(ti.lands() or {}) do
        local b = t.bounds
        parts[#parts + 1] = "ti:" .. (t.name or "") .. ":" .. b[1] .. "," .. b[2] .. "," .. b[3] .. "," .. b[4]
    end

    version_cache = short_hash(parts)
    return version_cache
end

function _M.clear_version_cache()
    version_cache = nil
end

function _M.db_path()
    return CAR_DB_PATH
end

-- Conexão writable singleton. PRAGMAs de bulk-write (CONSIDER #12).
local function ensure_conn()
    if writable_conn then return writable_conn end
    local f = io.open(CAR_DB_PATH, "r")
    if not f then
        logger.warn("car_protected_overlap: car.db not found at " .. CAR_DB_PATH)
        return nil
    end
    f:close()

    writable_conn = sqlite3.open(CAR_DB_PATH)
    if not writable_conn then
        logger.warn("car_protected_overlap: failed to open " .. CAR_DB_PATH)
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
    conn:exec([[
        CREATE TABLE IF NOT EXISTS car_protected_overlap (
            cod_imovel TEXT PRIMARY KEY,
            sampled INTEGER NOT NULL,
            overlaps TEXT NOT NULL,
            status TEXT NOT NULL,
            max_pct REAL NOT NULL,
            threshold REAL NOT NULL,
            version_key TEXT NOT NULL,
            computed_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_car_protected_computed_at
            ON car_protected_overlap(computed_at);
    ]])
end

-- Lê uma row pré-calculada. Retorna tabela decodificada ou nil.
function _M.get(cod_imovel)
    local conn = ensure_conn()
    if not conn then return nil end
    local stmt = conn:prepare([[
        SELECT sampled, overlaps, status, max_pct, threshold, version_key, computed_at
        FROM car_protected_overlap WHERE cod_imovel = ?
    ]])
    if not stmt then return nil end
    stmt:bind(1, cod_imovel:upper())
    local row
    for r in stmt:nrows() do row = r end
    stmt:finalize()
    if not row then return nil end

    local ok, overlaps = pcall(cjson.decode, row.overlaps or "[]")
    if not ok or type(overlaps) ~= "table" then overlaps = {} end
    return {
        cod_imovel = cod_imovel:upper(),
        sampled = tonumber(row.sampled) or 0,
        overlaps = overlaps,
        status = row.status,
        max_pct = tonumber(row.max_pct) or 0,
        threshold = tonumber(row.threshold) or 0,
        version_key = row.version_key,
        computed_at = row.computed_at,
    }
end

-- UPSERT unitário. Usado apenas pelo auto-repair throttled da rota.
function _M.upsert(cod_imovel, result, computed_at)
    local conn = ensure_conn()
    if not conn then return false end
    local overlaps_json, ok
    ok, overlaps_json = pcall(cjson.encode, result.overlaps)
    if not ok then
        logger.warn("car_protected_overlap upsert encode failed for " .. tostring(cod_imovel))
        return false
    end

    local stmt = conn:prepare([[
        INSERT INTO car_protected_overlap
            (cod_imovel, sampled, overlaps, status, max_pct, threshold, version_key, computed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(cod_imovel) DO UPDATE SET
            sampled=excluded.sampled,
            overlaps=excluded.overlaps,
            status=excluded.status,
            max_pct=excluded.max_pct,
            threshold=excluded.threshold,
            version_key=excluded.version_key,
            computed_at=excluded.computed_at
    ]])
    if not stmt then return false end
    stmt:bind(1, cod_imovel:upper())
    stmt:bind(2, result.sampled or 0)
    stmt:bind(3, overlaps_json)
    stmt:bind(4, result.status or "ok")
    stmt:bind(5, result.max_pct or 0)
    stmt:bind(6, result.threshold or tonumber(env.get("PROTECTED_OVERLAP_SUSPECT", "0.8")) or 0.8)
    stmt:bind(7, result.version_key or _M.current_version_key())
    stmt:bind(8, computed_at or os.date("!%Y-%m-%dT%H:%M:%SZ"))
    local rc = stmt:step()
    stmt:finalize()
    return rc == sqlite3.DONE
end

-- Bulk UPSERT em transação. Usado exclusivamente pelo batch offline.
function _M.bulk_upsert(rows)
    if not rows or #rows == 0 then return 0 end
    local conn = ensure_conn()
    if not conn then return 0 end

    local stmt = conn:prepare([[
        INSERT INTO car_protected_overlap
            (cod_imovel, sampled, overlaps, status, max_pct, threshold, version_key, computed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(cod_imovel) DO UPDATE SET
            sampled=excluded.sampled,
            overlaps=excluded.overlaps,
            status=excluded.status,
            max_pct=excluded.max_pct,
            threshold=excluded.threshold,
            version_key=excluded.version_key,
            computed_at=excluded.computed_at
    ]])
    if not stmt then return 0 end

    conn:exec("BEGIN")
    local n = 0
    local ok, err = pcall(function()
        for _, r in ipairs(rows) do
            local overlaps_json
            local enc_ok
            enc_ok, overlaps_json = pcall(cjson.encode, r.overlaps)
            if not enc_ok then
                logger.warn("bulk_upsert encode failed for " .. tostring(r.cod_imovel) .. ": " .. tostring(overlaps_json))
            else
                stmt:reset()
                stmt:bind(1, r.cod_imovel:upper())
                stmt:bind(2, r.sampled or 0)
                stmt:bind(3, overlaps_json)
                stmt:bind(4, r.status or "ok")
                stmt:bind(5, r.max_pct or 0)
                stmt:bind(6, r.threshold or tonumber(env.get("PROTECTED_OVERLAP_SUSPECT", "0.8")) or 0.8)
                stmt:bind(7, r.version_key or _M.current_version_key())
                stmt:bind(8, r.computed_at or os.date("!%Y-%m-%dT%H:%M:%SZ"))
                local rc = stmt:step()
                if rc == sqlite3.DONE then
                    n = n + 1
                end
            end
        end
    end)
    stmt:finalize()
    if ok then
        conn:exec("COMMIT")
    else
        pcall(function() conn:exec("ROLLBACK") end)
        logger.warn("bulk_upsert failed: " .. tostring(err))
        return 0
    end
    return n
end

return _M

-- tools/warm_car_prodes.lua — pré-cálculo offline CAR × PRODES
--
-- Usage:
--   lua5.1 tools/warm_car_prodes.lua [UF] [ALT_DB_PATH]
-- Sem argumento → todas as 27 UFs (sequential; para produção usar shell
-- worker que clona car.db por UF e invoca em paralelo, depois faz merge).
--
-- Só grava imóveis com has_prodes=true (pontos dentro do polígono CAR). Imóveis
-- sem PRODES continuam sendo resolvidos via fallback live, sem ocupar linhas
-- na tabela. A rota runtime consulta car_prodes ANTES do fallback.

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local backend_dir = script_dir:gsub("[\\/]tools[\\/]$", "/")
package.path = backend_dir .. "?.lua;" .. backend_dir .. "?/init.lua;" .. package.path

local env = require("app.env")
env.load_dotenv(backend_dir .. "../.env")
env.load_dotenv(backend_dir .. ".env")

local sqlite3    = require("lsqlite3")
local logger     = require("app.logger")
local db         = require("app.db")
local car_lookup = require("app.lookups.car_lookup")
local car_prodes = require("app.lookups.car_prodes")
local redis      = require("app.redis")
local car_routes = require("app.routes.car")

local UFS = {"AC","AL","AM","AP","BA","CE","DF","ES","GO","MA","MG","MS","MT",
             "PA","PB","PE","PI","PR","RJ","RN","RO","RR","RS","SC","SE","SP","TO"}

local MIN_PRECOMPUTE_HA = tonumber(env.get("CAR_PRODES_MIN_AREA_HA", "10")) or 10
local BULK_CHUNK = 500

-- Require-ável para testes (padrão deter_protected_alerts.lua): exports
-- run_batch e internals; quando carregado como módulo (busted), NÃO executa
-- o batch no load.
local _M = {}
-- Testes setam _skip_redis_invalidation=true para não varrer o namespace
-- car:prodes:* do Redis compartilhado (common-mistake §2).
_M._skip_redis_invalidation = false

-- Backup do car.db ANTES da primeira escrita no DB principal (plan:
-- precompute-car-prodes). Não roda em clones (alt_db_path) — clones são
-- descartáveis; igual warm_car_protected_overlap (SHOULD-FIX #10).
local function backup_if_needed(db_path)
    local f = io.open(db_path, "r")
    if not f then return false end
    f:close()

    local exists = false
    for attempt = 1, 30 do
        local conn = sqlite3.open(db_path)
        if conn then
            conn:exec("PRAGMA busy_timeout=60000")
            for row in conn:nrows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='car_prodes'") do
                exists = true
            end
            conn:close()
            if exists then break end
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

-- Determina se o imóvel tem PRODES sem repetir a lógica da rota: roda
-- compute_prodes_for_property e descarta resultados com def_count == 0.
local function process_imovel(prop, version_key)
    local result = car_routes.compute_prodes_for_property(prop)
    if not result then return nil end
    if result.has_prodes then
        result.version_key = version_key
        result.computed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        return result
    end
    return nil
end

-- Lista todos os cod_imovel da UF (ou todos) com área >= threshold.
local function candidate_ids(conn, uf_filter)
    local ids = {}
    local sql = "SELECT cod_imovel FROM car_data d JOIN car_rtree r ON d.id = r.id WHERE d.area >= " .. MIN_PRECOMPUTE_HA
    if uf_filter and uf_filter ~= "" then
        sql = sql .. " AND d.uf = '" .. uf_filter:upper() .. "'"
    end
    for row in conn:nrows(sql) do
        ids[#ids + 1] = row.cod_imovel
    end
    return ids
end

local function run_batch(uf_filter, alt_db_path)
    local db_path = alt_db_path or car_prodes.db_path()
    local f = io.open(db_path, "r")
    if not f then
        logger.error("warm_car_prodes: car.db not found at " .. db_path)
        return 1
    end
    f:close()

    db.init_db()
    car_lookup.load_car()

    if not car_lookup.is_loaded() then
        logger.error("warm_car_prodes: car.db empty or unavailable")
        return 1
    end

    -- Para alt_db_path (clone por UF), aponta o módulo para o clone.
    if alt_db_path then
        env.set("CAR_DB_PATH", alt_db_path)
        package.loaded["app.lookups.car_lookup"] = nil
        package.loaded["app.lookups.car_prodes"] = nil
        package.loaded["app.routes.car"] = nil
        car_lookup = require("app.lookups.car_lookup")
        car_prodes = require("app.lookups.car_prodes")
        car_routes = require("app.routes.car")
        car_lookup.load_car()
    end

    -- Backup antes da primeira escrita no car.db principal. Clones (alt_db_path)
    -- são descartáveis e não precisam de backup.
    if not alt_db_path then
        backup_if_needed(db_path)
    end

    car_prodes.ensure_schema(sqlite3.open(db_path))

    local version_key = car_prodes.current_version_key()
    logger.info("warm_car_prodes: version_key=" .. version_key)

    local conn = sqlite3.open(db_path)
    if not conn then
        logger.error("warm_car_prodes: cannot open car.db for reading")
        return 1
    end

    local ids = candidate_ids(conn, uf_filter)
    local total = #ids
    logger.info("warm_car_prodes: " .. total .. " candidate imóveis to process")

    local processed = 0
    local skipped = 0
    local row_buffer = {}
    local t0 = os.clock()
    local last_log = t0

    for _, cod in ipairs(ids) do
        local prop = car_lookup.get_by_cod_imovel(cod)
        if not prop or (prop.area_ha or 0) < MIN_PRECOMPUTE_HA then
            skipped = skipped + 1
        else
            local rec = process_imovel(prop, version_key)
            if rec then
                row_buffer[#row_buffer + 1] = rec
                if #row_buffer >= BULK_CHUNK then
                    local n = car_prodes.bulk_upsert(row_buffer)
                    processed = processed + n
                    row_buffer = {}
                end
            else
                skipped = skipped + 1
            end
        end

        local now = os.clock()
        if now - last_log >= 10 then
            local elapsed = now - t0
            local done = processed + skipped
            local eta = (done > 0) and (elapsed / done * (total - done)) or 0
            logger.info(string.format("warm_car_prodes: %d/%d processed=%d skipped=%d elapsed=%.1fs eta=%.1fs",
                done, total, processed, skipped, elapsed, eta))
            last_log = now
        end
    end

    if #row_buffer > 0 then
        local n = car_prodes.bulk_upsert(row_buffer)
        processed = processed + n
        row_buffer = {}
    end

    conn:close()

    logger.info(string.format("warm_car_prodes: done. processed=%d skipped=%d", processed, skipped))

    -- Invalida cache Redis para forçar próximos requests a usarem a tabela.
    -- Testes setam _skip_redis_invalidation para não varrer o namespace
    -- car:prodes:* do Redis compartilhado (common-mistake §2).
    if not _M._skip_redis_invalidation then
        pcall(function()
            redis.delete_pattern("car:prodes:*")
            logger.info("warm_car_prodes: invalidated Redis pattern car:prodes:*")
        end)
    end

    return 0
end

_M.run_batch = run_batch
_M.candidate_ids = candidate_ids
_M.process_imovel = process_imovel
_M.backup_if_needed = backup_if_needed

-- arg[0] = script principal quando rodado direto (lua5.1 tools/warm_car_prodes.lua)
local is_main = arg and arg[0] and arg[0]:match("warm_car_prodes%.lua$")
if is_main then
    local uf = arg and arg[1]
    local alt_db_path = arg and arg[2]
    if uf and #uf > 0 then
        local code = uf:upper()
        local valid = false
        for _, u in ipairs(UFS) do if u == code then valid = true; break end end
        if not valid then
            print("usage: lua5.1 tools/warm_car_prodes.lua [UF] [ALT_DB_PATH]")
            print("UF must be one of: " .. table.concat(UFS, ","))
            os.exit(1)
        end
    end
    os.exit(run_batch(uf, alt_db_path))
end

return _M

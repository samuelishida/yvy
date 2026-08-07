local env    = require("app.env")
local db     = require("app.db")
local sqlite3 = require("lsqlite3")
local utils  = require("app.utils")
local logger = require("app.logger")

local _M = {}

function _M.parse_qml(file_path)
    local file = io.open(file_path, "r")
    if not file then
        logger.warn("QML file not found: " .. file_path)
        return {}
    end

    local xml_text = file:read("*a")
    file:close()

    local color_legend = {}
    -- Extract each paletteEntry tag and parse attributes individually (order-independent)
    for entry in xml_text:gmatch("<paletteEntry[^/]-/>") do
        local value = entry:match([[value="(%d+)"]])
        local color = entry:match([[color="([^"]+)"]])
        local label = entry:match([[label="([^"]+)"]])
        if value and color and label then
            color_legend[tonumber(value)] = { color = color, label = label }
        end
    end

    return color_legend
end

function _M.ingest_prodes(csv_path, qml_path)
    local color_legend = _M.parse_qml(qml_path)

    local file = io.open(csv_path, "r")
    if not file then
        logger.error("PRODES CSV not found: " .. csv_path)
        return 0
    end

    local docs = {}
    local line_count = 0
    file:read("*l")

    for line in file:lines() do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            local lon, lat, value = line:match("([^,]+),([^,]+),([^,]+)")
            if lon and lat and value then
                lon = tonumber(lon)
                lat = tonumber(lat)
                value = tonumber(value)

                if lon and lat and value and color_legend[value] then
                    local legend = color_legend[value]
                    docs[#docs + 1] = {
                        lat = lat,
                        lon = lon,
                        name = legend.label,
                        clazz = "Desmatamento",
                        periods = "N/A",
                        source = "TerraBrasilis",
                        color = legend.color,
                        timestamp = utils.now_iso(),
                    }
                    line_count = line_count + 1
                end
            end
        end

        if #docs >= 1000 then
            db.bulk_upsert_deforestation(docs)
            docs = {}
        end
    end

    file:close()

    if #docs > 0 then
        db.bulk_upsert_deforestation(docs)
    end

    logger.info("PRODES ingestion complete: " .. line_count .. " records")
    return line_count
end

-- PRODES_FORCE_UPDATE: safety backup (VACUUM INTO snapshot) + truncate antes
-- de re-ingestir uma versão nova. Ordem: backup → verify → truncate. Se algo
-- falhar depois do truncate, deforestation_data é restaurada do backup
-- (table-level, via ATTACH) e o erro é re-lançado (exit != 0).
-- Só executa com PRODES_FORCE_UPDATE=1 (plan: terrabrasilis-integration, Inc 5).

-- PRAGMA wal_checkpoint devolve uma ROW (busy, log, checkpointed) — o flag
-- "busy" está na row, não no código de retorno do exec.
function _M.checkpoint_ok(result)
    return result ~= nil and (tonumber(result.busy or 0) or 0) == 0
end

-- Valida caminho de backup: nome/path simples, sem aspas simples (evita
-- injeção de SQL em VACUUM INTO / ATTACH DATABASE).
local function validate_backup_path(path)
    return path ~= nil and path ~= "" and not path:find("'", 1, true)
end

-- Checkpoint com leitura correta do flag busy (retry 1×; busy → warn, não falha).
local function checkpoint_wal(db_path)
    for attempt = 1, 2 do
        local cdb = sqlite3.open(db_path)
        cdb:exec("PRAGMA busy_timeout=15000")
        local last = { busy = 1 }
        for row in cdb:nrows("PRAGMA wal_checkpoint(TRUNCATE)") do
            last = row
        end
        cdb:close()
        if _M.checkpoint_ok(last) then
            return true
        end
    end
    return false
end

-- Abre o snapshot e roda integrity_check; também confirma que não está vazio.
local function verify_backup(backup_path)
    local f = io.open(backup_path, "rb")
    if not f then
        return false, "backup file not found: " .. tostring(backup_path)
    end
    local size = f:seek("end")
    f:close()
    if not size or size == 0 then
        return false, "backup file is empty: " .. tostring(backup_path)
    end

    local bdb = sqlite3.open(backup_path)
    if not bdb then
        return false, "cannot open backup: " .. tostring(backup_path)
    end
    local ok = false
    for row in bdb:nrows("PRAGMA integrity_check") do
        if tostring(row.integrity_check or row[1]) == "ok" then
            ok = true
        end
    end
    bdb:close()
    if not ok then
        return false, "integrity_check failed on backup: " .. tostring(backup_path)
    end
    return true
end

-- Restaura SÓ a tabela deforestation_data a partir do snapshot (table-level):
-- ATTACH + DELETE/INSERT dentro de transação. NUNCA cópia de arquivo por cima
-- do DB vivo — isso corromperia a conexão do serviço em execução e reverteria
-- escritas concorrentes em fire_data/news feitas durante a janela de ingest.
function _M.restore_deforestation_from(backup_path)
    -- Aceita também o arquivo ".new" (caso o rename pós-verificação falhe).
    local path = backup_path
    local f = io.open(path, "rb")
    if not f then
        local alt = backup_path .. ".new"
        local f2 = io.open(alt, "rb")
        if not f2 then
            return false, "backup not found for restore: " .. tostring(backup_path)
        end
        f2:close()
        path = alt
    else
        f:close()
    end

    if not validate_backup_path(path) then
        return false, "invalid backup path for restore: " .. tostring(path)
    end

    local db = sqlite3.open(db.path())
    db:exec("PRAGMA busy_timeout=15000")
    local rc = db:exec("ATTACH DATABASE '" .. path .. "' AS bak")
    if rc ~= sqlite3.OK then
        db:close()
        return false, "ATTACH backup failed"
    end

    db:exec("BEGIN")
    local rc1 = db:exec("DELETE FROM main.deforestation_data")
    local rc2 = sqlite3.OK
    if rc1 == sqlite3.OK then
        rc2 = db:exec("INSERT INTO main.deforestation_data (id, lat, lon, data) SELECT id, lat, lon, data FROM bak.deforestation_data")
    end
    if rc1 ~= sqlite3.OK or rc2 ~= sqlite3.OK then
        db:exec("ROLLBACK")
        db:exec("DETACH DATABASE bak")
        db:close()
        return false, "restore of deforestation_data failed"
    end
    db:exec("COMMIT")
    db:exec("DETACH DATABASE bak")
    db:close()
    logger.warn("PRODES_FORCE_UPDATE: deforestation_data restored from ", path)
    return true
end

-- Backup → verify → truncate. Retorna (true, backup_path) ou (false, motivo).
-- O backup antigo só é removido depois do novo estar verificado.
function _M.force_update_prodes(db_path, backup_path)
    db_path = db_path or db.path()
    backup_path = backup_path or (db_path .. ".preprodes")

    if not validate_backup_path(backup_path) then
        return false, "invalid backup path (single quote not allowed)"
    end

    -- 1. Checkpoint (busy flag lido da result row; busy → warn, não falha)
    if not checkpoint_wal(db_path) then
        logger.warn("PRODES_FORCE_UPDATE: wal_checkpoint busy after retry — proceeding")
    end

    -- 2. Backup binário novo — VACUUM INTO cria um snapshot standalone
    --    (equivalente ao `sqlite3 .backup`; NUNCA `sqlite3 db < backup` que só
    --    lê .dump texto). VACUUM INTO recusa arquivo existente → grava em
    --    <backup>.new primeiro.
    local new_backup = backup_path .. ".new"
    os.remove(new_backup)
    local bdb = sqlite3.open(db_path)
    bdb:exec("PRAGMA busy_timeout=15000")
    local brc = bdb:exec("VACUUM INTO '" .. new_backup .. "'")
    bdb:close()
    if brc ~= sqlite3.OK then
        return false, "VACUUM INTO backup failed"
    end

    -- 3. Verifica o backup novo ANTES de truncar qualquer coisa.
    local okv, verr = verify_backup(new_backup)
    if not okv then
        os.remove(new_backup)
        return false, tostring(verr)
    end

    -- 4. Só agora o backup antigo pode ser substituído (o novo está verificado).
    os.remove(backup_path)
    if not os.rename(new_backup, backup_path) then
        logger.warn("PRODES_FORCE_UPDATE: rename backup failed — keeping ", new_backup)
    end

    -- 5. Truncate (retry 3× via db.truncate_deforestation)
    if not db.truncate_deforestation() then
        return false, "DELETE deforestation_data failed (DB locked)"
    end
    return true, backup_path
end

function _M.run()
    -- Skip if deforestation data already in DB (unless PRODES_FORCE_UPDATE=1)
    local force = os.getenv("PRODES_FORCE_UPDATE") == "1"
    local version = os.getenv("PRODES_VERSION") or "prodes_brasil_2024_v20260407"
    local existing = db.count_deforestation()
    if existing > 0 and not force then
        logger.info("PRODES: ", existing, " rows already in DB — skipping ingestion")
        return 0
    end

    local csv_path = env.first_existing({
        (os.getenv("DATA_DIR") or "") .. "/" .. version .. ".csv",
        "data/" .. version .. "/" .. version .. ".csv",
        "/opt/yvy/backend-lua/data/" .. version .. "/" .. version .. ".csv",
    })
    local qml_path = env.first_existing({
        (os.getenv("DATA_DIR") or "") .. "/" .. version .. ".qml",
        "data/" .. version .. "/" .. version .. ".qml",
        "/opt/yvy/backend-lua/data/" .. version .. "/" .. version .. ".qml",
    })

    if not csv_path or not qml_path then
        logger.info("PRODES source files not found - skipping ingestion")
        return 0
    end

    if force and existing > 0 then
        logger.warn("PRODES_FORCE_UPDATE: truncating deforestation_data and re-ingesting ", version)
        local ok, backup_path = _M.force_update_prodes()
        if not ok then
            logger.error("PRODES_FORCE_UPDATE aborted (no data truncated): ", tostring(backup_path))
            error("PRODES_FORCE_UPDATE aborted: " .. tostring(backup_path))
        end

        -- Ingest protegido: qualquer falha (erro, 0 registros, 0 linhas no DB)
        -- → restaura deforestation_data do backup e re-lança (exit != 0).
        local ok2, res = pcall(_M.ingest_prodes, csv_path, qml_path)
        local final_count = db.count_deforestation()
        if not ok2 or not res or res == 0 or final_count == 0 then
            local reason = ok2 and ("ingested 0 records from " .. version) or tostring(res)
            local rok, rerr = _M.restore_deforestation_from(backup_path)
            if not rok then
                logger.error("PRODES_FORCE_UPDATE restore failed: ", tostring(rerr))
            end
            error("PRODES_FORCE_UPDATE failed (" .. reason .. "); deforestation_data restored from backup")
        end
        return res
    end

    return _M.ingest_prodes(csv_path, qml_path)
end

return _M

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

-- PRODES_FORCE_UPDATE: safety backup (sqlite3 .backup) + truncate antes de
-- re-ingestir uma versão nova. Retorna true ou (false, motivo). Só executa com
-- PRODES_FORCE_UPDATE=1 (plan: terrabrasilis-integration, Inc 5).
function _M.prepare_force_update()
    local db_path = db.path()

    -- 1. Checkpoint (retry 2×)
    local ok = false
    for _ = 1, 2 do
        local cdb = sqlite3.open(db_path)
        cdb:exec("PRAGMA busy_timeout=15000")
        local rc = cdb:exec("PRAGMA wal_checkpoint(TRUNCATE)")
        cdb:close()
        if rc == sqlite3.OK then
            ok = true
            break
        end
    end
    if not ok then
        return false, "wal_checkpoint failed"
    end

    -- 2. Backup binário — VACUUM INTO cria um snapshot standalone do DB
    --    (equivalente ao `sqlite3 .backup`; NUNCA `sqlite3 db < backup` que só
    --    lê .dump texto). VACUUM INTO recusa arquivo existente → remove antes.
    local backup_path = db_path .. ".preprodes"
    os.remove(backup_path)
    local bdb = sqlite3.open(db_path)
    bdb:exec("PRAGMA busy_timeout=15000")
    local brc = bdb:exec("VACUUM INTO '" .. backup_path .. "'")
    bdb:close()
    if brc ~= sqlite3.OK then
        return false, "VACUUM INTO backup failed"
    end

    -- 3. Truncate (retry 3× via db.truncate_deforestation)
    if not db.truncate_deforestation() then
        return false, "DELETE deforestation_data failed (DB locked)"
    end
    return true
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
        local ok, err = _M.prepare_force_update()
        if not ok then
            logger.error("PRODES_FORCE_UPDATE aborted: ", tostring(err))
            return 0
        end
    end

    return _M.ingest_prodes(csv_path, qml_path)
end

return _M

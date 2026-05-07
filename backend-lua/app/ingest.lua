local env    = require("app.env")
local db     = require("app.db")
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
    for value, color, label in xml_text:gmatch([[paletteEntry value="(%d+)" color="([^"]+)" label="([^"]+)"]]) do
        color_legend[tonumber(value)] = {
            color = color,
            label = label,
        }
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

function _M.run()
    -- Skip if deforestation data already in DB
    local existing = db.count_deforestation()
    if existing > 0 then
        logger.info("PRODES: ", existing, " rows already in DB — skipping ingestion")
        return 0
    end

    local csv_path = env.first_existing({
        (os.getenv("DATA_DIR") or "") .. "/prodes_brasil_2023.csv",
        "data/prodes_brasil_2023.csv",
        "../backend/prodes_brasil_2023.csv",
        "/opt/yvy/backend-lua/data/prodes_brasil_2023.csv",
    })
    local qml_path = env.first_existing({
        (os.getenv("DATA_DIR") or "") .. "/prodes_brasil_2023.qml",
        "data/prodes_brasil_2023.qml",
        "../backend/prodes_brasil_2023.qml",
        "/opt/yvy/backend-lua/data/prodes_brasil_2023.qml",
    })

    if not csv_path or not qml_path then
        logger.info("PRODES source files not found - skipping ingestion")
        return 0
    end

    return _M.ingest_prodes(csv_path, qml_path)
end

return _M

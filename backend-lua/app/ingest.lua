-- ingest.lua — Ingest TerraBrasilis PRODES data into SQLite
-- Port of backend/ingest_sqlite.py
-- Reads pre-processed CSV (from GDAL in CI) instead of TIF directly

local db    = require("app.db")
local utils = require("app.utils")
local cjson = require("cjson")

local _M = {}

-- ── QML color legend parser ──────────────────────────────────────────────

function _M.parse_qml(file_path)
    """Parse QML XML file to extract color legend. Returns {[value] = {color, label}}."""
    local f = io.open(file_path, "r")
    if not f then
        ngx.log(ngx.WARN, "QML file not found: ", file_path)
        return {}
    end
    local xml_text = f:read("*a")
    f:close()

    local color_legend = {}

    -- Simple regex-based QML parsing (avoids full XML parser for this simple case)
    for value, color, label in xml_text:gmatch([[paletteEntry value="(%d+)" color="([^"]+)" label="([^"]+)"]]) do
        color_legend[tonumber(value)] = {
            color = color,
            label = label,
        }
    end

    return color_legend
end

-- ── CSV-based PRODES ingestion ───────────────────────────────────────────

function _M.ingest_prodes(csv_path, qml_path)
    """Ingest PRODES data from CSV file (pre-processed from TIF via GDAL).
    CSV format: lon,lat,value
    """
    local color_legend = _M.parse_qml(qml_path)

    local f = io.open(csv_path, "r")
    if not f then
        ngx.log(ngx.ERR, "PRODES CSV not found: ", csv_path)
        return 0
    end

    local docs = {}
    local line_count = 0

    -- Skip header
    f:read("*l")

    for line in f:lines() do
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

        -- Batch insert every 1000 rows
        if #docs >= 1000 then
            db.bulk_upsert_deforestation(docs)
            docs = {}
        end
    end

    f:close()

    -- Insert remaining
    if #docs > 0 then
        db.bulk_upsert_deforestation(docs)
    end

    ngx.log(ngx.INFO, "PRODES ingestion complete: ", line_count, " records")
    return line_count
end

-- ── Standalone runner ────────────────────────────────────────────────────

function _M.run()
    """Run ingestion from default paths. Called from init or manually."""
    local data_dir = os.getenv("DATA_DIR") or "/opt/yvy/backend-lua/data"
    local csv_path = data_dir .. "/prodes_brasil_2023.csv"
    local qml_path = data_dir .. "/prodes_brasil_2023.qml"

    -- Check if CSV exists
    local f = io.open(csv_path, "r")
    if not f then
        ngx.log(ngx.INFO, "PRODES CSV not found at ", csv_path, " — skipping ingestion")
        return 0
    end
    f:close()

    return _M.ingest_prodes(csv_path, qml_path)
end

return _M

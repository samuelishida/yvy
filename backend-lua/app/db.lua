-- db.lua — SQLite database layer with JSONB support (baremetal Lua)
-- Port of backend/db_sqlite.py
--
-- Uses lsqlite3 (LuaJIT FFI binding to SQLite).
-- Single connection per process with WAL mode for concurrent reads.
--
-- Tables use hybrid scalar + JSONB BLOB columns:
--   fire_data:          lat, lon, acq_date, ingested_at | data BLOB
--   deforestation_data: lat, lon                        | data BLOB
--   news:               url, publishedAt, ingested_at   | data BLOB

local env     = require("app.env")
local sqlite3 = require("lsqlite3")
local utils   = require("app.utils")
local cjson   = require("cjson")
local logger  = require("app.logger")

local _M = {}

-- ── Configuration ────────────────────────────────────────────────────────

local configured_db_path = env.get("SQLITE_PATH")
if configured_db_path and configured_db_path:match("backend[/\\]data[/\\]yvy%.db") then
    logger.warn("Ignoring legacy SQLITE_PATH; using backend-lua/data/yvy.db", { path = configured_db_path })
    configured_db_path = nil
end

local DB_PATH = configured_db_path or env.first_with_existing_parent({
    "backend-lua/data/yvy.db",
    "data/yvy.db",
    "../backend-lua/data/yvy.db",
    "/opt/yvy/backend-lua/data/yvy.db",
})
local POOL_SIZE = 3  -- connections per nginx worker

-- ── Schema ───────────────────────────────────────────────────────────────

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS fire_data (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    lat REAL NOT NULL,
    lon REAL NOT NULL,
    acq_date TEXT,
    ingested_at TEXT,
    data BLOB,
    nature TEXT,
    nature_evidence BLOB,
    nature_at TEXT,
    nature_version INTEGER DEFAULT 0,
    UNIQUE(lat, lon, acq_date)
);

CREATE TABLE IF NOT EXISTS deforestation_data (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    lat REAL,
    lon REAL,
    data BLOB
);

CREATE TABLE IF NOT EXISTS news (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    url TEXT UNIQUE NOT NULL,
    publishedAt TEXT,
    ingested_at TEXT,
    data BLOB
);

CREATE INDEX IF NOT EXISTS idx_fire_lat ON fire_data(lat);
CREATE INDEX IF NOT EXISTS idx_fire_lon ON fire_data(lon);
CREATE INDEX IF NOT EXISTS idx_fire_acq_date ON fire_data(acq_date);
CREATE INDEX IF NOT EXISTS idx_fire_bbox_date ON fire_data(lat, lon, acq_date DESC);
CREATE INDEX IF NOT EXISTS idx_def_lat ON deforestation_data(lat);
CREATE INDEX IF NOT EXISTS idx_def_lon ON deforestation_data(lon);
CREATE INDEX IF NOT EXISTS idx_def_bbox ON deforestation_data(lat, lon);
CREATE INDEX IF NOT EXISTS idx_news_published ON news(publishedAt);
CREATE INDEX IF NOT EXISTS idx_news_ingested ON news(ingested_at);
CREATE INDEX IF NOT EXISTS idx_news_page ON news(publishedAt DESC, ingested_at DESC);
CREATE INDEX IF NOT EXISTS idx_fire_confidence ON fire_data(json_extract(data, '$.confidence'));
CREATE INDEX IF NOT EXISTS idx_fire_state ON fire_data(json_extract(data, '$.state'));
CREATE INDEX IF NOT EXISTS idx_fire_fire_type ON fire_data(json_extract(data, '$.fire_type'));
CREATE INDEX IF NOT EXISTS idx_fire_biome ON fire_data(json_extract(data, '$.biome'));
CREATE INDEX IF NOT EXISTS idx_def_name ON deforestation_data(json_extract(data, '$.name'));
CREATE INDEX IF NOT EXISTS idx_news_source ON news(json_extract(data, '$.source_name'));

CREATE TABLE IF NOT EXISTS lookup_data (
    key TEXT PRIMARY KEY,
    data BLOB,
    updated_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_lookup_updated ON lookup_data(updated_at);

-- ── TerraBrasilis integration tables (.plans/terrabrasilis-integration) ──
-- `geom` is declared BLOB (SQLite BLOB affinity stores values as-is) but
-- Python writers store GeoJSON as TEXT (python3 sqlite3 may link SQLite
-- < 3.45 without jsonb()); Lua json()/json_extract() read TEXT and JSONB
-- alike, so both storage forms are safe.

CREATE TABLE IF NOT EXISTS deter_polygons (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    classname TEXT,
    view_date TEXT,
    uf TEXT,
    municipality TEXT,
    mun_geocod TEXT,
    area_km2 REAL,
    uc TEXT,
    areauckm REAL,
    areamunkm REAL,
    publish_month TEXT,
    sensor TEXT,
    satellite TEXT,
    min_lat REAL,
    min_lon REAL,
    max_lat REAL,
    max_lon REAL,
    geom BLOB,
    ingested_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_deter_bbox ON deter_polygons(min_lat, min_lon, max_lat, max_lon);
CREATE INDEX IF NOT EXISTS idx_deter_view_date ON deter_polygons(view_date);

CREATE TABLE IF NOT EXISTS deter_car_alerts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    cod_imovel TEXT,
    classname TEXT,
    view_date TEXT,
    uf TEXT,
    municipio TEXT,
    area_afetada_ha REAL,
    fire_count INTEGER,
    fire_dates TEXT,
    severity TEXT,
    ingested_at TEXT,
    UNIQUE(cod_imovel, classname, view_date)
);

CREATE TABLE IF NOT EXISTS deter_alerts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    mun_geocod TEXT,
    municipality TEXT,
    classname TEXT,
    view_date TEXT,
    area_km2 REAL,
    uf TEXT,
    ingested_at TEXT,
    UNIQUE(mun_geocod, classname, view_date)
);

CREATE TABLE IF NOT EXISTS ams_risk (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    view_date TEXT,
    viewed_at TEXT,
    satelite TEXT,
    municipio TEXT,
    biome TEXT,
    geocode TEXT,
    layer TEXT,
    risk_level TEXT,
    min_lat REAL,
    min_lon REAL,
    max_lat REAL,
    max_lon REAL,
    geom BLOB,
    ingested_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_ams_bbox ON ams_risk(min_lat, min_lon, max_lat, max_lon);

CREATE INDEX IF NOT EXISTS idx_fire_source ON fire_data(json_extract(data, '$.source'));
]]

-- ── Connection pool ──────────────────────────────────────────────────────

local pool = {}
local pool_available = {}
-- No spinlock needed - copas coroutines yield during I/O, not during pool access
-- Pool operations are atomic within a single coroutine

local function pool_acquire()
    local conn = table.remove(pool_available)
    if conn then return conn end

    -- All connections busy; create a temporary one
    local db = sqlite3.open(DB_PATH)
    db:exec("PRAGMA journal_mode=WAL")
    db:exec("PRAGMA synchronous=NORMAL")
    db:exec("PRAGMA busy_timeout=5000")
    db:exec("PRAGMA cache_size=-8000")
    db:exec("PRAGMA temp_store=MEMORY")
    db:exec("PRAGMA mmap_size=268435456")  -- leitura pesada (ex: fire_data)
    return db
end

local function pool_release(conn)
    if #pool_available < POOL_SIZE then
        pool_available[#pool_available + 1] = conn
    else
        conn:close()
    end
end

-- ── Row helper ───────────────────────────────────────────────────────────

local function fetch_all(db, sql, params)
    local stmt = db:prepare(sql)
    if not stmt then
        logger.error("SQL prepare failed: " .. tostring(db:errmsg()) .. " | SQL: " .. sql)
        return {}
    end

    if params then
        for i, p in ipairs(params) do
            if type(p) == "number" then
                stmt:bind(i, p)
            else
                stmt:bind(i, p or "")
            end
        end
    end

    local rows = {}
    for row in stmt:nrows() do
        rows[#rows + 1] = row
    end
    stmt:finalize()
    return rows
end

local function fetch_one(db, sql, params)
    local rows = fetch_all(db, sql, params)
    return rows[1]
end

local function exec_write(db, sql, params)
    local stmt = db:prepare(sql)
    if not stmt then
        logger.error("SQL prepare failed: " .. tostring(db:errmsg()) .. " | SQL: " .. sql)
        return false, db:errmsg()
    end

    if params then
        for i, p in ipairs(params) do
            if type(p) == "number" then
                stmt:bind(i, p)
            elseif type(p) == "boolean" then
                stmt:bind(i, p and 1 or 0)
            else
                stmt:bind(i, tostring(p or ""))
            end
        end
    end

    local ok, err = stmt:step()
    stmt:finalize()
    if ok ~= sqlite3.DONE then
        logger.error("SQL exec failed: " .. tostring(err or db:errmsg()) .. " | SQL: " .. sql)
        return false, err or db:errmsg()
    end
    return true
end

-- ── Date helpers ────────────────────────────────────────────────────────

-- Data ISO (UTC) de `days` dias atrás — um único lugar para a semântica de
-- cutoff em UTC (Inc 7). Substitui os 11 `os.date("!%Y-%m-%d", ...)` inline.
function _M.days_ago_iso(days)
    return os.date("!%Y-%m-%d", os.time() - (days or 0) * 86400)
end

-- ── Version check ────────────────────────────────────────────────────────

local function check_sqlite_version(db)
    local row = fetch_one(db, "SELECT sqlite_version() AS ver")
    if not row then return false end
    local ver = row.ver or row["ver"] or ""
    local major, minor = ver:match("(%d+)%.(%d+)")
    if not major then return false end
    major, minor = tonumber(major), tonumber(minor)
    local version_num = major * 10000 + minor * 100
    if version_num < 34500 then
        logger.warn("SQLite " .. ver .. " does not support JSONB (need >= 3.45.0)")
        return false
    end
    logger.info("SQLite ", ver, " — JSONB supported")
    return true
end

-- ── Init / Close ─────────────────────────────────────────────────────────

function _M.init_db()
    -- Ensure directory exists
    local dir = DB_PATH:match("^(.*)[/\\]")
    if dir then
        if package.config:sub(1, 1) == "\\" then
            os.execute('mkdir "' .. dir .. '" >NUL 2>NUL')
        else
            os.execute('mkdir -p "' .. dir .. '" >/dev/null 2>&1')
        end
    end

    -- Check for legacy schema
    local needs_migration = false
    local f = io.open(DB_PATH, "r")
    if f then
        f:close()
        local check_db = sqlite3.open(DB_PATH)
        local cols = {}
        local stmt = check_db:prepare("PRAGMA table_info(fire_data)")
        if stmt then
            for row in stmt:rows() do
                cols[row[2] or row["name"] or ""] = true
            end
            stmt:finalize()
        end
        if cols["confidence"] then
            needs_migration = true
        end
        check_db:close()
    end

    if needs_migration then
        logger.info("Legacy flat-column schema detected — rebuilding tables to JSONB...")
        _M.migrate_to_jsonb()
    end

    -- Create schema
    local db = sqlite3.open(DB_PATH)
    check_sqlite_version(db)
    db:exec(SCHEMA)

    -- Additive migration: colunas de `nature` (DB legado) + índices relacionados.
    -- (Os índices ficam fora do SCHEMA porque a coluna pode não existir ainda num
    -- DB legado — CREATE INDEX falharia durante o exec(SCHEMA).)
    local fire_cols = {}
    local stmt = db:prepare("PRAGMA table_info(fire_data)")
    if stmt then
        for row in stmt:rows() do
            fire_cols[row[2] or row["name"] or ""] = true
        end
        stmt:finalize()
    end
    if not fire_cols["nature"] then
        logger.info("Adding nature columns to fire_data (additive migration)")
        db:exec("ALTER TABLE fire_data ADD COLUMN nature TEXT")
        db:exec("ALTER TABLE fire_data ADD COLUMN nature_evidence BLOB")
        db:exec("ALTER TABLE fire_data ADD COLUMN nature_at TEXT")
        db:exec("ALTER TABLE fire_data ADD COLUMN nature_version INTEGER DEFAULT 0")
    end
    db:exec("CREATE INDEX IF NOT EXISTS idx_fire_nature ON fire_data(nature, nature_version)")
    db:exec("CREATE INDEX IF NOT EXISTS idx_fire_acqdate_nature ON fire_data(acq_date, nature)")

    -- Additive: deter_alerts.municipality (plan: terrabrasilis-integration,
    -- Inc 2 — needed by by_municipality stats; tables may predate the column).
    local det_cols = {}
    local dstmt = db:prepare("PRAGMA table_info(deter_alerts)")
    if dstmt then
        for row in dstmt:rows() do
            det_cols[row[2] or row["name"] or ""] = true
        end
        dstmt:finalize()
    end
    if not det_cols["municipality"] then
        logger.info("Adding municipality column to deter_alerts (additive migration)")
        db:exec("ALTER TABLE deter_alerts ADD COLUMN municipality TEXT")
    end

    -- View_date indexes for the alert/AMS windowed queries (Inc 7).
    db:exec("CREATE INDEX IF NOT EXISTS idx_deter_alerts_view_date ON deter_alerts(view_date)")
    db:exec("CREATE INDEX IF NOT EXISTS idx_deter_car_alerts_view_date ON deter_car_alerts(view_date)")
    db:exec("CREATE INDEX IF NOT EXISTS idx_ams_risk_view_date ON ams_risk(view_date)")

    db:close()

    -- Build pool
    for _ = 1, POOL_SIZE do
        local conn = sqlite3.open(DB_PATH)
        conn:exec("PRAGMA journal_mode=WAL")
        conn:exec("PRAGMA synchronous=NORMAL")
        conn:exec("PRAGMA busy_timeout=5000")
        conn:exec("PRAGMA cache_size=-8000")
        conn:exec("PRAGMA temp_store=MEMORY")
        conn:exec("PRAGMA mmap_size=268435456")
        pool_available[#pool_available + 1] = conn
    end

    _M.optimize_db()

    logger.info("SQLite initialized at ", DB_PATH, " (JSONB schema, ", POOL_SIZE, " connections)")
end

function _M.optimize_db()
    local db = sqlite3.open(DB_PATH)
    db:exec("PRAGMA optimize")
    db:close()
end

-- Caminho do arquivo SQLite (usado por ingest.lua para backup PRODES_FORCE_UPDATE).
function _M.path()
    return DB_PATH
end

-- Remove TODAS as linhas de deforestation_data (PRODES_FORCE_UPDATE re-ingest).
-- Retorna true em sucesso; false se o DELETE falhar (DB travado) após 3 tentativas.
function _M.truncate_deforestation()
    local db_path = DB_PATH
    for attempt = 1, 3 do
        local db = sqlite3.open(db_path)
        db:exec("PRAGMA busy_timeout=15000")
        local rc = db:exec("DELETE FROM deforestation_data")
        db:exec("PRAGMA wal_checkpoint(TRUNCATE)")
        db:close()
        if rc == sqlite3.OK then
            return true
        end
    end
    return false
end

function _M.close_db()
    for _, conn in ipairs(pool_available) do
        conn:close()
    end
    pool_available = {}
end

-- ── Fire data ────────────────────────────────────────────────────────────

function _M.bulk_upsert_fires(docs)
    if not docs or #docs == 0 then return 0 end

    local db = pool_acquire()
    db:exec("BEGIN")

    local sql = [[
        INSERT INTO fire_data (lat, lon, acq_date, ingested_at, data)
        VALUES (?, ?, ?, ?, jsonb(?))
        ON CONFLICT(lat, lon, acq_date) DO UPDATE SET
            ingested_at=excluded.ingested_at,
            data=jsonb(excluded.data)
    ]]

    for _, d in ipairs(docs) do
        local data_json = utils.encode_jsonb({
            confidence = d.confidence,
            acq_time = d.acq_time,
            satellite = d.satellite,
            bright_ti4 = d.bright_ti4,
            source = d.source,
            state = d.state,
            fire_type = d.fire_type,
            frp = d.frp,
            daynight = d.daynight,
        })
        exec_write(db, sql, {
            d.lat, d.lon, d.acq_date, d.ingested_at, data_json
        })
    end

    db:exec("COMMIT")
    pool_release(db)
    return #docs
end

-- Como bulk_upsert_fires, mas ON CONFLICT DO NOTHING — usado pelo BdQueimadas
-- (plan: terrabrasilis-integration, Inc 10): quando o FIRMS já tem o mesmo foco
-- (lat,lon,acq_date), mantém o FIRMS (maior confiança); o BDQ só preenche gaps.
function _M.bulk_upsert_fires_keep_first(docs)
    if not docs or #docs == 0 then return 0 end

    local db = pool_acquire()
    db:exec("BEGIN")

    local sql = [[
        INSERT INTO fire_data (lat, lon, acq_date, ingested_at, data)
        VALUES (?, ?, ?, ?, jsonb(?))
        ON CONFLICT(lat, lon, acq_date) DO NOTHING
    ]]

    for _, d in ipairs(docs) do
        local data_json = utils.encode_jsonb({
            confidence = d.confidence,
            acq_time = d.acq_time,
            satellite = d.satellite,
            bright_ti4 = d.bright_ti4,
            source = d.source,
            state = d.state,
            fire_type = d.fire_type,
            frp = d.frp,
            daynight = d.daynight,
        })
        exec_write(db, sql, {
            d.lat, d.lon, d.acq_date, d.ingested_at, data_json
        })
    end

    db:exec("COMMIT")
    pool_release(db)
    return #docs
end

local function rows_to_fires(rows)
    local result = {}
    for _, r in ipairs(rows) do
        local d = utils.decode_jsonb(r.data_json or r["data_json"])
        result[#result + 1] = {
            lat = r.lat or r["lat"],
            lon = r.lon or r["lon"],
            confidence = d.confidence,
            acq_date = r.acq_date or r["acq_date"],
            acq_time = d.acq_time,
            satellite = d.satellite,
            bright_ti4 = d.bright_ti4,
            fire_type = d.fire_type,
            frp = d.frp,
            daynight = d.daynight,
            source = d.source,  -- Inc 10: origem (FIRMS / BdQueimadas)
            nature = r.nature or r["nature"],
            -- Sinaflor (plan: sinaflor-fogo-permitido): expõe a evidência da
            -- classificação (ex: authorization {nro,modo}) e a versão da regra
            -- p/ o frontend mostrar a autorização no popup. nature_evidence é
            -- JSONB binário → json() devolve texto; NULL → nil (nil-safe).
            nature_evidence = r.nature_evidence_json
                and utils.decode_jsonb(r.nature_evidence_json) or nil,
            nature_version = r.nature_version ~= nil
                and tonumber(r.nature_version) or nil,
        }
    end
    return result
end

-- Foco é atribuível a um estado brasileiro? Pontos fora do Brasil ficam com
-- `state` NULL (ingest) ou `""` (backfill legado) — ambos fora do filtro.
local function is_brazil_filter_sql()
    return "json_extract(data, '$.state') IS NOT NULL AND json_extract(data, '$.state') != ''"
end

function _M.find_fires(sw_lat, ne_lat, sw_lng, ne_lng, limit, brazil_only, source)
    limit = limit or 10000
    local db = pool_acquire()

    local sql = [[
        SELECT lat, lon, acq_date, ingested_at, nature, nature_at,
               json(nature_evidence) AS nature_evidence_json, nature_version,
               json(data) AS data_json
        FROM fire_data
        WHERE lat >= ? AND lat <= ? AND lon >= ? AND lon <= ?
    ]]
    local params = {sw_lat, ne_lat, sw_lng, ne_lng}
    if brazil_only then
        sql = sql .. "\n          AND " .. is_brazil_filter_sql()
    end
    -- Filtro opcional de fonte (Inc 10): ex. "%BDQ%" ou "NASA_FIRMS%"
    if source then
        sql = sql .. "\n          AND json_extract(data, '$.source') LIKE ?"
        params[#params + 1] = source
    end
    sql = sql .. [[
        ORDER BY acq_date DESC, lat, lon
        LIMIT ?
    ]]
    params[#params + 1] = limit

    local rows = fetch_all(db, sql, params)
    pool_release(db)
    return rows_to_fires(rows)
end

-- Same as find_fires but restricts to fires whose acq_date falls within the
-- last `days` days, so a heavy classification loop only sees relevant rows
-- instead of up to 50k historical ones.
function _M.find_fires_since(days, sw_lat, ne_lat, sw_lng, ne_lng, limit, brazil_only)
    limit = limit or 50000
    local cutoff = _M.days_ago_iso(days or 7)
    local db = pool_acquire()

    local sql = [[
        SELECT lat, lon, acq_date, ingested_at, nature, nature_at,
               json(nature_evidence) AS nature_evidence_json, nature_version,
               json(data) AS data_json
        FROM fire_data
        WHERE lat >= ? AND lat <= ? AND lon >= ? AND lon <= ?
          AND acq_date >= ?
    ]]
    local params = {sw_lat, ne_lat, sw_lng, ne_lng, cutoff}
    if brazil_only then
        sql = sql .. "\n          AND " .. is_brazil_filter_sql()
    end
    sql = sql .. [[
        ORDER BY acq_date DESC, lat, lon
        LIMIT ?
    ]]
    params[#params + 1] = limit

    local rows = fetch_all(db, sql, params)
    pool_release(db)
    return rows_to_fires(rows)
end

function _M.prune_old_fires(days)
    days = days or 90
    local cutoff = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - days * 86400)
    local db = pool_acquire()

    db:exec("BEGIN")
    local sql = "DELETE FROM fire_data WHERE ingested_at < ?"
    exec_write(db, sql, {cutoff})
    local count = db:changes()
    db:exec("COMMIT")
    pool_release(db)
    return count
end

function _M.get_fires_timeseries(days, state)
    days = tonumber(days) or 30
    local db = pool_acquire()
    local cutoff = "-" .. tostring(days) .. " days"

    local sql, params
    if state and state ~= "" then
        sql = [[
            SELECT acq_date AS date, COUNT(*) AS count
            FROM fire_data
            WHERE acq_date IS NOT NULL
              AND acq_date >= date('now', ?)
              AND json_extract(data, '$.state') = ?
            GROUP BY acq_date
            ORDER BY acq_date
        ]]
        params = {cutoff, state}
    else
        sql = [[
            SELECT acq_date AS date, COUNT(*) AS count
            FROM fire_data
            WHERE acq_date IS NOT NULL AND acq_date >= date('now', ?)
            GROUP BY acq_date
            ORDER BY acq_date
        ]]
        params = {cutoff}
    end

    local rows = fetch_all(db, sql, params)
    pool_release(db)

    local result = {}
    for _, r in ipairs(rows) do
        result[#result + 1] = {
            date = r.date or r["date"],
            count = tonumber(r.count or r["count"] or 0) or 0,
        }
    end
    return result
end

function _M.get_fires_by_state(limit, days)
    limit = tonumber(limit) or 10
    days = tonumber(days)
    local db = pool_acquire()

    local sql, params
    if days and days > 0 then
        sql = [[
            SELECT json_extract(data, '$.state') AS state, COUNT(*) AS count
            FROM fire_data
            WHERE json_extract(data, '$.state') IS NOT NULL AND json_extract(data, '$.state') != ''
              AND acq_date IS NOT NULL AND acq_date >= date('now', ?)
            GROUP BY state
            ORDER BY count DESC
            LIMIT ?
        ]]
        params = {"-" .. tostring(days) .. " days", limit}
    else
        sql = [[
            SELECT json_extract(data, '$.state') AS state, COUNT(*) AS count
            FROM fire_data
            WHERE json_extract(data, '$.state') IS NOT NULL AND json_extract(data, '$.state') != ''
            GROUP BY state
            ORDER BY count DESC
            LIMIT ?
        ]]
        params = {limit}
    end

    local rows = fetch_all(db, sql, params)
    pool_release(db)

    local result = {}
    for _, r in ipairs(rows) do
        local state_code = r.state or r["state"]
        if state_code and state_code ~= "" then
            result[#result + 1] = {
                state = state_code,
                count = tonumber(r.count or r["count"] or 0) or 0,
            }
        end
    end
    return result
end

function _M.count_fires_by_state_present()
    local db = pool_acquire()
    local row = fetch_one(db, [[
        SELECT
            COUNT(*) AS total,
            SUM(CASE WHEN json_extract(data, '$.state') IS NULL THEN 1 ELSE 0 END) AS unattributed,
            SUM(CASE WHEN json_extract(data, '$.state') = '' THEN 1 ELSE 0 END) AS sentinel_empty,
            SUM(CASE WHEN json_extract(data, '$.state_retry') IS NOT NULL THEN 1 ELSE 0 END) AS retried
        FROM fire_data
    ]])
    pool_release(db)
    return {
        total = row and tonumber(row.total or row["total"] or 0) or 0,
        unattributed = row and tonumber(row.unattributed or row["unattributed"] or 0) or 0,
        sentinel_empty = row and tonumber(row.sentinel_empty or row["sentinel_empty"] or 0) or 0,
        retried = row and tonumber(row.retried or row["retried"] or 0) or 0,
    }
end

function _M.get_fires_state_sparklines(days)
    days = tonumber(days) or 7
    local db = pool_acquire()
    local cutoff = "-" .. tostring(days) .. " days"
    local sql = [[
        SELECT json_extract(data, '$.state') AS state, acq_date, COUNT(*) AS count
        FROM fire_data
        WHERE json_extract(data, '$.state') IS NOT NULL AND json_extract(data, '$.state') != ''
          AND acq_date IS NOT NULL AND acq_date >= date('now', ?)
        GROUP BY state, acq_date
        ORDER BY state, acq_date
    ]]
    local rows = fetch_all(db, sql, {cutoff})
    pool_release(db)

    local result = {}
    for _, r in ipairs(rows) do
        local st = r.state or r["state"] or ""
        if st ~= "" then
            if not result[st] then result[st] = {} end
            table.insert(result[st], {
                date = r.acq_date or r["acq_date"],
                count = tonumber(r.count or r["count"] or 0) or 0,
            })
        end
    end
    return result
end

function _M.iter_fires_for_backfill(batch_size)
    batch_size = batch_size or 1000
    local db = pool_acquire()
    local sql = [[
        SELECT id, lat, lon
        FROM fire_data
        WHERE json_extract(data, '$.state') IS NULL
        LIMIT ?
    ]]
    local rows = fetch_all(db, sql, {batch_size})
    pool_release(db)
    local result = {}
    for _, r in ipairs(rows) do
        result[#result + 1] = {
            id = tonumber(r.id or r["id"]),
            lat = tonumber(r.lat or r["lat"]),
            lon = tonumber(r.lon or r["lon"]),
        }
    end
    return result
end

function _M.update_fire_state(id, state)
    local db = pool_acquire()
    local ok, err = pcall(function()
        db:exec("BEGIN")
        local row = fetch_one(db, "SELECT json(data) AS data_json FROM fire_data WHERE id = ?", {id})
        if row then
            local raw = row.data_json or row["data_json"]
            local current = utils.decode_jsonb(raw)
            -- Bail on corrupt JSON: empty decode of non-empty source means we'd overwrite all fields.
            if type(current) ~= "table" or (next(current) == nil and raw and raw ~= "" and raw ~= "{}") then
                db:exec("ROLLBACK")
                return
            end
            current.state = state
            local data_json = utils.encode_jsonb(current)
            exec_write(db, "UPDATE fire_data SET data = jsonb(?) WHERE id = ?", {data_json, id})
        end
        db:exec("COMMIT")
    end)
    if not ok then
        pcall(function() db:exec("ROLLBACK") end)
        pool_release(db)
        error(err)
    end
    pool_release(db)
end

-- ── State attribution repair (plan: dashboard-enhancement, Inc 2) ────────
--
-- O backfill legado gravou state='' (sentinel) para focos que o
-- point-in-polygon não conseguiu classificar — inclusive quando o layer de
-- estados estava VAZIO (40% dos focos em prod ficaram com ''). Corrigir exige
-- revisitar essas linhas, mas sem re-scanear para sempre os pontos que são
-- genuinamente não-classificáveis (oceano). O marcador `state_retry` separa
-- os dois casos: gravado quando o ponto foi reprocessado e continua sem UF.

-- Lote de focos com sentinel '' que ainda não foram reprocessados.
function _M.iter_fires_for_state_retry(batch_size)
    batch_size = batch_size or 500
    local db = pool_acquire()
    local rows = fetch_all(db, [[
        SELECT id, lat, lon
        FROM fire_data
        WHERE json_extract(data, '$.state') = ''
          AND json_extract(data, '$.state_retry') IS NULL
        LIMIT ?
    ]], {batch_size})
    pool_release(db)
    local result = {}
    for _, r in ipairs(rows) do
        result[#result + 1] = {
            id = tonumber(r.id or r["id"]),
            lat = tonumber(r.lat or r["lat"]),
            lon = tonumber(r.lon or r["lon"]),
        }
    end
    return result
end

-- Marca um foco como reprocessado e não-classificável: mantém state='' (para
-- consumidores verem que foi tentado) e grava state_retry para o loop nunca
-- mais re-scanear a linha. Se o layer de estados for corrigido depois, um
-- reset do marcador recupera a linha.
function _M.mark_fire_state_unattributable(id)
    local db = pool_acquire()
    local ok, err = pcall(function()
        db:exec("BEGIN")
        local row = fetch_one(db, "SELECT json(data) AS data_json FROM fire_data WHERE id = ?", {id})
        if row then
            local current = utils.decode_jsonb(row.data_json or row["data_json"])
            if type(current) ~= "table" or (next(current) == nil and row.data_json and row.data_json ~= "" and row.data_json ~= "{}") then
                db:exec("ROLLBACK")
                return
            end
            current.state = ""
            current.state_retry = utils.now_iso()
            local data_json = utils.encode_jsonb(current)
            exec_write(db, "UPDATE fire_data SET data = jsonb(?) WHERE id = ?", {data_json, id})
        end
        db:exec("COMMIT")
    end)
    if not ok then
        pcall(function() db:exec("ROLLBACK") end)
        pool_release(db)
        error(err)
    end
    pool_release(db)
end

-- ── Biome attribution (plan: dashboard-enhancement, Inc 4) ───────────────
--
-- O card de biomas precisa filtrar por dias/estado via SQL — hoje /api/biomes
-- faz point-in-polygon sobre ≤10k focos e não aceita params. Persistimos o
-- bioma em $.biome (mesmo padrão do backfill de state, com marcador
-- biome_retry para não re-scanear pontos não-classificáveis).

-- Aplica campos ao JSONB de um foco num único UPDATE transacional.
local function patch_fire_jsonb(id, fields)
    local db = pool_acquire()
    local ok, err = pcall(function()
        db:exec("BEGIN")
        local row = fetch_one(db, "SELECT json(data) AS data_json FROM fire_data WHERE id = ?", {id})
        if row then
            local current = utils.decode_jsonb(row.data_json or row["data_json"])
            if type(current) ~= "table" or (next(current) == nil and row.data_json and row.data_json ~= "" and row.data_json ~= "{}") then
                db:exec("ROLLBACK")
                return
            end
            for k, v in pairs(fields) do current[k] = v end
            local data_json = utils.encode_jsonb(current)
            exec_write(db, "UPDATE fire_data SET data = jsonb(?) WHERE id = ?", {data_json, id})
        end
        db:exec("COMMIT")
    end)
    if not ok then
        pcall(function() db:exec("ROLLBACK") end)
        pool_release(db)
        error(err)
    end
    pool_release(db)
end

function _M.update_fire_biome(id, name)
    patch_fire_jsonb(id, { biome = name })
end

function _M.mark_fire_biome_unattributable(id)
    patch_fire_jsonb(id, { biome = "", biome_retry = utils.now_iso() })
end

-- Lote de focos sem bioma (e sem biome_retry) para o backfill.
function _M.iter_fires_for_biome_backfill(batch_size)
    batch_size = batch_size or 500
    local db = pool_acquire()
    local rows = fetch_all(db, [[
        SELECT id, lat, lon
        FROM fire_data
        WHERE json_extract(data, '$.biome') IS NULL
          AND json_extract(data, '$.biome_retry') IS NULL
        LIMIT ?
    ]], {batch_size})
    pool_release(db)
    local result = {}
    for _, r in ipairs(rows) do
        result[#result + 1] = {
            id = tonumber(r.id or r["id"]),
            lat = tonumber(r.lat or r["lat"]),
            lon = tonumber(r.lon or r["lon"]),
        }
    end
    return result
end

-- Contagem por bioma num período (e estado opcional). A % é sobre o total de
-- focos COM bioma atribuído (honesta quanto à cobertura). Retorna (result, total).
function _M.get_fires_by_biome(days, state)
    days = tonumber(days) or 30
    local cutoff = _M.days_ago_iso(days)
    local db = pool_acquire()
    local params = {cutoff}
    local state_sql = ""
    if state and state ~= "" then
        state_sql = " AND json_extract(data, '$.state') = ?"
        params[#params + 1] = state
    end
    local rows = fetch_all(db, [[
        SELECT json_extract(data, '$.biome') AS biome, COUNT(*) AS cnt
        FROM fire_data
        WHERE acq_date IS NOT NULL AND acq_date >= ?
          AND json_extract(data, '$.biome') IS NOT NULL
          AND json_extract(data, '$.biome') != ''
    ]] .. state_sql .. [[
        GROUP BY biome ORDER BY cnt DESC
    ]], params)
    pool_release(db)

    local result = {}
    local total = 0
    for _, r in ipairs(rows) do
        local b = r.biome or r["biome"]
        local cnt = tonumber(r.cnt or r["cnt"]) or 0
        if b and b ~= "" then
            result[#result + 1] = { name = b, count = cnt }
            total = total + cnt
        end
    end
    for _, rec in ipairs(result) do
        rec.pct = total > 0 and (math.floor(rec.count / total * 1000 + 0.5) / 10) or 0
    end
    return result, total
end

-- Cobertura de atribuição de bioma (para o painel de freshness).
function _M.count_fires_by_biome_present()
    local db = pool_acquire()
    local row = fetch_one(db, [[
        SELECT COUNT(*) AS total,
               SUM(CASE WHEN json_extract(data, '$.biome') IS NULL OR json_extract(data, '$.biome') = '' THEN 1 ELSE 0 END) AS unattributed
        FROM fire_data
    ]])
    pool_release(db)
    return {
        total = row and tonumber(row.total or row["total"] or 0) or 0,
        unattributed = row and tonumber(row.unattributed or row["unattributed"] or 0) or 0,
    }
end

-- Cobertura de classificação de natureza (painel de freshness).
function _M.count_fires_by_nature_present()
    local db = pool_acquire()
    local row = fetch_one(db, [[
        SELECT COUNT(*) AS total,
               SUM(CASE WHEN nature IS NULL THEN 1 ELSE 0 END) AS unclassified
        FROM fire_data
    ]])
    pool_release(db)
    return {
        total = row and tonumber(row.total or row["total"] or 0) or 0,
        unclassified = row and tonumber(row.unclassified or row["unclassified"] or 0) or 0,
    }
end

-- Freshness por fonte: última ingestão (MAX ingested_at) + nº de linhas.
-- Chaves de resposta = ids de fonte (firms/news/deter/deter_car/ams).
function _M.get_ingest_freshness()
    local db = pool_acquire()
    local source_map = {
        fire_data = "firms",
        news = "news",
        deter_polygons = "deter",
        deter_car_alerts = "deter_car",
        ams_risk = "ams",
    }
    local res = {}
    for tbl, id in pairs(source_map) do
        local row = fetch_one(db, "SELECT COUNT(*) AS c, MAX(ingested_at) AS m FROM " .. tbl)
        res[id] = {
            rows = row and tonumber(row.c or row["c"]) or 0,
            last_ingested_at = row and (row.m or row["m"]) or nil,
        }
    end
    pool_release(db)
    return res
end

-- ── Fire nature classification ───────────────────────────────────────────

-- Batch update de nature/evidence/version numa transação. `version` é
-- EXATAMENTE o min_version usado para selecionar as linhas (rotina=0;
-- reclassify=NATURE_VERSION) — ver iter_fires_for_classification.
function _M.update_fire_natures(rows, version)
    if not rows or #rows == 0 then return 0 end
    version = tonumber(version) or 0
    local db = pool_acquire()
    db:exec("BEGIN")
    for _, r in ipairs(rows) do
        local evidence_json = r.evidence and utils.encode_jsonb(r.evidence) or "{}"
        exec_write(db, [[
            UPDATE fire_data SET nature=?, nature_evidence=jsonb(?), nature_at=?, nature_version=? WHERE id=?
        ]], {r.nature, evidence_json, r.at, version, r.id})
    end
    db:exec("COMMIT")
    pool_release(db)
    return #rows
end

-- Lote de focos a classificar. min_version:
--   0 (rotina / fast path) → só nature IS NULL (nature_version >= 0 nunca < 0)
--   NATURE_VERSION (reclassify pós-CAR/moratória) → nature_version < min_version + NULLs
function _M.iter_fires_for_classification(batch_size, min_version)
    batch_size = batch_size or 500
    min_version = tonumber(min_version) or 0
    local db = pool_acquire()
    local sql = [[
        SELECT id, lat, lon, acq_date,
               json_extract(data, '$.state') AS state,
               json_extract(data, '$.confidence') AS confidence,
               json_extract(data, '$.bright_ti4') AS bright_ti4,
               json_extract(data, '$.fire_type') AS fire_type
        FROM fire_data
        WHERE (nature IS NULL OR nature_version < ?) AND acq_date IS NOT NULL
        ORDER BY id
        LIMIT ?
    ]]
    local rows = fetch_all(db, sql, {min_version, batch_size})
    pool_release(db)

    local result = {}
    for _, r in ipairs(rows) do
        result[#result + 1] = {
            id = tonumber(r.id or r["id"]),
            lat = tonumber(r.lat or r["lat"]),
            lon = tonumber(r.lon or r["lon"]),
            acq_date = r.acq_date or r["acq_date"],
            state = r.state or r["state"] or "",
            confidence = r.confidence or r["confidence"],
            bright_ti4 = tonumber(r.bright_ti4 or r["bright_ti4"]),
            fire_type = r.fire_type or r["fire_type"],
        }
    end
    return result
end

-- Focos recentes (por data), paginados por id — usado pelo enriquecimento
-- FIRMS×DETER (plan: terrabrasilis-integration, Inc 4), que reprocessa todos
-- os focos da janela (não só não-classificados).
function _M.iter_fires_recent(days, batch_size, min_id)
    days = days or 7
    batch_size = batch_size or 500
    min_id = tonumber(min_id) or 0
    local cutoff = _M.days_ago_iso(days)
    local db = pool_acquire()
    local sql = [[
        SELECT id, lat, lon, acq_date,
               json_extract(data, '$.state') AS state,
               json_extract(data, '$.confidence') AS confidence,
               json_extract(data, '$.bright_ti4') AS bright_ti4,
               json_extract(data, '$.fire_type') AS fire_type
        FROM fire_data
        WHERE acq_date >= ? AND acq_date IS NOT NULL AND id > ?
        ORDER BY id
        LIMIT ?
    ]]
    local rows = fetch_all(db, sql, {cutoff, min_id, batch_size})
    pool_release(db)

    local result = {}
    for _, r in ipairs(rows) do
        result[#result + 1] = {
            id = tonumber(r.id or r["id"]),
            lat = tonumber(r.lat or r["lat"]),
            lon = tonumber(r.lon or r["lon"]),
            acq_date = r.acq_date or r["acq_date"],
            state = r.state or r["state"] or "",
            confidence = r.confidence or r["confidence"],
            bright_ti4 = tonumber(r.bright_ti4 or r["bright_ti4"]),
            fire_type = r.fire_type or r["fire_type"],
        }
    end
    return result
end

-- Há focos não-classificados? (cheap: LIMIT 1 sobre índice em nature)
function _M.count_unclassified()
    local db = pool_acquire()
    local row = fetch_one(db, "SELECT 1 AS found FROM fire_data WHERE nature IS NULL LIMIT 1")
    pool_release(db)
    return row ~= nil
end

-- Distribuição por natureza (nacional ou por estado), num período de dias.
-- Retorna (classes, total) — classes inclui 'unclassified' p/ nature NULL.
function _M.count_fires_by_nature(days, state)
    days = days or 7
    local cutoff = _M.days_ago_iso(days)
    local params = {cutoff}
    local sql = [[
        SELECT COALESCE(nature, 'unclassified') AS nature, COUNT(*) AS cnt
        FROM fire_data
        WHERE acq_date >= ?
    ]]
    if state and state ~= "" then
        sql = sql .. " AND json_extract(data, '$.state') = ?"
        params[#params + 1] = state
    end
    sql = sql .. " GROUP BY COALESCE(nature, 'unclassified')"

    local db = pool_acquire()
    local rows = fetch_all(db, sql, params)
    pool_release(db)

    local classes = {crime = 0, suspeito = 0, permitido = 0, natural = 0, unclassified = 0}
    local total = 0
    for _, r in ipairs(rows) do
        local n = tonumber(r.cnt or r["cnt"]) or 0
        local key = r.nature or r["nature"] or "unclassified"
        classes[key] = (classes[key] or 0) + n
        total = total + n
    end
    return classes, total
end

-- Distribuição por estado × natureza (ordenada por total desc).
function _M.count_fires_by_nature_by_state(days)
    days = days or 7
    local cutoff = _M.days_ago_iso(days)
    local db = pool_acquire()
    local sql = [[
        SELECT COALESCE(json_extract(data, '$.state'), '') AS st,
               COALESCE(nature, 'unclassified') AS nature,
               COUNT(*) AS cnt
        FROM fire_data
        WHERE acq_date >= ?
        GROUP BY COALESCE(json_extract(data, '$.state'), ''), COALESCE(nature, 'unclassified')
    ]]
    local rows = fetch_all(db, sql, {cutoff})
    pool_release(db)

    local by_state = {}
    for _, r in ipairs(rows) do
        local st = r.st or r["st"] or ""
        local nature = r.nature or r["nature"] or "unclassified"
        local n = tonumber(r.cnt or r["cnt"]) or 0
        local rec = by_state[st]
        if not rec then
            rec = {state = st, total = 0, crime = 0, suspeito = 0, permitido = 0, natural = 0, unclassified = 0}
            by_state[st] = rec
        end
        rec[nature] = (rec[nature] or 0) + n
        rec.total = rec.total + n
    end

    local list = {}
    for _, rec in pairs(by_state) do list[#list + 1] = rec end
    table.sort(list, function(a, b) return a.total > b.total end)
    return list
end

-- ── Dashboard aggregates (plan: dashboard-enhancement, Inc 3) ────────────
--
-- KPIs período-a-período numa única varredura: janela atual vs anterior são
-- separadas por um CASE WHEN no acq_date (sem overlap — o dia pivô pertence à
-- janela atual). Um scan só, usando idx_fire_acqdate_nature (acq_date, nature).

-- Contagens atuais e anteriores (total + por classe de natureza).
-- Retorna { fires={current,previous}, crime={...}, suspeito={...},
--           permitido={...}, natural={...}, unclassified={...} }.
function _M.get_dashboard_kpis(days, state)
    days = tonumber(days) or 30
    local cur_start = _M.days_ago_iso(days - 1)
    local prev_start = _M.days_ago_iso(days * 2 - 1)
    local db = pool_acquire()
    local params = {cur_start, prev_start}
    local state_sql = ""
    if state and state ~= "" then
        state_sql = " AND json_extract(data, '$.state') = ?"
        params[#params + 1] = state
    end

    local rows = fetch_all(db, [[
        SELECT
            CASE WHEN acq_date >= ? THEN 'current' ELSE 'previous' END AS period,
            COALESCE(nature, 'unclassified') AS nature,
            COUNT(*) AS cnt
        FROM fire_data
        WHERE acq_date IS NOT NULL AND acq_date >= ?
    ]] .. state_sql .. [[
        GROUP BY period, nature
    ]], params)
    pool_release(db)

    local res = {
        fires = {current = 0, previous = 0},
        crime = {current = 0, previous = 0},
        suspeito = {current = 0, previous = 0},
        permitido = {current = 0, previous = 0},
        natural = {current = 0, previous = 0},
        unclassified = {current = 0, previous = 0},
    }
    for _, r in ipairs(rows) do
        local period = r.period or r["period"]
        local nature = r.nature or r["nature"] or "unclassified"
        local cnt = tonumber(r.cnt or r["cnt"]) or 0
        if res[nature] and res[nature][period] ~= nil then
            res[nature][period] = res[nature][period] + cnt
        end
        res.fires[period] = res.fires[period] + cnt
    end
    return res
end

-- Dias distintos com fogo em cada janela — usado para o flag `complete` do
-- summary (janela com cobertura curta = dados parciais → delta não confiável).
function _M.count_distinct_fire_days(days, state)
    days = tonumber(days) or 30
    local cur_start = _M.days_ago_iso(days - 1)
    local prev_start = _M.days_ago_iso(days * 2 - 1)
    local db = pool_acquire()
    local params = {cur_start, prev_start}
    local state_sql = ""
    if state and state ~= "" then
        state_sql = " AND json_extract(data, '$.state') = ?"
        params[#params + 1] = state
    end

    local rows = fetch_all(db, [[
        SELECT
            CASE WHEN acq_date >= ? THEN 'current' ELSE 'previous' END AS period,
            COUNT(DISTINCT acq_date) AS days
        FROM fire_data
        WHERE acq_date IS NOT NULL AND acq_date >= ?
    ]] .. state_sql .. [[
        GROUP BY period
    ]], params)
    pool_release(db)

    local res = {current = 0, previous = 0}
    for _, r in ipairs(rows) do
        res[r.period or r["period"]] = tonumber(r.days or r["days"]) or 0
    end
    return res
end

-- Soma de área DETER (km²) numa janela deslocada: [today-(offset+days-1),
-- today-(offset-1)). current = offset 0; previous = offset = days.
function _M.get_deter_total_window(days, offset_days)
    days = tonumber(days) or 30
    offset_days = tonumber(offset_days) or 0
    local start = _M.days_ago_iso(offset_days + days - 1)
    local finish = _M.days_ago_iso(offset_days - 1)
    local db = pool_acquire()
    local row = fetch_one(db, [[
        SELECT COALESCE(SUM(area_km2), 0) AS s FROM deter_polygons
        WHERE view_date >= ? AND view_date < ?
    ]], {start, finish})
    pool_release(db)
    return tonumber(row and (row.s or row["s"])) or 0
end

-- ── Deforestation data ───────────────────────────────────────────────────

function _M.bulk_upsert_deforestation(docs)
    if not docs or #docs == 0 then return 0 end

    local db = pool_acquire()
    db:exec("BEGIN")

    local sql = [[
        INSERT INTO deforestation_data (lat, lon, data)
        VALUES (?, ?, jsonb(?))
        ON CONFLICT DO NOTHING
    ]]

    for _, d in ipairs(docs) do
        local data_json = utils.encode_jsonb({
            name = d.name,
            clazz = d.clazz or "Desmatamento",
            periods = d.periods or "N/A",
            source = d.source or "TerraBrasilis",
            color = d.color,
            timestamp = d.timestamp,
        })
        exec_write(db, sql, {d.lat, d.lon, data_json})
    end

    db:exec("COMMIT")
    pool_release(db)
    return #docs
end

function _M.find_deforestation(sw_lat, ne_lat, sw_lng, ne_lng, limit)
    limit = limit or 10000
    local db = pool_acquire()

    local sql = [[
        SELECT lat, lon, json(data) AS data_json
        FROM deforestation_data
        WHERE lat >= ? AND lat <= ? AND lon >= ? AND lon <= ?
        ORDER BY rowid
        LIMIT ?
    ]]

    local rows = fetch_all(db, sql, {sw_lat, ne_lat, sw_lng, ne_lng, limit})
    pool_release(db)

    local result = {}
    for _, r in ipairs(rows) do
        local d = utils.decode_jsonb(r.data_json or r["data_json"])
        result[#result + 1] = {
            name = d.name,
            clazz = d.clazz or "Desmatamento",
            periods = d.periods or "N/A",
            source = d.source or "TerraBrasilis",
            color = d.color,
            lat = r.lat or r["lat"],
            lon = r.lon or r["lon"],
            timestamp = d.timestamp,
        }
    end
    return result
end

-- Parseia o rótulo PRODES do campo `data.name` (legenda QML). Rótulos reais
-- têm prefixo de contagem (`"7 d2007"`, `"64 r2024"`); aceita também rótulo
-- sem prefixo (`"d2007"`). Casa `[dr]` + 4 dígitos em QUALQUER posição do
-- rótulo — não ancorado em início/fim (Inc 1: o regex âncora
-- `^([dr])(%d%d%d%d)$` nunca casava com labels com prefixo → type/year nil).
-- Retorna `type` ("d"|"r") e `year` (string), ou `nil` se não houver match.
local function parse_prodes_label(name)
    if type(name) ~= "string" then return nil end
    local t, yyyy = name:match("([dr])(%d%d%d%d)")
    if not t then return nil end
    return t, yyyy
end

-- PRODES points dentro de um bbox, com class/year decodificados do campo
-- `data.name` (rótulo da legenda QML, ex. `d2020`/`r2014` — não há coluna
-- estruturada de ano/classe). Usado pela verificação PRODES por recibo CAR
-- (plan: terrabrasilis-integration, Inc 12) e pelo crossing fogo×vegetação.
-- type = "deforestation" (classe d*) | "regrowth" (classe r*).
function _M.get_deforestation_in_bbox(sw_lat, ne_lat, sw_lng, ne_lng, limit)
    limit = limit or 50000
    local db = pool_acquire()

    local sql = [[
        SELECT lat, lon, json(data) AS data_json
        FROM deforestation_data
        WHERE lat >= ? AND lat <= ? AND lon >= ? AND lon <= ?
        ORDER BY rowid
        LIMIT ?
    ]]

    local rows = fetch_all(db, sql, {sw_lat, ne_lat, sw_lng, ne_lng, limit})
    pool_release(db)

    local result = {}
    for _, r in ipairs(rows) do
        local d = utils.decode_jsonb(r.data_json or r["data_json"])
        local class_name, year, kind = nil, nil, nil
        if type(d.name) == "string" then
            local t, yyyy = parse_prodes_label(d.name)
            if t then
                class_name = d.name
                year = tonumber(yyyy)
                kind = (t == "d") and "deforestation" or "regrowth"
            end
        end
        result[#result + 1] = {
            lat = r.lat or r["lat"],
            lon = r.lon or r["lon"],
            class_name = class_name,
            year = year,
            type = kind,
        }
    end
    return result
end

-- ── Fire × vegetation context (plan: terrabrasilis-integration, Inc 8) ──

-- ~30m em graus (resolução do pixel PRODES) — a checagem de proximidade.
local VEG_PAD = 0.0003

-- Grid de células ~0.001° (≈110m) sobre pontos PRODES, para lookup O(1) por
-- vizinhança 3x3. Célula = chave "ci,cj" com ci=floor(lat*1000+0.5).
local function build_veg_grid(points)
    local grid = {}
    for _, p in ipairs(points) do
        local ci = math.floor((p.lat or 0) * 1000 + 0.5)
        local cj = math.floor((p.lon or 0) * 1000 + 0.5)
        local key = string.format("%d,%d", ci, cj)
        local cell = grid[key]
        if not cell then cell = {}; grid[key] = cell end
        cell[#cell + 1] = p
    end
    return grid
end

-- Classifica o contexto vegetacional de um ponto: `native` (sem PRODES a ~30m)
-- | `deforested_<year>` | `regrowth_<year>`. Múltiplas classes sobrepostas →
-- prioriza desmatamento e ano mais recente.
local function vegetation_at(lat, lon, grid)
    local best
    local ci = math.floor((lat or 0) * 1000 + 0.5)
    local cj = math.floor((lon or 0) * 1000 + 0.5)
    for di = -1, 1 do
        for dj = -1, 1 do
            local cell = grid[string.format("%d,%d", ci + di, cj + dj)]
            if cell then
                for _, p in ipairs(cell) do
                    local dlat = (p.lat or 0) - (lat or 0)
                    local dlon = (p.lon or 0) - (lon or 0)
                    if math.sqrt(dlat * dlat + dlon * dlon) <= VEG_PAD then
                        local score_d = (p.type == "deforestation") and 1 or 0
                        local score_y = p.year or 0
                        if not best or score_d > best.score_d
                           or (score_d == best.score_d and score_y > best.score_y) then
                            best = { p = p, score_d = score_d, score_y = score_y }
                        end
                    end
                end
            end
        end
    end
    if not best then
        return { status = "native" }
    end
    local p = best.p
    -- Rótulo PRODES não parseado (fora do padrão [dr]+4 dígitos): sem
    -- type/year, retorna contexto desconhecido em vez de concatenar year nil
    -- no status (ex. `"deforested_nil"` → 500 no /api/fires?vegetation=true).
    if not p.type or not p.year then
        return { status = "unknown" }
    end
    if p.type == "regrowth" then
        return { status = "regrowth_" .. p.year, year = p.year, class_name = p.class_name }
    end
    return { status = "deforested_" .. p.year, year = p.year, class_name = p.class_name }
end

-- Contexto vegetacional de um único foco (popup individual).
function _M.get_fire_vegetation_context(lat, lon)
    local pts = _M.get_deforestation_in_bbox(lat - 0.002, lat + 0.002, lon - 0.002, lon + 0.002, 5000)
    if #pts == 0 then return { status = "native" } end
    return vegetation_at(lat, lon, build_veg_grid(pts))
end

-- Contexto em lote para um bbox de focos — UMA query de deforestation_data e
-- atribuição por foco (evita N queries por foco em bboxes grandes). Retorna
-- tabela índice-do-foco → {status, year, class_name}.
function _M.get_vegetation_context_batch(sw_lat, ne_lat, sw_lng, ne_lng, fires)
    local result = {}
    if not fires or #fires == 0 then return result end
    local pts = _M.get_deforestation_in_bbox(sw_lat, ne_lat, sw_lng, ne_lng, 200000)
    if #pts == 0 then
        for i = 1, #fires do result[i] = { status = "native" } end
        return result
    end
    local grid = build_veg_grid(pts)
    for i, f in ipairs(fires) do
        result[i] = vegetation_at(f.lat, f.lon, grid)
    end
    return result
end

-- ── News ─────────────────────────────────────────────────────────────────

-- Canonical form of an article URL for duplicate detection: strips any
-- fragment and trailing slashes (keeps root "/"). Shared by the write path
-- (upsert conflict key), the read path (feed dedupe) and the sync's in-batch
-- dedupe so every layer agrees on what counts as "the same URL".
function _M.canonical_url(u)
    if type(u) ~= "string" or u == "" then return u end
    u = u:gsub("#[^#]*$", "")
    if #u > 1 then u = u:gsub("/+$", "") end
    return u
end

function _M.bulk_upsert_news(articles)
    if not articles or #articles == 0 then return 0 end

    local db = pool_acquire()
    db:exec("BEGIN")

    local sql = [[
        INSERT INTO news (url, publishedAt, ingested_at, data)
        VALUES (?, ?, ?, jsonb(?))
        ON CONFLICT(url) DO UPDATE SET
            publishedAt=excluded.publishedAt,
            ingested_at=excluded.ingested_at,
            data=jsonb(excluded.data)
    ]]

    for _, a in ipairs(articles) do
        local source_name = nil
        if type(a.source) == "table" then
            source_name = a.source.name
        else
            source_name = a.source
        end

        local canon = _M.canonical_url(a.url)
        local ingested = a.ingested_at or utils.now_iso()
        local published_at = utils.normalize_news_date(a.publishedAt, ingested)
        local data_json = utils.encode_jsonb({
            title = a.title,
            description = a.description,
            title_en = a.title_en,
            description_en = a.description_en,
            source_name = source_name,
            urlToImage = a.urlToImage,
            content = a.content,
        })
        exec_write(db, sql, {canon, published_at, ingested, data_json})
    end

    db:exec("COMMIT")
    pool_release(db)
    return #articles
end

function _M.get_news_page(page, page_size, lang)
    page = page or 1
    page_size = page_size or 20
    lang = lang or "pt"
    local skip = (page - 1) * page_size

    local db = pool_acquire()

    local sql = [[
        SELECT url, publishedAt, ingested_at, json(data) AS data_json
        FROM news
        ORDER BY COALESCE(datetime(publishedAt), datetime(ingested_at)) DESC,
                 datetime(ingested_at) DESC,
                 id DESC
        LIMIT ? OFFSET ?
    ]]

    local rows = fetch_all(db, sql, {page_size, skip})
    pool_release(db)

    -- Defensive read-path dedupe: never serve two rows that canonicalize to
    -- the same URL (e.g. legacy trailing-slash duplicates). Rows are ordered
    -- newest-first, so the first occurrence per canonical URL is kept.
    local seen_canon = {}
    local result = {}
    for _, r in ipairs(rows) do
        local canon = _M.canonical_url(r.url or r["url"])
        local is_dup = canon ~= "" and seen_canon[canon]
        if not is_dup then
            seen_canon[canon] = true
        end

        if not is_dup then
            local d = utils.decode_jsonb(r.data_json or r["data_json"])
            local article = {
                url = r.url or r["url"],
                title = d.title,
                description = d.description,
                title_en = d.title_en,
                description_en = d.description_en,
                publishedAt = utils.normalize_news_date(r.publishedAt or r["publishedAt"], r.ingested_at or r["ingested_at"]),
                source = d.source_name and {name = d.source_name} or {},
                urlToImage = d.urlToImage,
                content = d.content,
                ingested_at = r.ingested_at or r["ingested_at"],
            }

            -- Apply language preference
            if lang == "en" then
                if article.title_en and article.title_en ~= "" then
                    article.title = article.title_en
                end
                if article.description_en and article.description_en ~= "" then
                    article.description = article.description_en
                end
            end

            result[#result + 1] = article
        end
    end
    return result
end

-- Map of normalized title -> existing URL for every news row. Used by the
-- sync to skip articles whose story is already indexed under a DIFFERENT URL
-- (same story published by multiple sources, e.g. syndication), which the
-- URL-based ON CONFLICT can never catch. Table is small (~1k rows), so this
-- is cheap enough to run every sync cycle.
function _M.get_news_title_map()
    local db = pool_acquire()
    local rows = fetch_all(db, "SELECT url, json_extract(data, '$.title') AS title FROM news")
    pool_release(db)

    local map = {}
    for _, r in ipairs(rows) do
        local nt = utils.normalize_title(r.title)
        if nt ~= "" and not map[nt] then
            map[nt] = r.url
        end
    end
    return map
end

function _M.has_recent_news(minutes)
    minutes = minutes or 15
    local cutoff = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - minutes * 60)
    local db = pool_acquire()
    local row = fetch_one(db, "SELECT COUNT(*) AS cnt FROM news WHERE ingested_at >= ?", {cutoff})
    pool_release(db)
    return row and (tonumber(row.cnt or row["cnt"] or 0) > 0)
end

function _M.count_news()
    local db = pool_acquire()
    local row = fetch_one(db, "SELECT COUNT(*) AS cnt FROM news")
    pool_release(db)
    return row and tonumber(row.cnt or row["cnt"] or 0) or 0
end

-- ── News field access (for translation repair) ───────────────────────────

function _M.get_news_fields_by_urls(urls, fields)
    if not urls or #urls == 0 then return {} end

    local db = pool_acquire()
    local result = {}

    for _, url in ipairs(urls) do
        local extracts = {}
        for _, f in ipairs(fields) do
            extracts[#extracts + 1] = "json_extract(data, '$." .. f .. "') AS " .. f
        end
        local sql = "SELECT url, " .. table.concat(extracts, ", ") .. " FROM news WHERE url = ?"
        local row = fetch_one(db, sql, {url})
        if row then
            result[url] = {}
            for _, f in ipairs(fields) do
                result[url][f] = row[f]
            end
        end
    end

    pool_release(db)
    return result
end

function _M.update_news_fields(url, updates)
    local db = pool_acquire()

    local row = fetch_one(db, "SELECT json(data) AS data_json FROM news WHERE url = ?", {url})
    if not row then
        pool_release(db)
        return
    end

    local current = utils.decode_jsonb(row.data_json or row["data_json"])
    for k, v in pairs(updates) do
        current[k] = v
    end

    local data_json = utils.encode_jsonb(current)
    db:exec("BEGIN")
    exec_write(db, "UPDATE news SET data = jsonb(?) WHERE url = ?", {data_json, url})
    db:exec("COMMIT")
    pool_release(db)
end

function _M.clear_news_fields(urls, fields)
    if not urls or #urls == 0 then return end

    local db = pool_acquire()
    db:exec("BEGIN")

    for _, url in ipairs(urls) do
        local row = fetch_one(db, "SELECT json(data) AS data_json FROM news WHERE url = ?", {url})
        if row then
            local current = utils.decode_jsonb(row.data_json or row["data_json"])
            for _, field in ipairs(fields) do
                current[field] = nil
            end
            local data_json = utils.encode_jsonb(current)
            exec_write(db, "UPDATE news SET data = jsonb(?) WHERE url = ?", {data_json, url})
        end
    end

    db:exec("COMMIT")
    pool_release(db)
end

-- ── Stats ────────────────────────────────────────────────────────────────

-- ── Lookup data (biome polygons, indigenous lands, conservation units) ──

function _M.get_lookup_data(key)
    local db = pool_acquire()
    local row = fetch_one(db, "SELECT json(data) AS data_json, updated_at FROM lookup_data WHERE key = ?", {key})
    pool_release(db)
    if not row then return nil end
    local d = utils.decode_jsonb(row.data_json or row["data_json"])
    d._updated_at = row.updated_at or row["updated_at"]
    return d
end

function _M.set_lookup_data(key, data)
    local db = pool_acquire()
    db:exec("BEGIN")
    local data_json = utils.encode_jsonb(data)
    local updated_at = utils.now_iso()
    exec_write(db, [[
        INSERT INTO lookup_data (key, data, updated_at)
        VALUES (?, jsonb(?), ?)
        ON CONFLICT(key) DO UPDATE SET data = jsonb(excluded.data), updated_at = excluded.updated_at
    ]], {key, data_json, updated_at})
    db:exec("COMMIT")
    pool_release(db)
    return true
end

function _M.has_lookup_data(key)
    local db = pool_acquire()
    local row = fetch_one(db, "SELECT 1 AS found FROM lookup_data WHERE key = ?", {key})
    pool_release(db)
    return row ~= nil
end

function _M.count_deforestation()
    local db = pool_acquire()
    local row = fetch_one(db, "SELECT COUNT(*) AS cnt FROM deforestation_data")
    pool_release(db)
    return row and tonumber(row.cnt or row["cnt"] or 0) or 0
end

function _M.get_stats()
    local db = pool_acquire()
    local fire_count = fetch_one(db, "SELECT COUNT(*) AS cnt FROM fire_data")
    local def_count  = fetch_one(db, "SELECT COUNT(*) AS cnt FROM deforestation_data")
    local news_count = fetch_one(db, "SELECT COUNT(*) AS cnt FROM news")
    pool_release(db)

    return {
        fires = fire_count and tonumber(fire_count.cnt or fire_count["cnt"] or 0) or 0,
        deforestation = def_count and tonumber(def_count.cnt or def_count["cnt"] or 0) or 0,
        news = news_count and tonumber(news_count.cnt or news_count["cnt"] or 0) or 0,
    }
end

-- ── Migration ────────────────────────────────────────────────────────────

function _M.migrate_to_jsonb()
    local db = sqlite3.open(DB_PATH)
    check_sqlite_version(db)

    -- ── fire_data ──
    local cols = {}
    local stmt = db:prepare("PRAGMA table_info(fire_data)")
    if stmt then
        for row in stmt:rows() do
            cols[row[2] or ""] = true
        end
        stmt:finalize()
    end

    if cols["confidence"] then
        logger.info("Rebuilding fire_data table to JSONB schema...")
        db:exec([[
            CREATE TABLE IF NOT EXISTS fire_data_new (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                lat REAL NOT NULL,
                lon REAL NOT NULL,
                acq_date TEXT,
                ingested_at TEXT,
                data BLOB,
                UNIQUE(lat, lon, acq_date)
            )
        ]])

        local rows = fetch_all(db, [[
            SELECT id, lat, lon, acq_date, ingested_at,
                   confidence, acq_time, satellite, bright_ti4, source
            FROM fire_data
        ]])

        for _, row in ipairs(rows) do
            local data_json = utils.encode_jsonb({
                confidence = row.confidence or row["confidence"],
                acq_time = row.acq_time or row["acq_time"],
                satellite = row.satellite or row["satellite"],
                bright_ti4 = row.bright_ti4 or row["bright_ti4"],
                source = row.source or row["source"],
            })
            exec_write(db, [[
                INSERT INTO fire_data_new (id, lat, lon, acq_date, ingested_at, data)
                VALUES (?, ?, ?, ?, ?, jsonb(?))
            ]], {
                row.id or row["id"],
                row.lat or row["lat"],
                row.lon or row["lon"],
                row.acq_date or row["acq_date"],
                row.ingested_at or row["ingested_at"],
                data_json,
            })
        end

        db:exec("DROP TABLE fire_data")
        db:exec("ALTER TABLE fire_data_new RENAME TO fire_data")
        db:exec([[
            CREATE INDEX IF NOT EXISTS idx_fire_lat ON fire_data(lat);
            CREATE INDEX IF NOT EXISTS idx_fire_lon ON fire_data(lon);
            CREATE INDEX IF NOT EXISTS idx_fire_acq_date ON fire_data(acq_date);
            CREATE INDEX IF NOT EXISTS idx_fire_confidence ON fire_data(json_extract(data, '$.confidence'));
        ]])
        logger.info("fire_data rebuilt with JSONB schema (", #rows, " rows)")
    end

    -- ── deforestation_data ──
    cols = {}
    stmt = db:prepare("PRAGMA table_info(deforestation_data)")
    if stmt then
        for row in stmt:rows() do
            cols[row[2] or ""] = true
        end
        stmt:finalize()
    end

    if cols["name"] then
        logger.info("Rebuilding deforestation_data table to JSONB schema...")
        db:exec([[
            CREATE TABLE IF NOT EXISTS deforestation_data_new (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                lat REAL,
                lon REAL,
                data BLOB
            )
        ]])

        local rows = fetch_all(db, [[
            SELECT id, lat, lon, name, clazz, periods, source, color, timestamp
            FROM deforestation_data
        ]])

        for _, row in ipairs(rows) do
            local data_json = utils.encode_jsonb({
                name = row.name or row["name"],
                clazz = row.clazz or row["clazz"],
                periods = row.periods or row["periods"],
                source = row.source or row["source"],
                color = row.color or row["color"],
                timestamp = row.timestamp or row["timestamp"],
            })
            exec_write(db, [[
                INSERT INTO deforestation_data_new (id, lat, lon, data)
                VALUES (?, ?, ?, jsonb(?))
            ]], {
                row.id or row["id"],
                row.lat or row["lat"],
                row.lon or row["lon"],
                data_json,
            })
        end

        db:exec("DROP TABLE deforestation_data")
        db:exec("ALTER TABLE deforestation_data_new RENAME TO deforestation_data")
        db:exec([[
            CREATE INDEX IF NOT EXISTS idx_def_lat ON deforestation_data(lat);
            CREATE INDEX IF NOT EXISTS idx_def_lon ON deforestation_data(lon);
            CREATE INDEX IF NOT EXISTS idx_def_name ON deforestation_data(json_extract(data, '$.name'));
        ]])
        logger.info("deforestation_data rebuilt with JSONB schema (", #rows, " rows)")
    end

    -- ── news ──
    cols = {}
    stmt = db:prepare("PRAGMA table_info(news)")
    if stmt then
        for row in stmt:rows() do
            cols[row[2] or ""] = true
        end
        stmt:finalize()
    end

    if cols["title"] then
        logger.info("Rebuilding news table to JSONB schema...")
        db:exec([[
            CREATE TABLE IF NOT EXISTS news_new (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT UNIQUE NOT NULL,
                publishedAt TEXT,
                ingested_at TEXT,
                data BLOB
            )
        ]])

        local rows = fetch_all(db, [[
            SELECT id, url, publishedAt, ingested_at,
                   title, description, title_en, description_en,
                   source_name, urlToImage, content
            FROM news
        ]])

        for _, row in ipairs(rows) do
            local data_json = utils.encode_jsonb({
                title = row.title or row["title"],
                description = row.description or row["description"],
                title_en = row.title_en or row["title_en"],
                description_en = row.description_en or row["description_en"],
                source_name = row.source_name or row["source_name"],
                urlToImage = row.urlToImage or row["urlToImage"],
                content = row.content or row["content"],
            })
            local ingested = row.ingested_at or row["ingested_at"] or row.publishedAt or row["publishedAt"]
            exec_write(db, [[
                INSERT INTO news_new (id, url, publishedAt, ingested_at, data)
                VALUES (?, ?, ?, ?, jsonb(?))
            ]], {
                row.id or row["id"],
                row.url or row["url"],
                row.publishedAt or row["publishedAt"],
                ingested,
                data_json,
            })
        end

        db:exec("DROP TABLE news")
        db:exec("ALTER TABLE news_new RENAME TO news")
        db:exec([[
            CREATE INDEX IF NOT EXISTS idx_news_published ON news(publishedAt);
            CREATE INDEX IF NOT EXISTS idx_news_ingested ON news(ingested_at);
            CREATE INDEX IF NOT EXISTS idx_news_source ON news(json_extract(data, '$.source_name'));
        ]])
        logger.info("news rebuilt with JSONB schema (", #rows, " rows)")
    end

    db:close()
    logger.info("Migration to JSONB complete")
end

-- ── DETER (plan: terrabrasilis-integration, Inc 2) ────────────────────────

-- Polígonos DETER dentro de um bbox, com filtro opcional de dias e geom
-- decodificada (JSON TEXT ou JSONB → tabela). Usa as colunas escalares de bbox
-- persistidas pelo writer Python (idx_deter_bbox).
function _M.get_deter_polygons(sw_lat, ne_lat, sw_lng, ne_lng, days, limit)
    limit = limit or 500
    local db = pool_acquire()
    local sql = [[
        SELECT id, classname, view_date, uf, municipality, mun_geocod, area_km2, uc,
               min_lat, min_lon, max_lat, max_lon, json(geom) AS geom_json
        FROM deter_polygons
        WHERE min_lat <= ? AND max_lat >= ? AND min_lon <= ? AND max_lon >= ?
    ]]
    local params = {ne_lat, sw_lat, ne_lng, sw_lng}
    if days then
        local cutoff = _M.days_ago_iso(days)
        sql = sql .. " AND view_date >= ?"
        params[#params + 1] = cutoff
    end
    sql = sql .. " ORDER BY view_date DESC LIMIT ?"
    params[#params + 1] = limit

    local rows = fetch_all(db, sql, params)
    pool_release(db)

    local result = {}
    for _, r in ipairs(rows) do
        result[#result + 1] = {
            id = r.id or r["id"],
            classname = r.classname,
            view_date = r.view_date,
            uf = r.uf,
            municipality = r.municipality,
            mun_geocod = r.mun_geocod,
            area_km2 = r.area_km2,
            uc = r.uc,
            bbox = {
                min_lat = r.min_lat, min_lon = r.min_lon,
                max_lat = r.max_lat, max_lon = r.max_lon,
            },
            geom = utils.decode_jsonb(r.geom_json or r["geom_json"]),
        }
    end
    return result
end

-- DETER polígonos recentes (por data), paginados por id — usado pelo scan de
-- alertas em UC/TI (plan: terrabrasilis-integration, Inc 6).
function _M.iter_deter_recent(days, batch_size, min_id)
    days = days or 30
    batch_size = batch_size or 1000
    min_id = tonumber(min_id) or 0
    local cutoff = _M.days_ago_iso(days)
    local db = pool_acquire()
    local rows = fetch_all(db, [[
        SELECT id, classname, view_date, area_km2, uc, areauckm,
               min_lat, min_lon, max_lat, max_lon, json(geom) AS geom_json
        FROM deter_polygons
        WHERE view_date >= ? AND id > ?
        ORDER BY id
        LIMIT ?
    ]], {cutoff, min_id, batch_size})
    pool_release(db)

    local result = {}
    for _, r in ipairs(rows) do
        result[#result + 1] = {
            id = tonumber(r.id or r["id"]),
            classname = r.classname,
            view_date = r.view_date,
            area_km2 = tonumber(r.area_km2),
            uc = r.uc,
            areauckm = tonumber(r.areauckm),
            min_lat = tonumber(r.min_lat), min_lon = tonumber(r.min_lon),
            max_lat = tonumber(r.max_lat), max_lon = tonumber(r.max_lon),
            geom = utils.decode_jsonb(r.geom_json or r["geom_json"]),
        }
    end
    return result
end

-- Estatísticas DETER agregadas num período. `by_municipality` lê `deter_alerts`
-- (histórico completo backfilled + rollup diário); o resto lê a janela de
-- polígonos (`deter_polygons`, retenção ~90 dias — R2).
-- `uf` opcional (plan: dashboard-enhancement, Inc 5) filtra por estado.
function _M.get_deter_stats(days, uf)
    days = days or 30
    local cutoff = _M.days_ago_iso(days)
    local db = pool_acquire()

    local uf_where = ""
    local params = {cutoff}
    if uf and uf ~= "" then
        uf_where = " AND uf = ?"
        params[#params + 1] = uf
    end

    local total = 0
    local row = fetch_one(db, "SELECT COALESCE(SUM(area_km2), 0) AS s FROM deter_polygons WHERE view_date >= ?" .. uf_where, params)
    total = tonumber(row and (row.s or row["s"])) or 0

    local by_class = {}
    for _, r in ipairs(fetch_all(db, [[
        SELECT classname AS name, SUM(area_km2) AS km2 FROM deter_polygons
        WHERE view_date >= ? ]] .. uf_where .. [[ GROUP BY classname ORDER BY km2 DESC
    ]], params)) do
        by_class[#by_class + 1] = { name = r.name, km2 = tonumber(r.km2) or 0 }
    end

    local by_uf = {}
    if uf and uf ~= "" then
        -- com UF filtrada, by_uf colapsa para uma entrada consistente com total
        by_uf[1] = { uf = uf, km2 = total }
    else
        for _, r in ipairs(fetch_all(db, [[
            SELECT uf, SUM(area_km2) AS km2 FROM deter_polygons
            WHERE view_date >= ? AND uf IS NOT NULL GROUP BY uf ORDER BY km2 DESC
        ]], {cutoff})) do
            by_uf[#by_uf + 1] = { uf = r.uf, km2 = tonumber(r.km2) or 0 }
        end
    end

    local by_day = {}
    for _, r in ipairs(fetch_all(db, [[
        SELECT view_date AS date, SUM(area_km2) AS km2 FROM deter_polygons
        WHERE view_date >= ? ]] .. uf_where .. [[ GROUP BY view_date ORDER BY view_date
    ]], params)) do
        by_day[#by_day + 1] = { date = r.date, km2 = tonumber(r.km2) or 0 }
    end

    local by_municipality = {}
    for _, r in ipairs(fetch_all(db, [[
        SELECT mun_geocod, MAX(municipality) AS name, SUM(area_km2) AS km2
        FROM deter_alerts WHERE view_date >= ? ]] .. uf_where .. [[ AND mun_geocod IS NOT NULL
        GROUP BY mun_geocod ORDER BY km2 DESC LIMIT 50
    ]], params)) do
        by_municipality[#by_municipality + 1] = {
            mun_geocod = r.mun_geocod, name = r.name, km2 = tonumber(r.km2) or 0,
        }
    end

    pool_release(db)
    return {
        total_km2 = total,
        by_class = by_class,
        by_uf = by_uf,
        by_day = by_day,
        by_municipality = by_municipality,
    }
end

-- Linhas de `deter_alerts` (agregado geocod×classe×data), filtros opcionais.
function _M.get_deter_alerts(mun_geocod, classname, days, limit)
    days = days or 90
    limit = limit or 10000  -- bounded (Inc 7): routes pass an explicit limit
    local cutoff = _M.days_ago_iso(days)
    local db = pool_acquire()
    local sql = [[
        SELECT mun_geocod, classname, view_date, area_km2, uf
        FROM deter_alerts WHERE view_date >= ?
    ]]
    local params = {cutoff}
    if mun_geocod then
        sql = sql .. " AND mun_geocod = ?"
        params[#params + 1] = mun_geocod
    end
    if classname then
        sql = sql .. " AND classname = ?"
        params[#params + 1] = classname
    end
    sql = sql .. " ORDER BY view_date DESC LIMIT ?"
    params[#params + 1] = limit

    local rows = fetch_all(db, sql, params)
    pool_release(db)

    local result = {}
    for _, r in ipairs(rows) do
        result[#result + 1] = {
            mun_geocod = r.mun_geocod,
            classname = r.classname,
            view_date = r.view_date,
            area_km2 = r.area_km2,
            uf = r.uf,
        }
    end
    return result
end

-- ── DETER × CAR alerts (plan: terrabrasilis-integration, Inc 3) ───────────

-- Alerta por propriedade CAR (deter_car_alerts), paginado e filtrável.
-- severity ranking: maximo > alto > medio > baixo.
function _M.get_car_alerts(uf, municipio, severity, days, page, page_size)
    days = days or 7
    page = page or 1
    page_size = page_size or 20
    local cutoff = _M.days_ago_iso(days)

    local db = pool_acquire()
    local where = " WHERE view_date >= ?"
    local params = {cutoff}
    if uf then
        where = where .. " AND uf = ?"
        params[#params + 1] = uf
    end
    if municipio then
        where = where .. " AND municipio LIKE ?"
        params[#params + 1] = "%" .. municipio .. "%"
    end
    if severity then
        where = where .. " AND severity = ?"
        params[#params + 1] = severity
    end

    local total = 0
    local crow = fetch_one(db, "SELECT COUNT(*) AS c FROM deter_car_alerts" .. where, params)
    total = tonumber(crow and (crow.c or crow["c"])) or 0

    local offset = (page - 1) * page_size
    local qparams = {}
    for _, p in ipairs(params) do qparams[#qparams + 1] = p end
    qparams[#qparams + 1] = page_size
    qparams[#qparams + 1] = offset

    local rows = fetch_all(db, [[
        SELECT cod_imovel, classname, view_date, uf, municipio, area_afetada_ha,
               fire_count, fire_dates, severity
        FROM deter_car_alerts ]] .. where .. [[
        ORDER BY view_date DESC,
          CASE severity WHEN 'maximo' THEN 0 WHEN 'alto' THEN 1
                        WHEN 'medio' THEN 2 ELSE 3 END
        LIMIT ? OFFSET ?
    ]], qparams)
    pool_release(db)

    local alerts = {}
    for _, r in ipairs(rows) do
        alerts[#alerts + 1] = {
            cod_imovel = r.cod_imovel,
            classname = r.classname,
            view_date = r.view_date,
            uf = r.uf,
            municipio = r.municipio,
            area_afetada_ha = r.area_afetada_ha,
            fire_count = r.fire_count,
            fire_dates = utils.decode_jsonb(r.fire_dates),
            severity = r.severity,
        }
    end
    return { alerts = alerts, total = total, page = page, page_size = page_size }
end

function _M.get_car_alert_stats(days, uf)
    days = days or 7
    local cutoff = _M.days_ago_iso(days)
    local db = pool_acquire()

    local uf_where = ""
    local params = {cutoff}
    if uf and uf ~= "" then
        uf_where = " AND uf = ?"
        params[#params + 1] = uf
    end

    local total = 0
    local crow = fetch_one(db, "SELECT COUNT(*) AS c FROM deter_car_alerts WHERE view_date >= ?" .. uf_where, params)
    total = tonumber(crow and (crow.c or crow["c"])) or 0

    local by_severity = {}
    for _, r in ipairs(fetch_all(db, [[
        SELECT severity, COUNT(*) AS cnt FROM deter_car_alerts
        WHERE view_date >= ? ]] .. uf_where .. [[ AND severity IS NOT NULL GROUP BY severity
    ]], params)) do
        by_severity[#by_severity + 1] = { severity = r.severity, count = r.cnt }
    end

    local by_uf = {}
    if uf and uf ~= "" then
        by_uf[1] = { uf = uf, count = total }
    else
        for _, r in ipairs(fetch_all(db, [[
            SELECT uf, COUNT(*) AS cnt FROM deter_car_alerts
            WHERE view_date >= ? AND uf IS NOT NULL GROUP BY uf ORDER BY cnt DESC
        ]], {cutoff})) do
            by_uf[#by_uf + 1] = { uf = r.uf, count = r.cnt }
        end
    end

    pool_release(db)
    return { total = total, by_severity = by_severity, by_uf = by_uf }
end

-- Alertas DETER×CAR de um imóvel específico (plan: terrabrasilis-integration,
-- Inc 4 — enriquecimento FIRMS×DETER). Retorna as linhas recentes do imóvel.
function _M.get_car_alerts_by_imovel(cod_imovel, days)    days = days or 7
    if type(cod_imovel) ~= "string" or cod_imovel == "" then return {} end
    local cutoff = _M.days_ago_iso(days)
    local db = pool_acquire()
    local rows = fetch_all(db, [[
        SELECT classname, view_date, severity, fire_count
        FROM deter_car_alerts
        WHERE cod_imovel = ? AND view_date >= ?
        ORDER BY view_date DESC
    ]], {cod_imovel:upper(), cutoff})
    pool_release(db)

    local result = {}
    for _, r in ipairs(rows) do
        result[#result + 1] = {
            classname = r.classname,
            view_date = r.view_date,
            severity = r.severity,
            fire_count = r.fire_count,
        }
    end
    return result
end

-- ── AMS (plan: terrabrasilis-integration, Inc 11) ─────────────────────────

-- Camadas AMS (fire-spreading-risk polígonos / active-fire-today pontos) num
-- bbox + janela de dias. geom decodificada (JSON TEXT/JSONB → tabela).
function _M.get_ams_risk(sw_lat, ne_lat, sw_lng, ne_lng, days, limit)
    days = days or 7
    limit = limit or 5000  -- bounded (Inc 7): serves fire-spreading-risk polygons
    local cutoff = _M.days_ago_iso(days)
    local db = pool_acquire()
    local rows = fetch_all(db, [[
        SELECT id, view_date, viewed_at, satelite, municipio, biome, geocode,
               layer, risk_level, min_lat, min_lon, max_lat, max_lon, json(geom) AS geom_json
        FROM ams_risk
        WHERE min_lat <= ? AND max_lat >= ? AND min_lon <= ? AND max_lon >= ?
          AND view_date >= ?
        ORDER BY view_date DESC
        LIMIT ?
    ]], {ne_lat, sw_lat, ne_lng, sw_lng, cutoff, limit})
    pool_release(db)

    local result = {}
    for _, r in ipairs(rows) do
        result[#result + 1] = {
            id = r.id,
            view_date = r.view_date,
            viewed_at = r.viewed_at,
            satelite = r.satelite,
            municipio = r.municipio,
            biome = r.biome,
            geocode = r.geocode,
            layer = r.layer,
            risk_level = r.risk_level,
            geom = utils.decode_jsonb(r.geom_json or r["geom_json"]),
        }
    end
    return result
end

-- Nível de risco em lote para N focos (Inc 7): elimina o N+1 do loop
-- per-foco de get_ams_risk_at em bboxes grandes (ex. ?ams=true, até 10k focos).
-- Estratégia bounded-batch: agrupa focos em buckets de ~2°; UMA query espacial
-- por bucket (bbox-pre-filter em SQL, ORDER BY view_date DESC); por foco,
-- seleciona o primeiro candidato cujo bbox (expandido pelo raio R) contém o
-- ponto — mesma semântica de get_ams_risk_at. Se um bucket exceder
-- MAX_CANDIDATES_PER_BUCKET, cai para queries per-foco (idênticas a
-- get_ams_risk_at). Retorna {id={risk_level, view_date}}.
function _M.get_ams_risk_batch(fires)
    local result = {}
    if not fires or #fires == 0 then return result end

    local BUCKET = 2.0          -- ~2° de span espacial por query
    local MAX_CANDIDATES_PER_BUCKET = 2000
    local R = 0.1               -- mesmo raio de busca de get_ams_risk_at (~11km)

    -- Agrupa focos por bucket (canto inferior-esquerdo do quadrado ~2°).
    local buckets, order = {}, {}
    for _, f in ipairs(fires) do
        local bk = string.format("%.0f,%.0f", math.floor((f.lat or 0) / BUCKET), math.floor((f.lon or 0) / BUCKET))
        if not buckets[bk] then
            buckets[bk] = {}
            order[#order + 1] = bk
        end
        buckets[bk][#buckets[bk] + 1] = f
    end

    local db = pool_acquire()
    for _, bk in ipairs(order) do
        local bls, bbs = bk:match("^([^,]+),(.+)$")
        local bl, bb = tonumber(bls) * BUCKET, tonumber(bbs) * BUCKET
        local ne_lat, sw_lat = bl + BUCKET, bl
        local ne_lng, sw_lng = bb + BUCKET, bb

        local rows = fetch_all(db, [[
            SELECT risk_level, view_date, min_lat, min_lon, max_lat, max_lon
            FROM ams_risk
            WHERE min_lat <= ? AND max_lat >= ? AND min_lon <= ? AND max_lon >= ?
              AND layer = 'fire-spreading-risk' AND risk_level IS NOT NULL
            ORDER BY view_date DESC
            LIMIT ?
        ]], {ne_lat, sw_lat, ne_lng, sw_lng, MAX_CANDIDATES_PER_BUCKET + 1})

        if #rows > MAX_CANDIDATES_PER_BUCKET then
            -- Bucket com candidatos demais: fallback per-foco (raro — os
            -- polígonos AMS são regionais, buckets pequenos raramente estouram).
            for _, f in ipairs(buckets[bk]) do
                local rr = fetch_all(db, [[
                    SELECT risk_level, view_date FROM ams_risk
                    WHERE min_lat <= ? AND max_lat >= ? AND min_lon <= ? AND max_lon >= ?
                      AND layer = 'fire-spreading-risk' AND risk_level IS NOT NULL
                    ORDER BY view_date DESC LIMIT 1
                ]], {f.lat + R, f.lat - R, f.lon + R, f.lon - R})
                if rr[1] then
                    result[f.id] = { risk_level = rr[1].risk_level, view_date = rr[1].view_date }
                end
            end
        else
            -- Point-in-bbox apenas nos candidatos do bucket (mais recente primeiro).
            for _, f in ipairs(buckets[bk]) do
                for _, p in ipairs(rows) do
                    if f.lat >= (p.min_lat or -90) - R and f.lat <= (p.max_lat or 90) + R
                       and f.lon >= (p.min_lon or -180) - R and f.lon <= (p.max_lon or 180) + R then
                        result[f.id] = { risk_level = p.risk_level, view_date = p.view_date }
                        break
                    end
                end
            end
        end
    end
    pool_release(db)
    return result
end

-- Nível de risco mais próximo de um ponto (fogo): procura um polígono
-- fire-spreading-risk num raio pequeno (≈1 bbox de busca). Retorna
-- {risk_level, view_date, biome, municipio} ou nil.
function _M.get_ams_risk_at(lat, lon)
    local R = 0.1  -- ~11km de busca (polígonos AMS são regionais)
    local db = pool_acquire()
    local rows = fetch_all(db, [[
        SELECT risk_level, view_date, biome, municipio
        FROM ams_risk
        WHERE min_lat <= ? AND max_lat >= ? AND min_lon <= ? AND max_lon >= ?
          AND layer = 'fire-spreading-risk' AND risk_level IS NOT NULL
        ORDER BY view_date DESC
        LIMIT 1
    ]], {lat + R, lat - R, lon + R, lon - R})
    pool_release(db)
    local r = rows[1]
    if not r then return nil end
    return {
        risk_level = r.risk_level,
        view_date = r.view_date,
        biome = r.biome,
        municipio = r.municipio,
    }
end

return _M

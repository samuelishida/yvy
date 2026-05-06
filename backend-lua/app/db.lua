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
CREATE INDEX IF NOT EXISTS idx_def_lat ON deforestation_data(lat);
CREATE INDEX IF NOT EXISTS idx_def_lon ON deforestation_data(lon);
CREATE INDEX IF NOT EXISTS idx_news_published ON news(publishedAt);
CREATE INDEX IF NOT EXISTS idx_news_ingested ON news(ingested_at);
CREATE INDEX IF NOT EXISTS idx_fire_confidence ON fire_data(json_extract(data, '$.confidence'));
CREATE INDEX IF NOT EXISTS idx_def_name ON deforestation_data(json_extract(data, '$.name'));
CREATE INDEX IF NOT EXISTS idx_news_source ON news(json_extract(data, '$.source_name'));

CREATE TABLE IF NOT EXISTS lookup_data (
    key TEXT PRIMARY KEY,
    data BLOB,
    updated_at TEXT
);
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
    db:exec("PRAGMA cache_size=-8000")
    db:exec("PRAGMA temp_store=MEMORY")
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
    db:close()

    -- Build pool
    for _ = 1, POOL_SIZE do
        local conn = sqlite3.open(DB_PATH)
        conn:exec("PRAGMA journal_mode=WAL")
        conn:exec("PRAGMA synchronous=NORMAL")
        conn:exec("PRAGMA cache_size=-8000")
        conn:exec("PRAGMA temp_store=MEMORY")
        pool_available[#pool_available + 1] = conn
    end

    logger.info("SQLite initialized at ", DB_PATH, " (JSONB schema, ", POOL_SIZE, " connections)")
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
        })
        exec_write(db, sql, {
            d.lat, d.lon, d.acq_date, d.ingested_at, data_json
        })
    end

    db:exec("COMMIT")
    pool_release(db)
    return #docs
end

function _M.find_fires(sw_lat, ne_lat, sw_lng, ne_lng, limit)
    limit = limit or 10000
    local db = pool_acquire()

    local sql = [[
        SELECT lat, lon, acq_date, ingested_at, json(data) AS data_json
        FROM fire_data
        WHERE lat >= ? AND lat <= ? AND lon >= ? AND lon <= ?
        ORDER BY acq_date DESC, lat, lon
        LIMIT ?
    ]]

    local rows = fetch_all(db, sql, {sw_lat, ne_lat, sw_lng, ne_lng, limit})
    pool_release(db)

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
        }
    end
    return result
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

-- ── News ─────────────────────────────────────────────────────────────────

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
        exec_write(db, sql, {a.url, published_at, ingested, data_json})
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
                 url DESC
        LIMIT ? OFFSET ?
    ]]

    local rows = fetch_all(db, sql, {page_size, skip})
    pool_release(db)

    local result = {}
    for _, r in ipairs(rows) do
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
    return result
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

return _M

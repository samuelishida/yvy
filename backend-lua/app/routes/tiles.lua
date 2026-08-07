-- tiles.lua — /api/tiles/prodes + /api/tiles/car
-- Serves PRODES WMS tiles and precomputed CAR tiles from local SQLite caches.
--
-- COLD-CACHE INVARIANT: tiles_prodes.db / tiles_car.db are pre-warmed OFFLINE
-- by scripts/cache_prodes_tiles.py (single writer, one connection — safe). The
-- backend opens them READ-ONLY (query_only=ON) and NEVER writes or spawns
-- on-demand writers: concurrent multi-process INSERTs from separate workers
-- corrupted the DB ("database disk image is malformed" → 500s). Miss → try the
-- nearest cached ANCESTOR tile (keeps the layer visible during a re-warm),
-- else transparent PNG.

local sqlite3     = require("lsqlite3")
local logger      = require("app.logger")
local env         = require("app.env")

local _M = {}
-- Per-path cached connections (never open per request — 256-tile bursts).
local _dbs = {}

-- CORS allowlist for tile responses (same policy as app/server.lua): echo the
-- request Origin only when it's in CORS_ORIGINS (or the allowlist contains "*").
-- No Origin header (curl, non-browser) → no Access-Control-Allow-Origin header.
local CORS_ORIGINS = os.getenv("CORS_ORIGINS") or "http://localhost:5001,http://127.0.0.1:5001,http://localhost:3000"
local cors_origins = {}
for origin in (CORS_ORIGINS .. ","):gmatch("([^,]+),") do
    origin = origin:gsub("^%s+", ""):gsub("%s+$", "")
    if origin ~= "" then
        cors_origins[origin] = true
    end
end

local function set_cors_headers(ctx)
    local origin = ctx.req.headers["origin"] or ""
    if cors_origins[origin] or cors_origins["*"] then
        ctx:set_header("Access-Control-Allow-Origin", origin)
    end
end

-- Minimal 1x1 transparent PNG (returned when tile has no data)
local EMPTY_PNG = string.char(
    0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A, -- PNG signature
    0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52, -- IHDR length + type
    0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01, -- 1x1
    0x08,0x06,0x00,0x00,0x00,0x1F,0x15,0xC4, -- 8-bit RGBA + CRC
    0x89,0x00,0x00,0x00,0x0A,0x49,0x44,0x41, -- IDAT length + type
    0x54,0x78,0x9C,0x62,0x00,0x00,0x00,0x02, -- compressed row
    0x00,0x01,0xE2,0x21,0xBC,0x33,0x00,0x00, -- CRC + IEND length
    0x00,0x00,0x49,0x45,0x4E,0x44,0xAE,0x42, -- IEND type + CRC
    0x60,0x82
)

-- Open (and cache per-path) a tiles DB connection. Returns nil if missing.
local function open_tiles_db(path)
    if _dbs[path] then return _dbs[path] end
    local f = io.open(path, "r")
    if not f then return nil end
    f:close()
    -- Open a READ-WRITE handle but with PRAGMA query_only=ON. A truly
    -- read-only WAL connection cannot maintain the shared-memory index when
    -- another process (the offline warmer) checkpoints the WAL, so a cached
    -- long-lived connection goes stale and reads garbage ("database disk
    -- image is malformed" → 500s). A read-write handle tracks WAL checkpoints
    -- correctly, and query_only=ON makes SQLite refuse ANY write on it — so
    -- the cold-cache invariant holds: this process can never write, and thus
    -- can never corrupt tiles_prodes.db / tiles_car.db.
    local db, err = sqlite3.open(path)
    if not db then
        logger.warn("Tiles DB open failed for " .. path .. ": " .. tostring(err))
        return nil
    end
    db:exec("PRAGMA query_only=ON")
    db:exec("PRAGMA busy_timeout=5000")
    db:exec("PRAGMA cache_size=-4000")
    _dbs[path] = db
    logger.info("Tiles DB opened (query_only): " .. path)
    return db
end
-- Look up one tile row in a cached connection. Returns data blob or nil.
-- Tiles DBs use a (z,x,y) key. If the cached connection has gone stale (e.g.
-- the offline warmer checkpointed the WAL mid-request), drop it, reopen fresh
-- and retry once — never surface a 500 for a transient WAL staleness.
local function lookup_tile(path, db, z, x, y)
    local function query(conn)
        local sql = "SELECT data FROM tiles WHERE z=? AND x=? AND y=?"
        local stmt = conn:prepare(sql)
        if not stmt then return nil end
        stmt:bind(1, z); stmt:bind(2, x); stmt:bind(3, y)
        local d
        for row in stmt:nrows() do
            d = row.data
        end
        stmt:finalize()
        return d
    end

    local ok, data = pcall(query, db)
    if ok then return data end

    -- Stale connection: close, forget, reopen once and retry.
    logger.warn("Tiles DB read failed (stale conn?), reopening: " .. tostring(data))
    pcall(function() db:close() end)
    _dbs[path] = nil
    local db2 = open_tiles_db(path)
    if not db2 then return nil end
    local ok2, data2 = pcall(query, db2)
    if not ok2 then
        logger.error("Tiles DB read failed after reopen: " .. tostring(data2))
        return nil
    end
    return data2
end

-- Walk up to the nearest cached ANCESTOR tile. The warmer fills z3→z12 in
-- order, so during a re-warm a missing child almost always has a cached parent
-- — serving it keeps the layer visible instead of a transparent hole (the
-- "PRODES disappears when zooming in" symptom). Bounded so a truly-empty area
-- costs at most MAX_FALLBACK_DEPTH cheap SELECTs. Returns data or nil.
local MAX_FALLBACK_DEPTH = 6

local function lookup_ancestor(path, db, z, x, y)
    local az, ax, ay = z, x, y
    for _ = 1, MAX_FALLBACK_DEPTH do
        if az <= 3 then break end -- never go below z3 (coarse but complete)
        az = az - 1
        ax = math.floor(ax / 2)
        ay = math.floor(ay / 2)
        local data = lookup_tile(path, db, az, ax, ay)
        if data then return data end
    end
    return nil
end

-- Resolve um tiles DB genérico: override de env → candidatos existentes → default.
local function resolve_generic_db(env_override, default_name)
    local override = env.get(env_override) or ""
    if override ~= "" then
        local f = io.open(override, "r")
        if f then f:close(); return override, open_tiles_db(override) end
    end
    local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
    local candidates = {
        script_dir .. "../../data/" .. default_name,
        script_dir .. "../data/" .. default_name,
        "data/" .. default_name,
        "/opt/yvy/backend-lua/data/" .. default_name,
    }
    for _, p in ipairs(candidates) do
        local f = io.open(p, "r")
        if f then f:close(); return p, open_tiles_db(p) end
    end
    return nil, nil
end

-- PRODES cache DB — thin wrapper around resolve_generic_db (env override
-- PRODES_TILES_DB first, otherwise existing path candidates). Keeps a targeted
-- warning when the cache is missing. Returns path, db (db nil if missing).
local function open_prodes_db()
    local path, db = resolve_generic_db("PRODES_TILES_DB", "tiles_prodes.db")
    if not path then
        logger.warn("tiles_prodes.db not found — run scripts/cache_prodes_tiles.py first")
    end
    return path, db
end

local function serve_png(ctx, data)
    ctx:set_header("Cache-Control", "public, max-age=2592000, immutable")
    set_cors_headers(ctx)
    ctx:send(200, data, "image/png")
end

-- Shared cache-miss handler: try the nearest cached ANCESTOR tile (keeps the
-- layer visible while the offline warm is mid-flight) with a short max-age;
-- otherwise serve the shared transparent PNG. `try_ancestor=false` (CAR — fully
-- precomputed, no live upstream) skips straight to the empty PNG.
local function serve_miss(ctx, path, db, z, x, y, try_ancestor, empty_max_age)
    if try_ancestor and db then
        local anc = lookup_ancestor(path, db, z, x, y)
        if anc then
            ctx:set_header("Cache-Control", "public, max-age=60")
            ctx:send(200, anc, "image/png")
            return
        end
    end
    ctx:set_header("Cache-Control", "public, max-age=" .. tostring(empty_max_age or 300))
    ctx:send(200, EMPTY_PNG, "image/png")
end

function _M.get_tile(ctx)
    local z = tonumber(ctx.req.args.z)
    local x = tonumber(ctx.req.args.x)
    local y = tonumber(ctx.req.args.y)

    if not z or not x or not y then
        ctx:error(400, "Missing z/x/y params")
        return
    end

    -- 1. Cache lookup
    local path, db = open_prodes_db()
    if db then
        local data = lookup_tile(path, db, z, x, y)
        if data then
            serve_png(ctx, data)
            return
        end
    end

    -- 2. Cache miss: PRODES is a COLD cache, pre-warmed offline by
    -- scripts/cache_prodes_tiles.py (single writer — safe). We never download
    -- or write from the request path: that is what corrupted the DB and froze
    -- the single-threaded loop. Serve the nearest cached ANCESTOR tile first
    -- (the warmer fills low→high zoom, so the parent almost always exists —
    -- this keeps the layer visible while the re-warm is in progress); only if
    -- no ancestor exists (area has no data) serve the transparent PNG. Short
    -- max-age either way so browsers re-request the REAL tile once the warm
    -- has cached it.
    serve_miss(ctx, path, db, z, x, y, true, 60)
end

-- ── CAR precomputed tiles (/api/tiles/car) ──────────────────────────────

-- Path to tiles_car.db. Env override (CAR_TILES_DB) first — lets tests/ops
-- point elsewhere; otherwise resolve like PRODES (existing-file candidates).
local CAR_TILES_DB = env.get("CAR_TILES_DB") or ""
if CAR_TILES_DB == "" then
    local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
    local candidates = {
        script_dir .. "../../data/tiles_car.db",
        script_dir .. "../data/tiles_car.db",
        "data/tiles_car.db",
        "/opt/yvy/backend-lua/data/tiles_car.db",
    }
    for _, p in ipairs(candidates) do
        local f = io.open(p, "r")
        if f then f:close(); CAR_TILES_DB = p; break end
    end
    if CAR_TILES_DB == "" then CAR_TILES_DB = "backend-lua/data/tiles_car.db" end
end

-- Serves precomputed CAR tiles from tiles_car.db. No live upstream (fully
-- precomputed); cache miss returns the shared transparent PNG.
function _M.get_tile_car(ctx)
    local z = tonumber(ctx.req.args.z)
    local x = tonumber(ctx.req.args.x)
    local y = tonumber(ctx.req.args.y)

    if not z or not x or not y then
        ctx:error(400, "Missing z/x/y params")
        return
    end

    local db = open_tiles_db(CAR_TILES_DB)
    if db then
        local data = lookup_tile(CAR_TILES_DB, db, z, x, y)
        if data then
            serve_png(ctx, data)
            return
        end
    end

    -- Cache miss: CAR is fully precomputed (no live upstream to backfill) —
    -- no ancestor fallback, transparent PNG (graceful).
    serve_miss(ctx, CAR_TILES_DB, db, z, x, y, false, 300)
end

-- ── Cerrado vegetation tiles (plan: terrabrasilis-integration, Inc 9)
--
-- Same cold-cache invariant as PRODES/CAR: DB pre-warmed offline by a single
-- Python writer (scripts/data/download_cerrado_veg.py); runtime is read-only
-- (query_only=ON via open_tiles_db). Env override (CERRADO_VEG_TILES_DB) lets
-- ops/tests point elsewhere.

-- Servidor genérico de tile para um DB de tiles (chave z,x,y).
local function serve_layer_tile(ctx, env_override, default_name)
    local z = tonumber(ctx.req.args.z)
    local x = tonumber(ctx.req.args.x)
    local y = tonumber(ctx.req.args.y)
    if not z or not x or not y then
        ctx:error(400, "Missing z/x/y params")
        return
    end

    local path, db = resolve_generic_db(env_override, default_name)
    if db then
        local data = lookup_tile(path, db, z, x, y)
        if data then
            serve_png(ctx, data)
            return
        end
    end

    -- Cache miss: same ancestor-then-empty policy as PRODES.
    serve_miss(ctx, path, db, z, x, y, true, 300)
end

-- /api/tiles/cerrado-veg?z=&x=&y= — tiles_cerrado_veg.db chave (z,x,y).
function _M.get_tile_cerrado_veg(ctx)
    serve_layer_tile(ctx, "CERRADO_VEG_TILES_DB", "tiles_cerrado_veg.db")
end

return _M

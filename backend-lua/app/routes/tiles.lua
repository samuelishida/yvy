-- tiles.lua — /api/tiles/prodes + /api/tiles/car
-- Serves PRODES WMS tiles and precomputed CAR tiles from local SQLite caches.
--
-- COLD-CACHE INVARIANT: tiles_prodes.db / tiles_car.db are pre-warmed OFFLINE
-- by scripts/cache_prodes_tiles.py (single writer, one connection — safe). The
-- backend opens them READ-ONLY and NEVER writes or spawns on-demand writers:
-- concurrent multi-process INSERTs from separate workers corrupted the DB
-- ("database disk image is malformed" → 500s). Miss → transparent PNG only.

local sqlite3     = require("lsqlite3")
local logger      = require("app.logger")
local env         = require("app.env")

local _M = {}
-- Per-path cached connections (never open per request — 256-tile bursts).
local _dbs = {}

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
    -- READ-ONLY: this process must never write to a cold cache. Concurrent
    -- writers from multiple processes are what corrupted tiles_prodes.db.
    local db, err = sqlite3.open(path, sqlite3.OPEN_READONLY)
    if not db then
        logger.warn("Tiles DB open (read-only) failed for " .. path .. ": " .. tostring(err))
        return nil
    end
    -- No journal_mode PRAGMA: setting WAL requires a write handle. The DB is
    -- already WAL from the offline warmer; read-only WAL reads are fine.
    db:exec("PRAGMA busy_timeout=5000")
    db:exec("PRAGMA cache_size=-4000")
    _dbs[path] = db
    logger.info("Tiles DB opened read-only: " .. path)
    return db
end

-- PRODES cache DB (existing path candidates; lazy proxy on miss).
local function open_prodes_db()
    local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
    local candidates = {
        script_dir .. "../../data/tiles_prodes.db",
        script_dir .. "../data/tiles_prodes.db",
        "data/tiles_prodes.db",
        "/opt/yvy/backend-lua/data/tiles_prodes.db",
    }
    local path
    for _, p in ipairs(candidates) do
        local f = io.open(p, "r")
        if f then f:close(); path = p; break end
    end
    if not path then
        logger.warn("tiles_prodes.db not found — run scripts/cache_prodes_tiles.py first")
        return nil
    end
    return open_tiles_db(path)
end

local function serve_png(ctx, data)
    ctx:set_header("Cache-Control", "public, max-age=2592000, immutable")
    ctx:set_header("Access-Control-Allow-Origin", "*")
    ctx:send(200, data, "image/png")
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
    local db = open_prodes_db()
    if db then
        local stmt = db:prepare("SELECT data FROM tiles WHERE z=? AND x=? AND y=?")
        if stmt then
            stmt:bind(1, z); stmt:bind(2, x); stmt:bind(3, y)
            for row in stmt:nrows() do
                local data = row.data
                stmt:finalize()
                serve_png(ctx, data)
                return
            end
            stmt:finalize()
        end
    end

    -- 2. Cache miss: PRODES is a COLD cache, pre-warmed offline by
    -- scripts/cache_prodes_tiles.py (single writer — safe). We never download
    -- or write from the request path: that is what corrupted the DB and froze
    -- the single-threaded loop. Serve the transparent PNG; the tile appears
    -- once the offline warmer has cached it. Short max-age so browsers
    -- re-request (and pick up the real tile) after a re-warm.
    ctx:set_header("Cache-Control", "public, max-age=60")
    ctx:send(200, EMPTY_PNG, "image/png")
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
        local stmt = db:prepare("SELECT data FROM tiles WHERE z=? AND x=? AND y=?")
        if stmt then
            stmt:bind(1, z); stmt:bind(2, x); stmt:bind(3, y)
            for row in stmt:nrows() do
                local data = row.data
                stmt:finalize()
                serve_png(ctx, data)
                return
            end
            stmt:finalize()
        end
    end

    -- Cache miss: no upstream to backfill — transparent PNG (graceful).
    ctx:set_header("Cache-Control", "public, max-age=300")
    ctx:send(200, EMPTY_PNG, "image/png")
end

return _M

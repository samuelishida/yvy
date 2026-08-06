-- tools/warm_prodes_tiles.lua — detached subprocess that fetches a single
-- PRODES tile from the TerraBrasilis WMS and caches it in tiles_prodes.db.
--
-- WHY: the backend is a single-threaded copas loop. The old tiles.lua code
-- did a synchronous `os.execute(curl ...)` (up to 20s) on a cache miss. A
-- browser zoom/pan burst (30-60 misses × ~2s each) serialized those
-- downloads and froze the whole API; the C frontend then hit its
-- MAX_CHILDREN cap and returned 503 "Server busy" for every tile. Mirroring
-- news_sync.lua / warm_ti_at_risk.lua, the fetch now runs detached
-- (nohup ... &) and the HTTP route returns the transparent PNG immediately
-- — the event loop never blocks, and the tile appears on the next request
-- once it is cached here.
--
-- Usage: lua5.1 tools/warm_prodes_tiles.lua <z> <x> <y>

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local backend_dir = script_dir:gsub("[\\/]tools[\\/]$", "/")
package.path = backend_dir .. "?.lua;" .. backend_dir .. "?/init.lua;" .. package.path

local env = require("app.env")
env.load_dotenv(backend_dir .. "../.env")
env.load_dotenv(backend_dir .. ".env")

local sqlite3     = require("lsqlite3")
local http_client = require("app.http_client")
local logger      = require("app.logger")
local redis       = require("app.redis")
local socket      = require("socket")

local z = tonumber(arg and arg[1])
local x = tonumber(arg and arg[2])
local y = tonumber(arg and arg[3])
if not z or not x or not y then
    logger.error("warm_prodes_tiles: usage: lua5.1 tools/warm_prodes_tiles.lua <z> <x> <y>")
    os.exit(1)
end

-- Per-tile lock so concurrent misses for the same tile don't re-download.
-- setnx returns true when Redis is down, so we degrade gracefully to no lock.
local tile_lock = string.format("tiles:prodes:dl:%d:%d:%d", z, x, y)
if not redis.setnx(tile_lock, "1", 120) then
    os.exit(0)  -- another fetch is already in flight
end

-- Global concurrency cap: a zoom/pan burst can spawn 30-60 workers at once.
-- Cap how many fetch concurrently so we don't stampede TerraBrasilis or
-- contend on the SQLite writer. Overflow workers wait (bounded) for a free
-- slot instead of exiting, so a single burst still warms every tile while
-- upstream concurrency never exceeds MAX_CONCURRENT. Slot-based setnx;
-- Redis-down degrades to no cap (all workers proceed immediately).
local MAX_CONCURRENT = 8
local SLOT_WAIT_SECONDS = 40
local slot_key
local deadline = os.time() + SLOT_WAIT_SECONDS
while os.time() < deadline do
    for i = 0, MAX_CONCURRENT - 1 do
        local k = "tiles:prodes:inflight:" .. i
        if redis.setnx(k, "1", 120) then
            slot_key = k
            break
        end
    end
    if slot_key then break end
    socket.sleep(0.5)
end
if not slot_key then
    redis.delete(tile_lock)  -- let a later re-request take this tile
    os.exit(0)               -- waited too long; browser re-requests later
end

local ok, err = pcall(function()

    -- Resolve tiles_prodes.db (same candidates as app/routes/tiles.lua).
    local candidates = {
        backend_dir .. "data/tiles_prodes.db",
        "data/tiles_prodes.db",
        "/opt/yvy/backend-lua/data/tiles_prodes.db",
    }
    local db_path
    for _, p in ipairs(candidates) do
        local f = io.open(p, "r")
        if f then f:close(); db_path = p; break end
    end
    if not db_path then
        error("tiles_prodes.db not found — run scripts/cache_prodes_tiles.py first")
    end

    -- Same WMS request the route used to build inline.
    local n = 2 ^ z
    local lon_min = x / n * 360 - 180
    local lon_max = (x + 1) / n * 360 - 180
    local lat_max = math.atan(math.sinh(math.pi * (1 - 2 * y / n))) * 180 / math.pi
    local lat_min = math.atan(math.sinh(math.pi * (1 - 2 * (y + 1) / n))) * 180 / math.pi
    local wms_url = string.format(
        "https://terrabrasilis.dpi.inpe.br/geoserver/prodes-brasil-nb/prodes_brasil/wms"
        .. "?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap"
        .. "&BBOX=%.6f,%.6f,%.6f,%.6f&SRS=EPSG%%3A4326"
        .. "&WIDTH=256&HEIGHT=256&LAYERS=prodes_brasil"
        .. "&FORMAT=image%%2Fpng&TRANSPARENT=TRUE",
        lon_min, lat_min, lon_max, lat_max)

    -- Download to a temp file (binary-safe), with retries to ride out
    -- transient upstream throttling under load.
    local tmp = (os.getenv("TEMP") or os.getenv("TMP") or ".")
        .. "/yvy_tile_" .. z .. "_" .. x .. "_" .. y .. "_" .. tostring(os.time()) .. ".png"
    local got
    for attempt = 1, 3 do
        got = http_client.download(wms_url, tmp, 20)
        if got then break end
        if attempt < 3 then socket.sleep(attempt) end
    end
    if not got then
        error(string.format("download failed for %d/%d/%d", z, x, y))
    end

    local f = io.open(tmp, "rb")
    local data = f and f:read("*a")
    if f then f:close() end
    os.remove(tmp)

    if not data or #data <= 8 or data:sub(1, 4) ~= "\137PNG" then
        error(string.format("invalid PNG for %d/%d/%d", z, x, y))
    end

    -- Cache it. busy_timeout lets concurrent workers wait for the writer
    -- instead of failing immediately with SQLITE_BUSY.
    local db = sqlite3.open(db_path)
    db:exec("PRAGMA journal_mode=WAL")
    db:exec("PRAGMA busy_timeout=5000")
    local ins = db:prepare(
        "INSERT OR REPLACE INTO tiles (z,x,y,data,content_type,fetched_at) VALUES (?,?,?,?,?,?)"
    )
    if ins then
        ins:bind(1, z); ins:bind(2, x); ins:bind(3, y)
        ins:bind_blob(4, data); ins:bind(5, "image/png")
        ins:bind(6, os.date("!%Y-%m-%dT%H:%M:%SZ"))
        ins:step(); ins:finalize()
    end
    db:close()

    logger.info(string.format("warm_prodes_tiles: cached %d/%d/%d (%d bytes)", z, x, y, #data))
end)

-- Release the concurrency slot and the per-tile lock (TTLs also clean up on
-- crash). Both are released on success AND failure: on success the tile is
-- cached, on failure a later re-request should be allowed to retry.
redis.delete(slot_key)
redis.delete(tile_lock)

if not ok then
    logger.warn("warm_prodes_tiles: worker failed: " .. tostring(err))
    os.exit(1)
end

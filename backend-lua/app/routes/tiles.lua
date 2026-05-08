-- tiles.lua — /api/tiles/prodes
-- Serves PRODES WMS tiles from local SQLite cache.
-- On cache miss, proxies to TerraBrasilis WMS and caches the PNG.

local sqlite3     = require("lsqlite3")
local http_client = require("app.http_client")
local logger      = require("app.logger")

local _M = {}
local _db = nil

local WMS_BASE = "https://terrabrasilis.dpi.inpe.br/geoserver/prodes-brasil-nb/prodes_brasil/wms"

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

local function open_db()
    if _db then return _db end
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
    local db = sqlite3.open(path)
    db:exec("PRAGMA journal_mode=WAL")
    db:exec("PRAGMA cache_size=-4000")
    _db = db
    logger.info("Tiles DB opened: " .. path)
    return _db
end

local function tile_to_bbox(z, x, y)
    local n = 2 ^ z
    local lon_min = x / n * 360 - 180
    local lon_max = (x + 1) / n * 360 - 180
    local lat_max = math.atan(math.sinh(math.pi * (1 - 2 * y / n))) * 180 / math.pi
    local lat_min = math.atan(math.sinh(math.pi * (1 - 2 * (y + 1) / n))) * 180 / math.pi
    return lon_min, lat_min, lon_max, lat_max
end

local function serve_png(ctx, data)
    ctx:set_header("Cache-Control", "public, max-age=86400")
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
    local db = open_db()
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

    -- 2. Cache miss: fetch from TerraBrasilis WMS, save to temp file (binary-safe)
    local lon_min, lat_min, lon_max, lat_max = tile_to_bbox(z, x, y)
    local wms_url = string.format(
        "%s?SERVICE=WMS&VERSION=1.1.1&REQUEST=GetMap"
        .. "&BBOX=%.6f,%.6f,%.6f,%.6f&SRS=EPSG%%3A4326"
        .. "&WIDTH=256&HEIGHT=256&LAYERS=prodes_brasil"
        .. "&FORMAT=image%%2Fpng&TRANSPARENT=TRUE",
        WMS_BASE, lon_min, lat_min, lon_max, lat_max
    )

    local tmp = (os.getenv("TEMP") or os.getenv("TMP") or ".") .. "/yvy_tile_" .. z .. "_" .. x .. "_" .. y .. ".png"
    local ok = http_client.download(wms_url, tmp, 20)
    local data
    if ok then
        local f = io.open(tmp, "rb")
        if f then
            data = f:read("*a")
            f:close()
            os.remove(tmp)
        end
    end

    -- 3. Validate PNG magic bytes; cache and serve
    if data and #data > 8 and data:sub(1, 4) == "\137PNG" then
        if db then
            local ins = db:prepare(
                "INSERT OR REPLACE INTO tiles (z,x,y,data,content_type,fetched_at) VALUES (?,?,?,?,?,?)"
            )
            if ins then
                ins:bind(1, z); ins:bind(2, x); ins:bind(3, y)
                ins:bind_blob(4, data); ins:bind(5, "image/png")
                ins:bind(6, os.date("!%Y-%m-%dT%H:%M:%SZ"))
                ins:step(); ins:finalize()
            end
        end
        serve_png(ctx, data)
    else
        ctx:set_header("Cache-Control", "public, max-age=300")
        ctx:send(200, EMPTY_PNG, "image/png")
    end
end

return _M

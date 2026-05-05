-- fires.lua — /api/fires, /api/fires/sync, /api/admin/firms/sync
-- Baremetal Lua version using ctx-based request/response

local db         = require("app.db")
local auth       = require("app.auth")
local rl         = require("app.rate_limit")
local redis      = require("app.redis")
local utils      = require("app.utils")
local http_client = require("app.http_client")
local cjson      = require("cjson")
local logger     = require("app.logger")

local _M = {}

local FIRMS_MAP_KEY = os.getenv("FIRMS_MAP_KEY") or ""
local FIRMS_SOURCE = os.getenv("FIRMS_SOURCE") or "VIIRS_SNPP_NRT"
local FIRMS_DAY_RANGE = tonumber(os.getenv("FIRMS_DAY_RANGE") or "3")
local FIRMS_BBOX = "-74,-34,-34,5.5"
local MAX_RESULTS = tonumber(os.getenv("MAX_RESULTS_PER_REQUEST") or "10000")

local GLOBAL_BBOXES = {
    "-180,-90,-90,90",
    "-90,-90,0,90",
    "0,-90,90,90",
    "90,-90,180,90",
}

-- ── GET /api/fires ───────────────────────────────────────────────────────

function _M.get_fires(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local args = ctx.req.args
    local ne_lat = args.ne_lat
    local ne_lng = args.ne_lng
    local sw_lat = args.sw_lat
    local sw_lng = args.sw_lng

    local cache_key = "fires:" .. (ne_lat or "global") .. ":" .. (ne_lng or "") .. ":" .. (sw_lat or "") .. ":" .. (sw_lng or "")

    local cached = redis.get(cache_key)
    if cached then
        ctx:send(200, cached)
        return
    end

    if ne_lat and ne_lng and sw_lat and sw_lng then
        ne_lat = tonumber(ne_lat); ne_lng = tonumber(ne_lng)
        sw_lat = tonumber(sw_lat); sw_lng = tonumber(sw_lng)
        if not ne_lat or not ne_lng or not sw_lat or not sw_lng then
            ctx:error(400, "Invalid coordinates."); return
        end
        if ne_lat <= sw_lat or ne_lng <= sw_lng then
            ctx:error(400, "Invalid bbox."); return
        end
    else
        sw_lat, ne_lat, sw_lng, ne_lng = -90, 90, -180, 180
    end

    local data = db.find_fires(sw_lat, ne_lat, sw_lng, ne_lng, MAX_RESULTS)
    local last_sync = redis.get("fires:last_sync")

    local response = cjson.encode({fires = data, last_sync = last_sync})
    redis.set(cache_key, response, 60)
    ctx:send(200, response)
end

-- ── FIRMS data fetch ─────────────────────────────────────────────────────

function _M.fetch_firms_data(global_sync)
    if FIRMS_MAP_KEY == "" then
        logger.warn("FIRMS_MAP_KEY not configured, skipping fire data sync")
        return 0
    end

    local bboxes = global_sync and GLOBAL_BBOXES or {FIRMS_BBOX}
    local total_count = 0

    for _, bbox in ipairs(bboxes) do
        local url = "https://firms.modaps.eosdis.nasa.gov/api/area/csv/"
            .. FIRMS_MAP_KEY .. "/" .. FIRMS_SOURCE .. "/" .. bbox .. "/" .. FIRMS_DAY_RANGE

        logger.info("Fetching FIRMS fire data: " .. url)
        local res, err = http_client.get(url, {timeout = 60})
        if not res then
            logger.error("FIRMS fetch error: " .. tostring(err))
            goto continue
        end
        if res.status ~= 200 then
            logger.error("FIRMS API returned " .. res.status)
            goto continue
        end

        local docs = utils.parse_csv(res.body)
        local fire_docs = {}
        for _, row in ipairs(docs) do
            local lat = tonumber(row.latitude or row["latitude"])
            local lon = tonumber(row.longitude or row["longitude"])
            if lat and lon and lat >= -90 and lat <= 90 and lon >= -180 and lon <= 180 then
                fire_docs[#fire_docs + 1] = {
                    lat = lat, lon = lon,
                    confidence = (row.confidence or row["confidence"] or "low"):lower(),
                    acq_date = row.acq_date or row["acq_date"] or "",
                    acq_time = row.acq_time or row["acq_time"] or "",
                    satellite = row.satellite or row["satellite"] or "",
                    bright_ti4 = tonumber(row.bright_ti4 or row["bright_ti4"] or 0) or 0,
                    source = "NASA_FIRMS_VIIRS_SNPP",
                    ingested_at = utils.now_iso(),
                }
            end
        end

        if #fire_docs > 0 then db.bulk_upsert_fires(fire_docs) end
        total_count = total_count + #fire_docs
        ::continue::
    end

    redis.set("fires:last_sync", utils.now_iso(), 3600)
    redis.delete("fires:*")
    logger.info("FIRMS sync complete: " .. total_count .. " records")
    return total_count
end

-- ── POST /api/fires/sync ─────────────────────────────────────────────────

function _M.sync_fires(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local global_sync = ctx.req.args["global"] == "1"
    local count = _M.fetch_firms_data(global_sync)
    ctx:json(200, {status = "synced", records = count, global = global_sync})
end

-- ── POST /api/admin/firms/sync ───────────────────────────────────────────

function _M.admin_firms_sync(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    logger.info("Manual FIRMS sync triggered")
    local count = _M.fetch_firms_data(false)
    local last_sync = redis.get("fires:last_sync")
    ctx:json(200, {
        status = "success",
        message = "FIRMS sync completed. " .. count .. " records processed.",
        records = count, last_sync = last_sync,
    })
end

return _M


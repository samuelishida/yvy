-- rate_limit.lua — Rate limiting middleware for baremetal Lua server
-- Uses Redis (via redis.lua) with in-memory fallback

local redis_mod = require("app.redis")
local socket = require("socket")
local logger = require("app.logger")

local _M = {}

local RATE_LIMIT_REQUESTS = tonumber(os.getenv("RATE_LIMIT_REQUESTS") or "60")
local RATE_LIMIT_WINDOW_SECONDS = tonumber(os.getenv("RATE_LIMIT_WINDOW_SECONDS") or "60")

-- In-memory fallback buckets
local buckets = {}

function _M.enforce(ctx)
    """Check rate limit. Calls ctx:error(429) if exceeded. Returns true if ok."""
    local client_ip = ctx.req.remote_addr or "unknown"

    -- Try Redis first
    local limited = redis_mod.check_rate_limit(client_ip, RATE_LIMIT_REQUESTS, RATE_LIMIT_WINDOW_SECONDS)
    if limited then
        logger.warn("Rate limit exceeded for " .. client_ip)
        ctx:error(429, "Rate limit exceeded. Please retry later.")
        return false
    end

    -- In-memory fallback
    local now = socket.gettime()
    if not buckets[client_ip] then buckets[client_ip] = {} end
    local bucket = buckets[client_ip]

    local i = 1
    while i <= #bucket do
        if bucket[i] < now - RATE_LIMIT_WINDOW_SECONDS then
            table.remove(bucket, i)
        else
            i = i + 1
        end
    end

    if #bucket >= RATE_LIMIT_REQUESTS then
        logger.warn("Rate limit exceeded (memory) for " .. client_ip)
        ctx:error(429, "Rate limit exceeded. Please retry later.")
        return false
    end

    bucket[#bucket + 1] = now
    return true
end

return _M


require("app.env")
local redis_mod = require("app.redis")
local socket = require("socket")
local logger = require("app.logger")

local _M = {}

local RATE_LIMIT_REQUESTS = tonumber(os.getenv("RATE_LIMIT_REQUESTS") or "60")
local RATE_LIMIT_WINDOW_SECONDS = tonumber(os.getenv("RATE_LIMIT_WINDOW_SECONDS") or "60")

-- In-memory fallback with LRU cleanup
local buckets = {}
local MAX_BUCKETS = 10000  -- Prevent unbounded growth

-- Periodic cleanup to prevent memory leak
local function cleanup_buckets()
    local now = socket.gettime()
    local count = 0
    for ip, bucket in pairs(buckets) do
        local i = 1
        while i <= #bucket do
            if bucket[i] < now - RATE_LIMIT_WINDOW_SECONDS then
                table.remove(bucket, i)
            else
                i = i + 1
            end
        end
        if #bucket == 0 then
            buckets[ip] = nil
            count = count + 1
        end
    end
    if count > 0 then
        logger.debug("Cleaned up " .. count .. " empty rate limit buckets")
    end
end

-- Cleanup every 5 minutes
if package.loaded.copas then
    local copas = require("copas")
    copas.addthread(function()
        while true do
            copas.sleep(300)
            cleanup_buckets()
        end
    end)
end

function _M.enforce(ctx)
    local client_ip = ctx.req.remote_addr or "unknown"

    local limited = redis_mod.check_rate_limit(client_ip, RATE_LIMIT_REQUESTS, RATE_LIMIT_WINDOW_SECONDS)
    if limited then
        logger.warn("Rate limit exceeded for " .. client_ip)
        ctx:error(429, "Rate limit exceeded. Please retry later.")
        return false
    end

    -- In-memory fallback (Redis might be down)
    local now = socket.gettime()
    if not buckets[client_ip] then
        if #buckets >= MAX_BUCKETS then
            cleanup_buckets()  -- Force cleanup if at limit
            if #buckets >= MAX_BUCKETS then
                logger.warn("Rate limit bucket table full, rejecting request")
                ctx:error(503, "Service temporarily unavailable")
                return false
            end
        end
        buckets[client_ip] = {}
    end
    local bucket = buckets[client_ip]

    -- Remove expired entries
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

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

-- Resolve the real client IP from trusted proxy headers. nginx (prod) sets
-- X-Real-IP and X-Forwarded-For on every /api request; the C dev server sets
-- them the same way. The backend only listens on 127.0.0.1, so only the proxy
-- can write these headers — clients can't spoof them. X-Forwarded-For's LAST
-- entry is the one appended by the last trusted proxy; earlier entries are
-- client-controlled.
local function real_client_ip(ctx)
    local headers = ctx.req.headers or {}

    local xri = headers["x-real-ip"]
    if xri and xri ~= "" then
        return xri:gsub("^%s+", ""):gsub("%s+$", "")
    end

    local xff = headers["x-forwarded-for"]
    if xff and xff ~= "" then
        local last
        for entry in xff:gmatch("[^,]+") do
            last = entry:gsub("^%s+", ""):gsub("%s+$", "")
        end
        if last and last ~= "" then
            return last
        end
    end

    return ctx.req.remote_addr or "unknown"
end

-- Local/private traffic is trusted infrastructure, not an abuse vector: in
-- dev every request arrives via the C server as 127.0.0.1 (and LAN clients
-- as private ranges), and health checks / polling would otherwise share one
-- tiny bucket. Skip rate limiting for it. In prod, nginx forwards the real
-- client IP via X-Real-IP, which is public for external users — those ARE
-- limited per client.
local function is_private_ip(ip)
    if not ip or ip == "" then return true end
    if ip == "127.0.0.1" or ip == "::1" or ip == "localhost" or ip == "unknown" then
        return true
    end
    local a, b = ip:match("^(%d+)%.(%d+)")
    if a then
        a, b = tonumber(a), tonumber(b)
        if a == 10 then return true end
        if a == 127 then return true end
        if a == 172 and b >= 16 and b <= 31 then return true end
        if a == 192 and b == 168 then return true end
        if a == 169 and b == 254 then return true end
    end
    return false
end

function _M.enforce(ctx)
    local client_ip = real_client_ip(ctx)

    if is_private_ip(client_ip) then
        return true  -- trusted local/private traffic: not rate limited
    end

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

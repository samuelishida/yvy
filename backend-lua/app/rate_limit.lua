-- rate_limit.lua — Rate limiting middleware
-- Uses Redis (via redis.lua) with in-memory fallback

local redis_mod = require("app.redis")

local _M = {}

local RATE_LIMIT_REQUESTS = tonumber(os.getenv("RATE_LIMIT_REQUESTS") or "60")
local RATE_LIMIT_WINDOW_SECONDS = tonumber(os.getenv("RATE_LIMIT_WINDOW_SECONDS") or "60")

-- In-memory fallback buckets (per-worker, not shared across workers)
local buckets = {}

function _M.enforce()
    """Check rate limit for current request. Calls ngx.exit(429) if exceeded."""
    local client_ip = ngx.var.remote_addr or "unknown"

    -- Try Redis first
    local limited = redis_mod.check_rate_limit(client_ip, RATE_LIMIT_REQUESTS, RATE_LIMIT_WINDOW_SECONDS)
    if limited then
        ngx.log(ngx.WARN, "Rate limit exceeded for ", client_ip)
        ngx.status = 429
        ngx.say('{"error":"Rate limit exceeded. Please retry later."}')
        ngx.exit(429)
    end

    -- In-memory fallback (if Redis was down, check_rate_limit returned false)
    -- We still track locally to avoid total free-for-all
    local now = ngx.now()
    if not buckets[client_ip] then
        buckets[client_ip] = {}
    end

    local bucket = buckets[client_ip]
    -- Remove old entries
    local i = 1
    while i <= #bucket do
        if bucket[i] < now - RATE_LIMIT_WINDOW_SECONDS then
            table.remove(bucket, i)
        else
            i = i + 1
        end
    end

    if #bucket >= RATE_LIMIT_REQUESTS then
        ngx.log(ngx.WARN, "Rate limit exceeded (memory fallback) for ", client_ip)
        ngx.status = 429
        ngx.say('{"error":"Rate limit exceeded. Please retry later."}')
        ngx.exit(429)
    end

    bucket[#bucket + 1] = now
end

return _M

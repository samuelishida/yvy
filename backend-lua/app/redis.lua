-- redis.lua — Redis cache helpers
-- Port of backend/backend.py cache_get/cache_set/cache_delete
-- Uses lua-resty-redis with connection pooling via ngx.shared.DICT

local redis = require("resty.redis")
local cjson = require("cjson")

local _M = {}

local REDIS_URL = os.getenv("REDIS_URL") or "redis://127.0.0.1:6379/0"
local CACHE_TTL_DEFAULT = 300

-- Parse redis://host:port/db
local function parse_redis_url(url)
    local host, port, db = "127.0.0.1", 6379, 0
    local h, p, d = url:match("redis://([^:]+):(%d+)/(%d+)")
    if h then
        host = h
        port = tonumber(p) or 6379
        db = tonumber(d) or 0
    else
        h, p = url:match("redis://([^:]+):(%d+)")
        if h then
            host = h
            port = tonumber(p) or 6379
        end
    end
    return host, port, db
end

local redis_host, redis_port, redis_db = parse_redis_url(REDIS_URL)

-- Connection pool key
local POOL_KEY = "redis_pool"

local function get_conn()
    local red = redis:new()
    red:set_timeout(5000)  -- 5s

    local ok, err = red:connect(redis_host, redis_port)
    if not ok then
        ngx.log(ngx.WARN, "Redis connect failed: ", err)
        return nil
    end

    if redis_db > 0 then
        red:select(redis_db)
    end

    return red
end

local function close_conn(red)
    if red then
        red:set_keepalive(60000, 10)  -- 60s idle, max 10 in pool
    end
end

function _M.get(key)
    local red = get_conn()
    if not red then return nil end

    local val, err = red:get(key)
    close_conn(red)

    if not val or val == ngx.null then
        return nil
    end
    return val
end

function _M.set(key, value, ttl)
    ttl = ttl or CACHE_TTL_DEFAULT
    local red = get_conn()
    if not red then return end

    red:setex(key, ttl, value)
    close_conn(red)
end

function _M.delete(pattern)
    """Delete keys matching pattern using SCAN."""
    local red = get_conn()
    if not red then return end

    local cursor = "0"
    repeat
        local res, err = red:scan(cursor, "MATCH", pattern, "COUNT", 100)
        if not res then break end
        cursor = res[1]
        local keys = res[2]
        if keys and #keys > 0 then
            for _, k in ipairs(keys) do
                red:del(k)
            end
        end
    until cursor == "0"

    close_conn(red)
end

-- ── Rate limiting via Redis sorted sets ──────────────────────────────────

function _M.check_rate_limit(ip, limit, window_seconds)
    """Check if IP has exceeded rate limit using sorted set.
    Returns true if rate limited, false if allowed.
    """
    limit = limit or 60
    window_seconds = window_seconds or 60

    local red = get_conn()
    if not red then return false end  -- Allow if Redis down

    local key = "rate_limit:" .. ip
    local now = ngx.now()

    -- Remove old entries
    red:zremrangebyscore(key, 0, now - window_seconds)

    -- Count current
    local count, err = red:zcard(key)
    if not count then
        close_conn(red)
        return false
    end

    if tonumber(count) >= limit then
        close_conn(red)
        return true
    end

    -- Add current request
    red:zadd(key, now, tostring(now) .. "_" .. tostring(math.random(1000000)))
    red:expire(key, window_seconds)
    close_conn(red)
    return false
end

return _M

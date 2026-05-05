-- redis.lua — Redis cache helpers for baremetal Lua
-- Uses luasocket TCP + Redis RESP protocol
-- Replaces lua-resty-redis

local socket = require("socket")
local logger = require("app.logger")

local _M = {}

local REDIS_URL = os.getenv("REDIS_URL") or "redis://127.0.0.1:6379/0"
local CACHE_TTL_DEFAULT = 300

-- Parse redis://host:port/db
local function parse_redis_url(url)
    local host, port, db = "127.0.0.1", 6379, 0
    local h, p, d = url:match("redis://([^:]+):(%d+)/(%d+)")
    if h then
        host = h; port = tonumber(p) or 6379; db = tonumber(d) or 0
    else
        h, p = url:match("redis://([^:]+):(%d+)")
        if h then host = h; port = tonumber(p) or 6379 end
    end
    return host, port, db
end

local redis_host, redis_port, redis_db = parse_redis_url(REDIS_URL)

-- ── RESP protocol helpers ────────────────────────────────────────────────

local function connect()
    local s = socket.tcp()
    s:settimeout(5)
    local ok, err = s:connect(redis_host, redis_port)
    if not ok then
        logger.warn("Redis connect failed: " .. tostring(err))
        return nil
    end
    if redis_db > 0 then
        s:send("*2\r\n$6\r\nSELECT\r\n$" .. #tostring(redis_db) .. "\r\n" .. redis_db .. "\r\n")
        s:receive("*l")  -- consume +OK
    end
    return s
end

local function command(s, ...)
    local args = {...}
    local parts = {"*" .. #args .. "\r\n"}
    for _, arg in ipairs(args) do
        local a = tostring(arg)
        parts[#parts + 1] = "$" .. #a .. "\r\n" .. a .. "\r\n"
    end
    s:send(table.concat(parts))
end

local function read_response(s)
    local line = s:receive("*l")
    if not line then return nil end
    local prefix = line:sub(1, 1)
    if prefix == "+" then
        return line:sub(2)
    elseif prefix == "-" then
        return nil, line:sub(2)
    elseif prefix == ":" then
        return tonumber(line:sub(2))
    elseif prefix == "$" then
        local len = tonumber(line:sub(2))
        if len < 0 then return nil end
        local data = s:receive(len)
        s:receive("*l")  -- consume trailing \r\n
        return data
    elseif prefix == "*" then
        local count = tonumber(line:sub(2))
        if count < 0 then return nil end
        local result = {}
        for i = 1, count do
            result[i] = read_response(s)
        end
        return result
    end
    return nil
end

-- ── Public API ───────────────────────────────────────────────────────────

function _M.get(key)
    local s = connect()
    if not s then return nil end
    command(s, "GET", key)
    local val = read_response(s)
    s:close()
    return val
end

function _M.set(key, value, ttl)
    ttl = ttl or CACHE_TTL_DEFAULT
    local s = connect()
    if not s then return end
    command(s, "SETEX", key, ttl, value)
    read_response(s)
    s:close()
end

function _M.delete(pattern)
    local s = connect()
    if not s then return end
    local cursor = "0"
    repeat
        command(s, "SCAN", cursor, "MATCH", pattern, "COUNT", "100")
        local res = read_response(s)
        if not res or #res < 2 then break end
        cursor = res[1]
        local keys = res[2]
        if keys and #keys > 0 then
            for _, k in ipairs(keys) do
                command(s, "DEL", k)
                read_response(s)
            end
        end
    until cursor == "0"
    s:close()
end

-- ── Rate limiting via sorted sets ────────────────────────────────────────

function _M.check_rate_limit(ip, limit, window_seconds)
    limit = limit or 60
    window_seconds = window_seconds or 60
    local now = socket.gettime()

    local s = connect()
    if not s then return false end  -- Allow if Redis down

    local key = "rate_limit:" .. ip

    -- Remove old entries
    command(s, "ZREMRANGEBYSCORE", key, "0", tostring(now - window_seconds))
    read_response(s)

    -- Count current
    command(s, "ZCARD", key)
    local count = read_response(s)
    if not count then s:close(); return false end

    if tonumber(count) >= limit then
        s:close()
        return true
    end

    -- Add current request
    local member = tostring(now) .. "_" .. tostring(math.random(1000000))
    command(s, "ZADD", key, tostring(now), member)
    read_response(s)
    command(s, "EXPIRE", key, tostring(window_seconds))
    read_response(s)

    s:close()
    return false
end

return _M


require("app.env")
local logger = require("app.logger")

local _M = {}

local AUTH_REQUIRED = (os.getenv("AUTH_REQUIRED") or "1") == "1"
local API_KEY = os.getenv("API_KEY") or ""

-- Constant-time string comparison to prevent timing attacks
local function secure_compare(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then
        return false
    end
    if #a ~= #b then
        -- Still do work proportional to length to avoid timing leak
        local dummy = 0
        for i = 1, math.max(#a, #b) do
            dummy = dummy + 1
        end
        return false
    end
    local mismatch = false
    for i = 1, #a do
        if string.byte(a, i) ~= string.byte(b, i) then
            mismatch = true
        end
    end
    return not mismatch
end

function _M.enforce(ctx)
    -- Trust requests from localhost (nginx proxy; API key injected server-side)
    local remote = ctx.req.remote_addr or ""
    if remote == "127.0.0.1" or remote == "::1" then
        return true
    end

    if not AUTH_REQUIRED then
        return true
    end

    if API_KEY == "" then
        logger.error("API key authentication is enabled but API_KEY is missing")
        ctx:error(503, "API authentication is not configured.")
        return false
    end

    local headers = ctx.req.headers
    local provided_key = (headers["x-api-key"] or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if provided_key == "" then
        local auth_header = headers["authorization"] or ""
        if auth_header:sub(1, 7) == "Bearer " then
            provided_key = auth_header:sub(8):gsub("^%s+", ""):gsub("%s+$", "")
        end
    end

    if provided_key == "" or not secure_compare(provided_key, API_KEY) then
        logger.warn("Rejected unauthorized API request from " .. (ctx.req.remote_addr or "unknown"))
        ctx:error(401, "A valid API key is required.")
        return false
    end

    return true
end

return _M

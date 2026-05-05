-- auth.lua — API key authentication for baremetal Lua server
-- Uses ctx-based request context instead of ngx.* globals

local logger = require("app.logger")

local _M = {}

local AUTH_REQUIRED = (os.getenv("AUTH_REQUIRED") or "1") == "1"
local API_KEY = os.getenv("API_KEY") or ""

function _M.enforce(ctx)
    """Check X-API-Key or Bearer token. Calls ctx:error(401/503) on failure.
    Returns true if auth passed, false if it sent an error response.
    """
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

    if provided_key == "" or provided_key ~= API_KEY then
        logger.warn("Rejected unauthorized API request from " .. (ctx.req.remote_addr or "unknown"))
        ctx:error(401, "A valid API key is required.")
        return false
    end

    return true
end

return _M


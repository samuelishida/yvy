-- auth.lua — API key authentication
-- Port of backend/backend.py enforce_api_auth()

local _M = {}

local AUTH_REQUIRED = (os.getenv("AUTH_REQUIRED") or "1") == "1"
local API_KEY = os.getenv("API_KEY") or ""

function _M.enforce()
    """Check X-API-Key or Bearer token. Calls ngx.exit(401) or ngx.exit(503) on failure."""
    if not AUTH_REQUIRED then
        return
    end

    if API_KEY == "" then
        ngx.log(ngx.ERR, "API key authentication is enabled but API_KEY is missing")
        ngx.status = 503
        ngx.say('{"error":"API authentication is not configured."}')
        ngx.exit(503)
    end

    local headers = ngx.req.get_headers()
    local provided_key = (headers["X-API-Key"] or headers["x-api-key"] or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if provided_key == "" then
        local auth_header = headers["Authorization"] or headers["authorization"] or ""
        if auth_header:sub(1, 7) == "Bearer " then
            provided_key = auth_header:sub(8):gsub("^%s+", ""):gsub("%s+$", "")
        end
    end

    if provided_key == "" or provided_key ~= API_KEY then
        ngx.log(ngx.WARN, "Rejected unauthorized API request from ", ngx.var.remote_addr)
        ngx.status = 401
        ngx.say('{"error":"A valid API key is required."}')
        ngx.exit(401)
    end
end

return _M

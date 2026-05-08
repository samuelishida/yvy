-- frontend_server.lua — Static file server + API proxy for Yvy frontend
-- Replaces Node.js/Express server for Lua stack
--
-- Features:
--   - Serve React build static files
--   - Proxy /api/* to Lua backend with X-API-Key injection
--   - CORS headers
--   - Gzip compression (if lua-zlib available)
--   - Security headers

local env = require("app.env")
local copas = require("copas")
local socket = require("socket")
local http = require("socket.http")
local url = require("socket.url")
local ltn12 = require("ltn12")
local cjson = require("cjson")
local logger = require("app.logger")

local _M = {}

-- ── Configuration ────────────────────────────────────────────────────────

local PORT = tonumber(os.getenv("PORT") or "5001")
local BACKEND_URL = os.getenv("BACKEND_URL") or "http://127.0.0.1:5000"
local API_KEY = os.getenv("API_KEY") or ""
local STATIC_DIR = os.getenv("STATIC_DIR") or env.first_existing({
    "../frontend/build",
    "frontend/build",
    "/opt/yvy/frontend/build",
}) or "../frontend/build"

local CORS_ORIGINS = os.getenv("CORS_ORIGINS") or "http://localhost:5001,http://127.0.0.1:5001,http://localhost:3000"

-- Parse CORS origins
local cors_origins = {}
for o in (CORS_ORIGINS .. ","):gmatch("([^,]+),") do
    local origin = o:gsub("^%s+", ""):gsub("%s+$", "")
    if origin ~= "" then
        cors_origins[origin] = true
    end
end

-- Security headers
local SECURITY_HEADERS = {
    ["X-Content-Type-Options"] = "nosniff",
    ["X-Frame-Options"] = "DENY",
    ["Referrer-Policy"] = "strict-origin-when-cross-origin",
    ["Permissions-Policy"] = "geolocation=(), microphone=(), camera=(), bluetooth=()",
    ["Content-Security-Policy"] = "default-src 'self'; img-src 'self' data: https://tile.openstreetmap.org https://*.tile.openstreetmap.org; style-src 'self' 'unsafe-inline' https://stackpath.bootstrapcdn.com https://cdn.jsdelivr.net https://unpkg.com; script-src 'self' 'unsafe-inline' https://code.jquery.com https://cdn.jsdelivr.net https://unpkg.com; font-src 'self' https://stackpath.bootstrapcdn.com; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
}

-- MIME types
local mime_types = {
    html = "text/html", htm = "text/html",
    css = "text/css", js = "application/javascript",
    json = "application/json", xml = "application/xml",
    png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg",
    gif = "image/gif", svg = "image/svg+xml", ico = "image/x-icon",
    woff = "font/woff", woff2 = "font/woff2",
    txt = "text/plain", pdf = "application/pdf",
}

-- ── Request parsing ──────────────────────────────────────────────────────

local function parse_request(skt)
    local line, err = skt:receive("*l")
    if not line then return nil, err end

    local method, path, _ = line:match("^(%w+)%s+(%S+)%s+(%S+)$")
    if not method then return nil, "bad request line: " .. line end

    -- Parse query string
    local query_string = ""
    local clean_path = path
    local qm = path:find("?")
    if qm then
        clean_path = path:sub(1, qm - 1)
        query_string = path:sub(qm + 1)
    end

    -- Parse query args
    local args = {}
    if query_string ~= "" then
        for k, v in query_string:gmatch("([^&=]+)=([^&=]*)") do
            args[url.unescape(k)] = url.unescape(v)
        end
    end

    -- Read headers
    local headers = {}
    while true do
        line, err = skt:receive("*l")
        if not line then return nil, err end
        if line == "" then break end
        local key, value = line:match("^(.-):%s*(.*)$")
        if key then
            headers[key:lower()] = value
        end
    end

    -- Read body if Content-Length present
    local body = ""
    local content_length = tonumber(headers["content-length"] or "0")
    if content_length > 0 then
        body, err = skt:receive(content_length)
        if not body then return nil, err end
    end

    return {
        method = method,
        path = clean_path,
        query_string = query_string,
        args = args,
        headers = headers,
        body = body,
        remote_addr = skt:getpeername() or "unknown",
    }
end

-- ── Response helpers ─────────────────────────────────────────────────────

local function send_response(skt, status, body, content_type, extra_headers)
    content_type = content_type or "application/octet-stream"
    extra_headers = extra_headers or {}

    local response_lines = {
        "HTTP/1.1 " .. status .. " " .. ({
            [200] = "OK", [201] = "Created", [204] = "No Content",
            [301] = "Moved Permanently", [302] = "Found", [304] = "Not Modified",
            [400] = "Bad Request", [401] = "Unauthorized", [403] = "Forbidden",
            [404] = "Not Found", [429] = "Too Many Requests",
            [500] = "Internal Server Error", [502] = "Bad Gateway",
        })[status] or "Unknown",
    }

    -- Security headers
    for k, v in pairs(SECURITY_HEADERS) do
        response_lines[#response_lines + 1] = k .. ": " .. v
    end

    -- Content-Type
    response_lines[#response_lines + 1] = "Content-Type: " .. content_type
    response_lines[#response_lines + 1] = "Content-Length: " .. tostring(#body)

    -- Extra headers
    for k, v in pairs(extra_headers) do
        response_lines[#response_lines + 1] = k .. ": " .. v
    end

    response_lines[#response_lines + 1] = ""  -- blank line
    response_lines[#response_lines + 1] = body

    skt:send(table.concat(response_lines, "\r\n"))
end

local function error_response(skt, status, message, extra_headers)
    local body = cjson.encode({error = message})
    send_response(skt, status, body, "application/json", extra_headers)
end

-- ── Static file serving ──────────────────────────────────────────────────

local function serve_static(skt, req)
    local file_path = STATIC_DIR .. req.path
    -- Default to index.html for SPA routes
    if req.path == "/" or not req.path:find("%.") then
        file_path = STATIC_DIR .. "/index.html"
    end

    local f, err = io.open(file_path, "rb")
    if not f then
        -- SPA fallback: serve index.html for any non-file path
        f, err = io.open(STATIC_DIR .. "/index.html", "rb")
        if not f then
            error_response(skt, 404, "Not found")
            return 404, 0
        end
    end

    local content = f:read("*a")
    f:close()

    local ext = file_path:match("%.([^.]+)$") or ""
    local mime = mime_types[ext:lower()] or "application/octet-stream"

    -- No-cache for JS/CSS to prevent stale bundle
    local extra_headers = {}
    if ext == "js" or ext == "css" then
        extra_headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
        extra_headers["Pragma"] = "no-cache"
        extra_headers["Expires"] = "0"
    elseif ext == "html" or ext == "" then
        -- Also prevent index.html caching so new bundles get loaded
        extra_headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    end

    send_response(skt, 200, content, mime, extra_headers)
    return 200, #content
end

-- ── API Proxy ────────────────────────────────────────────────────────────

local function proxy_api(skt, req)
    -- Build backend path
    local backend_path = req.path
    if req.query_string ~= "" then
        backend_path = backend_path .. "?" .. req.query_string
    end

    -- Prepare headers
    local proxy_headers = {}
    for k, v in pairs(req.headers) do
        local key = k:lower()
        if key ~= "host" and key ~= "connection" and key ~= "proxy-connection" then
            proxy_headers[k] = v
        end
    end
    proxy_headers["Host"] = BACKEND_URL:match("https?://([^/]+)") or "127.0.0.1"
    proxy_headers["Connection"] = "close"

    -- Inject API key
    if API_KEY ~= "" then
        proxy_headers["X-API-Key"] = API_KEY
    end

    -- Parse backend URL
    local backend_host = BACKEND_URL:match("https?://([^:/]+)")
    local backend_port = tonumber(BACKEND_URL:match("https?://[^:]+:(%d+)") or "5000")
    
    logger.debug("Proxying to " .. backend_host .. ":" .. backend_port .. backend_path)

    -- Make direct socket request (copas-compatible)
    local ok, result = pcall(function()
        local s = socket.tcp()
        copas.wrap(s)
        s:settimeout(10)

        local ok, err = s:connect(backend_host, backend_port)
        if not ok then error("Connection failed: " .. tostring(err)) end

        -- Send HTTP request
        s:send(req.method .. " " .. backend_path .. " HTTP/1.1\r\n")
        for k, v in pairs(proxy_headers) do
            s:send(k .. ": " .. tostring(v) .. "\r\n")
        end
        s:send("\r\n")

        if req.body ~= "" and req.method ~= "GET" then
            s:send(req.body)
        end

        -- Read response
        local response = s:receive("*a")
        s:close()

        -- Parse response
        local status_line, headers_str, body = response:match("^(HTTP/1%.[01] %d+ .-\r\n)(.-)\r\n\r\n(.*)$")
        if not status_line then
            error("Invalid response format")
        end

        local code = tonumber(status_line:match("HTTP/1%.[01] (%d+)"))
        local resp_headers = {}
        for key, value in headers_str:gmatch("([^:]+):%s*(.-)\r\n") do
            resp_headers[key:lower()] = value
        end

        return code, resp_headers, body
    end)

    if not ok then
        logger.error("Backend proxy error: " .. tostring(result))
        error_response(skt, 502, "Bad Gateway")
        return 502, 0
    end

    local code, resp_headers, body = ok, result, nil
    if type(result) == "number" then
        code, resp_headers, body = result, select(2, result)
    end

    -- Forward response
    local extra_headers = {}
    if resp_headers then
        if resp_headers["content-type"] then
            extra_headers["Content-Type"] = resp_headers["content-type"]
        end
        if resp_headers["cache-control"] then
            extra_headers["Cache-Control"] = resp_headers["cache-control"]
        end
    end

    -- Add CORS headers
    local origin = req.headers["origin"] or ""
    if cors_origins[origin] or cors_origins["*"] then
        extra_headers["Access-Control-Allow-Origin"] = origin
        extra_headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        extra_headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization, X-API-Key"
        extra_headers["Access-Control-Max-Age"] = "86400"
    end

    send_response(skt, code or 200, body or "", nil, extra_headers)
    return code or 200, body and #body or 0
end

-- ── Request handler ──────────────────────────────────────────────────────

local function handle_request(skt)
    local start_time = socket.gettime()

    local req, err = parse_request(skt)
    if not req then
        logger.warn("Failed to parse request: " .. tostring(err))
        skt:close()
        return
    end

    -- Handle OPTIONS (CORS preflight)
    if req.method == "OPTIONS" then
        local extra = {}
        local origin = req.headers["origin"] or ""
        if cors_origins[origin] or cors_origins["*"] then
            extra["Access-Control-Allow-Origin"] = origin
            extra["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
            extra["Access-Control-Allow-Headers"] = "Content-Type, Authorization, X-API-Key"
            extra["Access-Control-Max-Age"] = "86400"
        end
        send_response(skt, 204, "", "text/plain", extra)
        local duration = math.floor((socket.gettime() - start_time) * 1000)
        logger.request(req.method, req.path, 204, duration, req.remote_addr, 0)
        return
    end

    local status_code = 200
    local bytes_sent = 0

    -- Route: /api/* → proxy to backend
    if req.path:sub(1, 4) == "/api" then
        status_code, bytes_sent = proxy_api(skt, req)
    else
        -- Static file serving
        status_code, bytes_sent = serve_static(skt, req)
    end

    local duration = math.floor((socket.gettime() - start_time) * 1000)
    logger.request(req.method, req.path, status_code, duration, req.remote_addr, bytes_sent)
end

-- ── Start server ─────────────────────────────────────────────────────────

function _M.start()
    logger.info("Yvy frontend (Lua) starting on port " .. PORT)
    logger.info("Serving static files from: " .. STATIC_DIR)
    logger.info("Proxying /api/* to: " .. BACKEND_URL)

    local server_skt = socket.tcp()
    assert(server_skt:bind("*", PORT))
    server_skt:listen(128)

    copas.addserver(server_skt, handle_request)
    logger.info("Frontend listening on :" .. PORT)

    copas.loop()
end

return _M

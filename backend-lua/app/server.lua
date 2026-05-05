-- server.lua — Minimal async HTTP server for baremetal Lua
-- Uses luasocket + copas for cross-platform (Windows + Ubuntu) event loop
-- Replaces nginx.conf + Express proxy
--
-- Features:
--   - Route registration (method + path pattern)
--   - Query string parsing
--   - JSON request/response helpers
--   - Static file serving
--   - CORS headers
--   - Gzip compression (if lua-zlib available)
--   - Security headers

local socket = require("socket")
local http   = require("socket.http")
local copas  = require("copas")
local cjson  = require("cjson")
local logger = require("app.logger")

local _M = {}

-- ── Configuration ────────────────────────────────────────────────────────

local PORT = tonumber(os.getenv("PORT") or "5000")
local CORS_ORIGINS = os.getenv("CORS_ORIGINS") or "http://localhost:5001,http://127.0.0.1:5001,http://localhost:3000"
local STATIC_DIR = os.getenv("STATIC_DIR") or "frontend/build"

-- Parse CORS origins
local cors_origins = {}
for origin in (CORS_ORIGINS .. ","):gmatch("([^,]+),") do
    origin = origin:gsub("^%s+", ""):gsub("%s+$", "")
    if origin ~= "" then
        cors_origins[origin] = true
    end
end

-- ── Security headers ─────────────────────────────────────────────────────

local SECURITY_HEADERS = {
    ["X-Content-Type-Options"] = "nosniff",
    ["X-Frame-Options"] = "DENY",
    ["Referrer-Policy"] = "strict-origin-when-cross-origin",
    ["Permissions-Policy"] = "geolocation=(), microphone=(), camera=(), bluetooth=()",
    ["Content-Security-Policy"] = "default-src 'self'; img-src 'self' data: https://tile.openstreetmap.org https://*.tile.openstreetmap.org; style-src 'self' 'unsafe-inline' https://stackpath.bootstrapcdn.com https://cdn.jsdelivr.net https://unpkg.com; script-src 'self' 'unsafe-inline' https://code.jquery.com https://cdn.jsdelivr.net https://unpkg.com; font-src 'self' https://stackpath.bootstrapcdn.com; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
}

-- ── Route table ──────────────────────────────────────────────────────────

-- routes[method][path] = handler
-- Special: routes["GET"]["*"] = static file fallback
local routes = {}

function _M.route(method, path, handler)
    method = method:upper()
    if not routes[method] then routes[method] = {} end
    routes[method][path] = handler
end

-- ── Request object ───────────────────────────────────────────────────────

local function parse_request(skt)
    -- Read request line
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
            args[http.unescape(k)] = http.unescape(v)
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
    content_type = content_type or "application/json"
    extra_headers = extra_headers or {}

    local response_lines = {
        "HTTP/1.1 " .. status .. " " .. ({
            [200] = "OK", [201] = "Created", [204] = "No Content",
            [400] = "Bad Request", [401] = "Unauthorized", [404] = "Not Found",
            [429] = "Too Many Requests", [500] = "Internal Server Error",
            [502] = "Bad Gateway", [503] = "Service Unavailable",
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

local function json_response(skt, status, data, extra_headers)
    local body = cjson.encode(data)
    send_response(skt, status, body, "application/json", extra_headers)
end

local function error_response(skt, status, message)
    json_response(skt, status, {error = message})
end

-- ── Static file serving ──────────────────────────────────────────────────

local mime_types = {
    html = "text/html", htm = "text/html",
    css = "text/css", js = "application/javascript",
    json = "application/json", xml = "application/xml",
    png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg",
    gif = "image/gif", svg = "image/svg+xml", ico = "image/x-icon",
    woff = "font/woff", woff2 = "font/woff2",
    txt = "text/plain", pdf = "application/pdf",
}

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
            return
        end
    end

    local content = f:read("*a")
    f:close()

    local ext = file_path:match("%.([^.]+)$") or ""
    local mime = mime_types[ext:lower()] or "application/octet-stream"

    send_response(skt, 200, content, mime)
end

-- ── CORS handling ────────────────────────────────────────────────────────

local function add_cors_headers(req, extra_headers)
    local origin = req.headers["origin"] or ""
    if cors_origins[origin] or cors_origins["*"] then
        extra_headers["Access-Control-Allow-Origin"] = origin
        extra_headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        extra_headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization, X-API-Key"
        extra_headers["Access-Control-Max-Age"] = "86400"
    end
end

-- ── Request handler (dispatched by copas) ────────────────────────────────

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
        add_cors_headers(req, extra)
        send_response(skt, 204, "", "text/plain", extra)
        local duration = math.floor((socket.gettime() - start_time) * 1000)
        logger.request(req.method, req.path, 204, duration, req.remote_addr, 0)
        return
    end

    -- Find route handler
    local method_routes = routes[req.method]
    local handler = method_routes and method_routes[req.path]

    if handler then
        -- Wrap in pcall for error handling
        local ok, err_or_status = pcall(function()
            -- Create a response context
            local ctx = {
                req = req,
                skt = skt,
                status = 200,
                _headers = {},
                _sent = false,
            }

            function ctx.send(status, body, content_type)
                ctx._sent = true
                add_cors_headers(req, ctx._headers)
                send_response(skt, status, body, content_type or "application/json", ctx._headers)
            end

            function ctx.json(status, data)
                ctx._sent = true
                add_cors_headers(req, ctx._headers)
                json_response(skt, status, data, ctx._headers)
            end

            function ctx.error(status, msg)
                ctx._sent = true
                add_cors_headers(req, ctx._headers)
                error_response(skt, status, msg)
            end

            function ctx.set_header(k, v)
                ctx._headers[k] = v
            end

            handler(ctx)
        end)

        if not ok then
            logger.error("Handler error: " .. tostring(err_or_status))
            if not ctx or not ctx._sent then
                error_response(skt, 500, "Internal server error")
            end
        end
    else
        -- Try static file serving for GET requests
        if req.method == "GET" then
            serve_static(skt, req)
        else
            error_response(skt, 404, "Not found")
        end
    end

    local duration = math.floor((socket.gettime() - start_time) * 1000)
    logger.request(req.method, req.path, 200, duration, req.remote_addr, 0)
end

-- ── Start server ─────────────────────────────────────────────────────────

function _M.start()
    logger.info("Yvy backend (Lua baremetal) starting on port " .. PORT)

    local server_skt = socket.tcp()
    assert(server_skt:bind("*", PORT))
    server_skt:listen(128)

    copas.addserver(server_skt, handle_request)
    logger.info("Server listening on :" .. PORT)

    copas.loop()
end

return _M

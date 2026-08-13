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

local env    = require("app.env")
local copas  = require("copas")
local socket = require("socket")
local http   = require("socket.http")
local url    = require("socket.url")
local cjson  = require("cjson")
local logger = require("app.logger")
local has_coxpcall, coxpcall = pcall(require, "coxpcall")

if type(cjson.encode_empty_table_as_object) == "function" then
    cjson.encode_empty_table_as_object(false)
end

local _M = {}
local safe_pcall = (has_coxpcall and coxpcall and coxpcall.pcall) or pcall

-- ── Configuration ────────────────────────────────────────────────────────

local PORT = tonumber(os.getenv("PORT") or "5000")
local HOST = os.getenv("HOST") or "127.0.0.1"
local CORS_ORIGINS = os.getenv("CORS_ORIGINS") or "http://localhost:5001,http://127.0.0.1:5001,http://localhost:3000"
local STATIC_DIR = os.getenv("STATIC_DIR") or env.first_existing({
    "../frontend/build",
    "frontend/build",
    "/opt/yvy/frontend/build",
}) or "../frontend/build"

-- Security limits
-- MAX_REQUEST_SIZE default 8MB (plan: risk-intelligence, Inc 3) para uploads de
-- CSV raw de fornecedores. Em produção o gate real é o nginx
-- `client_max_body_size` (yvy-nginx.conf.j2); este é o segundo gate.
local MAX_REQUEST_SIZE = tonumber(os.getenv("MAX_REQUEST_SIZE") or "8388608")  -- 8MB default
local MAX_URI_LENGTH = tonumber(os.getenv("MAX_URI_LENGTH") or "2048")  -- 2KB
local CLIENT_TIMEOUT = tonumber(os.getenv("CLIENT_TIMEOUT_SECONDS") or "5")

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

    -- Validate request line length (DoS protection)
    if #line > MAX_URI_LENGTH then
        return nil, "request line too long (max " .. MAX_URI_LENGTH .. " bytes)"
    end

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
    
    -- Validate request size (DoS protection)
    if content_length > MAX_REQUEST_SIZE then
        return nil, "request body too large (max " .. MAX_REQUEST_SIZE .. " bytes)"
    end
    
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
    extra_headers["Connection"] = extra_headers["Connection"] or "close"

    local response_lines = {
        "HTTP/1.1 " .. status .. " " .. (({
            [200] = "OK", [201] = "Created", [202] = "Accepted",
            [204] = "No Content", [304] = "Not Modified",
            [400] = "Bad Request", [401] = "Unauthorized", [404] = "Not Found",
            [429] = "Too Many Requests", [500] = "Internal Server Error",
            [502] = "Bad Gateway", [503] = "Service Unavailable",
        })[status] or "Unknown"),
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

local function error_response(skt, status, message, extra_headers)
    json_response(skt, status, {error = message}, extra_headers)
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
            return 404, 0
        end
    end

    local content = f:read("*a")
    f:close()

    local ext = file_path:match("%.([^.]+)$") or ""
    local mime = mime_types[ext:lower()] or "application/octet-stream"

    send_response(skt, 200, content, mime)
    return 200, #content
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
    pcall(function()
        skt:settimeout(CLIENT_TIMEOUT)
    end)

    local req, err = parse_request(skt)
    if not req then
        if err ~= "timeout" then
            logger.warn("Failed to parse request: " .. tostring(err))
        end
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
        skt:close()
        return
    end

    -- Find route handler
    local method_routes = routes[req.method]
    local handler = method_routes and method_routes[req.path]
    local status_code = 200
    local bytes_sent = 0

    if handler then
        local ctx
        local ok, err_or_status = safe_pcall(function()
            -- Create a response context
            ctx = {
                req = req,
                skt = skt,
                status = 200,
                _headers = {},
                _sent = false,
                _status_code = 200,
                _bytes_sent = 0,
            }

            function ctx:send(status, body, content_type)
                body = body or ""
                self._sent = true
                self._status_code = status
                self._bytes_sent = #body
                add_cors_headers(req, self._headers)
                send_response(skt, status, body, content_type or "application/json", self._headers)
            end

            function ctx:json(status, data)
                local body = cjson.encode(data)
                self._sent = true
                self._status_code = status
                self._bytes_sent = #body
                add_cors_headers(req, self._headers)
                send_response(skt, status, body, "application/json", self._headers)
            end

            function ctx:error(status, msg)
                self._sent = true
                self._status_code = status
                add_cors_headers(req, self._headers)
                error_response(skt, status, msg, self._headers)
            end

            function ctx:set_header(k, v)
                self._headers[k] = v
            end

            return handler(ctx)
        end)

        if not ok then
            logger.error("Handler error: " .. tostring(err_or_status))
            status_code = 500
            if not ctx or not ctx._sent then
                error_response(skt, 500, "Internal server error")
            end
        elseif ctx then
            status_code = ctx._status_code or 200
            bytes_sent = ctx._bytes_sent or 0
        end
    else
        -- Try static file serving for GET requests
        if req.method == "GET" then
            status_code, bytes_sent = serve_static(skt, req)
        else
            status_code = 404
            error_response(skt, 404, "Not found")
        end
    end

    local duration = math.floor((socket.gettime() - start_time) * 1000)
    logger.request(req.method, req.path, status_code, duration, req.remote_addr, bytes_sent)
    skt:close()
end

-- ── Start server ─────────────────────────────────────────────────────────

function _M.start()
    logger.info("Yvy backend (Lua baremetal) starting on " .. HOST .. ":" .. PORT)

    -- socket.tcp4() creates the fd immediately so SO_REUSEADDR sticks
    -- before bind(); socket.tcp() defers fd creation, leaving setoption a no-op
    -- and causing EADDRINUSE if TIME-WAIT entries exist on the port.
    local server_skt = assert(socket.tcp4())
    local ok, err = server_skt:setoption("reuseaddr", true)
    if not ok then
        logger.error("setoption reuseaddr failed: " .. tostring(err))
    end
    pcall(function() server_skt:setoption("reuseport", true) end)
    assert(server_skt:bind(HOST, PORT))
    server_skt:listen(128)

    copas.addserver(server_skt, handle_request)
    logger.info("Server listening on " .. HOST .. ":" .. PORT)

    copas.loop()
end

-- Test-only export: lets tests exercise the status-line construction (incl.
-- the 304 precedence fix) without opening a socket. Not used in production.
_M.send_response = send_response

return _M

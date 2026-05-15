-- http_client.lua - Async-ish HTTP client for baremetal Lua
-- Uses LuaSocket for plain HTTP and curl subprocess fallback for HTTPS.

local http = require("socket.http")
local socket = require("socket")
local socket_url = require("socket.url")
local ltn12 = require("ltn12")
local cjson = require("cjson")
local logger = require("app.logger")
local has_coxpcall, coxpcall = pcall(require, "coxpcall")

local _M = {}
local safe_pcall = (has_coxpcall and coxpcall and coxpcall.pcall) or pcall

local DEFAULT_TIMEOUT = 30
local MAX_RETRIES = 3
local RETRY_DELAY_MS = 100

local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local NULL_DEV = IS_WINDOWS and "nul" or "/dev/null"
local PATH_SEP = IS_WINDOWS and "\\" or "/"

local function shell_quote(value)
    return '"' .. tostring(value):gsub('"', '\\"') .. '"'
end

local function normalize_path(path)
    return tostring(path):gsub("\\", "/")
end

local function read_file(path, mode)
    local f = io.open(path, mode or "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function sleep_ms(ms)
    if package.loaded.copas then
        require("copas").sleep(ms / 1000)
    else
        socket.sleep(ms / 1000)
    end
end

local function build_query(url, query)
    if not query or not next(query) then
        return url
    end

    local parts = {}
    for k, v in pairs(query) do
        parts[#parts + 1] = socket_url.escape(tostring(k)) .. "=" .. socket_url.escape(tostring(v))
    end
    return url .. "?" .. table.concat(parts, "&")
end

local function curl_request(method, url, timeout, headers, body)
    timeout = timeout or DEFAULT_TIMEOUT
    headers = headers or {}
    body = body or ""

    local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or (IS_WINDOWS and "." or "/tmp")
    local stamp = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
    local req_body_path = nil

    local cmd_parts = {
        "curl",
        "-sS",
        "-L",
        "--max-time", tostring(timeout),
        "-X", method,
    }

    for key, value in pairs(headers) do
        cmd_parts[#cmd_parts + 1] = "-H"
        cmd_parts[#cmd_parts + 1] = shell_quote(tostring(key) .. ": " .. tostring(value))
    end

    if method == "POST" and body ~= "" then
        req_body_path = normalize_path(temp_dir .. PATH_SEP .. "yvy_curl_req_" .. stamp .. ".txt")
        local reqf, err = io.open(req_body_path, "wb")
        if not reqf then
            return nil, "failed to create temp curl body: " .. tostring(err)
        end
        reqf:write(body)
        reqf:close()
        cmd_parts[#cmd_parts + 1] = "--data-binary"
        cmd_parts[#cmd_parts + 1] = "@" .. req_body_path
    end

    cmd_parts[#cmd_parts + 1] = shell_quote(url)
    cmd_parts[#cmd_parts + 1] = "-w"
    cmd_parts[#cmd_parts + 1] = shell_quote("__YVY_CURL_STATUS__:%{http_code}")
    cmd_parts[#cmd_parts + 1] = "2>" .. NULL_DEV

    local proc = io.popen(table.concat(cmd_parts, " "), "r")
    if not proc then
        if req_body_path then
            os.remove(req_body_path)
        end
        return nil, "io.popen failed"
    end
    local output = proc:read("*a")
    proc:close()

    if req_body_path then
        os.remove(req_body_path)
    end

    local response_body, code = output:match("^(.*)__YVY_CURL_STATUS__:(%d+)%s*$")
    local status = tonumber(code)
    if not status then
        return nil, "curl did not return HTTP status"
    end

    return {
        status = status,
        body = response_body or "",
        headers = {},
    }
end

local function socket_request(method, url, timeout, headers, body)
    local response_body = {}
    local request = {
        url = url,
        method = method,
        headers = headers or {},
        sink = ltn12.sink.table(response_body),
        create = function()
            local s = socket.tcp()
            s:settimeout(timeout)
            return s
        end,
    }

    if method == "POST" then
        request.source = ltn12.source.string(body or "")
    end

    local ok, result_or_err, code, resp_headers, status_line = safe_pcall(http.request, request)
    if ok and tonumber(code) then
        return {
            status = tonumber(code) or 0,
            body = table.concat(response_body),
            headers = resp_headers or {},
            status_line = status_line,
        }
    end

    return nil, tostring(result_or_err or code or "request failed")
end

-- Build a curl command string for a single GET. Used by parallel_get to
-- launch multiple subprocesses concurrently.
local function build_curl_get_cmd(url, timeout, headers)
    local parts = {"curl", "-sS", "-L", "--max-time", tostring(timeout), "-X", "GET"}
    for k, v in pairs(headers or {}) do
        parts[#parts + 1] = "-H"
        parts[#parts + 1] = shell_quote(tostring(k) .. ": " .. tostring(v))
    end
    parts[#parts + 1] = shell_quote(url)
    parts[#parts + 1] = "-w"
    parts[#parts + 1] = shell_quote("__YVY_CURL_STATUS__:%{http_code}")
    parts[#parts + 1] = "2>" .. NULL_DEV
    return table.concat(parts, " ")
end

local function parse_curl_output(output)
    local body, code = output:match("^(.*)__YVY_CURL_STATUS__:(%d+)%s*$")
    local status = tonumber(code)
    if not status then return nil, "curl did not return HTTP status" end
    return {status = status, body = body or "", headers = {}}
end

-- Launch N HTTPS GETs as concurrent curl subprocesses, then collect responses.
-- Returns an array of {res = response, err = err_str} parallel to the urls input.
-- Total wall time ≈ max(t_i) instead of sum(t_i) — io.popen returns immediately,
-- so the kernel runs all curl processes in parallel; only the reads serialize.
function _M.parallel_get(urls, opts)
    opts = opts or {}
    local timeout = opts.timeout or DEFAULT_TIMEOUT
    local headers = opts.headers or {}

    local entries = {}
    for i, url in ipairs(urls) do
        local full_url = build_query(url, opts.query and opts.query[i] or {})
        if full_url:sub(1, 8) == "https://" then
            local cmd = build_curl_get_cmd(full_url, timeout, headers)
            local proc = io.popen(cmd, "r")
            entries[i] = {proc = proc, fallback = nil}
        else
            local res, err = socket_request("GET", full_url, timeout, headers)
            entries[i] = {proc = nil, fallback = {res = res, err = err}}
        end
    end

    local results = {}
    for i, entry in ipairs(entries) do
        if entry.fallback then
            results[i] = entry.fallback
        elseif entry.proc then
            local output = entry.proc:read("*a")
            entry.proc:close()
            local res, err = parse_curl_output(output)
            results[i] = {res = res, err = err}
        else
            results[i] = {res = nil, err = "popen failed"}
        end
    end

    return results
end

function _M.get(url, opts)
    opts = opts or {}
    local timeout = opts.timeout or DEFAULT_TIMEOUT
    local headers = opts.headers or {}
    local retries = opts.retries or MAX_RETRIES
    url = build_query(url, opts.query or {})

    local last_err
    for attempt = 1, retries do
        local res, err
        if url:sub(1, 8) == "https://" then
            res, err = curl_request("GET", url, timeout, headers)
        else
            res, err = socket_request("GET", url, timeout, headers)
        end

        if res then
            return res
        end

        last_err = err or "GET failed"
        logger.warn("HTTP GET attempt " .. attempt .. " failed: " .. last_err, {url = url})
        if attempt < retries then
            sleep_ms(RETRY_DELAY_MS * attempt)
        end
    end

    logger.warn("HTTP GET failed after " .. retries .. " attempts: " .. tostring(last_err), {url = url})
    return nil, last_err
end

function _M.post(url, opts)
    opts = opts or {}
    local timeout = opts.timeout or DEFAULT_TIMEOUT
    local body = opts.body or ""
    local headers = opts.headers or {}
    local retries = opts.retries or MAX_RETRIES

    if type(body) == "table" then
        body = cjson.encode(body)
        headers["content-type"] = "application/json"
    end
    headers["content-length"] = tostring(#body)

    local last_err
    for attempt = 1, retries do
        local res, err
        if url:sub(1, 8) == "https://" then
            res, err = curl_request("POST", url, timeout, headers, body)
        else
            res, err = socket_request("POST", url, timeout, headers, body)
        end

        if res then
            return res
        end

        last_err = err or "POST failed"
        logger.warn("HTTP POST attempt " .. attempt .. " failed: " .. last_err, {url = url})
        if attempt < retries then
            sleep_ms(RETRY_DELAY_MS * attempt)
        end
    end

    logger.warn("HTTP POST failed after " .. retries .. " attempts: " .. tostring(last_err), {url = url})
    return nil, last_err
end

function _M.download(url, dest_path, timeout)
    timeout = timeout or 120

    if url:sub(1, 8) == "https://" then
        local safe_url = shell_quote(url)
        local safe_dest = shell_quote(dest_path)
        local cmd = string.format("curl -sS -L --max-time %d -o %s %s 2>%s", timeout, safe_dest, safe_url, NULL_DEV)
        local ok = os.execute(cmd)
        if ok ~= 0 and ok ~= true then
            os.remove(dest_path)
            return nil, "curl download failed"
        end
        return true
    end

    local f, err = io.open(dest_path, "wb")
    if not f then return nil, err end

    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.file(f),
        create = function()
            local s = socket.tcp()
            s:settimeout(timeout)
            return s
        end,
    }

    local ok, result_or_err, code = safe_pcall(http.request, request)
    f:close()

    if not ok or tonumber(code) ~= 200 then
        os.remove(dest_path)
        return nil, tostring(code or result_or_err)
    end
    return true
end

return _M

-- http_client.lua — Async HTTP client for baremetal Lua
-- Wraps luasocket's http module with copas-aware timeouts
-- Replaces lua-resty-http / httpx

local http = require("socket.http")
local ltn12 = require("ltn12")
local cjson = require("cjson")
local logger = require("app.logger")

local _M = {}

local DEFAULT_TIMEOUT = 30

function _M.get(url, opts)
    opts = opts or {}
    local timeout = opts.timeout or DEFAULT_TIMEOUT
    local query = opts.query or {}
    local headers = opts.headers or {}

    -- Build query string
    if next(query) then
        local parts = {}
        for k, v in pairs(query) do
            parts[#parts + 1] = k .. "=" .. http.url_encode(tostring(v))
        end
        url = url .. "?" .. table.concat(parts, "&")
    end

    local response_body = {}
    local request = {
        url = url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(response_body),
        create = function()
            local s = require("socket").tcp()
            s:settimeout(timeout)
            return s
        end,
    }

    local ok, code, resp_headers = pcall(http.request, request)
    if not ok then
        logger.warn("HTTP GET failed: " .. tostring(code), {url = url})
        return nil, tostring(code)
    end

    return {
        status = code,
        body = table.concat(response_body),
        headers = resp_headers,
    }
end

function _M.post(url, opts)
    opts = opts or {}
    local timeout = opts.timeout or DEFAULT_TIMEOUT
    local body = opts.body or ""
    local headers = opts.headers or {}

    if type(body) == "table" then
        body = cjson.encode(body)
        headers["content-type"] = "application/json"
    end

    headers["content-length"] = tostring(#body)

    local response_body = {}
    local request = {
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response_body),
        create = function()
            local s = require("socket").tcp()
            s:settimeout(timeout)
            return s
        end,
    }

    local ok, code, resp_headers = pcall(http.request, request)
    if not ok then
        logger.warn("HTTP POST failed: " .. tostring(code), {url = url})
        return nil, tostring(code)
    end

    return {
        status = code,
        body = table.concat(response_body),
        headers = resp_headers,
    }
end

-- Streaming download (for large files like PRODES zip)
function _M.download(url, dest_path, timeout)
    timeout = timeout or 120
    local f, err = io.open(dest_path, "wb")
    if not f then return nil, err end

    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.file(f),
        create = function()
            local s = require("socket").tcp()
            s:settimeout(timeout)
            return s
        end,
    }

    local ok, code = pcall(http.request, request)
    f:close()

    if not ok then
        os.remove(dest_path)
        return nil, tostring(code)
    end
    return true
end

return _M

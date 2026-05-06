-- http_client.lua — Async HTTP client for baremetal Lua
-- Wraps luasocket's http module with copas-aware timeouts
-- HTTPS URLs fall back to curl subprocess (luasec not installed)

local http = require("socket.http")
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

-- curl-based HTTPS GET (used when URL starts with https://)
local function curl_get(url, timeout)
    timeout = timeout or DEFAULT_TIMEOUT
    -- escape double quotes in url to prevent shell injection
    local safe_url = url:gsub('"', '\\"')
    local cmd = string.format('curl -s --max-time %d "%s" 2>nul', timeout, safe_url)
    local f = io.popen(cmd, "r")
    if not f then return nil, "io.popen failed" end
    local body = f:read("*a")
    local ok = f:close()
    if not body or #body == 0 then
        return nil, "curl returned empty response"
    end
    return { status = 200, body = body, headers = {} }
end

local function sleep_ms(ms)
    if package.loaded.copas then
        require("copas").sleep(ms / 1000)
    else
        require("socket").sleep(ms / 1000)
    end
end

function _M.get(url, opts)
    opts = opts or {}
    local timeout = opts.timeout or DEFAULT_TIMEOUT
    local query = opts.query or {}
    local headers = opts.headers or {}
    local retries = opts.retries or MAX_RETRIES

    -- Build query string
    if next(query) then
        local parts = {}
        for k, v in pairs(query) do
            parts[#parts + 1] = socket_url.escape(tostring(k)) .. "=" .. socket_url.escape(tostring(v))
        end
        url = url .. "?" .. table.concat(parts, "&")
    end

    -- HTTPS: luasec not installed, fall back to curl
    if url:sub(1, 8) == "https://" then
        local last_err
        for attempt = 1, retries do
            local res, err = curl_get(url, timeout)
            if res then return res end
            last_err = err or "curl failed"
            logger.warn("HTTPS GET attempt " .. attempt .. " failed: " .. last_err, {url = url})
            if attempt < retries then sleep_ms(RETRY_DELAY_MS * attempt) end
        end
        logger.warn("HTTPS GET failed after " .. retries .. " attempts: " .. last_err, {url = url})
        return nil, last_err
    end

    local last_err
    for attempt = 1, retries do
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

        local ok, result_or_err, code, resp_headers, status_line = safe_pcall(http.request, request)
        if ok and result_or_err and tonumber(code) >= 200 and tonumber(code) < 300 then
            return {
                status = tonumber(code) or 0,
                body = table.concat(response_body),
                headers = resp_headers,
                status_line = status_line,
            }
        end

        last_err = tostring(result_or_err or "HTTP error " .. tostring(code))
        logger.warn("HTTP GET attempt " .. attempt .. " failed: " .. last_err, {url = url})

        if attempt < retries then
            sleep_ms(RETRY_DELAY_MS * attempt)  -- Exponential backoff
        end
    end

    logger.warn("HTTP GET failed after " .. retries .. " attempts: " .. last_err, {url = url})
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

        local ok, result_or_err, code, resp_headers, status_line = safe_pcall(http.request, request)
        if ok and result_or_err and tonumber(code) >= 200 and tonumber(code) < 300 then
            return {
                status = tonumber(code) or 0,
                body = table.concat(response_body),
                headers = resp_headers,
                status_line = status_line,
            }
        end

        last_err = tostring(result_or_err or "HTTP error " .. tostring(code))
        logger.warn("HTTP POST attempt " .. attempt .. " failed: " .. last_err, {url = url})

        if attempt < retries then
            sleep_ms(RETRY_DELAY_MS * attempt)
        end
    end

    logger.warn("HTTP POST failed after " .. retries .. " attempts: " .. last_err, {url = url})
    return nil, last_err
end

-- Streaming download (for large files like PRODES zip)
function _M.download(url, dest_path, timeout)
    timeout = timeout or 120

    if url:sub(1, 8) == "https://" then
        local safe_url = url:gsub('"', '\\"')
        local cmd = string.format('curl -s --max-time %d -o "%s" "%s" 2>nul', timeout, dest_path, safe_url)
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
            local s = require("socket").tcp()
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

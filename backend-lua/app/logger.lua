-- logger.lua — Structured JSON logger for baremetal Lua
-- Replaces nginx access/error log + Python JsonFormatter
-- Thread-safe, writes to stdout/stderr

local cjson = require("cjson")

local _M = {}

local LOG_LEVELS = {DEBUG = 10, INFO = 20, WARN = 30, ERROR = 40}
local current_level = LOG_LEVELS[os.getenv("LOG_LEVEL") or "INFO"] or LOG_LEVELS.INFO

local function format_log(level, message, extra)
    local payload = {
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        level = level,
        message = message,
    }
    if extra then
        for k, v in pairs(extra) do
            payload[k] = v
        end
    end
    return cjson.encode(payload)
end

function _M.debug(msg, extra)
    if current_level <= LOG_LEVELS.DEBUG then
        io.stderr:write(format_log("DEBUG", msg, extra), "\n")
        io.stderr:flush()
    end
end

function _M.info(msg, extra)
    if current_level <= LOG_LEVELS.INFO then
        io.stdout:write(format_log("INFO", msg, extra), "\n")
        io.stdout:flush()
    end
end

function _M.warn(msg, extra)
    if current_level <= LOG_LEVELS.WARN then
        io.stderr:write(format_log("WARN", msg, extra), "\n")
        io.stderr:flush()
    end
end

function _M.error(msg, extra)
    if current_level <= LOG_LEVELS.ERROR then
        io.stderr:write(format_log("ERROR", msg, extra), "\n")
        io.stderr:flush()
    end
end

-- HTTP request logging (structured, like nginx json format)
function _M.request(method, path, status, duration_ms, remote_addr, bytes_sent)
    if current_level <= LOG_LEVELS.INFO then
        local payload = {
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            level = "INFO",
            event = "http_request",
            method = method,
            path = path,
            status_code = status,
            duration_ms = duration_ms,
            remote_addr = remote_addr or "-",
            bytes = bytes_sent or 0,
        }
        io.stdout:write(cjson.encode(payload), "\n")
        io.stdout:flush()
    end
end

return _M

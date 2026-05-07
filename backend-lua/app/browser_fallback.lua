local cjson = require("cjson")
local logger = require("app.logger")

local _M = {}

local function shell_quote(value)
    return '"' .. tostring(value):gsub('"', '""') .. '"'
end

local function resolve_script_path()
    local candidates = {
        "scripts/browser_fallback.py",
        "../scripts/browser_fallback.py",
    }

    for _, path in ipairs(candidates) do
        local f = io.open(path, "rb")
        if f then
            f:close()
            return path
        end
    end

    return "scripts/browser_fallback.py"
end

local function detect_python()
    local override = os.getenv("PYTHON")
    if override and override ~= "" then return override end
    -- Linux: prefer python3
    if package.config:sub(1, 1) == "/" then
        return "python3"
    end
    return "python"
end

local function is_windows()
    return package.config:sub(1, 1) == "\\"
end

function _M.fetch(url, mode)
    local python = detect_python()
    local inner_cmd = table.concat({
        shell_quote(python),
        shell_quote(resolve_script_path()),
        "--url",
        shell_quote(url),
        "--mode",
        shell_quote(mode or "feed"),
        "2>&1",
    }, " ")
    local cmd
    if is_windows() then
        cmd = 'cmd /c ' .. shell_quote(inner_cmd)
    else
        cmd = inner_cmd
    end

    local handle = io.popen(cmd, "r")
    if not handle then
        return nil, "browser fallback popen failed"
    end

    local raw = handle:read("*a")
    handle:close()

    if not raw or raw == "" then
        return nil, "browser fallback empty output"
    end

    local ok, decoded = pcall(cjson.decode, raw)
    if not ok or type(decoded) ~= "table" then
        logger.warn("Browser fallback returned invalid JSON", {
            url = url,
            output = raw:sub(1, 400),
        })
        return nil, "browser fallback invalid json"
    end

    if not decoded.ok then
        return nil, decoded.error or "browser fallback failed"
    end

    return decoded
end

return _M

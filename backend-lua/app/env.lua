local _M = {}

local raw_getenv = os.getenv
local values = {}

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function path_exists(path)
    if not path or path == "" then
        return false
    end

    local ok, _, code = os.rename(path, path)
    if ok then
        return true
    end

    return code == 13
end

function _M.get(key, default)
    local value = values[key]
    if value == nil then
        value = raw_getenv(key)
    end

    if value == nil or value == "" then
        return default
    end

    return value
end

function _M.set(key, value)
    if value == nil then
        values[key] = nil
        return
    end

    values[key] = tostring(value)
end

function _M.load_dotenv(path)
    local file = io.open(path, "r")
    if not file then
        return false
    end

    for l in file:lines() do
        local line = trim(l)
        if line ~= "" and not line:match("^#") then
            local key, value = line:match("^([%w_]+)%s*=%s*(.*)$")
            if key then
                value = value:gsub('^"', ""):gsub('"$', ""):gsub("^'", ""):gsub("'$", "")
                value = value:match("^(.-)%s*#") or value
                _M.set(key, trim(value))
            end
        end
    end

    file:close()
    return true
end

function _M.first_existing(candidates)
    for _, candidate in ipairs(candidates or {}) do
        if path_exists(candidate) then
            return candidate
        end
    end
    return nil
end

function _M.first_with_existing_parent(candidates)
    for _, candidate in ipairs(candidates or {}) do
        local dir = candidate and candidate:match("^(.*)[/\\]")
        if dir and path_exists(dir) then
            return candidate
        end
    end

    return candidates and candidates[1] or nil
end

os.getenv = function(key)
    return _M.get(key)
end

os.setenv = function(key, value)
    _M.set(key, value)
end

return _M

local env = require("app.env")
local cjson = require("cjson")
local csv = require("lua-csv.csv")

local _M = {}

function _M.encode_jsonb(tbl)
    return cjson.encode(tbl)
end

function _M.decode_jsonb(blob)
    if blob == nil or blob == "" then
        return {}
    end
    if type(blob) == "table" then
        return blob
    end
    if type(blob) == "string" then
        local ok, result = pcall(cjson.decode, blob)
        if ok then return result end
    end
    return {}
end

function _M.parse_csv(text)
    if not text or text == "" then
        return {}
    end

    local result = {}
    local lines = {}
    for line in text:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
    end
    if #lines < 2 then return result end

    -- Parse header
    local headers = {}
    local pos = 1
    local field = ""
    local in_quotes = false
    for i = 1, #lines[1] do
        local c = lines[1]:sub(i, i)
        if c == '"' then
            in_quotes = not in_quotes
        elseif c == ',' and not in_quotes then
            headers[#headers + 1] = field:gsub('^%s*', ""):gsub('%s*$', "")
            field = ""
        else
            field = field .. c
        end
    end
    headers[#headers + 1] = field:gsub('^%s*', ""):gsub('%s*$', "")

    -- Parse data rows
    for i = 2, #lines do
        local row = {}
        local values = {}
        field = ""
        in_quotes = false
        for j = 1, #lines[i] do
            local c = lines[i]:sub(j, j)
            if c == '"' then
                in_quotes = not in_quotes
            elseif c == ',' and not in_quotes then
                values[#values + 1] = field:gsub('^%s*"', ""):gsub('"%s*$', ""):gsub('^%s+', ""):gsub('%s+$', "")
                field = ""
            else
                field = field .. c
            end
        end
        values[#values + 1] = field:gsub('^%s*"', ""):gsub('"%s*$', ""):gsub('^%s+', ""):gsub('%s+$', "")

        for col, key in ipairs(headers) do
            if values[col] then
                row[key] = values[col]
            end
        end
        if next(row) then
            result[#result + 1] = row
        end
    end
    return result
end

function _M.now_iso()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function _M.iso_from_timestamp(ts)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", ts)
end

function _M.parse_iso(iso_str)
    if not iso_str then return nil end
    local year, month, day, hour, min, sec =
        iso_str:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not year then return nil end
    return {
        year = tonumber(year), month = tonumber(month), day = tonumber(day),
        hour = tonumber(hour), min = tonumber(min), sec = tonumber(sec),
    }
end

function _M.hours_between(iso1, iso2)
    local t1 = _M.parse_iso(iso1)
    local t2 = _M.parse_iso(iso2)
    if not t1 or not t2 then return nil end
    local ts1 = os.time(t1)
    local ts2 = os.time(t2)
    return math.abs(os.difftime(ts2, ts1)) / 3600
end

function _M.load_dotenv(path)
    return env.load_dotenv(path)
end

function _M.trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function _M.starts_with(s, prefix)
    return s:sub(1, #prefix) == prefix
end

function _M.clamp(val, min_val, max_val)
    return math.max(min_val, math.min(max_val, val))
end

function _M.table_contains(tbl, value)
    for _, v in ipairs(tbl) do
        if v == value then return true end
    end
    return false
end

return _M

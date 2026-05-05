-- utils.lua — JSON, CSV, date helpers, .env parser, string utilities
local cjson = require("cjson")
local csv = require("lua-csv")

local _M = {}

-- ── JSON ─────────────────────────────────────────────────────────────────

function _M.encode_jsonb(tbl)
    """Encode a table to JSON text for jsonb() SQL function.
    SQLite's jsonb() converts text JSON → binary JSONB at INSERT time.
    """
    return cjson.encode(tbl)
end

function _M.decode_jsonb(blob)
    """Decode JSONB text (from json(data) in SQL) back to Lua table."""
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

-- ── CSV ──────────────────────────────────────────────────────────────────

function _M.parse_csv(text)
    """Parse CSV text into array of tables (header row → keys)."""
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
    for h in lines[1]:gmatch('([^,]+)') do
        headers[#headers + 1] = h:gsub('^%s*"', ""):gsub('"%s*$', ""):gsub('^%s+', ""):gsub('%s+$', "")
    end

    -- Parse rows
    for i = 2, #lines do
        local row = {}
        local col = 1
        for v in lines[i]:gmatch('([^,]+)') do
            local key = headers[col]
            if key then
                local val = v:gsub('^%s*"', ""):gsub('"%s*$', ""):gsub('^%s+', ""):gsub('%s+$', "")
                row[key] = val
            end
            col = col + 1
        end
        if next(row) then
            result[#result + 1] = row
        end
    end
    return result
end

-- ── Date / Time ──────────────────────────────────────────────────────────

function _M.now_iso()
    """Return current UTC time as ISO-8601 string."""
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function _M.iso_from_timestamp(ts)
    """Convert Unix timestamp to ISO-8601 UTC string."""
    return os.date("!%Y-%m-%dT%H:%M:%SZ", ts)
end

function _M.parse_iso(iso_str)
    """Parse ISO-8601 string to {year, month, day, hour, min, sec} table, or nil."""
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
    """Return hours elapsed between two ISO-8601 strings."""
    local t1 = _M.parse_iso(iso1)
    local t2 = _M.parse_iso(iso2)
    if not t1 or not t2 then return nil end
    local ts1 = os.time(t1)
    local ts2 = os.time(t2)
    return math.abs(os.difftime(ts2, ts1)) / 3600
end

-- ── .env parser ──────────────────────────────────────────────────────────

function _M.load_dotenv(path)
    """Load KEY=VALUE pairs from a .env file into os environment.
    Handles comments (#), quotes, and empty lines.
    """
    local file = io.open(path, "r")
    if not file then return end

    for line in file:lines() do
        line = line:match("^%s*(.-)%s*$")  -- trim
        if line ~= "" and not line:match("^#") then
            local key, value = line:match("^([%w_]+)%s*=%s*(.*)$")
            if key then
                -- Strip surrounding quotes
                value = value:gsub('^"', ""):gsub('"$', ""):gsub("^'", ""):gsub("'$", "")
                -- Strip inline comments (unless inside quotes — simplified)
                value = value:match("^(.-)%s*#") or value
                os.setenv(key, value)
            end
        end
    end
    file:close()
end

-- ── String helpers ───────────────────────────────────────────────────────

function _M.trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function _M.starts_with(s, prefix)
    return s:sub(1, #prefix) == prefix
end

-- ── Math helpers ─────────────────────────────────────────────────────────

function _M.clamp(val, min_val, max_val)
    return math.max(min_val, math.min(max_val, val))
end

-- ── Table helpers ────────────────────────────────────────────────────────

function _M.table_contains(tbl, value)
    for _, v in ipairs(tbl) do
        if v == value then return true end
    end
    return false
end

return _M

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
        if ok then
            -- Some legacy lookup rows were inserted as JSON strings containing
            -- JSON objects. Decode one extra layer so callers always get tables.
            if type(result) == "string" and result:match("^%s*[%[{]") then
                local ok2, nested = pcall(cjson.decode, result)
                if ok2 then
                    return nested
                end
            end
            return result
        end
    end
    return {}
end

-- Normalize an article title for duplicate detection: lowercase, collapse
-- punctuation/whitespace runs into single spaces, trim edges. Shared by the
-- news sync (in-batch + cross-batch dedupe) and cleanup tools.
function _M.normalize_title(s)
    if type(s) ~= "string" then return "" end
    return s:lower():gsub("[%p%s]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Strip RSS boilerplate attribution suffixes from news descriptions. Some
-- feeds append a line like "O post [título] apareceu primeiro em [fonte]."
-- / "The post [title] appeared first on [source]." to the description text;
-- it adds visual noise in the UI and pollutes search. Shared by the RSS
-- scraper and cleanup tools.
--
-- The pattern set covers the real corpus (744+ rows), not just the canonical
-- forms: "appeared first in" (translated feeds), "first appeared on/in" word
-- order, "The <Word> post ..." prefixes (e.g. "The Dell post", "The Alcântara
-- post"), "<Owner>'s <Word> post ..." (e.g. "Petrobras' Plan post"), and
-- truncated suffixes where the source was cut off (ends in "appeared first"
-- or with a UTF-8 ellipsis). `[^%.]+` bounds the source name to the sentence
-- so trailing text after the boilerplate is preserved.
function _M.strip_boilerplate(desc)
    if type(desc) ~= "string" or desc == "" then return desc end
    -- PT: canonical + truncated (source cut off with an ellipsis)
    desc = desc:gsub("[Oo] post .+ apareceu primeiro em [^%.]+%.?%s*", "")
    desc = desc:gsub("[Oo] post .+ apareceu primeiro%s+…", "")
    -- EN canonical: "The post [title] appeared first on/in [source]."
    desc = desc:gsub("[Tt]he post .+ appeared first on [^%.]+%.?%s*", "")
    desc = desc:gsub("[Tt]he post .+ appeared first in [^%.]+%.?%s*", "")
    desc = desc:gsub("[Tt]he post .+ first appeared on [^%.]+%.?%s*", "")
    desc = desc:gsub("[Tt]he post .+ first appeared in [^%.]+%.?%s*", "")
    -- EN: "The <Word> post[title] ..." — note `.+` directly after "post" so
    -- a comma/punct right after "post" ("The Alcântara post, a quilombo...")
    -- still matches; the literal space would break on "post,".
    desc = desc:gsub("[Tt]he [^%s]+ post.+ appeared first on [^%.]+%.?%s*", "")
    desc = desc:gsub("[Tt]he [^%s]+ post.+ appeared first in [^%.]+%.?%s*", "")
    desc = desc:gsub("[Tt]he [^%s]+ post.+ first appeared on [^%.]+%.?%s*", "")
    desc = desc:gsub("[Tt]he [^%s]+ post.+ first appeared in [^%.]+%.?%s*", "")
    -- EN: "<Owner>'s <Word> post[title] ..." (e.g. "Petrobras' Plan post")
    desc = desc:gsub("[A-Z][^%s]-%'%s+[^%s]+ post.+ appeared first on [^%.]+%.?%s*", "")
    desc = desc:gsub("[A-Z][^%s]-%'%s+[^%s]+ post.+ appeared first in [^%.]+%.?%s*", "")
    desc = desc:gsub("[A-Z][^%s]-%'%s+[^%s]+ post.+ first appeared on [^%.]+%.?%s*", "")
    desc = desc:gsub("[A-Z][^%s]-%'%s+[^%s]+ post.+ first appeared in [^%.]+%.?%s*", "")
    -- EN truncated: suffix cut off (no source), anchored to end of string or
    -- followed by a UTF-8 ellipsis (feeds cut the source off mid-sentence)
    desc = desc:gsub("[Tt]he post .+ appeared first on%s*$", "")
    desc = desc:gsub("[Tt]he post .+ appeared first in%s*$", "")
    desc = desc:gsub("[Tt]he post .+ appeared first%s*$", "")
    desc = desc:gsub("[Tt]he [^%s]+ post.+ first appeared%s*$", "")
    desc = desc:gsub("[Tt]he [^%s]+ post.+ appeared first%s*$", "")
    desc = desc:gsub("[Tt]he post .+ appeared first%s*…", "")
    desc = desc:gsub("[Tt]he post .+ first appeared%s*…", "")
    desc = desc:gsub("[Tt]he [^%s]+ post.+ appeared first%s*…", "")
    desc = desc:gsub("[Tt]he [^%s]+ post.+ first appeared%s*…", "")
    -- EN: InfoAmazonia attribution "This content was first published on
    -- <source>, at <title>" — always appended at the end of the description,
    -- so greedy `.+` to end-of-string is safe. The `$`-anchored second pattern
    -- covers feeds that cut the source off mid-word ("... on InfoAma").
    desc = desc:gsub("[Tt]his content was first published on [^%,]+%s*,%s*at%s+.+", "")
    desc = desc:gsub("[Tt]his content was first published on [^%,]+$", "")
    return desc:gsub("^%s+", ""):gsub("%s+$", "")
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

local MONTHS = {
    jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6,
    jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12,
}

local function trim_text(value)
    if type(value) ~= "string" then
        return ""
    end
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parse_tz_offset(text)
    text = trim_text(text):upper()
    if text == "" or text == "Z" or text == "UTC" or text == "GMT" then
        return 0
    end

    local sign, hours, minutes = text:match("^([%+%-])(%d%d):?(%d?%d?)$")
    if not sign then
        return nil
    end

    minutes = minutes ~= "" and minutes or "00"
    local offset = (tonumber(hours) or 0) * 3600 + (tonumber(minutes) or 0) * 60
    if sign == "-" then
        offset = -offset
    end
    return offset
end

local function utc_iso_from_components(year, month, day, hour, minute, second, tz_offset_seconds)
    local local_guess = os.time({
        year = tonumber(year),
        month = tonumber(month),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(minute),
        sec = tonumber(second),
        isdst = false,
    })
    if not local_guess then
        return nil
    end

    local local_to_utc = os.difftime(os.time(os.date("!*t", local_guess)), local_guess)
    local ts = local_guess - local_to_utc - (tonumber(tz_offset_seconds) or 0)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", ts)
end

local function parse_news_date(raw)
    local text = trim_text(raw)
    if text == "" then
        return nil
    end

    local year, month, day, hour, minute, second, tail =
        text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$")
    if year then
        tail = trim_text((tail or ""):gsub("^%.%d+", ""))
        local offset = parse_tz_offset(tail)
        if offset ~= nil then
            return utc_iso_from_components(year, month, day, hour, minute, second, offset)
        end
    end

    local only_year, only_month, only_day = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if only_year then
        return utc_iso_from_components(only_year, only_month, only_day, "00", "00", "00", 0)
    end

    local cleaned = text:gsub("^%a+,%s+", "")
    local day2, month_name, year2, hour2, minute2, second2, tail2 =
        cleaned:match("^(%d?%d)%s+(%a+)%s+(%d%d%d%d)%s+(%d%d):(%d%d):(%d%d)%s*(.*)$")
    if day2 and month_name then
        local month_num = MONTHS[month_name:lower():sub(1, 3)]
        local offset = parse_tz_offset(tail2)
        if month_num and offset ~= nil then
            return utc_iso_from_components(year2, month_num, day2, hour2, minute2, second2, offset)
        end
    end

    return nil
end

function _M.normalize_news_date(raw, fallback)
    local normalized = parse_news_date(raw)
    if normalized then
        return normalized
    end

    normalized = parse_news_date(fallback)
    if normalized then
        return normalized
    end

    return _M.now_iso()
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

-- Julian Day Number (proleptic Gregorian). Used for timezone-safe day deltas.
local function jdn(y, m, d)
    local a = math.floor((14 - m) / 12)
    local y1 = y + 4800 - a
    local m1 = m + 12 * a - 3
    return d + math.floor((153 * m1 + 2) / 5)
        + 365 * y1 + math.floor(y1 / 4) - math.floor(y1 / 100) + math.floor(y1 / 400) - 32045
end

-- Day delta between two ISO date strings (date-only prefix is enough).
-- Returns integer days (date2 - date1) in UTC, independent of local timezone.
-- Non-ISO inputs return nil.
function _M.days_between_iso(date1, date2)
    local y1, m1, d1 = tostring(date1):match("^(....)-(..)-(..)")
    local y2, m2, d2 = tostring(date2):match("^(....)-(..)-(..)")
    if not y1 or not y2 then return nil end
    return jdn(tonumber(y2), tonumber(m2), tonumber(d2)) - jdn(tonumber(y1), tonumber(m1), tonumber(d1))
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

-- Shared bbox parser (routes DETER/AMS). Reads sw_lat/ne_lat/sw_lng/ne_lng from
-- args; returns a named-key table or nil+error. Identical to the previous local
-- copies in deter.lua/ams.lua so route behavior is unchanged.
function _M.parse_bbox(args)
    local sw_lat = tonumber(args.sw_lat)
    local ne_lat = tonumber(args.ne_lat)
    local sw_lng = tonumber(args.sw_lng)
    local ne_lng = tonumber(args.ne_lng)
    if not (sw_lat and ne_lat and sw_lng and ne_lng) then
        return nil, "Missing bbox (sw_lat, ne_lat, sw_lng, ne_lng)"
    end
    if sw_lat > ne_lat or sw_lng > ne_lng then
        return nil, "Invalid bbox (sw must be <= ne)"
    end
    return { sw_lat = sw_lat, ne_lat = ne_lat, sw_lng = sw_lng, ne_lng = ne_lng }
end

return _M

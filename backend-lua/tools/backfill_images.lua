-- Backfill urlToImage for news rows missing images, via og:image meta tag.
-- Usage: lua5.1 backend-lua/tools/backfill_images.lua [LIMIT]

package.path = "./backend-lua/?.lua;./backend-lua/?/init.lua;" .. package.path

local sqlite = require("lsqlite3")
local cjson = require("cjson")

local DB_PATH = os.getenv("SQLITE_PATH")
if not DB_PATH or DB_PATH == "" then
    DB_PATH = "./backend-lua/data/yvy.db"
end

local LIMIT = tonumber(arg[1]) or 200

local function decode_html_entities(s)
    if type(s) ~= "string" then return s end
    return (s:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#x27;", "'"):gsub("&#39;", "'"))
end

local function looks_bad(u)
    if type(u) ~= "string" or u == "" then return true end
    local lower = u:lower()
    if lower:sub(1, 5) == "data:" then return true end
    if lower:match("/none$") or lower:match("/null$") or lower:match("/undefined$") then return true end
    return false
end

local function extract_og_image(html_text)
    if type(html_text) ~= "string" or html_text == "" then return nil end
    local head_end = html_text:find("</head>", 1, true)
    local search_in = head_end and html_text:sub(1, head_end) or html_text:sub(1, 64 * 1024)
    local patterns = {
        '<meta[^>]+property=["\']og:image["\'][^>]+content=["\']([^"\']+)["\']',
        '<meta[^>]+content=["\']([^"\']+)["\'][^>]+property=["\']og:image["\']',
        '<meta[^>]+property=["\']og:image:url["\'][^>]+content=["\']([^"\']+)["\']',
        '<meta[^>]+name=["\']twitter:image["\'][^>]+content=["\']([^"\']+)["\']',
        '<meta[^>]+content=["\']([^"\']+)["\'][^>]+name=["\']twitter:image["\']',
        '<meta[^>]+name=["\']twitter:image:src["\'][^>]+content=["\']([^"\']+)["\']',
        '<meta[^>]+itemprop=["\']image["\'][^>]+content=["\']([^"\']+)["\']',
    }
    for _, p in ipairs(patterns) do
        local m = search_in:match(p)
        if m and m ~= "" then
            m = decode_html_entities(m)
            if not looks_bad(m) then
                if m:sub(1, 2) == "//" then m = "https:" .. m end
                return m
            end
        end
    end
    return nil
end

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function fetch_html(url)
    local cmd = "curl -sS -L --max-time 15 "
              .. "-A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' "
              .. "-H 'Accept-Language: pt-BR,pt;q=0.9,en;q=0.8' "
              .. "-H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' "
              .. shell_quote(url) .. " 2>/dev/null"
    local f = io.popen(cmd, "r")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    if not body or body == "" then return nil end
    return body
end

local db = sqlite.open(DB_PATH)
if not db then print("ERROR: cannot open DB " .. DB_PATH); os.exit(1) end
print("DB: " .. DB_PATH)
print("LIMIT: " .. LIMIT)

local rows = {}
for r in db:nrows("SELECT url, json(data) AS data_json FROM news ORDER BY publishedAt DESC LIMIT " .. LIMIT * 4) do
    local ok, d = pcall(cjson.decode, r.data_json or "{}")
    if ok and (not d.urlToImage or d.urlToImage == "" or looks_bad(d.urlToImage)) then
        rows[#rows + 1] = {url = r.url, data = d}
        if #rows >= LIMIT then break end
    end
end
print("missing image rows: " .. #rows)

local updated, failed = 0, 0
for i, r in ipairs(rows) do
    io.write(string.format("[%d/%d] %s ... ", i, #rows, r.url:sub(1, 80)))
    io.flush()
    local html = fetch_html(r.url)
    local img = html and extract_og_image(html) or nil
    if img then
        r.data.urlToImage = img
        local json = cjson.encode(r.data):gsub("'", "''")
        db:exec("UPDATE news SET data = jsonb('" .. json .. "') WHERE url = '" .. r.url:gsub("'", "''") .. "'")
        updated = updated + 1
        print("OK " .. img:sub(1, 80))
    else
        failed = failed + 1
        print("MISS")
    end
end

print(string.format("done. updated=%d failed=%d", updated, failed))
db:close()

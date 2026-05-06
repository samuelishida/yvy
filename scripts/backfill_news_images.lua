#!/usr/bin/env lua5.1
-- backfill_news_images.lua — Backfill missing urlToImage for Mongabay, O Eco, OC.eco.br
--
-- Finds news articles from target domains with missing images,
-- fetches each article URL via curl.exe, extracts the first image
-- from HTML (og:image, twitter:image, or <img src>), and updates
-- the JSONB data column in SQLite.
--
-- Usage:
--   lua5.1 scripts/backfill_news_images.lua [--dry-run] [--limit N]
--
-- Options:
--   --dry-run   Show what would be updated (no DB writes)
--   --limit N   Process max N articles (default: all)

local sqlite3 = require("lsqlite3")
local cjson   = require("cjson")

-- ── Config ──────────────────────────────────────────────────────────────

local DB_PATH = "data/yvy.db"

-- URL patterns to match (source_name is often nil for these sources)
-- Set to empty to backfill ALL sources with missing images
local URL_PATTERNS = {
    "oeco.org.br",
    "mongabay.com",
    "oc.eco.br",
}

-- When URL_PATTERNS is empty, backfill ALL articles with missing images
local BACKFILL_ALL = (#URL_PATTERNS == 0)

local HTTP_TIMEOUT = 15  -- seconds for curl

-- ── CLI args ────────────────────────────────────────────────────────────

local DRY_RUN = false
local LIMIT   = 0  -- 0 = all

for i = 1, #arg do
    if arg[i] == "--dry-run" then
        DRY_RUN = true
    elseif arg[i] == "--limit" and arg[i + 1] then
        LIMIT = tonumber(arg[i + 1]) or 0
    end
end

-- ── HTML image extraction ───────────────────────────────────────────────

local function extract_image_from_html(html)
    if not html or #html == 0 then return nil end

    -- 1. og:image (most reliable for news articles)
    local og = html:match('property="og:image"%s+content="([^"]+)"')
    if not og then
        og = html:match('content="([^"]+)"%s+property="og:image"')
    end
    if not og then
        og = html:match("property='og:image'%s+content='([^']+)'")
    end
    if og and #og > 10 then return og end

    -- 2. twitter:image
    local tw = html:match('name="twitter:image"%s+content="([^"]+)"')
    if not tw then
        tw = html:match('content="([^"]+)"%s+name="twitter:image"')
    end
    if tw and #tw > 10 then return tw end

    -- 3. First <img> with src — skip tiny icons, tracking pixels, SVGs, data URIs
    for src in html:gmatch('<img[^>]-src="([^"]+)"') do
        if #src > 15
            and not src:match("^data:")
            and not src:match("icon")
            and not src:match("logo")
            and not src:match("%.svg")
            and not src:match("pixel")
            and not src:match("1x1")
        then
            return src
        end
    end

    -- 4. Fallback: any <img> src
    local any_img = html:match('<img[^>]-src="([^"]+)"')
    if any_img and #any_img > 10 and not any_img:match("^data:") then
        return any_img
    end

    return nil
end

local function fetch_url(url)
    -- Use curl.exe with browser User-Agent (some sites block bots)
    local cmd = string.format(
        'curl.exe -sL --max-time %d --compressed -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" "%s" 2>NUL',
        HTTP_TIMEOUT, url
    )

    local handle = io.popen(cmd)
    if not handle then return nil, "popen failed" end
    local html = handle:read("*a")
    handle:close()

    if not html or #html == 0 then
        return nil, "empty response"
    end
    -- Detect 403/4xx block pages (tiny HTML with no real content)
    if #html < 200 and (html:match("403") or html:match("Forbidden") or html:match("denied")) then
        return nil, "blocked (403)"
    end
    return html
end

local function fetch_google_image(query)
    -- Use Google Images search to find an image for a query
    -- Returns the first image URL found, or nil
    local encoded_query = query:gsub("[^%w%d _-]", function(c)
        return string.format("%%%02X", string.byte(c))
    end):gsub(" ", "+")

    local url = "https://www.google.com/search?q=" .. encoded_query
        .. "&tbm=isch&udm=2"

    local cmd = string.format(
        'curl.exe -sL --max-time %d --compressed '
        .. '-A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36" '
        .. '"%s" 2>NUL',
        HTTP_TIMEOUT, url
    )

    local handle = io.popen(cmd)
    if not handle then return nil end
    local html = handle:read("*a")
    handle:close()

    if not html or #html == 0 then return nil end

    -- Try to extract image URLs from Google Images results
    -- Pattern 1: "ou":"https://..." (original URL in image metadata)
    for url in html:gmatch('"ou":"(https?://[^"]+)"') do
        if #url > 20
            and not url:match("gstatic")
            and not url:match("google")
            and not url:match("%.svg")
        then
            return url
        end
    end

    -- Pattern 2: "ptimg":"https://..." 
    for url in html:gmatch('"ptimg":"(https?://[^"]+)"') do
        if #url > 20 and not url:match("gstatic") then
            return url
        end
    end

    -- Pattern 3: src="https://..." in img tags (thumbnails)
    for src in html:gmatch('src="(https://[^"]+)"') do
        if #src > 30
            and not src:match("gstatic")
            and not src:match("google")
            and not src:match("%.svg")
            and not src:match("1x1")
        then
            return src
        end
    end

    return nil
end

-- ── Database ────────────────────────────────────────────────────────────

local function open_db()
    local db = sqlite3.open(DB_PATH)
    if not db then
        error("Cannot open database at " .. DB_PATH)
    end
    db:exec("PRAGMA journal_mode=WAL")
    db:exec("PRAGMA busy_timeout=5000")
    return db
end

local function find_missing_images(db, limit)
    local where_clause
    if BACKFILL_ALL then
        where_clause = "1=1"
    else
        -- Build WHERE clause from URL patterns
        local where_parts = {}
        for _, pat in ipairs(URL_PATTERNS) do
            where_parts[#where_parts + 1] = string.format("url LIKE '%%%s%%'", pat)
        end
        where_clause = table.concat(where_parts, " OR ")
    end

    local sql = string.format([[
        SELECT url, json(data) AS data_json
        FROM news
        WHERE (%s)
          AND (
            json_extract(data, '$.urlToImage') IS NULL
            OR json_extract(data, '$.urlToImage') = ''
          )
        ORDER BY publishedAt DESC
    ]], where_clause)

    if limit and limit > 0 then
        sql = sql .. string.format(" LIMIT %d", limit)
    end

    local result = {}
    for row in db:nrows(sql) do
        result[#result + 1] = {
            url = row.url,
            data_json = row.data_json,
        }
    end

    return result
end

local function update_news_image(db, url, image_url)
    -- Read current JSONB data
    local fetch_sql = "SELECT json(data) AS data_json FROM news WHERE url = ?"
    local stmt = db:prepare(fetch_sql)
    if not stmt then return false, "prepare fetch failed" end
    stmt:bind(1, url)

    local current_data = nil
    for row in stmt:nrows() do
        local ok, decoded = pcall(cjson.decode, row.data_json)
        if ok then current_data = decoded end
        break
    end
    stmt:finalize()

    if not current_data then return false, "no data found for url" end

    -- Update urlToImage
    current_data.urlToImage = image_url
    local updated_json = cjson.encode(current_data)

    -- Write back as JSONB
    local update_sql = "UPDATE news SET data = jsonb(?) WHERE url = ?"
    local ustmt = db:prepare(update_sql)
    if not ustmt then return false, "prepare update failed" end
    ustmt:bind(1, updated_json)
    ustmt:bind(2, url)

    local rc = ustmt:step()
    ustmt:finalize()

    if rc == sqlite3.DONE then
        return true
    else
        return false, "update step failed"
    end
end

-- ── Main ────────────────────────────────────────────────────────────────

local function main()
    local db = open_db()

    local total_processed = 0
    local total_updated = 0
    local total_failed = 0

    print("[INFO] Backfilling missing images for: " .. table.concat(URL_PATTERNS, ", "))
    if DRY_RUN then print("[DRY RUN] No database writes will occur") end
    print()

    local articles = find_missing_images(db, LIMIT > 0 and LIMIT or 0)
    print(string.format("[INFO] Found %d articles with missing images", #articles))
    print()

    if #articles == 0 then
        db:close()
        print("[DONE] Nothing to backfill.")
        return
    end

    if not DRY_RUN then
        db:exec("BEGIN")
    end

    for idx, article in ipairs(articles) do
        local url = article.url
        local short_url = #url > 70 and url:sub(1, 67) .. "..." or url
        io.write(string.format("  [%d/%d] %s => ", idx, #articles, short_url))
        io.flush()

        local image_url = nil
        local source = nil

        -- 1. Try direct article scrape
        local html, err = fetch_url(url)
        if html then
            image_url = extract_image_from_html(html)
            if image_url then source = "direct" end
        end

        -- 2. Fallback: Google Images search using article title
        if not image_url and article.data_json then
            local ok, data = pcall(cjson.decode, article.data_json)
            if ok and data then
                local title = data.title or data.title_en or ""
                if title ~= "" then
                    io.write("GOOGLE=> ")
                    io.flush()
                    image_url = fetch_google_image(title)
                    if image_url then source = "google" end
                end
            end
        end

        if not image_url then
            print("NO IMAGE FOUND")
            total_failed = total_failed + 1
        else
            local short_img = #image_url > 60 and image_url:sub(1, 57) .. "..." or image_url
            if DRY_RUN then
                print(string.format("WOULD SET (%s): %s", source, short_img))
                total_updated = total_updated + 1
            else
                local ok, uerr = update_news_image(db, url, image_url)
                if ok then
                    print(string.format("OK (%s): %s", source, short_img))
                    total_updated = total_updated + 1
                else
                    print("DB ERROR: " .. (uerr or "unknown"))
                    total_failed = total_failed + 1
                end
            end
        end

        total_processed = total_processed + 1

        -- Commit batch every 10 articles
        if not DRY_RUN and total_processed % 10 == 0 then
            db:exec("COMMIT")
            db:exec("BEGIN")
            print(string.format("  [BATCH] Committed %d updates so far", total_updated))
        end
    end

    if not DRY_RUN then
        db:exec("COMMIT")
    end
    db:close()

    print()
    print("[RESULTS]")
    print(string.format("  Processed:  %d", total_processed))
    print(string.format("  Updated:    %d", total_updated))
    print(string.format("  Failed:     %d", total_failed))
    if DRY_RUN then
        print("  (DRY RUN — no changes written)")
    end
end

main()

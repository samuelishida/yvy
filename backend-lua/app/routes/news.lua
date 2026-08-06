-- news.lua - /api/news, /api/news/refresh, /api/news/repair

require("app.env")
local db = require("app.db")
local auth = require("app.middleware.auth")
local rl = require("app.middleware.rate_limit")
local scrapers = require("app.scrapers")
local translate = require("app.translate")
local cjson = require("cjson")
local logger = require("app.logger")
local utils = require("app.utils")
local redis = require("app.redis")

local _M = {}

local NEWS_CACHE_TTL = 300
local RECENT_NEWS_MINUTES = 15
local REPAIR_SCAN_LIMIT = 500

local function news_cache_key(lang, page, page_size)
    return "news:" .. lang .. ":" .. page .. ":" .. page_size
end

local function normalize_text(value)
    if type(value) ~= "string" then
        return ""
    end
    return utils.trim(value)
end

local function has_text(value)
    return normalize_text(value) ~= ""
end

local function clear_bad_en(article)
    if article.title_en and translate.is_mymemory_warning(article.title_en) then
        article.title_en = nil
        article.title_en_bad = true
    end
    if article.description_en and translate.is_mymemory_warning(article.description_en) then
        article.description_en = nil
        article.description_en_bad = true
    end
end

local function get_cached_translations(urls)
    return db.get_news_fields_by_urls(urls, {"title_en", "description_en"})
end

local function batch_translate(texts, source_lang, target_lang)
    local chain = translate.new_chain()
    local results = {}
    for i, text in ipairs(texts) do
        if text and text ~= "" then
            results[i] = chain:translate(text, source_lang, target_lang)
        else
            results[i] = ""
        end
    end
    return results
end

local function save_en_to_db(articles)
    for _, article in ipairs(articles) do
        local updates = {}
        if article.title_en and article.title_en ~= "" then
            updates.title_en = article.title_en
        end
        if article.description_en and article.description_en ~= "" then
            updates.description_en = article.description_en
        end
        if next(updates) then
            db.update_news_fields(article.url, updates)
        end
    end
end

local function wipe_bad_en_from_db(bad_title_urls, bad_desc_urls)
    if #bad_title_urls > 0 then
        db.clear_news_fields(bad_title_urls, {"title_en"})
    end
    if #bad_desc_urls > 0 then
        db.clear_news_fields(bad_desc_urls, {"description_en"})
    end
end

local function iter_news_candidates(limit)
    limit = limit or REPAIR_SCAN_LIMIT
    local total = db.count_news()
    local page = 1
    local page_size = 100
    local candidates = {}

    while #candidates < limit and ((page - 1) * page_size) < total do
        local articles = db.get_news_page(page, page_size, "pt")
        if not articles or #articles == 0 then
            break
        end

        for _, article in ipairs(articles) do
            clear_bad_en(article)
            local missing_title = (not article.title_en or article.title_en == "") and has_text(article.title)
            local missing_desc = (not article.description_en or article.description_en == "") and has_text(article.description)
            if missing_title or missing_desc then
                candidates[#candidates + 1] = article
                if #candidates >= limit then
                    break
                end
            end
        end

        page = page + 1
    end

    return candidates
end

local function repair_bad_translations(limit)
    local candidates = iter_news_candidates(limit)
    local repaired, failed, skipped = 0, 0, 0

    if #candidates == 0 then
        return {repaired = 0, failed = 0, skipped = 0}
    end

    local chain = translate.new_chain()
    for _, article in ipairs(candidates) do
        local updates = {}
        local changed = false

        local title = normalize_text(article.title)
        local description = normalize_text(article.description)

        if (not article.title_en or article.title_en == "") and title ~= "" then
            local title_en = chain:translate(title, "pt", "en")
            if title_en and title_en ~= "" and not translate.is_mymemory_warning(title_en) then
                updates.title_en = title_en
                changed = true
            end
        end

        if (not article.description_en or article.description_en == "") and description ~= "" then
            local description_en = chain:translate(description, "pt", "en")
            if description_en and description_en ~= "" and not translate.is_mymemory_warning(description_en) then
                updates.description_en = description_en
                changed = true
            end
        end

        if changed then
            db.update_news_fields(article.url, updates)
            repaired = repaired + 1
        else
            skipped = skipped + 1
        end
    end

    return {repaired = repaired, failed = failed, skipped = skipped}
end

function _M.get_news(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local args = ctx.req.args
    local page = tonumber(args.page)
    local page_size = tonumber(args.page_size)
    local lang = (args.lang or "pt"):lower()

    if page == nil then page = 1 end
    if page_size == nil then page_size = 20 end
    if page < 1 then
        ctx:error(400, "'page' must be >= 1.")
        return
    end
    if page_size < 1 or page_size > 100 then
        ctx:error(400, "'page_size' must be between 1 and 100.")
        return
    end
    if lang ~= "pt" and lang ~= "en" then
        lang = "pt"
    end

    local cache_key = news_cache_key(lang, page, page_size)
    local cached = redis.get(cache_key)
    if cached then
        ctx:set_header("Cache-Control", "public, max-age=300")
        ctx:send(200, cached)
        return
    end

    local articles = db.get_news_page(page, page_size, "pt")
    local bad_title_urls = {}
    local bad_desc_urls = {}

    -- Read path only: never translate or repair synchronously (blocks request).
    -- Background news_sync_loop + admin /api/news/repair handle translation.
    -- Missing EN strings fall back to PT on the client side.
    for _, article in ipairs(articles) do
        clear_bad_en(article)
        if article.title_en_bad then
            bad_title_urls[#bad_title_urls + 1] = article.url
            article.title_en_bad = nil
        end
        if article.description_en_bad then
            bad_desc_urls[#bad_desc_urls + 1] = article.url
            article.description_en_bad = nil
        end

        if lang == "en" then
            if article.title_en and article.title_en ~= "" then
                article.title = article.title_en
            end
            if article.description_en and article.description_en ~= "" then
                article.description = article.description_en
            end
        end
    end

    if #bad_title_urls > 0 or #bad_desc_urls > 0 then
        pcall(wipe_bad_en_from_db, bad_title_urls, bad_desc_urls)
    end

    local body = cjson.encode(articles)
    redis.set(cache_key, body, NEWS_CACHE_TTL)
    ctx:set_header("Cache-Control", "public, max-age=300")
    ctx:send(200, body)
end

function _M.fetch_and_save_news(opts)
    opts = opts or {}
    if not opts.force and db.has_recent_news(RECENT_NEWS_MINUTES) then
        logger.info("Recent news already available. Skipping fetch.")
        return db.get_news_page(1, 20, "pt")
    end

    local fetched = scrapers.fetch_all()
    if #fetched == 0 then
        logger.warn("No articles fetched from any RSS source")
        return db.get_news_page(1, 20, "pt")
    end

    local function norm_title(s)
        if type(s) ~= "string" then return "" end
        return s:lower():gsub("[%p%s]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    end

    local deduped = {}
    local seen_urls = {}
    local seen_titles = {}
    for _, article in ipairs(fetched) do
        local url = article.url or ""
        url = url:gsub("/$", "")  -- strip trailing slash
        if url ~= "" and not seen_urls[url] then
            local nt = norm_title(article.title)
            if nt == "" or not seen_titles[nt] then
                seen_urls[url] = true
                if nt ~= "" then seen_titles[nt] = true end
                article.url = url
                article.ingested_at = article.ingested_at or utils.now_iso()
                deduped[#deduped + 1] = article
            end
        end
    end

    -- Enrich missing images via og:image fetch (bounded internally)
    pcall(scrapers.enrich_missing_images, deduped)

    local urls = {}
    for _, article in ipairs(deduped) do
        urls[#urls + 1] = article.url
    end

    local cached = get_cached_translations(urls)
    local texts_to_translate = {}
    local translate_map = {}

    for i, article in ipairs(deduped) do
        local cached_en = cached[article.url] or {}
        local pt_title = normalize_text(article.title)
        local pt_desc = normalize_text(article.description)

        if cached_en.title_en and not translate.is_mymemory_warning(cached_en.title_en) then
            article.title_en = cached_en.title_en
        elseif pt_title ~= "" then
            texts_to_translate[#texts_to_translate + 1] = pt_title
            translate_map[#translate_map + 1] = {index = i, field = "title"}
        end

        if cached_en.description_en and not translate.is_mymemory_warning(cached_en.description_en) then
            article.description_en = cached_en.description_en
        elseif pt_desc ~= "" then
            texts_to_translate[#texts_to_translate + 1] = pt_desc
            translate_map[#translate_map + 1] = {index = i, field = "description"}
        end
    end

    if #texts_to_translate > 0 then
        local translations = batch_translate(texts_to_translate, "pt", "en")
        for idx, map in ipairs(translate_map) do
            local val = translations[idx]
            if val and val ~= "" and not translate.is_mymemory_warning(val) then
                deduped[map.index][map.field .. "_en"] = val
            end
        end
    end

    db.bulk_upsert_news(deduped)
    redis.delete_pattern("news:*")
    pcall(repair_bad_translations, 50)
    logger.info("News sync complete: " .. #deduped .. " articles")
    return db.get_news_page(1, 20, "pt")
end

-- Spawns a detached subprocess (tools/news_sync.lua) to run the full news
-- sync. Never blocks the copas loop — os.execute returns immediately for a
-- backgrounded command, and the blocking HTTP/translation work runs off-loop.
-- A Redis lock (setnx, TTL 1800s) prevents duplicate syncs.
function _M.trigger_news_sync(force)
    force = force or false

    -- NB: NOT "news:sync:lock" — fetch_and_save_news calls
    -- redis.delete_pattern("news:*") at the end of every sync, which would
    -- wipe a lock named under the "news:" prefix. This key must outlive the
    -- sync for its full TTL to guard against overlapping syncs.
    local lock_key = "news_sync:lock"
    if not redis.setnx(lock_key, "1", 1800) then
        return false  -- another sync is already in flight
    end

    local source = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    local backend_dir = source:match("^(.*[/\\])app[/\\]routes[/\\]") or ""
    local script = backend_dir .. "tools/news_sync.lua"

    local cmd
    if package.config:sub(1, 1) == "\\" then
        cmd = 'start /b lua5.1.exe "' .. script .. '" ' .. (force and "1" or "0") .. ' >NUL 2>NUL'
    else
        cmd = 'nohup lua5.1 "' .. script .. '" ' .. (force and "1" or "0") .. ' >/dev/null 2>&1 &'
    end

    local ok, err = pcall(os.execute, cmd)
    if not ok then
        logger.warn("Failed to spawn news sync: " .. tostring(err))
    end
    return true
end

function _M.refresh_news(ctx)
    if os.getenv("AUTH_REQUIRED") == "1" then
        if not auth.enforce(ctx) then return end
    end
    if not rl.enforce(ctx) then return end

    local force = ctx.req.args and (ctx.req.args.force == "1" or ctx.req.args.force == "true")
    local triggered = _M.trigger_news_sync(force)
    ctx:json(200, {
        status = triggered and "sync_triggered" or "sync_in_progress",
        forced = force or false,
    })
end

function _M.repair_news(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local result = repair_bad_translations(REPAIR_SCAN_LIMIT)
    redis.delete_pattern("news:*")
    result.status = "repair_complete"
    ctx:json(200, result)
end

function _M.admin_news_sync(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    logger.info("Manual news sync triggered (detached subprocess)")
    local triggered = _M.trigger_news_sync(false)
    ctx:json(200, {
        status = triggered and "sync_triggered" or "sync_in_progress",
        message = "News sync running in background. /api/news refreshes when it completes.",
    })
end

return _M

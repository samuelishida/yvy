-- news.lua — /api/news, /api/news/refresh, /api/news/repair
-- Baremetal Lua version

require("app.env")
local db        = require("app.db")
local auth      = require("app.middleware.auth")
local rl        = require("app.middleware.rate_limit")
local scrapers  = require("app.scrapers")
local translate = require("app.translate")
local cjson     = require("cjson")
local logger    = require("app.logger")

local _M = {}

-- In-memory news cache
local news_cache = {}
local NEWS_CACHE_TTL = 300

-- ── GET /api/news ────────────────────────────────────────────────────────

function _M.get_news(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local args = ctx.req.args
    local page = tonumber(args.page) or 1
    local page_size = tonumber(args.page_size) or 20
    local lang = (args.lang or "pt"):lower()

    if page < 1 then page = 1 end
    if page_size < 1 or page_size > 100 then page_size = 20 end
    if lang ~= "pt" and lang ~= "en" then lang = "pt" end

    local cache_key = "news_" .. lang .. "_" .. page .. "_" .. page_size
    local cached = news_cache[cache_key]
    if cached and os.time() - cached.time < NEWS_CACHE_TTL then
        ctx:set_header("Cache-Control", "public, max-age=300")
        ctx:send(200, cached.body)
        return
    end

    local articles = db.get_news_page(page, page_size, lang)
    local body = cjson.encode(articles)
    news_cache[cache_key] = {time = os.time(), body = body}

    ctx:set_header("Cache-Control", "public, max-age=300")
    ctx:send(200, body)
end

-- ── News sync ────────────────────────────────────────────────────────────

function _M.fetch_and_save_news()
    local articles = scrapers.fetch_all()
    if #articles == 0 then
        logger.warn("No articles fetched from any RSS source")
        return {}
    end

    local chain = translate.new_chain()
    for _, article in ipairs(articles) do
        local pt_title = article.title or ""
        local pt_desc = article.description or ""
        if pt_title ~= "" then article.title_en = chain:translate(pt_title, "pt", "en") end
        if pt_desc ~= "" then article.description_en = chain:translate(pt_desc, "pt", "en") end
    end

    db.bulk_upsert_news(articles)
    news_cache = {}
    logger.info("News sync complete: " .. #articles .. " articles")
    return articles
end

-- ── POST /api/news/refresh ───────────────────────────────────────────────

function _M.refresh_news(ctx)
    if os.getenv("AUTH_REQUIRED") == "1" then
        if not auth.enforce(ctx) then return end
    end
    if not rl.enforce(ctx) then return end

    _M.fetch_and_save_news()
    ctx:json(200, {status = "refreshed"})
end

-- ── POST /api/news/repair ────────────────────────────────────────────────

function _M.repair_news(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local articles = db.get_news_page(1, 100, "pt")
    local chain = translate.new_chain()
    local repaired = 0

    for _, article in ipairs(articles) do
        local needs_repair = false
        local updates = {}

        if not article.title_en or article.title_en == ""
            or translate.is_mymemory_warning(article.title_en) then
            if article.title and article.title ~= "" then
                local t = chain:translate(article.title, "pt", "en")
                if t and not translate.is_mymemory_warning(t) then
                    updates.title_en = t; needs_repair = true
                end
            end
        end

        if not article.description_en or article.description_en == ""
            or translate.is_mymemory_warning(article.description_en) then
            if article.description and article.description ~= "" then
                local t = chain:translate(article.description, "pt", "en")
                if t and not translate.is_mymemory_warning(t) then
                    updates.description_en = t; needs_repair = true
                end
            end
        end

        if needs_repair then
            db.update_news_fields(article.url, updates)
            repaired = repaired + 1
        end
    end

    news_cache = {}
    ctx:json(200, {status = "repair_complete", repaired = repaired, failed = 0, skipped = #articles - repaired})
end

-- ── POST /api/admin/news/sync ────────────────────────────────────────────

function _M.admin_news_sync(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    logger.info("Manual news sync triggered")
    local articles = _M.fetch_and_save_news()
    ctx:json(200, {status = "success", message = "News sync complete. " .. #articles .. " articles available.", count = #articles})
end

return _M


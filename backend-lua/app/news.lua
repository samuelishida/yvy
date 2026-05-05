-- news.lua — /api/news, /api/news/refresh, /api/news/repair
-- Port of backend/news_sqlite.py + backend/backend.py news routes

local db        = require("app.db")
local auth      = require("app.auth")
local rl        = require("app.rate_limit")
local scrapers  = require("app.scrapers")
local translate = require("app.translate")
local cjson     = require("cjson")

local _M = {}

-- In-memory news cache (per-worker)
local news_cache = {}
local NEWS_CACHE_TTL = 300  -- 5 minutes

-- ── GET /api/news ────────────────────────────────────────────────────────

function _M.get_news()
    auth.enforce()
    rl.enforce()

    local args = ngx.req.get_uri_args()
    local page = tonumber(args.page) or 1
    local page_size = tonumber(args.page_size) or 20
    local lang = (args.lang or "pt"):lower()

    if page < 1 then page = 1 end
    if page_size < 1 or page_size > 100 then page_size = 20 end
    if lang ~= "pt" and lang ~= "en" then lang = "pt" end

    local cache_key = "news_" .. lang .. "_" .. page .. "_" .. page_size
    local cached = news_cache[cache_key]
    if cached and ngx.time() - cached.time < NEWS_CACHE_TTL then
        ngx.header["Content-Type"] = "application/json"
        ngx.header["Cache-Control"] = "public, max-age=300"
        ngx.say(cached.body)
        return
    end

    local articles = db.get_news_page(page, page_size, lang)
    local body = cjson.encode(articles)

    news_cache[cache_key] = {time = ngx.time(), body = body}

    ngx.header["Content-Type"] = "application/json"
    ngx.header["Cache-Control"] = "public, max-age=300"
    ngx.say(body)
end

-- ── News sync (fetch + translate + save) ─────────────────────────────────

function _M.fetch_and_save_news()
    """Fetch RSS articles, translate PT→EN, save to DB. Returns articles."""
    -- Fetch from RSS scrapers
    local articles = scrapers.fetch_all()

    if #articles == 0 then
        ngx.log(ngx.WARN, "No articles fetched from any RSS source")
        return {}
    end

    -- Translate PT → EN
    local chain = translate.new_chain()
    local semaphore_count = 3
    local active = 0
    local translated = {}

    -- Simple concurrency limiter using coroutines
    local co_tasks = {}
    for _, article in ipairs(articles) do
        local co = coroutine.create(function()
            local pt_title = article.title or ""
            local pt_desc = article.description or ""

            if pt_title ~= "" then
                article.title_en = chain:translate(pt_title, "pt", "en")
            end
            if pt_desc ~= "" then
                article.description_en = chain:translate(pt_desc, "pt", "en")
            end
        end)
        co_tasks[#co_tasks + 1] = co
    end

    -- Run in batches of 3
    for i = 1, #co_tasks, semaphore_count do
        local batch = {}
        for j = i, math.min(i + semaphore_count - 1, #co_tasks) do
            batch[#batch + 1] = co_tasks[j]
        end
        for _, co in ipairs(batch) do
            coroutine.resume(co)
        end
    end

    -- Save to DB
    db.bulk_upsert_news(articles)

    -- Clear cache
    news_cache = {}

    ngx.log(ngx.INFO, "News sync complete: ", #articles, " articles")
    return articles
end

-- ── POST /api/news/refresh ───────────────────────────────────────────────

function _M.refresh_news()
    if os.getenv("AUTH_REQUIRED") == "1" then
        auth.enforce()
    end
    rl.enforce()

    _M.fetch_and_save_news()

    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"status":"refreshed"}')
end

-- ── POST /api/news/repair ────────────────────────────────────────────────

function _M.repair_news()
    auth.enforce()
    rl.enforce()

    -- Find articles with bad/missing EN translations
    local db_conn = require("app.db")
    -- We need raw DB access for the repair query
    -- For now, do a simpler approach: re-translate recent articles
    local articles = db.get_news_page(1, 100, "pt")
    local chain = translate.new_chain()
    local repaired = 0

    for _, article in ipairs(articles) do
        local needs_repair = false
        local updates = {}

        if not article.title_en or article.title_en == ""
            or translate.is_mymemory_warning(article.title_en) then
            if article.title and article.title ~= "" then
                local translated = chain:translate(article.title, "pt", "en")
                if translated and not translate.is_mymemory_warning(translated) then
                    updates.title_en = translated
                    needs_repair = true
                end
            end
        end

        if not article.description_en or article.description_en == ""
            or translate.is_mymemory_warning(article.description_en) then
            if article.description and article.description ~= "" then
                local translated = chain:translate(article.description, "pt", "en")
                if translated and not translate.is_mymemory_warning(translated) then
                    updates.description_en = translated
                    needs_repair = true
                end
            end
        end

        if needs_repair then
            db.update_news_fields(article.url, updates)
            repaired = repaired + 1
        end
    end

    news_cache = {}

    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({
        status = "repair_complete",
        repaired = repaired,
        failed = 0,
        skipped = #articles - repaired,
    }))
end

-- ── POST /api/admin/news/sync ────────────────────────────────────────────

function _M.admin_news_sync()
    auth.enforce()
    rl.enforce()

    ngx.log(ngx.INFO, "Manual news sync triggered")
    local articles = _M.fetch_and_save_news()

    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({
        status = "success",
        message = "News sync complete. " .. #articles .. " articles available.",
        count = #articles,
    }))
end

return _M

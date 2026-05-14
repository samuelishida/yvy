-- scrapers.lua — RSS scraper for Brazilian environmental news sources
-- Baremetal Lua version using http_client + LuaExpat

local http_client = require("app.http_client")
local browser_fallback = require("app.browser_fallback")
local lxp         = require("lxp")
local cjson       = require("cjson")
local utils       = require("app.utils")
local logger      = require("app.logger")

local _M = {}

-- ── Keyword relevance filter ─────────────────────────────────────────────

local KEYWORDS_PT = {
    "desmatamento", "queimada", "queimadas", "incêndio", "incêndios",
    "fogo", "fumaça", "brumagem",
    "amazônia", "amazon", "cerrado", "pantanal", "mata atlântica",
    "caatinga", "pampa", "bioma", "biomas", "floresta", "florestas",
    "manguezal", "restinga",
    "clima", "climático", "climática", "mudança climática", "mudanças climáticas",
    "aquecimento global", "efeito estufa", "gases de efeito estufa",
    "carbono", "emissão", "emissões", "neutralidade", "descarbonização",
    "seca", "estiagem", "enchente", "alagamento", "inundação", "tempestade",
    "ciclone", "furacão", "el niño", "la niña",
    "biodiversidade", "espécie ameaçada", "extinção", "fauna", "flora",
    "conservação", "área protegida", "unidade de conservação",
    "terra indígena", "território indígena", "ibama", "icmbio",
    "poluição", "contaminação", "agrotóxico", "pesticida",
    "lixo", "resíduo", "reciclagem", "plástico", "microplástico",
    "qualidade do ar", "qualidade da água", "esgoto",
    "sustentabilidade", "sustentável", "energia renovável", "energia solar",
    "energia eólica", "transição energética", "matriz energética",
    "prodes", "inpe", "terrabrasillis",
    "meio ambiente", "ambiental", "ecologia", "ecológico",
    "preservação", "reflorestamento", "áreas verdes",
    "mineração", "mineração em águas profundas", "minerais críticos", "minerais",
    "extrativismo", "extrativista", "recursos naturais", "recursos minerais",
    "vida marinha", "oceano", "oceanos", "fundo do mar", "fundo oceânico",
    "águas profundas", "biodiversidade marinha", "ecossistema marinho",
    "pesca", "sobrepesca", "mangue", "recife de coral", "coral",
    "licença ambiental", "licenciamento ambiental", "impacto ambiental",
    "projeto de lei", "legislação ambiental", "política ambiental",
}

local KEYWORDS_EN = {
    "deforestation", "wildfire", "wildland fire", "amazon", "cerrado",
    "pantanal", "atlantic forest", "biome", "forest", "mangrove",
    "climate", "climate change", "global warming", "greenhouse gas",
    "carbon", "emissions", "net zero", "decarbonization",
    "drought", "flood", "flooding", "hurricane", "cyclone",
    "el nino", "la nina", "biodiversity", "endangered species",
    "extinction", "conservation", "protected area", "indigenous land",
    "pollution", "contamination", "pesticide", "plastic", "microplastic",
    "air quality", "water quality", "sewage",
    "sustainability", "sustainable", "renewable energy", "solar energy",
    "wind energy", "energy transition", "environmental",
    "ecology", "ecological", "reforestation", "green areas",
    "ibama", "inpe",
    "deep-sea mining", "deep sea mining", "seabed mining", "critical minerals",
    "extractivism", "natural resources", "marine life", "ocean", "oceans",
    "deep sea", "deep water", "marine biodiversity", "marine ecosystem",
    "overfishing", "coral reef", "coral", "fishing",
    "environmental license", "environmental impact", "environmental policy",
    "environmental legislation", "mining",
}

-- Build combined keyword list (longest first for matching)
local all_keywords = {}
for _, kw in ipairs(KEYWORDS_PT) do all_keywords[#all_keywords + 1] = kw end
for _, kw in ipairs(KEYWORDS_EN) do all_keywords[#all_keywords + 1] = kw end
table.sort(all_keywords, function(a, b) return #a > #b end)

function _M.is_relevant(article)
    local text = (article.title or "") .. " " .. (article.description or "")
    text = text:lower()
    for _, kw in ipairs(all_keywords) do
        if text:find(kw, 1, true) then  -- plain substring match
            return true
        end
    end
    return false
end

-- ── RSS feed sources ─────────────────────────────────────────────────────

local RSS_SOURCES = {
    {
        name = "Amazônia Real",
        url = "https://amazoniareal.com.br/feed/",
    },
    {
        name = "InfoAmazônia",
        url = "https://infoamazonia.org/feed/",
    },
    {
        name = "O Eco",
        url = "https://oeco.org.br/feed/",
    },
    {
        name = "Mongabay Brasil",
        url = "https://brasil.mongabay.com/feed/",
    },
    {
        name = "Greenpeace Brasil",
        url = "https://www.greenpeace.org/brasil/feed/",
    },
    {
        name = "ISA",
        url = "https://www.socioambiental.org/pt-br/feed",
    },
    {
        name = "WWF Brasil",
        url = "https://www.wwf.org.br/feed/",
    },
    {
        name = "Observatório do Clima",
        url = "https://www.oc.eco.br/feed/",
    },
}

-- ── RSS XML parser (SAX-based via LuaExpat) ──────────────────────────────

local function parse_rss(xml_text, source_name)
    local articles = {}
    local current = {}
    local in_item = false
    local text_buffer = {}
    local current_tag = nil

    local callbacks = {
        StartElement = function(parser, name, attrs)
            if name == "item" or name == "entry" then
                in_item = true
                current = {source_name = source_name}
            end
            if in_item then
                current_tag = name
                text_buffer = {}
            end
        end,

        CharacterData = function(parser, text)
            if in_item and current_tag then
                text_buffer[#text_buffer + 1] = text
            end
        end,

        EndElement = function(parser, name)
            if in_item and current_tag then
                local text = table.concat(text_buffer):gsub("^%s+", ""):gsub("%s+$", "")
                local tag = current_tag:lower()

                if tag == "title" then
                    current.title = text
                elseif tag == "link" then
                    if not current.url then
                        current.url = text
                    end
                elseif tag == "description" or tag == "summary" or tag == "content" then
                    -- Strip HTML tags for description
                    local desc = text:gsub("<[^>]+>", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
                    if not current.description or #desc > #(current.description or "") then
                        current.description = desc
                    end
                    
                    -- Extract first <img src="..."> from HTML content if no image yet
                    if not current.urlToImage and text:find("<img") then
                        local img_src = text:match('src%s*=%s*["\']([^"\']+)["\']')
                        if img_src then
                            current.urlToImage = img_src
                        end
                    end
                elseif tag == "pubdate" or tag == "published" or tag == "updated" or tag == "date" then
                    current.publishedAt = text
                elseif tag == "enclosure" then
                    -- handled in StartElement via attrs
                elseif tag == "media:content" or tag == "content" then
                    -- handled in StartElement
                end

                current_tag = nil
                text_buffer = {}
            end

            if (name == "item" or name == "entry") and in_item then
                in_item = false
                if current.url and current.title then
                    local ingested_at = utils.now_iso()
                    current.publishedAt = utils.normalize_news_date(current.publishedAt, ingested_at)
                    current.ingested_at = ingested_at
                    current.urlToImage = current.urlToImage or nil
                    current.content = current.content or ""

                    articles[#articles + 1] = current
                end
                current = {}
            end
        end,
    }

    -- Handle enclosure/media attributes in StartElement
    local orig_start = callbacks.StartElement
    callbacks.StartElement = function(parser, name, attrs)
        orig_start(parser, name, attrs)
        if in_item and attrs then
            local tag = name:lower()
            if tag == "enclosure" or tag == "media:content" or tag == "media:thumbnail" then
                local url = attrs.url or attrs["url"]
                if url and not current.urlToImage then
                    current.urlToImage = url
                end
            end
            if tag == "link" and attrs.href and not current.url then
                current.url = attrs.href
            end
        end
    end

    local ok, err = pcall(function()
        local parser = lxp.new(callbacks)
        parser:parse(xml_text)
        parser:close()
    end)

    if not ok then
        logger.warn("RSS parse error for " .. source_name .. ": " .. tostring(err))
    end

    return articles
end

-- ── Fetch all sources ────────────────────────────────────────────────────

local function looks_blocked(status, body)
    if status == 403 or status == 429 or status == 503 then
        return true
    end
    if type(body) ~= "string" or body == "" then
        return false
    end

    local lowered = body:lower()
    return lowered:find("captcha", 1, true)
        or lowered:find("cloudflare", 1, true)
        or lowered:find("attention required", 1, true)
        or lowered:find("verify you are human", 1, true)
        or lowered:find("access denied", 1, true)
        or lowered:find("/cdn-cgi/challenge", 1, true)
end

local function maybe_fetch_with_browser(source, res, err)
    if res and res.status == 404 then
        return res, err
    end
    if res and not looks_blocked(res.status, res.body) then
        return res, err
    end

    logger.warn("Trying browser fallback for RSS source", {
        source = source.name,
        url = source.url,
        status = res and res.status or nil,
        error = err,
    })

    local browser_res, browser_err = browser_fallback.fetch(source.url, "feed")
    if not browser_res then
        logger.warn("Browser fallback failed for RSS source", {
            source = source.name,
            url = source.url,
            error = browser_err,
        })
        return res, err
    end

    return {
        status = browser_res.status or 0,
        body = browser_res.body or browser_res.html or "",
        headers = {},
    }, nil
end

-- ── Per-article image enrichment (og:image / twitter:image) ─────────────

local function decode_html_entities(s)
    if type(s) ~= "string" then return s end
    return (s:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#x27;", "'"):gsub("&#39;", "'"))
end

local function looks_bad_image_url(u)
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
            if not looks_bad_image_url(m) then
                if m:sub(1, 2) == "//" then m = "https:" .. m end
                return m
            end
        end
    end
    return nil
end

local function fetch_article_image(url)
    if type(url) ~= "string" or url == "" then return nil end
    local res, _ = http_client.get(url, {
        headers = {
            ["User-Agent"] = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            ["Accept-Language"] = "pt-BR,pt;q=0.9,en;q=0.8",
        },
        timeout = 10,
        retries = 1,
    })
    if res and res.status == 200 and res.body then
        local img = extract_og_image(res.body)
        if img then return img end
    end
    if res and looks_blocked(res.status, res.body) then
        local browser_res = browser_fallback.fetch(url, "page")
        if browser_res and (browser_res.html or browser_res.body) then
            return extract_og_image(browser_res.html or browser_res.body)
        end
    end
    return nil
end

-- Enrich articles missing urlToImage by fetching article HTML and reading og:image.
-- Bounded by ENRICH_LIMIT to avoid making ingest take forever on cold runs.
local ENRICH_LIMIT = 40
function _M.enrich_missing_images(articles)
    local enriched = 0
    for _, a in ipairs(articles) do
        if enriched >= ENRICH_LIMIT then break end
        if not a.urlToImage or a.urlToImage == "" or looks_bad_image_url(a.urlToImage) then
            local img = fetch_article_image(a.url)
            if img then
                a.urlToImage = img
                enriched = enriched + 1
                logger.info("Enriched image for " .. (a.source_name or "?") .. ": " .. tostring(a.url))
            end
        end
    end
    if enriched > 0 then
        logger.info("Enriched " .. enriched .. " article images via og:image")
    end
    return enriched
end

function _M.fetch_all()
    local all_articles = {}

    for _, source in ipairs(RSS_SOURCES) do
        logger.info("Fetching RSS: " .. source.name .. " (" .. source.url .. ")")
        local res, err = http_client.get(source.url, {
            headers = {
                ["User-Agent"] = "Mozilla/5.0 (compatible; YvyApp/1.0; environmental-monitoring)",
                ["Accept"] = "application/rss+xml, application/atom+xml, application/xml, text/xml",
            },
            timeout = 15,
        })
        res, err = maybe_fetch_with_browser(source, res, err)

        if not res or res.status ~= 200 then
            logger.warn("RSS fetch failed for " .. source.name .. ": " .. tostring(err or (res and res.status)))
        else
            local articles = parse_rss(res.body, source.name)
            for _, article in ipairs(articles) do
                if _M.is_relevant(article) then
                    all_articles[#all_articles + 1] = article
                end
            end

            logger.info("RSS " .. source.name .. ": " .. #articles .. " articles, " .. #all_articles .. " relevant total")
        end
    end

    table.sort(all_articles, function(a, b)
        local a_date = utils.normalize_news_date(a.publishedAt, a.ingested_at)
        local b_date = utils.normalize_news_date(b.publishedAt, b.ingested_at)
        if a_date ~= b_date then
            return a_date > b_date
        end

        local a_ingested = a.ingested_at or ""
        local b_ingested = b.ingested_at or ""
        if a_ingested ~= b_ingested then
            return a_ingested > b_ingested
        end

        local a_url = a.url or ""
        local b_url = b.url or ""
        if a_url ~= b_url then
            return a_url < b_url
        end

        local a_source = a.source_name or ""
        local b_source = b.source_name or ""
        return a_source < b_source
    end)

    return all_articles
end

return _M

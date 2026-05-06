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
                    -- Normalize publishedAt to ISO-8601
                    if current.publishedAt then
                        -- Try to parse common RSS date formats
                        local patterns = {
                            "(%d%d%d?%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)",
                            "(%d%d? %a%a%a? %d%d%d%d %d%d:%d%d:%d%d)",
                        }
                        for _, pat in ipairs(patterns) do
                            local m = current.publishedAt:match(pat)
                            if m then
                                current.publishedAt = m
                                break
                            end
                        end
                    end
                    if not current.publishedAt or current.publishedAt == "" then
                        current.publishedAt = utils.now_iso()
                    end

                    current.ingested_at = utils.now_iso()
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

    return all_articles
end

return _M

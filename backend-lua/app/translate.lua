-- translate.lua — Multi-provider translation chain
-- Baremetal Lua version using http_client + logger
-- MyMemory → LibreTranslate → Google Translate

local http_client = require("app.http_client")
local cjson       = require("cjson")
local logger      = require("app.logger")

local _M = {}

local MYMEMORY_API_URL = "https://api.mymemory.translated.net/get"

-- Regex matches MyMemory quota-exhaustion warning
local MYMEMORY_WARNING_PATTERN = "MYMEMORY%s+WARNING.*YOU%s+USED%s+ALL%s+AVAILABLE%s+FREE%s+TRANSLATIONS"

local TranslatorChain = {}
TranslatorChain.__index = TranslatorChain

function TranslatorChain:new()
    return setmetatable({
        mymemory_quota_exhausted = false,
    }, self)
end

function TranslatorChain:translate(text, source_lang, target_lang)
    if not text or text == "" then
        return ""
    end

    if not self.mymemory_quota_exhausted then
        local result = self:_try_mymemory(text, source_lang, target_lang)
        if result and not _M.is_mymemory_warning(result) then
            return result
        end
    end

    local result = self:_try_libre(text, source_lang, target_lang)
    if result then
        return result
    end

    result = self:_try_google(text, source_lang, target_lang)
    if result then
        return result
    end

    return ""
end

function TranslatorChain:_try_mymemory(text, source_lang, target_lang)
    local res, err = http_client.get(MYMEMORY_API_URL, {
        query = {
            q = text:sub(1, 500),
            langpair = source_lang .. "|" .. target_lang,
        },
        timeout = 15,
    })

    if not res or res.status ~= 200 then return nil end

    local ok, data = pcall(cjson.decode, res.body)
    if not ok then return nil end

    local status = data.responseStatus
    local translation = data.responseData and data.responseData.translatedText or ""

    if status ~= 200 or translation == "" then return nil end

    if _M.is_mymemory_warning(translation) then
        self.mymemory_quota_exhausted = true
        logger.warn("MyMemory quota exhausted. Switching to fallbacks.")
        return nil
    end

    if translation:lower() == text:lower() then return nil end
    return translation
end

function TranslatorChain:_try_libre(text, source_lang, target_lang)
    local res, err = http_client.post("https://libretranslate.de/translate", {
        body = {q = text, source = source_lang, target = target_lang},
        headers = {["Content-Type"] = "application/json"},
        timeout = 10,
    })

    if not res or res.status ~= 200 then return nil end

    local ok, data = pcall(cjson.decode, res.body)
    if not ok then return nil end

    local translation = data.translatedText or ""
    if translation ~= "" and translation:lower() ~= text:lower() then
        return translation
    end
    return nil
end

function TranslatorChain:_try_google(text, source_lang, target_lang)
    local res, err = http_client.get("https://translate.googleapis.com/translate_a/single", {
        query = {
            client = "gtx", sl = source_lang, tl = target_lang,
            dt = "t", q = text:sub(1, 5000),
        },
        timeout = 10,
    })

    if not res or res.status ~= 200 then return nil end

    local ok, data = pcall(cjson.decode, res.body)
    if not ok then return nil end

    if type(data) == "table" and #data > 0
        and type(data[1]) == "table" and #data[1] > 0
        and type(data[1][1]) == "table" and #data[1][1] > 0 then
        local translation = data[1][1][1]
        if translation and translation ~= "" and translation:lower() ~= text:lower() then
            return translation
        end
    end
    return nil
end

-- ── Warning detection ────────────────────────────────────────────────────

function _M.is_mymemory_warning(text)
    if type(text) ~= "string" then return false end
    return text:match(MYMEMORY_WARNING_PATTERN) ~= nil
end

function _M.new_chain()
    return TranslatorChain:new()
end

return _M


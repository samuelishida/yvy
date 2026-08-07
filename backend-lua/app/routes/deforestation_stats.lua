-- deforestation_stats.lua — /api/deforestation/historical
-- Serves INPE PRODES annual Amazônia Legal totals from a static JSON.

local env    = require("app.env")
local auth   = require("app.middleware.auth")
local rl     = require("app.middleware.rate_limit")
local redis  = require("app.redis")
local db     = require("app.db")
local cjson  = require("cjson")
local logger = require("app.logger")

local _M = {}

local CACHE_KEY = "deforestation:historical"
local CACHE_TTL = 86400  -- 24h

local _cached_body
local _cached_etag

local function djb2_hex(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + string.byte(s, i)) % 4294967296
    end
    return string.format("%08x", h)
end

local function load_body()
    if _cached_body then return _cached_body, _cached_etag end

    local cached = redis.get(CACHE_KEY)
    if cached then
        _cached_body = cached
        _cached_etag = '"' .. djb2_hex(cached) .. '"'
        return _cached_body, _cached_etag
    end

    local paths = {
        "backend-lua/data/prodes_historical.json",
        "data/prodes_historical.json",
        "/opt/yvy/backend-lua/data/prodes_historical.json",
        "../backend-lua/data/prodes_historical.json",
    }
    local override = env.get("PRODES_HISTORICAL_PATH")
    if override and override ~= "" then table.insert(paths, 1, override) end
    local resolved = env.first_existing(paths)
    if not resolved then
        logger.warn("prodes_historical.json not found")
        return nil, nil
    end

    local f = io.open(resolved, "r")
    if not f then return nil, nil end
    local body = f:read("*a")
    f:close()

    _cached_body = body
    _cached_etag = '"' .. djb2_hex(body) .. '"'
    redis.set(CACHE_KEY, body, CACHE_TTL)
    return _cached_body, _cached_etag
end

function _M.get_historical(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local body, etag = load_body()
    if not body then
        ctx:json(503, {error = "PRODES historical data unavailable"})
        return
    end

    ctx:set_header("Cache-Control", "public, max-age=3600")
    ctx:set_header("ETag", etag)
    local inm = ctx.req.headers and ctx.req.headers["if-none-match"]
    if inm and inm == etag then
        ctx:send(304, "")
        return
    end
    ctx:send(200, body)
end

-- ── Territorial deforestation stats (plan: terrabrasilis-integration, Inc 7)
--
-- Os agregados são PRÉ-COMPUTADOS offline (scripts/precompute_deforestation_stats.py
-- roda o spatial join deforestation_data × municípios/UC/TI e grava JSON blobs
-- em lookup_data: `def_stats:<tipo>:<year>`). As rotas só leem lookup_data —
-- nada de spatial join ao vivo no loop copas.

-- Ano válido (2000-2025) ou "all" (agrega todos os anos).
local function check_year(year)
    if year == "all" then return true end
    local y = tonumber(year)
    if not y or y < 2000 or y > 2025 then return false end
    return true
end

-- official_km2 da comparação (spec §4.5). prodes_historical.json hoje só tem
-- totais anuais da Amazônia (sem breakdown por município/estado), então
-- retorna nil para quase tudo — o campo existe para o contrato da API e passa
-- a ter valor se o JSON ganhar entradas por estado/ano.
local _official
local function load_official()
    if _official ~= nil then return _official end
    _official = {}
    local paths = {
        "backend-lua/data/prodes_historical.json",
        "data/prodes_historical.json",
        "/opt/yvy/backend-lua/data/prodes_historical.json",
    }
    local resolved = env.first_existing(paths)
    if not resolved then return _official end
    local f = io.open(resolved, "r")
    if not f then return _official end
    local body = f:read("*a")
    f:close()
    local ok, data = pcall(cjson.decode, body)
    if ok and type(data) == "table" and type(data.yearly) == "table" then
        for _, e in ipairs(data.yearly) do
            if e.state and e.year then
                _official[e.state .. ":" .. e.year] = e.area_km or e.amazon_km2
            end
        end
    end
    return _official
end

local function official_km2(uf, year)
    local off = load_official()
    return off[uf .. ":" .. year] or off["AM:" .. year] or nil
end

local function read_def_stats(tipo, year)
    return db.get_lookup_data("def_stats:" .. tipo .. ":" .. year)
end

-- Resposta comum: itens ordenados por área desc + filtro uf + limit.
local function serve_stats(ctx, tipo, name_field)
    local args = ctx.req.args
    local year = (type(args.year) == "string" and args.year ~= "") and args.year or "all"
    if not check_year(year) then
        ctx:error(400, "invalid year (2000-2025 or 'all')")
        return
    end
    local uf = (type(args.uf) == "string" and args.uf ~= "") and args.uf:upper() or nil
    local limit = tonumber(args.limit) or 20
    if limit < 1 then limit = 1 end
    if limit > 200 then limit = 200 end
    local compare_official = args.compare_official == "true"

    local stats = read_def_stats(tipo, year)
    if not stats or type(stats.items) ~= "table" then
        ctx:json(200, { items = {}, precomputed = false, year = year })
        return
    end

    local items = {}
    for _, it in ipairs(stats.items) do
        if not uf or (it.uf or "") == uf then
            items[#items + 1] = it
        end
    end
    table.sort(items, function(a, b) return (a.area_km2 or 0) > (b.area_km2 or 0) end)

    local total = #items
    if #items > limit then
        local out = {}
        for i = 1, limit do out[i] = items[i] end
        items = out
    end

    if compare_official then
        for _, it in ipairs(items) do
            it.official_km2 = official_km2(it.uf or (it.key or ""):sub(1, 2), year)
        end
    end

    ctx:json(200, { items = items, total = total, precomputed = true, year = year })
end

function _M.get_by_municipality(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end
    serve_stats(ctx, "municipio")
end

function _M.get_by_uc(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end
    serve_stats(ctx, "uc")
end

function _M.get_by_ti(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end
    serve_stats(ctx, "ti")
end

return _M

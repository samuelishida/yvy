-- fires.lua — /api/fires, /api/fires/sync, /api/admin/firms/sync
-- Baremetal Lua version using ctx-based request/response

require("app.env")
local db         = require("app.db")
local auth       = require("app.middleware.auth")
local rl         = require("app.middleware.rate_limit")
local redis      = require("app.redis")
local utils      = require("app.utils")
local http_client = require("app.http_client")
local cjson      = require("cjson")
local logger     = require("app.logger")
local state_lookup = require("app.lookups.state_lookup")

local _M = {}

local FIRMS_MAP_KEY = os.getenv("FIRMS_MAP_KEY") or ""
local FIRMS_SOURCE = os.getenv("FIRMS_SOURCE") or "VIIRS_SNPP_NRT"
local FIRMS_DAY_RANGE = tonumber(os.getenv("FIRMS_DAY_RANGE") or "3")
local FIRMS_BBOX = "-74,-34,-34,5.5"
local MAX_RESULTS = tonumber(os.getenv("MAX_RESULTS_PER_REQUEST") or "10000")

-- Brazil bounding box (sw_lat, ne_lat, sw_lng, ne_lng) — clamp default queries here
local BR_SW_LAT, BR_NE_LAT, BR_SW_LNG, BR_NE_LNG = -34.0, 5.5, -74.0, -34.0

local GLOBAL_BBOXES = {
    "-180,-90,-90,90",
    "-90,-90,0,90",
    "0,-90,90,90",
    "90,-90,180,90",
}

-- ── GET /api/fire-detail ────────────────────────────────────────────────
-- Dados pesados (nature_evidence) sob demanda para o popup, evitando
-- inflar a listagem de /api/fires.
function _M.get_fire_detail(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local id = tonumber(ctx.req.args.id)
    if not id then
        ctx:error(400, "missing id")
        return
    end

    local fire = db.find_fire_by_id(id)
    if not fire then
        ctx:error(404, "fire not found")
        return
    end

    ctx:json(200, { fire = fire })
end

-- ── GET /api/fires ───────────────────────────────────────────────────────

function _M.get_fires(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local args = ctx.req.args
    local ne_lat = args.ne_lat
    local ne_lng = args.ne_lng
    local sw_lat = args.sw_lat
    local sw_lng = args.sw_lng

    -- (a) Whitelist de source (canônica), ANTES do cache: o cache key embute
    -- apenas params canônicos, então ?source=ams (inválido) nunca vira chave.
    local source = args.source or ""
    if source ~= "" and source ~= "firms" and source ~= "bdqueimadas" then
        ctx:error(400, "invalid source"); return
    end

    -- (plan: sinaflor-fogo-permitido) ?days=N opcional (1..365): janela de datas
    -- via find_fires_since — permite ver focos antigos (ex: permitido fora da
    -- moratória) que o cap de 10k dos "mais recentes" esconderia.
    local days = nil
    if args.days ~= nil and args.days ~= "" then
        days = tonumber(args.days)
        if not days or days < 1 then days = 1 end
        if days > 365 then days = 365 end
    end

    -- ?limit=N opcional (500..50000): cap de resultados para o frontend não
    -- travar com 50k CircleMarkers. Sem limit, usa o default de cada query.
    local limit = nil
    if args.limit ~= nil and args.limit ~= "" then
        limit = tonumber(args.limit)
        if not limit or limit < 500 then limit = 500 end
        if limit > 50000 then limit = 50000 end
    end

    local cache_key = "firescache:" .. (ne_lat or "global") .. ":" .. (ne_lng or "") .. ":" .. (sw_lat or "") .. ":" .. (sw_lng or "") .. (args.vegetation == "true" and ":veg" or "") .. (source ~= "" and (":" .. source) or "") .. (days and (":days" .. days) or "") .. (limit and (":lim" .. limit) or "")

    local cached = redis.get(cache_key)
    if cached then
        ctx:set_header("Cache-Control", "public, max-age=60")
        ctx:send(200, cached)
        return
    end

    if ne_lat and ne_lng and sw_lat and sw_lng then
        ne_lat = tonumber(ne_lat); ne_lng = tonumber(ne_lng)
        sw_lat = tonumber(sw_lat); sw_lng = tonumber(sw_lng)
        if not ne_lat or not ne_lng or not sw_lat or not sw_lng then
            ctx:error(400, "Invalid coordinates."); return
        end
        -- (c) range-clamp: lat/lon fora dos limites geográficos são limitados,
        -- não rejeitados (viewports/zoom extremos não viram 400).
        ne_lat = math.max(-90, math.min(90, ne_lat))
        sw_lat = math.max(-90, math.min(90, sw_lat))
        ne_lng = math.max(-180, math.min(180, ne_lng))
        sw_lng = math.max(-180, math.min(180, sw_lng))
        if ne_lat <= sw_lat or ne_lng <= sw_lng then
            ctx:error(400, "Invalid bbox."); return
        end
    else
        sw_lat, ne_lat, sw_lng, ne_lng = BR_SW_LAT, BR_NE_LAT, BR_SW_LNG, BR_NE_LNG
    end

    -- Mapa carrega apenas focos dentro do Brasil (state atribuído = polígono IBGE).
    -- Pontos em países vizinhos (dentro do bbox) são excluídos.
    -- Filtro opcional de fonte (Inc 10): ?source=bdqueimadas|firms|all
    local source_filter
    if source == "bdqueimadas" then
        source_filter = "%BDQ%"
    elseif source == "firms" then
        source_filter = "NASA_FIRMS%"
    end
    local data
    if days then
        -- Janela de datas (find_fires_since): default 50000 — durante a
        -- moratória (jul-out) os mais recentes são todos 'crime', e um limite
        -- baixo truncaria os 'permitido' (Abr-Jun). O frontend faz zoom-gate
        -- (z<7 não renderiza) + viewport-clip para performance.
        data = db.find_fires_since(days, sw_lat, ne_lat, sw_lng, ne_lng, limit or 50000, true)
    else
        data = db.find_fires(sw_lat, ne_lat, sw_lng, ne_lng, limit or MAX_RESULTS, true, source_filter)
    end

    -- Inc 8 (plan: terrabrasilis-integration): ?vegetation=true cruza cada foco
    -- com PRODES no local — UMA query de deforestation_data por bbox + atribuição.
    if args.vegetation == "true" then
        local veg_map = db.get_vegetation_context_batch(sw_lat, ne_lat, sw_lng, ne_lng, data)
        for i, f in ipairs(data) do
            f.vegetation = veg_map[i]  -- (d) batch sempre devolve o mapa completo
        end
    end

    local last_sync = redis.get("fires:last_sync")

    local response = cjson.encode({fires = data, last_sync = last_sync})
    redis.set(cache_key, response, 60)
    ctx:set_header("Cache-Control", "public, max-age=60")
    ctx:send(200, response)
end

-- ── FIRMS data fetch ─────────────────────────────────────────────────────

function _M.fetch_firms_data(global_sync)
    if FIRMS_MAP_KEY == "" then
        logger.warn("FIRMS_MAP_KEY not configured, skipping fire data sync")
        return 0
    end

    local bboxes = global_sync and GLOBAL_BBOXES or {FIRMS_BBOX}
    local total_count = 0

    for _, bbox in ipairs(bboxes) do
        local url = "https://firms.modaps.eosdis.nasa.gov/api/area/csv/"
            .. FIRMS_MAP_KEY .. "/" .. FIRMS_SOURCE .. "/" .. bbox .. "/" .. FIRMS_DAY_RANGE

        logger.info("Fetching FIRMS fire data: " .. url)
        local res, err = http_client.get(url, {timeout = 60})
        if not res then
            logger.error("FIRMS fetch error: " .. tostring(err))
        elseif res.status ~= 200 then
            logger.error("FIRMS API returned " .. res.status)
        else
            local docs = utils.parse_csv(res.body)
            local fire_docs = {}
            for _, row in ipairs(docs) do
                local lat = tonumber(row.latitude or row["latitude"])
                local lon = tonumber(row.longitude or row["longitude"])
                if lat and lon and lat >= -90 and lat <= 90 and lon >= -180 and lon <= 180 then
                    -- VIIRS CSV usa coluna "type" (0=veg, 1=industrial, 2=offshore, 3=water);
                    -- MODIS usa "fire_type". Tentamos "type" primeiro, converte
                    -- numérico p/ number (ativa ramo fire_type_industrial_num do
                    -- thermal_weak), string p/ lowercase (ramo fire_type_industrial).
                    local fire_type_raw = row.type or row["type"]
                        or row.fire_type or row["fire_type"] or ""
                    local fire_type
                    local ft_num = tonumber(fire_type_raw)
                    if ft_num ~= nil then
                        fire_type = ft_num
                    else
                        fire_type = tostring(fire_type_raw):lower()
                    end

                    fire_docs[#fire_docs + 1] = {
                        lat = lat, lon = lon,
                        confidence = (row.confidence or row["confidence"] or "low"):lower(),
                        acq_date = row.acq_date or row["acq_date"] or "",
                        acq_time = row.acq_time or row["acq_time"] or "",
                        satellite = row.satellite or row["satellite"] or "",
                        bright_ti4 = tonumber(row.bright_ti4 or row["bright_ti4"] or 0) or 0,
                        fire_type = fire_type,
                        frp = tonumber(row.frp or row["frp"] or 0) or 0,
                        daynight = (row.daynight or row["daynight"] or ""):upper(),
                        source = "NASA_FIRMS_VIIRS_SNPP",
                        state = state_lookup.classify_point(lon, lat),
                        ingested_at = utils.now_iso(),
                    }
                end
            end

            if #fire_docs > 0 then db.bulk_upsert_fires(fire_docs) end
            total_count = total_count + #fire_docs
        end
    end

    redis.delete_pattern("firescache:*")
    -- Invalidate all derived caches that depend on fire data: dashboard
    -- timeseries, by-state breakdowns, stats summary, biomes, and
    -- protected-share. Without this, the dashboard showed stale data for
    -- up to 60-300s after a FIRMS sync (same class of bug as the news
    -- "set antigo" — cache outliving the data it represents).
    redis.delete_pattern("fires:ts:*")
    redis.delete_pattern("fires:bystate:*")
    redis.delete("stats:all")
    redis.delete("biomes:all")
    redis.delete("fires:protected_share")
    redis.set("fires:last_sync", utils.now_iso(), 3600)
    logger.info("FIRMS sync complete: " .. total_count .. " records")
    return total_count
end

-- ── GET /api/fires/timeseries ────────────────────────────────────────────

function _M.get_fires_timeseries(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local args = ctx.req.args or {}
    local days = tonumber(args.days) or 30
    if days < 1 then days = 1 end
    if days > 365 then days = 365 end
    local state = type(args.state) == "string" and args.state ~= "" and args.state:upper() or nil

    local cache_key = "fires:ts:" .. days .. (state and (":" .. state) or "")
    local cached = redis.get(cache_key)
    if cached then
        ctx:set_header("Cache-Control", "public, max-age=60")
        ctx:send(200, cached)
        return
    end

    local series = db.get_fires_timeseries(days, state)
    local body = cjson.encode({days = days, state = state, series = series})
    redis.set(cache_key, body, 60)
    ctx:set_header("Cache-Control", "public, max-age=60")
    ctx:send(200, body)
end

-- ── GET /api/fires/by-state ──────────────────────────────────────────────

function _M.get_fires_by_state(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local args = ctx.req.args or {}
    local limit = tonumber(args.limit) or 10
    if limit < 1 then limit = 1 end
    if limit > 27 then limit = 27 end
    local days = tonumber(args.days)
    if days ~= nil and (days < 1 or days > 365) then
        ctx:json(400, {error = "days must be between 1 and 365"})
        return
    end

    local cache_key = "fires:bystate:" .. limit .. ":" .. (days or "all")
    local cached = redis.get(cache_key)
    if cached then
        ctx:set_header("Cache-Control", "public, max-age=60")
        ctx:send(200, cached)
        return
    end

    local data = db.get_fires_by_state(limit, days)
    local body = cjson.encode({limit = limit, days = days, states = data})
    redis.set(cache_key, body, 60)
    ctx:set_header("Cache-Control", "public, max-age=60")
    ctx:send(200, body)
end

-- ── GET /api/fires/by-biome (plan: dashboard-enhancement, Inc 4) ─────────

-- Agregado por bioma (persistido em $.biome) com filtro de dias/estado —
-- substitui o point-in-polygon do /api/biomes para o card filtrável.
function _M.get_by_biome(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local args = ctx.req.args or {}
    local days = tonumber(args.days)
    if days == nil then days = 30 end
    if days < 1 or days > 365 then
        ctx:json(400, {error = "days must be between 1 and 365"})
        return
    end
    local state = (type(args.state) == "string" and args.state ~= "") and args.state:upper() or nil
    if state then
        local found = false
        for _, uf in ipairs(state_lookup.list_ufs()) do
            if uf.sigla == state then found = true break end
        end
        if not found then
            ctx:json(400, {error = "invalid state"})
            return
        end
    end

    local cache_key = "fires:bybiome:" .. days .. ":" .. (state or "all")
    local cached = redis.get(cache_key)
    if cached then
        ctx:set_header("Cache-Control", "public, max-age=60")
        ctx:send(200, cached)
        return
    end

    local biomes, total = db.get_fires_by_biome(days, state)
    local body = cjson.encode({days = days, state = state, total = total, biomes = biomes})
    redis.set(cache_key, body, 120)
    ctx:set_header("Cache-Control", "public, max-age=60")
    ctx:send(200, body)
end

-- ── Fire nature stats (pure compute; rota em main.lua) ───────────────────

function _M.get_fire_nature_stats(days, state)
    days = days or 7
    local classes, total = db.count_fires_by_nature(days, state)
    local by_state = nil
    if not state or state == "" then
        by_state = db.count_fires_by_nature_by_state(days)
    end
    return {
        days = days,
        state = state,
        total = total,
        classes = classes,
        by_state = by_state,
    }
end

-- ── GET /api/fires/protected-share ───────────────────────────────────────

function _M.get_protected_share(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local cache_key = "fires:protected_share"
    local cached = redis.get(cache_key)
    if cached then
        ctx:set_header("Cache-Control", "public, max-age=300")
        ctx:send(200, cached)
        return
    end

    local alerts_raw = redis.get("alerts:all")
    local indigenous_count, conservation_count = 0, 0
    if alerts_raw and alerts_raw ~= "" then
        local ok, decoded = pcall(cjson.decode, alerts_raw)
        if ok and type(decoded) == "table" then
            local alerts_list = decoded.alerts
            if type(alerts_list) == "table" then
                for _, a in ipairs(alerts_list) do
                    if type(a) == "table" then
                        local n = tonumber(a.fire_count) or 0
                        if a.type == "indigenous_land" then
                            indigenous_count = indigenous_count + n
                        elseif a.type == "conservation_unit" then
                            conservation_count = conservation_count + n
                        end
                    end
                end
            end
        end
    end

    local total_fires_row = db.get_stats()
    local total = (total_fires_row and total_fires_row.fires) or 0
    local protected = indigenous_count + conservation_count
    local other = math.max(0, total - protected)

    local body = cjson.encode({
        indigenous = indigenous_count,
        conservation = conservation_count,
        other = other,
        total = total,
    })
    redis.set(cache_key, body, 300)
    ctx:set_header("Cache-Control", "public, max-age=300")
    ctx:send(200, body)
end

-- ── POST /api/fires/sync ─────────────────────────────────────────────────

function _M.sync_fires(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local global_sync = ctx.req.args["global"] == "1"
    local count = _M.fetch_firms_data(global_sync)
    ctx:json(200, {status = "synced", records = count, global = global_sync})
end

-- ── POST /api/admin/firms/sync ───────────────────────────────────────────

function _M.admin_firms_sync(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    logger.info("Manual FIRMS sync triggered")
    local count = _M.fetch_firms_data(false)
    local last_sync = redis.get("fires:last_sync")
    ctx:json(200, {
        status = "success",
        message = "FIRMS sync completed. " .. count .. " records processed.",
        records = count, last_sync = last_sync,
    })
end

function _M.get_fires_state_sparklines(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    -- Inc 5: days era passado cru (sem validação) — clamp 1..90 + cache Redis.
    local days = tonumber(ctx.req.args.days) or 7
    if days < 1 then days = 1 end
    if days > 90 then days = 90 end

    local cache_key = "fires:sparklines:" .. days
    local cached = redis.get(cache_key)
    if cached then
        ctx:set_header("Cache-Control", "public, max-age=300")
        ctx:send(200, cached)
        return
    end

    local sparklines = db.get_fires_state_sparklines(days)
    local body = cjson.encode({ days = days, sparklines = sparklines })
    redis.set(cache_key, body, 300)
    ctx:set_header("Cache-Control", "public, max-age=300")
    ctx:send(200, body)
end

-- ── TI at-risk compute (runs off the copas loop) ─────────────────────────

-- Pure compute for /api/fires/ti-at-risk. Returns the JSON body; callers are
-- responsible for caching. Kept OFF the copas event loop (runs in a detached
-- subprocess via trigger_ti_at_risk_refresh) because it is CPU-heavy.
function _M.compute_ti_at_risk(days, limit)
    days = days or 7
    limit = limit or 10

    local ti_lookup = require("app.lookups.indigenous_lands_lookup")
    local fires_data = db.find_fires_since(days, BR_SW_LAT, BR_NE_LAT, BR_SW_LNG, BR_NE_LNG, 50000)

    local by_ti = {}
    for _, fire in ipairs(fires_data) do
        local info = ti_lookup.classify_point(fire.lon, fire.lat)
        if info then
            local name = info.name
            local rec = by_ti[name]
            if not rec then
                rec = {name = name, state_abbr = info.state_abbr or "", fire_count = 0, sum_lat = 0, sum_lon = 0}
                by_ti[name] = rec
            end
            rec.fire_count = rec.fire_count + 1
            rec.sum_lat = rec.sum_lat + (tonumber(fire.lat) or 0)
            rec.sum_lon = rec.sum_lon + (tonumber(fire.lon) or 0)
        end
    end

    local sorted = {}
    for _, rec in pairs(by_ti) do
        sorted[#sorted + 1] = rec
    end
    table.sort(sorted, function(a, b) return a.fire_count > b.fire_count end)

    local result = {}
    for i = 1, math.min(limit, #sorted) do
        local r = sorted[i]
        local n = r.fire_count > 0 and r.fire_count or 1
        result[#result + 1] = {
            name = r.name,
            state_abbr = r.state_abbr,
            fire_count = r.fire_count,
            lat = r.sum_lat / n,
            lon = r.sum_lon / n,
        }
    end

    return cjson.encode({ days = days, limit = limit, count = #result, lands = result })
end

-- Spawns a detached subprocess to recompute the ti-at-risk payload. Never
-- blocks the copas loop (os.execute returns immediately for a backgrounded
-- command). A short Redis lock (setnx) prevents duplicate refreshers.
function _M.trigger_ti_at_risk_refresh(days, limit)
    days = days or 7
    limit = limit or 10

    local lock_key = "fires:ti_at_risk:lock:" .. days .. ":" .. limit
    if not redis.setnx(lock_key, "1", 120) then
        return  -- another refresh is already in flight
    end

    local source = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    local backend_dir = source:match("^(.*[/\\])app[/\\]routes[/\\]") or ""
    local script = backend_dir .. "tools/warm_ti_at_risk.lua"

    local cmd
    if package.config:sub(1, 1) == "\\" then
        cmd = 'start /b lua5.1.exe "' .. script .. '" ' .. days .. ' ' .. limit .. ' >NUL 2>NUL'
    else
        cmd = 'nohup lua5.1 "' .. script .. '" ' .. days .. ' ' .. limit .. ' >/dev/null 2>&1 &'
    end

    local ok, err = pcall(os.execute, cmd)
    if not ok then
        logger.warn("Failed to spawn ti-at-risk warmup: " .. tostring(err))
    end
end

-- Spawns a detached subprocess to (re)classify fire nature. Never blocks the
-- copas loop. A Redis lock (setnx, TTL 1800s) prevents duplicate jobs and
-- covers the full retroactive backfill (~159k+ rows). version=0 → routine
-- (só não-classificados); version=NATURE_VERSION → reclassifica antigos.
function _M.trigger_fire_classification(version)
    version = tonumber(version) or 0

    local lock_key = "fires:classify:lock"
    if not redis.setnx(lock_key, "1", 1800) then
        return false  -- another job is already in flight
    end

    local source = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    local backend_dir = source:match("^(.*[/\\])app[/\\]routes[/\\]") or ""
    local script = backend_dir .. "tools/classify_fires.lua"

    local cmd
    if package.config:sub(1, 1) == "\\" then
        cmd = 'start /b lua5.1.exe "' .. script .. '" ' .. version .. ' >NUL 2>NUL'
    else
        cmd = 'nohup lua5.1 "' .. script .. '" ' .. version .. ' >/dev/null 2>&1 &'
    end

    local ok, err = pcall(os.execute, cmd)
    if not ok then
        logger.warn("Failed to spawn fire classification: " .. tostring(err))
    end
    return true
end

return _M


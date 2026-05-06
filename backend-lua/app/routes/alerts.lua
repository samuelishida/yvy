-- alerts.lua — Fire and environmental alert generation
-- Port of backend/alerts.py
--
-- Produces 6 alert types:
--   cluster          — 5+ high/nominal fires within 15 km (24h)
--   night_fire       — 3+ fires between 18:00–06:00 within 10 km (12h)
--   indigenous_land  — any fire inside a Terra Indígena
--   conservation_unit— any fire inside a UC ICMBio
--   prodes           — deforestation records exist in DB
--   pm25             — PM2.5 > 55 µg/m³ at any monitored station

require("app.env")
local db           = require("app.db")
local biome_lookup = require("app.lookups.biome_lookup")
local ti_lookup    = require("app.lookups.indigenous_lands_lookup")
local uc_lookup    = require("app.lookups.conservation_units_lookup")
local http_client  = require("app.http_client")
local cjson        = require("cjson")
local logger       = require("app.logger")

local _M = {}

-- ── Constants ────────────────────────────────────────────────────────────

local CLUSTER_RADIUS_KM    = 15.0
local CLUSTER_MIN_FIRES    = 5
local CLUSTER_WINDOW_HOURS = 24

local NIGHT_RADIUS_KM      = 10.0
local NIGHT_MIN_FIRES      = 3
local NIGHT_WINDOW_HOURS   = 12
local NIGHT_START_HHMM     = 1800
local NIGHT_END_HHMM       = 600

local PM25_THRESHOLD       = 55
local MAX_ALERTS           = 20

-- WAQI station IDs for major Brazilian cities
local WAQI_STATIONS = {
    {"AC", "Rio Branco",   "rio-branco"},
    {"RO", "Porto Velho",  "porto-velho"},
    {"MT", "Cuiabá",       "cuiaba"},
    {"AM", "Manaus",       "manaus"},
    {"PA", "Belém",        "belem"},
    {"MA", "São Luís",     "sao-luis"},
    {"MS", "Campo Grande", "campo-grande"},
    {"TO", "Palmas",       "palmas"},
    {"GO", "Goiânia",      "goiania"},
    {"DF", "Brasília",     "brasilia"},
}

-- ── Geometry helpers ─────────────────────────────────────────────────────

local function haversine_km(lat1, lon1, lat2, lon2)
    local R = 6371.0
    local function rad(d) return d * math.pi / 180 end
    local phi1, phi2 = rad(lat1), rad(lat2)
    local dphi = rad(lat2 - lat1)
    local dlam = rad(lon2 - lon1)
    local a = math.sin(dphi / 2) ^ 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam / 2) ^ 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
end

local function meta_for_fire(lat, lon)
    return biome_lookup.classify_point(lat, lon) or "Brasil"
end

-- ── Time utilities ───────────────────────────────────────────────────────

local function parse_fire_time(fire)
    local acq_date = fire.acq_date or ""
    local acq_time = fire.acq_time or ""
    if acq_date == "" then return nil end

    local year, month, day = acq_date:match("(%d+)-(%d+)-(%d+)")
    if not year then return nil end

    local hhmm = tonumber(acq_time) or 0
    local hh = math.floor(hhmm / 100)
    local mm = hhmm % 100

    return os.time({
        year = tonumber(year), month = tonumber(month), day = tonumber(day),
        hour = hh, min = mm, sec = 0,
    })
end

local function is_night(acq_time)
    local t = tonumber(acq_time)
    if not t then return false end
    return t >= NIGHT_START_HHMM or t < NIGHT_END_HHMM
end

local function hours_ago(ts)
    return (os.time() - ts) / 3600
end

-- ── Cluster detection ────────────────────────────────────────────────────

local function find_clusters(fires)
    local now = os.time()
    local recent = {}

    -- Filter to recent fires with high/nominal confidence
    for _, fire in ipairs(fires) do
        local ts = parse_fire_time(fire)
        if ts and hours_ago(ts) <= CLUSTER_WINDOW_HOURS then
            local conf = (fire.confidence or ""):lower()
            if conf == "high" or conf == "nominal" or conf == "n" or conf == "h" then
                recent[#recent + 1] = fire
            end
        end
    end

    -- Union-Find for clustering
    local parent = {}
    local function find(i)
        while parent[i] and parent[i] ~= i do
            parent[i] = parent[parent[i]] or parent[i]
            i = parent[i]
        end
        return i
    end
    local function union(i, j)
        local ri, rj = find(i), find(j)
        if ri ~= rj then parent[ri] = rj end
    end

    -- Connect fires within radius
    for i = 1, #recent do
        parent[i] = i
    end
    for i = 1, #recent do
        for j = i + 1, #recent do
            local d = haversine_km(
                recent[i].lat, recent[i].lon,
                recent[j].lat, recent[j].lon
            )
            if d <= CLUSTER_RADIUS_KM then
                union(i, j)
            end
        end
    end

    -- Collect clusters
    local clusters = {}
    for i = 1, #recent do
        local root = find(i)
        if not clusters[root] then
            clusters[root] = {}
        end
        clusters[root][#clusters[root] + 1] = recent[i]
    end

    -- Filter to clusters with >= MIN_FIRES
    local alerts = {}
    for _, cluster in pairs(clusters) do
        if #cluster >= CLUSTER_MIN_FIRES then
            -- Compute centroid
            local sum_lat, sum_lon = 0, 0
            for _, f in ipairs(cluster) do
                sum_lat = sum_lat + f.lat
                sum_lon = sum_lon + f.lon
            end
            local center_lat = sum_lat / #cluster
            local center_lon = sum_lon / #cluster

            local loc = meta_for_fire(center_lat, center_lon)
            alerts[#alerts + 1] = {
                type = "cluster",
                severity = "high",
                title = "Cluster de queimadas",
                title_en = "Fire cluster",
                description = #cluster .. " focos de calor em " .. loc,
                description_en = #cluster .. " fire hotspots in " .. loc,
                lat = center_lat,
                lon = center_lon,
                count = #cluster,
                meta = loc,
                state = "",
                location = loc,
            }
        end
    end

    return alerts
end

-- ── Night fire detection ─────────────────────────────────────────────────

local function find_night_fires(fires)
    local now = os.time()
    local night_fires = {}

    for _, fire in ipairs(fires) do
        local ts = parse_fire_time(fire)
        if ts and hours_ago(ts) <= NIGHT_WINDOW_HOURS and is_night(fire.acq_time or "") then
            night_fires[#night_fires + 1] = fire
        end
    end

    -- Union-Find
    local parent = {}
    local function find(i)
        while parent[i] and parent[i] ~= i do
            parent[i] = parent[parent[i]] or parent[i]
            i = parent[i]
        end
        return i
    end
    local function union(i, j)
        local ri, rj = find(i), find(j)
        if ri ~= rj then parent[ri] = rj end
    end

    for i = 1, #night_fires do parent[i] = i end
    for i = 1, #night_fires do
        for j = i + 1, #night_fires do
            local d = haversine_km(
                night_fires[i].lat, night_fires[i].lon,
                night_fires[j].lat, night_fires[j].lon
            )
            if d <= NIGHT_RADIUS_KM then
                union(i, j)
            end
        end
    end

    local clusters = {}
    for i = 1, #night_fires do
        local root = find(i)
        if not clusters[root] then clusters[root] = {} end
        clusters[root][#clusters[root] + 1] = night_fires[i]
    end

    local alerts = {}
    for _, cluster in pairs(clusters) do
        if #cluster >= NIGHT_MIN_FIRES then
            local sum_lat, sum_lon = 0, 0
            for _, f in ipairs(cluster) do
                sum_lat = sum_lat + f.lat
                sum_lon = sum_lon + f.lon
            end
            local center_lat = sum_lat / #cluster
            local center_lon = sum_lon / #cluster

            local loc = meta_for_fire(center_lat, center_lon)
            alerts[#alerts + 1] = {
                type = "night_fire",
                severity = "high",
                title = "Queimadas noturnas",
                title_en = "Night fires",
                description = #cluster .. " focos noturnos em " .. loc,
                description_en = #cluster .. " nighttime fires in " .. loc,
                lat = center_lat,
                lon = center_lon,
                count = #cluster,
                meta = loc,
                state = "",
                location = loc,
            }
        end
    end

    return alerts
end

-- ── Indigenous land / Conservation unit intersection ─────────────────────

local function find_land_alerts(fires)
    local alerts = {}
    local seen_ti = {}
    local seen_uc = {}

    for _, fire in ipairs(fires) do
        local lat = tonumber(fire.lat)
        local lon = tonumber(fire.lon)
        if lat and lon then
            local ti = ti_lookup.classify_point(lon, lat)
            if ti then
                local key = ti.name or "ti"
                if not seen_ti[key] then
                    seen_ti[key] = true
                    alerts[#alerts + 1] = {
                        type = "indigenous_land",
                        severity = "critical",
                        title = "Fogo em Terra Indígena",
                        title_en = "Fire in Indigenous Land",
                        description = "Foco detectado na " .. (ti.name or "Terra Indígena") .. " (" .. (ti.state_abbr or "") .. ")",
                        description_en = "Fire detected in " .. (ti.name or "Indigenous Land") .. " (" .. (ti.state_abbr or "") .. ")",
                        lat = lat,
                        lon = lon,
                        meta = ti.name or "Terra Indígena",
                        state = ti.state_abbr or "",
                        location = ti.name or "Terra Indígena",
                    }
                end
            end

            local uc = uc_lookup.classify_point(lon, lat)
            if uc then
                local key = uc.name or "uc"
                if not seen_uc[key] then
                    seen_uc[key] = true
                    alerts[#alerts + 1] = {
                        type = "conservation_unit",
                        severity = "high",
                        title = "Fogo em Unidade de Conservação",
                        title_en = "Fire in Conservation Unit",
                        description = "Foco detectado na " .. (uc.name or "UC") .. " (" .. (uc.category or "") .. ")",
                        description_en = "Fire detected in " .. (uc.name or "Conservation Unit") .. " (" .. (uc.category or "") .. ")",
                        lat = lat,
                        lon = lon,
                        meta = uc.name or "Unidade de Conservação",
                        state = uc.category or "",
                        location = uc.name or "Unidade de Conservação",
                    }
                end
            end
        end
    end

    return alerts
end

-- ── PRODES deforestation alerts ──────────────────────────────────────────

local function find_prodes_alerts()
    local stats = db.get_stats()
    if stats.deforestation > 0 then
        return {{
            type = "prodes",
            severity = "info",
            title = "Dados de desmatamento disponíveis",
            title_en = "Deforestation data available",
            description = stats.deforestation .. " registros de desmatamento no banco de dados",
            description_en = stats.deforestation .. " deforestation records in database",
            lat = -14.235,
            lon = -51.925,
            location = "Brasil",
        }}
    end
    return {}
end

-- ── PM2.5 alerts ─────────────────────────────────────────────────────────

local function find_pm25_alerts(waqi_token)
    local alerts = {}
    local token = waqi_token or os.getenv("WAQI_TOKEN") or "demo"

    if token == "" or token == "demo" then
        return alerts
    end

    for _, station in ipairs(WAQI_STATIONS) do
        local state, city, station_id = station[1], station[2], station[3]
        local url = "https://api.waqi.info/feed/" .. station_id .. "/?token=" .. token

        local res, err = http_client.get(url, {timeout = 10})
        if res and res.status == 200 then

            local ok, data = pcall(cjson.decode, res.body)
            if ok and data.status == "ok" then

        local pm25 = data.data and data.data.iaqi and data.data.iaqi.pm25 and data.data.iaqi.pm25.v
        if pm25 and tonumber(pm25) > PM25_THRESHOLD then
            alerts[#alerts + 1] = {
                type = "pm25",
                severity = "high",
                title = "Qualidade do ar ruim em " .. city,
                title_en = "Poor air quality in " .. city,
                description = "PM2.5: " .. pm25 .. " µg/m³ em " .. city .. ", " .. state,
                description_en = "PM2.5: " .. pm25 .. " µg/m³ in " .. city .. ", " .. state,
                lat = data.data.city and data.data.city.geo and data.data.city.geo[1] or 0,
                lon = data.data.city and data.data.city.geo and data.data.city.geo[2] or 0,
                pm25 = tonumber(pm25),
                meta = city,
                state = state,
                location = city .. ", " .. state,
            }
        end

            end
        end
    end

    return alerts
end

-- ── Generate all alerts ──────────────────────────────────────────────────

local RADIUS_BY_TYPE = {
    cluster          = CLUSTER_RADIUS_KM,
    night_fire       = NIGHT_RADIUS_KM,
    indigenous_land  = 8,
    conservation_unit= 8,
    prodes           = 50,
    pm25             = 15,
}

local TICK_BY_SEVERITY = {critical = "crit", high = "warn", info = "info"}

local TYPE_PRIORITY = {cluster=1, night_fire=2, pm25=3, indigenous_land=4, conservation_unit=5, prodes=6}

-- Cap per-type before merging to prevent one type flooding MAX_ALERTS
local TYPE_CAP = 5

local function add_common_fields(a, idx)
    a.id         = a.type .. "_" .. idx
    a.tick       = TICK_BY_SEVERITY[a.severity] or "info"
    a.ts         = os.date("!%Y-%m-%dT%H:%M:%SZ")
    a.center     = {a.lat or 0, a.lon or 0}
    a.radius_km  = RADIUS_BY_TYPE[a.type] or 10
    a.meta       = a.meta or a.location or "Brasil"
    a.state      = a.state or ""
    return a
end

function _M.generate_all_alerts(fires, deforestation_data, waqi_token)
    local buckets = {}

    local function add_bucket(type_name, list)
        buckets[#buckets + 1] = {type_name = type_name, list = list}
    end

    add_bucket("cluster",           find_clusters(fires))
    add_bucket("night_fire",        find_night_fires(fires))
    add_bucket("pm25",              find_pm25_alerts(waqi_token))
    add_bucket("indigenous_land",   find_land_alerts(fires))  -- already deduped
    add_bucket("prodes",            find_prodes_alerts())

    -- Sort buckets by type priority, then fill up to MAX_ALERTS respecting per-type cap
    local severity_rank = {critical = 1, high = 2, info = 3}
    local all_alerts = {}

    for _, bucket in ipairs(buckets) do
        local list = bucket.list
        -- Sort within bucket by severity
        table.sort(list, function(a, b)
            return (severity_rank[a.severity] or 99) < (severity_rank[b.severity] or 99)
        end)
        local added = 0
        for _, a in ipairs(list) do
            if #all_alerts >= MAX_ALERTS then break end
            if added < TYPE_CAP then
                all_alerts[#all_alerts + 1] = a
                added = added + 1
            end
        end
        if #all_alerts >= MAX_ALERTS then break end
    end

    -- Add required frontend fields
    for i, a in ipairs(all_alerts) do
        add_common_fields(a, i)
    end

    return {alerts = all_alerts, count = #all_alerts}
end

return _M

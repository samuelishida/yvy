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

local db          = require("app.db")
local biome_lookup = require("app.biome_lookup")
local ti_lookup   = require("app.indigenous_lands_lookup")
local uc_lookup   = require("app.conservation_units_lookup")
local http        = require("resty.http")
local cjson       = require("cjson")

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
    """Parse acq_date + acq_time into a Unix timestamp, or nil."""
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
    """Return true if acquisition time is between 18:00 and 06:00 UTC."""
    local t = tonumber(acq_time)
    if not t then return false end
    return t >= NIGHT_START_HHMM or t < NIGHT_END_HHMM
end

local function hours_ago(ts)
    """Return hours elapsed since timestamp."""
    return (os.time() - ts) / 3600
end

-- ── Cluster detection ────────────────────────────────────────────────────

local function find_clusters(fires)
    """Find clusters of 5+ high/nominal fires within 15 km in 24h."""
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

            alerts[#alerts + 1] = {
                type = "cluster",
                severity = "high",
                title = "Cluster de queimadas",
                title_en = "Fire cluster",
                description = #cluster .. " focos de calor em " .. meta_for_fire(center_lat, center_lon),
                description_en = #cluster .. " fire hotspots in " .. meta_for_fire(center_lat, center_lon),
                lat = center_lat,
                lon = center_lon,
                count = #cluster,
                location = meta_for_fire(center_lat, center_lon),
            }
        end
    end

    return alerts
end

-- ── Night fire detection ─────────────────────────────────────────────────

local function find_night_fires(fires)
    """Find 3+ night fires within 10 km in 12h."""
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

            alerts[#alerts + 1] = {
                type = "night_fire",
                severity = "high",
                title = "Queimadas noturnas",
                title_en = "Night fires",
                description = #cluster .. " focos noturnos em " .. meta_for_fire(center_lat, center_lon),
                description_en = #cluster .. " nighttime fires in " .. meta_for_fire(center_lat, center_lon),
                lat = center_lat,
                lon = center_lon,
                count = #cluster,
                location = meta_for_fire(center_lat, center_lon),
            }
        end
    end

    return alerts
end

-- ── Indigenous land / Conservation unit intersection ─────────────────────

local function find_land_alerts(fires)
    """Find fires inside indigenous lands or conservation units."""
    local alerts = {}

    for _, fire in ipairs(fires) do
        local lat = tonumber(fire.lat)
        local lon = tonumber(fire.lon)
        if lat and lon then
            local ti = ti_lookup.classify_point(lon, lat)
            if ti then
                alerts[#alerts + 1] = {
                    type = "indigenous_land",
                    severity = "critical",
                    title = "Fogo em Terra Indígena",
                    title_en = "Fire in Indigenous Land",
                    description = "Foco detectado na " .. (ti.name or "Terra Indígena") .. " (" .. (ti.state_abbr or "") .. ")",
                    description_en = "Fire detected in " .. (ti.name or "Indigenous Land") .. " (" .. (ti.state_abbr or "") .. ")",
                    lat = lat,
                    lon = lon,
                    location = ti.name or "Terra Indígena",
                }
            end

            local uc = uc_lookup.classify_point(lon, lat)
            if uc then
                alerts[#alerts + 1] = {
                    type = "conservation_unit",
                    severity = "high",
                    title = "Fogo em Unidade de Conservação",
                    title_en = "Fire in Conservation Unit",
                    description = "Foco detectado na " .. (uc.name or "UC") .. " (" .. (uc.category or "") .. ")",
                    description_en = "Fire detected in " .. (uc.name or "Conservation Unit") .. " (" .. (uc.category or "") .. ")",
                    lat = lat,
                    lon = lon,
                    location = uc.name or "Unidade de Conservação",
                }
            end
        end
    end

    return alerts
end

-- ── PRODES deforestation alerts ──────────────────────────────────────────

local function find_prodes_alerts()
    """Check if there are any deforestation records in DB."""
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

local function find_pm25_alerts(http_client, waqi_token)
    """Check PM2.5 levels at monitored stations."""
    local alerts = {}
    local token = waqi_token or os.getenv("WAQI_TOKEN") or "demo"

    for _, station in ipairs(WAQI_STATIONS) do
        local state, city, station_id = station[1], station[2], station[3]
        local url = "https://api.waqi.info/feed/" .. station_id .. "/?token=" .. token

        local res, err = http_client:request_uri(url, {method = "GET"})
        if not res or res.status ~= 200 then
            goto continue
        end

        local ok, data = pcall(cjson.decode, res.body)
        if not ok or data.status ~= "ok" then
            goto continue
        end

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
                location = city .. ", " .. state,
            }
        end

        ::continue::
    end

    return alerts
end

-- ── Generate all alerts ──────────────────────────────────────────────────

function _M.generate_all_alerts(fires, http_client, waqi_token)
    """Generate all alert types from fire data. Returns {alerts, count}."""
    local all_alerts = {}

    -- Cluster alerts
    local clusters = find_clusters(fires)
    for _, a in ipairs(clusters) do all_alerts[#all_alerts + 1] = a end

    -- Night fire alerts
    local night = find_night_fires(fires)
    for _, a in ipairs(night) do all_alerts[#all_alerts + 1] = a end

    -- Indigenous land / Conservation unit alerts
    local land = find_land_alerts(fires)
    for _, a in ipairs(land) do all_alerts[#all_alerts + 1] = a end

    -- PRODES alerts
    local prodes = find_prodes_alerts()
    for _, a in ipairs(prodes) do all_alerts[#all_alerts + 1] = a end

    -- PM2.5 alerts
    local pm25 = find_pm25_alerts(http_client, waqi_token)
    for _, a in ipairs(pm25) do all_alerts[#all_alerts + 1] = a end

    -- Cap at MAX_ALERTS
    if #all_alerts > MAX_ALERTS then
        -- Sort by severity: critical > high > info
        local severity_rank = {critical = 1, high = 2, info = 3}
        table.sort(all_alerts, function(a, b)
            return (severity_rank[a.severity] or 99) < (severity_rank[b.severity] or 99)
        end)
        -- Truncate
        for i = MAX_ALERTS + 1, #all_alerts do
            all_alerts[i] = nil
        end
    end

    return {alerts = all_alerts, count = #all_alerts}
end

return _M

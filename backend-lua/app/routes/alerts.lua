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
local MAX_ALERTS           = 50

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

local function is_in_brazil_bbox(lat, lon)
    return lat >= -34 and lat <= 5.5 and lon >= -74 and lon <= -28
end

-- Country/region lookup based on coordinates
local function get_region_for_coords(lat, lon)
    -- Brazil check first
    if is_in_brazil_bbox(lat, lon) then
        return "Brasil"
    end

    -- South American countries with approximate bounding boxes
    local countries = {
        { name = "Argentina",   lat_min = -55, lat_max = -21, lon_min = -74, lon_max = -53 },
        { name = "Colombia",    lat_min = -4,  lat_max = 13,  lon_min = -79, lon_max = -67 },
        { name = "Peru",        lat_min = -18, lat_max = 0,   lon_min = -81, lon_max = -68 },
        { name = "Bolivia",     lat_min = -23, lat_max = -9,  lon_min = -70, lon_max = -57 },
        { name = "Paraguay",    lat_min = -28, lat_max = -19, lon_min = -63, lon_max = -54 },
        { name = "Uruguay",     lat_min = -35, lat_max = -30, lon_min = -58, lon_max = -53 },
        { name = "Chile",       lat_min = -56, lat_max = -17, lon_min = -81, lon_max = -66 },
        { name = "Venezuela",   lat_min = 1,   lat_max = 12,  lon_min = -73, lon_max = -59 },
        { name = "Guyana",      lat_min = 1,   lat_max = 9,   lon_min = -61, lon_max = -56 },
        { name = "Suriname",    lat_min = 2,   lat_max = 6,   lon_min = -58, lon_max = -54 },
        { name = "Ecuador",     lat_min = -5,  lat_max = 2,   lon_min = -81, lon_max = -75 },
        { name = "Guiana Francesa", lat_min = 2, lat_max = 6, lon_min = -54, lon_max = -51 },
    }

    for _, country in ipairs(countries) do
        if lat >= country.lat_min and lat <= country.lat_max and
           lon >= country.lon_min and lon <= country.lon_max then
            return country.name
        end
    end

    return "América do Sul"
end

local function meta_for_fire(lat, lon)
    local biome = biome_lookup.classify_point(lat, lon)
    if biome then
        return biome
    end
    return get_region_for_coords(lat, lon)
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

local function ts_label(generated_at)
    local total_s = os.time() - generated_at
    if total_s < 3600 then
        return math.max(1, math.floor(total_s / 60)) .. "m"
    elseif total_s < 86400 then
        return math.floor(total_s / 3600) .. "h"
    else
        return math.floor(total_s / 86400) .. "d"
    end
end

-- ── Clustering (greedy O(n²), same as Python) ───────────────────────────

local function cluster_fires(candidates, radius_km, min_count, window_hours)
    local now = os.time()
    local cutoff = now - window_hours * 3600

    local recent = {}
    for _, f in ipairs(candidates) do
        local t = parse_fire_time(f)
        if t and t >= cutoff then
            recent[#recent + 1] = f
        end
    end

    local assigned = {}
    for i = 1, #recent do assigned[i] = false end
    local clusters = {}

    for i, seed in ipairs(recent) do
        if not assigned[i] then
            local cluster = {seed}
            assigned[i] = true
            for j, other in ipairs(recent) do
                if not assigned[j] then
                    if haversine_km(seed.lat, seed.lon, other.lat, other.lon) <= radius_km then
                        cluster[#cluster + 1] = other
                        assigned[j] = true
                    end
                end
            end
            if #cluster >= min_count then
                clusters[#clusters + 1] = cluster
            end
        end
    end

    -- Sort by size descending
    table.sort(clusters, function(a, b) return #a > #b end)
    return clusters
end

-- ── Alert generators ─────────────────────────────────────────────────────

local function cluster_alerts(fires)
    local candidates = {}
    for _, f in ipairs(fires) do
        local conf = (f.confidence or ""):lower()
        if conf == "high" or conf == "nominal" or conf == "h" or conf == "n" then
            candidates[#candidates + 1] = f
        end
    end

    local clusters = cluster_fires(candidates, CLUSTER_RADIUS_KM, CLUSTER_MIN_FIRES, CLUSTER_WINDOW_HOURS)
    local now = os.time()
    local alerts = {}

    for idx = 1, math.min(15, #clusters) do
        local cluster = clusters[idx]
        local sum_lat, sum_lon = 0, 0
        for _, f in ipairs(cluster) do
            sum_lat = sum_lat + f.lat
            sum_lon = sum_lon + f.lon
        end
        local clat = sum_lat / #cluster
        local clon = sum_lon / #cluster

        local max_d = 5.0
        for _, f in ipairs(cluster) do
            local d = haversine_km(clat, clon, f.lat, f.lon)
            if d > max_d then max_d = d end
        end
        local radius_km = math.max(5.0, max_d)

        local meta = meta_for_fire(clat, clon)
        alerts[#alerts + 1] = {
            id = string.format("cluster_%.2f_%.2f", clat, clon),
            type = "cluster",
            tick = "crit",
            meta = meta,
            state = #cluster .. " focos",
            center = {clat, clon},
            radius_km = radius_km,
            generated_at = now,
            ts = ts_label(now),
        }
    end
    return alerts
end

local function night_fire_alerts(fires)
    local candidates = {}
    for _, f in ipairs(fires) do
        if is_night(f.acq_time or "") then
            candidates[#candidates + 1] = f
        end
    end

    local clusters = cluster_fires(candidates, NIGHT_RADIUS_KM, NIGHT_MIN_FIRES, NIGHT_WINDOW_HOURS)
    local now = os.time()
    local alerts = {}

    for idx = 1, math.min(15, #clusters) do
        local cluster = clusters[idx]
        local sum_lat, sum_lon = 0, 0
        for _, f in ipairs(cluster) do
            sum_lat = sum_lat + f.lat
            sum_lon = sum_lon + f.lon
        end
        local clat = sum_lat / #cluster
        local clon = sum_lon / #cluster

        local max_d = 5.0
        for _, f in ipairs(cluster) do
            local d = haversine_km(clat, clon, f.lat, f.lon)
            if d > max_d then max_d = d end
        end
        local radius_km = math.max(5.0, max_d)

        local meta = meta_for_fire(clat, clon)
        alerts[#alerts + 1] = {
            id = string.format("night_%.2f_%.2f", clat, clon),
            type = "night_fire",
            tick = "warn",
            meta = meta,
            state = #cluster .. " focos",
            center = {clat, clon},
            radius_km = radius_km,
            generated_at = now,
            ts = ts_label(now),
        }
    end
    return alerts
end

local function indigenous_land_alerts(fires)
    if not ti_lookup._lands or #ti_lookup._lands == 0 then
        return {}
    end

    local by_ti = {}
    for _, fire in ipairs(fires) do
        local info = ti_lookup.classify_point(fire.lon, fire.lat)
        if info then
            local name = info.name
            if not by_ti[name] then
                by_ti[name] = {info = info, lats = {}, lons = {}}
            end
            local t = by_ti[name]
            t.lats[#t.lats + 1] = fire.lat
            t.lons[#t.lons + 1] = fire.lon
        end
    end

    -- Sort by fire count descending
    local sorted = {}
    for name, data in pairs(by_ti) do
        sorted[#sorted + 1] = {name = name, data = data}
    end
    table.sort(sorted, function(a, b) return #a.data.lats > #b.data.lats end)

    local now = os.time()
    local alerts = {}
    for idx = 1, math.min(15, #sorted) do
        local item = sorted[idx]
        local info = item.data.info
        local state_abbr = info.state_abbr or ""
        local lats, lons = item.data.lats, item.data.lons
        local clat = 0; for _, v in ipairs(lats) do clat = clat + v end; clat = clat / #lats
        local clon = 0; for _, v in ipairs(lons) do clon = clon + v end; clon = clon / #lons

        local max_d = 5.0
        for i = 1, #lats do
            local d = haversine_km(clat, clon, lats[i], lons[i])
            if d > max_d then max_d = d end
        end
        local radius_km = math.max(5.0, max_d)

        local region = meta_for_fire(clat, clon)
        local meta = region .. " · " .. item.name
        local safe_id = item.name:sub(1, 20):gsub(" ", "_")
        alerts[#alerts + 1] = {
            id = "ti_" .. safe_id,
            type = "indigenous_land",
            tick = "crit",
            meta = meta,
            state = (state_abbr ~= "" and state_abbr or region) .. " · " .. #lats .. " focos",
            center = {clat, clon},
            radius_km = radius_km,
            generated_at = now,
            ts = ts_label(now),
        }
    end
    return alerts
end

local function conservation_unit_alerts(fires)
    if not uc_lookup._units or #uc_lookup._units == 0 then
        return {}
    end

    local by_uc = {}
    for _, fire in ipairs(fires) do
        local info = uc_lookup.classify_point(fire.lon, fire.lat)
        if info then
            local name = info.name
            if not by_uc[name] then
                by_uc[name] = {info = info, lats = {}, lons = {}}
            end
            local t = by_uc[name]
            t.lats[#t.lats + 1] = fire.lat
            t.lons[#t.lons + 1] = fire.lon
        end
    end

    local sorted = {}
    for name, data in pairs(by_uc) do
        sorted[#sorted + 1] = {name = name, data = data}
    end
    table.sort(sorted, function(a, b) return #a.data.lats > #b.data.lats end)

    local now = os.time()
    local alerts = {}
    for idx = 1, math.min(15, #sorted) do
        local item = sorted[idx]
        local info = item.data.info
        local state_abbr = info.state_abbr or ""
        local category = info.category or "UC"
        local lats, lons = item.data.lats, item.data.lons
        local clat = 0; for _, v in ipairs(lats) do clat = clat + v end; clat = clat / #lats
        local clon = 0; for _, v in ipairs(lons) do clon = clon + v end; clon = clon / #lons

        local max_d = 5.0
        for i = 1, #lats do
            local d = haversine_km(clat, clon, lats[i], lons[i])
            if d > max_d then max_d = d end
        end
        local radius_km = math.max(5.0, max_d)

        local region = meta_for_fire(clat, clon)
        local meta = category .. " · " .. item.name:sub(1, 30)
        local safe_id = item.name:sub(1, 20):gsub(" ", "_")
        alerts[#alerts + 1] = {
            id = "uc_" .. safe_id,
            type = "conservation_unit",
            tick = "crit",
            meta = meta,
            state = (state_abbr ~= "" and state_abbr or region) .. " · " .. #lats .. " focos",
            center = {clat, clon},
            radius_km = radius_km,
            generated_at = now,
            ts = ts_label(now),
        }
    end
    return alerts
end

local function prodes_alerts()
    local ok, records = pcall(db.find_deforestation, -34.0, 5.5, -74.0, -34.0, 10)
    if not ok or not records or #records == 0 then
        return {}
    end

    local now = os.time()
    local first = records[1]
    local meta = meta_for_fire(first.lat or -14.235, first.lon or -51.925)
    local area_km2 = #records * 2

    return {{
        id = "prodes_latest",
        type = "prodes",
        tick = "info",
        meta = meta,
        state = area_km2 .. " km²",
        center = {first.lat or -14.235, first.lon or -51.925},
        radius_km = 50,
        generated_at = now,
        ts = ts_label(now),
    }}
end

local function pm25_alerts(waqi_token)
    local token = waqi_token or os.getenv("WAQI_TOKEN") or "demo"
    if token == "" or token == "demo" then
        return {}
    end

    local now = os.time()
    local alerts = {}

    for _, station in ipairs(WAQI_STATIONS) do
        local state, city, station_id = station[1], station[2], station[3]
        local url = "https://api.waqi.info/feed/" .. station_id .. "/?token=" .. token

        local res, err = http_client.get(url, {timeout = 8})
        if res and res.status == 200 then
            local ok, data = pcall(cjson.decode, res.body)
            if ok and data.status == "ok" then
                local pm25 = data.data and data.data.iaqi and data.data.iaqi.pm25 and data.data.iaqi.pm25.v
                if pm25 and tonumber(pm25) >= PM25_THRESHOLD then
                    alerts[#alerts + 1] = {
                        id = "pm25_" .. station_id,
                        type = "pm25",
                        tick = "warn",
                        meta = state .. " · " .. city,
                        state = state .. " · " .. pm25 .. " µg/m³",
                        center = {data.data.city and data.data.city.geo and data.data.city.geo[1] or 0,
                                  data.data.city and data.data.city.geo and data.data.city.geo[2] or 0},
                        radius_km = 15,
                        generated_at = now,
                        ts = ts_label(now),
                    }
                end
            end
        end
    end

    return alerts
end

-- ── Public API ───────────────────────────────────────────────────────────

function _M.generate_all_alerts(fires, deforestation_data, waqi_token)
    local all_alerts = {}

    -- Fire-based alerts (CPU-bound, no I/O)
    local function extend(list)
        for _, a in ipairs(list) do
            all_alerts[#all_alerts + 1] = a
        end
    end

    extend(cluster_alerts(fires))
    extend(night_fire_alerts(fires))
    extend(indigenous_land_alerts(fires))
    extend(conservation_unit_alerts(fires))

    -- Async I/O alerts
    extend(prodes_alerts())
    extend(pm25_alerts(waqi_token))

    -- Sort: crit first, then warn, then info; within each tier by id for stability
    local tier = {crit = 0, warn = 1, info = 2}
    table.sort(all_alerts, function(a, b)
        local ta = tier[a.tick] or 9
        local tb = tier[b.tick] or 9
        if ta ~= tb then return ta < tb end
        return (a.id or "") < (b.id or "")
    end)

    -- Cap
    if #all_alerts > MAX_ALERTS then
        local capped = {}
        for i = 1, MAX_ALERTS do capped[i] = all_alerts[i] end
        all_alerts = capped
    end

    local now = os.time()
    return {
        alerts = all_alerts,
        count = #all_alerts,
        generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ", now),
    }
end

return _M

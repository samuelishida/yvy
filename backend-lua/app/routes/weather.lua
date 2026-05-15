-- weather.lua — /api/weather/air-quality, /api/weather/temperature
-- Baremetal Lua version

require("app.env")
local rl          = require("app.middleware.rate_limit")
local redis       = require("app.redis")
local http_client = require("app.http_client")
local cjson       = require("cjson")

local _M = {}

local WAQI_TOKEN = os.getenv("WAQI_TOKEN") or "demo"

-- Reverse geocoding cache
local reverse_geo_cache = {}
local REVERSE_GEO_TTL = 3600

local function reverse_geocode(lat, lon)
    local key = string.format("%.4f,%.4f", lat, lon)
    local entry = reverse_geo_cache[key]
    if entry and entry.expires > os.time() then return entry.city end

    local res, err = http_client.get("https://nominatim.openstreetmap.org/reverse", {
        query = {lat = lat, lon = lon, format = "json", zoom = 10, ["accept-language"] = "pt"},
        headers = {["User-Agent"] = "YvyApp/1.0 (environmental-monitoring)"},
        timeout = 5,
    })

    if not res or res.status ~= 200 then return "Brasil" end
    local ok, data = pcall(cjson.decode, res.body)
    if not ok then return "Brasil" end

    local address = data.address or {}
    local city = address.city or address.town or address.village
        or address.municipality or address.state or "Brasil"

    reverse_geo_cache[key] = {city = city, expires = os.time() + REVERSE_GEO_TTL}
    return city
end

-- ── GET /api/weather/air-quality ─────────────────────────────────────────

function _M.get_air_quality(ctx)
    if not rl.enforce(ctx) then return end

    local args = ctx.req.args
    local lat = args.lat; local lon = args.lon
    local station = args.station or ""

    local cache_key
    if lat and lon then
        cache_key = "weather:aqi:" .. string.format("%.1f:%.1f", tonumber(lat), tonumber(lon))
    else
        cache_key = "weather:aqi:brasil"
    end

    local cached = redis.get(cache_key)
    if cached then
        ctx:set_header("Cache-Control", "public, max-age=600")
        ctx:send(200, cached)
        return
    end

    if station == "" and lat and lon then station = "@" .. lat .. "," .. lon
    elseif station == "" then station = "brasilia" end

    local fallback = "brasilia"
    local result = nil

    local url = "https://api.waqi.info/feed/" .. station .. "/?token=" .. WAQI_TOKEN
    local res, err = http_client.get(url, {timeout = 10})

    if res and res.status == 200 then
        local ok, data = pcall(cjson.decode, res.body)
        if ok and data.status == "ok" then
            local d = data.data
            local city = (lat and lon) and reverse_geocode(tonumber(lat), tonumber(lon)) or "Brasil"
            result = {aqi = d.aqi, pm25 = d.iaqi and d.iaqi.pm25 and d.iaqi.pm25.v,
                      humidity = d.iaqi and d.iaqi.h and d.iaqi.h.v, city = city}
        elseif station ~= fallback then
            local url2 = "https://api.waqi.info/feed/" .. fallback .. "/?token=" .. WAQI_TOKEN
            local res2, err2 = http_client.get(url2, {timeout = 10})
            if res2 and res2.status == 200 then
                local ok2, data2 = pcall(cjson.decode, res2.body)
                if ok2 and data2.status == "ok" then
                    local d = data2.data
                    local city = (lat and lon) and reverse_geocode(tonumber(lat), tonumber(lon)) or "Brasil"
                    result = {aqi = d.aqi, pm25 = d.iaqi and d.iaqi.pm25 and d.iaqi.pm25.v,
                              humidity = d.iaqi and d.iaqi.h and d.iaqi.h.v, city = city}
                end
            end
        end
    end

    if result then
        local body = cjson.encode(result)
        redis.set(cache_key, body, 900)
        ctx:set_header("Cache-Control", "public, max-age=600")
        ctx:send(200, body)
    else
        ctx:json(200, {aqi = cjson.null})
    end
end

-- ── GET /api/weather/temperature ─────────────────────────────────────────

function _M.get_temperature(ctx)
    if not rl.enforce(ctx) then return end

    local args = ctx.req.args
    local lat = args.lat or "-14.235"
    local lon = args.lon or "-51.925"

    local cache_key = "weather:temp:" .. string.format("%.1f:%.1f", tonumber(lat), tonumber(lon))
    local cached = redis.get(cache_key)
    if cached then
        ctx:set_header("Cache-Control", "public, max-age=600")
        ctx:send(200, cached)
        return
    end

    local url = "https://api.open-meteo.com/v1/forecast"
        .. "?latitude=" .. lat .. "&longitude=" .. lon
        .. "&current=temperature_2m,relative_humidity_2m,apparent_temperature,wind_speed_10m,wind_direction_10m"
        .. "&wind_speed_unit=kmh&timezone=America/Sao_Paulo"

    local res, err = http_client.get(url, {timeout = 10})
    if not res or res.status ~= 200 then ctx:json(200, {temp = cjson.null}); return end

    local ok, data = pcall(cjson.decode, res.body)
    if not ok or not data.current then ctx:json(200, {temp = cjson.null}); return end

    local current = data.current
    local city = reverse_geocode(tonumber(lat), tonumber(lon))
    local result = {
        temp = current.temperature_2m, feels_like = current.apparent_temperature,
        humidity = current.relative_humidity_2m, wind_speed = current.wind_speed_10m,
        wind_direction = current.wind_direction_10m, city = city,
    }

    local body = cjson.encode(result)
    redis.set(cache_key, body, 900)
    ctx:set_header("Cache-Control", "public, max-age=600")
    ctx:send(200, body)
end

-- ── GET /api/weather (combined) ──────────────────────────────────────────
-- Single request that returns both AQI and temperature. Backend fans out
-- the two upstream calls as concurrent curl subprocesses via
-- http_client.parallel_get, so wall time ≈ max(t_aqi, t_temp) rather than
-- the sum. Saves one client→backend round trip vs two separate fetches.

function _M.get_weather(ctx)
    if not rl.enforce(ctx) then return end

    local args = ctx.req.args
    local lat = args.lat or "-14.235"
    local lon = args.lon or "-51.925"
    local station = args.station or ""

    local combined_key = "weather:all:" .. string.format("%.1f:%.1f", tonumber(lat), tonumber(lon))
    local cached = redis.get(combined_key)
    if cached then
        ctx:set_header("Cache-Control", "public, max-age=600")
        ctx:send(200, cached)
        return
    end

    local aqi_key = "weather:aqi:" .. string.format("%.1f:%.1f", tonumber(lat), tonumber(lon))
    local temp_key = "weather:temp:" .. string.format("%.1f:%.1f", tonumber(lat), tonumber(lon))

    local aqi_data, temp_data

    local cached_aqi = redis.get(aqi_key)
    if cached_aqi then
        local ok, dec = pcall(cjson.decode, cached_aqi)
        if ok then aqi_data = dec end
    end

    local cached_temp = redis.get(temp_key)
    if cached_temp then
        local ok, dec = pcall(cjson.decode, cached_temp)
        if ok then temp_data = dec end
    end

    -- Build URL list for whatever is missing from cache. AQI gets a geo + fallback
    -- "brasilia" pair so the demo WAQI token still resolves to something usable.
    local urls, slots = {}, {}
    if not aqi_data then
        local geo_station = (station ~= "" and station) or ("@" .. lat .. "," .. lon)
        urls[#urls + 1] = "https://api.waqi.info/feed/" .. geo_station .. "/?token=" .. WAQI_TOKEN
        slots[#slots + 1] = "aqi"
        urls[#urls + 1] = "https://api.waqi.info/feed/brasilia/?token=" .. WAQI_TOKEN
        slots[#slots + 1] = "aqi_fallback"
    end
    if not temp_data then
        urls[#urls + 1] = "https://api.open-meteo.com/v1/forecast"
            .. "?latitude=" .. lat .. "&longitude=" .. lon
            .. "&current=temperature_2m,relative_humidity_2m,apparent_temperature,wind_speed_10m,wind_direction_10m"
            .. "&wind_speed_unit=kmh&timezone=America/Sao_Paulo"
        slots[#slots + 1] = "temp"
    end

    if #urls > 0 then
        local responses = http_client.parallel_get(urls, {timeout = 10})
        local aqi_fallback_res = nil
        for i, slot in ipairs(slots) do
            local r = responses[i]
            local res = r and r.res
            if (slot == "aqi" or slot == "aqi_fallback") and res and res.status == 200 then
                local ok, data = pcall(cjson.decode, res.body)
                if ok and data.status == "ok" then
                    if slot == "aqi" and not aqi_data then
                        local d = data.data
                        local city = (lat and lon) and reverse_geocode(tonumber(lat), tonumber(lon)) or "Brasil"
                        aqi_data = {aqi = d.aqi,
                                    pm25 = d.iaqi and d.iaqi.pm25 and d.iaqi.pm25.v,
                                    humidity = d.iaqi and d.iaqi.h and d.iaqi.h.v,
                                    city = city}
                    elseif slot == "aqi_fallback" then
                        aqi_fallback_res = data.data
                    end
                end
            elseif slot == "temp" and res and res.status == 200 then
                local ok, data = pcall(cjson.decode, res.body)
                if ok and data.current then
                    local current = data.current
                    local city = reverse_geocode(tonumber(lat), tonumber(lon))
                    temp_data = {
                        temp = current.temperature_2m,
                        feels_like = current.apparent_temperature,
                        humidity = current.relative_humidity_2m,
                        wind_speed = current.wind_speed_10m,
                        wind_direction = current.wind_direction_10m,
                        city = city,
                    }
                    redis.set(temp_key, cjson.encode(temp_data), 900)
                end
            end
        end

        -- Use fallback AQI if the geo-station call returned no data.
        if not aqi_data and aqi_fallback_res then
            local d = aqi_fallback_res
            local city = (lat and lon) and reverse_geocode(tonumber(lat), tonumber(lon)) or "Brasil"
            aqi_data = {aqi = d.aqi,
                        pm25 = d.iaqi and d.iaqi.pm25 and d.iaqi.pm25.v,
                        humidity = d.iaqi and d.iaqi.h and d.iaqi.h.v,
                        city = city}
        end
        if aqi_data then
            redis.set(aqi_key, cjson.encode(aqi_data), 900)
        end
    end

    local response = {
        aqi            = aqi_data and aqi_data.aqi or cjson.null,
        pm25           = aqi_data and aqi_data.pm25 or cjson.null,
        aqi_humidity   = aqi_data and aqi_data.humidity or cjson.null,
        aqi_city       = aqi_data and aqi_data.city or cjson.null,
        temp           = temp_data and temp_data.temp or cjson.null,
        feels_like     = temp_data and temp_data.feels_like or cjson.null,
        humidity       = temp_data and temp_data.humidity or cjson.null,
        wind_speed     = temp_data and temp_data.wind_speed or cjson.null,
        wind_direction = temp_data and temp_data.wind_direction or cjson.null,
        city           = (temp_data and temp_data.city) or (aqi_data and aqi_data.city) or cjson.null,
    }

    local body = cjson.encode(response)
    redis.set(combined_key, body, 600)
    ctx:set_header("Cache-Control", "public, max-age=600")
    ctx:send(200, body)
end

return _M


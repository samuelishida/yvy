-- weather.lua — /api/weather/air-quality, /api/weather/temperature
-- Port of backend/backend.py weather routes

local rl    = require("app.rate_limit")
local redis = require("app.redis")
local cjson = require("cjson")
local http  = require("resty.http")

local _M = {}

local WAQI_TOKEN = os.getenv("WAQI_TOKEN") or "demo"

-- Reverse geocoding cache (simple in-memory, per-worker)
local reverse_geo_cache = {}
local REVERSE_GEO_TTL = 3600

local function reverse_geocode(lat, lon)
    local key = string.format("%.4f,%.4f", lat, lon)
    local entry = reverse_geo_cache[key]
    if entry and entry.expires > ngx.time() then
        return entry.city
    end

    local httpc = http.new()
    httpc:set_timeout(5000)

    local res, err = httpc:request_uri("https://nominatim.openstreetmap.org/reverse", {
        method = "GET",
        query = {
            lat = lat, lon = lon, format = "json", zoom = 10,
            ["accept-language"] = "pt",
        },
        headers = {
            ["User-Agent"] = "YvyApp/1.0 (environmental-monitoring)",
        },
    })

    httpc:close()

    if not res or res.status ~= 200 then
        return "Brasil"
    end

    local ok, data = pcall(cjson.decode, res.body)
    if not ok then return "Brasil" end

    local address = data.address or {}
    local city = address.city or address.town or address.village
        or address.municipality or address.state or "Brasil"

    reverse_geo_cache[key] = {city = city, expires = ngx.time() + REVERSE_GEO_TTL}
    return city
end

-- ── GET /api/weather/air-quality ─────────────────────────────────────────

function _M.get_air_quality()
    rl.enforce()

    local args = ngx.req.get_uri_args()
    local lat = args.lat
    local lon = args.lon
    local station = args.station or ""

    local cache_key
    if lat and lon then
        cache_key = "weather:aqi:" .. string.format("%.1f:%.1f", tonumber(lat), tonumber(lon))
    else
        cache_key = "weather:aqi:brasil"
    end

    local cached = redis.get(cache_key)
    if cached then
        ngx.header["Content-Type"] = "application/json"
        ngx.say(cached)
        return
    end

    if station == "" and lat and lon then
        station = "@" .. lat .. "," .. lon
    elseif station == "" then
        station = "brasilia"
    end

    local fallback = "brasilia"
    local httpc = http.new()
    httpc:set_timeout(10000)

    local result = nil
    local url = "https://api.waqi.info/feed/" .. station .. "/?token=" .. WAQI_TOKEN
    local res, err = httpc:request_uri(url, {method = "GET"})

    if res and res.status == 200 then
        local ok, data = pcall(cjson.decode, res.body)
        if ok and data.status == "ok" then
            local d = data.data
            local city = "Brasil"
            if lat and lon then
                city = reverse_geocode(tonumber(lat), tonumber(lon))
            end
            result = {
                aqi = d.aqi,
                pm25 = d.iaqi and d.iaqi.pm25 and d.iaqi.pm25.v,
                humidity = d.iaqi and d.iaqi.h and d.iaqi.h.v,
                city = city,
            }
        elseif station ~= fallback then
            -- Try fallback
            local url2 = "https://api.waqi.info/feed/" .. fallback .. "/?token=" .. WAQI_TOKEN
            local res2, _ = httpc:request_uri(url2, {method = "GET"})
            if res2 and res2.status == 200 then
                local ok2, data2 = pcall(cjson.decode, res2.body)
                if ok2 and data2.status == "ok" then
                    local d = data2.data
                    local city = "Brasil"
                    if lat and lon then
                        city = reverse_geocode(tonumber(lat), tonumber(lon))
                    end
                    result = {
                        aqi = d.aqi,
                        pm25 = d.iaqi and d.iaqi.pm25 and d.iaqi.pm25.v,
                        humidity = d.iaqi and d.iaqi.h and d.iaqi.h.v,
                        city = city,
                    }
                end
            end
        end
    end

    httpc:close()

    if result then
        local body = cjson.encode(result)
        redis.set(cache_key, body, 900)  -- 15 min
        ngx.header["Content-Type"] = "application/json"
        ngx.say(body)
    else
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"aqi":null}')
    end
end

-- ── GET /api/weather/temperature ─────────────────────────────────────────

function _M.get_temperature()
    rl.enforce()

    local args = ngx.req.get_uri_args()
    local lat = args.lat or "-14.235"
    local lon = args.lon or "-51.925"

    local cache_key = "weather:temp:" .. string.format("%.1f:%.1f", tonumber(lat), tonumber(lon))
    local cached = redis.get(cache_key)
    if cached then
        ngx.header["Content-Type"] = "application/json"
        ngx.say(cached)
        return
    end

    local url = "https://api.open-meteo.com/v1/forecast"
        .. "?latitude=" .. lat .. "&longitude=" .. lon
        .. "&current=temperature_2m,relative_humidity_2m,apparent_temperature,wind_speed_10m,wind_direction_10m"
        .. "&wind_speed_unit=kmh&timezone=America/Sao_Paulo"

    local httpc = http.new()
    httpc:set_timeout(10000)

    local res, err = httpc:request_uri(url, {method = "GET"})
    httpc:close()

    if not res or res.status ~= 200 then
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"temp":null}')
        return
    end

    local ok, data = pcall(cjson.decode, res.body)
    if not ok then
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"temp":null}')
        return
    end

    local current = data.current
    if not current then
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"temp":null}')
        return
    end

    local city = reverse_geocode(tonumber(lat), tonumber(lon))
    local result = {
        temp = current.temperature_2m,
        feels_like = current.apparent_temperature,
        humidity = current.relative_humidity_2m,
        wind_speed = current.wind_speed_10m,
        wind_direction = current.wind_direction_10m,
        city = city,
    }

    local body = cjson.encode(result)
    redis.set(cache_key, body, 900)  -- 15 min

    ngx.header["Content-Type"] = "application/json"
    ngx.say(body)
end

return _M

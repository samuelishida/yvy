-- tools/enrich_fire_deter.lua — FIRMS × DETER crossover enrichment (detached)
--
-- Reprocessa os focos dos últimos N dias: para cada foco dentro de uma
-- propriedade CAR com linha em deter_car_alerts, injeta o contexto DETER no
-- territory e re-roda fire_classify.classify_fire — o que pode upgrade
-- suspeito → crime (Cenário C). Depois mescla o objeto `deter` na evidência
-- persistida (nature_evidence.deter).
--
-- Duas formas de linha em deter_car_alerts (Inc 3):
--   • classname real (ex. DESMATAMENTO_VEG) → has_deter_nearby=true
--   • classname="FIRMS" (Pass 2, fogo-driven medio/baixo) → has_deter_nearby=false
--     — NÃO rotular um foco como "tem alerta DETER" quando não tem.
--
-- WHY detached: como classify_fires.lua — cruzamento CAR por foco é CPU-heavy
-- num loop copas single-threaded; roda via nohup e escreve direto no SQLite.
--
-- Usage: lua5.1 tools/enrich_fire_deter.lua [days]

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local backend_dir = script_dir:gsub("[\\/]tools[\\/]$", "/")
package.path = backend_dir .. "?.lua;" .. backend_dir .. "?/init.lua;" .. package.path

local env = require("app.env")
env.load_dotenv(backend_dir .. "../.env")
env.load_dotenv(backend_dir .. ".env")

local db            = require("app.db")
local redis         = require("app.redis")
local fire_classify = require("app.fire_classify")
local cjson         = require("cjson")
local logger        = require("app.logger")

local days = tonumber(arg and arg[1]) or 7

db.init_db()

local car = nil
pcall(function() car = require("app.lookups.car_lookup") end)
if car and car.load_car then pcall(car.load_car) end

-- Constrói o objeto `deter` da evidência a partir das linhas deter_car_alerts
-- do imóvel. `alerts` vem ordenado por view_date DESC (get_car_alerts_by_imovel).
local function build_deter(alerts, cod_imovel)
    if not alerts or #alerts == 0 then return nil end
    local a = alerts[1]
    if a.classname == "FIRMS" then
        -- Pass 2: alerta fire-driven (medio/baixo) — NÃO é um DETER real
        return {
            has_deter_nearby = false,
            deter_classname = cjson.null,
            deter_view_date = cjson.null,
            car_imovel = cod_imovel,
            severity = a.severity,
        }
    end
    return {
        has_deter_nearby = true,
        deter_classname = a.classname,
        deter_view_date = a.view_date,
        car_imovel = cod_imovel,
        severity = a.severity,
    }
end

local BATCH = 500
local t0 = os.time()
local total = 0
local version = fire_classify.NATURE_VERSION
local last_id = 0

while true do
    local batch = db.iter_fires_recent(days, BATCH, last_id)
    if #batch == 0 then break end

    local rows = {}
    for _, row in ipairs(batch) do
        local territory = {}
        local car_hit = car and car.classify_point and car.classify_point(row.lon, row.lat)
        if car_hit then
            territory.car = { name = car_hit.name, id = car_hit.id }
            local alerts = db.get_car_alerts_by_imovel(car_hit.id, days)
            local deter = build_deter(alerts, car_hit.id)
            if deter then territory.deter = deter end
        end

        local res = fire_classify.classify_fire(row, territory)
        local evidence = res.evidence
        if territory.deter then
            evidence.deter = territory.deter  -- mescla contexto DETER (qualquer caminho)
        end
        rows[#rows + 1] = {
            id = row.id,
            nature = res.nature,
            evidence = evidence,
            at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        }
        last_id = row.id
    end
    db.update_fire_natures(rows, version)
    total = total + #rows

    if #batch < BATCH then break end
end

local duration = os.time() - t0

-- Invalida caches derivadas
redis.delete_pattern("fires:nature:*")
redis.delete_pattern("firescache:*")

-- Marcador observável (stdout do nohup é descartado)
redis.set("fires:deter:last_run", cjson.encode({
    count = total, duration = duration, days = days, version = version,
}), 86400)

logger.info("DETER enrichment done: " .. total .. " fires (v" .. version .. ") in " .. duration .. "s")

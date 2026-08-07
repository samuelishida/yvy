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

-- TI/UC (Inc 8): geometrias de terra indígena e unidade de conservação para o
-- caminho de crime-em-área-protegida do fire_classify (~linha 144). Mesmos
-- lookups do tools/classify_fires.lua; pcall para uma falha de lookup não
-- derrubar o tool (loga e mantém o comportamento anterior).
local ti = nil
pcall(function() ti = require("app.lookups.indigenous_lands_lookup") end)
if ti and ti.load_indigenous_lands then pcall(ti.load_indigenous_lands) end
local uc = nil
pcall(function() uc = require("app.lookups.conservation_units_lookup") end)
if uc and uc.load_conservation_units then pcall(uc.load_conservation_units) end

-- Constrói o objeto `deter` da evidência a partir das linhas deter_car_alerts
-- do imóvel. `alerts` vem ordenado por view_date DESC (get_car_alerts_by_imovel).
-- Inc 8: itera TODAS as linhas e escolhe o DETER real mais recente por
-- view_date — um foco FIRMS (Pass 2, classname="FIRMS") não pode mascarar um
-- alerta DETER real da mesma propriedade.
local function build_deter(alerts, cod_imovel)
    if not alerts or #alerts == 0 then return nil end
    local best = nil  -- linha DETER real mais recente (classname != "FIRMS")
    for _, a in ipairs(alerts) do
        if a.classname ~= "FIRMS" then
            if not best or (a.view_date or "") > (best.view_date or "") then
                best = a
            end
        end
    end
    if not best then
        -- Pass 2: alerta fire-driven (medio/baixo) — NÃO é um DETER real.
        -- alerts[1] é a linha mais recente (ordenação view_date DESC).
        return {
            has_deter_nearby = false,
            deter_classname = cjson.null,
            deter_view_date = cjson.null,
            car_imovel = cod_imovel,
            severity = alerts[1].severity,
        }
    end
    return {
        has_deter_nearby = true,
        deter_classname = best.classname,
        deter_view_date = best.view_date,
        car_imovel = cod_imovel,
        severity = best.severity,
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

        -- TI/UC (Inc 8): injeta a geometria protegida para que o caminho de
        -- crime (fire_classify, linha ~144) dispare. Falha de lookup → loga e
        -- segue com o comportamento anterior (sem crash do tool).
        local ti_hit = nil
        local ti_ok, ti_err = pcall(function()
            ti_hit = ti and ti.classify_point and ti.classify_point(row.lon, row.lat) or nil
        end)
        if not ti_ok then
            logger.warn("TI lookup failed for fire " .. tostring(row.id) .. ": " .. tostring(ti_err))
            ti_hit = nil
        end
        if ti_hit then territory.indigenous = ti_hit.name or ti_hit.full_name end

        local uc_hit = nil
        local uc_ok, uc_err = pcall(function()
            uc_hit = uc and uc.classify_point and uc.classify_point(row.lon, row.lat) or nil
        end)
        if not uc_ok then
            logger.warn("UC lookup failed for fire " .. tostring(row.id) .. ": " .. tostring(uc_err))
            uc_hit = nil
        end
        if uc_hit then territory.conservation = uc_hit.name or uc_hit.full_name end

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

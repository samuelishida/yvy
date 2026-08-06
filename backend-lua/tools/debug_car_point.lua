-- tools/debug_car_point.lua — Diagnóstico: o que cada camada diz sobre um ponto.
--
-- Uso: lua5.1 tools/debug_car_point.lua <lat> <lon> [acq_date]
--   Ex: lua5.1 tools/debug_car_point.lua -11.19154 -54.90798 2026-08-05
--
-- Mostra o resultado de TI / UC / CAR (car_lookup.classify_point) e, se
-- acq_date for dado, a natureza final que o fire_classify atribuiria
-- (crime/suspeito/permitido/natural) + evidência.

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local backend_dir = script_dir:gsub("[\\/]tools[\\/]$", "/")
package.path = backend_dir .. "?.lua;" .. backend_dir .. "?/init.lua;" .. package.path

local env = require("app.env")
env.load_dotenv(backend_dir .. "../.env")
env.load_dotenv(backend_dir .. ".env")

local cjson          = require("cjson")
local fire_classify  = require("app.fire_classify")
local ti             = require("app.lookups.indigenous_lands_lookup")
local uc             = require("app.lookups.conservation_units_lookup")
local car            = require("app.lookups.car_lookup")

local lat = tonumber(arg and arg[1])
local lon = tonumber(arg and arg[2])
local acq_date = arg and arg[3]

if not lat or not lon then
    print("uso: lua5.1 tools/debug_car_point.lua <lat> <lon> [acq_date]")
    os.exit(1)
end

ti.load_indigenous_lands()
uc.load_conservation_units()
car.load_car()

local function name_of(t) return t and (t.name or t.full_name) or nil end

local ti_hit  = name_of(ti.classify_point(lon, lat))
local uc_hit  = name_of(uc.classify_point(lon, lat))
local car_hit = car.classify_point and car.classify_point(lon, lat) or nil

print("ponto: " .. lat .. ", " .. lon)
print("  TI (terra indígena): " .. tostring(ti_hit))
print("  UC (unid. conserv.): " .. tostring(uc_hit))
if car_hit then
    print("  CAR: " .. car_hit.id .. " (" .. car_hit.name .. "/" .. car_hit.uf .. ")")
    print("  CAR count total: " .. tostring(car.count and car.count() or "?"))
else
    print("  CAR: (nenhum imóvel)"
)
end

if acq_date then
    local territory = {
        indigenous   = ti_hit,
        conservation = uc_hit,
        car          = car_hit,
    }
    local fire = { lon = lon, lat = lat, acq_date = acq_date, state = car_hit and car_hit.uf or "" }
    local res = fire_classify.classify_fire(fire, territory)
    print("  acq_date=" .. acq_date .. " -> natureza: " .. tostring(res and res.nature))
    print("  evidência: " .. cjson.encode(res and res.evidence or {}))
end

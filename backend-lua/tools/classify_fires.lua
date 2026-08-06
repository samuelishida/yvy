-- tools/classify_fires.lua — detached subprocess that classifies the NATURE of
-- unclassified (or outdated-version) fires and writes it back to fire_data.
--
-- WHY: the backend is a single-threaded copas loop. The territorial crossing
-- (TI 547 + UC 298 + CAR ~7M polygons) over many fires is CPU-heavy and would
-- block every other request if run inline. The admin route therefore spawns
-- this script detached (nohup ... &); results are written straight to SQLite
-- and the caches are invalidated at the end. The event loop never blocks.
--
-- Usage: lua5.1 tools/classify_fires.lua [version]
--   version = 0 (default)               → only nature IS NULL (routine)
--   version = FIRE_NATURE_VERSION (ex: 2) → also reclassify nature_version < v
--           (bump when CAR is imported or the moratorium config changes)

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local backend_dir = script_dir:gsub("[\\/]tools[\\/]$", "/")
package.path = backend_dir .. "?.lua;" .. backend_dir .. "?/init.lua;" .. package.path

local env = require("app.env")
env.load_dotenv(backend_dir .. "../.env")
env.load_dotenv(backend_dir .. ".env")

local db             = require("app.db")
local redis          = require("app.redis")
local fire_classify  = require("app.fire_classify")
local ti             = require("app.lookups.indigenous_lands_lookup")
local uc             = require("app.lookups.conservation_units_lookup")
local cjson          = require("cjson")
local logger         = require("app.logger")

local version = tonumber(arg and arg[1]) or 0

db.init_db()
ti.load_indigenous_lands()
uc.load_conservation_units()

-- CAR layer (Inc 6): carrega se disponível; sem car_lookup.lua o sistema
-- simplesmente não cruza com CAR (territory.car = nil).
local car = nil
pcall(function() car = require("app.lookups.car_lookup") end)
if car and car.load_car then pcall(car.load_car) end

local BATCH = 500
local t0 = os.time()
local total = 0
local by_nature = {}

while true do
    local batch = db.iter_fires_for_classification(BATCH, version)
    if #batch == 0 then break end

    local rows = {}
    for _, row in ipairs(batch) do
        local territory = {
            indigenous   = ti.classify_point(row.lon, row.lat),
            conservation = uc.classify_point(row.lon, row.lat),
            car          = car and car.classify_point and car.classify_point(row.lon, row.lat) or nil,
        }
        local res = fire_classify.classify_fire(row, territory)
        if res and res.nature then
            rows[#rows + 1] = {
                id = row.id,
                nature = res.nature,
                evidence = res.evidence,
                at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            }
            by_nature[res.nature] = (by_nature[res.nature] or 0) + 1
        end
    end
    db.update_fire_natures(rows, version)
    total = total + #rows
end

local duration = os.time() - t0

-- Invalida caches derivadas para o /api/fires e /api/fires/nature-stats
-- refletirem a classificação nova.
redis.delete_pattern("fires:nature:*")
redis.delete_pattern("firescache:*")

-- Marcador observável (o stdout/stderr do nohup é descartado — ver verificação
-- do Inc 4: conferir este marcador + COUNT(*) WHERE nature IS NULL).
redis.set("fires:classify:last_run", cjson.encode({
    count = total, duration = duration, by_nature = by_nature, version = version,
}), 86400)

logger.info("Fire classification done: " .. total .. " fires (v" .. version .. ") in " .. duration .. "s")

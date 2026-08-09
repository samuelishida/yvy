-- tools/import_car.lua — CLI: GeoJSON (por UF) → car.db
--
-- Usage: lua5.1 tools/import_car.lua [UF ...]
--   sem args → importa todos os 27 UFs que tiverem arquivo em data/car/<UF>.json
-- Ex: lua5.1 tools/import_car.lua RO
--
-- Roda OFFLINE (dev/ops), nunca no loop copas. Otimizações do bulk load:
-- synchronous=OFF numa transação por UF; ao final wal_checkpoint(TRUNCATE) +
-- VACUUM + ANALYZE + PRAGMA optimize.

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local backend_dir = script_dir:gsub("[\\/]tools[\\/]$", "/")
package.path = backend_dir .. "?.lua;" .. backend_dir .. "?/init.lua;" .. package.path

local env = require("app.env")
env.load_dotenv(backend_dir .. "../.env")
env.load_dotenv(backend_dir .. ".env")

local sqlite3 = require("lsqlite3")
local car_import = require("app.car_import")

local UFS = {"AC","AL","AM","AP","BA","CE","DF","ES","GO","MA","MG","MS","MT",
             "PA","PB","PE","PI","PR","RJ","RN","RO","RR","RS","SC","SE","SP","TO"}

local car_db = car_import.car_db_path()
local data_dir = backend_dir .. "data/car"

-- Garante diretório
local dir = car_db:match("^(.*)[/\\]")
if dir then
    if package.config:sub(1, 1) == "\\" then
        os.execute('mkdir "' .. dir .. '" >NUL 2>NUL')
    else
        os.execute('mkdir -p "' .. dir .. '"')
    end
end

local conn = sqlite3.open(car_db)
conn:exec("PRAGMA journal_mode=WAL")
conn:exec("PRAGMA synchronous=OFF")   -- bulk load
conn:exec("PRAGMA cache_size=-200000")
conn:exec("PRAGMA temp_store=MEMORY")
car_import.create_schema(conn)
car_import.create_car_protected_schema(conn)

local args = {...}
local targets = {}
if #args > 0 then
    for _, uf in ipairs(args) do targets[#targets + 1] = uf:upper() end
else
    targets = UFS
end
table.sort(targets)

-- Reimport idempotente por UF: apaga pré-cálculo da UF ANTES de apagar os
-- dados, evitando overlaps órfãos (plan: car-protected-optimize).
local total = 0
for _, uf in ipairs(targets) do
    car_import.delete_car_protected_for_uf(conn, uf)
    conn:exec("DELETE FROM car_data WHERE uf = '" .. uf .. "'")
    conn:exec("DELETE FROM car_rtree WHERE id IN (SELECT id FROM car_data WHERE uf = '" .. uf .. "')")
    local n = car_import.import_file(conn, data_dir .. "/" .. uf .. ".json", total)
    total = total + n
end

conn:exec("PRAGMA wal_checkpoint(TRUNCATE)")
conn:exec("VACUUM")
conn:exec("ANALYZE")
conn:exec("PRAGMA optimize")
conn:close()

print("import done: " .. total .. " imóveis -> " .. car_db)

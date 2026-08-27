-- tools/import_car.lua — CLI: GeoJSON (por UF) → car.db
--
-- Usage: lua5.1 tools/import_car.lua [UF ...]
--   sem args → importa todos os 27 UFs que tiverem arquivo em data/car/<UF>.json
-- Ex: lua5.1 tools/import_car.lua RO
--
-- Roda OFFLINE (dev/ops), nunca no loop copas. Otimizações do bulk load:
-- synchronous=OFF numa transação por UF; ao final wal_checkpoint(TRUNCATE) +
-- VACUUM + ANALYZE + PRAGMA optimize.

-- RESOLUÇÃO DOS CAMINHOS EM PRA (independente do cwd). BUG REAL (2026-08):
-- rodando como `lua5.1 tools/import_car.lua`, debug.getinfo(1).source é
-- RELATIVO ("tools/import_car.lua") → data_dir virava "tools/data/car"
-- (inexistente), mas car_db_path() ainda apontava para o car.db de verdade:
-- o DELETE por UF esvaziava o banco e a importação zerava — e o cron
-- car_weekly continuava o scp + swap atômico, distribuindo o car.db VAZIO
-- p/ prod (clique no imóvel regrediu p/ {"imovel":null}).
local src_raw = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
local src_abs = src_raw
if src_raw ~= "" and not src_raw:match("^[/\\]") then
    local pwd = os.getenv("PWD")
    if pwd and pwd ~= "" and pwd:match("^/") then src_abs = pwd .. "/" .. src_raw end
end
local stem_match = src_abs:match("^(.*[/\\])[%w_%.%-]+$")
local script_dir = stem_match or ""
local backend_dir = script_dir:gsub("[/\\]tools[/\\]?$", "/")
if backend_dir == "" and script_dir == "" then
    -- último recurso: cwd
    backend_dir = "./"
end
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
car_import.create_car_prodes_schema(conn)

local args = {...}
local targets = {}
if #args > 0 then
    for _, uf in ipairs(args) do targets[#targets + 1] = uf:upper() end
else
    targets = UFS
end
table.sort(targets)

-- Reimport idempotente por UF: apaga pré-cálculo da UF ANTES de apagar os
-- dados, evitando overlaps/prodes órfãos (plan: car-protected-optimize / precompute-car-prodes).
-- O cleanup do rtree CAPTURA OS IDS ANTES do DELETE de car_data: a versão
-- anterior usava o subquery "DELETE FROM car_rtree WHERE id IN (SELECT id
-- FROM car_data WHERE uf=...)" APOS o delete da tabela — nunca achava nada e
-- o banco ficou com 8.4M linhas fantasmas no rtree (lookup: rtree ok +
-- car_data vazio → {imovel:null} em todo clique, tile continuava renderizando).
local total = 0
for _, uf in ipairs(targets) do
    car_import.delete_car_protected_for_uf(conn, uf)
    car_import.delete_car_prodes_for_uf(conn, uf)
    local ids = {}
    for row in conn:nrows("SELECT id FROM car_data WHERE uf = '" .. uf .. "'") do
        ids[#ids + 1] = row.id
    end
    conn:exec("DELETE FROM car_data WHERE uf = '" .. uf .. "'")
    car_import.delete_rtree_by_ids(conn, ids)
    local n = car_import.import_file(conn, data_dir .. "/" .. uf .. ".json", total)
    total = total + n
end

-- Reconciliação pós-import: remove QUALQUER linha órfã do rtree (defesa em
-- profundidade contra a class-2026-08 do bug — 8.4M fantasmas deixados por
-- um import falho; o gate car_rtree==car_data do car_weekly.sh cobraria de
-- qualquer jeito, mas melhor não deixá-las entrar no deploy).
conn:exec("DELETE FROM car_rtree WHERE NOT EXISTS (SELECT 1 FROM car_data WHERE car_data.id = car_rtree.id)")

conn:exec("PRAGMA wal_checkpoint(TRUNCATE)")
conn:exec("VACUUM")
conn:exec("ANALYZE")
conn:exec("PRAGMA optimize")
conn:close()

print("import done: " .. total .. " imóveis -> " .. car_db)

-- Guarda anti-esvaziamento (incidente 2026-08-17/24): DELETE por UF + 0 linhas
-- importadas (arquivos perdidos, parse quebrado, caminho errado) não pode
-- terminar com exit 0 — o caller (car_weekly.sh) precisa do exit code para
-- NÃO scp'dar/trocar o car.db esvaziado em prod.
if total == 0 then
    io.stderr:write("ERROR: import gerou 0 imóveis — verifique data/car/<UF>.json; car.db NÃO deve ser trocado\n")
    os.exit(1)
end

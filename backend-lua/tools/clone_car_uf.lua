-- tools/clone_car_uf.lua <src.db> <dst.db> <UF>
--
-- Cria um clone FILTRADO POR UF do car.db: copia só as linhas de car_data da
-- UF + as rows correspondentes de car_rtree + todos os schemas (incluindo
-- car_prodes vazia). O warm CAR × PRODES roda nesse clone e o merge só extrai
-- a tabela car_prodes.
--
-- Por que filtrado em vez de cópia integral? O car.db tem ~7 GB; 27 cópias
-- integrais não cabem em disco. Um clone por UF (~car.db/27 ≈ 250 MB) é
-- suficiente porque o warm só processa os imóveis da UF e car_lookup resolve
-- por cod_imovel dentro da mesma UF.
--
-- Requisitos: lua5.1 + lsqlite3 (sem CLI sqlite3 — lê o WAL via lsqlite3).

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local backend_dir = script_dir:gsub("[\\/]tools[\\/]$", "/")
package.path = backend_dir .. "?.lua;" .. backend_dir .. "?/init.lua;" .. package.path

local sqlite3 = require("lsqlite3")
local car_import = require("app.car_import")

local src = arg[1]
local dst = arg[2]
local uf = arg and arg[3] and arg[3]:upper() or ""

if not src or not dst or uf == "" then
    print("usage: lua5.1 tools/clone_car_uf.lua <src.db> <dst.db> <UF>")
    os.exit(1)
end

local dconn = sqlite3.open(dst)
if not dconn then
    print("clone_car_uf: cannot create " .. dst)
    os.exit(1)
end
dconn:exec("PRAGMA journal_mode=WAL")
dconn:exec("PRAGMA synchronous=OFF")
dconn:exec("PRAGMA cache_size=-200000")
dconn:exec("PRAGMA busy_timeout=60000")
car_import.create_schema(dconn)
car_import.create_car_protected_schema(dconn)
car_import.create_car_prodes_schema(dconn)

-- Copia via ATTACH + INSERT SELECT para PRESERVAR o storage class nativo do
-- `geom` (BLOB JSONB). Copiar BLOB por Lua liga como TEXT e corrompe o JSONB
-- ("malformed JSON" no json(geom) da leitura).
local astmt = dconn:prepare("ATTACH DATABASE ? AS src")
astmt:bind_values(src)
if astmt:step() ~= sqlite3.DONE then
    print("clone_car_uf: ATTACH falhou para " .. src)
    os.exit(1)
end
astmt:finalize()

dconn:exec("BEGIN")
local n = dconn:exec(string.format([[
    INSERT INTO car_data (id, cod_imovel, uf, municipio, area, geom)
    SELECT id, cod_imovel, uf, municipio, area, geom
    FROM src.car_data WHERE uf = '%s'
]], uf))
dconn:exec("COMMIT")
if n ~= sqlite3.OK then
    print("clone_car_uf: copia de car_data falhou para " .. uf)
    os.exit(1)
end

-- car_rtree só dos ids da UF (join evita rows de outras UFs).
dconn:exec("BEGIN")
local m = dconn:exec(string.format([[
    INSERT INTO car_rtree (id, minLon, maxLon, minLat, maxLat)
    SELECT r.id, r.minLon, r.maxLon, r.minLat, r.maxLat
    FROM src.car_rtree r JOIN src.car_data d ON r.id = d.id
    WHERE d.uf = '%s'
]], uf))
dconn:exec("COMMIT")
if m ~= sqlite3.OK then
    print("clone_car_uf: copia de car_rtree falhou para " .. uf)
    os.exit(1)
end

local cnt = 0
for r in dconn:nrows("SELECT count(*) AS c FROM car_data") do cnt = tonumber(r.c) or 0 end

dconn:exec("DETACH DATABASE src")
dconn:exec("ANALYZE")
dconn:exec("PRAGMA wal_checkpoint(TRUNCATE)")
dconn:close()
print(string.format("clone_car_uf: %s -> %s (imoveis=%d)", uf, dst, cnt))

-- merge_car_protected_overlap.lua
-- Uso: lua5.1 tools/merge_car_protected_overlap.lua <clone1.db> [<clone2.db> ...]
-- Faz merge OR REPLACE de todas as tabelas car_protected_overlap dos clones
-- para o car.db principal.
package.path = package.path .. ";./?.lua;app/?.lua;app/lookups/?.lua"
package.cpath = package.cpath .. ";./?.so"

local sqlite3 = require("lsqlite3")
local env = require("app.env")

local target = env.get("CAR_DB_PATH") or "data/car/car.db"
local clones = {}
for i = 1, #arg do table.insert(clones, arg[i]) end

local function attach(conn, path, alias)
  local stmt = conn:prepare("ATTACH DATABASE ? AS " .. alias)
  if not stmt then
    error("failed to prepare ATTACH for " .. path .. ": " .. tostring(conn:errmsg()))
  end
  stmt:bind_values(path)
  if stmt:step() ~= sqlite3.DONE then
    stmt:finalize()
    error("failed to attach " .. path .. ": " .. tostring(conn:errmsg()))
  end
  stmt:finalize()
end

local function exec(conn, sql)
  local ok, err = conn:exec(sql)
  if ok ~= sqlite3.OK then
    error("SQL error: " .. sql .. " -> " .. tostring(err or conn:errmsg()))
  end
end

local conn = sqlite3.open(target)
conn:busy_timeout(60000)
exec(conn, "PRAGMA journal_mode=WAL")
exec(conn, "PRAGMA foreign_keys=OFF")
exec(conn, "PRAGMA synchronous=NORMAL")

for i, path in ipairs(clones) do
  local alias = "c" .. i
  attach(conn, path, alias)
  print("attached " .. path .. " as " .. alias)
end

exec(conn, "BEGIN IMMEDIATE")
for i = 1, #clones do
  local alias = "c" .. i
  local sql = string.format(
    "INSERT OR REPLACE INTO car_protected_overlap " ..
    "SELECT cod_imovel, sampled, overlaps, status, max_pct, threshold, version_key, computed_at " ..
    "FROM %s.car_protected_overlap", alias)
  print("merging " .. alias .. " ...")
  exec(conn, sql)
end
exec(conn, "COMMIT")

for i = 1, #clones do
  exec(conn, "DETACH DATABASE c" .. i)
end

-- Vacuum compacta o DB após bulk insert (pode demorar, mas reduz tamanho).
print("vacuuming target ...")
exec(conn, "VACUUM")

conn:close()
print("merge complete. total clones: " .. #clones)

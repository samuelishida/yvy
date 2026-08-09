-- merge_car_prodes.lua
-- Uso: lua5.1 tools/merge_car_prodes.lua <clone1.db> [<clone2.db> ...]
-- Faz merge OR REPLACE da tabela car_prodes dos clones para o car.db principal.
-- Aborta se detectar version_key inconsistente entre os clones (sinal de dataset
-- divergente ou warm parcial). O target pode já ter rows antigas; elas serão
-- sobrescritas se version_key casar, ou ignoradas na comparação de sanity.
package.path = package.path .. ";./?.lua;app/?.lua;app/lookups/?.lua"
package.cpath = package.cpath .. ";./?.so"

local sqlite3 = require("lsqlite3")
local env     = require("app.env")
local car_import = require("app.car_import")

-- Require-ável para testes (padrão deter_protected_alerts.lua): exports
-- _M.merge(target, clones); quando carregado como módulo (busted), NÃO executa
-- o merge no load.
local _M = {}

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

local function single_value(conn, sql)
    local stmt = conn:prepare(sql)
    if not stmt then return nil end
    local v
    for r in stmt:nrows() do
        v = r.v
        break
    end
    stmt:finalize()
    return v
end

local function merge_impl(target, clones)
if #clones == 0 then
    error("merge_car_prodes: no clones provided")
end

local conn = sqlite3.open(target)
conn:busy_timeout(60000)
exec(conn, "PRAGMA journal_mode=WAL")
exec(conn, "PRAGMA foreign_keys=OFF")
exec(conn, "PRAGMA synchronous=NORMAL")

-- Garante o schema no target: um car.db legado (sem car_prodes) não pode
-- quebrar o merge. Idempotente via CREATE TABLE IF NOT EXISTS.
car_import.create_car_prodes_schema(conn)

-- Fase 1 — VALIDAÇÃO: abre cada clone individualmente (SQLite limita a 10
-- ATTACH por conexão; com 27 UFs é impossível validar todos anexados de uma
-- vez). Verifica tabela presente e lê o version_key de cada clone.
local version_keys = {}
for _, path in ipairs(clones) do
    local c = sqlite3.open(path)
    if not c then
        error("cannot open clone: " .. path)
    end
    c:exec("PRAGMA busy_timeout=60000")
    local has_table = false
    for r in c:nrows("SELECT 1 FROM sqlite_master WHERE type='table' AND name='car_prodes'") do
        has_table = true
    end
    if not has_table then
        c:close()
        error("clone missing car_prodes table: " .. path)
    end
    local key = single_value(c, "SELECT version_key AS v FROM car_prodes LIMIT 1")
    if key then version_keys[key] = (version_keys[key] or 0) + 1 end
    print("validated " .. path .. " version_key=" .. tostring(key))
    c:close()
end

-- Requer que haja exatamente um version_key dominante com >0 rows.
local dominant_key, dominant_count = nil, 0
local total_with_key = 0
for k, c in pairs(version_keys) do
    total_with_key = total_with_key + c
    if c > dominant_count then
        dominant_key = k
        dominant_count = c
    end
end
if not dominant_key then
    error("no version_key found in any clone")
end
if dominant_count < total_with_key then
    local msg = "inconsistent version_key across clones:"
    for k, c in pairs(version_keys) do
        msg = msg .. " " .. k .. "=" .. c
    end
    error(msg)
end

-- Substituição completa: o merge regenera TODAS as UFs. Rows antigas do target
-- (warm anterior / smoke test) com version_key diferente são apagadas; rows do
-- key dominante já presentes são sobrescritas pelo INSERT OR REPLACE abaixo.
-- Só aborta se os CLONES divergirem entre si (validado acima) — um re-warm
-- legítimo sempre troca o version_key inteiro.
local del = conn:prepare("DELETE FROM car_prodes WHERE version_key <> ?")
del:bind_values(dominant_key)
del:step()
del:finalize()

-- Fase 2 — INSERT em lotes de ≤8 clones: ATTACH, INSERT OR REPLACE (só rows do
-- version_key dominante), DETACH. SEM transação global: o SQLite não permite
-- DETACH dentro de transação ("database is locked"). É uma operação offline
-- idempotente — cada INSERT é atômico e re-executar o merge é seguro (o
-- DELETE de rows não-dominantes no início + INSERT OR REPLACE tornam o merge
-- convergente).
local BATCH = 8
for start = 1, #clones, BATCH do
    local finish = math.min(start + BATCH - 1, #clones)
    -- ATTACH do lote
    for i = start, finish do
        local alias = "c" .. i
        attach(conn, clones[i], alias)
    end
    -- INSERT de cada clone do lote
    for i = start, finish do
        local alias = "c" .. i
        local sql = string.format(
            "INSERT OR REPLACE INTO car_prodes " ..
            "SELECT cod_imovel, found, has_prodes, prodes_area_ha, property_area_ha, " ..
            "pct_deforested, years, classes, regrowth, sampled, bbox, area_estimate, " ..
            "version_key, computed_at " ..
            "FROM %s.car_prodes WHERE version_key = ?", alias)
        local stmt = conn:prepare(sql)
        if not stmt then
            error("failed to prepare merge for " .. alias .. ": " .. tostring(conn:errmsg()))
        end
        stmt:bind_values(dominant_key)
        if stmt:step() ~= sqlite3.DONE then
            stmt:finalize()
            error("merge failed for " .. alias .. ": " .. tostring(conn:errmsg()))
        end
        stmt:finalize()
        print("merged " .. alias)
    end
    -- DETACH do lote (fora de transação)
    for i = start, finish do
        exec(conn, "DETACH DATABASE c" .. i)
    end
end

print("vacuuming target ...")
exec(conn, "VACUUM")

conn:close()
print("merge complete: version_key=" .. dominant_key .. " clones=" .. #clones)
end

_M.merge = merge_impl

-- arg[0] = script principal quando rodado direto (lua5.1 tools/merge_car_prodes.lua)
local is_main = arg and arg[0] and arg[0]:match("merge_car_prodes%.lua$")
if is_main then
    local clones = {}
    for i = 1, #arg do table.insert(clones, arg[i]) end
    if #clones == 0 then
        print("usage: lua5.1 tools/merge_car_prodes.lua <clone1.db> [<clone2.db> ...]")
        os.exit(1)
    end
    local target = env.get("CAR_DB_PATH") or "data/car/car.db"
    local ok, err = pcall(merge_impl, target, clones)
    if not ok then
        print("merge failed: " .. tostring(err))
        os.exit(1)
    end
end

return _M

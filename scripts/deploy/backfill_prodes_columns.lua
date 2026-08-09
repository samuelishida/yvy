#!/usr/bin/env lua5.1
-- backfill_prodes_columns.lua — Preenche year/class_type em deforestation_data
-- (plan: optimize-car-prodes-queries, Inc 1).
--
-- Script manual one-shot, rodado ANTES do deploy com o backend parado.
-- Pega o mesmo DB que o backend usa (backend-lua/data/yvy.db) e faz o backfill
-- em batches de 10k, resumível via WHERE year IS NULL.
--
-- Uso:  lua5.1 scripts/deploy/backfill_prodes_columns.lua
--   ou: make backfill-prodes  (a partir de backend-lua/)

local sqlite3 = require("lsqlite3")

-- Resolve DB path: backend-lua/data/yvy.db relativo ao diretório do script.
-- O script está em scripts/deploy/, então o repo root é ../../.
local script_dir = arg[0]:match("^(.*)[/\\]")
if not script_dir then script_dir = "." end
local repo_root = script_dir .. "/../.."

-- Permite override via SQLITE_PATH (mesma env do backend).
local env_path = os.getenv("SQLITE_PATH")
local DB_PATH = env_path or (repo_root .. "/backend-lua/data/yvy.db")

local BATCH_SIZE = 10000

-- Mesma lógica de parse_prodes_label do db.lua: casa [dr]+4 dígitos em
-- qualquer posição do rótulo QML (ex: "7 d2007", "64 r2024", "d2020").
local function parse_prodes_label(name)
    if type(name) ~= "string" then return nil end
    local t, yyyy = name:match("([dr])(%d%d%d%d)")
    if not t then return nil end
    return t, yyyy
end

local function log(msg)
    io.write("[" .. os.date("!%Y-%m-%dT%H:%M:%SZ") .. "] " .. msg .. "\n")
    io.flush()
end

local db = sqlite3.open(DB_PATH)
if not db then
    log("ERROR: cannot open " .. DB_PATH)
    os.exit(1)
end

db:exec("PRAGMA journal_mode=WAL")
db:exec("PRAGMA synchronous=NORMAL")
db:exec("PRAGMA busy_timeout=5000")

-- Verifica que as colunas existem (init_db() deve ter rodado antes).
local has_year = false
local stmt = db:prepare("PRAGMA table_info(deforestation_data)")
if stmt then
    for row in stmt:rows() do
        local colname = row[2] or row["name"] or ""
        if colname == "year" then has_year = true end
    end
    stmt:finalize()
end
if not has_year then
    log("ERROR: column 'year' does not exist in deforestation_data.")
    log("       Start the backend once (make start) so init_db() adds the columns, then re-run.")
    db:close()
    os.exit(1)
end

-- SELECT id, name das linhas com year NULL — usa json_extract no BLOB data.
local select_sql = [[
    SELECT id, json_extract(data, '$.name') AS name
    FROM deforestation_data
    WHERE year IS NULL
    ORDER BY rowid
    LIMIT ?
]]

local update_sql = "UPDATE deforestation_data SET year = ?, class_type = ? WHERE id = ?"

local total = 0
local batch_num = 0
local remaining = db:prepare("SELECT COUNT(*) AS c FROM deforestation_data WHERE year IS NULL")
if remaining then
    local row = remaining:nrows()()
    remaining:finalize()
    log("Rows to backfill: " .. tostring(row and (row.c or row["c"]) or "?"))
end

while true do
    local sel = db:prepare(select_sql)
    if not sel then
        log("ERROR: prepare select failed: " .. db:errmsg())
        break
    end
    sel:bind(1, BATCH_SIZE)

    local updates = {}
    local batch_count = 0
    for row in sel:nrows() do
        local id = row.id or row["id"]
        local name = row.name or row["name"]
        local class_type, year = nil, nil
        if name then
            local t, yyyy = parse_prodes_label(name)
            if t then class_type = t; year = tonumber(yyyy) end
        end
        -- Se não casar o padrão, year/class_type ficam NULL (mesmo comportamento
        -- de runtime). Não bloqueia o batch.
        updates[#updates + 1] = { id = id, year = year, class_type = class_type }
        batch_count = batch_count + 1
    end
    sel:finalize()

    if batch_count == 0 then break end

    db:exec("BEGIN")
    local upd = db:prepare(update_sql)
    for _, u in ipairs(updates) do
        upd:bind(1, u.year or nil)
        upd:bind(2, u.class_type or nil)
        upd:bind(3, u.id)
        upd:step()
        upd:reset()
    end
    upd:finalize()
    db:exec("COMMIT")

    total = total + batch_count
    batch_num = batch_num + 1
    log(string.format("Backfilled batch %d: %d rows (total: %d)", batch_num, batch_count, total))
end

db:close()
log("Done. Total rows backfilled: " .. total)
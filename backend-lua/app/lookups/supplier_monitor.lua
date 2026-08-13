-- app/lookups/supplier_monitor.lua — fornecedores monitorados + alertas in-app.
--
-- DB dedicado `suppliers.db` (padrão car.db): nunca toca o yvy.db vivo. Cada
-- fornecedor tem cnpj PK + dados de contato/geometria + webhook_url. O scan
-- (tools/scan_supplier_alerts.lua) cruza alertas MapBiomas recentes com os
-- fornecedores e grava alertas em Redis `risk:supplier_alert:<cnpj>` (TTL) +
-- `risk:supplier_alerts` (lista in-app).

require("app.env")
local env     = require("app.env")
local sqlite3 = require("lsqlite3")
local cjson   = require("cjson")
local logger  = require("app.logger")
local redis   = require("app.redis")

local _M = {}

local SUPPLIERS_DB_PATH = env.get("SUPPLIERS_DB_PATH") or env.first_with_existing_parent({
    "backend-lua/data/suppliers/suppliers.db",
    "data/suppliers/suppliers.db",
    "../backend-lua/data/suppliers/suppliers.db",
    "/opt/yvy/backend-lua/data/suppliers/suppliers.db",
}) or "backend-lua/data/suppliers/suppliers.db"

local writable_conn = nil
local read_conn = nil

function _M.db_path()
    return SUPPLIERS_DB_PATH
end

local function ensure_conn()
    if writable_conn then return writable_conn end
    local dir = SUPPLIERS_DB_PATH:match("^(.*)[/\\]")
    if dir then
        os.execute("mkdir -p " .. dir)
    end
    writable_conn = sqlite3.open(SUPPLIERS_DB_PATH)
    if not writable_conn then
        logger.warn("supplier_monitor: failed to open " .. SUPPLIERS_DB_PATH)
        return nil
    end
    writable_conn:exec("PRAGMA journal_mode=WAL")
    writable_conn:exec("PRAGMA synchronous=OFF")
    writable_conn:exec("PRAGMA busy_timeout=60000")
    _M.ensure_schema(writable_conn)
    return writable_conn
end

function _M.ensure_schema(conn)
    conn:exec([[
        CREATE TABLE IF NOT EXISTS suppliers (
            cnpj TEXT PRIMARY KEY,
            nome TEXT,
            cod_imovel TEXT,
            lat REAL,
            lon REAL,
            webhook_url TEXT,
            status TEXT,
            last_score INTEGER,
            last_alert_at TEXT
        );
    ]])
    -- Migração aditiva (common-mistake #5): adiciona as colunas do novo modelo
    -- de score (level/confidence/unknown) se ainda não existirem. Guardado por
    -- PRAGMA table_info para ser idempotente em DBs já migrados.
    local cols = {}
    for row in conn:nrows("PRAGMA table_info(suppliers)") do
        cols[row.name] = true
    end
    local additions = {
        { "last_level", "TEXT" },
        { "last_confidence", "INTEGER" },
        { "last_unknown", "INTEGER" },
    }
    for _, a in ipairs(additions) do
        if not cols[a[1]] then
            conn:exec("ALTER TABLE suppliers ADD COLUMN " .. a[1] .. " " .. a[2])
        end
    end
end

local function read_conn_open()
    if read_conn then return read_conn end
    local f = io.open(SUPPLIERS_DB_PATH, "r")
    if not f then return nil end
    f:close()
    read_conn = sqlite3.open(SUPPLIERS_DB_PATH)
    if not read_conn then return nil end
    read_conn:exec("PRAGMA query_only=ON")
    read_conn:exec("PRAGMA busy_timeout=5000")
    return read_conn
end

-- Lista todos os fornecedores monitorados.
function _M.get_suppliers()
    local conn = read_conn_open()
    if not conn then return {} end
    local out = {}
    for row in conn:nrows("SELECT * FROM suppliers ORDER BY nome") do
        out[#out + 1] = {
            cnpj = row.cnpj,
            nome = row.nome,
            cod_imovel = row.cod_imovel,
            lat = tonumber(row.lat),
            lon = tonumber(row.lon),
            webhook_url = row.webhook_url,
            status = row.status,
            last_score = tonumber(row.last_score),
            last_level = row.last_level,
            last_confidence = tonumber(row.last_confidence),
            last_unknown = tonumber(row.last_unknown),
            last_alert_at = row.last_alert_at,
        }
    end
    return out
end

-- Busca um fornecedor por cnpj.
function _M.get_supplier(cnpj)
    local conn = read_conn_open()
    if not conn then return nil end
    local key = tostring(cnpj or ""):gsub("%D", "")
    if key == "" then return nil end
    local stmt = conn:prepare("SELECT * FROM suppliers WHERE cnpj = ?")
    if not stmt then return nil end
    stmt:bind(1, key)
    local row
    for r in stmt:nrows() do row = r end
    stmt:finalize()
    if not row then return nil end
    return {
        cnpj = row.cnpj,
        nome = row.nome,
        cod_imovel = row.cod_imovel,
        lat = tonumber(row.lat),
        lon = tonumber(row.lon),
        webhook_url = row.webhook_url,
        status = row.status,
        last_score = tonumber(row.last_score),
        last_level = row.last_level,
        last_confidence = tonumber(row.last_confidence),
        last_unknown = tonumber(row.last_unknown),
        last_alert_at = row.last_alert_at,
    }
end

-- Upsert de fornecedor.
function _M.upsert_supplier(row)
    local conn = ensure_conn()
    if not conn then return false end
    local stmt = conn:prepare([[
        INSERT INTO suppliers
            (cnpj, nome, cod_imovel, lat, lon, webhook_url, status, last_score, last_alert_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(cnpj) DO UPDATE SET
            nome=excluded.nome,
            cod_imovel=excluded.cod_imovel,
            lat=excluded.lat,
            lon=excluded.lon,
            webhook_url=excluded.webhook_url,
            status=excluded.status,
            last_score=excluded.last_score,
            last_alert_at=excluded.last_alert_at
    ]])
    if not stmt then return false end
    stmt:bind(1, tostring(row.cnpj or ""):gsub("%D", ""))
    stmt:bind(2, row.nome or "")
    stmt:bind(3, row.cod_imovel or "")
    stmt:bind(4, row.lat or nil)
    stmt:bind(5, row.lon or nil)
    stmt:bind(6, row.webhook_url or "")
    stmt:bind(7, row.status or "ativo")
    stmt:bind(8, row.last_score or nil)
    stmt:bind(9, row.last_alert_at or nil)
    local rc = stmt:step()
    stmt:finalize()
    return rc == sqlite3.DONE
end

-- Atualiza o status/score de um fornecedor após um scan.
function _M.update_status(cnpj, status, last_score, last_alert_at)
    local conn = ensure_conn()
    if not conn then return false end
    local stmt = conn:prepare([[
        UPDATE suppliers SET status=?, last_score=?, last_alert_at=?
        WHERE cnpj=?
    ]])
    if not stmt then return false end
    stmt:bind(1, status or "ativo")
    stmt:bind(2, last_score or nil)
    stmt:bind(3, last_alert_at or nil)
    stmt:bind(4, tostring(cnpj or ""):gsub("%D", ""))
    local rc = stmt:step()
    stmt:finalize()
    return rc == sqlite3.DONE
end

-- Persiste o resultado completo de score de um fornecedor (novo modelo de 3
-- pilares). Grava last_score + last_level + last_confidence + last_unknown +
-- updated_at atomicamente. `score_result` é o retorno de risk_score.score
-- (ou um subset com level/confidence/unknown). Mantém compatibilidade com
-- chamadores legados que passam apenas last_score via update_status.
function _M.record_score(cnpj, score_result)
    local conn = ensure_conn()
    if not conn then return false end
    local stmt = conn:prepare([[
        UPDATE suppliers SET
            last_score=?,
            last_level=?,
            last_confidence=?,
            last_unknown=?,
            last_alert_at=?
        WHERE cnpj=?
    ]])
    if not stmt then return false end
    stmt:bind(1, score_result.score or 0)
    stmt:bind(2, score_result.level or "baixo")
    stmt:bind(3, score_result.confidence or 0)
    stmt:bind(4, score_result.unknown or 0)
    stmt:bind(5, os.date("!%Y-%m-%dT%H:%M:%SZ"))
    stmt:bind(6, tostring(cnpj or ""):gsub("%D", ""))
    local rc = stmt:step()
    stmt:finalize()
    return rc == sqlite3.DONE
end

-- Lista alertas in-app (de Redis `risk:supplier_alerts`).
function _M.get_alerts()
    local raw = redis.get("risk:supplier_alerts")
    if not raw then return {} end
    local ok, data = pcall(cjson.decode, raw)
    if not ok or type(data) ~= "table" then return {} end
    return data
end

-- Grava um alerta in-app (append na lista Redis, cap 100).
function _M.push_alert(alert)
    local alerts = _M.get_alerts()
    alerts[#alerts + 1] = alert
    if #alerts > 100 then
        local trimmed = {}
        for i = #alerts - 99, #alerts do
            trimmed[#trimmed + 1] = alerts[i]
        end
        alerts = trimmed
    end
    redis.set("risk:supplier_alerts", cjson.encode(alerts), 86400)
end

-- Expõe a conexão writable apenas para scripts offline (scan/tests).
function _M._offline_conn()
    return ensure_conn()
end

return _M

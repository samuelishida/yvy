-- app/lookups/risk_precompute.lua — lookup + writer offline do pré-cálculo
-- de risco por-propriedade (plan: risk-intelligence, Inc 2).
--
-- A runtime (routes/risk.lua) lê resultados prontos via `get`. O warm offline
-- (tools/warm_risk_scores.lua) e o batch (tools/run_batch_analysis.lua) são
-- responsáveis por escrever no risk.db; a runtime NUNCA deve escrever na
-- tabela. Por isso `get` abre uma conexão query-only, e as funções de escrita
-- (upsert/bulk_upsert) abrem uma conexão própria writable quando invocadas por
-- processos offline.
--
-- `property_id` é um SURROGATE que reconcilia as três chaves de entrada:
-- `cod_imovel` quando existe, senão `cnpj`, senão `lat:lon` (centroide). A
-- chave é gerada por `risk_score.resolve_property_id` (função pura) para
-- garantir consistência entre batch e monitor.

require("app.env")
local env        = require("app.env")
local sqlite3    = require("lsqlite3")
local cjson      = require("cjson")
local logger     = require("app.logger")
local risk_score = require("app.risk_score")

local _M = {}

local RISK_DB_PATH = env.get("RISK_DB_PATH") or env.first_with_existing_parent({
    "backend-lua/data/risk/risk.db",
    "data/risk/risk.db",
    "../backend-lua/data/risk/risk.db",
    "/opt/yvy/backend-lua/data/risk/risk.db",
}) or "backend-lua/data/risk/risk.db"

local writable_conn = nil
local read_conn = nil

-- Caminho do marker de versão da área efetiva (sibling do area_efetiva.db,
-- NÃO derivado de RISK_DB_PATH, que aponta para risk.db em outro diretório).
local AREA_EFETIVA_MARKER = env.get("AREA_EFETIVA_VERSION_FILE") or env.first_with_existing_parent({
    "backend-lua/data/area_efetiva/area_efetiva.version",
    "data/area_efetiva/area_efetiva.version",
    "../backend-lua/data/area_efetiva/area_efetiva.version",
    "/opt/yvy/backend-lua/data/area_efetiva/area_efetiva.version",
}) or "backend-lua/data/area_efetiva/area_efetiva.version"

function _M.db_path()
    return RISK_DB_PATH
end

-- Lê o conteúdo de um arquivo marker, trimado. Retorna nil se ausente.
local function read_marker(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    if not content then return nil end
    return content:gsub("^%s+", ""):gsub("%s+$", "")
end

-- Hash simples/stable para version_key (mesmo padrão de car_prodes).
local function short_hash(parts)
    local s = table.concat(parts, "|")
    local h = 5381
    for i = 1, #s do
        h = ((h * 33) + s:byte(i)) % 0x100000000
    end
    return string.format("%08x%08x", h, h)
end

-- version_key: invalida quando MapBiomas/PRODES/UC/TI/área efetiva/Sinaflor/
-- protected-overlap muda. Para v1, deriva de env vars (bump manual) + contagem
-- de alertas MapBiomas (se disponível). `AREA_EFETIVA_VERSION` (Inc 3) é
-- gravado pelo compute_area_efetiva.py via marker; um recomputo da área
-- efetiva invalida os scores cacheados que a consomem. O warm/batch passa o
-- version_key atual; `get` compara e retorna nil (stale) quando diverge →
-- recompute.
--
-- A versão da área efetiva vem do marker file (fonte de verdade escrita após
-- sucesso, common-mistake #5), com fallback para a env var. Ler o arquivo
-- direto decoupla do systemd env propagation (que exigiria restart por
-- recomputo).
--
-- Inc 2: o version_key também inclui o hash do DB Sinaflor (mtime do arquivo,
-- pois sinaflor_lookup não expõe version_key) e o version_key do
-- car_protected_overlap. Sem isso, uma atualização de Sinaflor ou do
-- pré-cálculo UC/TI não invalidaria os scores cacheados que os consomem.
function _M.current_version_key()
    local area_efetiva_version = read_marker(AREA_EFETIVA_MARKER)
        or env.get("AREA_EFETIVA_VERSION", "")

    -- Sinaflor: mtime do DB dedicado (fonte de verdade do import offline).
    local sinaflor_version = ""
    local sinaflor_path = env.get("SINAFLOR_DB_PATH")
        or env.first_with_existing_parent({
            "backend-lua/data/sinaflor/sinaflor_auth.db",
            "data/sinaflor/sinaflor_auth.db",
            "../backend-lua/data/sinaflor/sinaflor_auth.db",
            "/opt/yvy/backend-lua/data/sinaflor/sinaflor_auth.db",
        })
    if sinaflor_path then
        local f = io.open(sinaflor_path, "r")
        if f then
            local stat = f:seek("end")
            f:close()
            sinaflor_version = tostring(stat)
        end
    end

    -- car_protected_overlap: version_key do pré-cálculo UC/TI. Guardado em
    -- pcall — em testes sem os dados UC/TI carregados, cai para um valor
    -- estável (não derruba o version_key).
    local protected_version = ""
    pcall(function()
        local car_protected = require("app.lookups.car_protected_overlap")
        protected_version = car_protected.current_version_key() or ""
    end)

    local parts = {
        tostring(env.get("RISK_VERSION", "2")),
        tostring(env.get("PRODES_VERSION", "")),
        tostring(env.get("MAPBIOMAS_VERSION", "")),
        tostring(area_efetiva_version),
        tostring(sinaflor_version),
        tostring(protected_version),
    }
    return short_hash(parts)
end

-- Conexão writable singleton. Usada SOMENTE por scripts offline (warm/batch).
local function ensure_conn()
    if writable_conn then return writable_conn end
    local dir = RISK_DB_PATH:match("^(.*)[/\\]")
    if dir then
        os.execute("mkdir -p " .. dir)
    end
    writable_conn = sqlite3.open(RISK_DB_PATH)
    if not writable_conn then
        logger.warn("risk_precompute: failed to open " .. RISK_DB_PATH)
        return nil
    end
    writable_conn:exec("PRAGMA journal_mode=WAL")
    writable_conn:exec("PRAGMA synchronous=OFF")
    writable_conn:exec("PRAGMA cache_size=-200000")
    writable_conn:exec("PRAGMA temp_store=MEMORY")
    writable_conn:exec("PRAGMA busy_timeout=60000")
    _M.ensure_schema(writable_conn)
    return writable_conn
end

function _M.ensure_schema(conn)
    conn:exec([[
        CREATE TABLE IF NOT EXISTS risk_scores (
            property_id TEXT PRIMARY KEY,
            score INTEGER,
            level TEXT,
            recommendation TEXT,
            factors BLOB,
            version_key TEXT,
            computed_at TEXT
        );
    ]])
    -- Migração aditiva (common-mistake #5): adiciona as colunas de pilares/
    -- confiança/unknown se ainda não existirem. Guardado por PRAGMA table_info
    -- para ser idempotente em DBs já migrados. Pilares são colunas individuais
    -- (não JSON BLOB) para evitar drift de representação dupla.
    local cols = {}
    for row in conn:nrows("PRAGMA table_info(risk_scores)") do
        cols[row.name] = true
    end
    local additions = {
        { "severity", "REAL" },
        { "legality", "REAL" },
        { "evidence", "REAL" },
        { "confidence", "INTEGER" },
        { "coverage", "REAL" },
        { "evidence_gap", "INTEGER" },
        { "unknown", "INTEGER" },
    }
    for _, a in ipairs(additions) do
        if not cols[a[1]] then
            conn:exec("ALTER TABLE risk_scores ADD COLUMN " .. a[1] .. " " .. a[2])
        end
    end
end

-- Conexão read-only (query_only=ON) para a runtime. Abre sob demanda e
-- sobrevive à troca de arquivo (padrão car_lookup).
local function read_conn_open()
    if read_conn then return read_conn end
    local f = io.open(RISK_DB_PATH, "r")
    if not f then return nil end
    f:close()
    read_conn = sqlite3.open(RISK_DB_PATH)
    if not read_conn then return nil end
    read_conn:exec("PRAGMA query_only=ON")
    read_conn:exec("PRAGMA busy_timeout=5000")
    return read_conn
end

-- Lê uma row pré-calculada. Retorna tabela decodificada ou nil se ausente,
-- stale ou corrompido.
function _M.get(property_id)
    local conn = read_conn_open()
    if not conn then return nil end
    local key = tostring(property_id or ""):upper()
    if key == "" then return nil end

    local stmt = conn:prepare([[
        SELECT property_id, score, level, recommendation, factors,
               severity, legality, evidence, confidence, coverage,
               evidence_gap, unknown,
               version_key, computed_at
        FROM risk_scores WHERE property_id = ?
    ]])
    if not stmt then return nil end
    stmt:bind(1, key)
    local row
    for r in stmt:nrows() do row = r end
    stmt:finalize()
    if not row then return nil end

    local current_version = _M.current_version_key()
    if row.version_key ~= current_version then
        return nil
    end

    local ok, factors = pcall(cjson.decode, row.factors or "[]")
    if not ok or type(factors) ~= "table" then factors = {} end

    return {
        property_id = row.property_id,
        score = tonumber(row.score) or 0,
        level = row.level,
        recommendation = row.recommendation,
        factors = factors,
        pillars = {
            severity = tonumber(row.severity) or 0,
            legality = tonumber(row.legality) or 0,
            evidence = tonumber(row.evidence) or 0,
        },
        confidence = tonumber(row.confidence) or 0,
        coverage = tonumber(row.coverage) or 0,
        evidence_gap = tonumber(row.evidence_gap) or 0,
        unknown = tonumber(row.unknown) or 0,
        version_key = row.version_key,
        computed_at = row.computed_at,
    }
end

-- Upsert unitário. Não usado na rota runtime; mantido para testes e helpers.
function _M.upsert(property_id, result)
    local conn = ensure_conn()
    if not conn then return false end

    local factors_json, ok
    ok, factors_json = pcall(cjson.encode, result.factors or {})
    if not ok then factors_json = "[]" end

    local stmt = conn:prepare([[
        INSERT INTO risk_scores
            (property_id, score, level, recommendation, factors,
             severity, legality, evidence, confidence, coverage,
             evidence_gap, unknown,
             version_key, computed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(property_id) DO UPDATE SET
            score=excluded.score,
            level=excluded.level,
            recommendation=excluded.recommendation,
            factors=excluded.factors,
            severity=excluded.severity,
            legality=excluded.legality,
            evidence=excluded.evidence,
            confidence=excluded.confidence,
            coverage=excluded.coverage,
            evidence_gap=excluded.evidence_gap,
            unknown=excluded.unknown,
            version_key=excluded.version_key,
            computed_at=excluded.computed_at
    ]])
    if not stmt then return false end
    stmt:bind(1, tostring(property_id or ""):upper())
    stmt:bind(2, result.score or 0)
    stmt:bind(3, result.level or "baixo")
    stmt:bind(4, result.recommendation or "")
    stmt:bind(5, factors_json)
    stmt:bind(6, (result.pillars and result.pillars.severity) or 0)
    stmt:bind(7, (result.pillars and result.pillars.legality) or 0)
    stmt:bind(8, (result.pillars and result.pillars.evidence) or 0)
    stmt:bind(9, result.confidence or 0)
    stmt:bind(10, result.coverage or 0)
    stmt:bind(11, result.evidence_gap or 0)
    stmt:bind(12, result.unknown or 0)
    stmt:bind(13, result.version_key or _M.current_version_key())
    stmt:bind(14, result.computed_at or os.date("!%Y-%m-%dT%H:%M:%SZ"))
    local rc = stmt:step()
    stmt:finalize()
    return rc == sqlite3.DONE
end

-- Bulk UPSERT em transação. Usado exclusivamente pelo warm/batch offline.
function _M.bulk_upsert(rows)
    if not rows or #rows == 0 then return 0 end
    local conn = ensure_conn()
    if not conn then return 0 end

    local stmt = conn:prepare([[
        INSERT INTO risk_scores
            (property_id, score, level, recommendation, factors,
             severity, legality, evidence, confidence, coverage,
             evidence_gap, unknown,
             version_key, computed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(property_id) DO UPDATE SET
            score=excluded.score,
            level=excluded.level,
            recommendation=excluded.recommendation,
            factors=excluded.factors,
            severity=excluded.severity,
            legality=excluded.legality,
            evidence=excluded.evidence,
            confidence=excluded.confidence,
            coverage=excluded.coverage,
            evidence_gap=excluded.evidence_gap,
            unknown=excluded.unknown,
            version_key=excluded.version_key,
            computed_at=excluded.computed_at
    ]])
    if not stmt then return 0 end

    conn:exec("BEGIN")
    local n = 0
    local ok, err = pcall(function()
        for _, r in ipairs(rows) do
            local factors_json, enc_ok
            enc_ok, factors_json = pcall(cjson.encode, r.factors or {})
            if not enc_ok then factors_json = "[]" end

            stmt:reset()
            stmt:bind(1, tostring(r.property_id or ""):upper())
            stmt:bind(2, tonumber(r.score) or 0)
            stmt:bind(3, r.level or "baixo")
            stmt:bind(4, r.recommendation or "")
            stmt:bind(5, factors_json)
            stmt:bind(6, (r.pillars and r.pillars.severity) or 0)
            stmt:bind(7, (r.pillars and r.pillars.legality) or 0)
            stmt:bind(8, (r.pillars and r.pillars.evidence) or 0)
            stmt:bind(9, r.confidence or 0)
            stmt:bind(10, r.coverage or 0)
            stmt:bind(11, r.evidence_gap or 0)
            stmt:bind(12, r.unknown or 0)
            stmt:bind(13, r.version_key or _M.current_version_key())
            stmt:bind(14, r.computed_at or os.date("!%Y-%m-%dT%H:%M:%SZ"))
            local rc = stmt:step()
            if rc == sqlite3.DONE then
                n = n + 1
            else
                logger.warn("risk_precompute bulk_upsert step failed: " .. tostring(conn:errmsg()))
            end
        end
    end)
    stmt:finalize()
    if not ok then
        pcall(function() conn:exec("ROLLBACK") end)
        logger.warn("risk_precompute bulk_upsert aborted: " .. tostring(err))
        return n
    end
    conn:exec("COMMIT")
    return n
end

-- Expõe a conexão writable apenas para scripts offline (warm/batch/tests).
function _M._offline_conn()
    return ensure_conn()
end

return _M

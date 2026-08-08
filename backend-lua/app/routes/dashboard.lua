-- app/routes/dashboard.lua — agregados do dashboard (plan: dashboard-enhancement)
--
-- /api/dashboard/summary   — KPIs (fogo, natureza, DETER, PRODES) com comparação
--                            período-a-período numa única request
-- /api/dashboard/freshness — (Inc 8) ingestão por fonte + cobertura de atributos

require("app.env")
local auth          = require("app.middleware.auth")
local rl            = require("app.middleware.rate_limit")
local redis         = require("app.redis")
local db            = require("app.db")
local cjson         = require("cjson")
local logger        = require("app.logger")
local utils         = require("app.utils")
local state_lookup  = require("app.lookups.state_lookup")

local _M = {}

local function valid_state(state)
    if not state or state == "" then return true end
    for _, uf in ipairs(state_lookup.list_ufs()) do
        if uf.sigla == state then return true end
    end
    return false
end

-- Variação % arredondada a 1 casa; nil quando não há base de comparação
-- (previous = 0) — nunca "+∞%" nem divisão por zero.
local function delta_pct(current, previous)
    if not previous or previous == 0 or current == nil then return nil end
    return math.floor((current - previous) / previous * 1000 + 0.5) / 10
end

-- KPI: par current/previous + delta + complete. `complete` é falso quando uma
-- das janelas tem cobertura curta — tolerância de 3 dias ausentes (uma data
-- de ingestão faltando não invalida o delta; ingestão claramente quebrada
-- sim). O delta não é confiável com ingestão parcial.
local function kpi(current, previous, days, covered)
    local need = days - 3
    return {
        current = current,
        previous = previous,
        delta_pct = delta_pct(current, previous),
        complete = covered.current >= need and covered.previous >= need,
    }
end

function _M.get_summary(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local args = ctx.req.args or {}
    local days = tonumber(args.days) or 30
    if days < 1 or days > 365 then
        ctx:json(400, {error = "invalid days"})
        return
    end
    local state = (type(args.state) == "string" and args.state ~= "") and args.state:upper() or nil
    if state and not valid_state(state) then
        ctx:json(400, {error = "invalid state"})
        return
    end

    local cache_key = "dashboard:summary:" .. days .. ":" .. (state or "all")
    local cached = redis.get(cache_key)
    if cached then
        ctx:set_header("Cache-Control", "public, max-age=120")
        ctx:send(200, cached)
        return
    end

    local kpis = db.get_dashboard_kpis(days, state)
    local covered = db.count_distinct_fire_days(days, state)

    -- DETER: janela atual vs anterior. Tabelas vazias (dev / ingestão ainda
    -- não rodou) → available=false, nunca 0 como se fosse dado real.
    local deter_cur = db.get_deter_total_window(days, 0)
    local deter_prev = db.get_deter_total_window(days, days)
    local deter_available = deter_cur > 0 or deter_prev > 0

    -- PRODES: último ano disponível (leitor memoizado em deforestation_stats).
    local ds = require("app.routes.deforestation_stats")
    local prodes_latest = ds.get_latest_prodes()

    local classes = {"crime", "suspeito", "permitido", "natural", "unclassified"}
    local kpis_out = {}
    for _, c in ipairs(classes) do
        kpis_out[c] = kpi(kpis[c].current, kpis[c].previous, days, covered)
    end
    kpis_out.fires = kpi(kpis.fires.current, kpis.fires.previous, days, covered)
    kpis_out.deter_km2 = {
        current = deter_available and deter_cur or nil,
        previous = deter_available and deter_prev or nil,
        delta_pct = deter_available and delta_pct(deter_cur, deter_prev) or nil,
        available = deter_available,
    }
    kpis_out.prodes_latest = prodes_latest

    local body = cjson.encode({
        days = days,
        state = state,
        generated_at = utils.now_iso(),
        kpis = kpis_out,
        sources = {
            { id = "firms", available = true },
            { id = "deter", available = deter_available },
        },
    })
    redis.set(cache_key, body, 120)
    ctx:set_header("Cache-Control", "public, max-age=120")
    ctx:send(200, body)
end

-- ── GET /api/dashboard/freshness (plan: dashboard-enhancement, Inc 8) ─────

-- Ingestão por fonte + cobertura de atributos. Nunca 500a: uma fonte que falha
-- degrada para available=false apenas para ela.
function _M.get_freshness(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local cache_key = "dashboard:freshness"
    local cached = redis.get(cache_key)
    if cached then
        ctx:set_header("Cache-Control", "public, max-age=300")
        ctx:send(200, cached)
        return
    end

    local ok, freshness = pcall(db.get_ingest_freshness)
    if not ok then freshness = {} end

    local sources = {}
    for _, id in ipairs({"firms", "news", "deter", "deter_car"}) do
        local f = freshness[id] or {}
        sources[#sources + 1] = {
            id = id,
            rows = tonumber(f.rows) or 0,
            last_ingested_at = f.last_ingested_at or nil,
            available = tonumber(f.rows or 0) > 0,
        }
    end

    local state_cov = db.count_fires_by_state_present()
    local biome_cov = db.count_fires_by_biome_present()
    local nature_cov = db.count_fires_by_nature_present()

    local function frac(attributed, total)
        if not total or total == 0 then return 0 end
        return math.floor(attributed / total * 1000 + 0.5) / 1000
    end

    local body = cjson.encode({
        generated_at = utils.now_iso(),
        sources = sources,
        coverage = {
            state_pct = frac(state_cov.total - state_cov.unattributed - state_cov.sentinel_empty, state_cov.total),
            biome_pct = frac(biome_cov.total - biome_cov.unattributed, biome_cov.total),
            nature_pct = frac(nature_cov.total - nature_cov.unclassified, nature_cov.total),
        },
    })
    redis.set(cache_key, body, 300)
    ctx:set_header("Cache-Control", "public, max-age=300")
    ctx:send(200, body)
end

return _M

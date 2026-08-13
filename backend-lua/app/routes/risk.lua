-- risk.lua — Risk Intelligence routes (plan: risk-intelligence).
--
-- Handlers:
--   POST /api/risk/batch          — upload CSV raw de fornecedores → dispara job
--   GET  /api/risk/batch?id=<id>  — progresso + resultados do lote
--   GET  /api/risk/report?id=<id> — PDF do laudo de uma propriedade (Inc 4)
--   POST /api/risk/supplier       — cadastra fornecedor monitorado (Inc 6)
--   GET  /api/risk/suppliers      — lista fornecedores monitorados (Inc 6)
--   GET  /api/risk/supplier-alerts— alertas in-app de monitoramento (Inc 6)
--
-- O upload é CSV raw (Content-Type: text/csv), não multipart: o body já é
-- string raw em ctx.req.body e passa direto ao utils.parse_csv. O POST dispara
-- tools/run_batch_analysis.lua via nohup + lock Redis e retorna o batch_id
-- cedo (sem esperar o filho terminar).

require("app.env")
local auth       = require("app.middleware.auth")
local rl         = require("app.middleware.rate_limit")
local redis      = require("app.redis")
local utils      = require("app.utils")
local cjson      = require("cjson")
local logger     = require("app.logger")
local risk_score = require("app.risk_score")
local risk_precompute = require("app.lookups.risk_precompute")
local supplier_monitor = require("app.lookups.supplier_monitor")
local car_lookup = require("app.lookups.car_lookup")
local mapbiomas  = require("app.lookups.mapbiomas_lookup")
local area_efetiva = require("app.lookups.area_efetiva_lookup")
local embargo    = require("app.lookups.embargo_lookup")
local car_protected = require("app.lookups.car_protected_overlap")
local sinaflor   = require("app.lookups.sinaflor_lookup")

local _M = {}

-- Gera um batch_id curto e único.
local function new_batch_id()
    return "b" .. os.time() .. "_" .. tostring(math.random(100000, 999999))
end

-- Spawna o subprocesso destacado do lote. Fecha/redireciona o fd do socket
-- herdado do cliente (gotcha do proxy C) para o POST retornar cedo.
local function spawn_batch(batch_id, csv_path)
    local source = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    local backend_dir = source:match("^(.*[/\\])app[/\\]routes[/\\]") or ""
    local script = backend_dir .. "tools/run_batch_analysis.lua"

    local cmd
    if package.config:sub(1, 1) == "\\" then
        cmd = 'start /b lua5.1.exe "' .. script .. '" "' .. batch_id .. '" "' .. csv_path .. '" >NUL 2>NUL'
    else
        cmd = 'nohup lua5.1 "' .. script .. '" "' .. batch_id .. '" "' .. csv_path .. '" >/dev/null 2>&1 &'
    end

    local ok, err = pcall(os.execute, cmd)
    if not ok then
        logger.warn("Failed to spawn batch analysis: " .. tostring(err))
        return false
    end
    return true
end

-- POST /api/risk/batch — aceita CSV raw, dispara job assíncrono.
function _M.post_batch(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local body = ctx.req.body or ""
    if body == "" then
        ctx:error(400, "empty CSV body")
        return
    end

    local rows = utils.parse_csv(body)
    if #rows == 0 then
        ctx:error(400, "CSV has no data rows")
        return
    end

    -- Validação mínima: cada linha precisa de ao menos um identificador.
    for i, row in ipairs(rows) do
        local pid = risk_score.resolve_property_id({
            cod_imovel = row.cod_imovel,
            cnpj = row.cnpj,
            lat = tonumber(row.lat),
            lon = tonumber(row.lon),
        })
        if pid == "" then
            ctx:error(400, "row " .. i .. " has no identifier (need cod_imovel, cnpj, or lat/lon)")
            return
        end
    end

    -- Grava o CSV em arquivo temporário para o subprocesso ler.
    local batch_id = new_batch_id()
    local tmp_dir = os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
    local csv_path = tmp_dir .. "/yvy_risk_batch_" .. batch_id .. ".csv"
    local f, err = io.open(csv_path, "w")
    if not f then
        ctx:error(500, "failed to stage CSV: " .. tostring(err))
        return
    end
    f:write(body)
    f:close()

    -- Lock de dedup: um batch por vez por batch_id (o id é único, mas o lock
    -- evita re-spawn acidental do mesmo id). Grava JSON válido (não string
    -- pura) para o get_batch conseguir decodificar antes do subprocesso
    -- gravar o progresso real.
    redis.setnx("risk:batch:" .. batch_id,
        cjson.encode({ status = "running", total = #rows, processed = 0 }), 3600)

    if not spawn_batch(batch_id, csv_path) then
        ctx:error(500, "failed to start batch job")
        return
    end

    ctx:json(202, { batch_id = batch_id, status = "running", total = #rows, processed = 0 })
end

-- GET /api/risk/batch?id=<id> — progresso + resultados.
function _M.get_batch(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local batch_id = ctx.req.args.id
    if not batch_id or batch_id == "" then
        ctx:error(400, "missing id")
        return
    end

    local raw = redis.get("risk:batch:" .. batch_id)
    if not raw then
        ctx:error(404, "batch not found")
        return
    end

    local ok, data = pcall(cjson.decode, raw)
    if not ok or type(data) ~= "table" then
        ctx:error(500, "corrupt batch state")
        return
    end
    ctx:json(200, data)
end

-- GET /api/risk/report?id=<property_id> — PDF do laudo (Inc 4).
--
-- Monta um JSON de contexto enriquecido (identificação, eventos,
-- sobreposições, histórico, evidências, geometrias para o mapa P5) e passa ao
-- renderer Python. Todos os lookups são em memória/índice (query_only=ON,
-- memo 60s) — sem cruzamento espacial denso, o loop copas não é bloqueado.
-- O PDF pesado roda no subprocesso Python destacado.

-- Resolve o cod_imovel a partir do property_id (surrogate: cod_imovel | cnpj
-- | lat:lon). Se property_id for cod_imovel, usa direto; se for cnpj/lat:lon,
-- tenta car_lookup.get_by_cod_imovel/classify_point. Retorna nil se não
-- resolver (as seções espaciais ficam vazias com nota).
local function resolve_cod_imovel(property_id)
    local pid = tostring(property_id or ""):upper()
    if pid == "" then return nil end
    -- property_id é cod_imovel (formato SICAR: UF-XXXXXXX-...).
    if pid:match("^%u%u%-%d") then
        return pid
    end
    -- cnpj (14 dígitos) ou lat:lon — tenta resolver via car_lookup.
    local lat, lon = pid:match("^([%-%d%.]+):([%-%d%.]+)$")
    if lat and lon then
        local car = car_lookup.classify_point(tonumber(lon), tonumber(lat))
        if car and car.id then
            return tostring(car.id):upper()
        end
        return nil
    end
    -- cnpj: sem mapeamento direto para CAR — retorna nil (seções vazias).
    return nil
end

-- Monta o context.json enriquecido do laudo. Nunca falha o laudo inteiro: um
-- lookup indisponível → seção omitida com nota.
local function build_report_context(property_id)
    local context = {
        property_id = property_id,
        property = nil,
        score = nil,
        factors = {},
        alerts = {},
        area_efetiva = {},
        embargoes = {},
        protected = {},
        sinaflor = {},
        history = {},
        geometries = { property_geom = nil, alert_geoms = {} },
        notes = {},
    }

    -- 1. resolve cod_imovel a partir de property_id.
    local cod = resolve_cod_imovel(property_id)
    if not cod then
        context.notes[#context.notes + 1] =
            "property_id não é um CAR — seções cadastrais/espaciais vazias"
        return context
    end

    -- 2. car_lookup.get_by_cod_imovel → property geom (GeoJSON) + área.
    car_lookup.load_car()
    local prop = car_lookup.get_by_cod_imovel(cod)
    if prop then
        context.property = {
            cod_imovel = prop.id,
            uf = prop.uf,
            municipio = prop.municipio,
            area_ha = prop.area_ha,
        }
        context.geometries.property_geom = prop.geom
    end

    -- 3. mapbiomas_lookup.get_alerts_by_car → alerts[] (com geom p/ mapa P5).
    mapbiomas.load_mapbiomas()
    local alerts = mapbiomas.get_alerts_by_car(cod, true)
    context.alerts = alerts
    for _, a in ipairs(alerts) do
        if a.geom then
            context.geometries.alert_geoms[#context.geometries.alert_geoms + 1] = a.geom
        end
    end

    -- 4. area_efetiva_lookup.get_by_car → area_efetiva[].
    area_efetiva.load_area_efetiva()
    context.area_efetiva = area_efetiva.get_by_car(cod)

    -- 5. embargo_lookup.get_by_car → embargoes[].
    embargo.load_embargo()
    context.embargoes = embargo.get_by_car(cod)

    -- 6. car_protected_overlap.get → protected[] (UC/TI).
    local prot = car_protected.get(cod)
    if prot then
        context.protected = prot.overlaps
    end

    -- 7. sinaflor_lookup → sinaflor[] (ASV/AUTESP). O lookup é por
    -- car_prop {id, name, uf}; usamos authorized com data atual para listar
    -- autorizações vigentes.
    sinaflor.load_sinaflor()
    local auth = sinaflor.authorized({ id = cod }, os.date("!%Y-%m-%d"))
    if auth then
        context.sinaflor[#context.sinaflor + 1] = auth
    end

    -- 8. risk_precompute.get → score, level, recommendation, factors.
    local score = risk_precompute.get(property_id)
    if score then
        context.score = {
            score = score.score,
            level = score.level,
            recommendation = score.recommendation,
            computed_at = score.computed_at,
        }
        context.factors = score.factors
    end

    -- 9. history[] — snapshots históricos se disponíveis (v1: vazio).
    return context
end

-- Gera um report_id curto e único (espelha new_batch_id).
local function new_report_id()
    return "r" .. os.time() .. "_" .. tostring(math.random(100000, 999999))
end

-- Valida um report_id estrito (r<time>_<rand>). Rejeita qualquer coisa que
-- não case — evita path/header injection via o id.
local function valid_report_id(id)
    return type(id) == "string" and id:match("^r%d+_%d+$") ~= nil
end

-- Resolve o python do venv (reportlab/matplotlib vivem só lá), com fallback
-- para python3. Espelha check_prodes_update.sh/deter_daily.sh.
local function venv_python(project_dir)
    local venv = project_dir .. ".venv/bin/python3"
    local f = io.open(venv, "r")
    if f then
        f:close()
        return venv
    end
    return "python3"
end

-- Spawna o renderer Python destacado (nohup ... &) — o loop copas não pode
-- ser bloqueado por os.execute síncrono. O renderer escreve o PDF + um marker
-- sidecar .done/.fail; o status endpoint lê o marker para flipar o estado.
-- Exposto como _M.spawn_report para o teste injetar um mock (sem subprocesso).
function _M.spawn_report(property_id, context_json)
    local source = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    local backend_dir = source:match("^(.*[/\\])app[/\\]routes[/\\]") or ""
    local project_dir = backend_dir:gsub("backend%-lua[/\\]$", "")
    local script = project_dir .. "scripts/data/render_risk_report.py"
    local python = venv_python(project_dir)

    local report_id = new_report_id()
    local tmp_in = "/tmp/yvy_risk_report_" .. report_id .. ".json"
    local tmp_out = "/tmp/yvy_risk_report_" .. report_id .. ".pdf"
    local log = "/tmp/yvy_risk_report_" .. report_id .. ".log"

    local inf, err = io.open(tmp_in, "w")
    if not inf then
        logger.warn("Failed to stage report input: " .. tostring(err))
        return nil
    end
    inf:write(context_json)
    inf:close()

    local cmd = 'nohup "' .. python .. '" "' .. script .. '" "' .. tmp_in
        .. '" "' .. tmp_out .. '" >"' .. log .. '" 2>&1 &'
    local ok, oerr = pcall(os.execute, cmd)
    if not ok then
        logger.warn("Failed to spawn report renderer: " .. tostring(oerr))
        os.remove(tmp_in)
        return nil
    end

    -- Registra o estado running no Redis (TTL 300s). O marker sidecar é a
    -- fonte de verdade de conclusão; o Redis é só o estado transitório.
    redis.set("risk:report:" .. report_id, "running", 300)
    return report_id
end

-- GET /api/risk/report?id=<property_id> — dispara o render assíncrono (202).
function _M.get_report(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local property_id = ctx.req.args.id
    if not property_id or property_id == "" then
        ctx:error(400, "missing id")
        return
    end

    local score = risk_precompute.get(property_id)
    if not score then
        ctx:error(404, "score not found for property")
        return
    end

    -- Monta o contexto enriquecido e passa ao renderer.
    local context = build_report_context(property_id)
    context.score = context.score or {
        score = score.score,
        level = score.level,
        recommendation = score.recommendation,
        computed_at = score.computed_at,
    }
    if #context.factors == 0 then
        context.factors = score.factors
    end

    local report_id = _M.spawn_report(property_id, cjson.encode(context))
    if not report_id then
        ctx:error(500, "failed to start report render")
        return
    end

    ctx:json(202, { report_id = report_id, status = "running" })
end

-- GET /api/risk/report/status?id=<report_id> — running/ready/failed.
function _M.get_report_status(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local report_id = ctx.req.args.id
    if not report_id or report_id == "" then
        ctx:error(400, "missing id")
        return
    end
    if not valid_report_id(report_id) then
        ctx:error(404, "unknown report")
        return
    end

    local state = redis.get("risk:report:" .. report_id)
    local done = io.open("/tmp/yvy_risk_report_" .. report_id .. ".done", "r")
    local fail = io.open("/tmp/yvy_risk_report_" .. report_id .. ".fail", "r")

    -- Marker sidecar é a fonte de verdade de conclusão: se o renderer
    -- terminou, flipa o estado Redis e reporta.
    if done then
        done:close()
        redis.set("risk:report:" .. report_id, "ready", 300)
        ctx:json(200, {
            status = "ready",
            url = "/api/risk/report/download?id=" .. report_id,
        })
        return
    end
    if fail then
        fail:close()
        redis.set("risk:report:" .. report_id, "failed", 300)
        ctx:json(200, { status = "failed", url = nil })
        return
    end

    if state == "ready" then
        ctx:json(200, {
            status = "ready",
            url = "/api/risk/report/download?id=" .. report_id,
        })
        return
    end
    if state == "failed" then
        ctx:json(200, { status = "failed", url = nil })
        return
    end

    -- running (ou estado desconhecido/vencido) → ainda processando.
    ctx:json(200, { status = "running", url = nil })
end

-- GET /api/risk/report/download?id=<report_id> — serve o PDF pronto.
function _M.get_report_download(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local report_id = ctx.req.args.id
    if not report_id or report_id == "" then
        ctx:error(400, "missing id")
        return
    end
    if not valid_report_id(report_id) then
        ctx:error(404, "unknown report")
        return
    end

    local pdf_path = "/tmp/yvy_risk_report_" .. report_id .. ".pdf"
    local outf = io.open(pdf_path, "rb")
    if not outf then
        ctx:error(404, "report not ready")
        return
    end
    local pdf = outf:read("*a")
    outf:close()

    -- Filename sanitizado: report_id já é estrito (r<time>_<rand>), sem
    -- caracteres de header injection.
    ctx:set_header("Content-Disposition",
        'attachment; filename="yvy_risk_report_' .. report_id .. '.pdf"')
    ctx:send(200, pdf, "application/pdf")
end

-- POST /api/risk/supplier — cadastra fornecedor monitorado (Inc 6).
function _M.post_supplier(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local body = ctx.req.body or ""
    local ok, data = pcall(cjson.decode, body)
    if not ok or type(data) ~= "table" then
        ctx:error(400, "invalid JSON body")
        return
    end

    local cnpj = tostring(data.cnpj or ""):gsub("%D", "")
    if cnpj == "" then
        ctx:error(400, "missing cnpj")
        return
    end

    local ok2 = supplier_monitor.upsert_supplier({
        cnpj = cnpj,
        nome = data.nome,
        cod_imovel = data.cod_imovel,
        lat = tonumber(data.lat),
        lon = tonumber(data.lon),
        webhook_url = data.webhook_url,
    })
    if not ok2 then
        ctx:error(500, "failed to save supplier")
        return
    end
    ctx:json(200, { cnpj = cnpj, status = "saved" })
end

-- GET /api/risk/suppliers — lista fornecedores monitorados (Inc 6).
function _M.get_suppliers(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local suppliers = supplier_monitor.get_suppliers()
    ctx:json(200, { suppliers = suppliers })
end

-- GET /api/risk/supplier-alerts — alertas in-app de monitoramento (Inc 6).
function _M.get_supplier_alerts(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local alerts = supplier_monitor.get_alerts()
    ctx:json(200, { alerts = alerts })
end

return _M

-- tools/scan_supplier_alerts.lua — subprocess destacado que cruza alertas
-- MapBiomas recentes com fornecedores monitorados e dispara webhook + alerta
-- in-app.
--
-- WHY: o backend é um loop copas single-threaded. O cruzamento de alertas
-- recentes × fornecedores é CPU-heavy e bloquearia o loop se rodasse inline.
-- Este script roda destacado (nohup ... & ou via systemd timer) e grava alertas
-- em Redis `risk:supplier_alert:<cnpj>` (TTL) + `risk:supplier_alerts` (in-app).
--
-- Usage: lua5.1 tools/scan_supplier_alerts.lua [days]
--   days = janela de alertas recentes (default 30)
--
-- Require-ável para testes (padrão deter_protected_alerts.lua): exports
-- check_supplier e run_scan; quando carregado como módulo (busted), NÃO executa
-- o scan no load.

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local backend_dir = script_dir:gsub("[\\/]tools[\\/]$", "/")
package.path = backend_dir .. "?.lua;" .. backend_dir .. "?/init.lua;" .. package.path

local env = require("app.env")
env.load_dotenv(backend_dir .. "../.env")
env.load_dotenv(backend_dir .. ".env")

local cjson = require("cjson")
local logger = require("app.logger")
local redis = require("app.redis")
local http_client = require("app.http_client")
local mapbiomas = require("app.lookups.mapbiomas_lookup")
local embargo = require("app.lookups.embargo_lookup")
local area_efetiva = require("app.lookups.area_efetiva_lookup")
local supplier_monitor = require("app.lookups.supplier_monitor")

local _M = {}
-- Testes setam _skip_redis_invalidation=true para não varrer o namespace
-- risk:* do Redis compartilhado (common-mistake §2).
_M._skip_redis_invalidation = false

-- Verifica se um fornecedor tem alerta recente. Retorna o alerta ou nil.
-- Um fornecedor sem cod_imovel/coordenadas é monitorado por bbox/centroide.
-- O fator `embargo` é alimentado via embargo_lookup (Inc 2) — antes era nil.
-- O fator `deforestation` usa `area_efetiva_ha` (Inc 3) quando disponível.
function _M.check_supplier(supplier, recent_alerts)
    if not supplier then return nil end
    local cod = tostring(supplier.cod_imovel or ""):upper()
    local lat = tonumber(supplier.lat)
    local lon = tonumber(supplier.lon)

    -- Embargo ativo → fator 1 (0..1). DB ausente → nil (fator neutro).
    if cod ~= "" and embargo.has_active_embargo(cod) then
        supplier.embargo = 1
    end
    -- Área efetiva (soma das áreas dos alertas dentro do imóvel). DB ausente
    -- → nil (fallback para recent_alerts no score).
    if cod ~= "" then
        local sum = area_efetiva.sum_by_car(cod)
        if sum > 0 then
            supplier.area_efetiva_ha = sum
        end
    end

    for _, a in ipairs(recent_alerts) do
        -- Match por cod_imovel (quando o fornecedor tem CAR).
        if cod ~= "" and tostring(a.cod_imovel or ""):upper() == cod then
            return a
        end
        -- Match espacial por bbox/centroide (quando o fornecedor tem coords).
        if lat and lon and a.lat and a.lon then
            local dlat = math.abs(a.lat - lat)
            local dlon = math.abs(a.lon - lon)
            -- ~0.5° (~55km) de raio de tolerância.
            if dlat <= 0.5 and dlon <= 0.5 then
                return a
            end
        end
    end
    return nil
end

-- Dispara o webhook do fornecedor (retry simples + log). Nunca aborta o scan.
local function fire_webhook(supplier, alert)
    local url = supplier.webhook_url
    if not url or url == "" then
        return false
    end
    local payload = cjson.encode({
        event = "supplier_alert",
        cnpj = supplier.cnpj,
        nome = supplier.nome,
        alert_code = alert.alert_code,
        area_ha = alert.area_ha,
        biome = alert.biome,
        state = alert.state,
        data_deteccao = alert.data_deteccao,
    })
    local ok, resp = pcall(http_client.post, url, {
        body = payload,
        headers = { ["Content-Type"] = "application/json" },
    })
    if not ok then
        logger.warn("scan_supplier_alerts: webhook failed for " .. supplier.cnpj
                    .. ": " .. tostring(resp))
        return false
    end
    return true
end

-- Roda o scan completo: cruza alertas recentes × fornecedores, grava alertas
-- e dispara webhooks.
function _M.run_scan(days)
    days = tonumber(days) or 30
    local lock_key = "risk:monitor:lock"
    if not _M._skip_redis_invalidation then
        if not redis.setnx(lock_key, os.time(), 3600) then
            logger.info("scan_supplier_alerts: lock held — skipping")
            return 0
        end
    end

    mapbiomas.load_mapbiomas()
    embargo.load_embargo()
    area_efetiva.load_area_efetiva()
    local recent = mapbiomas.get_recent_alerts(days)
    local suppliers = supplier_monitor.get_suppliers()

    local alerted = 0
    for _, s in ipairs(suppliers) do
        local alert = _M.check_supplier(s, recent)
        if alert then
            local alert_key = "risk:supplier_alert:" .. s.cnpj
            redis.set(alert_key, cjson.encode(alert), 86400)
            supplier_monitor.push_alert({
                cnpj = s.cnpj,
                nome = s.nome,
                alert_code = alert.alert_code,
                area_ha = alert.area_ha,
                biome = alert.biome,
                state = alert.state,
                data_deteccao = alert.data_deteccao,
                at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            })
            supplier_monitor.update_status(s.cnpj, "alerta", nil,
                os.date("!%Y-%m-%dT%H:%M:%SZ"))
            fire_webhook(s, alert)
            alerted = alerted + 1
        end
    end

    if not _M._skip_redis_invalidation then
        redis.set("risk:monitor:last_run", os.date("!%Y-%m-%dT%H:%M:%SZ"), 86400)
        redis.delete(lock_key)
    end
    logger.info("scan_supplier_alerts: " .. alerted .. " suppliers alerted")
    return alerted
end

if arg and arg[0] and arg[0]:match("scan_supplier_alerts%.lua$") then
    local days = tonumber(arg[1]) or 30
    local n = _M.run_scan(days)
    os.exit(n >= 0 and 0 or 1)
end

return _M

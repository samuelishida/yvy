-- app/routes/deter.lua — DETER alerts (plan: terrabrasilis-integration, Inc 2/3)
--
-- /api/deter/polygons    — polígonos DETER num bbox (janela de ~90 dias)
-- /api/deter/stats       — agregados (total, por classe/UF/dia/município)
-- /api/deter/car-alerts  — (Inc 3) alertas DETER por propriedade CAR

require("app.env")
local auth = require("app.middleware.auth")
local rl   = require("app.middleware.rate_limit")
local cjson = require("cjson")

local _M = {}

local function parse_bbox(args)
    local sw_lat = tonumber(args.sw_lat)
    local ne_lat = tonumber(args.ne_lat)
    local sw_lng = tonumber(args.sw_lng)
    local ne_lng = tonumber(args.ne_lng)
    if not (sw_lat and ne_lat and sw_lng and ne_lng) then
        return nil, "Missing bbox (sw_lat, ne_lat, sw_lng, ne_lng)"
    end
    if sw_lat > ne_lat or sw_lng > ne_lng then
        return nil, "Invalid bbox (sw must be <= ne)"
    end
    return { sw_lat = sw_lat, ne_lat = ne_lat, sw_lng = sw_lng, ne_lng = ne_lng }
end

function _M.get_polygons(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local bbox, err = parse_bbox(ctx.req.args)
    if not bbox then
        ctx:error(400, err)
        return
    end

    local days = tonumber(ctx.req.args.days) or 7
    if days < 1 then days = 1 end
    if days > 120 then days = 120 end  -- retenção de polígonos (~90 dias, R2)
    local limit = tonumber(ctx.req.args.limit) or 500
    if limit > 5000 then limit = 5000 end

    local db = require("app.db")
    local polygons = db.get_deter_polygons(bbox.sw_lat, bbox.ne_lat, bbox.sw_lng, bbox.ne_lng, days, limit)
    ctx:json(200, { count = #polygons, polygons = polygons })
end

function _M.get_stats(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local days = tonumber(ctx.req.args.days) or 30
    if days < 1 then days = 1 end
    if days > 3650 then days = 3650 end

    local db = require("app.db")
    ctx:json(200, db.get_deter_stats(days))
end

function _M.get_car_alerts(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local args = ctx.req.args
    local days = tonumber(args.days) or 7
    if days < 1 then days = 1 end
    if days > 120 then days = 120 end
    local page = tonumber(args.page) or 1
    local page_size = tonumber(args.page_size) or 20
    if page < 1 then page = 1 end
    if page_size < 1 then page_size = 1 end
    if page_size > 100 then page_size = 100 end

    local db = require("app.db")
    local uf = (type(args.uf) == "string" and args.uf ~= "") and args.uf:upper() or nil
    local municipio = (type(args.municipio) == "string" and args.municipio ~= "") and args.municipio or nil
    local severity = (type(args.severity) == "string" and args.severity ~= "") and args.severity:lower() or nil

    local result = db.get_car_alerts(uf, municipio, severity, days, page, page_size)
    ctx:json(200, result)
end

return _M

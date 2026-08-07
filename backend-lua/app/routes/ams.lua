-- app/routes/ams.lua — AMS fire-spreading-risk overlay (plan: terrabrasilis-integration, Inc 11)
--
-- /api/ams/risk    — polígonos de risco de propagação num bbox
-- /api/ams/active  — pontos "active-fire-today" num bbox

require("app.env")
local auth  = require("app.middleware.auth")
local rl    = require("app.middleware.rate_limit")
local utils = require("app.utils")

local _M = {}

function _M.get_risk(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local bbox, err = utils.parse_bbox(ctx.req.args)
    if not bbox then
        ctx:error(400, err)
        return
    end
    local days = tonumber(ctx.req.args.days) or 7
    if days < 1 then days = 1 end
    if days > 30 then days = 30 end

    local db = require("app.db")
    local polys = db.get_ams_risk(bbox.sw_lat, bbox.ne_lat, bbox.sw_lng, bbox.ne_lng, days, 5000)
    local out = {}
    for _, p in ipairs(polys) do
        if p.layer == "fire-spreading-risk" then
            out[#out + 1] = {
                id = p.id, risk_level = p.risk_level, view_date = p.view_date,
                municipio = p.municipio, biome = p.biome, geom = p.geom,
            }
        end
    end
    ctx:json(200, { count = #out, polygons = out })
end

function _M.get_active(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local bbox, err = utils.parse_bbox(ctx.req.args)
    if not bbox then
        ctx:error(400, err)
        return
    end

    local db = require("app.db")
    local rows = db.get_ams_risk(bbox.sw_lat, bbox.ne_lat, bbox.sw_lng, bbox.ne_lng, 2, 20000)
    local out = {}
    for _, r in ipairs(rows) do
        if r.layer == "active-fire-today" and r.geom then
            -- pontos AMS: geom = Point → pega lon/lat das coordenadas
            local c = r.geom.coordinates
            if c and c[1] and c[2] then
                out[#out + 1] = {
                    id = r.id, satelite = r.satelite, municipio = r.municipio,
                    biome = r.biome, geocode = r.geocode, viewed_at = r.viewed_at,
                    lon = c[1], lat = c[2],
                }
            end
        end
    end
    ctx:json(200, { count = #out, points = out })
end

return _M

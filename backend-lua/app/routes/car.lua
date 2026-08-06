-- app/routes/car.lua — /api/car/lookup (ponto → imóvel CAR)
--
-- Clique-para-inspecionar do overlay CAR (plano .plans/car-overlay, Inc 2).
-- Reusa car_lookup.classify_point (RTree bbox → decode candidatos → ray-cast)
-- e devolve o imóvel sob o ponto, ou null se não houver CAR ali.

require("app.env")
local auth = require("app.middleware.auth")
local rl   = require("app.middleware.rate_limit")
local cjson = require("cjson")

local _M = {}

function _M.get_lookup(ctx)
    if not auth.enforce(ctx) then return end
    if not rl.enforce(ctx) then return end

    local lat = tonumber(ctx.req.args.lat)
    local lon = tonumber(ctx.req.args.lon)
    if not lat or not lon then
        ctx:error(400, "Missing lat/lon")
        return
    end

    local car = require("app.lookups.car_lookup")
    car.load_car()
    local hit = car.classify_point(lon, lat)   -- {id=cod_imovel, name=municipio, uf} | nil
    ctx:json(200, { imovel = hit or cjson.null })
end

return _M

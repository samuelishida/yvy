-- tools/deter_protected_alerts.lua — alertas DETER em UC/TI (detached)
--
-- Scan noturno: para cada polígono DETER recente, detecta se cai numa UC ou TI
-- e gera entradas de alerta `deter_protected`, gravadas em Redis
-- (`alerts:deter_protected`, TTL 86400) para o /api/alerts consumir.
--
-- Detecção UC: atributo nativo `uc` (INPE, Inc 2, possivelmente multi-valor,
-- separado por ,/;) com filtro areauckm/area_km2 ≥ 10% (incursão pequena
-- descartada); fallback para centroide point-in-polygon quando `uc` vazio.
-- TI não tem atributo nativo → centroide contra os anéis de TI.
--
-- WHY detached: como classify_fires.lua — point-in-polygon contra 298 UC + 547
-- TI por polígono DETER bloqueia o loop copas se inline.
--
-- Usage: lua5.1 tools/deter_protected_alerts.lua [days]

local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local backend_dir = script_dir:gsub("[\\/]tools[\\/]$", "/")
package.path = backend_dir .. "?.lua;" .. backend_dir .. "?/init.lua;" .. package.path

local env = require("app.env")
env.load_dotenv(backend_dir .. "../.env")
env.load_dotenv(backend_dir .. ".env")

local db       = require("app.db")
local redis    = require("app.redis")
local ti       = require("app.lookups.indigenous_lands_lookup")
local uc       = require("app.lookups.conservation_units_lookup")
local cjson    = require("cjson")
local logger   = require("app.logger")

local days = tonumber(arg and arg[1]) or 30

db.init_db()
ti.load_indigenous_lands()
uc.load_conservation_units()

local function name_hash(s)
    local h = 5381
    for i = 1, #s do h = ((h * 33) + s:byte(i)) % 0x100000 end
    return string.format("%05x", h)
end

local function split_ucs(uc_attr)
    if type(uc_attr) ~= "string" or uc_attr == "" then return {} end
    local result = {}
    for part in uc_attr:gmatch("[^,;]+") do
        local trimmed = part:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then result[#result + 1] = trimmed end
    end
    return result
end

-- Centroide aproximado = centro do bbox (representative point barato e estável)
local function bbox_center(polygon)
    return (polygon.min_lat + polygon.max_lat) / 2, (polygon.min_lon + polygon.max_lon) / 2
end

-- Detecta UCs/TIs de um polígono DETER. Retorna lista de hits
-- { type="uc"|"ti", name=..., info=... }.
local function detect_territory(polygon)
    local hits = {}
    local clat, clon = bbox_center(polygon)

    -- UC: atributo nativo primeiro (com filtro de incursão ≥ 10%)
    local ucs = split_ucs(polygon.uc)
    if #ucs > 0 then
        local include_uc = true
        if polygon.area_km2 and polygon.areauckm and polygon.area_km2 > 0 then
            if (polygon.areauckm / polygon.area_km2) < 0.10 then
                include_uc = false  -- incursão pequena de borda → descarta UC
            end
        end
        if include_uc then
            for _, name in ipairs(ucs) do
                hits[#hits + 1] = { type = "uc", name = name }
            end
        end
    else
        local info = uc.classify_point(clon, clat)
        if info then
            hits[#hits + 1] = { type = "uc", name = info.name, info = info }
        end
    end

    -- TI: centroide contra anéis
    local ti_info = ti.classify_point(clon, clat)
    if ti_info then
        hits[#hits + 1] = { type = "ti", name = ti_info.name, info = ti_info }
    end

    return hits
end

-- Agrega por (type, nome, data): soma área, coleta classes. Entradas de alerta
-- sem `tick` — o routes/alerts.lua decide crit/warn (R6, class/area rule).
local function run()
    local by_key = {}
    local last_id = 0
    local BATCH = 1000
    local total = 0

    while true do
        local batch = db.iter_deter_recent(days, BATCH, last_id)
        if #batch == 0 then break end

        for _, poly in ipairs(batch) do
            local hits = detect_territory(poly)
            for _, hit in ipairs(hits) do
                local key = hit.type .. ":" .. hit.name .. ":" .. poly.view_date
                local entry = by_key[key]
                if not entry then
                    local clat, clon = bbox_center(poly)
                    entry = {
                        id = "deter_protected_" .. name_hash(key),
                        type = "deter_protected",
                        territory_type = hit.type,
                        territory_name = hit.name,
                        area_ha = 0,
                        classes = {},
                        class_set = {},
                        center = { clat, clon },
                        generated_at = os.time(),
                    }
                    by_key[key] = entry
                end
                entry.area_ha = entry.area_ha + ((poly.area_km2 or 0) * 100)
                if poly.classname and not entry.class_set[poly.classname] then
                    entry.class_set[poly.classname] = true
                    entry.classes[#entry.classes + 1] = poly.classname
                end
                entry.classname = entry.classes[1]
                entry.view_date = poly.view_date
                entry.meta = (hit.type == "uc" and "UC " or "TI ") .. hit.name
                    .. " · " .. string.format("%.1f", entry.area_ha) .. " ha DETER"
                entry.state = (entry.classname or "DETER") .. " · " .. poly.view_date
            end
            total = total + 1
        end

        if #batch < BATCH then break end
        last_id = batch[#batch].id
    end

    -- Materializa + ordena por área (maiores primeiro)
    local alerts = {}
    for key, e in pairs(by_key) do
        e.radius_km = math.max(5.0, math.sqrt(e.area_ha / 100) * 1.5)
        e.ts = os.date("!%H:%M", e.generated_at)
        alerts[#alerts + 1] = e
    end
    table.sort(alerts, function(a, b) return a.area_ha > b.area_ha end)

    redis.set("alerts:deter_protected", cjson.encode(alerts), 86400)
    logger.info("DETER protected-area alerts: " .. #alerts .. " entries (" .. total .. " polygons scanned, " .. days .. "d)")
end

local ok, err = pcall(run)
if not ok then
    logger.error("deter_protected_alerts failed: " .. tostring(err))
    -- chave ausente = sentinela de run falho (ver plan Inc 6 observability)
    os.exit(1)
end

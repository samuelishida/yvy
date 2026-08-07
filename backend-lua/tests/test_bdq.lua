-- test_bdq.lua — BdQueimadas (plan: terrabrasilis-fixes, Inc 3)
--
-- Verifica: (a) deduplicação ON CONFLICT DO NOTHING (FIRMS mantido no conflito)
-- + filtro de fonte no find_fires; (b) a descoberta WFS por GetCapabilities
-- (função pura, fixture sem rede) — só camadas ams*:active-fire-* são escolhidas;
-- (c) o mapeamento de campos (view_date/data_hora_gmt → acq_date normalizado,
-- estado → uf) via fixture, sem rede.

local env = require("app.env")
local sqlite3 = require("lsqlite3")
local utils = require("app.utils")

local tmp_yvy_db = "./yvy_bdq_" .. tostring(os.time()) .. ".db"
env.set("SQLITE_PATH", tmp_yvy_db)
package.loaded["app.db"] = nil
local db_mod = require("app.db")

-- Carrega o tool (funções puras) sem executar o sync — o auto-run é guardado
-- por arg[0] (só roda quando invocado como `lua5.1 tools/sync_bdqueimadas.lua`).
package.path = "./?.lua;./?/init.lua;" .. package.path
local bdq = dofile("tools/sync_bdqueimadas.lua")

dofile("tests/helpers.lua")  -- fornece days_ago(n): fixtures relativas ao relógio

local function fire_doc(lat, lon, date, source)
    return {
        lat = lat, lon = lon, confidence = "high", acq_date = date,
        acq_time = "1200", satellite = "NPP", bright_ti4 = 350.0,
        source = source, state = "RO", fire_type = "vegetation",
        frp = 10, daynight = "D", ingested_at = utils.now_iso(),
    }
end

describe("bdqueimadas", function()
    describe("db dedup (ON CONFLICT DO NOTHING)", function()
        setup(function()
            db_mod.init_db()
            -- FIRMS já tem o foco em (-10.5, -60.5, days_ago(6))
            db_mod.bulk_upsert_fires({ fire_doc(-10.5, -60.5, days_ago(6), "NASA_FIRMS_VIIRS_SNPP") })
            -- BDQ tenta inserir o MESMO foco + um foco novo
            local n = db_mod.bulk_upsert_fires_keep_first({
                fire_doc(-10.5, -60.5, days_ago(6), "bdqueimadas"),  -- conflito → mantém FIRMS
                fire_doc(-12.0, -62.0, days_ago(5), "bdqueimadas"),  -- gap → insere
            })
            assert.are_equal(2, n)
        end)

        teardown(function()
            db_mod.close_db()
            os.remove(tmp_yvy_db)
            os.remove(tmp_yvy_db .. "-wal")
            os.remove(tmp_yvy_db .. "-shm")
        end)

        it("keeps FIRMS on (lat,lon,acq_date) conflict", function()
            local fires = db_mod.find_fires(-34, 5.5, -74, -34, 100)
            local at_conflict
            for _, f in ipairs(fires) do
                if f.lat == -10.5 and f.lon == -60.5 and f.acq_date == days_ago(6) then
                    at_conflict = f
                end
            end
            assert.is_not_nil(at_conflict)
            assert.are_equal("NASA_FIRMS_VIIRS_SNPP", at_conflict.source)
        end)

        it("inserts BDQ fires in gaps", function()
            local fires = db_mod.find_fires(-34, 5.5, -74, -34, 100)
            local found = false
            for _, f in ipairs(fires) do
                if f.lat == -12.0 and f.lon == -62.0 then
                    assert.are_equal("bdqueimadas", f.source)
                    found = true
                end
            end
            assert.is_true(found)
        end)

        it("find_fires filters by source", function()
            local bdq_rows = db_mod.find_fires(-34, 5.5, -74, -34, 100, true, "bdqueimadas")
            local firms = db_mod.find_fires(-34, 5.5, -74, -34, 100, true, "NASA_FIRMS%")
            assert.are_equal(1, #bdq_rows)
            assert.are_equal(1, #firms)
            assert.are_equal("bdqueimadas", bdq_rows[1].source)
            assert.are_equal("NASA_FIRMS_VIIRS_SNPP", firms[1].source)
        end)
    end)

    describe("discovery (fixture, no network)", function()
        it("selects only ams active-fire point layers", function()
            local layers = {
                "prodes-legal-amz:accumulated_deforestation_2007",
                "ams1h:active-fire-today",
                "ams3:active-fire-today",
                "ams1h:fire-spreading-risk",     -- POLÍGONO do AMS risk — NÃO ingere
                "ams2:municipalities_border",    -- sem "active-fire" — descartado
                "queimadas:dummy",               -- workspace != ams — descartado
                "deter-amz:cs_geo_view",         -- sem "active-fire" — descartado
                "ams1h:last_date",               -- sem "active-fire" — descartado
            }
            local selected = bdq.select_fire_layers(layers)
            assert.are_equal(2, #selected)
            assert.are_equal("ams1h:active-fire-today", selected[1])
            assert.are_equal("ams3:active-fire-today", selected[2])
        end)

        it("parses GetCapabilities XML into version + feature types", function()
            local xml = [[
<?xml version="1.0" encoding="UTF-8"?>
<wfs:WFS_Capabilities version="2.0.0" xmlns:wfs="http://www.opengis.net/wfs/2.0">
  <ows:ServiceIdentification><ows:ServiceTypeVersion>2.0.0</ows:ServiceTypeVersion></ows:ServiceIdentification>
  <FeatureTypeList>
    <FeatureType><Name>ams1h:active-fire-today</Name></FeatureType>
    <FeatureType><Name>ams3:active-fire-today</Name></FeatureType>
    <FeatureType><Name>ams1h:fire-spreading-risk</Name></FeatureType>
    <FeatureType><Name>ams2:municipalities_border</Name></FeatureType>
    <FeatureType><Name>queimadas:dummy</Name></FeatureType>
  </FeatureTypeList>
</wfs:WFS_Capabilities>
]]
            local caps = bdq.parse_capabilities(xml)
            assert.are_equal("2.0.0", caps.version)
            assert.are_equal(5, #caps.feature_types)
            assert.are_equal("ams1h:active-fire-today", caps.feature_types[1])
            -- integração parse → filtro: só as 2 camadas de fogo
            local layers = bdq.select_fire_layers(caps.feature_types)
            assert.are_equal(2, #layers)
        end)
    end)

    describe("map_feature (fixture, no network)", function()
        it("maps live WFS fields (view_date/geom/satelite/estado)", function()
            local f = {
                type = "Feature",
                geometry = { type = "Point", coordinates = { -60.5, -10.5 } },
                properties = {
                    view_date = days_ago(0),
                    viewed_at = days_ago(0) .. "T14:30:00Z",
                    satelite = "GOES-16",
                    municipio = "Vilhena",
                    biome = "Amazônia",
                    estado = "RO",
                },
            }
            local d = bdq.map_feature(f)
            assert.is_not_nil(d)
            assert.are_equal(-10.5, d.lat)
            assert.are_equal(-60.5, d.lon)
            assert.are_equal(days_ago(0), d.acq_date)
            assert.are_equal("1430", d.acq_time)   -- viewed_at HH:MM → HHMM
            assert.are_equal("GOES-16", d.satellite)
            assert.are_equal("bdqueimadas", d.source)
            assert.are_equal("RO", d.state)        -- estado → uf (data JSONB)
        end)

        it("normalizes data_hora_gmt datetime to YYYY-MM-DD", function()
            local f = {
                geometry = { coordinates = { -60.5, -10.5 } },
                properties = {
                    data_hora_gmt = days_ago(0) .. "T18:45:00Z",
                    longitude = -60.5,
                    latitude = -10.5,
                    estado = "RO",
                },
            }
            local d = bdq.map_feature(f)
            assert.is_not_nil(d)
            assert.are_equal(days_ago(0), d.acq_date)
            assert.are_equal(-10.5, d.lat)
            assert.are_equal(-60.5, d.lon)
            assert.are_equal("RO", d.state)
        end)

        it("rejects features without date or coordinates", function()
            assert.is_nil(bdq.map_feature({ properties = { view_date = days_ago(0) } }))
            assert.is_nil(bdq.map_feature({ geometry = { coordinates = { -60.5, -10.5 } } }))
        end)
    end)
end)

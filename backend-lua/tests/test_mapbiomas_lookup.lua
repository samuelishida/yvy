-- test_mapbiomas_lookup.lua — MapBiomas Alerta lookup (bbox, CAR, recent, DB ausente)
dofile("tests/helpers.lua")
local env = require("app.env")
local sqlite3 = require("lsqlite3")
local cjson = require("cjson")

local tmp_db = "./yvy_mapbiomas_test_" .. tostring(os.time()) .. ".db"
env.set("MAPBIOMAS_DB_PATH", tmp_db)

-- Fixture com o mesmo schema do scripts/data/download_mapbiomas_alerta.py
local function build_fixture()
    local conn = sqlite3.open(tmp_db)
    conn:exec([[CREATE TABLE alerts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        alert_code TEXT UNIQUE,
        source TEXT,
        area_ha REAL,
        biome TEXT,
        state TEXT,
        city TEXT,
        ano_det INTEGER,
        data_deteccao TEXT,
        data_publicacao TEXT,
        cod_imovel TEXT,
        geom BLOB,
        bbox TEXT
    );]])
    conn:exec([[CREATE TABLE alerts_rtree (
        id INTEGER PRIMARY KEY,
        minLon REAL, maxLon REAL, minLat REAL, maxLat REAL
    );]])
    local insert = conn:prepare([[INSERT INTO alerts
        (alert_code, source, area_ha, biome, state, city, ano_det,
         data_deteccao, data_publicacao, cod_imovel, geom, bbox)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)]])
    local rtree = conn:prepare([[INSERT INTO alerts_rtree
        (id, minLon, maxLon, minLat, maxLat) VALUES (?,?,?,?,?)]])
    local function add(id, code, area, biome, state, ano, det, cod, bbox)
        insert:bind(1, code)
        insert:bind(2, "mapbiomas")
        insert:bind(3, area)
        insert:bind(4, biome)
        insert:bind(5, state)
        insert:bind(6, "")
        insert:bind(7, ano)
        insert:bind(8, det)
        insert:bind(9, det)
        insert:bind(10, cod)
        insert:bind(11, nil)
        insert:bind(12, cjson.encode(bbox))
        insert:step()
        insert:reset()
        rtree:bind(1, id)
        rtree:bind(2, bbox[1])
        rtree:bind(3, bbox[2])
        rtree:bind(4, bbox[3])
        rtree:bind(5, bbox[4])
        rtree:step()
        rtree:reset()
    end
    -- RO-1: alerta em Rondônia (lat -10.5, lon -60.5), ano 2024
    add(1, "AL-RO-1", 12.5, "Amazônia", "RO", 2024, days_ago(10), "RO-1",
        {-60.6, -60.4, -10.6, -10.4})
    -- MT-1: alerta em Mato Grosso (lat -12.0, lon -55.0), ano 2023
    add(2, "AL-MT-1", 5.0, "Cerrado", "MT", 2023, days_ago(200), "MT-1",
        {-55.1, -54.9, -12.1, -11.9})
    -- Sem CAR: alerta sem cod_imovel (lat -3.0, lon -60.0)
    add(3, "AL-AM-1", 3.0, "Amazônia", "AM", 2025, days_ago(5), nil,
        {-60.1, -59.9, -3.1, -2.9})
    insert:finalize()
    rtree:finalize()
    conn:close()
end

local build_ok, build_err = pcall(build_fixture)

package.loaded["app.lookups.mapbiomas_lookup"] = nil
local mapbiomas = require("app.lookups.mapbiomas_lookup")

describe("mapbiomas_lookup", function()
    setup(function()
        assert(build_ok, "fixture build failed: " .. tostring(build_err))
        mapbiomas.load_mapbiomas()
    end)

    teardown(function()
        os.remove(tmp_db)
    end)

    it("is_loaded after fixture", function()
        assert.is_true(mapbiomas.is_loaded())
        assert.is_true(mapbiomas.count() >= 3)
    end)

    it("get_alerts_in_bbox returns alerts crossing the bbox", function()
        local rows = mapbiomas.get_alerts_in_bbox(-11.0, -10.0, -61.0, -60.0, 10)
        assert.is_true(#rows >= 1)
        local found = false
        for _, a in ipairs(rows) do
            if a.alert_code == "AL-RO-1" then found = true end
        end
        assert.is_true(found, "expected AL-RO-1 in bbox")
    end)

    it("get_alerts_by_car returns alerts for a cod_imovel", function()
        local rows = mapbiomas.get_alerts_by_car("RO-1")
        assert.is_true(#rows >= 1)
        assert.are_equal("AL-RO-1", rows[1].alert_code)
        -- case-insensitive key
        local rows2 = mapbiomas.get_alerts_by_car("ro-1")
        assert.is_true(#rows2 >= 1)
    end)

    it("get_recent_alerts returns only recent alerts", function()
        local rows = mapbiomas.get_recent_alerts(30)
        local codes = {}
        for _, a in ipairs(rows) do codes[a.alert_code] = true end
        assert.is_true(codes["AL-RO-1"], "recent alert present")
        assert.is_true(codes["AL-AM-1"], "recent alert present")
        assert.is_falsy(codes["AL-MT-1"], "old alert excluded")
    end)

    it("graceful degradation when DB is absent", function()
        env.set("MAPBIOMAS_DB_PATH", "./yvy_mapbiomas_missing_" .. tostring(os.time()) .. ".db")
        package.loaded["app.lookups.mapbiomas_lookup"] = nil
        local m2 = require("app.lookups.mapbiomas_lookup")
        m2.load_mapbiomas()
        assert.is_false(m2.is_loaded())
        assert.are_equal(0, #m2.get_alerts_in_bbox(-11, -10, -61, -60, 10))
        assert.are_equal(0, #m2.get_alerts_by_car("RO-1"))
        assert.are_equal(0, #m2.get_recent_alerts(30))
        env.set("MAPBIOMAS_DB_PATH", tmp_db)
    end)
end)

-- test_supplier_monitor.lua — fornecedores monitorados + scan de alertas
-- (CRUD, scan detecta alerta, webhook chamado, teardown Redis).
dofile("tests/helpers.lua")
local env = require("app.env")
local sqlite3 = require("lsqlite3")
local cjson = require("cjson")

local tmp_suppliers_db = "./yvy_suppliers_test_" .. tostring(os.time()) .. ".db"
local tmp_mapbiomas_db = "./yvy_mapbiomas_scan_" .. tostring(os.time()) .. ".db"

env.set("SUPPLIERS_DB_PATH", tmp_suppliers_db)
env.set("MAPBIOMAS_DB_PATH", tmp_mapbiomas_db)
package.loaded["app.lookups.supplier_monitor"] = nil
package.loaded["app.lookups.mapbiomas_lookup"] = nil
package.loaded["tools.scan_supplier_alerts"] = nil

local supplier_monitor = require("app.lookups.supplier_monitor")
local mapbiomas = require("app.lookups.mapbiomas_lookup")
local scan = require("tools.scan_supplier_alerts")
local redis = require("app.redis")

-- Fixture do mapbiomas_alerta.db com um alerta recente para RO-1.
local function build_mapbiomas_fixture()
    local conn = sqlite3.open(tmp_mapbiomas_db)
    conn:exec([[CREATE TABLE alerts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        alert_code TEXT UNIQUE, source TEXT, area_ha REAL, biome TEXT,
        state TEXT, city TEXT, ano_det INTEGER, data_deteccao TEXT,
        data_publicacao TEXT, cod_imovel TEXT, geom BLOB, bbox TEXT
    );]])
    conn:exec([[CREATE TABLE alerts_rtree (
        id INTEGER PRIMARY KEY, minLon REAL, maxLon REAL, minLat REAL, maxLat REAL
    );]])
    local ins = conn:prepare([[INSERT INTO alerts
        (alert_code, source, area_ha, biome, state, city, ano_det,
         data_deteccao, data_publicacao, cod_imovel, geom, bbox)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)]])
    ins:bind(1, "AL-RO-1")
    ins:bind(2, "mapbiomas")
    ins:bind(3, 12.5)
    ins:bind(4, "Amazônia")
    ins:bind(5, "RO")
    ins:bind(6, "")
    ins:bind(7, 2026)
    ins:bind(8, days_ago(5))
    ins:bind(9, days_ago(5))
    ins:bind(10, "RO-1")
    ins:bind(11, nil)
    ins:bind(12, cjson.encode({-60.6, -60.4, -10.6, -10.4}))
    ins:step()
    ins:finalize()
    conn:close()
end

local build_ok, build_err = pcall(build_mapbiomas_fixture)

describe("supplier_monitor", function()
    setup(function()
        assert(build_ok, "mapbiomas fixture failed: " .. tostring(build_err))
        supplier_monitor.ensure_schema(supplier_monitor._offline_conn())
        mapbiomas.load_mapbiomas()
        -- Isola o scan do Redis compartilhado (common-mistake §2).
        scan._skip_redis_invalidation = true
    end)

    teardown(function()
        -- Limpa as chaves Redis do scan (common-mistake §2): o run_scan grava
        -- risk:supplier_alerts e risk:supplier_alert:<cnpj> no Redis compartilhado.
        redis.delete("risk:supplier_alerts")
        redis.delete("risk:supplier_alert:12345678000199")
        redis.delete("risk:supplier_alert:99999999000199")
        os.remove(tmp_suppliers_db)
        os.remove(tmp_suppliers_db .. "-wal")
        os.remove(tmp_suppliers_db .. "-shm")
        os.remove(tmp_mapbiomas_db)
    end)

    it("upsert + get supplier round-trips", function()
        local ok = supplier_monitor.upsert_supplier({
            cnpj = "12345678000199", nome = "Fornecedor A", cod_imovel = "RO-1",
        })
        assert.is_true(ok)
        local s = supplier_monitor.get_supplier("12345678000199")
        assert.is_not_nil(s)
        assert.are_equal("Fornecedor A", s.nome)
        assert.are_equal("RO-1", s.cod_imovel)
    end)

    it("get_suppliers lists all", function()
        supplier_monitor.upsert_supplier({ cnpj = "99999999000199", nome = "B" })
        local list = supplier_monitor.get_suppliers()
        assert.is_true(#list >= 2)
    end)

    it("check_supplier matches by cod_imovel", function()
        local alert = scan.check_supplier(
            { cnpj = "12345678000199", cod_imovel = "RO-1" },
            mapbiomas.get_recent_alerts(30))
        assert.is_not_nil(alert)
        assert.are_equal("AL-RO-1", alert.alert_code)
    end)

    it("check_supplier returns nil when no match", function()
        local alert = scan.check_supplier(
            { cnpj = "12345678000199", cod_imovel = "MT-999" },
            mapbiomas.get_recent_alerts(30))
        assert.is_nil(alert)
    end)

    it("run_scan alerts a monitored supplier and pushes in-app alert", function()
        supplier_monitor.upsert_supplier({
            cnpj = "12345678000199", nome = "Fornecedor A", cod_imovel = "RO-1",
        })
        local n = scan.run_scan(30)
        assert.is_true(n >= 1)
        local alerts = supplier_monitor.get_alerts()
        assert.is_true(#alerts >= 1)
        assert.are_equal("12345678000199", alerts[#alerts].cnpj)
    end)
end)

-- test_area_efetiva_lookup.lua — lookup de área efetiva (query por alerta, por
-- imóvel, fração, DB ausente → graceful degradation).
dofile("tests/helpers.lua")
local env = require("app.env")
local sqlite3 = require("lsqlite3")

local tmp_db = "./yvy_area_efetiva_test_" .. tostring(os.time()) .. ".db"
env.set("AREA_EFETIVA_DB_PATH", tmp_db)

package.loaded["app.lookups.area_efetiva_lookup"] = nil
local area_efetiva = require("app.lookups.area_efetiva_lookup")

-- Cria um area_efetiva.db de teste com pares conhecidos.
local function seed_db()
    local conn = sqlite3.open(tmp_db)
    conn:exec([[
        CREATE TABLE area_efetiva (
            alert_code TEXT NOT NULL,
            cod_imovel TEXT NOT NULL,
            area_efetiva_ha REAL,
            fracao REAL,
            version_key TEXT,
            PRIMARY KEY (alert_code, cod_imovel)
        );
    ]])
    conn:exec([[
        INSERT INTO area_efetiva VALUES
            ('A1', 'RO-1', 8.0, 0.67, '20260813'),
            ('A1', 'RO-2', 4.0, 0.33, '20260813'),
            ('A2', 'RO-1', 12.0, 1.0, '20260813');
    ]])
    conn:close()
end

describe("area_efetiva_lookup", function()
    teardown(function()
        os.remove(tmp_db)
    end)

    it("returns pairs by alert (one row per CAR)", function()
        seed_db()
        area_efetiva.load_area_efetiva()
        local pairs = area_efetiva.get_by_alert("A1")
        assert.are_equal(2, #pairs)
        -- Ordem não garantida; verifica por cod_imovel.
        local by_cod = {}
        for _, p in ipairs(pairs) do
            by_cod[p.cod_imovel] = p
        end
        assert.are_equal(8.0, by_cod["RO-1"].area_efetiva_ha)
        assert.are_equal(0.67, by_cod["RO-1"].fracao)
        assert.are_equal(4.0, by_cod["RO-2"].area_efetiva_ha)
    end)

    it("returns pairs by car (sum of effective areas)", function()
        local pairs = area_efetiva.get_by_car("RO-1")
        assert.are_equal(2, #pairs)
        assert.are_equal(20.0, area_efetiva.sum_by_car("RO-1"))
    end)

    it("returns fraction for a specific (alert, car) pair", function()
        assert.are_equal(0.67, area_efetiva.get_fracao("A1", "RO-1"))
        assert.are_equal(1.0, area_efetiva.get_fracao("A2", "RO-1"))
    end)

    it("returns nil/empty for unknown keys", function()
        assert.are_equal(0, #area_efetiva.get_by_alert("NOPE"))
        assert.are_equal(0, #area_efetiva.get_by_car("NOPE"))
        assert.is_nil(area_efetiva.get_fracao("NOPE", "RO-1"))
        assert.are_equal(0, area_efetiva.sum_by_car("NOPE"))
    end)

    it("graceful degradation when DB absent", function()
        os.remove(tmp_db)
        package.loaded["app.lookups.area_efetiva_lookup"] = nil
        local fresh = require("app.lookups.area_efetiva_lookup")
        fresh.load_area_efetiva()
        assert.is_false(fresh.is_loaded())
        assert.are_equal(0, #fresh.get_by_alert("A1"))
        assert.are_equal(0, #fresh.get_by_car("RO-1"))
        assert.is_nil(fresh.get_fracao("A1", "RO-1"))
        assert.are_equal(0, fresh.sum_by_car("RO-1"))
    end)
end)

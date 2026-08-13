-- test_embargo_lookup.lua — lookup de embargo (query por car, por coordenada,
-- DB ausente → graceful degradation).
dofile("tests/helpers.lua")
local env = require("app.env")
local sqlite3 = require("lsqlite3")

local tmp_db = "./yvy_embargo_test_" .. tostring(os.time()) .. ".db"
env.set("EMBARGO_DB_PATH", tmp_db)

package.loaded["app.lookups.embargo_lookup"] = nil
local embargo = require("app.lookups.embargo_lookup")

-- Cria um embargo.db de teste com embargos conhecidos.
local function seed_db()
    local conn = sqlite3.open(tmp_db)
    conn:exec([[
        CREATE TABLE embargoes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            numero TEXT UNIQUE,
            data TEXT,
            situacao TEXT,
            municipio TEXT,
            uf TEXT,
            cod_imovel TEXT,
            geom BLOB,
            bbox TEXT
        );
        CREATE TABLE embargoes_rtree (
            id INTEGER PRIMARY KEY,
            minLon REAL, maxLon REAL, minLat REAL, maxLat REAL
        );
    ]])
    conn:exec([[
        INSERT INTO embargoes (id, numero, data, situacao, municipio, uf, cod_imovel, geom, bbox)
        VALUES
            (1, 'E1', '2026-01-01', 'N', 'Morada Nova', 'CE', 'CE-1', 'POLYGON((-38.34 -4.86,-38.33 -4.86,-38.33 -4.87,-38.34 -4.87,-38.34 -4.86))', '[-38.34,-38.33,-4.87,-4.86]'),
            (2, 'E2', '2026-02-01', 'N', 'Mateiros', 'TO', 'TO-1', 'POLYGON((-46.51 -11.09,-46.50 -11.09,-46.50 -11.10,-46.51 -11.10,-46.51 -11.09))', '[-46.51,-46.50,-11.10,-11.09]');
        INSERT INTO embargoes_rtree (id, minLon, maxLon, minLat, maxLat) VALUES
            (1, -38.34, -38.33, -4.87, -4.86),
            (2, -46.51, -46.50, -11.10, -11.09);
    ]])
    conn:close()
end

describe("embargo_lookup", function()
    teardown(function()
        os.remove(tmp_db)
    end)

    it("returns embargoes by car", function()
        seed_db()
        embargo.load_embargo()
        local list = embargo.get_by_car("CE-1")
        assert.are_equal(1, #list)
        assert.are_equal("E1", list[1].numero)
        assert.are_equal("CE", list[1].uf)
    end)

    it("has_active_embargo is true for an embargoed property", function()
        assert.is_true(embargo.has_active_embargo("CE-1"))
        assert.is_false(embargo.has_active_embargo("NOPE-1"))
    end)

    it("returns embargoes by coordinate (rtree)", function()
        local list = embargo.get_at(-38.335, -4.865)
        assert.are_equal(1, #list)
        assert.are_equal("E1", list[1].numero)
    end)

    it("returns empty for unknown keys", function()
        assert.are_equal(0, #embargo.get_by_car("NOPE"))
        assert.are_equal(0, #embargo.get_at(-100, -100))
    end)

    it("graceful degradation when DB absent", function()
        os.remove(tmp_db)
        package.loaded["app.lookups.embargo_lookup"] = nil
        local fresh = require("app.lookups.embargo_lookup")
        fresh.load_embargo()
        assert.is_false(fresh.is_loaded())
        assert.are_equal(0, #fresh.get_by_car("CE-1"))
        assert.is_false(fresh.has_active_embargo("CE-1"))
        assert.are_equal(0, #fresh.get_at(-38.335, -4.865))
    end)
end)

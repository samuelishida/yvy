-- test_bdq.lua — BdQueimadas (plan: terrabrasilis-integration, Inc 10)
--
-- Verifica a deduplicação ON CONFLICT DO NOTHING (FIRMS mantido no conflito) e
-- o filtro de fonte no find_fires.

local env = require("app.env")
local sqlite3 = require("lsqlite3")
local utils = require("app.utils")

local tmp_yvy_db = "./yvy_bdq_" .. tostring(os.time()) .. ".db"
env.set("SQLITE_PATH", tmp_yvy_db)
package.loaded["app.db"] = nil
local db_mod = require("app.db")

local function fire_doc(lat, lon, date, source)
    return {
        lat = lat, lon = lon, confidence = "high", acq_date = date,
        acq_time = "1200", satellite = "NPP", bright_ti4 = 350.0,
        source = source, state = "RO", fire_type = "vegetation",
        frp = 10, daynight = "D", ingested_at = utils.now_iso(),
    }
end

describe("bdqueimadas", function()
    setup(function()
        db_mod.init_db()
        -- FIRMS já tem o foco em (-10.5, -60.5, 2026-08-01)
        db_mod.bulk_upsert_fires({ fire_doc(-10.5, -60.5, "2026-08-01", "NASA_FIRMS_VIIRS_SNPP") })
        -- BDQ tenta inserir o MESMO foco + um foco novo
        local n = db_mod.bulk_upsert_fires_keep_first({
            fire_doc(-10.5, -60.5, "2026-08-01", "INPE_BDQUEIMADAS"),  -- conflito → mantém FIRMS
            fire_doc(-12.0, -62.0, "2026-08-02", "INPE_BDQUEIMADAS"),  -- gap → insere
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
            if f.lat == -10.5 and f.lon == -60.5 and f.acq_date == "2026-08-01" then
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
                assert.are_equal("INPE_BDQUEIMADAS", f.source)
                found = true
            end
        end
        assert.is_true(found)
    end)

    it("find_fires filters by source", function()
        local bdq = db_mod.find_fires(-34, 5.5, -74, -34, 100, true, "%BDQ%")
        local firms = db_mod.find_fires(-34, 5.5, -74, -34, 100, true, "NASA_FIRMS%")
        assert.are_equal(1, #bdq)
        assert.are_equal(1, #firms)
        assert.are_equal("INPE_BDQUEIMADAS", bdq[1].source)
        assert.are_equal("NASA_FIRMS_VIIRS_SNPP", firms[1].source)
    end)
end)

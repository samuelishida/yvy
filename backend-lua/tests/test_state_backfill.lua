-- test_state_backfill.lua — reparo de atribuição state (plan: dashboard-enhancement, Inc 2)
--
-- O backfill legado gravou state='' (sentinel) quando o point-in-polygon
-- devolvia nil — inclusive com o layer de estados vazio (40% dos focos em
-- prod). Este teste cobre o reprocessamento: linhas sentinel são revisitadas
-- (iter_fires_for_state_retry), as recuperáveis ganham UF (update_fire_state),
-- as não-classificáveis (oceano) são marcadas (mark_fire_state_unattributable)
-- e nunca mais re-scaneadas. Redis não é usado por estas funções.

local env = require("app.env")
local sqlite3 = require("lsqlite3")

local tmp_yvy_db = "./yvy_state_backfill_" .. tostring(os.time()) .. ".db"
env.set("SQLITE_PATH", tmp_yvy_db)
package.loaded["app.db"] = nil
package.loaded["app.lookups.state_lookup"] = nil

local db_mod = require("app.db")
local sl = require("app.lookups.state_lookup")

dofile("tests/helpers.lua")

describe("state backfill repair", function()
    setup(function()
        db_mod.init_db()
        db_mod.bulk_upsert_fires({
            -- ponto no interior (RO) com sentinel '' — recuperável
            { lat = -10.5, lon = -60.5, acq_date = days_ago(1), ingested_at = days_ago(1) .. "T00:00:00Z", state = "" },
            -- ponto no Atlântico (longe da costa) com sentinel '' — não-classificável
            { lat = -20.0, lon = -30.0, acq_date = days_ago(1), ingested_at = days_ago(1) .. "T00:00:00Z", state = "" },
            -- ponto sem a chave state (não é sentinel; outro caminho do backfill)
            { lat = -10.4, lon = -60.6, acq_date = days_ago(2), ingested_at = days_ago(2) .. "T00:00:00Z" },
        })
        sl.load_states()
    end)

    teardown(function()
        db_mod.close_db()
        os.remove(tmp_yvy_db)
        os.remove(tmp_yvy_db .. "-wal")
        os.remove(tmp_yvy_db .. "-shm")
    end)

    it("reports coverage including sentinel and retried", function()
        local cov = db_mod.count_fires_by_state_present()
        assert.are_equal(3, cov.total)
        assert.are_equal(1, cov.unattributed)   -- sem chave state
        assert.are_equal(2, cov.sentinel_empty) -- com state=''
        assert.are_equal(0, cov.retried)        -- nada reprocessado ainda
    end)

    it("classify_point recovers the inland point but not the ocean", function()
        assert.are_equal("MT", sl.classify_point(-60.5, -10.5))
        assert.is_nil(sl.classify_point(-30.0, -20.0))
    end)

    it("retry iterator returns only untried sentinel rows", function()
        local rows = db_mod.iter_fires_for_state_retry(100)
        assert.are_equal(2, #rows)  -- os 2 sentinel; o sem chave state não entra
        local lons = {}
        for _, r in ipairs(rows) do
            assert.is_not_nil(r.id)
            lons[r.lon] = true
        end
        assert.is_true(lons[-60.5])
        assert.is_true(lons[-30.0])
    end)

    it("mark_fire_state_unattributable prevents re-scanning", function()
        local rows = db_mod.iter_fires_for_state_retry(100)
        local ocean_id
        for _, r in ipairs(rows) do
            if r.lon == -30.0 then ocean_id = r.id end
        end
        assert.is_not_nil(ocean_id)
        db_mod.mark_fire_state_unattributable(ocean_id)

        local cov = db_mod.count_fires_by_state_present()
        assert.are_equal(1, cov.retried)

        local remaining = db_mod.iter_fires_for_state_retry(100)
        assert.are_equal(1, #remaining)
        assert.are_equal(-60.5, remaining[1].lon)
    end)

    it("update_fire_state fixes a sentinel row to a UF", function()
        -- o teste anterior já marcou o oceano; aqui sobra só o ponto do interior
        local rows = db_mod.iter_fires_for_state_retry(100)
        assert.are_equal(1, #rows)
        local inland_id = rows[1].id
        assert.is_not_nil(inland_id)
        db_mod.update_fire_state(inland_id, "MT")

        local remaining = db_mod.iter_fires_for_state_retry(100)
        assert.are_equal(0, #remaining)  -- atribuído → fora do conjunto de retry
    end)

    it("loaded_count reflects loaded polygons", function()
        assert.is_true(sl.loaded_count() > 0)
    end)
end)

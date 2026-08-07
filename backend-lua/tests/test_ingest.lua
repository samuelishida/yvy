-- test_ingest.lua — PRODES ingest + PRODES_FORCE_UPDATE (plan: terrabrasilis-integration, Inc 5)
--
-- Simula a base já povoada (2 linhas), um CSV+QML de teste num DATA_DIR
-- temporário, e valida: skip sem flag; truncate + backup + re-ingest com
-- PRODES_FORCE_UPDATE=1.

local env = require("app.env")
local sqlite3 = require("lsqlite3")

local ts = tostring(os.time())
local tmp_yvy_db = "./yvy_ingest_" .. ts .. ".db"
local tmp_data = "./ingest_data_" .. ts
local version = "prodes_brasil_test_v20260807"
local csv_path = tmp_data .. "/" .. version .. ".csv"
local qml_path = tmp_data .. "/" .. version .. ".qml"

os.execute('mkdir -p "' .. tmp_data .. '"')

local csv = io.open(csv_path, "w")
csv:write("lon,lat,value\n-60.5,-10.5,1\n-61.0,-11.0,2\n")
csv:close()
local qml = io.open(qml_path, "w")
qml:write([[<qgis><pipe><rasterrenderer><colorPalette>
<paletteEntry value="1" color="255,0,0" label="d2000"/>
<paletteEntry value="2" color="0,255,0" label="d2001"/>
</colorPalette></rasterrenderer></pipe></qgis>]])
qml:close()

env.set("SQLITE_PATH", tmp_yvy_db)
env.set("DATA_DIR", tmp_data)
env.set("PRODES_VERSION", version)
env.set("PRODES_FORCE_UPDATE", "0")
package.loaded["app.db"] = nil
package.loaded["app.ingest"] = nil

local db_mod = require("app.db")
local ingest = require("app.ingest")

local function def_count()
    return db_mod.count_deforestation()
end

describe("ingest", function()
    setup(function()
        db_mod.init_db()
        -- Linhas existentes simulam a base já povoada
        db_mod.bulk_upsert_deforestation({
            { lat = -10.5, lon = -60.5, name = "d2020" },
            { lat = -11.0, lon = -61.0, name = "d2024" },
        })
    end)

    teardown(function()
        db_mod.close_db()
        os.remove(tmp_yvy_db)
        os.remove(tmp_yvy_db .. "-wal")
        os.remove(tmp_yvy_db .. "-shm")
        os.remove(tmp_yvy_db .. ".preprodes")
        os.remove(csv_path)
        os.remove(qml_path)
        os.execute('rmdir "' .. tmp_data .. '" 2>/dev/null || true')
    end)

    it("skips ingestion when data exists and no force flag", function()
        local n = ingest.run()
        assert.are_equal(0, n)
        assert.are_equal(2, def_count())
    end)

    it("PRODES_FORCE_UPDATE truncates, backs up and re-ingests", function()
        env.set("PRODES_FORCE_UPDATE", "1")
        local n = ingest.run()
        assert.are_equal(2, n)  -- 2 registros do CSV (d2000, d2001)
        assert.are_equal(2, def_count())

        -- Backup binário criado (sqlite3 .backup)
        local f = io.open(tmp_yvy_db .. ".preprodes", "rb")
        assert.is_not_nil(f)
        f:close()
        env.set("PRODES_FORCE_UPDATE", "0")
    end)
end)

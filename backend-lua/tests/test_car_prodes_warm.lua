-- test_car_prodes_warm.lua — warm offline + merge do pré-cálculo CAR × PRODES
-- (plan: precompute-car-prodes).
--
-- Cria car.db + yvy.db temporários com a fixture, roda warm_car_prodes.run_batch
-- (require-ável como módulo) e asserts: só imóveis positivos são gravados na
-- tabela car_prodes; depois cria dois clones e roda merge_car_prodes.merge,
-- verificando que o target recebe as rows de ambos.

local env = require("app.env")
local sqlite3 = require("lsqlite3")

local tmp_car_db = "./yvy_car_prodes_warm_" .. tostring(os.time()) .. ".db"
local tmp_yvy_db = "./yvy_prodes_warm_" .. tostring(os.time()) .. ".db"
local FIXTURE = "./tests/fixtures/car_sample.json"

env.set("CAR_DB_PATH", tmp_car_db)
env.set("SQLITE_PATH", tmp_yvy_db)
package.loaded["app.lookups.car_lookup"] = nil
package.loaded["app.lookups.car_prodes"] = nil
package.loaded["app.routes.car"] = nil
package.loaded["app.db"] = nil
package.loaded["tools.warm_car_prodes"] = nil
package.loaded["tools.merge_car_prodes"] = nil

local car_import = require("app.car_import")
local car_lookup = require("app.lookups.car_lookup")
local car_prodes = require("app.lookups.car_prodes")
local db_mod = require("app.db")
local warm = require("tools.warm_car_prodes")
local merge_mod = require("tools.merge_car_prodes")

local function make_car_db(path)
    local conn = sqlite3.open(path)
    conn:exec("PRAGMA journal_mode=WAL")
    car_import.create_schema(conn)
    car_import.create_car_prodes_schema(conn)
    local n = car_import.import_file(conn, FIXTURE)
    conn:close()
    return n
end

local function count_rows(path)
    local conn = sqlite3.open(path)
    local n = 0
    for r in conn:nrows("SELECT COUNT(*) AS c FROM car_prodes") do n = tonumber(r.c) or 0 end
    conn:close()
    return n
end

local function cods_in(path)
    local conn = sqlite3.open(path)
    local cods = {}
    for r in conn:nrows("SELECT cod_imovel FROM car_prodes ORDER BY cod_imovel") do
        cods[#cods + 1] = r.cod_imovel
    end
    conn:close()
    return cods
end

local function contains(list, v)
    for _, x in ipairs(list) do
        if x == v then return true end
    end
    return false
end

describe("car_prodes warm offline", function()
    setup(function()
        assert.are_equal(3, make_car_db(tmp_car_db))

        -- yvy.db: 2 d* + 1 r* dentro do RO-1; 1 d* fora de qualquer polígono.
        db_mod.init_db()
        db_mod.bulk_upsert_deforestation({
            { lat = -10.5, lon = -60.5, name = "d2020" },
            { lat = -10.3, lon = -60.2, name = "d2024" },
            { lat = -10.1, lon = -60.1, name = "r2014" },
            { lat = -30.0, lon = -50.0, name = "d2024" },
        })

        car_lookup.load_car()

        -- Não varre o Redis compartilhado no teste (common-mistake §2).
        warm._skip_redis_invalidation = true
    end)

    teardown(function()
        db_mod.close_db()
        os.remove(tmp_car_db)
        os.remove(tmp_car_db .. "-wal")
        os.remove(tmp_car_db .. "-shm")
        os.remove(tmp_yvy_db)
        os.remove(tmp_yvy_db .. "-wal")
        os.remove(tmp_yvy_db .. "-shm")
        -- backup_if_needed gera car.db.warm-backup-<ts> na 1ª escrita do DB
        -- principal (não em clones). Limpa o glob no teardown.
        os.execute('rm -f "' .. tmp_car_db .. '.warm-backup-*" 2>/dev/null')
    end)

    it("warm cria rows positivas na tabela car_prodes", function()
        local rc = warm.run_batch("RO", nil)
        assert.are_equal(0, rc)

        -- RO-1 (100ha, 2 d* + 1 r*) e RO-2 (500ha, contém bbox do RO-1) → positivos.
        local cods = cods_in(tmp_car_db)
        assert.is_true(contains(cods, "RO-1"))
        assert.is_true(contains(cods, "RO-2"))
    end)

    it("warm NÃO cria registro para imóvel sem PRODES (sem negativas)", function()
        local rc = warm.run_batch("MT", nil)
        assert.are_equal(0, rc)
        -- MT-1 (50ha) não tem PRODES → não deve existir row.
        local cods = cods_in(tmp_car_db)
        assert.is_false(contains(cods, "MT-1"))
        -- Rodar RO + MT não duplica e não grava negativos.
        assert.are_equal(2, #cods)
    end)

    it("rows gravadas têm version_key do dataset atual", function()
        local rc = warm.run_batch("RO", nil)
        assert.are_equal(0, rc)
        local expected = car_prodes.current_version_key()

        local conn = sqlite3.open(tmp_car_db)
        local all_match = true
        for r in conn:nrows("SELECT version_key FROM car_prodes") do
            if r.version_key ~= expected then all_match = false end
        end
        conn:close()
        assert.is_true(all_match)
    end)
end)

describe("car_prodes merge", function()
    local clone1 = "./yvy_car_prodes_clone1_" .. tostring(os.time()) .. ".db"
    local clone2 = "./yvy_car_prodes_clone2_" .. tostring(os.time()) .. ".db"
    local target = "./yvy_car_prodes_merged_" .. tostring(os.time()) .. ".db"

    setup(function()
        -- Dois clones com car_prodes independentes. Usa version_key fixo para
        -- não depender do pool de db (fechado no teardown do describe anterior).
        make_car_db(clone1)
        make_car_db(clone2)

        local vk = "test-vk-0001"
        local ts = os.date("!%Y-%m-%dT%H:%M:%SZ")

        local function insert_clone(path, cod, area)
            local conn = sqlite3.open(path)
            conn:exec("PRAGMA journal_mode=WAL")
            local stmt = conn:prepare([[
                INSERT INTO car_prodes
                    (cod_imovel, found, has_prodes, prodes_area_ha, property_area_ha,
                     pct_deforested, years, classes, regrowth, sampled, bbox,
                     area_estimate, version_key, computed_at)
                VALUES (?,1,1,?,?,1,'[2020]','[]',0,0,'{}','pixel-based',?,?)
            ]])
            stmt:bind_values(cod, area, area, vk, ts)
            stmt:step()
            stmt:finalize()
            conn:close()
        end

        insert_clone(clone1, "RO-1", 100.0)
        insert_clone(clone2, "MT-1", 50.0)
    end)

    teardown(function()
        for _, p in ipairs({clone1, clone1 .. "-wal", clone1 .. "-shm",
                            clone2, clone2 .. "-wal", clone2 .. "-shm",
                            target, target .. "-wal", target .. "-shm"}) do
            os.remove(p)
        end
    end)

    it("merge junta rows de dois clones no target", function()
        local ok, err = pcall(merge_mod.merge, target, {clone1, clone2})
        assert.is_true(ok, tostring(err))

        local cods = cods_in(target)
        assert.is_true(contains(cods, "RO-1"))
        assert.is_true(contains(cods, "MT-1"))
        assert.are_equal(2, #cods)
    end)

    it("merge rejeita clones com version_key divergente", function()
        -- Altera o version_key do clone2 para simular dataset divergente.
        local conn = sqlite3.open(clone2)
        conn:exec("UPDATE car_prodes SET version_key = 'stale-key-0000'")
        conn:close()

        local ok, err = pcall(merge_mod.merge, target, {clone1, clone2})
        assert.is_false(ok)
        assert.is_match("inconsistent version_key", tostring(err))
    end)
end)

describe("car_prodes merge: batching >10 clones + replace target", function()
    -- SQLite limita ATTACH a 10 por conexão; o merge deve processar em lotes.
    local N = 11
    local clones = {}
    local paths = {}
    local target = "./yvy_car_prodes_many_" .. tostring(os.time()) .. ".db"

    setup(function()
        for i = 1, N do
            local p = "./yvy_car_prodes_many_c" .. i .. "_" .. tostring(os.time()) .. ".db"
            table.insert(clones, p)
            make_car_db(p)
            local conn = sqlite3.open(p)
            conn:exec("PRAGMA journal_mode=WAL")
            local stmt = conn:prepare([[
                INSERT INTO car_prodes
                    (cod_imovel, found, has_prodes, prodes_area_ha, property_area_ha,
                     pct_deforested, years, classes, regrowth, sampled, bbox,
                     area_estimate, version_key, computed_at)
                VALUES (?,1,1,0.09,10,0,'[2020]','[]',0,0,'{}','pixel-based',?,?)
            ]])
            stmt:bind_values("C-" .. i, "batch-vk", os.date("!%Y-%m-%dT%H:%M:%SZ"))
            stmt:step()
            stmt:finalize()
            conn:close()
        end
    end)

    teardown(function()
        os.remove(target)
        os.remove(target .. "-wal")
        os.remove(target .. "-shm")
        for _, p in ipairs(clones) do
            os.remove(p)
            os.remove(p .. "-wal")
            os.remove(p .. "-shm")
        end
    end)

    it("mergeia >10 clones (batching) e substitui rows antigas do target", function()
        -- Target com uma row antiga (version_key diferente) — deve ser substituída.
        make_car_db(target)
        local tconn = sqlite3.open(target)
        tconn:exec("PRAGMA journal_mode=WAL")
        local stmt = tconn:prepare([[
            INSERT INTO car_prodes
                (cod_imovel, found, has_prodes, prodes_area_ha, property_area_ha,
                 pct_deforested, years, classes, regrowth, sampled, bbox,
                 area_estimate, version_key, computed_at)
            VALUES ('OLD-1',1,1,99,10,0,'[2020]','[]',0,0,'{}','pixel-based',?,?)
        ]])
        stmt:bind_values("old-vk", os.date("!%Y-%m-%dT%H:%M:%SZ"))
        stmt:step()
        stmt:finalize()
        tconn:close()

        local ok, err = pcall(merge_mod.merge, target, clones)
        assert.is_true(ok, tostring(err))

        local conn = sqlite3.open(target)
        local cods, keys = {}, {}
        for r in conn:nrows("SELECT cod_imovel, version_key FROM car_prodes ORDER BY cod_imovel") do
            cods[#cods + 1] = r.cod_imovel
            keys[r.version_key] = (keys[r.version_key] or 0) + 1
        end
        conn:close()

        -- Todos os 11 clones presentes, sem duplicar.
        assert.are_equal(N, #cods)
        for i = 1, N do
            assert.is_true(contains(cods, "C-" .. i))
        end
        -- Row antiga do target substituída.
        assert.is_false(contains(cods, "OLD-1"))
        -- Um único version_key.
        local nkeys = 0
        for _ in pairs(keys) do nkeys = nkeys + 1 end
        assert.are_equal(1, nkeys)
        assert.is_not_nil(keys["batch-vk"])
    end)
end)

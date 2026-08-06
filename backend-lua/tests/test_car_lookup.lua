-- test_car_lookup.lua — CAR lookup via SQLite RTree (car.db temporário + fixture)
local env = require("app.env")
local sqlite3 = require("lsqlite3")

local tmp_car_db = "./yvy_car_test_" .. tostring(os.time()) .. ".db"
env.set("CAR_DB_PATH", tmp_car_db)

local FIXTURE = "./tests/fixtures/car_sample.json"

-- Build car.db a partir da fixture (mesmo caminho do import de produção)
local car_import = require("app.car_import")
local build_ok, build_err = pcall(function()
    local conn = sqlite3.open(tmp_car_db)
    conn:exec("PRAGMA journal_mode=WAL")
    car_import.create_schema(conn)
    local n = car_import.import_file(conn, FIXTURE)
    if n ~= 3 then error("fixture import should insert 3 imóveis, got " .. tostring(n)) end
    conn:close()
end)

package.loaded["app.lookups.car_lookup"] = nil
local car = require("app.lookups.car_lookup")

describe("car_lookup", function()
    setup(function()
        if not build_ok then error("car.db fixture build failed: " .. tostring(build_err)) end
        car.load_car()
    end)

    teardown(function()
        os.remove(tmp_car_db)
        os.remove(tmp_car_db .. "-wal")
        os.remove(tmp_car_db .. "-shm")
    end)

    it("count() retorna os imóveis importados", function()
        assert.are_equal(3, car.count())
    end)

    it("classifica ponto dentro de imóvel único", function()
        local r = car.classify_point(-54.5, -12.5)  -- dentro de MT-1
        assert.is_not_nil(r)
        assert.are_equal("MT-1", r.id)
        assert.are_equal("MT", r.uf)
        assert.are_equal("Municipio C", r.name)
    end)

    it("sobreposição → escolhe o de MAIOR área", function()
        -- (-60.5, -10.5) está dentro de RO-1 (area 100) E RO-2 (area 500)
        local r = car.classify_point(-60.5, -10.5)
        assert.is_not_nil(r)
        assert.are_equal("RO-2", r.id)
    end)

    it("ponto dentro do menor imóvel sobreposto também acha o maior", function()
        -- dentro de RO-1 e RO-2 → ainda RO-2 (maior área)
        local r = car.classify_point(-60.2, -10.2)
        assert.are_equal("RO-2", r.id)
    end)

    it("ponto fora de todos → nil", function()
        assert.is_nil(car.classify_point(-70.0, -5.0))
        assert.is_nil(car.classify_point(0.0, 0.0))
    end)

    it("is_private reflete classify_point", function()
        assert.is_true(car.is_private(-54.5, -12.5))
        assert.is_false(car.is_private(-70.0, -5.0))
    end)
end)

describe("car_import multi-arquivo (ids sem colisão)", function()
    local mf_db = "./yvy_car_multi_" .. tostring(os.time()) .. ".db"
    local second_file = "./yvy_car_second_" .. tostring(os.time()) .. ".json"

    local function write_second_fixture()
        local json = [==[
{"type":"FeatureCollection","features":[
  {"type":"Feature","properties":{"cod_imovel":"XX-1","uf":"XX","municipio":"M1","area":900},"geometry":{"type":"Polygon","coordinates":[[[-58.0,-13.0],[-56.0,-13.0],[-56.0,-11.0],[-58.0,-11.0],[-58.0,-13.0]]]}},
  {"type":"Feature","properties":{"cod_imovel":"XX-2","uf":"XX","municipio":"M2","area":700},"geometry":{"type":"Polygon","coordinates":[[[-60.0,-15.0],[-59.0,-15.0],[-59.0,-14.0],[-60.0,-14.0],[-60.0,-15.0]]]}}
]}
]==]
        local f = io.open(second_file, "w")
        f:write(json)
        f:close()
    end

    it("importa 2 arquivos sem colidir ids e sem rtree órfão", function()
        write_second_fixture()
        local conn = sqlite3.open(mf_db)
        conn:exec("PRAGMA journal_mode=WAL")
        car_import.create_schema(conn)

        local n1 = car_import.import_file(conn, FIXTURE, 0)
        assert.are_equal(3, n1)
        local n2 = car_import.import_file(conn, second_file, n1)
        assert.are_equal(2, n2)

        local data_n, rtree_n = 0, 0
        for r in conn:nrows("SELECT COUNT(*) AS n FROM car_data") do data_n = r.n end
        for r in conn:nrows("SELECT COUNT(*) AS n FROM car_rtree") do rtree_n = r.n end
        conn:close()
        assert.are_equal(5, data_n)
        assert.are_equal(5, rtree_n, "rtree não deve ter órfãos (car_data == car_rtree)")
    end)

    teardown(function()
        os.remove(mf_db)
        os.remove(mf_db .. "-wal")
        os.remove(mf_db .. "-shm")
        os.remove(second_file)
    end)
end)

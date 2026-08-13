-- test_sinaflor_lookup.lua — Sinaflor authorized-burn lookup (ASV/AUTESP)
local env = require("app.env")
local sqlite3 = require("lsqlite3")

local tmp_db = "./yvy_sinaflor_test_" .. tostring(os.time()) .. ".db"
env.set("SINAFLOR_DB_PATH", tmp_db)

-- Fixture com o mesmo schema do scripts/data/download_sinaflor_auth.py
local function build_fixture()
    local conn = sqlite3.open(tmp_db)
    conn:exec([[CREATE TABLE sinaflor_auth (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        cod_imovel TEXT NOT NULL,
        nro_autorizacao TEXT,
        modo TEXT,
        data_inicio TEXT,
        data_fim TEXT,
        uf TEXT,
        municipio TEXT,
        situacao TEXT,
        lat REAL,
        lon REAL
    );]])
    local insert = conn:prepare([[INSERT INTO sinaflor_auth
        (cod_imovel, nro_autorizacao, modo, data_inicio, data_fim, uf,
         municipio, situacao, lat, lon)
        VALUES (?,?,?,?,?,?,?,?,?,?)]])
    local function add(cod, nro, modo, ini, fim, uf)
        insert:bind(1, cod)
        insert:bind(2, nro)
        insert:bind(3, modo)
        insert:bind(4, ini)
        insert:bind(5, fim)
        insert:bind(6, uf)
        insert:bind(7, "")
        insert:bind(8, "")
        insert:bind(9, nil)
        insert:bind(10, nil)
        insert:step()
        insert:reset()
    end
    -- MT-1: uma janela ativa em 2026-03-01
    add("MT-1", "ASV-1", "ASV", "2026-01-01", "2026-12-31", "MT")
    -- MT-2: duas janelas — a antiga e a ativa; a ativa é a de data_inicio mais recente
    add("MT-2", "ASV-OLD", "ASV", "2025-01-01", "2025-12-31", "MT")
    add("MT-2", "ASV-2", "ASV", "2026-01-01", "2026-12-31", "MT")
    -- MT-5: duas janelas ATIVAS na MESMA data (regressão: best.inicio era nil
    -- e a 2ª janela ativa crashava com "attempt to compare nil with string")
    add("MT-5", "ASV-5A", "ASV", "2026-01-01", "2026-12-31", "MT")
    add("MT-5", "ASV-5B", "ASV", "2026-06-01", "2026-12-31", "MT")
    -- MT-3: janela passada (fora da data do foco)
    add("MT-3", "ASV-3", "ASV", "2025-01-01", "2025-06-30", "MT")
    -- MT-4: data_fim aberta
    add("MT-4", "AUT-4", "AUTESP", "2026-01-01", "9999-12-31", "MT")
    insert:finalize()
    conn:close()
end

local build_ok, build_err = pcall(build_fixture)

package.loaded["app.lookups.sinaflor_lookup"] = nil
local sinaflor = require("app.lookups.sinaflor_lookup")

describe("sinaflor_lookup", function()
    setup(function()
        if not build_ok then error("fixture build failed: " .. tostring(build_err)) end
        sinaflor.load_sinaflor()
    end)

    teardown(function()
        os.remove(tmp_db)
    end)

    it("count() retorna as autorizações", function()
        assert.are_equal(7, sinaflor.count())
    end)

    it("is_loaded() true após load", function()
        assert.is_true(sinaflor.is_loaded())
    end)

    it("authorized dentro da janela → objeto da autorização", function()
        local a = sinaflor.authorized({id = "MT-1", name = "F", uf = "MT"}, "2026-03-01")
        assert.is_not_nil(a)
        assert.are_equal("ASV-1", a.nro)
        assert.are_equal("ASV", a.modo)
        assert.are_equal("2026-01-01", a.data_inicio)
        assert.are_equal("2026-12-31", a.data_fim)
    end)

    it("authorized fora da janela → nil", function()
        assert.is_nil(sinaflor.authorized({id = "MT-3", name = "F", uf = "MT"}, "2026-03-01"))
    end)

    it("CAR sem autorização → nil", function()
        assert.is_nil(sinaflor.authorized({id = "SP-999", name = "F", uf = "SP"}, "2026-03-01"))
    end)

    it("múltiplas janelas → a ativa com data_inicio mais recente (determinístico)", function()
        local a = sinaflor.authorized({id = "MT-2", name = "F", uf = "MT"}, "2026-03-01")
        assert.are_equal("ASV-2", a.nro)
    end)

    it("2+ janelas ativas na mesma data não crasha (regressão best.inicio nil)", function()
        -- MT-5 tem duas janelas ativas em 2026-07-01; antes do fix, a 2ª
        -- comparação `w.inicio > best.inicio` crashava (best.inicio era nil).
        local a = sinaflor.authorized({id = "MT-5", name = "F", uf = "MT"}, "2026-07-01")
        assert.is_not_nil(a)
        -- A mais recente (data_inicio 2026-06-01) vence.
        assert.are_equal("ASV-5B", a.nro)
    end)

    it("data_fim aberta (9999-12-31) cobre a data do foco", function()
        local a = sinaflor.authorized({id = "MT-4", name = "F", uf = "MT"}, "2026-03-01")
        assert.are_equal("AUT-4", a.nro)
    end)

    it("chave normalizada para UPPERCASE (id lowercase casa)", function()
        local a = sinaflor.authorized({id = "mt-1", name = "F", uf = "MT"}, "2026-03-01")
        assert.are_equal("ASV-1", a.nro)
    end)

    it("car_prop não-tabela ou id vazio → nil (nil-safe)", function()
        assert.is_nil(sinaflor.authorized("MT-1", "2026-03-01"))
        assert.is_nil(sinaflor.authorized({id = "", name = "F"}, "2026-03-01"))
        assert.is_nil(sinaflor.authorized({id = "MT-1", name = "F"}, nil))
    end)

    it("hook() retorna fn que devolve auth|false", function()
        local fn = sinaflor.hook()
        assert.is_function(fn)
        local a = fn({id = "MT-1", name = "F", uf = "MT"}, "2026-03-01")
        assert.are_equal("ASV-1", a.nro)
        assert.is_false(fn({id = "MT-3", name = "F", uf = "MT"}, "2026-03-01"))
    end)
end)

-- DB ausente → não derruba (módulo re-requerido com SINAFLOR_DB_PATH inválido;
-- padrão test_car_lookup.lua: env.set + package.loaded[nil] + re-require)
describe("sinaflor_lookup sem DB", function()
    local missing_db = "./yvy_sinaflor_missing_" .. tostring(os.time()) .. ".db"
    env.set("SINAFLOR_DB_PATH", missing_db)
    package.loaded["app.lookups.sinaflor_lookup"] = nil
    local sinaflor2 = require("app.lookups.sinaflor_lookup")

    it("load_sinaflor não derruba; is_loaded false; count 0", function()
        assert.has_no.errors(function() sinaflor2.load_sinaflor() end)
        assert.is_false(sinaflor2.is_loaded())
        assert.are_equal(0, sinaflor2.count())
    end)

    it("hook retorna false sem DB", function()
        local fn = sinaflor2.hook()
        assert.is_false(fn({id = "MT-1", name = "F", uf = "MT"}, "2026-03-01"))
    end)

    teardown(function()
        os.remove(missing_db)
    end)
end)

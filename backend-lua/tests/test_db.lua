-- test_db.lua — Tests for db.lua (SQLite + JSONB schema)
-- Uses in-memory SQLite database

local env = require("app.env")
local sqlite3 = require("lsqlite3")
local utils   = require("app.utils")

-- Override DB_PATH to use temp file for tests
local test_db_path = "./yvy_test_" .. tostring(os.time()) .. ".db"
env.set("SQLITE_PATH", test_db_path)
package.loaded["app.db"] = nil
local db_mod  = require("app.db")

describe("db", function()
    setup(function()
        -- Initialize test database
        db_mod.init_db()
    end)

    teardown(function()
        db_mod.close_db()
        os.remove(test_db_path)
    end)

    describe("init_db", function()
        it("creates all tables", function()
            local db = sqlite3.open(test_db_path)
            local tables = {}
            local stmt = db:prepare("SELECT name FROM sqlite_master WHERE type='table'")
            for row in stmt:rows() do
                tables[row[1] or ""] = true
            end
            stmt:finalize()
            db:close()

            assert.is_true(tables["fire_data"])
            assert.is_true(tables["deforestation_data"])
            assert.is_true(tables["news"])

            -- TerraBrasilis integration tables (plan: terrabrasilis-integration, Inc 1)
            assert.is_true(tables["deter_polygons"])
            assert.is_true(tables["deter_car_alerts"])
            assert.is_true(tables["deter_alerts"])
            assert.is_true(tables["ams_risk"])
        end)
    end)

    describe("terrabrasilis schema", function()
        it("creates the bbox expression indexes", function()
            local db = sqlite3.open(test_db_path)
            local idx = {}
            local stmt = db:prepare("SELECT name FROM sqlite_master WHERE type='index'")
            for row in stmt:rows() do
                idx[row[1] or ""] = true
            end
            stmt:finalize()
            db:close()

            assert.is_true(idx["idx_deter_bbox"])
            assert.is_true(idx["idx_ams_bbox"])
            assert.is_true(idx["idx_fire_source"])
        end)

        it("deter_car_alerts enforces the dedup key", function()
            local db = sqlite3.open(test_db_path)
            local sql = [[
                INSERT INTO deter_car_alerts (cod_imovel, classname, view_date, severity, ingested_at)
                VALUES ('BR-RO-1', 'DESMATAMENTO_VEG', '2026-08-06', 'maximo', '2026-08-07T00:00:00Z')
            ]]
            db:exec(sql)
            db:exec(sql)  -- duplicate (cod_imovel, classname, view_date) → no-op
            local n = 0
            for row in db:nrows("SELECT COUNT(*) AS cnt FROM deter_car_alerts") do
                n = tonumber(row.cnt) or 0
            end
            db:close()
            assert.are_equal(1, n)
        end)
    end)

    describe("bulk_upsert_fires / find_fires", function()
        it("inserts and queries fires within bbox", function()
            local docs = {
                {
                    lat = -10.5, lon = -55.0, confidence = "high",
                    acq_date = "2024-01-01", acq_time = "1200",
                    satellite = "NPP", bright_ti4 = 350.0,
                    source = "NASA_FIRMS_VIIRS_SNPP",
                    ingested_at = utils.now_iso(),
                },
                {
                    lat = -11.0, lon = -56.0, confidence = "low",
                    acq_date = "2024-01-02", acq_time = "1300",
                    satellite = "NPP", bright_ti4 = 300.0,
                    source = "NASA_FIRMS_VIIRS_SNPP",
                    ingested_at = utils.now_iso(),
                },
            }

            local count = db_mod.bulk_upsert_fires(docs)
            assert.are_equal(2, count)

            -- Query within bbox
            local results = db_mod.find_fires(-12, -10, -57, -54)
            assert.are_equal(2, #results)

            -- Query outside bbox
            local empty = db_mod.find_fires(-12, -11, -51, -49)
            assert.are_equal(0, #empty)
        end)

        it("upserts on conflict (same lat, lon, acq_date)", function()
            local doc = {
                lat = -15.0, lon = -50.0, confidence = "high",
                acq_date = "2024-03-01", acq_time = "1400",
                satellite = "NPP", bright_ti4 = 400.0,
                source = "NASA_FIRMS_VIIRS_SNPP",
                ingested_at = utils.now_iso(),
            }

            db_mod.bulk_upsert_fires({doc})
            doc.confidence = "low"
            db_mod.bulk_upsert_fires({doc})

            local results = db_mod.find_fires(-16, -14, -51, -49)
            assert.are_equal(1, #results)
            -- Should reflect the update
            assert.are_equal("low", results[1].confidence)
        end)

        it("persists and returns fire_type/frp/daynight", function()
            local doc = {
                lat = -17.0, lon = -53.0, confidence = "nominal",
                acq_date = "2024-05-10", acq_time = "1500",
                satellite = "NPP", bright_ti4 = 320.0,
                fire_type = "vegetation", frp = 245.3, daynight = "D",
                source = "NASA_FIRMS_VIIRS_SNPP",
                ingested_at = utils.now_iso(),
            }
            db_mod.bulk_upsert_fires({doc})
            local results = db_mod.find_fires(-18, -16, -54, -52)
            assert.are_equal(1, #results)
            assert.are_equal("vegetation", results[1].fire_type)
            assert.are_equal(245.3, results[1].frp)
            assert.are_equal("D", results[1].daynight)
        end)

        it("fire_type/frp/daynight nil-safe quando ausentes", function()
            local doc = {
                lat = -18.0, lon = -45.0, confidence = "high",
                acq_date = "2024-05-11", acq_time = "1600",
                satellite = "NPP", bright_ti4 = 360.0,
                source = "NASA_FIRMS_VIIRS_SNPP",
                ingested_at = utils.now_iso(),
            }
            db_mod.bulk_upsert_fires({doc})
            local results = db_mod.find_fires(-19, -17, -46, -44)
            assert.are_equal(1, #results)
            assert.is_nil(results[1].fire_type)
            assert.is_nil(results[1].frp)
            assert.is_nil(results[1].daynight)
        end)

        it("brazil_only filtra focos fora do Brasil (state NULL ou vazio)", function()
            -- Coordenadas isoladas no RS (região não usada por outros testes)
            -- para não colidir com focos persistentes das suítes anteriores.
            local BBOX = { sw_lat = -31.0, ne_lat = -29.0, sw_lng = -56.0, ne_lng = -52.0 }
            -- Dentro do Brasil (state = RS)
            local br = {
                lat = -30.0, lon = -53.5, confidence = "high",
                acq_date = "2024-06-02", acq_time = "1200",
                satellite = "NPP", bright_ti4 = 350.0, state = "RS",
                source = "NASA_FIRMS_VIIRS_SNPP",
                ingested_at = utils.now_iso(),
            }
            -- Fora: state nil (ingest sem atribuição) — mesma bbox
            local out_null = {
                lat = -30.2, lon = -55.5, confidence = "low",
                acq_date = "2024-06-02", acq_time = "1200",
                satellite = "NPP", bright_ti4 = 300.0,
                source = "NASA_FIRMS_VIIRS_SNPP",
                ingested_at = utils.now_iso(),
            }
            -- Fora: state "" (backfill legado)
            local out_empty = {
                lat = -30.4, lon = -55.0, confidence = "low",
                acq_date = "2024-06-02", acq_time = "1200",
                satellite = "NPP", bright_ti4 = 310.0, state = "",
                source = "NASA_FIRMS_VIIRS_SNPP",
                ingested_at = utils.now_iso(),
            }
            db_mod.bulk_upsert_fires({br, out_null, out_empty})

            -- Sem filtro: os 3 aparecem na bbox
            local all = db_mod.find_fires(BBOX.sw_lat, BBOX.ne_lat, BBOX.sw_lng, BBOX.ne_lng)
            assert.are_equal(3, #all)

            -- Com filtro: só o dentro do Brasil (RS = lat -30.0)
            local only = db_mod.find_fires(BBOX.sw_lat, BBOX.ne_lat, BBOX.sw_lng, BBOX.ne_lng, 10000, true)
            assert.are_equal(1, #only)
            assert.are_equal(-30.0, only[1].lat)
        end)
    end)

    describe("bulk_upsert_news / get_news_page", function()
        it("inserts and paginates news", function()
            local articles = {}
            for i = 1, 5 do
                articles[i] = {
                    url = "https://example.com/article" .. i,
                    title = "Article " .. i,
                    description = "Description " .. i,
                    publishedAt = "2024-0" .. i .. "-01T00:00:00Z",
                    source = {name = "TestSource"},
                    ingested_at = utils.now_iso(),
                }
            end

            local count = db_mod.bulk_upsert_news(articles)
            assert.are_equal(5, count)

            -- Page 1, size 3
            local page1 = db_mod.get_news_page(1, 3, "pt")
            assert.are_equal(3, #page1)

            -- Page 2, size 3
            local page2 = db_mod.get_news_page(2, 3, "pt")
            assert.are_equal(2, #page2)
        end)

        it("normalizes dates and keeps newest items first", function()
            local articles = {
                {
                    url = "https://example.com/article-newest",
                    title = "Newest Article",
                    description = "Newest Description",
                    publishedAt = "Wed, 02 Jan 2099 10:00:00 GMT",
                    source = {name = "TestSource"},
                    ingested_at = "2099-01-02T10:00:00Z",
                },
                {
                    url = "https://example.com/article-mid",
                    title = "Mid Article",
                    description = "Mid Description",
                    publishedAt = "2099-01-01T23:00:00-03:00",
                    source = {name = "TestSource"},
                    ingested_at = "2099-01-02T01:00:00Z",
                },
                {
                    url = "https://example.com/article-fallback",
                    title = "Fallback Article",
                    description = "Fallback Description",
                    publishedAt = "not-a-date",
                    source = {name = "TestSource"},
                    ingested_at = "2098-12-31T23:59:59Z",
                },
            }

            local count = db_mod.bulk_upsert_news(articles)
            assert.are_equal(3, count)

            local page = db_mod.get_news_page(1, 3, "pt")
            assert.are_equal(3, #page)
            assert.are_equal("https://example.com/article-newest", page[1].url)
            assert.are_equal("2099-01-02T10:00:00Z", page[1].publishedAt)
            assert.are_equal("https://example.com/article-mid", page[2].url)
            assert.are_equal("2099-01-02T02:00:00Z", page[2].publishedAt)
            assert.are_equal("https://example.com/article-fallback", page[3].url)
            assert.are_equal("2098-12-31T23:59:59Z", page[3].publishedAt)
        end)
    end)

    describe("get_stats", function()
        it("returns counts for all tables", function()
            local stats = db_mod.get_stats()
            assert.is_not_nil(stats.fires)
            assert.is_not_nil(stats.deforestation)
            assert.is_not_nil(stats.news)
        end)
    end)

    describe("prune_old_fires", function()
        it("deletes old fire records", function()
            -- Insert an old fire
            local old_doc = {
                lat = -20.0, lon = -60.0, confidence = "low",
                acq_date = "2020-01-01", acq_time = "0000",
                satellite = "NPP", bright_ti4 = 200.0,
                source = "NASA_FIRMS_VIIRS_SNPP",
                ingested_at = "2020-01-01T00:00:00Z",
            }
            db_mod.bulk_upsert_fires({old_doc})

            local deleted = db_mod.prune_old_fires(90)
            assert.is_true(deleted >= 1)
        end)
    end)

    describe("fire nature classification", function()
        it("init_db cria colunas de nature (SCHEMA novo)", function()
            local db = sqlite3.open(test_db_path)
            local cols = {}
            local stmt = db:prepare("PRAGMA table_info(fire_data)")
            for row in stmt:rows() do
                cols[row[2] or row["name"] or ""] = true
            end
            stmt:finalize()
            db:close()
            assert.is_true(cols["nature"])
            assert.is_true(cols["nature_evidence"])
            assert.is_true(cols["nature_at"])
            assert.is_true(cols["nature_version"])
        end)

        it("update_fire_natures round-trip (batch, JSONB evidence + version)", function()
            local doc = {
                lat = -21.0, lon = -62.0, confidence = "high",
                acq_date = "2024-06-01", acq_time = "1200",
                satellite = "NPP", bright_ti4 = 350.0,
                source = "NASA_FIRMS_VIIRS_SNPP",
                ingested_at = utils.now_iso(),
            }
            db_mod.bulk_upsert_fires({doc})

            local db = sqlite3.open(test_db_path)
            local id
            for row in db:nrows("SELECT id FROM fire_data WHERE lat=-21.0 AND lon=-62.0 AND acq_date='2024-06-01'") do
                id = tonumber(row.id)
            end
            db:close()
            assert.is_not_nil(id)

            local n = db_mod.update_fire_natures({{id = id, nature = "crime", evidence = {moratorium = true}, at = utils.now_iso()}}, 1)
            assert.are_equal(1, n)

            local db2 = sqlite3.open(test_db_path)
            local nature, version, ev
            local stmt2 = db2:prepare("SELECT nature, nature_version, json(nature_evidence) AS ev FROM fire_data WHERE id=?")
            stmt2:bind(1, id)
            for r in stmt2:nrows() do
                nature = r.nature
                version = r.nature_version
                ev = r.ev
            end
            stmt2:finalize()
            db2:close()
            assert.are_equal("crime", nature)
            assert.are_equal(1, version)
            assert.is_not_nil(ev and ev:find("true"))
        end)

        it("iter_fires_for_classification: min_version 0 exclui classificados; >0 inclui reclassificáveis", function()
            local db = sqlite3.open(test_db_path)
            local id
            for row in db:nrows("SELECT id FROM fire_data WHERE lat=-21.0 AND lon=-62.0 AND acq_date='2024-06-01'") do
                id = tonumber(row.id)
            end
            db:close()
            assert.is_not_nil(id)

            local it0 = db_mod.iter_fires_for_classification(10000, 0)
            local found0 = false
            for _, r in ipairs(it0) do if r.id == id then found0 = true end end
            assert.is_false(found0, "classificado não deve aparecer com min_version=0")

            local it2 = db_mod.iter_fires_for_classification(10000, 2)
            local found2 = false
            for _, r in ipairs(it2) do if r.id == id then found2 = true end end
            assert.is_true(found2, "reclassificável deve aparecer com min_version=2")
        end)

        it("count_fires_by_nature agrupa (incl. NULL → unclassified)", function()
            local doc = {
                lat = -22.5, lon = -63.0, confidence = "nominal",
                acq_date = "2020-01-02", acq_time = "1200",
                satellite = "NPP", bright_ti4 = 330.0,
                source = "NASA_FIRMS_VIIRS_SNPP",
                ingested_at = utils.now_iso(),
            }
            db_mod.bulk_upsert_fires({doc})

            local classes, total = db_mod.count_fires_by_nature(9999)
            assert.is_number(total)
            assert.is_true(total >= 2)
            assert.is_true(classes.unclassified >= 1, "deve haver foco sem classificação")
            assert.is_true(classes.crime >= 1, "o foco classificado como crime deve contar")
        end)

        it("bulk_upsert_fires NÃO apaga nature (coluna escalar)", function()
            -- Re-upsert do mesmo foco classificado (mesmo lat/lon/acq_date)
            local doc = {
                lat = -21.0, lon = -62.0, confidence = "high",
                acq_date = "2024-06-01", acq_time = "1200",
                satellite = "NPP", bright_ti4 = 350.0,
                source = "NASA_FIRMS_VIIRS_SNPP",
                ingested_at = utils.now_iso(),
            }
            db_mod.bulk_upsert_fires({doc})

            local db = sqlite3.open(test_db_path)
            local nature
            local stmt = db:prepare("SELECT nature FROM fire_data WHERE lat=-21.0 AND lon=-62.0 AND acq_date='2024-06-01'")
            for r in stmt:nrows() do nature = r.nature end
            stmt:finalize()
            db:close()
            assert.are_equal("crime", nature)
        end)
    end)
end)

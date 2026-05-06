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
end)

-- test_utils.lua — Tests for utils.lua

local utils = require("app.utils")

describe("utils", function()
    describe("encode_jsonb / decode_jsonb", function()
        it("round-trips a simple table", function()
            local input = {confidence = "high", acq_time = "1200"}
            local encoded = utils.encode_jsonb(input)
            local decoded = utils.decode_jsonb(encoded)
            assert.are_equal("high", decoded.confidence)
            assert.are_equal("1200", decoded.acq_time)
        end)

        it("handles nil / empty", function()
            local decoded = utils.decode_jsonb(nil)
            local count = 0
            for _ in pairs(decoded) do count = count + 1 end
            assert.are_equal(0, count)  -- empty table
        end)

        it("handles empty string", function()
            local decoded = utils.decode_jsonb("")
            local count = 0
            for _ in pairs(decoded) do count = count + 1 end
            assert.are_equal(0, count)
        end)
    end)

    describe("parse_csv", function()
        it("parses FIRMS CSV format", function()
            local csv = [[latitude,longitude,confidence,acq_date,acq_time
-10.5,-55.0,high,2024-01-01,1200
-11.0,-56.0,low,2024-01-02,1300]]
            local rows = utils.parse_csv(csv)
            assert.are_equal(2, #rows)
            assert.are_equal("-10.5", rows[1].latitude)
            assert.are_equal("high", rows[1].confidence)
        end)

        it("handles empty input", function()
            local rows = utils.parse_csv("")
            assert.are_equal(0, #rows)
        end)

        it("handles single line (header only)", function()
            local rows = utils.parse_csv("a,b,c")
            assert.are_equal(0, #rows)
        end)
    end)

    describe("now_iso", function()
        it("returns a valid ISO-8601 string", function()
            local iso = utils.now_iso()
            assert.is_not_nil(iso:match("%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ"))
        end)
    end)

    describe("normalize_news_date", function()
        it("normalizes common RSS date formats to UTC", function()
            assert.are_equal("2026-05-06T10:30:00Z", utils.normalize_news_date("Tue, 06 May 2026 10:30:00 GMT"))
            assert.are_equal("2026-05-06T13:30:00Z", utils.normalize_news_date("2026-05-06T10:30:00-03:00"))
        end)

        it("falls back to a known timestamp when raw input is invalid", function()
            assert.are_equal("2026-05-06T10:30:00Z", utils.normalize_news_date("not-a-date", "2026-05-06T10:30:00Z"))
        end)
    end)

    describe("hours_between", function()
        it("computes hours between two ISO strings", function()
            local h = utils.hours_between("2024-01-01T00:00:00Z", "2024-01-01T06:00:00Z")
            assert.are_equal(6, h)
        end)
    end)

    describe("trim", function()
        it("trims whitespace", function()
            assert.are_equal("hello", utils.trim("  hello  "))
        end)
    end)

    describe("starts_with", function()
        it("detects prefix", function()
            assert.is_true(utils.starts_with("Bearer abc123", "Bearer "))
            assert.is_false(utils.starts_with("abc", "xyz"))
        end)
    end)

    describe("strip_boilerplate", function()
        it("strips PT RSS boilerplate", function()
            assert.are_equal("Incêndios avançam na Amazônia.",
                utils.strip_boilerplate("Incêndios avançam na Amazônia. O post Incêndios avançam na Amazônia apareceu primeiro em InfoAmazônia."))
        end)

        it("strips EN RSS boilerplate", function()
            assert.are_equal("Fires advance in the Amazon.",
                utils.strip_boilerplate("Fires advance in the Amazon. The post Fires advance in the Amazon appeared first on Mongabay."))
        end)

        it("preserves text after the boilerplate", function()
            assert.are_equal("Extra info",
                utils.strip_boilerplate("The post X appeared first on Y. Extra info"))
        end)

        it("is a no-op on clean descriptions", function()
            assert.are_equal("Uma matéria normal sobre o Cerrado.",
                utils.strip_boilerplate("Uma matéria normal sobre o Cerrado."))
        end)

        it("handles nil, empty and non-string", function()
            assert.is_nil(utils.strip_boilerplate(nil))
            assert.are_equal("", utils.strip_boilerplate(""))
            assert.are_equal(42, utils.strip_boilerplate(42))
        end)

        it("strips 'appeared first in' variant", function()
            assert.are_equal("Smart toilets use water.",
                utils.strip_boilerplate("Smart toilets use water. The post The end of an era: what will replace toilet paper in homes? appeared first in Ratchet Free."))
        end)

        it("strips 'first appeared on' word-order variant", function()
            assert.are_equal("Framework alleges Dell is sabotaging.",
                utils.strip_boilerplate("Framework alleges Dell is sabotaging. The Dell post attempts to affect Framework marketing by sending XPS laptops to influencers first appeared on Edivaldo Blog."))
        end)

        it("strips 'The <Word> post' prefix variant", function()
            assert.are_equal("IPhone Ultra promises.",
                utils.strip_boilerplate("IPhone Ultra promises. The Apple post may launch iPhone Ultra in 2026 first appeared on Edivaldo Blog."))
        end)

        it("strips '<Owner> post' prefix variant", function()
            assert.are_equal("Petrobras began drilling the seabed.",
                utils.strip_boilerplate("Petrobras began drilling the seabed. Petrobras' Plan post excludes the rescue of manatees in the new oil frontier appeared first on Environmental News."))
        end)

        it("handles punctuation right after 'post' (comma)", function()
            assert.are_equal("In the municipality with the largest quilombola population in Brazil.",
                utils.strip_boilerplate("In the municipality with the largest quilombola population in Brazil. The Alcântara post, a quilombo under rockets first appeared in Amazônia Real ."))
        end)

        it("strips truncated suffix (no source)", function()
            assert.are_equal("An investigation into wildlife trafficking.",
                utils.strip_boilerplate("An investigation into wildlife trafficking. The post Investigation into wildlife trafficking aims at a link with a mega zoo in India appeared first on"))
            assert.are_equal("The golden lion tamarin is in danger.",
                utils.strip_boilerplate("The golden lion tamarin is in danger. The post Golden Lion Tamarin comes into the crosshairs appeared first"))
            assert.are_equal("Morgan Stanley sees the company as a favorite.",
                utils.strip_boilerplate("Morgan Stanley sees the company as a favorite. The post Second phase of UniversalizaSP can reach $100 billion appeared first…"))
        end)

        it("strips PT truncated suffix (ellipsis)", function()
            assert.are_equal("Sempre guardo uma rolha de vinho na fruteira.",
                utils.strip_boilerplate("Sempre guardo uma rolha de vinho na fruteira. O post Sempre guardo uma rolha de vinho na fruteira. Esse método é infalível apareceu primeiro …"))
        end)

        it("strips 'This content was first published on' attribution", function()
            assert.are_equal("Um novo projeto de lei quer alavancar o papel do Brasil na corrida global dos minerais críticos.",
                utils.strip_boilerplate("Um novo projeto de lei quer alavancar o papel do Brasil na corrida global dos minerais críticos. This content was first published on InfoAmazonia , at PL de minerais críticos avança sem considerar riscos"))
        end)
    end)
end)

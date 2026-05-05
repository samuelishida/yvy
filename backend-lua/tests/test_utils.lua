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
            assert.are_equal(0, #vim.tbl_keys(decoded))  -- empty table
        end)

        it("handles empty string", function()
            local decoded = utils.decode_jsonb("")
            assert.are_equal(0, #vim.tbl_keys(decoded))
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
end)

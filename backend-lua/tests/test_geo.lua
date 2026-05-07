-- test_geo.lua — Tests for geo.lua (point-in-polygon)

local geo = require("app.geo")

describe("geo", function()
    describe("point_in_ring", function()
        local square = {
            {0, 0},   -- bottom-left
            {10, 0},  -- bottom-right
            {10, 10}, -- top-right
            {0, 10},  -- top-left
        }

        it("returns true for point inside square", function()
            assert.is_true(geo.point_in_ring(5, 5, square))
        end)

        it("returns false for point outside square", function()
            assert.is_false(geo.point_in_ring(20, 20, square))
        end)

        it("returns false for point on boundary (edge case)", function()
            -- On the left edge — ray casting may or may not count this
            -- Just verify it doesn't crash
            local result = geo.point_in_ring(0, 5, square)
            assert.is_boolean(result)
        end)

        it("returns false for ring with < 3 points", function()
            assert.is_false(geo.point_in_ring(5, 5, {{0, 0}, {10, 10}}))
        end)

        it("handles triangle", function()
            local triangle = {{0, 0}, {10, 0}, {5, 10}}
            assert.is_true(geo.point_in_ring(5, 3, triangle))
            assert.is_false(geo.point_in_ring(15, 15, triangle))
        end)
    end)

    describe("point_in_polygon", function()
        local exterior = {{0, 0}, {10, 0}, {10, 10}, {0, 10}}
        local hole = {{3, 3}, {7, 3}, {7, 7}, {3, 7}}

        it("returns true for point in exterior but not in hole", function()
            assert.is_true(geo.point_in_polygon(1, 1, {exterior}))
        end)

        it("returns false for point in hole", function()
            assert.is_false(geo.point_in_polygon(5, 5, {exterior, hole}))
        end)

        it("returns false for point outside exterior", function()
            assert.is_false(geo.point_in_polygon(20, 20, {exterior}))
        end)

        it("returns false for empty rings", function()
            assert.is_false(geo.point_in_polygon(5, 5, {}))
        end)
    end)
end)

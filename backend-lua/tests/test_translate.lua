-- test_translate.lua — Tests for translate.lua

local translate = require("app.translate")

describe("translate", function()
    describe("is_mymemory_warning", function()
        it("detects MyMemory quota warning", function()
            local warning = "MYMEMORY WARNING: YOU USED ALL AVAILABLE FREE TRANSLATIONS FOR TODAY. NEXT AVAILABLE IN 06 HOURS"
            assert.is_true(translate.is_mymemory_warning(warning))
        end)

        it("returns false for normal text", function()
            assert.is_false(translate.is_mymemory_warning("This is a normal translation"))
        end)

        it("returns false for nil", function()
            assert.is_false(translate.is_mymemory_warning(nil))
        end)

        it("returns false for empty string", function()
            assert.is_false(translate.is_mymemory_warning(""))
        end)
    end)

    describe("new_chain", function()
        it("creates a TranslatorChain instance", function()
            local chain = translate.new_chain()
            assert.is_not_nil(chain)
            assert.is_function(chain.translate)
        end)

        it("returns empty string for empty input", function()
            local chain = translate.new_chain()
            local result = chain:translate("", "pt", "en")
            assert.are_equal("", result)
        end)
    end)
end)

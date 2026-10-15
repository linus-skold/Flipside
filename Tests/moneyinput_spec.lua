local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

describe("Kit money input", function()
    local Kit

    before_each(function()
        mock.reset()
        local ns = {}
        for _, name in ipairs({ "Theme", "Widgets", "MoneyInput" }) do
            assert(loadfile(manifest.path(name)))("Flipside", ns)
        end
        Kit = ns.Kit
    end)

    after_each(function()
        mock.teardown()
    end)

    local function fill(input, gold, silver, copper)
        input.gold:SetText(gold)
        input.silver:SetText(silver)
        input.copper:SetText(copper)
    end

    describe("split and join", function()
        it("splits copper into gold, silver and copper", function()
            assert.are.same({ 1, 20, 5 }, { Kit.SplitMoney(12005) })
            assert.are.same({ 0, 1, 19 }, { Kit.SplitMoney(119) })
            assert.are.same({ 0, 0, 0 }, { Kit.SplitMoney(0) })
            assert.are.same({ 0, 0, 0 }, { Kit.SplitMoney(nil) })
            assert.are.same({ 12345, 67, 89 }, { Kit.SplitMoney(123456789) })
        end)

        it("joins the parts, and an empty or bad part counts as 0", function()
            assert.are.equal(12005, Kit.JoinMoney(1, 20, 5))
            assert.are.equal(12005, Kit.JoinMoney("1", "20", "5"))
            assert.are.equal(10000, Kit.JoinMoney("1", "", ""))
            assert.are.equal(2000, Kit.JoinMoney("", "20", nil))
            assert.are.equal(7, Kit.JoinMoney("", "", "7"))
            assert.are.equal(0, Kit.JoinMoney("", "", ""))
            assert.are.equal(0, Kit.JoinMoney("x", "-3", "abc"))
        end)

        it("reads back what it splits", function()
            for _, copper in ipairs({ 0, 1, 99, 100, 10001, 123456789 }) do
                assert.are.equal(copper, Kit.JoinMoney(Kit.SplitMoney(copper)))
            end
        end)
    end)

    describe("the input", function()
        it("has a gold, a silver and a copper box, each with a coin icon", function()
            local input = Kit.MoneyInput(CreateFrame("Frame"))
            for _, key in ipairs({ "gold", "silver", "copper" }) do
                assert.is_table(input[key])
                assert.is_true(input[key].numeric)
                assert.is_table(input[key .. "Icon"])
            end
            assert.are.equal("coin-gold", input.goldIcon.atlas)
            assert.are.equal("coin-silver", input.silverIcon.atlas)
            assert.are.equal("coin-copper", input.copperIcon.atlas)
            assert.are.equal(7, input.gold.maxLetters)
            assert.are.equal(2, input.silver.maxLetters)
            assert.are.equal(2, input.copper.maxLetters)
        end)

        it("takes the icons as arguments", function()
            local input = Kit.MoneyInput(CreateFrame("Frame"), { icons = { gold = "a", silver = "b", copper = "c" } })
            assert.are.same({ "a", "b", "c" }, { input.goldIcon.atlas, input.silverIcon.atlas, input.copperIcon.atlas })
        end)

        it("gives the copper of the three boxes", function()
            local input = Kit.MoneyInput(CreateFrame("Frame"))
            fill(input, "1", "20", "5")
            assert.are.equal(12005, input:GetCopper())
        end)

        it("counts empty boxes as 0", function()
            local input = Kit.MoneyInput(CreateFrame("Frame"))
            assert.are.equal(0, input:GetCopper())
            fill(input, "", "3", "")
            assert.are.equal(300, input:GetCopper())
            fill(input, "2", "", "")
            assert.are.equal(20000, input:GetCopper())
            fill(input, "", "", "9")
            assert.are.equal(9, input:GetCopper())
        end)

        it("shows an amount and leaves a part of 0 empty", function()
            local input = Kit.MoneyInput(CreateFrame("Frame"))
            input:SetCopper(10005)
            assert.are.same({ "1", "", "5" }, { input.gold:GetText(), input.silver:GetText(), input.copper:GetText() })
            input:SetCopper(119)
            assert.are.same({ "", "1", "19" }, { input.gold:GetText(), input.silver:GetText(), input.copper:GetText() })
            assert.are.equal(119, input:GetCopper())
        end)

        it("clears all boxes for nil", function()
            local input = Kit.MoneyInput(CreateFrame("Frame"))
            input:SetCopper(5000)
            input:SetCopper(nil)
            assert.are.same({ "", "", "" }, { input.gold:GetText(), input.silver:GetText(), input.copper:GetText() })
            assert.are.equal(0, input:GetCopper())
        end)

        it("calls onChange with the copper when the user types, and not on SetCopper", function()
            local seen = {}
            local input = Kit.MoneyInput(CreateFrame("Frame"), { onChange = function(copper)
                seen[#seen + 1] = copper
            end })
            fill(input, "1", "", "")
            input.gold.scripts.OnTextChanged(input.gold)
            fill(input, "1", "2", "3")
            input.copper.scripts.OnTextChanged(input.copper)
            assert.are.same({ 10000, 10203 }, seen)
            input:SetCopper(50)
            assert.are.same({ 10000, 10203 }, seen)
        end)

        it("turns the three boxes on and off", function()
            local input = Kit.MoneyInput(CreateFrame("Frame"))
            input:SetEnabled(false)
            assert.is_false(input.gold.enabled)
            assert.is_false(input.silver.enabled)
            assert.is_false(input.copper.enabled)
            input:SetEnabled(true)
            assert.is_true(input.copper.enabled)
        end)

        it("uses no Flipside name", function()
            local handle = assert(io.open(manifest.path("MoneyInput"), "rb"))
            local source = handle:read("*a")
            handle:close()
            assert.is_nil(source:lower():find("flipside", 1, true))
        end)
    end)
end)

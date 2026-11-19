local manifest = require("Tests.manifest")
local ns = {}
assert(loadfile(manifest.path("CraftListMargin")))("Flipside", ns)
local Margin = ns.CraftListMargin

describe("CraftListMargin", function()
    -- Materials: key "1" (price 100 each) and key "2" (price 50 each). Results: key "9" sells for 1000 each.
    local prices
    local function options(extra)
        local opts = {
            materialPrice = function(material, needed)
                local unit = prices.material[material.key]
                if unit == nil then
                    return nil
                end
                return unit * needed, prices.estimate[material.key]
            end,
            resultPrice = function(result)
                return prices.result[result.key]
            end,
        }
        for name, value in pairs(extra or {}) do
            opts[name] = value
        end
        return opts
    end

    before_each(function()
        prices = { material = { ["1"] = 100, ["2"] = 50 }, estimate = {}, result = { ["9"] = 1000 } }
    end)

    describe("Cut", function()
        it("is 5 percent, rounded half up", function()
            assert.are.equal(50, Margin.Cut(1000))
            assert.are.equal(1, Margin.Cut(10))
            assert.are.equal(0, Margin.Cut(9))
        end)
    end)

    describe("WalkLevels", function()
        local levels = {
            { unitPrice = 10, quantity = 3 },
            { unitPrice = 12, quantity = 5, own = true },
            { unitPrice = 15, quantity = 10 },
        }

        it("takes the cheapest units and part of the last level", function()
            assert.are.equal(20, Margin.WalkLevels(levels, 2))
            assert.are.equal(3 * 10 + 2 * 15, Margin.WalkLevels(levels, 5))
        end)

        it("skips a level that is yours", function()
            assert.are.equal(30 + 10 * 15, Margin.WalkLevels(levels, 13))
        end)

        it("gives nil when the levels hold too few units, or the need is not valid", function()
            assert.is_nil(Margin.WalkLevels(levels, 14))
            assert.is_nil(Margin.WalkLevels({}, 1))
            assert.is_nil(Margin.WalkLevels(nil, 1))
            assert.is_nil(Margin.WalkLevels(levels, 0))
        end)

        it("buys a stack level in whole stacks and counts the units above the need", function()
            local stacks = {
                { unitPrice = 5, stackSize = 5, stacks = 3, quantity = 15, own = true },
                { unitPrice = 10, stackSize = 5, stacks = 2, quantity = 10 },
                { unitPrice = 12, stackSize = 20, stacks = 1, quantity = 20 },
            }
            -- 7 units need 2 stacks of 5: 10 units are paid.
            assert.are.equal(10 * 10, Margin.WalkLevels(stacks, 7))
            -- 12 units: the 2 stacks (10 units), then 1 stack of 20 for the last 2 units.
            assert.are.equal(10 * 10 + 20 * 12, Margin.WalkLevels(stacks, 12))
            -- The level holds at most its stacks.
            assert.is_nil(Margin.WalkLevels(stacks, 31))
            assert.are.equal(10 * 10 + 20 * 12, Margin.WalkLevels(stacks, 30))
        end)

        it("prices a Forever item level of 40 items at 449 each as 449 for each item", function()
            local level = { { unitPrice = 449, stackSize = 40, stacks = 1, quantity = 40 } }
            assert.are.equal(449 * 40, Margin.WalkLevels(level, 40))
        end)
    end)

    describe("Compute", function()
        local list
        before_each(function()
            list = {
                materials = { { key = "1", itemID = 1, count = 4 }, { key = "2", itemID = 2 } },
                results = { { key = "9", itemID = 9, min = 1, max = 2 } },
            }
        end)

        it("sums the material cost; a material with no count needs 1 unit", function()
            local out = Margin.Compute(list, options())
            assert.are.equal(4, out.materials[1].needed)
            assert.are.equal(400, out.materials[1].total)
            assert.are.equal(1, out.materials[2].needed)
            assert.are.equal(450, out.cost)
            assert.is_true(out.costKnown)
            assert.is_false(out.estimate)
        end)

        it("values the results after the cut at min, average and max yield", function()
            local out = Margin.Compute(list, options())
            assert.are.equal(950, out.results[1].net.min)
            assert.are.equal(1.5, out.results[1].avg)
            assert.are.equal(1425, out.results[1].net.avg)
            assert.are.equal(1900, out.results[1].net.max)
            assert.same({ min = 950, avg = 1425, max = 1900 }, out.value)
        end)

        it("gives the margin and the margin percent", function()
            local out = Margin.Compute(list, options())
            assert.same({ min = 500, avg = 975, max = 1450 }, out.margin)
            assert.is_near(500 / 450 * 100, out.percent.min, 0.001)
            assert.is_near(975 / 450 * 100, out.percent.avg, 0.001)
            assert.is_near(1450 / 450 * 100, out.percent.max, 0.001)
        end)

        it("gives a negative margin when the cost is above the value", function()
            prices.result["9"] = 100
            local out = Margin.Compute(list, options())
            assert.is_true(out.margin.min < 0)
            assert.is_true(out.percent.min < 0)
        end)

        it("adds the value of several results", function()
            list.results[2] = { key = "8", itemID = 8, min = 2, max = 5 }
            prices.result["8"] = 200
            local out = Margin.Compute(list, options())
            -- 8: min 2 x 200 = 400 -> 380, avg 3.5 x 200 = 700 -> 665, max 5 x 200 = 1000 -> 950.
            assert.same({ min = 950 + 380, avg = 1425 + 665, max = 1900 + 950 }, out.value)
        end)

        it("scales the materials and the results with the number of crafts", function()
            local out = Margin.Compute(list, options({ crafts = 3 }))
            assert.are.equal(3, out.crafts)
            assert.are.equal(12, out.materials[1].needed)
            assert.are.equal(3, out.materials[2].needed)
            assert.are.equal(1350, out.cost)
            assert.are.equal(3 * 950, out.value.min)
            assert.are.equal(3 * 1900, out.value.max)
        end)

        it("uses 1 craft for a number that is not a whole number above 0", function()
            for _, crafts in ipairs({ 0, -2, 1.5, "3" }) do
                assert.are.equal(1, Margin.Compute(list, options({ crafts = crafts })).crafts)
            end
        end)

        it("marks an estimate and keeps the exact cost for the others", function()
            prices.estimate["2"] = true
            local out = Margin.Compute(list, options())
            assert.is_true(out.estimate)
            assert.is_false(out.materials[1].estimate)
            assert.is_true(out.materials[2].estimate)
            assert.are.equal(450, out.cost)
            assert.is_not_nil(out.margin)
        end)

        it("gives no margin when a material has no price", function()
            prices.material["2"] = nil
            local out = Margin.Compute(list, options())
            assert.is_false(out.costKnown)
            assert.is_nil(out.materials[2].total)
            assert.is_false(out.materials[2].estimate)
            assert.are.equal(400, out.cost)
            assert.is_nil(out.margin)
            assert.is_nil(out.percent)
        end)

        it("gives no margin when a result has no price", function()
            prices.result["9"] = nil
            local out = Margin.Compute(list, options())
            assert.is_false(out.valueKnown)
            assert.is_nil(out.results[1].unit)
            assert.is_nil(out.results[1].net)
            assert.is_nil(out.margin)
        end)

        it("gives a margin but no percent when the cost is 0", function()
            list.materials = {}
            local out = Margin.Compute(list, options())
            assert.are.equal(0, out.cost)
            assert.same({ min = 950, avg = 1425, max = 1900 }, out.margin)
            assert.is_nil(out.percent)
        end)

        it("uses the cut function of the caller", function()
            local out = Margin.Compute(list, options({ cut = function() return 0 end }))
            assert.are.equal(1000, out.value.min)
            assert.are.equal(2000, out.value.max)
        end)

        it("accepts a list with no materials and no results", function()
            local out = Margin.Compute({}, options())
            assert.are.equal(0, out.cost)
            assert.same({}, out.results)
            assert.same({ min = 0, avg = 0, max = 0 }, out.margin)
        end)
    end)

    describe("Compute with the mode oneOf", function()
        local list
        before_each(function()
            -- A: 1-2 for 100 each. B: 2-3 for 1000 each. The materials cost 450.
            prices.result = { ["9"] = 100, ["8"] = 1000 }
            list = {
                materials = { { key = "1", itemID = 1, count = 4 }, { key = "2", itemID = 2 } },
                results = { { key = "9", itemID = 9, name = "A", min = 1, max = 2 },
                    { key = "8", itemID = 8, name = "B", min = 2, max = 3 } },
                resultMode = "oneOf",
            }
        end)

        it("takes the lowest min of one result, the highest max of one result and the mean of the avg", function()
            local out = Margin.Compute(list, options())
            assert.are.equal("oneOf", out.resultMode)
            assert.same({ min = 95, avg = 1258.5, max = 2850 }, out.value)
            assert.same({ min = 1, max = 2 }, out.pick)
            assert.same({ min = -355, avg = 808.5, max = 2400 }, out.margin)
            assert.are.equal("B", out.results[out.pick.max].name)
        end)

        it("names the result that sets the min or the max, whichever it is", function()
            prices.result = { ["9"] = 1000, ["8"] = 100 }
            local out = Margin.Compute(list, options())
            assert.same({ min = 2, max = 1 }, out.pick)
            assert.same({ min = 190, avg = 831, max = 1900 }, out.value)
        end)

        it("scales with the crafts", function()
            local out = Margin.Compute(list, options({ crafts = 2 }))
            assert.same({ min = 190, avg = 2517.5, max = 5700 }, out.value)
            assert.are.equal(900, out.cost)
        end)

        it("gives no value and no margin if a result has no price", function()
            prices.result["8"] = nil
            local out = Margin.Compute(list, options())
            assert.is_false(out.valueKnown)
            assert.is_nil(out.margin)
            assert.is_nil(out.percent)
        end)

        it("keeps the sum of the results in the mode all, and for a list with no mode", function()
            for _, mode in ipairs({ "all", "none" }) do
                list.resultMode = mode ~= "none" and mode or nil
                local out = Margin.Compute(list, options())
                assert.are.equal("all", out.resultMode)
                assert.same({ min = 95 + 1900, avg = 142 + 2375, max = 190 + 2850 }, out.value)
            end
        end)
    end)

    describe("the scan prices", function()
        it("prices the needed units of a material at ScanMarket, as an estimate", function()
            assert.are.equal(1200, (Margin.ScanMaterialPrice({ scanMarket = 300 }, 4)))
            assert.is_nil((Margin.ScanMaterialPrice({ scanMin = 300 }, 4)))
            assert.is_nil((Margin.ScanMaterialPrice(nil, 4)))
        end)

        it("prices a result at ScanRecent, else ScanMarket, else ScanMin, else no price", function()
            assert.are.equal(1200, Margin.ScanResultPrice({ scanRecent = 1200, scanMarket = 1000, scanMin = 800 }))
            assert.are.equal(1000, Margin.ScanResultPrice({ scanMarket = 1000, scanMin = 800 }))
            assert.are.equal(800, Margin.ScanResultPrice({ scanMin = 800 }))
            assert.is_nil(Margin.ScanResultPrice({}))
            assert.is_nil(Margin.ScanResultPrice(nil))
        end)

        it("prices a material at ScanRecent first, else ScanMarket", function()
            assert.are.same({ 1600, true, "latest scan" },
                { Margin.ScanMaterialPrice({ scanRecent = 400, scanMarket = 300 }, 4) })
            assert.are.same({ 1200, true, "14-day average" }, { Margin.ScanMaterialPrice({ scanMarket = 300 }, 4) })
        end)

        it("names the source and the age of a scan price", function()
            assert.are.equal("latest scan, 12 min ago", Margin.PriceSource({ scanAge = 0.2 }, "scanRecent"))
            assert.are.equal("14-day average, 3 h ago", Margin.PriceSource({ scanAge = 3.4 }, "scanMarket"))
            assert.are.equal("lowest listing, 3 d ago", Margin.PriceSource({ scanAge = 80 }, "scanMin"))
            assert.are.equal("latest scan", Margin.PriceSource({}, "scanRecent"))
            assert.is_nil(Margin.PriceSource({}, "other"))
        end)

        it("gives the source of a price in the margin lines", function()
            local out = Margin.Compute({ materials = { { key = "1", itemID = 1 } },
                results = { { key = "2", itemID = 2, min = 1, max = 1 } } }, {
                materialPrice = function()
                    return 100, true, "latest scan"
                end,
                resultPrice = function()
                    return 500, "14-day average"
                end,
            })
            assert.are.equal("latest scan", out.materials[1].source)
            assert.are.equal("14-day average", out.results[1].source)
        end)
    end)
end)

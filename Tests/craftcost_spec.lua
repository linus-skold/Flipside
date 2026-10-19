local manifest = require("Tests.manifest")

describe("CraftCost", function()
    local ns, cost

    local function cut(gross)
        return math.floor(gross * 0.05 + 0.5)
    end

    local function options(reagents, items)
        return {
            reagentPrice = function(id) return reagents[id] end,
            itemPrice = function(id) return items[id] end,
            cut = cut,
        }
    end

    before_each(function()
        ns = {}
        assert(loadfile(manifest.path("CraftCost")))("Flipside", ns)
        cost = ns.CraftCost
    end)

    it("sums the reagent lines", function()
        local recipe = { reagents = { { itemID = 1, count = 2 }, { itemID = 2, count = 3 } }, itemID = 9,
            madeMin = 1, madeMax = 1 }
        local result = cost.Compute(recipe, options({ [1] = 100, [2] = 50 }, { [9] = 1000 }))
        assert.are.equal(350, result.cost)
        assert.are.equal(200, result.lines[1].total)
        assert.are.equal(50, result.lines[2].unit)
        assert.is_false(result.partial)
    end)

    it("marks the cost partial if a reagent has no price", function()
        local recipe = { reagents = { { itemID = 1, count = 2 }, { itemID = 2, count = 1 } }, itemID = 9,
            madeMin = 1, madeMax = 1 }
        local result = cost.Compute(recipe, options({ [1] = 100 }, { [9] = 1000 }))
        assert.are.equal(200, result.cost)
        assert.is_true(result.partial)
        assert.is_nil(result.lines[2].unit)
        assert.is_nil(result.lines[2].total)
    end)

    it("uses the average of the made range", function()
        assert.are.equal(2, cost.AverageMade(1, 3))
        assert.are.equal(1.5, cost.AverageMade(1, 2))
        assert.are.equal(1, cost.AverageMade(nil, nil))
        local recipe = { reagents = { { itemID = 1, count = 1 } }, itemID = 9, madeMin = 1, madeMax = 2 }
        local result = cost.Compute(recipe, options({ [1] = 100 }, { [9] = 1000 }))
        assert.are.equal(1.5, result.made)
        assert.are.equal(1500, result.value)
    end)

    it("takes the AH cut from the value", function()
        local recipe = { reagents = { { itemID = 1, count = 1 } }, itemID = 9, madeMin = 1, madeMax = 1 }
        local result = cost.Compute(recipe, options({ [1] = 100 }, { [9] = 1000 }))
        assert.are.equal(50, result.cutAmount)
        assert.are.equal(850, result.profit)
        assert.are.equal(850, result.percent)
    end)

    it("gives a negative profit and percent for a loss", function()
        local recipe = { reagents = { { itemID = 1, count = 1 } }, itemID = 9, madeMin = 1, madeMax = 1 }
        local result = cost.Compute(recipe, options({ [1] = 1000 }, { [9] = 500 }))
        assert.are.equal(-525, result.profit)
        assert.are.equal(-52.5, result.percent)
    end)

    it("has no percent if the cost is zero", function()
        local recipe = { reagents = {}, itemID = 9, madeMin = 1, madeMax = 1 }
        local result = cost.Compute(recipe, options({}, { [9] = 100 }))
        assert.are.equal(95, result.profit)
        assert.is_nil(result.percent)
    end)

    it("gives no value and no profit if the item has no price", function()
        local recipe = { reagents = { { itemID = 1, count = 1 } }, itemID = 9, madeMin = 1, madeMax = 1 }
        local result = cost.Compute(recipe, options({ [1] = 100 }, {}))
        assert.is_true(result.hasItem)
        assert.is_nil(result.value)
        assert.is_nil(result.profit)
        assert.are.equal(100, result.cost)
    end)

    it("gives the cost only if the recipe has no item", function()
        local recipe = { reagents = { { itemID = 1, count = 2 } }, madeMin = 1, madeMax = 1 }
        local result = cost.Compute(recipe, options({ [1] = 100 }, {}))
        assert.is_false(result.hasItem)
        assert.are.equal(200, result.cost)
        assert.is_nil(result.value)
        assert.is_nil(result.profit)
    end)
end)

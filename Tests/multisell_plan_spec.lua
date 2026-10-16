local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function load(toc, flavour)
    mock.reset({ flavour = flavour })
    mock.playerName = "Tester"
    mock.realmName = "TestRealm"
    local ns = {}
    for _, path in ipairs(manifest.files(toc)) do
        assert(loadfile(path))("Flipside", ns)
    end
    return ns
end

local function field(ns, key)
    for _, f in ipairs(ns.OperationSchema.Fields("selling")) do
        if f.key == key then
            return f
        end
    end
end

describe("multisell operation fields", function()
    after_each(function()
        mock.teardown()
    end)

    it("gives the TBC selling operation a stack size and a max stacks field", function()
        local ns = load("Flipside_TBC.toc", "tbc")
        local size, stacks = field(ns, "stackSize"), field(ns, "maxStacks")
        assert.is_not_nil(size)
        assert.is_not_nil(stacks)
        assert.are.equal("Stack size", size.label)
        assert.are.equal("Max stacks", stacks.label)
        assert.are.equal(0, size.default)
        assert.are.equal(0, stacks.default)
        assert.are.equal(0, ns.OperationSchema.Defaults("selling").maxStacks)
    end)

    it("checks the max stacks value", function()
        local ns = load("Flipside_TBC.toc", "tbc")
        assert.is_true(ns.OperationSchema.ValidateField("selling", "maxStacks", 5))
        assert.is_false(ns.OperationSchema.ValidateField("selling", "maxStacks", -1))
        assert.is_false(ns.OperationSchema.ValidateField("selling", "maxStacks", 2.5))
    end)

    it("gives the Forever selling operation no max stacks field", function()
        local ns = load("Flipside.toc", "forever")
        assert.is_nil(field(ns, "maxStacks"))
        assert.is_nil(ns.OperationSchema.Defaults("selling").maxStacks)
        assert.are.equal("Max stack size", field(ns, "stackSize").label)
        assert.is_false(ns.SellingPlan.Multisell())
    end)

    it("sets the multisell flag on TBC only", function()
        assert.is_true(load("Flipside_TBC.toc", "tbc").SellingPlan.Multisell())
        assert.is_false(load("Flipside.toc", "forever").SellingPlan.Multisell())
    end)
end)

describe("SellingPlan.Decide with multisell", function()
    local ns, SP

    local function candidate(count, settings)
        return {
            key = "100", itemID = 100, count = count, owned = 0, ownedUnits = 0, minPrice = 1000, normalPrice = 5000,
            maxPrice = 9000, settings = settings or {},
        }
    end

    before_each(function()
        ns = { Flavour = { multisell = true } }
        assert(loadfile(manifest.path("SellingPlan")))("Flipside", ns)
        SP = ns.SellingPlan
    end)

    it("posts all full stacks and keeps the rest as a remainder", function()
        local d = SP.Decide(candidate(47), {}, { maxStack = 20 })
        assert.are.equal(20, d.quantity)
        assert.are.equal(2, d.auctions)
        assert.are.equal(7, d.remainder)
    end)

    it("has no remainder for exact stacks", function()
        local d = SP.Decide(candidate(40), {}, { maxStack = 20 })
        assert.are.equal(2, d.auctions)
        assert.is_nil(d.remainder)
    end)

    it("limits the stacks with max stacks and then posts no remainder", function()
        local d = SP.Decide(candidate(47), {}, { maxStack = 20 })
        assert.are.equal(2, d.auctions)
        d = SP.Decide(candidate(47, { maxStacks = 1 }), {}, { maxStack = 20 })
        assert.are.equal(1, d.auctions)
        assert.is_nil(d.remainder)
    end)

    it("uses the stack size of the operation", function()
        local d = SP.Decide(candidate(47, { stackSize = 10 }), {}, { maxStack = 20 })
        assert.are.equal(10, d.quantity)
        assert.are.equal(4, d.auctions)
        assert.are.equal(7, d.remainder)
    end)

    it("posts one partial stack when the count is below the stack size", function()
        local d = SP.Decide(candidate(7), {}, { maxStack = 20 })
        assert.are.equal(7, d.quantity)
        assert.are.equal(1, d.auctions)
        assert.is_nil(d.remainder)
    end)

    it("keeps the post cap on the stack count and gives no remainder past it", function()
        local c = candidate(47, { postCap = 2 })
        local d = SP.Decide(c, {}, { maxStack = 20 })
        assert.are.equal(2, d.auctions)
        assert.is_nil(d.remainder)
    end)

    it("gives no remainder when the client has no multisell", function()
        ns.Flavour.multisell = nil
        local d = SP.Decide(candidate(47, { maxStacks = 1 }), {}, { maxStack = 20 })
        assert.are.equal(2, d.auctions)
        assert.is_nil(d.remainder)
    end)

    it("counts the items of all stacks in the profit", function()
        local profit = SP.Profit(100, { { quantity = 20, stacks = 3, deposit = 30 }, { quantity = 7 } }, 10)
        assert.are.equal(67, profit.quantity)
        assert.are.equal(6700, profit.gross)
        assert.are.equal(670, profit.vendor)
    end)
end)

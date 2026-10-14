local manifest = require("Tests.manifest")
describe("BuyingPlan", function()
    local ns, BP, GT, groups, ops, prices, rules, run

    local function load(path)
        assert(loadfile(path))("Flipside", ns)
    end

    before_each(function()
        ns = {}
        load(manifest.path("ItemString"))
        load(manifest.path("GroupTree"))
        load(manifest.path("BuyingPlan"))
        BP, GT = ns.BuyingPlan, ns.GroupTree
        groups = GT.NewData()
        ops = {
            [10] = { id = 10, name = "Cheap", type = "buying", settings = { maxPrice = "p", showAboveMax = true } },
            [11] = { id = 11, name = "Sell", type = "selling", settings = { maxPrice = "p" } },
        }
        prices = {
            ["100"] = { 5000 },
            ["200"] = { nil, { kind = "error", message = "bad" } },
            ["300"] = { nil, { kind = "invalid" } },
        }
        rules = {
            Walk = function(_, fn) return GT.Walk(groups, fn) end,
            ItemsIn = function(_, id) return GT.ItemsIn(groups, id) end,
            Path = function(_, id) return GT.Path(groups, id) end,
            EffectiveOperation = function(_, id, t) return (GT.Effective(groups, id, t)) end,
            GetOperation = function(_, id) return ops[id] end,
        }
        run = {
            Evaluate = function(_, _, key)
                local p = prices[key]
                if not p then
                    return nil, { kind = "invalid" }
                end
                return p[1], p[2] or { kind = "ok" }
            end,
        }
    end)

    local function list()
        return BP.ShoppingList({ rules = rules, formulaRun = run })
    end

    describe("ShoppingList", function()
        it("is empty without groups or operations", function()
            assert.same({}, list())
            local g = GT.Create(groups, 1, "Herbs")
            GT.AddItem(groups, "100", g)
            assert.same({}, list())
        end)

        it("lists items of a group with a buying operation", function()
            local g = GT.Create(groups, 1, "Herbs")
            GT.AddItem(groups, "100", g)
            GT.Attach(groups, g, "buying", 10)
            local out = list()
            assert.equal(1, #out)
            assert.equal("100", out[1].key)
            assert.equal(100, out[1].itemID)
            assert.same({ "Base", "Herbs" }, out[1].groupPath)
            assert.equal("Cheap", out[1].operationName)
            assert.equal(5000, out[1].maxPrice)
            assert.is_true(out[1].showAboveMax)
            assert.is_nil(out[1].reason)
        end)

        it("inherits the operation from a parent group", function()
            local parent = GT.Create(groups, 1, "Herbs")
            local child = GT.Create(groups, parent, "Rare")
            GT.AddItem(groups, "100", child)
            GT.Attach(groups, parent, "buying", 10)
            local out = list()
            assert.equal(1, #out)
            assert.same({ "Base", "Herbs", "Rare" }, out[1].groupPath)
        end)

        it("ignores groups with only a selling operation", function()
            local g = GT.Create(groups, 1, "Herbs")
            GT.AddItem(groups, "100", g)
            GT.Attach(groups, g, "selling", 11)
            assert.same({}, list())
        end)

        it("gives a reason for a formula error and for no data", function()
            local g = GT.Create(groups, 1, "Herbs")
            GT.AddItem(groups, "200", g)
            GT.AddItem(groups, "300", g)
            GT.AddItem(groups, "400", g)
            GT.Attach(groups, g, "buying", 10)
            local out = list()
            assert.equal(3, #out)
            assert.is_nil(out[1].maxPrice)
            assert.equal("formula error: bad", out[1].reason)
            assert.equal("no data", out[2].reason)
            assert.equal("no data", out[3].reason)
        end)

        it("treats a price of 0 as no price", function()
            prices["100"] = { 0 }
            local g = GT.Create(groups, 1, "Herbs")
            GT.AddItem(groups, "100", g)
            GT.Attach(groups, g, "buying", 10)
            local out = list()
            assert.is_nil(out[1].maxPrice)
            assert.equal("no data", out[1].reason)
        end)
    end)

    describe("Evaluate", function()
        local entry
        local function row(id, price, qty, extra)
            local r = { auctionID = id, unitPrice = price, quantity = qty or 1, isCommodity = false }
            for k, v in pairs(extra or {}) do
                r[k] = v
            end
            return r
        end

        before_each(function()
            entry = { key = "100", maxPrice = 1000, showAboveMax = false }
        end)

        it("stops with no max price", function()
            local r = BP.Evaluate({ key = "100" }, { row(1, 10) })
            assert.equal("no max price", r.stop)
            assert.is_nil(r.first)
        end)

        it("stops with no results", function()
            assert.equal("no results", BP.Evaluate(entry, {}).stop)
            assert.equal("no results", BP.Evaluate(entry, nil).stop)
        end)

        it("stops when all rows are above the max price", function()
            local r = BP.Evaluate(entry, { row(1, 1001), row(2, 2000) })
            assert.equal("above max price", r.stop)
            assert.same({}, r.buyable)
            assert.same({}, r.aboveMax)
            assert.equal(0, r.quantity)
        end)

        it("lists rows above the max only with showAboveMax", function()
            local rows = { row(1, 900), row(2, 1500) }
            assert.same({}, BP.Evaluate(entry, rows).aboveMax)
            local r = BP.Evaluate(entry, rows, { showAboveMax = true })
            assert.same({ rows[2] }, r.aboveMax)
            assert.same({ rows[1] }, r.buyable)
            entry.showAboveMax = true
            assert.same({ rows[2] }, BP.Evaluate(entry, rows).aboveMax)
        end)

        it("buys rows up to and at the max price", function()
            local rows = { row(1, 500), row(2, 1000, 3), row(3, 1001) }
            local r = BP.Evaluate(entry, rows)
            assert.is_nil(r.stop)
            assert.equal(rows[1], r.first)
            assert.equal(2, #r.buyable)
            assert.equal(4, r.quantity)
            assert.equal(500 + 3000, r.cost)
            assert.equal(1000, r.maxPrice)
        end)

        it("skips own auctions", function()
            local rows = { row(1, 100, 1, { ownerItem = true }), row(2, 200) }
            local r = BP.Evaluate(entry, rows)
            assert.equal(rows[2], r.first)
            assert.equal(1, #r.buyable)
        end)

        it("stops with own auction only", function()
            local r = BP.Evaluate(entry, { row(1, 100, 1, { ownerItem = true }), row(2, 100, 1, { isOwn = true }) })
            assert.equal("own auction only", r.stop)
        end)

        it("uses the isOwn option", function()
            local rows = { row(1, 100), row(2, 200) }
            local r = BP.Evaluate(entry, rows, { isOwn = function(x) return x.auctionID == 1 end })
            assert.equal(rows[2], r.first)
        end)

        it("sums commodity quantity at quoted unit prices", function()
            local rows = {
                row(nil, 100, 50, { isCommodity = true }),
                row(nil, 200, 150, { isCommodity = true }),
                row(nil, 2000, 10, { isCommodity = true }),
            }
            local r = BP.Evaluate(entry, rows)
            assert.equal(200, r.quantity)
            assert.equal(100 * 50 + 200 * 150, r.cost)
            assert.equal(rows[1], r.first)
        end)

        it("counts each item auction as one buy unit", function()
            local rows = { row(1, 100), row(2, 100), row(3, 100) }
            local r = BP.Evaluate(entry, rows)
            assert.equal(3, #r.buyable)
            assert.equal(3, r.quantity)
            assert.equal(300, r.cost)
        end)
    end)

    describe("Log", function()
        it("adds and lists entries in order", function()
            local log = BP.NewLog(5)
            log:Add({ key = "100", itemID = 100, operationName = "Cheap" }, "skip", "no results")
            log:Add({ key = "200" }, "buy", "below max")
            local out = log:List()
            assert.equal(2, #out)
            assert.equal("100", out[1].key)
            assert.equal("skip", out[1].decision)
            assert.equal("no results", out[1].reason)
            assert.equal("Cheap", out[1].operationName)
            assert.equal("200", out[2].key)
        end)

        it("keeps only the newest entries up to the cap", function()
            local log = BP.NewLog(3)
            for i = 1, 5 do
                log:Add({ key = tostring(i) }, "skip", "r")
            end
            local out = log:List()
            assert.equal(3, #out)
            assert.equal("3", out[1].key)
            assert.equal("5", out[3].key)
            assert.equal(5, out[3].seq)
        end)

        it("has a default session log with a cap of 200", function()
            BP.Log:Clear()
            for i = 1, 205 do
                BP.Log:Add({ key = tostring(i) }, "skip", "r")
            end
            assert.equal(200, #BP.Log:List())
            assert.equal("6", BP.Log:List()[1].key)
            BP.Log:Clear()
            assert.same({}, BP.Log:List())
        end)

        it("returns a copy of the list", function()
            local log = BP.NewLog(3)
            log:Add({ key = "1" }, "skip", "r")
            table.remove(log:List(), 1)
            assert.equal(1, #log:List())
        end)
    end)

    describe("PriceLevels", function()
        it("groups rows by unit price, cheapest first", function()
            local levels = BP.PriceLevels({
                { unitPrice = 200, quantity = 5, auctionID = 3 },
                { unitPrice = 100, quantity = 2, auctionID = 1 },
                { unitPrice = 100, quantity = 3, auctionID = 2 },
            })
            assert.are.equal(2, #levels)
            assert.are.equal(100, levels[1].unitPrice)
            assert.are.equal(5, levels[1].quantity)
            assert.are.equal(2, levels[1].listings)
            assert.is_false(levels[1].own)
            assert.are.equal(200, levels[2].unitPrice)
            assert.are.equal(1, levels[2].listings)
        end)

        it("marks a level that holds an own row", function()
            local levels = BP.PriceLevels({
                { unitPrice = 100, quantity = 1 },
                { unitPrice = 100, quantity = 1, ownerItem = true },
                { unitPrice = 150, quantity = 1 },
            })
            assert.is_true(levels[1].own)
            assert.is_false(levels[2].own)
        end)

        it("gives no level for no rows", function()
            assert.are.same({}, BP.PriceLevels(nil))
            assert.are.same({}, BP.PriceLevels({}))
        end)
    end)

    describe("NextLevel", function()
        local levels = { { unitPrice = 100 }, { unitPrice = 150 }, { unitPrice = 200 } }

        it("gives the first level when nothing was bought", function()
            assert.are.equal(100, BP.NextLevel(levels, nil).unitPrice)
        end)

        it("gives the first higher level after a buy", function()
            assert.are.equal(150, BP.NextLevel(levels, 100).unitPrice)
            assert.are.equal(200, BP.NextLevel(levels, 150).unitPrice)
            assert.is_nil(BP.NextLevel(levels, 200))
        end)

        it("can keep the same price for an item", function()
            assert.are.equal(100, BP.NextLevel(levels, 100, true).unitPrice)
        end)
    end)

    describe("JumpCheck", function()
        it("flags a rise of more than the threshold", function()
            local check = BP.JumpCheck(100, 130, 25)
            assert.is_true(check.jump)
            assert.are.equal(30, check.percent)
        end)

        it("does not flag a rise of 20 percent or exactly the threshold", function()
            assert.is_false(BP.JumpCheck(100, 120, 25).jump)
            assert.is_false(BP.JumpCheck(100, 125, 25).jump)
        end)

        it("handles the examples 100g to 150g and 2g to 8g", function()
            assert.are.equal(50, BP.JumpCheck(1000000, 1500000, 25).percent)
            assert.is_true(BP.JumpCheck(20000, 80000, 25).jump)
            assert.are.equal(300, BP.JumpCheck(20000, 80000, 25).percent)
        end)

        it("flags nothing for a missing or zero previous price", function()
            assert.is_false(BP.JumpCheck(nil, 100, 25).jump)
            assert.is_false(BP.JumpCheck(0, 100, 25).jump)
        end)
    end)end)

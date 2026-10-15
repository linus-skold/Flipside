local manifest = require("Tests.manifest")
describe("SellingPlan", function()
    local ns, SP, GT, groups, ops, prices, rules, run, stats, bag

    local function load(path)
        assert(loadfile(path))("Flipside", ns)
    end

    local function settings(extra)
        local s = { minPrice = "min", normalPrice = "normal", maxPrice = "max" }
        for k, v in pairs(extra or {}) do
            s[k] = v
        end
        return s
    end

    before_each(function()
        ns = {}
        load(manifest.path("ItemString"))
        load(manifest.path("GroupTree"))
        load(manifest.path("SellingPlan"))
        SP, GT = ns.SellingPlan, ns.GroupTree
        groups = GT.NewData()
        ops = { [11] = { id = 11, name = "Sell", type = "selling", settings = settings() } }
        prices = { min = 1000, normal = 5000, max = 9000 }
        stats = nil
        bag = { { key = "100", itemID = 100, name = "Herb", count = 40, stacks = {} } }
        rules = {
            GroupOf = function(_, key) return GT.GroupOf(groups, key) end,
            Path = function(_, id) return GT.Path(groups, id) end,
            EffectiveOperation = function(_, id, t) return (GT.Effective(groups, id, t)) end,
            GetOperation = function(_, id) return ops[id] end,
        }
        run = {
            Evaluate = function(_, text)
                local p = prices[text]
                if type(p) == "table" then
                    return nil, p
                end
                if not p then
                    return nil, { kind = "invalid" }
                end
                return p, { kind = "ok" }
            end,
        }
        local g = GT.Create(groups, 1, "Herbs")
        GT.AddItem(groups, "100", g)
        GT.Attach(groups, g, "selling", 11)
    end)

    local function candidate(extra)
        ops[11].settings = settings(extra)
        local out = SP.Candidates({
            rules = rules, formulaRun = run, bagItems = bag, owned = { ["100"] = 0 },
            dataStats = stats and function() return stats end or nil,
        })
        return out[1]
    end

    local function row(price, own, commodity)
        return { unitPrice = price, quantity = 1, ownerItem = own, isCommodity = commodity }
    end

    describe("Candidates", function()
        it("lists bag items of groups with a selling operation", function()
            local c = candidate()
            assert.equal("100", c.key)
            assert.same({ "Base", "Herbs" }, c.groupPath)
            assert.equal("Sell", c.operationName)
            assert.equal(1000, c.minPrice)
            assert.equal(5000, c.normalPrice)
            assert.equal(9000, c.maxPrice)
            assert.is_nil(c.reason)
        end)

        it("ignores bag items outside groups", function()
            bag[2] = { key = "200", itemID = 200, name = "Other", count = 1 }
            ops[11].settings = settings()
            local out = SP.Candidates({ rules = rules, formulaRun = run, bagItems = bag })
            assert.equal(1, #out)
        end)

        it("sets a reason for a formula error", function()
            prices.normal = { kind = "error", message = "bad" }
            assert.equal("formula error: bad", candidate().reason)
        end)

        it("names the price and the missing source when there is no data", function()
            prices.min = { kind = "invalid", missing = { "crafting", "scanmarket" }, later = { "crafting" } }
            assert.equal("no data for min price: scanmarket missing, scan again", candidate().reason)
            prices.min = 1000
            prices.normal = { kind = "invalid", missing = {}, later = {} }
            assert.equal("no data for normal price", candidate().reason)
            prices.normal = 5000
            prices.max = { kind = "invalid", missing = { "scanmarket" } }
            assert.equal("no data for max price: scanmarket missing, scan again", candidate().reason)
        end)

        it("sets a reason for stale data and few samples", function()
            stats = { ageHours = 100, samples = 10 }
            assert.matches("stale", candidate().reason)
            stats = { ageHours = 1, samples = 2 }
            assert.matches("few samples", candidate().reason)
            stats = { ageHours = 1, samples = 3 }
            assert.is_nil(candidate().reason)
        end)
    end)

    describe("Decide", function()
        it("undercuts the lowest competitor", function()
            local d = SP.Decide(candidate(), { row(4500), row(4600, true), row(4800) }, { maxStack = 20 })
            assert.equal("post", d.action)
            assert.equal(4499, d.price)
            assert.equal(24, d.duration)
        end)

        it("uses the operation undercut", function()
            local d = SP.Decide(candidate({ undercut = 50 }), { row(4500) }, { maxStack = 20 })
            assert.equal(4450, d.price)
        end)

        it("posts at normal without a competitor", function()
            local d = SP.Decide(candidate(), {}, { maxStack = 20 })
            assert.equal("post", d.action)
            assert.equal(5000, d.price)
        end)

        it("skips when the own auction is already lowest", function()
            local d = SP.Decide(candidate(), { row(4000, true), row(4500) }, { maxStack = 20 })
            assert.equal("skip", d.action)
            assert.equal("already lowest", d.reason)
        end)

        it("posts at max above the maximum by default", function()
            local d = SP.Decide(candidate(), { row(20000) }, { maxStack = 20 })
            assert.equal(9000, d.price)
        end)

        it("posts at normal above the maximum with postAtNormal", function()
            local d = SP.Decide(candidate({ aboveMax = "postAtNormal" }), { row(20000) }, { maxStack = 20 })
            assert.equal(5000, d.price)
        end)

        it("skips below the minimum by default", function()
            local d = SP.Decide(candidate(), { row(500) }, { maxStack = 20 })
            assert.equal("skip", d.action)
            assert.equal("below minimum", d.reason)
        end)

        it("posts at min below the minimum with postAtMin", function()
            local d = SP.Decide(candidate({ belowMin = "postAtMin" }), { row(500) }, { maxStack = 20 })
            assert.equal("post", d.action)
            assert.equal(1000, d.price)
        end)

        it("keeps items in the bags", function()
            local d = SP.Decide(candidate({ keepInBags = 30, stackSize = 5 }), {}, { maxStack = 20 })
            assert.equal(5, d.quantity)
            assert.equal(2, d.auctions)
            d = SP.Decide(candidate({ keepInBags = 40 }), {}, { maxStack = 20 })
            assert.equal("skip", d.action)
            assert.equal("keep in bags reached", d.reason)
        end)

        it("posts full stacks by default and caps the stack size", function()
            local d = SP.Decide(candidate(), {}, { maxStack = 20 })
            assert.equal(20, d.quantity)
            assert.equal(2, d.auctions)
            d = SP.Decide(candidate({ stackSize = 100 }), {}, { maxStack = 20 })
            assert.equal(20, d.quantity)
            d = SP.Decide(candidate({ stackSize = 8 }), {}, { maxStack = 20 })
            assert.equal(8, d.quantity)
            assert.equal(5, d.auctions)
        end)

        it("posts one partial stack when the count is below the stack size", function()
            bag[1].count = 7
            local d = SP.Decide(candidate(), {}, { maxStack = 20 })
            assert.equal(7, d.quantity)
            assert.equal(1, d.auctions)
        end)

        it("respects the post cap minus owned auctions", function()
            local c = candidate({ postCap = 4, stackSize = 5 })
            c.owned = 1
            local d = SP.Decide(c, {}, { maxStack = 20 })
            assert.equal(3, d.auctions)
            c.owned = 4
            d = SP.Decide(c, {}, { maxStack = 20 })
            assert.equal("skip", d.action)
            assert.equal("post cap reached", d.reason)
        end)

        it("posts a commodity as one listing", function()
            local d = SP.Decide(candidate({ postCap = 4 }), { row(4500, false, true) }, { maxStack = 20 })
            assert.equal(40, d.quantity)
            assert.equal(1, d.auctions)
            assert.is_true(d.commodity)
        end)

        it("skips on a safety failure", function()
            stats = { ageHours = 100, samples = 10 }
            local d = SP.Decide(candidate(), {}, { maxStack = 20 })
            assert.equal("skip", d.action)
            assert.matches("stale", d.reason)
        end)

        it("skips on a formula error", function()
            prices.max = { kind = "error", message = "oops" }
            local d = SP.Decide(candidate(), {}, { maxStack = 20 })
            assert.equal("skip", d.action)
            assert.equal("formula error: oops", d.reason)
        end)
    end)

    describe("Log", function()
        it("keeps the newest entries", function()
            local log = SP.NewLog(2)
            for i = 1, 3 do
                log:Add({ key = tostring(i) }, { action = "skip", reason = "r" })
            end
            local list = log:List()
            assert.equal(2, #list)
            assert.equal("2", list[1].key)
            assert.equal("skip", list[2].decision)
            log:Clear()
            assert.equal(0, #log:List())
        end)
    end)
end)

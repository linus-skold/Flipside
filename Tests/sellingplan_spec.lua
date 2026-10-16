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

        it("sets a reason for stale data", function()
            stats = { ageHours = 100, samples = 10 }
            assert.matches("stale", candidate().reason)
            stats = { ageHours = 1, samples = 3 }
            assert.is_nil(candidate().reason)
            assert.is_nil(candidate().fewSamples)
        end)

        it("marks few samples and does not block the candidate", function()
            stats = { ageHours = 1, samples = 2 }
            local c = candidate()
            assert.is_nil(c.reason)
            assert.equal("too few samples: 2 of 3", c.fewSamples)
            stats = { ageHours = 100, samples = 2 }
            assert.matches("stale", candidate().reason)
        end)

        it("does not check the samples when the operation needs no scan data", function()
            stats = { ageHours = 1, samples = 0 }
            assert.is_nil(candidate({ needScanData = false }).fewSamples)
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
            local d = SP.Decide(candidate(), { row(4500, false, true) }, { maxStack = 20 })
            assert.equal(40, d.quantity)
            assert.equal(1, d.auctions)
            assert.is_true(d.commodity)
        end)

        it("ignores the stack size for a commodity", function()
            local d = SP.Decide(candidate({ stackSize = 5 }), { row(4500, false, true) }, { maxStack = 20 })
            assert.equal(40, d.quantity)
            assert.equal(1, d.auctions)
        end)

        it("counts the post quantity of a commodity in units", function()
            local c = candidate({ postCap = 25 })
            c.ownedUnits = 10
            local d = SP.Decide(c, { row(4500, false, true) }, { maxStack = 20 })
            assert.equal(15, d.quantity)
            c.ownedUnits = 25
            d = SP.Decide(c, { row(4500, false, true) }, { maxStack = 20 })
            assert.equal("skip", d.action)
            assert.equal("post cap reached", d.reason)
        end)

        it("passes the units that own auctions hold to the candidate", function()
            ops[11].settings = settings()
            local out = SP.Candidates({ rules = rules, formulaRun = run, bagItems = bag, ownedUnits = { ["100"] = 7 } })
            assert.equal(7, out[1].ownedUnits)
        end)

        it("passes the post duration of the rule to the decision", function()
            assert.equal(2, SP.Decide(candidate({ duration = 2 }), {}, { maxStack = 20 }).duration)
            assert.equal(8, SP.Decide(candidate({ duration = 8 }), {}, { maxStack = 20 }).duration)
        end)

        it("reads an old saved duration of 12 as 8 and 48 as 24", function()
            assert.equal(8, SP.Decide(candidate({ duration = 12 }), {}, { maxStack = 20 }).duration)
            assert.equal(24, SP.Decide(candidate({ duration = 48 }), {}, { maxStack = 20 }).duration)
        end)

        it("maps any saved duration to a valid one", function()
            assert.same({ 2, 8, 24 }, SP.DURATIONS)
            assert.equal(2, SP.NormalizeDuration(2))
            assert.equal(8, SP.NormalizeDuration(8))
            assert.equal(24, SP.NormalizeDuration(24))
            assert.equal(8, SP.NormalizeDuration(12))
            assert.equal(24, SP.NormalizeDuration(48))
            assert.equal(2, SP.NormalizeDuration(1))
            assert.equal(24, SP.NormalizeDuration(nil))
            assert.equal(24, SP.NormalizeDuration("x"))
        end)

        describe("with too few samples", function()
            before_each(function()
                stats = { ageHours = 1, samples = 2 }
            end)

            it("prices from the cheapest listing minus the undercut, with a reason", function()
                local d = SP.Decide(candidate({ undercut = 50 }), { row(4500), row(4800) }, { maxStack = 20 })
                assert.equal("post", d.action)
                assert.equal(4450, d.price)
                assert.equal("few samples, using the cheapest listing", d.reason)
            end)

            it("uses the cheapest listing of another seller", function()
                local d = SP.Decide(candidate(), { row(4500), row(5000, true) }, { maxStack = 20 })
                assert.equal(4499, d.price)
                local own = SP.Decide(candidate(), { row(4000, true), row(4500) }, { maxStack = 20 })
                assert.equal("already lowest", own.reason)
            end)

            it("still keeps the minimum and maximum price of the rule", function()
                local low = SP.Decide(candidate(), { row(500) }, { maxStack = 20 })
                assert.equal("skip", low.action)
                assert.equal("below minimum", low.reason)
                local high = SP.Decide(candidate(), { row(20000) }, { maxStack = 20 })
                assert.equal(9000, high.price)
                assert.equal("above max, at max", high.reason)
            end)

            it("skips with the old reason when there is no listing", function()
                local d = SP.Decide(candidate(), {}, { maxStack = 20 })
                assert.equal("skip", d.action)
                assert.equal("too few samples: 2 of 3", d.reason)
            end)

            it("posts at the market value with enough samples", function()
                stats = { ageHours = 1, samples = 3 }
                local d = SP.Decide(candidate(), {}, { maxStack = 20 })
                assert.equal("post", d.action)
                assert.equal(5000, d.price)
                assert.equal("undercut", SP.Decide(candidate(), { row(4500) }, { maxStack = 20 }).reason)
            end)
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

    describe("VendorSkip", function()
        local post = { action = "post", price = 1000, quantity = 20, auctions = 1 }

        it("skips when the vendor pays more than the net, with a reason", function()
            -- 20000 gross - 1000 cut - 300 deposit = 18700 net; the vendor pays 20 x 1000 = 20000.
            local d = SP.VendorSkip(candidate(), post, { { quantity = 20, deposit = 300 } }, 1000)
            assert.equal("skip", d.action)
            assert.equal("vendor pays more than the AH", d.reason)
            assert.equal(1000, d.suggested)
            assert.equal(20000, d.vendor)
            assert.equal(18700, d.net)
            assert.equal("100", d.key)
        end)

        it("is on by default and when the field is true", function()
            local units = { { quantity = 20, deposit = 0 } }
            assert.is_table(SP.VendorSkip(candidate(), post, units, 2000))
            assert.is_table(SP.VendorSkip(candidate({ vendorSkip = true }), post, units, 2000))
        end)

        it("skips nothing when the field is false", function()
            local units = { { quantity = 20, deposit = 0 } }
            assert.is_nil(SP.VendorSkip(candidate({ vendorSkip = false }), post, units, 2000))
        end)

        it("skips nothing when the AH pays more or the vendor price is not known", function()
            local units = { { quantity = 20, deposit = 300 } }
            assert.is_nil(SP.VendorSkip(candidate(), post, units, 900))
            assert.is_nil(SP.VendorSkip(candidate(), post, units, nil))
            assert.is_nil(SP.VendorSkip(candidate(), post, {}, 5000))
        end)

        it("uses the cut and the deposit of all units", function()
            local units = { { quantity = 10, deposit = 5000 }, { quantity = 10, deposit = 5000 } }
            -- Net 20000 - 1000 - 10000 = 9000, below the vendor 10 x 500 x 2 = 10000.
            assert.is_table(SP.VendorSkip(candidate(), post, units, 500))
            assert.is_nil(SP.VendorSkip(candidate(), post, units, 400))
        end)
    end)

    describe("Profit", function()
        it("takes a 5 percent cut and the deposit from the gross", function()
            local p = SP.Profit(1000, { { quantity = 20, deposit = 300 }, { quantity = 20, deposit = 300 } }, nil)
            assert.equal(40000, p.gross)
            assert.equal(2000, p.cut)
            assert.equal(600, p.deposit)
            assert.equal(37400, p.net)
            assert.is_nil(p.vs)
            assert.equal(0.05, SP.AH_CUT)
        end)

        it("rounds the cut to the nearest copper", function()
            assert.equal(5, SP.Cut(99))
            assert.equal(4, SP.Cut(89))
            assert.equal(0, SP.Cut(0))
        end)

        it("subtracts the vendor value of the same items for vs vendor", function()
            local p = SP.Profit(1000, { { quantity = 10, deposit = 100 } }, 400)
            assert.equal(10000 - 500 - 100, p.net)
            assert.equal(4000, p.vendor)
            assert.equal(9400 - 4000, p.vs)
        end)

        it("can be negative", function()
            local p = SP.Profit(10, { { quantity = 5, deposit = 500 } }, 20)
            assert.equal(50 - 3 - 500, p.net)
            assert.is_true(p.net < 0)
            assert.is_true(p.vs < p.net)
        end)

        it("counts a missing deposit as 0", function()
            local p = SP.Profit(100, { { quantity = 2 } }, nil)
            assert.equal(190, p.net)
            assert.is_false(p.depositKnown)
        end)

        it("marks the deposit known only when every unit has one", function()
            assert.is_true(SP.Profit(100, { { quantity = 2, deposit = 0 } }, nil).depositKnown)
            assert.is_false(SP.Profit(100, { { quantity = 2, deposit = 5 }, { quantity = 2 } }, nil).depositKnown)
        end)
    end)

    describe("Log", function()        it("keeps the newest entries", function()
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

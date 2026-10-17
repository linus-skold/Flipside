local manifest = require("Tests.manifest")

-- LedgerVendor with the real money tracker: one record for each money change, with item and quantity.
describe("LedgerVendor", function()
    local ns, bus, clock, money, records, timers, tracker, vendor, world

    local function load(name)
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end

    local function advance(seconds)
        clock = clock + seconds
        local due, rest = {}, {}
        for _, timer in ipairs(timers) do
            table.insert(timer.at <= clock and due or rest, timer)
        end
        timers = rest
        for _, timer in ipairs(due) do
            timer.fn()
        end
    end

    local function change(delta)
        money = money + delta
        bus:Emit("PLAYER_MONEY")
    end

    -- A sale: the item goes to the buyback list, the money arrives.
    local function sell(link, price, qty)
        world.buyback[#world.buyback + 1] = { link = link, price = price, qty = qty }
        change(price)
    end

    before_each(function()
        ns = {}
        load("EventBus")
        load("LedgerRecord")
        load("LedgerMoney")
        load("LedgerVendor")
        bus = ns.EventBus.New({})
        clock, money, records, timers = 100, 100000, {}, {}
        world = { buyback = {}, merchant = {}, repair = 0 }
        tracker = ns.LedgerMoney.Attach({
            bus = bus,
            buffer = {
                Add = function(_, record)
                    local ok, message = ns.LedgerRecord.Validate(record)
                    if not ok then
                        return false, message
                    end
                    records[#records + 1] = record
                    return true
                end,
            },
            getMoney = function()
                return money
            end,
            now = function()
                return clock
            end,
            serverTime = function()
                return 1700000000
            end,
            character = function()
                return "Tester-Realm"
            end,
            after = function(seconds, fn)
                timers[#timers + 1] = { at = clock + seconds, fn = fn }
            end,
            setting = function()
                return false
            end,
            itemKey = function(input)
                return input
            end,
        })
        vendor = ns.LedgerVendor.New({
            bus = bus,
            tracker = tracker,
            now = function()
                return clock
            end,
            itemKey = function(link)
                return "k:" .. link
            end,
            api = {
                buybackCount = function()
                    return #world.buyback
                end,
                buyback = function(index)
                    local entry = world.buyback[index]
                    return "name", "texture", entry.price, entry.qty
                end,
                buybackLink = function(index)
                    return world.buyback[index].link
                end,
                merchantLink = function(index)
                    return world.merchant[index] and world.merchant[index].link
                end,
                merchantInfo = function(index)
                    local entry = world.merchant[index]
                    return entry and entry.price, entry and entry.stack
                end,
                repairCost = function()
                    return world.repair, true
                end,
            },
        })
        bus:Emit("MERCHANT_SHOW")
    end)

    describe("vendor sale", function()
        it("gives the item and the quantity from the newest buyback entry", function()
            sell("linen", 150, 20)
            assert.are.equal(1, #records)
            assert.are.equal("vendorSale", records[1].source)
            assert.are.equal("income", records[1].type)
            assert.are.equal(150, records[1].money)
            assert.are.equal("k:linen", records[1].item)
            assert.are.equal(20, records[1].qty)
        end)

        it("matches a per-unit price too", function()
            sell("wool", 10, 5)
            -- A money change of price times quantity is the other reading.
            world.buyback[2] = { link = "silk", price = 30, qty = 4 }
            change(120)
            assert.are.equal("k:silk", records[2].item)
            assert.are.equal(4, records[2].qty)
        end)

        it("gives each of two sales of the same item and price its own entry", function()
            sell("a", 50, 1)
            sell("a", 50, 1)
            change(50)
            advance(ns.LedgerMoney.QUEST_WINDOW_SECONDS)
            assert.are.equal(3, #records)
            assert.are.equal("k:a", records[1].item)
            assert.are.equal("k:a", records[2].item)
            assert.is_nil(records[3].item)
        end)

        it("ignores buyback entries that were in the list when the window opened", function()
            bus:Emit("MERCHANT_CLOSED")
            world.buyback = { { link = "old", price = 70, qty = 1 } }
            bus:Emit("MERCHANT_SHOW")
            change(70)
            advance(ns.LedgerMoney.QUEST_WINDOW_SECONDS)
            assert.are.equal(1, #records)
            assert.are.equal("vendorSale", records[1].source)
            assert.are.equal("", records[1].item or "")
        end)

        it("uses an entry again after the item was bought back", function()
            sell("a", 50, 1)
            world.buyback = {}
            bus:Emit("MERCHANT_UPDATE")
            sell("a", 50, 1)
            assert.are.equal("k:a", records[2].item)
        end)

        it("waits once for a buyback entry that comes after the money change", function()
            change(80)
            assert.are.equal(0, #records)
            world.buyback[1] = { link = "late", price = 80, qty = 2 }
            advance(ns.LedgerMoney.QUEST_WINDOW_SECONDS)
            assert.are.equal(1, #records)
            assert.are.equal("k:late", records[1].item)
            assert.are.equal(2, records[1].qty)
        end)

        it("writes the sale with no item if no entry matches", function()
            change(80)
            advance(ns.LedgerMoney.QUEST_WINDOW_SECONDS)
            assert.are.equal(1, #records)
            assert.are.equal("vendorSale", records[1].source)
            assert.is_nil(records[1].item)
            assert.is_nil(records[1].qty)
        end)
    end)

    describe("vendor purchase", function()
        it("gives the item and the quantity from the BuyMerchantItem call", function()
            world.merchant[3] = { link = "bandage", price = 100, stack = 1 }
            vendor.OnBuy(3, 5)
            change(-500)
            assert.are.equal(1, #records)
            assert.are.equal("vendorPurchase", records[1].source)
            assert.are.equal("expense", records[1].type)
            assert.are.equal(500, records[1].money)
            assert.are.equal("k:bandage", records[1].item)
            assert.are.equal(5, records[1].qty)
        end)

        it("buys one stack when the call has no quantity", function()
            world.merchant[2] = { link = "arrow", price = 200, stack = 200 }
            vendor.OnBuy(2)
            change(-200)
            assert.are.equal("k:arrow", records[1].item)
            assert.are.equal(200, records[1].qty)
        end)

        it("scales the price of a stack by the quantity", function()
            world.merchant[2] = { link = "arrow", price = 200, stack = 200 }
            vendor.OnBuy(2, 50)
            change(-50)
            assert.are.equal(50, records[1].qty)
        end)

        it("matches two purchases to their own money changes", function()
            world.merchant[1] = { link = "a", price = 10, stack = 1 }
            world.merchant[2] = { link = "b", price = 25, stack = 1 }
            vendor.OnBuy(1, 1)
            vendor.OnBuy(2, 1)
            change(-25)
            change(-10)
            assert.are.equal("k:b", records[1].item)
            assert.are.equal("k:a", records[2].item)
        end)

        it("writes no item for a purchase with an unknown price, and keeps one record", function()
            world.merchant[1] = { link = "a", price = 10, stack = 1 }
            vendor.OnBuy(1, 1)
            change(-99)
            assert.are.equal(1, #records)
            assert.are.equal("vendorPurchase", records[1].source)
            assert.is_nil(records[1].item)
        end)

        it("drops a purchase that gets no money change in time", function()
            world.merchant[1] = { link = "a", price = 10, stack = 1 }
            vendor.OnBuy(1, 1)
            advance(ns.LedgerVendor.PURCHASE_SECONDS + 1)
            change(-10)
            assert.is_nil(records[1].item)
        end)

        it("does not fail when the APIs give nil", function()
            assert.is_false(vendor.OnBuy(9, 1))
            assert.is_false(vendor.OnBuy(nil, nil))
            world.merchant[1] = { link = nil, price = 10, stack = nil }
            assert.is_true(vendor.OnBuy(1, nil))
            change(-10)
            assert.are.equal(1, #records)
            assert.is_nil(records[1].item)
        end)
    end)

    describe("repair", function()
        it("labels a spend of the repair cost as a repair", function()
            world.repair = 4321
            bus:Emit("MERCHANT_UPDATE")
            change(-4321)
            assert.are.equal(1, #records)
            assert.are.equal("repair", records[1].source)
            assert.are.equal("expense", records[1].type)
            assert.are.equal(4321, records[1].money)
        end)

        it("keeps the cost that was read before the repair set it to zero", function()
            world.repair = 900
            bus:Emit("MERCHANT_UPDATE")
            world.repair = 0
            bus:Emit("MERCHANT_UPDATE")
            change(-900)
            assert.are.equal("repair", records[1].source)
        end)

        it("counts a repair once", function()
            world.repair = 900
            bus:Emit("MERCHANT_UPDATE")
            change(-900)
            change(-900)
            assert.are.equal("repair", records[1].source)
            assert.are.equal("vendorPurchase", records[2].source)
        end)

        it("prefers a bought item with the same price", function()
            world.repair = 100
            bus:Emit("MERCHANT_UPDATE")
            world.merchant[1] = { link = "a", price = 100, stack = 1 }
            vendor.OnBuy(1, 1)
            change(-100)
            assert.are.equal("vendorPurchase", records[1].source)
            assert.are.equal("k:a", records[1].item)
        end)

        it("forgets the cost when the merchant closes", function()
            world.repair = 900
            bus:Emit("MERCHANT_UPDATE")
            bus:Emit("MERCHANT_CLOSED")
            world.repair = 0
            bus:Emit("MERCHANT_SHOW")
            change(-900)
            assert.are.equal("vendorPurchase", records[1].source)
        end)
    end)

    it("does not change the record of a change outside the merchant window", function()
        bus:Emit("MERCHANT_CLOSED")
        world.repair = 900
        bus:Emit("MERCHANT_UPDATE")
        change(-900)
        assert.are.equal("unknown", records[1].source)
    end)

    it("keeps working when the matcher fails", function()
        tracker:SetMerchantMatcher(function()
            error("boom")
        end)
        change(-10)
        assert.are.equal(1, #records)
        assert.are.equal("vendorPurchase", records[1].source)
    end)
end)

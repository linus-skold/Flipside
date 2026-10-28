local manifest = require("Tests.manifest")

local function loadModules()
    local ns = {}
    for _, name in ipairs({ "ItemString", "BuyingPlan" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

describe("BuyingPlan.VendorEntries", function()
    local ns, records, cache, requests, run, evaluated, sell

    local SINCE = 1000

    local function record(min, time, partial)
        return { latest = { time = time or SINCE, min = min, market = min, qty = 1, auctions = 1, partial = partial } }
    end

    local function deps(extra)
        local d = {
            store = {
                Keys = function()
                    local keys = {}
                    for key in pairs(records) do
                        keys[#keys + 1] = key
                    end
                    table.sort(keys)
                    return keys
                end,
                Get = function(_, key) return records[key] end,
            },
            itemCache = cache, formulaRun = run, formula = "vendorsell", since = SINCE,
        }
        for k, v in pairs(extra or {}) do
            d[k] = v
        end
        return d
    end

    before_each(function()
        ns = loadModules()
        records, requests, evaluated = {}, {}, {}
        sell = {}
        cache = {
            states = {},
            Get = function(self, itemID)
                if sell[itemID] ~= nil then
                    return { sellPrice = sell[itemID] }, "loaded"
                end
                return nil, self.states[itemID] or "unknown"
            end,
            Request = function(self, itemID)
                requests[#requests + 1] = itemID
                self.states[itemID] = "requested"
            end,
        }
        -- The formula "vendorsell" gives the sell price of the item; any other text is not valid.
        run = {
            Evaluate = function(_, text, key)
                evaluated[#evaluated + 1] = key
                if text ~= "vendorsell" then
                    return nil, { kind = "error", message = "bad" }
                end
                return sell[tonumber(key)], {}
            end,
        }
    end)

    it("keeps an item that is below its max price and gives the max price on the entry", function()
        sell[100] = 500
        records["100"] = record(300)
        local entries = ns.BuyingPlan.VendorEntries(deps())
        assert.are.equal(1, #entries)
        assert.are.equal("100", entries[1].key)
        assert.are.equal(100, entries[1].itemID)
        assert.are.equal(500, entries[1].maxPrice)
        assert.are.equal(300, entries[1].scanMin)
        assert.are.equal(200, entries[1].profit)
        assert.are.equal("Vendor", entries[1].groupPath)
        assert.is_false(entries[1].showAboveMax)
    end)

    it("skips an item with a vendor price of 0", function()
        sell[100] = 0
        records["100"] = record(300)
        assert.are.same({}, ns.BuyingPlan.VendorEntries(deps()))
    end)

    it("skips a key with no record", function()
        sell[100] = 500
        local d = deps()
        d.store.Keys = function() return { "100" } end
        assert.are.same({}, ns.BuyingPlan.VendorEntries(d))
    end)

    it("skips a record from before the last full scan", function()
        sell[100] = 500
        records["100"] = record(300, SINCE - 1)
        assert.are.same({}, ns.BuyingPlan.VendorEntries(deps()))
    end)

    it("skips a partial record", function()
        sell[100] = 500
        records["100"] = record(300, SINCE, true)
        assert.are.same({}, ns.BuyingPlan.VendorEntries(deps()))
    end)

    it("skips an item whose ScanMin is at or above the max price", function()
        sell[100], sell[200], sell[300] = 500, 500, 500
        records["100"], records["200"], records["300"] = record(500), record(600), record(499)
        local entries = ns.BuyingPlan.VendorEntries(deps())
        assert.are.equal(1, #entries)
        assert.are.equal("300", entries[1].key)
    end)

    it("gives no entry for a formula that is not valid", function()
        sell[100] = 500
        records["100"] = record(300)
        assert.are.same({}, ns.BuyingPlan.VendorEntries(deps({ formula = "oops" })))
    end)

    it("sorts by profit for each unit, highest first", function()
        sell[1], sell[2], sell[3] = 1000, 1000, 1000
        records["1"], records["2"], records["3"] = record(900), record(100), record(500)
        local entries = ns.BuyingPlan.VendorEntries(deps())
        assert.are.same({ "2", "3", "1" }, { entries[1].key, entries[2].key, entries[3].key })
        assert.are.same({ 900, 500, 100 }, { entries[1].profit, entries[2].profit, entries[3].profit })
    end)

    it("skips an item whose data is not loaded, counts it and requests it", function()
        records["100"] = record(300)
        local entries, stats = ns.BuyingPlan.VendorEntries(deps())
        assert.are.same({}, entries)
        assert.are.equal(1, stats.unknown)
        assert.are.same({ 100 }, requests)
        assert.are.same({}, evaluated)
    end)

    it("requests at most requestLimit items, and none again that are asked for", function()
        for id = 1, 5 do
            records[tostring(id)] = record(300)
        end
        local _, stats = ns.BuyingPlan.VendorEntries(deps({ requestLimit = 2 }))
        assert.are.equal(5, stats.unknown)
        assert.are.equal(2, #requests)
        ns.BuyingPlan.VendorEntries(deps({ requestLimit = 2 }))
        assert.are.equal(4, #requests)
    end)

    it("does not request an item that failed to load", function()
        records["100"] = record(300)
        cache.states[100] = "failed"
        ns.BuyingPlan.VendorEntries(deps())
        assert.are.same({}, requests)
    end)

    it("gives one checkpoint for each record", function()
        sell[1], sell[2] = 500, 500
        records["1"], records["2"] = record(100), record(100)
        local points = 0
        ns.BuyingPlan.VendorEntries(deps(), { Checkpoint = function() points = points + 1 end })
        assert.are.equal(2, points)
    end)
end)

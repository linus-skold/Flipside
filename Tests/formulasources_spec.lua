local ns = {}
assert(loadfile("Services/ScanClock.lua"))("Flipside", ns)
assert(loadfile("Services/ScanSources.lua"))("Flipside", ns)
assert(loadfile("Core/ItemInfoCache.lua"))("Flipside", ns)
assert(loadfile("Services/FormulaSources.lua"))("Flipside", ns)

local DAY = 86400
local TODAY = 20000
local NOW = TODAY * DAY + 3600 * 6

local LATER = {
    "vendorbuy", "avgbuy", "avgsell", "smartavgbuy", "minbuy", "maxbuy", "minsell",
    "maxsell", "crafting", "matprice", "destroy", "salerate", "importmarket",
}

local function makeRecord()
    return {
        latest = { time = NOW - 7200, min = 900, market = 1000, qty = 40, partial = false },
        days = {
            { day = TODAY - 1, min = 1, market = 2000, qty = 1, scans = 1 },
            { day = TODAY - 3, min = 1, market = 3000, qty = 1, scans = 1 },
        },
    }
end

describe("FormulaSources", function()
    local sources

    before_each(function()
        sources = ns.FormulaSources.New()
    end)

    it("reports the status of each name group", function()
        for _, name in ipairs({ "scanmin", "scanrecent", "scanmarket", "scanhistorical",
            "scanqty", "scanage", "scansamples", "vendorsell" }) do
            assert.are.equal("available", sources:Status(name))
        end
        for _, name in ipairs(LATER) do
            assert.are.equal("later", sources:Status(name))
        end
        assert.are.equal("unknown", sources:Status("dbmarket"))
        assert.are.equal("unknown", sources:Status("invalid"))
        assert.are.equal("unknown", sources:Status(nil))
    end)

    it("ignores case in names", function()
        assert.are.equal("available", sources:Status("ScanMin"))
        assert.are.equal("later", sources:Status("VendorBuy"))
        assert.are.equal(900, sources:Read("SCANMIN", { record = makeRecord(), now = NOW }))
    end)

    it("reads each scan source", function()
        local ctx = { record = makeRecord(), now = NOW }
        local expected = ns.ScanSources.Compute(makeRecord(), NOW)
        assert.are.equal(900, sources:Read("scanmin", ctx))
        assert.are.equal(1000, sources:Read("scanrecent", ctx))
        assert.are.equal(40, sources:Read("scanqty", ctx))
        assert.are.equal(2, sources:Read("scanage", ctx))
        assert.are.equal(expected.scanMarket, sources:Read("scanmarket", ctx))
        assert.are.equal(2500, sources:Read("scanhistorical", ctx))
        assert.are.equal(expected.scanSamples, sources:Read("scansamples", ctx))
        assert.is_truthy(expected.scanMarket)
    end)

    it("returns nil without a record", function()
        assert.is_nil(sources:Read("scanmin", { now = NOW }))
        assert.is_nil(sources:Read("scanmarket", { record = nil, now = NOW }))
    end)

    it("computes once for several reads with the same ctx", function()
        local original = ns.ScanSources.Compute
        local count = 0
        ns.ScanSources.Compute = function(...)
            count = count + 1
            return original(...)
        end
        local ctx = { record = makeRecord(), now = NOW }
        sources:Read("scanmin", ctx)
        sources:Read("scanmarket", ctx)
        sources:Read("scanqty", ctx)
        ns.ScanSources.Compute = original
        assert.are.equal(1, count)
    end)

    describe("vendorsell", function()
        local client, requests, cache

        before_each(function()
            client = {}
            requests = {}
            cache = ns.ItemInfoCache.New({
                getInfo = function(id)
                    return client[id]
                end,
                requestLoad = function(id)
                    requests[#requests + 1] = id
                end,
            })
            sources = ns.FormulaSources.New({ itemCache = cache })
        end)

        it("returns the sell price of a loaded item", function()
            client[10] = { name = "x", sellPrice = 55 }
            assert.are.equal(55, sources:Read("vendorsell", { itemID = 10 }))
        end)

        it("is nil and requests once while loading", function()
            local ctx = { itemID = 10 }
            assert.is_nil(sources:Read("vendorsell", ctx))
            assert.is_nil(sources:Read("vendorsell", ctx))
            assert.is_nil(sources:Read("vendorsell", ctx))
            assert.same({ 10 }, requests)
            client[10] = { name = "x", sellPrice = 7 }
            assert.are.equal(7, sources:Read("vendorsell", ctx))
        end)

        it("is nil for a sell price of 0", function()
            client[10] = { name = "x", sellPrice = 0 }
            assert.is_nil(sources:Read("vendorsell", { itemID = 10 }))
        end)

        it("is nil without a cache or an item", function()
            assert.is_nil(ns.FormulaSources.New():Read("vendorsell", { itemID = 10 }))
            assert.is_nil(sources:Read("vendorsell", {}))
            assert.are.equal(0, #requests)
        end)
    end)

    it("returns nil for later and unknown names", function()
        local ctx = { record = makeRecord(), now = NOW, itemID = 10 }
        for _, name in ipairs(LATER) do
            assert.is_nil(sources:Read(name, ctx))
        end
        assert.is_nil(sources:Read("dbmarket", ctx))
    end)

    it("lists the names sorted with status", function()
        local list = sources:List()
        assert.are.equal(#LATER + 8, #list)
        for i = 2, #list do
            assert.is_true(list[i - 1].name < list[i].name)
        end
        local found = {}
        for _, item in ipairs(list) do
            found[item.name] = item.status
        end
        assert.are.equal("available", found.vendorsell)
        assert.are.equal("later", found.crafting)
    end)
end)

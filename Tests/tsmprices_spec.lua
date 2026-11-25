local manifest = require("Tests.manifest")

local function load()
    local ns = {}
    for _, name in ipairs({ "ScanClock", "ScanSources", "ItemString", "TsmPrices", "ItemInfoCache", "FormulaParse",
        "FormulaFunctions", "FormulaEval", "FormulaSources" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

describe("TsmPrices", function()
    local ns, calls

    before_each(function()
        ns = load()
        calls = {}
    end)

    after_each(function()
        _G.TSM_API = nil
    end)

    local function mockApi(values)
        _G.TSM_API = {
            GetCustomPriceValue = function(key, itemString)
                calls[#calls + 1] = { key, itemString }
                return values[key]
            end,
            ToItemString = function(link)
                return link == "bad" and 5 or "i:" .. link
            end,
        }
    end

    it("reads a value with the TSM key and the item string", function()
        mockApi({ DBMarket = 1234 })
        assert.is_true(ns.TsmPrices.IsLoaded())
        assert.are.equal(1234, ns.TsmPrices.Get("tsmMarket", 2592))
        assert.are.same({ { "DBMarket", "i:2592" } }, calls)
    end)

    it("maps all ten names to TSM keys", function()
        local expect = {
            tsmmarket = "DBMarket", tsmminbuyout = "DBMinBuyout", tsmrecent = "DBRecent",
            tsmhistorical = "DBHistorical", tsmregionmarket = "DBRegionMarketAvg",
            tsmregionhistorical = "DBRegionHistorical", tsmregionsaleavg = "DBRegionSaleAvg",
            tsmregionsalerate = "DBRegionSaleRate", tsmregionsoldperday = "DBRegionSoldPerDay",
            tsmnumauctions = "DBNumAuctions",
        }
        assert.are.same(expect, ns.TsmPrices.KEYS)
        assert.are.equal(10, #ns.TsmPrices.NAMES)
        for _, name in ipairs(ns.TsmPrices.NAMES) do
            assert.is_not_nil(ns.TsmPrices.KEYS[name:lower()])
        end
    end)

    it("uses the base item for a variant key and a bare id", function()
        mockApi({ DBMarket = 5 })
        ns.TsmPrices.Get("tsmmarket", "19019#1:2:3")
        ns.TsmPrices.Get("tsmmarket", "19019")
        ns.TsmPrices.Get("tsmmarket", "19019#s5#b1")
        assert.are.equal("i:19019", calls[1][2])
        assert.are.equal("i:19019", calls[2][2])
        assert.are.equal("i:19019", calls[3][2])
    end)

    it("returns nil when TSM_API is absent", function()
        _G.TSM_API = nil
        assert.is_false(ns.TsmPrices.IsLoaded())
        assert.is_nil(ns.TsmPrices.Get("tsmmarket", 2592))
        assert.is_nil(ns.TsmPrices.ItemString("item:2592"))
    end)

    it("returns nil when the API is not complete", function()
        _G.TSM_API = {}
        assert.is_false(ns.TsmPrices.IsLoaded())
        assert.is_nil(ns.TsmPrices.Get("tsmmarket", 2592))
    end)

    it("returns nil when TSM raises an error", function()
        _G.TSM_API = {
            GetCustomPriceValue = function()
                error("boom")
            end,
            ToItemString = function()
                error("boom")
            end,
        }
        assert.is_nil(ns.TsmPrices.Get("tsmmarket", 2592))
        assert.is_nil(ns.TsmPrices.ItemString("item:2592"))
    end)

    it("returns nil for a nil or non-number result", function()
        mockApi({ DBMarket = "text", DBRecent = 0 / 0 })
        assert.is_nil(ns.TsmPrices.Get("tsmminbuyout", 2592))
        assert.is_nil(ns.TsmPrices.Get("tsmmarket", 2592))
        assert.is_nil(ns.TsmPrices.Get("tsmrecent", 2592))
    end)

    it("returns nil for an unknown name or a bad item", function()
        mockApi({ DBMarket = 1 })
        assert.is_nil(ns.TsmPrices.Get("scanmarket", 2592))
        assert.is_nil(ns.TsmPrices.Get(nil, 2592))
        assert.is_nil(ns.TsmPrices.Get("tsmmarket", nil))
        assert.is_nil(ns.TsmPrices.Get("tsmmarket", "abc"))
        assert.are.equal(0, #calls)
    end)

    it("converts a link with ToItemString and rejects a bad result", function()
        mockApi({})
        assert.are.equal("i:item:1", ns.TsmPrices.ItemString("item:1"))
        assert.is_nil(ns.TsmPrices.ItemString("bad"))
        assert.is_nil(ns.TsmPrices.ItemString(12))
    end)

    describe("as formula sources", function()
        it("reports the names as available and reads them with the item id", function()
            mockApi({ DBMarket = 777, DBNumAuctions = 4 })
            local sources = ns.FormulaSources.New()
            assert.are.equal("available", sources:Status("tsmMarket"))
            assert.are.equal("available", sources:Status("TSMREGIONSALERATE"))
            assert.are.equal(777, sources:Read("tsmMarket", { itemID = 10 }))
            assert.are.equal(4, sources:Read("tsmnumauctions", { itemID = 10 }))
            assert.is_nil(sources:Read("tsmrecent", { itemID = 10 }))
            assert.is_not_nil(ns.FormulaSources.DOCS.tsmmarket)
        end)

        it("gives nil without TSM and without an item id", function()
            local sources = ns.FormulaSources.New()
            assert.is_nil(sources:Read("tsmmarket", { itemID = 10 }))
            mockApi({ DBMarket = 777 })
            assert.is_nil(sources:Read("tsmmarket", {}))
        end)
    end)
end)

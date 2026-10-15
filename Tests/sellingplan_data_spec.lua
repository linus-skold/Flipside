local manifest = require("Tests.manifest")

-- The user case of 2026-10-15: records from a scan before the history fix hold only "latest".
describe("SellingPlan with scan records", function()
    local ns, rules, run, store

    local DAY = 86400
    local NOW = 20000 * DAY + 3600 * 6

    local function load(path)
        assert(loadfile(path))("Flipside", ns)
    end

    local function candidates(record)
        store:Put("2589", record)
        local data = ns.GroupTree.NewData()
        local g = ns.GroupTree.Create(data, 1, "Cloth")
        ns.GroupTree.AddItem(data, "2589", g)
        ns.GroupTree.Attach(data, g, "selling", 1)
        local op = {
            id = 1, name = "Cloth", type = "selling",
            settings = { minPrice = "scanmarket", normalPrice = "scanmarket", maxPrice = "2 * scanmarket" },
        }
        rules = {
            Walk = function(_, fn) return ns.GroupTree.Walk(data, fn) end,
            ItemsIn = function(_, id) return ns.GroupTree.ItemsIn(data, id) end,
            Path = function(_, id) return ns.GroupTree.Path(data, id) end,
            EffectiveOperation = function(_, id, t) return (ns.GroupTree.Effective(data, id, t)) end,
            GetOperation = function() return op end,
        }
        return ns.SellingPlan.Candidates({
            rules = rules, formulaRun = run,
            bagItems = { { key = "2589", itemID = 2589, name = "Linen Cloth", count = 20, stacks = {} } },
        })
    end

    before_each(function()
        ns = {}
        for _, name in ipairs({ "ScanClock", "ScanRecord", "ScanSources", "ScanStore", "ItemString", "GroupTree",
            "FormulaParse", "FormulaFunctions", "FormulaSources", "FormulaLookup", "FormulaEval", "FormulaRun",
            "SellingPlan" }) do
            load(manifest.path(name))
        end
        store = ns.ScanStore.New({}, { region = "beta", ruleset = "standard", schemaVersion = 1 })
        run = ns.FormulaRun.New({
            store = store,
            sources = ns.FormulaSources.New({ itemCache = { Get = function() end, Request = function() end } }),
            serverTime = function() return NOW end,
        })
    end)

    it("gives no data for a record that holds only latest, and names scanmarket", function()
        local record = assert(ns.ScanRecord.Decode("1;" .. (NOW - 3600) .. ",15,17,8381,202,1;;"))
        local c = candidates(record)[1]
        assert.equal("no data for min price: scanmarket missing, scan again", c.reason)
    end)

    it("prices a record that has a snapshot of today", function()
        local record = ns.ScanRecord.New()
        record.latest = { time = NOW - 3600, min = 15, market = 17, qty = 8381, auctions = 202, partial = false }
        local snap = { time = NOW - 3600, min = 15, market = 17, qty = 8381, auctions = 202 }
        record.today = { day = 20000, snaps = { snap } }
        local c = candidates(record)[1]
        assert.is_nil(c.reason)
        assert.equal(17, c.normalPrice)
        assert.equal(34, c.maxPrice)
    end)
end)

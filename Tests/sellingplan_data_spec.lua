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
            GroupOf = function(_, key) return ns.GroupTree.GroupOf(data, key) end,
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

-- The Default selling operation: lowest auction - 1c, vendor price as the floor, no scan data needed.
describe("SellingPlan with the Default operation", function()
    local ns, rules, run, store, infos

    local DAY = 86400
    local NOW = 20000 * DAY + 3600 * 6

    local function load(path)
        assert(loadfile(path))("Flipside", ns)
    end

    local function candidate(key, itemID, dataStats)
        local out = ns.SellingPlan.Candidates({
            rules = rules, formulaRun = run, dataStats = dataStats,
            bagItems = { { key = key, itemID = itemID, name = "Item", count = 10, stacks = {} } },
        })
        return out[1]
    end

    local function row(price, own)
        return { unitPrice = price, quantity = 1, ownerItem = own }
    end

    before_each(function()
        ns = {}
        for _, name in ipairs({ "ScanClock", "ScanRecord", "ScanSources", "ScanStore", "ItemString", "GroupTree",
            "SettingsDB", "OperationSchema", "RulesStore", "FormulaParse", "FormulaFunctions", "FormulaSources",
            "FormulaLookup", "FormulaEval", "FormulaRun", "SellingPlan" }) do
            load(manifest.path(name))
        end
        infos = {}
        store = ns.ScanStore.New({}, { region = "beta", ruleset = "standard", schemaVersion = 1 })
        run = ns.FormulaRun.New({
            store = store,
            sources = ns.FormulaSources.New({
                itemCache = { Get = function(_, id) return infos[id] end, Request = function() end },
            }),
            serverTime = function() return NOW end,
        })
        local db = ns.SettingsDB.New({}, { character = "Me", schemaVersion = 1 })
        rules = ns.RulesStore.New(db, { seedDefault = true })
    end)

    it("covers an item of no group, with no scan data", function()
        infos[100] = { sellPrice = 50 }
        local c = candidate("100", 100)
        assert.is_nil(c.reason)
        assert.equal("Default", c.operationName)
        assert.equal(1, c.groupID)
        local d = ns.SellingPlan.Decide(c, { row(1000), row(1200) }, { maxStack = 20 })
        assert.equal("post", d.action)
        assert.equal(999, d.price)
        assert.equal(10, d.quantity)
    end)

    it("covers a group that has no selling operation", function()
        infos[100] = { sellPrice = 50 }
        local g = rules:CreateGroup(1, "Herbs")
        rules:AddItem("100", g)
        local c = candidate("100", 100)
        assert.equal("Default", c.operationName)
        assert.same({ "Base", "Herbs" }, c.groupPath)
    end)

    it("keeps the operation of a group that has its own", function()
        local g = rules:CreateGroup(1, "Herbs")
        rules:AddItem("100", g)
        local own = rules:CreateOperation("selling", "Own")
        rules:SetSetting(own, "minPrice", "7")
        rules:AttachOperation(g, "selling", own)
        local c = candidate("100", 100)
        assert.equal("Own", c.operationName)
        assert.equal(7, c.minPrice)
    end)

    it("skips below the vendor price", function()
        infos[100] = { sellPrice = 600 }
        local d = ns.SellingPlan.Decide(candidate("100", 100), { row(500) }, { maxStack = 20 })
        assert.equal("skip", d.action)
        assert.equal("below minimum", d.reason)
        assert.equal(600, d.floor)
    end)

    it("posts at the lowest price minus 1c when the vendor price is unknown", function()
        local c = candidate("100", 100)
        assert.equal(1, c.minPrice)
        local d = ns.SellingPlan.Decide(c, { row(2) }, { maxStack = 20 })
        assert.equal("post", d.action)
        assert.equal(1, d.price)
    end)

    it("posts at the market value when there is no competitor", function()
        infos[100] = { sellPrice = 50 }
        local record = ns.ScanRecord.New()
        record.latest = { time = NOW - 60, min = 400, market = 450, qty = 5, auctions = 2, partial = false }
        local snap = { time = NOW - 60, min = 400, market = 450, qty = 5, auctions = 2 }
        record.today = { day = 20000, snaps = { snap } }
        store:Put("100", record)
        local d = ns.SellingPlan.Decide(candidate("100", 100), {}, { maxStack = 20 })
        assert.equal("post", d.action)
        assert.equal(450, d.price)
    end)

    it("skips with no price when there is no competitor and no market value", function()
        infos[100] = { sellPrice = 50 }
        local d = ns.SellingPlan.Decide(candidate("100", 100), {}, { maxStack = 20 })
        assert.equal("skip", d.action)
        assert.matches("^no price", d.reason)
    end)

    it("needs no fresh data and no samples, even with a thin old record", function()
        infos[100] = { sellPrice = 50 }
        local c = candidate("100", 100, function() return { ageHours = 5000, samples = 0 } end)
        assert.is_nil(c.reason)
        local d = ns.SellingPlan.Decide(c, { row(1000) }, { maxStack = 20 })
        assert.equal("post", d.action)
        assert.equal(999, d.price)
    end)

    it("still skips on a formula error", function()
        local id = rules:ListOperations("selling")[1].id
        rules:SetSetting(id, "normalPrice", "scanmarket")
        local run2 = { Evaluate = function(_, text)
            if text == "scanmarket" then
                return nil, { kind = "error", message = "bad" }
            end
            return 5, { kind = "ok" }
        end }
        local out = ns.SellingPlan.Candidates({
            rules = rules, formulaRun = run2,
            bagItems = { { key = "100", itemID = 100, name = "Item", count = 1, stacks = {} } },
        })
        assert.equal("formula error: bad", out[1].reason)
    end)
end)

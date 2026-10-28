local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end }
    for _, name in ipairs({ "EventBus", "SettingsDB", "ItemString", "OperationSchema", "ItemNameIndex", "BuyingPlan",
        "Theme", "Widgets", "Window", "List", "Tree", "Tabs", "Columns", "AuctionTabs", "BuyingTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

describe("BuyingTab Vendor source", function()
    local ns, bus, client, tab, ui, db, timers, records, sell, requests, lastScan, held

    local SCAN = 1000

    local function makeClient()
        local c = { searches = {}, rows = {} }
        c.CanLiveSearch = function() return true end
        c.IsReady = function() return true end
        c.LiveSearch = function(itemID)
            c.searches[#c.searches + 1] = itemID
            return true
        end
        c.LiveRows = function(itemID) return c.rows[itemID] or {} end
        c.LiveResultEvents = function() return "COMMODITY_RESULTS", "ITEM_RESULTS" end
        c.ReadyEvent = function() return "READY" end
        c.CloseEvent = function() return "CLOSE" end
        c.BuyEvents = function() return nil end
        c.CanBuy = function() return true end
        return c
    end

    local function makeRules()
        return {
            Walk = function() end,
            Children = function() return {} end,
            Name = function() return "Base" end,
            ItemsIn = function() return {} end,
            Path = function() return { "Base" } end,
            GroupOf = function() return nil end,
            EffectiveOperation = function() return nil end,
            GetOperation = function() return nil end,
        }
    end

    local function record(min, time)
        return { latest = { time = time or SCAN, min = min, market = min, qty = 1, auctions = 1 } }
    end

    local function mount(extra)
        local deps = {
            bus = bus, rules = makeRules(), client = client, db = db,
            formulaRun = {
                Evaluate = function(_, text, key)
                    local price = sell[tonumber(key)]
                    if text == "vendorsell" then
                        return price
                    elseif text == "vendorsell*2" then
                        return price and price * 2
                    end
                    return nil, { kind = "error", message = "bad" }
                end,
                Compile = function(_, text)
                    if text:find("!", 1, true) then
                        return nil, { message = "bad formula" }
                    end
                    return {}
                end,
            },
            scanStore = {
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
            itemCache = {
                Get = function(_, itemID)
                    if sell[itemID] then
                        return { sellPrice = sell[itemID] }, "loaded"
                    end
                    return nil, requests[itemID] and "requested" or "unknown"
                end,
                Request = function(_, itemID) requests[itemID] = true end,
            },
            lastScan = function() return lastScan end,
            isAuctionHouseOpen = function() return true end,
            after = function(seconds, fn) timers[#timers + 1] = { seconds = seconds, fn = fn } end,
            itemInfo = function(id) return "item " .. id, 1 end,
        }
        for k, v in pairs(extra or {}) do
            deps[k] = v
        end
        local core = ns.BuyingTab.New(deps)
        core:Mount(CreateFrame("Frame", nil, UIParent), { Enter = function() end, Leave = function() end })
        return core
    end

    before_each(function()
        mock.reset()
        _G.ScrollUtil = nil
        getmetatable(CreateFrame("Frame")).__index.SetJustifyH = function() end
        ns = loadModules()
        bus = ns.EventBus.New({})
        db = ns.SettingsDB.New({}, { character = "Alice-Realm", schemaVersion = 1 })
        timers, requests, held = {}, {}, nil
        records, sell, lastScan = {}, {}, SCAN
        client = makeClient()
        ns.BuyingPlan.Log:Clear()
        tab = mount()
        ui = tab.ui
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("the source tab", function()
        it("is the third source, after Groups and Lists", function()
            assert.is_true(ui.sourceTabs.buttons[3]:IsShown())
            assert.is_false(ui.vendorInput:IsShown())
            assert.is_true(tab:SetSource("vendor"))
            assert.are.equal("vendor", tab.source)
            assert.is_true(ui.vendorInput:IsShown())
            assert.is_true(tab:SetSource("groups"))
            assert.is_false(ui.vendorInput:IsShown())
        end)

        it("is off without the scan store", function()
            local plain = mount({ scanStore = false })
            assert.is_false(plain:SetSource("vendor"))
            assert.is_false(plain.ui.sourceTabs.buttons[3]:IsShown())
        end)
    end)

    describe("the list", function()
        it("shows the items below the max price, the most profit first, with the max price", function()
            sell[100], sell[200], sell[300] = 1000, 1000, 1000
            records["100"], records["200"], records["300"] = record(900), record(100), record(1000)
            tab:SetSource("vendor")
            assert.are.equal(2, #tab.list)
            assert.are.equal("200", tab.list[1].key)
            assert.are.equal(1000, tab.list[1].maxPrice)
            assert.are.equal("100", tab.list[2].key)
            assert.are.equal(2, #tab.nodes)
            assert.are.equal("item 200", tab.nodes[1].text)
        end)

        it("says that a full scan is needed when there is no scan", function()
            lastScan = nil
            tab:SetSource("vendor")
            assert.are.equal("Run a full scan first.", ui.vendorStatus.text)
            assert.are.equal("Run a full scan first.", ui.summary.text)
        end)

        it("says that no item is below the max price", function()
            sell[100] = 1000
            records["100"] = record(1000)
            tab:SetSource("vendor")
            assert.are.equal("No items below the max price in the last scan.", ui.vendorStatus.text)
            assert.are.equal("No items below the max price in the last scan.", ui.summary.text)
        end)

        it("shows Building list... while the job runs and the list when it ends", function()
            sell[100] = 1000
            records["100"] = record(100)
            local fakeJob = { Checkpoint = function() end }
            tab = mount({ runJob = function(_, fn) held = fn end })
            tab:SetSource("vendor")
            assert.are.equal("Building list...", tab.ui.vendorStatus.text)
            assert.are.equal("Building list...", tab.ui.summary.text)
            held(fakeJob)
            assert.are.equal(1, #tab.list)
            assert.are.equal("", tab.ui.vendorStatus.text)
        end)

        it("keeps the built list between two opens", function()
            sell[100] = 1000
            records["100"] = record(100)
            local builds = 0
            tab = mount({ runJob = function(_, fn) builds = builds + 1 fn({ Checkpoint = function() end }) end })
            tab:SetSource("vendor")
            tab:SetSource("groups")
            tab:SetSource("vendor")
            assert.are.equal(1, builds)
        end)

        it("builds again after a scan", function()
            sell[100] = 1000
            tab:Select()
            tab:SetSource("vendor")
            assert.are.equal(0, #tab.list)
            records["100"] = record(100)
            bus:Emit("Flipside.ScanFinished", {})
            assert.are.equal(1, #tab.list)
        end)

        it("asks for item data and builds again when it arrives", function()
            records["100"] = record(100)
            tab:Select()
            tab:SetSource("vendor")
            assert.is_true(requests[100])
            assert.are.equal(0, #tab.list)
            sell[100] = 1000
            bus:Emit("ITEM_DATA_LOAD_RESULT", 100, true)
            bus:Emit("ITEM_DATA_LOAD_RESULT", 100, true)
            assert.are.equal(1, #timers)
            timers[1].fn()
            assert.are.equal(1, #tab.list)
        end)

        it("does not build again for an item that it did not ask for", function()
            tab:Select()
            tab:SetSource("vendor")
            bus:Emit("ITEM_DATA_LOAD_RESULT", 555, true)
            assert.are.equal(0, #timers)
        end)
    end)

    describe("the formula", function()
        it("has the default vendorsell", function()
            assert.are.equal("vendorsell", tab:GetVendorFormula())
            tab:SetSource("vendor")
            assert.are.equal("vendorsell", ui.vendorInput:GetText())
        end)

        it("saves a valid formula in the profile and builds the list again", function()
            sell[100] = 1000
            records["100"] = record(1500)
            tab:SetSource("vendor")
            assert.are.equal(0, #tab.list)
            assert.is_true(tab:SetVendorFormula(" vendorsell*2 "))
            assert.are.equal("vendorsell*2", db:Get("profile", "buying.vendorFormula"))
            assert.are.equal("vendorsell*2", tab:GetVendorFormula())
            assert.are.equal(1, #tab.list)
            assert.are.equal(2000, tab.list[1].maxPrice)
        end)

        it("shows the error and does not save a formula that does not compile", function()
            tab:SetSource("vendor")
            local ok, err = tab:SetVendorFormula("1 !")
            assert.is_false(ok)
            assert.are.equal("bad formula", err)
            assert.is_nil(db:Get("profile", "buying.vendorFormula"))
            assert.are.equal("vendorsell", tab:GetVendorFormula())
            assert.are.equal("Formula error: bad formula", ui.vendorStatus.text)
        end)

        it("does not save an empty formula", function()
            tab:SetSource("vendor")
            assert.is_false(tab:SetVendorFormula("  "))
            assert.is_nil(db:Get("profile", "buying.vendorFormula"))
        end)
    end)

    describe("a click on an item", function()
        it("starts the live search with the formula result as the max price", function()
            sell[100] = 1000
            records["100"] = record(100)
            tab:SetSource("vendor")
            tab:_OnTreeSelect(tab.nodes[1])
            assert.are.equal("100", tab.selectedKey)
            assert.are.same({ 100 }, client.searches)
            client.rows[100] = { { unitPrice = 300, quantity = 2, auctionID = 1 },
                { unitPrice = 1500, quantity = 1, auctionID = 2 } }
            bus:Emit("COMMODITY_RESULTS", 100)
            local result = tab.results["100"].result
            assert.are.equal(1000, result.maxPrice)
            assert.are.equal(2, result.quantity)
        end)
    end)
end)

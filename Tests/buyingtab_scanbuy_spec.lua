local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end, Flavour = { hasCommodityMarket = true } }
    for _, name in ipairs({ "EventBus", "SettingsDB", "ItemString", "OperationSchema", "ItemNameIndex", "BuyingPlan",
        "BuyWalk", "Theme", "Widgets", "Window", "List", "Tree", "Tabs", "Columns", "AuctionTabs", "BuyingTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

describe("BuyingTab Scan and buy", function()
    local ns, bus, client, tab, ui, db, records, sell, lastScan, lastPartial, engine, accept, ready

    local SCAN = 1000

    local function row(price, quantity)
        return { unitPrice = price, quantity = quantity, ownerItem = false, auctionID = price }
    end

    local function makeClient()
        local c = { searches = {}, rows = {}, calls = {} }
        c.CanLiveSearch = function() return true end
        c.IsReady = function() return ready end
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

    local function record(min)
        return { latest = { time = SCAN, min = min, market = min, qty = 1, auctions = 1 } }
    end

    local function mount()
        local deps = {
            bus = bus, rules = makeRules(), client = client, db = db,
            formulaRun = {
                Evaluate = function(_, _, key) return sell[tonumber(key)] end,
                Compile = function() return {} end,
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
                GetState = function(_, itemID) return sell[itemID] and "loaded" or "unknown" end,
                Get = function(_, itemID)
                    if sell[itemID] then
                        return { sellPrice = sell[itemID] }, "loaded"
                    end
                    return nil, "unknown"
                end,
                Request = function() end,
            },
            lastScan = function() return lastScan, lastPartial end,
            isAuctionHouseOpen = function() return true end,
            after = function() end,
            itemInfo = function(id) return "item " .. id, 1 end,
            scanEngine = engine,
            confirmScan = function(onAccept) accept = onAccept end,
        }
        local core = ns.BuyingTab.New(deps)
        core:Mount(CreateFrame("Frame", nil, UIParent), { Enter = function() end, Leave = function() end })
        return core
    end

    local function fire(event, ...)
        bus:Emit(event, ...)
    end

    -- Two candidates: item 200 has the most profit and comes first.
    local function fillRecords()
        sell[100], sell[200] = 1000, 1000
        records["100"], records["200"] = record(900), record(100)
    end

    before_each(function()
        mock.reset()
        _G.ScrollUtil = nil
        getmetatable(CreateFrame("Frame")).__index.SetJustifyH = function() end
        ns = loadModules()
        bus = ns.EventBus.New({})
        db = ns.SettingsDB.New({}, { character = "Alice-Realm", schemaVersion = 1 })
        records, sell, lastScan, lastPartial, accept, ready = {}, {}, SCAN, false, nil, true
        engine = {
            canStart = true, reason = nil, started = 0,
            CanStart = function(self) return self.canStart, self.reason end,
            Start = function(self)
                self.started = self.started + 1
                return true
            end,
        }
        client = makeClient()
        ns.BuyingPlan.Log:Clear()
        tab = mount()
        ui = tab.ui
        fillRecords()
        tab:SetSource("vendor")
    end)

    after_each(function()
        mock.teardown()
    end)

    it("shows the button on the Vendor source only, with the scan deps", function()
        assert.is_true(ui.scanBuy:IsShown())
        assert.is_false(ui.walkSkip:IsShown())
        assert.is_false(ui.walkStop:IsShown())
        tab:SetSource("groups")
        assert.is_false(ui.scanBuy:IsShown())
    end)

    describe("with no cooldown", function()
        it("starts a full scan only after the confirm", function()
            assert.is_true(tab:ScanAndBuy())
            assert.are.equal(0, engine.started)
            assert.is_function(accept)
            accept()
            assert.are.equal(1, engine.started)
            assert.is_true(tab.walk:IsWaitingForScan())
            assert.are.same({}, client.searches)
            assert.is_false(ui.scanBuy.enabled)
        end)

        it("selects the first row and starts its search when the full scan ends", function()
            tab:ScanAndBuy()
            accept()
            fire("Flipside.ScanFinished", { result = "ok", mode = "full" })
            assert.is_true(tab.walk:IsWalking())
            assert.are.equal("200", tab.selectedKey)
            assert.are.same({ 200 }, client.searches)
            assert.is_true(ui.walkSkip:IsShown())
            assert.is_true(ui.walkStop:IsShown())
        end)

        it("stops with a message when the scan is partial", function()
            tab:ScanAndBuy()
            accept()
            fire("Flipside.ScanFinished", { result = "partial", mode = "full" })
            assert.is_false(tab.walk:IsActive())
            assert.are.equal(ns.BuyWalk.TEXT.partial, ui.message.text)
            assert.are.same({}, client.searches)
        end)

        it("stops with a message when the scan fails", function()
            tab:ScanAndBuy()
            accept()
            fire("Flipside.ScanFinished", { result = "error", mode = "full" })
            assert.is_false(tab.walk:IsActive())
            assert.are.equal(ns.BuyWalk.TEXT.failed, ui.message.text)
        end)

        it("does not start the walk for a scan that the user started", function()
            fire("Flipside.ScanFinished", { result = "ok", mode = "full" })
            assert.is_false(tab.walk:IsActive())
            assert.are.same({}, client.searches)
        end)

        it("shows the refusal of the scan engine", function()
            engine.canStart, engine.reason = false, "ah-closed"
            assert.is_false(tab:ScanAndBuy())
            assert.is_nil(accept)
            assert.is_truthy(ui.message.text:find("ah-closed", 1, true))
        end)
    end)

    describe("on cooldown", function()
        before_each(function()
            engine.canStart, engine.reason = false, "cooldown"
        end)

        it("skips the scan and walks over the list of a full scan", function()
            assert.is_true(tab:ScanAndBuy())
            assert.is_nil(accept)
            assert.are.equal(0, engine.started)
            assert.is_true(tab.walk:IsWalking())
            assert.are.equal("200", tab.selectedKey)
            assert.are.same({ 200 }, client.searches)
            assert.are.equal(ns.BuyWalk.TEXT.cooldown, ui.message.text)
        end)

        it("starts nothing and shows the empty state when there is no full scan", function()
            lastScan = nil
            tab:RefreshList()
            assert.is_false(tab:ScanAndBuy())
            assert.is_false(tab.walk:IsActive())
            assert.are.same({}, client.searches)
            assert.are.equal("Run a full scan first.", ui.message.text)
        end)

        it("starts nothing when the last scan was partial", function()
            lastPartial = true
            assert.is_false(tab:ScanAndBuy())
            assert.is_false(tab.walk:IsActive())
            assert.are.same({}, client.searches)
        end)

        it("starts nothing when the list is empty", function()
            records, sell = {}, {}
            tab.vendorDirty = true
            tab:RefreshList()
            assert.is_false(tab:ScanAndBuy())
            assert.are.equal("No items below the max price in the last scan.", ui.message.text)
        end)
    end)

    describe("the walk", function()
        before_each(function()
            engine.canStart, engine.reason = false, "cooldown"
            tab:ScanAndBuy()
        end)

        it("goes to the next row when no level is at or below the max price", function()
            client.rows[200] = { row(5000, 3) }
            fire("COMMODITY_RESULTS", 200)
            assert.are.equal("100", tab.selectedKey)
            assert.are.same({ 200, 100 }, client.searches)
        end)

        it("goes to the next row when the search finds no level", function()
            client.rows[200] = {}
            fire("COMMODITY_RESULTS", 200)
            assert.are.equal("100", tab.selectedKey)
        end)

        it("waits for the user while a level is buyable and never buys", function()
            client.rows[200] = { row(50, 3) }
            fire("COMMODITY_RESULTS", 200)
            assert.are.equal("200", tab.selectedKey)
            assert.is_true(tab.walk:IsWalking())
            assert.is_nil(tab.buy)
            assert.are.same({ 200 }, client.searches)
            assert.is_true(ui.buyNext.enabled)
        end)

        it("ends with a done message after the last row", function()
            client.rows[200], client.rows[100] = {}, {}
            fire("COMMODITY_RESULTS", 200)
            fire("COMMODITY_RESULTS", 100)
            assert.is_false(tab.walk:IsActive())
            assert.are.equal(ns.BuyWalk.TEXT.done, ui.message.text)
        end)

        it("moves on at once with Skip", function()
            tab:WalkSkip()
            assert.are.equal("100", tab.selectedKey)
            tab:WalkSkip()
            assert.is_false(tab.walk:IsActive())
            assert.are.equal(ns.BuyWalk.TEXT.done, ui.message.text)
        end)

        it("ends with Stop", function()
            assert.is_true(tab:WalkStop())
            assert.is_false(tab.walk:IsActive())
            assert.are.equal(ns.BuyWalk.TEXT.stopped, ui.message.text)
            client.rows[200] = {}
            fire("COMMODITY_RESULTS", 200)
            assert.are.same({ 200 }, client.searches)
        end)

        it("ends when the source changes", function()
            tab:SetSource("groups")
            assert.is_false(tab.walk:IsActive())
        end)

        it("ends when the Auction House closes", function()
            fire("CLOSE")
            assert.is_false(tab.walk:IsActive())
        end)

        it("ends when the tab is left", function()
            tab:Deselect()
            assert.is_false(tab.walk:IsActive())
        end)

        it("skips a row that left the list", function()
            tab.list = { tab.list[1] }
            tab:WalkSkip()
            assert.is_false(tab.walk:IsActive())
            assert.are.equal(ns.BuyWalk.TEXT.done, ui.message.text)
        end)
    end)

    it("starts the search again at the ready event when the client was not ready", function()
        ready = false
        engine.canStart, engine.reason = false, "cooldown"
        tab:ScanAndBuy()
        assert.are.same({}, client.searches)
        assert.is_true(tab.walkNeedSearch)
        ready = true
        fire("READY")
        assert.are.same({ 200 }, client.searches)
        assert.is_false(tab.walkNeedSearch)
    end)

    it("does not show the button without the scan engine", function()
        engine = nil
        local plain = mount()
        plain:SetSource("vendor")
        assert.is_false(plain.ui.scanBuy:IsShown())
        assert.is_false(plain:ScanAndBuy())
    end)
end)

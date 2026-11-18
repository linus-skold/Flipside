local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end }
    for _, name in ipairs({ "EventBus", "ItemString", "ScanKey", "BagItems", "SellingPlan", "BuyingPlan", "BuyFlow",
        "Theme", "Widgets", "MoneyInput", "Window", "List", "Columns", "Tree", "AuctionTabs", "BuyDialog",
        "SellingTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

describe("SellingTab level list", function()
    local ns, bus, client, tab, ui, bagItems, itemGroup, groups, store

    local function makeClient()
        local c = { ready = true, searches = {}, rows = {}, commodity = {}, calls = {}, violations = {}, canBuy = true }
        c.CanLiveSearch = function() return true end
        c.CanPost = function() return true end
        c.IsReady = function() return c.ready end
        c.LiveSearch = function(itemID)
            c.searches[#c.searches + 1] = itemID
            return true
        end
        c.LiveRows = function(itemID) return c.rows[itemID] or {} end
        c.LiveResultEvents = function() return "COMMODITY_RESULTS", "ITEM_RESULTS" end
        c.ReadyEvent = function() return "READY" end
        c.PostedEvent = function() return "CREATED" end
        c.ItemIsCommodity = function(itemID) return c.commodity[itemID] end
        c.CanReadOwned = function() return false end
        c.Deposit = function(_, _, _, quantity) return quantity * 10 end
        c.BuyEvents = function()
            return {
                priceUpdated = "QUOTE", priceUnavailable = "NOQUOTE", commoditySucceeded = "BOUGHT",
                commodityFailed = "NOTBOUGHT", itemCompleted = "ITEMBOUGHT", itemError = "ITEMERR",
            }
        end
        c.CanBuy = function() return c.canBuy end
        local function protected(name)
            return function(...)
                c.calls[#c.calls + 1] = { name, ... }
                if not c.inClick then
                    c.violations[#c.violations + 1] = name
                end
            end
        end
        c.StartCommodityPurchase = protected("start")
        c.ConfirmCommodityPurchase = protected("confirm")
        c.BuyItemAuction = protected("bid")
        c.CancelCommodityPurchase = function()
            c.calls[#c.calls + 1] = { "cancel" }
        end
        c.QuoteSecondsLeft = function() return 30 end
        return c
    end

    local function makeRules()
        return {
            Children = function(_, id) return groups[id].children end,
            Name = function(_, id) return groups[id].name end,
            GroupOf = function(_, key) return itemGroup[key] or 1 end,
            Walk = function(_, fn)
                for _, id in ipairs({ 1, 2 }) do
                    fn(id)
                end
            end,
            EffectiveOperation = function(_, id)
                if id == 2 then
                    return 7
                end
            end,
            GetOperation = function()
                return { name = "Sell", settings = {
                    minPrice = "10", normalPrice = "100", maxPrice = "200", undercut = 1, duration = 24,
                    vendorSkip = false,
                } }
            end,
            Path = function(_, id) return groups[id].name end,
            ItemsIn = function(_, id)
                local list = {}
                for key, group in pairs(itemGroup) do
                    if group == id then
                        list[#list + 1] = key
                    end
                end
                table.sort(list)
                return list
            end,
        }
    end

    local function crow(price, quantity, own)
        return { unitPrice = price, quantity = quantity, ownerItem = own or false, auctionID = price,
            isCommodity = true }
    end

    local function arow(price, quantity, own)
        return { unitPrice = price, quantity = quantity, ownerItem = own or false, auctionID = price,
            isCommodity = false, buyout = price * quantity, owner = "Bob" }
    end

    local function click(button)
        client.inClick = true
        button.scripts.OnClick(button)
        client.inClick = false
    end

    -- A click on row index of the level list, as the mouse does.
    local function clickLevel(index)
        local row = ui.levelList.rows[index]
        client.inClick = true
        row.scripts.OnClick(row)
        client.inClick = false
    end

    local function box()
        for _, frame in ipairs(mock.frames) do
            if frame.name == "FlipsideBuyConfirm" then
                return frame
            end
        end
    end

    local function names()
        local out = {}
        for _, call in ipairs(client.calls) do
            out[#out + 1] = call[1]
        end
        return out
    end

    local function mount(extra)
        local deps = {
            bus = bus, rules = makeRules(), formulaRun = { Evaluate = function(_, text) return tonumber(text) end },
            client = client, after = function() end,
            itemInfo = function(id) return "Item" .. id, 1 end,
            readBags = function() return bagItems end,
            maxStack = function(id) return id == 10 and 20 or 1 end,
            vendorPrice = function() return nil end,
            syncInterval = 0, time = function() return 0 end,
            db = {
                Get = function(_, scope, key) return store[scope .. "/" .. key] end,
                Set = function(_, scope, key, value) store[scope .. "/" .. key] = value end,
            },
        }
        for k, v in pairs(extra or {}) do
            deps[k] = v
        end
        local core = ns.SellingTab.New(deps)
        core:Mount(CreateFrame("Frame", nil, UIParent), { Enter = function() end, Leave = function() end })
        core:Select()
        return core
    end

    local function choose(itemID, rows)
        client.rows[itemID] = rows
        ui.tree:Select("i" .. itemID)
        bus:Emit(itemID == 10 and "ITEM_RESULTS" or "COMMODITY_RESULTS", itemID)
    end

    before_each(function()
        mock.reset()
        _G.ScrollUtil = nil
        local frameMethods = getmetatable(CreateFrame("Frame")).__index
        frameMethods.SetJustifyH = function() end
        ns = loadModules()
        bus = ns.EventBus.New({})
        client = makeClient()
        client.commodity[10] = false
        client.commodity[11] = true
        store = {}
        groups = { [1] = { name = "Base", children = { 2 } }, [2] = { name = "Cloth", children = {} } }
        itemGroup = { ["10"] = 2, ["11"] = 2 }
        bagItems = {
            { key = "11", itemID = 11, name = "Bolt of Linen", count = 12, stacks = {
                { bag = 0, slot = 4, count = 12 } } },
            { key = "10", itemID = 10, name = "Linen Cloth", count = 60, stacks = {
                { bag = 1, slot = 1, count = 20 }, { bag = 1, slot = 2, count = 20 },
                { bag = 1, slot = 3, count = 20 } } },
        }
        ns.BuyingPlan.Log:Clear()
        tab = mount()
        ui = tab.ui
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("the toggle", function()
        it("is off at first: all tree columns, no list", function()
            assert.are.equal("Levels", ui.levels.text)
            assert.is_false(ui.levelList.frame:IsShown())
            assert.is_false(ui.levelHeader.frame:IsShown())
            assert.is_nil(ns.SellingTab.COLUMNS[3].hidden)
            assert.is_nil(ns.SellingTab.COLUMNS[6].hidden)
            assert.are.equal(244, ns.SellingTab.COLUMNS[1].width)
            assert.are.equal(124, ns.SellingTab.COLUMNS[4].width)
        end)

        it("shows the list and the compact tree when on, and restores the tree when off", function()
            click(ui.levels)
            assert.are.equal("Hide", ui.levels.text)
            assert.is_true(ui.levelList.frame:IsShown())
            assert.is_true(ui.levelHeader.frame:IsShown())
            assert.is_true(ns.SellingTab.COLUMNS[3].hidden)
            assert.is_true(ns.SellingTab.COLUMNS[6].hidden)
            assert.are.equal(190, ns.SellingTab.COLUMNS[1].width)
            assert.are.equal(110, ns.SellingTab.COLUMNS[4].width)
            click(ui.levels)
            assert.are.equal("Levels", ui.levels.text)
            assert.is_false(ui.levelList.frame:IsShown())
            assert.is_nil(ns.SellingTab.COLUMNS[3].hidden)
            assert.is_nil(ns.SellingTab.COLUMNS[6].hidden)
            assert.are.equal(244, ns.SellingTab.COLUMNS[1].width)
        end)

        it("makes room at the right of the tree only while on", function()
            local before = ui.tree.frame.points[#ui.tree.frame.points]
            click(ui.levels)
            local after = ui.tree.frame.points[#ui.tree.frame.points]
            assert.is_true(after[4] < before[4])
            click(ui.levels)
            assert.are.equal(before[4], ui.tree.frame.points[#ui.tree.frame.points][4])
        end)

        it("is saved in the profile settings and read again when the tab opens", function()
            click(ui.levels)
            assert.is_true(store["profile/ui.sellingLevels"])
            tab:Unmount()
            tab = mount()
            ui = tab.ui
            assert.are.equal("Hide", ui.levels.text)
            assert.is_true(ui.levelList.frame:IsShown())
        end)

        it("moves the reason of the Info column to the warning line", function()
            click(ui.levels)
            choose(11, { crow(150, 5) })
            local entry = tab.entries[1].key == "11" and tab.entries[1] or tab.entries[2]
            local info = ns.SellingTab.InfoText(entry)
            assert.is_true(info ~= "")
            assert.are.equal(info, ui.details.warn.text)
        end)
    end)

    describe("the rows", function()
        it("are empty with no item shown", function()
            click(ui.levels)
            assert.are.same({}, ui.levelList.data)
        end)

        it("show the levels of the shown item cheapest first, with the own mark", function()
            click(ui.levels)
            choose(11, { crow(150, 5), crow(160, 4, true), crow(170, 2) })
            local data = ui.levelList.data
            assert.are.equal(3, #data)
            assert.are.same({ 150, 160, 170 }, { data[1].unitPrice, data[2].unitPrice, data[3].unitPrice })
            assert.are.same({ "5", "4", "2" }, { data[1].available, data[2].available, data[3].available })
            assert.are.same({ false, true, false }, { data[1].mine, data[2].mine, data[3].mine })
            assert.are.equal("Yours", data[2].yours)
            assert.are.equal("", data[1].yours)
        end)

        it("show the stacks of an item level as stacks x size", function()
            click(ui.levels)
            choose(10, { arow(150, 2), arow(150, 2), arow(160, 5) })
            local data = ui.levelList.data
            assert.are.equal("2 x 2", data[1].available)
            assert.are.equal("5", data[2].available)
        end)

        it("show the deal mark and the percent against the market value", function()
            ns.ScanSources = { Compute = function() return { scanMarket = 1000 } end }
            tab:Unmount()
            tab = mount({ getRecord = function() return {} end, now = function() return 1 end })
            ui = tab.ui
            click(ui.levels)
            choose(11, { crow(200, 5), crow(900, 4), crow(1200, 1) })
            local data = ui.levelList.data
            assert.are.same({ "-80%", "-10%", "+20%" }, { data[1].vs, data[2].vs, data[3].vs })
            assert.are.same({ true, false, false }, { data[1].deal, data[2].deal, data[3].deal })
            assert.are.equal("-", ns.SellingTab.VsText(100, nil))
        end)

        it("clear while a search runs and read the new rows after it", function()
            click(ui.levels)
            choose(11, { crow(150, 5) })
            assert.are.equal(1, #ui.levelList.data)
            tab:_Research(tab.entries[1].key == "11" and tab.entries[1] or tab.entries[2])
            assert.are.same({}, ui.levelList.data)
            client.rows[11] = { crow(150, 5), crow(160, 4) }
            bus:Emit("COMMODITY_RESULTS", 11)
            assert.are.equal(2, #ui.levelList.data)
        end)

        it("are empty with the list off", function()
            choose(11, { crow(150, 5) })
            assert.are.same({}, ui.levelList.data)
        end)
    end)

    describe("the selection", function()
        it("changes the button text, and a second click clears it", function()
            click(ui.levels)
            choose(11, { crow(150, 5), crow(160, 4) })
            assert.are.equal("Buy lowest", ui.buyLowest.text)
            clickLevel(2)
            assert.are.equal("Buy selected", ui.buyLowest.text)
            assert.is_true(ui.buyLowest.enabled)
            clickLevel(2)
            assert.are.equal("Buy lowest", ui.buyLowest.text)
        end)

        it("does not select a level of yours", function()
            click(ui.levels)
            choose(11, { crow(150, 5, true), crow(160, 4) })
            clickLevel(1)
            assert.is_nil(tab.levelSel)
            assert.are.equal("Buy lowest", ui.buyLowest.text)
            assert.are.same({}, client.calls)
        end)

        it("clears on a new search and when the list goes off", function()
            click(ui.levels)
            choose(11, { crow(150, 5), crow(160, 4) })
            clickLevel(2)
            click(ui.levels)
            assert.is_nil(tab.levelSel)
            assert.are.equal("Buy lowest", ui.buyLowest.text)
        end)
    end)

    describe("Buy selected on a commodity", function()
        it("asks for the units of all levels up to the selected level, and buys only after the confirm", function()
            click(ui.levels)
            choose(11, { crow(150, 2), crow(160, 3), crow(170, 4) })
            clickLevel(3)
            click(ui.buyLowest)
            assert.are.same({ { "start", 11, 9 } }, client.calls)
            assert.is_nil(box())
            bus:Emit("QUOTE", 160, 1440)
            assert.is_true(box():IsShown())
            assert.is_truthy(box().text.text:find("Buy 9 x", 1, true))
            assert.are.same({ "start" }, names())
            click(box().yesButton)
            assert.are.same({ { "start", 11, 9 }, { "confirm", 11, 9 } }, client.calls)
            assert.are.same({}, client.violations)
        end)

        it("searches again and reads the new rows after the buy", function()
            click(ui.levels)
            choose(11, { crow(150, 2), crow(160, 3), crow(170, 4) })
            clickLevel(2)
            click(ui.buyLowest)
            bus:Emit("QUOTE", 156, 780)
            click(box().yesButton)
            local before = #client.searches
            bus:Emit("BOUGHT")
            assert.are.equal(before + 1, #client.searches)
            assert.is_nil(tab.levelSel)
            assert.are.same({}, ui.levelList.data)
            client.rows[11] = { crow(170, 4) }
            bus:Emit("COMMODITY_RESULTS", 11)
            assert.are.equal(1, #ui.levelList.data)
            assert.are.equal("Buy lowest", ui.buyLowest.text)
            local list = ns.BuyingPlan.Log:List()
            assert.is_truthy(list[#list].decision:find("^bought 5 at "))
        end)

        it("is off when a level of yours is below the selected level", function()
            click(ui.levels)
            choose(11, { crow(150, 2, true), crow(160, 3), crow(170, 4) })
            clickLevel(3)
            assert.is_false(ui.buyLowest.enabled)
            click(ui.buyLowest)
            assert.are.same({}, client.calls)
        end)

        it("is off when the selected level is gone after a new search", function()
            click(ui.levels)
            choose(11, { crow(150, 2), crow(160, 3) })
            clickLevel(2)
            client.rows[11] = { crow(150, 2) }
            tab:_Research(tab.entries[1].key == "11" and tab.entries[1] or tab.entries[2])
            bus:Emit("COMMODITY_RESULTS", 11)
            assert.is_nil(tab.levelSel)
            assert.are.equal("Buy lowest", ui.buyLowest.text)
        end)
    end)

    describe("Buy selected on an item auction", function()
        it("goes to the confirm and buys the selected auction at its buyout", function()
            click(ui.levels)
            choose(10, { arow(150, 1), arow(160, 2), arow(170, 1) })
            clickLevel(2)
            click(ui.buyLowest)
            assert.are.same({}, client.calls)
            assert.is_true(box():IsShown())
            assert.is_truthy(box().text.text:find("Buy one stack: 2 x", 1, true))
            click(box().yesButton)
            assert.are.same({ { "bid", 160, 320 } }, client.calls)
            assert.are.same({}, client.violations)
        end)

        it("finds the auction again at the confirm and does not buy a gone auction", function()
            click(ui.levels)
            choose(10, { arow(150, 1), arow(160, 2) })
            clickLevel(2)
            click(ui.buyLowest)
            client.rows[10] = { arow(150, 1) }
            click(box().yesButton)
            assert.are.same({}, client.calls)
            assert.is_nil(tab.buy)
        end)

        it("keeps the guards: one buy at a time, Post and Skip off", function()
            click(ui.levels)
            choose(10, { arow(150, 1), arow(160, 2) })
            clickLevel(2)
            click(ui.buyLowest)
            assert.is_false(ui.postNext.enabled)
            assert.is_false(ui.skip.enabled)
            assert.is_false(ui.buyLowest.enabled)
            assert.is_false((tab:SelectLevel(ns.BuyFlow.LevelId(ui.levelList.data[1]))))
        end)
    end)
end)

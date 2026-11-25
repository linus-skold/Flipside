local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end }
    for _, name in ipairs({ "EventBus", "ItemString", "ScanKey", "BagItems", "SellingPlan", "BuyingPlan", "BuyFlow",
        "Theme", "Widgets", "MoneyInput", "Window", "Prompt", "List", "Columns", "Tree", "AuctionTabs", "BuyDialog",
        "SellingTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

describe("SellingTab level pane and the buy menu", function()
    local ns, bus, client, tab, ui, bagItems, itemGroup, groups

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

    -- A shift and left click on row index of the level list.
    local function shiftClickLevel(index)
        _G.IsShiftKeyDown = function() return true end
        clickLevel(index)
        _G.IsShiftKeyDown = nil
    end

    -- The id of the level at row index.
    local function levelId(index)
        return ui.levelList.data[index].id
    end

    -- Click entry entryNo (default: the first) of the buy menu of the level at row index, as a hardware click.
    local function menuClick(index, entryNo)
        local entries = tab:LevelMenuEntries(levelId(index))
        client.inClick = true
        entries[entryNo or 1].onClick()
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

    -- The yellow of your own rows and the green of a deal price.
    local YELLOW = { 1, 0.82, 0.1 }
    local GREEN = { 0.4, 1, 0.4 }

    local function colorOf(label)
        return { label.color[1], label.color[2], label.color[3] }
    end

    describe("the pane", function()
        it("is always shown, with no toggle", function()
            assert.is_nil(ui.levels)
            assert.is_true(ui.levelList.frame:IsShown())
            assert.is_true(ui.levelHeader.frame:IsShown())
            assert.is_nil(ui.buyRow)
        end)

        it("has the compact tree: Operation and Info hidden, no Lowest column", function()
            assert.is_true(ns.SellingTab.COLUMNS[3].hidden)
            assert.is_true(ns.SellingTab.COLUMNS[5].hidden)
            assert.is_nil(ui.headers.labels.lowest)
            for _, column in ipairs(ns.SellingTab.COLUMNS) do
                assert.are_not.equal("lowest", column.key)
            end
        end)

        it("has only the price and the Available columns: no vs market and no Yours", function()
            local keys = {}
            for _, column in ipairs(ns.SellingTab.LEVEL_COLUMNS) do
                keys[#keys + 1] = column.key
            end
            assert.are.same({ "price", "available" }, keys)
            assert.is_nil(ui.levelHeader.labels.vs)
            assert.is_nil(ui.levelHeader.labels.yours)
        end)

        it("makes room at the right of the tree", function()
            local point = ui.tree.frame.points[#ui.tree.frame.points]
            assert.is_true(point[4] < 0)
        end)

        it("is wide (320) for a wide content and tight (220) for a narrow one", function()
            tab.content.GetWidth = function() return 800 end
            assert.are.equal(320, tab:_LevelWidth())
            tab.content.GetWidth = function() return 700 end
            assert.are.equal(220, tab:_LevelWidth())
        end)

        it("moves the reason of the Info column to the warning line", function()
            choose(11, { crow(150, 5) })
            local entry = tab.entries[1].key == "11" and tab.entries[1] or tab.entries[2]
            local info = ns.SellingTab.InfoText(entry)
            assert.is_true(info ~= "")
            assert.are.equal(info, ui.details.warn.text)
        end)

        it("has no amount box and no Buy button, and the pane gets the height down to the content", function()
            assert.is_nil(ui.buy)
            assert.is_nil(ui.amount)
            assert.is_nil(ui.buyInfo)
            assert.is_nil(ui.buyLowest)
            local bottom
            for _, point in ipairs(ui.levelList.frame.points) do
                if point[1] == "BOTTOMRIGHT" then
                    bottom = point
                end
            end
            assert.are.equal(0, bottom[5])
        end)
    end)

    describe("the rows", function()
        it("are empty with no item shown", function()
            assert.are.same({}, ui.levelList.data)
        end)

        it("show the levels cheapest first, and your own level is marked yellow", function()
            choose(11, { crow(150, 5), crow(160, 4, true), crow(170, 2) })
            local data = ui.levelList.data
            assert.are.equal(3, #data)
            assert.are.same({ 150, 160, 170 }, { data[1].unitPrice, data[2].unitPrice, data[3].unitPrice })
            assert.are.same({ "5", "4", "2" }, { data[1].available, data[2].available, data[3].available })
            assert.are.same({ false, true, false }, { data[1].mine, data[2].mine, data[3].mine })
            local rows = ui.levelList.rows
            assert.are.same(YELLOW, colorOf(rows[2].levelParts.cells.price))
            assert.are.same(YELLOW, colorOf(rows[2].levelParts.cells.available))
            assert.is_true(rows[2].levelParts.mark:IsShown())
            assert.is_false(rows[1].levelParts.mark:IsShown())
            assert.are.same({ 1, 1, 1 }, colorOf(rows[1].levelParts.cells.price))
        end)

        it("show the price of a deal in green (30 percent or more under the market value)", function()
            ns.ScanSources = { Compute = function() return { scanMarket = 1000 } end }
            tab:Unmount()
            tab = mount({ getRecord = function() return {} end, now = function() return 1 end })
            ui = tab.ui
            choose(11, { crow(200, 5), crow(900, 4), crow(1200, 1) })
            local data = ui.levelList.data
            assert.are.same({ true, false, false }, { data[1].deal, data[2].deal, data[3].deal })
            local rows = ui.levelList.rows
            assert.are.same(GREEN, colorOf(rows[1].levelParts.cells.price))
            assert.are.same({ 1, 1, 1 }, colorOf(rows[2].levelParts.cells.price))
            assert.are.same({ 1, 1, 1 }, colorOf(rows[3].levelParts.cells.price))
        end)

        it("keep the yellow of your own row, also when its price is a deal", function()
            ns.ScanSources = { Compute = function() return { scanMarket = 1000 } end }
            tab:Unmount()
            tab = mount({ getRecord = function() return {} end, now = function() return 1 end })
            ui = tab.ui
            choose(11, { crow(200, 5, true), crow(900, 4) })
            assert.are.same(YELLOW, colorOf(ui.levelList.rows[1].levelParts.cells.price))
        end)

        it("show the stacks of an item level as stacks x size", function()
            choose(10, { arow(150, 2), arow(150, 2), arow(160, 5) })
            local data = ui.levelList.data
            assert.are.equal("2 x 2", data[1].available)
            assert.are.equal("5", data[2].available)
        end)

        it("show a Forever item row of 40 as 40 stacks of 1", function()
            choose(10, { { unitPrice = 449, quantity = 40, ownerItem = false, auctionID = 7, isCommodity = false,
                buyout = 449, owner = "Bob", perItem = true } })
            assert.are.equal("40", ui.levelList.data[1].available)
        end)

        it("clear while a search runs and read the new rows after it", function()
            choose(11, { crow(150, 5) })
            assert.are.equal(1, #ui.levelList.data)
            tab:_Research(tab.entries[1].key == "11" and tab.entries[1] or tab.entries[2])
            assert.are.same({}, ui.levelList.data)
            client.rows[11] = { crow(150, 5), crow(160, 4) }
            bus:Emit("COMMODITY_RESULTS", 11)
            assert.are.equal(2, #ui.levelList.data)
        end)

        it("have a header Price for a single item and Unit price for a commodity", function()
            -- Forever has no stacks: an item auction is a single item.
            choose(10, { arow(150, 1) })
            assert.are.equal("Price", ui.levelHeader.labels.price.text)
            choose(11, { crow(150, 5) })
            assert.are.equal("Unit price", ui.levelHeader.labels.price.text)
        end)
    end)

    describe("the selection", function()
        it("selects a level with a click, and a second click clears it", function()
            choose(11, { crow(150, 5), crow(160, 4) })
            clickLevel(2)
            assert.are.equal(160, tab.levelSel)
            clickLevel(2)
            assert.is_nil(tab.levelSel)
        end)

        it("does not select a level of yours", function()
            choose(11, { crow(150, 5, true), crow(160, 4) })
            clickLevel(1)
            assert.is_nil(tab.levelSel)
            assert.are.same({}, client.calls)
        end)

        it("clears on a new search", function()
            choose(11, { crow(150, 5), crow(160, 4) })
            clickLevel(2)
            tab:_Research(tab.entries[1].key == "11" and tab.entries[1] or tab.entries[2])
            assert.is_nil(tab.levelSel)
        end)
    end)

    describe("the range", function()
        local function selectedRows()
            local out = {}
            for index, row in ipairs(ui.levelList.rows) do
                out[index] = row.levelParts.select:IsShown()
            end
            return out
        end

        it("is made by a shift click: from the selected level to the clicked level, both included", function()
            choose(11, { crow(150, 2), crow(160, 3), crow(170, 4), crow(180, 1) })
            clickLevel(1)
            ui.details.priceInput:SetCopper(99)
            shiftClickLevel(3)
            assert.are.same({ [150] = true, [160] = true, [170] = true }, tab.levelRange)
            assert.are.equal(150, tab.levelSel)
            assert.are.same({ true, true, true, false }, selectedRows())
            -- The range does not change the post price.
            assert.are.equal(99, ui.details.priceInput:GetCopper())
        end)

        it("goes from a higher level down to a lower level too", function()
            choose(11, { crow(150, 2), crow(160, 3), crow(170, 4) })
            clickLevel(3)
            shiftClickLevel(2)
            assert.are.same({ [160] = true, [170] = true }, tab.levelRange)
        end)

        it("is a normal click when no level is selected", function()
            choose(11, { crow(150, 2), crow(160, 3), crow(170, 4) })
            shiftClickLevel(2)
            assert.are.equal(160, tab.levelSel)
            assert.is_nil(tab.levelRange)
        end)

        it("is not made when it would include a level of yours: the message line gives the reason", function()
            choose(11, { crow(150, 2), crow(160, 3, true), crow(170, 4) })
            clickLevel(1)
            shiftClickLevel(3)
            assert.is_nil(tab.levelRange)
            assert.are.equal("a range cannot include your own level", ui.details.warn.text)
            assert.are.same({ true, false, false }, selectedRows())
        end)

        it("clears on a click on a level", function()
            choose(11, { crow(150, 2), crow(160, 3), crow(170, 4) })
            clickLevel(1)
            shiftClickLevel(3)
            clickLevel(2)
            assert.is_nil(tab.levelRange)
            assert.are.equal(160, tab.levelSel)
        end)

        it("clears on a new search", function()
            choose(11, { crow(150, 2), crow(160, 3), crow(170, 4) })
            clickLevel(1)
            shiftClickLevel(3)
            tab:_Research(tab.entries[1].key == "11" and tab.entries[1] or tab.entries[2])
            assert.is_nil(tab.levelRange)
            assert.is_nil(tab.levelSel)
        end)
    end)

    describe("the menu of a commodity", function()
        it("buys up to the clicked level, cheapest units first, and shows the units and the total", function()
            choose(11, { crow(150, 2), crow(160, 3), crow(170, 4) })
            local entries = tab:LevelMenuEntries(levelId(3))
            assert.are.equal("Buy up to this level (9 units, " .. GetMoneyString(1460) .. " total)", entries[1].text)
            assert.are.equal("Buy amount...", entries[2].text)
            assert.is_false(entries[1].disabled == true)
            entries = tab:LevelMenuEntries(levelId(1))
            assert.are.equal("Buy up to this level (2 units, " .. GetMoneyString(300) .. " total)", entries[1].text)
        end)

        it("asks for the quote in the click of the entry, then buys only after the confirm click", function()
            choose(11, { crow(150, 2), crow(160, 3), crow(170, 4) })
            assert.are.same({}, client.calls)
            menuClick(3)
            assert.are.same({ { "start", 11, 9 } }, client.calls)
            assert.is_nil(box())
            bus:Emit("QUOTE", 150, 1460)
            assert.is_true(box():IsShown())
            assert.is_truthy(box().text.text:find("Buy 9 x", 1, true))
            assert.are.same({ "start" }, names())
            click(box().yesButton)
            assert.are.same({ { "start", 11, 9 }, { "confirm", 11, 9 } }, client.calls)
            assert.are.same({}, client.violations)
        end)

        it("opens the menu on a right click and makes no call", function()
            local built = {}
            _G.MenuUtil = { CreateContextMenu = function(owner, generator)
                local root = { CreateTitle = function(_, text) built[#built + 1] = "title " .. text end,
                    CreateButton = function(_, text)
                        built[#built + 1] = text
                        return { SetEnabled = function(_, on) built[#built + 1] = on and "on" or "off" end }
                    end }
                generator(owner, root)
                return root
            end }
            choose(11, { crow(150, 2), crow(160, 3) })
            local row = ui.levelList.rows[2]
            row.scripts.OnClick(row, "RightButton")
            _G.MenuUtil = nil
            assert.are.same({ "Buy up to this level (5 units, " .. GetMoneyString(780) .. " total)",
                "Buy amount..." }, built)
            assert.are.same({}, client.calls)
            assert.is_nil(tab.levelSel)
        end)

        it("gives no menu for a level of yours: the message line gives the reason", function()
            choose(11, { crow(150, 2, true), crow(160, 3) })
            local entries, reason = tab:LevelMenuEntries(levelId(1))
            assert.is_nil(entries)
            assert.are.equal(ns.BuyingPlan.REASON.own, reason)
            local row = ui.levelList.rows[1]
            row.scripts.OnClick(row, "RightButton")
            assert.are.equal(ns.BuyingPlan.REASON.own, ui.details.warn.text)
            assert.are.same({}, client.calls)
        end)

        it("turns the entries off when a level of yours is below the clicked level", function()
            choose(11, { crow(150, 2), crow(160, 3, true), crow(170, 4) })
            local entries, reason = tab:LevelMenuEntries(levelId(3))
            assert.is_true(entries[1].disabled)
            assert.is_true(entries[2].disabled)
            assert.are.equal(ns.BuyingPlan.REASON.ownBelow, reason)
            entries[1].onClick()
            assert.are.same({}, client.calls)
            assert.are.equal(ns.BuyingPlan.REASON.ownBelow, ui.details.warn.text)
            -- The level below your level is allowed.
            assert.is_false(tab:LevelMenuEntries(levelId(1))[1].disabled == true)
        end)

        it("buys up to the top of the range for a level in the range", function()
            choose(11, { crow(150, 2), crow(160, 3), crow(170, 4), crow(180, 5) })
            clickLevel(2)
            shiftClickLevel(3)
            -- Level 2 and 3 are in the range. N counts from the cheapest level to the top of the range.
            local entries = tab:LevelMenuEntries(levelId(2))
            assert.are.equal("Buy selected range (9 units, " .. GetMoneyString(1460) .. " total)", entries[1].text)
            entries = tab:LevelMenuEntries(levelId(3))
            assert.are.equal("Buy selected range (9 units, " .. GetMoneyString(1460) .. " total)", entries[1].text)
            -- A level out of the range is a normal buy.
            entries = tab:LevelMenuEntries(levelId(4))
            assert.are.equal("Buy up to this level (14 units, " .. GetMoneyString(2360) .. " total)", entries[1].text)
            menuClick(2)
            assert.are.same({ { "start", 11, 9 } }, client.calls)
        end)

        it("opens a window for an amount: whole units from 1 up to the units for sale", function()
            choose(11, { crow(150, 2), crow(160, 3), crow(170, 4) })
            tab:LevelMenuEntries(levelId(2))[2].onClick()
            assert.are.same({}, client.calls)
            local config = ns.Kit.Prompt("FlipsideSellingBuyAmount").config
            assert.are.equal("Buy amount", config.title)
            assert.are.equal("5", config.text)
            assert.is_truthy(config.validate("0"))
            assert.is_truthy(config.validate("10"))
            assert.is_truthy(config.validate("2.5"))
            assert.is_nil(config.validate("9"))
            client.inClick = true
            assert.is_nil(config.onOK("4"))
            client.inClick = false
            assert.are.same({ { "start", 11, 4 } }, client.calls)
            assert.are.same({}, client.violations)
        end)

        it("caps the amount below your first level", function()
            choose(11, { crow(150, 2), crow(160, 3, true), crow(170, 4) })
            tab:LevelMenuEntries(levelId(1))[2].onClick()
            local config = ns.Kit.Prompt("FlipsideSellingBuyAmount").config
            assert.is_nil(config.validate("2"))
            assert.is_truthy(config.validate("3"))
            assert.is_truthy(config.onOK("3"))
            assert.are.same({}, client.calls)
        end)

        it("shows a quote more than 10 percent above the list as a price jump, and still needs the confirm", function()
            choose(11, { crow(150, 2), crow(160, 3), crow(170, 4) })
            menuClick(2)
            -- The list says 780 for 5 units. A quote of 1000 is 28% above.
            bus:Emit("QUOTE", 200, 1000)
            assert.is_truthy(box().text.text:find("Price jumps from", 1, true))
            assert.are.same({ "start" }, names())
            click(box().yesButton)
            assert.are.same({ "start", "confirm" }, names())
        end)

        it("logs the unit price of the quote and searches again after the buy", function()
            choose(11, { crow(150, 2), crow(160, 3), crow(170, 4) })
            clickLevel(2)
            menuClick(2)
            bus:Emit("QUOTE", 156, 780)
            click(box().yesButton)
            local before = #client.searches
            bus:Emit("BOUGHT")
            assert.are.equal(before + 1, #client.searches)
            assert.is_nil(tab.levelSel)
            assert.is_nil(tab.levelRange)
            assert.are.same({}, ui.levelList.data)
            client.rows[11] = { crow(170, 4) }
            bus:Emit("COMMODITY_RESULTS", 11)
            assert.are.equal(1, #ui.levelList.data)
            local list = ns.BuyingPlan.Log:List()
            assert.are.equal("bought 5 at " .. GetMoneyString(156), list[#list].decision)
        end)
    end)

    describe("the guards of the menu", function()
        local function assertOff(setup)
            choose(11, { crow(150, 5), crow(160, 4) })
            setup()
            local entries = tab:LevelMenuEntries(levelId(1))
            assert.is_true(entries[1].disabled)
            assert.is_true(entries[2].disabled)
            entries[1].onClick()
            assert.are.same({}, client.calls)
        end

        it("turn the entries off while a buy is open", function()
            choose(11, { crow(150, 5), crow(160, 4) })
            menuClick(1)
            assert.is_true(tab:LevelMenuEntries(levelId(2))[1].disabled)
            tab:BuyLevel(levelId(2))
            assert.are.same({ "start" }, names())
        end)

        it("turn the entries off while the other tab has a buy open", function()
            assertOff(function()
                ns.BuyFlow.Register("buying", function() return true end)
            end)
        end)

        it("turn the entries off while a post is open", function()
            assertOff(function()
                tab.lock = true
            end)
        end)

        it("turn the entries off while a search runs", function()
            assertOff(function()
                tab.pending = {}
            end)
        end)

        it("turn the entries off while the AH is not ready", function()
            assertOff(function()
                client.ready = false
            end)
        end)

        it("turn the entries off when the client cannot buy", function()
            assertOff(function()
                client.canBuy = false
            end)
        end)
    end)

    describe("the menu of an item auction or a stack", function()
        it("has one entry with the buyout, for a stack and for a Forever row of items", function()
            choose(10, { arow(150, 2) })
            local entries = tab:LevelMenuEntries(levelId(1))
            assert.are.equal(1, #entries)
            assert.are.equal("Buy this auction (" .. GetMoneyString(300) .. ")", entries[1].text)
            choose(10, { { unitPrice = 449, quantity = 40, ownerItem = false, auctionID = 7, isCommodity = false,
                buyout = 449, owner = "Bob", perItem = true } })
            entries = tab:LevelMenuEntries(levelId(1))
            assert.are.equal("Buy this auction (" .. GetMoneyString(449) .. ")", entries[1].text)
        end)

        it("opens the confirm in the click of the entry and buys at the buyout after the confirm click", function()
            choose(10, { arow(150, 1), arow(160, 2), arow(170, 1) })
            menuClick(2)
            assert.are.same({}, client.calls)
            assert.is_true(box():IsShown())
            assert.is_truthy(box().text.text:find("Buy one stack: 2 x", 1, true))
            click(box().yesButton)
            assert.are.same({ { "bid", 160, 320 } }, client.calls)
            assert.are.same({}, client.violations)
        end)

        it("is on above an own auction, because an item buy takes one auction", function()
            choose(10, { arow(140, 1, true), arow(150, 1) })
            assert.is_nil(tab:LevelMenuEntries(levelId(1)))
            assert.is_false(tab:LevelMenuEntries(levelId(2))[1].disabled == true)
        end)

        it("finds the auction again at the confirm and does not buy a gone auction", function()
            choose(10, { arow(150, 1), arow(160, 2) })
            menuClick(2)
            client.rows[10] = { arow(150, 1) }
            click(box().yesButton)
            assert.are.same({}, client.calls)
            assert.is_nil(tab.buy)
        end)

        it("keeps the guards: one buy at a time, Post and Skip off", function()
            choose(10, { arow(150, 1), arow(160, 2) })
            menuClick(2)
            assert.is_false(ui.postNext.enabled)
            assert.is_false(ui.skip.enabled)
            assert.is_true(tab:LevelMenuEntries(levelId(1))[1].disabled)
            assert.is_false((tab:SelectLevel(levelId(1))))
        end)
    end)

    describe("a range of item auctions", function()
        local function yes()
            return box().yesButton
        end

        before_each(function()
            choose(10, { arow(150, 1), arow(160, 1), arow(170, 1) })
            clickLevel(1)
            shiftClickLevel(3)
        end)

        it("shows the count and the total", function()
            local entries = tab:LevelMenuEntries(levelId(2))
            assert.are.equal("Buy 3 auctions in range (" .. GetMoneyString(480) .. " total)", entries[1].text)
            assert.are.equal(1, #entries)
        end)

        it("asks once for each auction: each confirm click buys one, and the next confirm opens", function()
            menuClick(2)
            assert.are.same({}, client.calls)
            assert.are.equal("Buy next", yes().text)
            click(yes())
            assert.are.same({ { "bid", 150, 150 } }, client.calls)
            bus:Emit("ITEMBOUGHT", 150)
            -- The next auction asks for its own click. No call goes out by itself.
            assert.are.same({ { "bid", 150, 150 } }, client.calls)
            assert.is_true(box():IsShown())
            assert.are.equal("Buy next", yes().text)
            click(yes())
            bus:Emit("ITEMBOUGHT", 160)
            assert.are.equal("Buy", yes().text)
            click(yes())
            assert.are.same({ { "bid", 150, 150 }, { "bid", 160, 160 }, { "bid", 170, 170 } }, client.calls)
            local before = #client.searches
            bus:Emit("ITEMBOUGHT", 170)
            assert.is_nil(tab.buy)
            assert.is_nil(tab.buyQueue)
            assert.is_nil(tab.levelRange)
            assert.is_false(box():IsShown())
            assert.are.equal(before + 1, #client.searches)
            assert.are.same({}, client.violations)
        end)

        it("stops at Cancel: no more auctions are bought", function()
            menuClick(2)
            click(yes())
            bus:Emit("ITEMBOUGHT", 150)
            click(box().noButton)
            assert.is_nil(tab.buy)
            assert.is_nil(tab.buyQueue)
            assert.are.same({ { "bid", 150, 150 } }, client.calls)
        end)

        it("stops when an auction is gone from the list at the confirm", function()
            menuClick(2)
            click(yes())
            bus:Emit("ITEMBOUGHT", 150)
            client.rows[10] = { arow(170, 1) }
            click(yes())
            assert.are.same({ { "bid", 150, 150 } }, client.calls)
            assert.is_nil(tab.buy)
            assert.is_nil(tab.buyQueue)
        end)

        it("counts each item of a Forever row as one auction", function()
            choose(10, {
                { unitPrice = 449, quantity = 3, ownerItem = false, auctionID = 7, isCommodity = false,
                    buyout = 449, owner = "Bob", perItem = true },
                { unitPrice = 459, quantity = 2, ownerItem = false, auctionID = 8, isCommodity = false,
                    buyout = 459, owner = "Bob", perItem = true },
            })
            clickLevel(1)
            shiftClickLevel(2)
            local entries = tab:LevelMenuEntries(levelId(1))
            assert.are.equal("Buy 5 auctions in range (" .. GetMoneyString(2265) .. " total)", entries[1].text)
        end)
    end)

    describe("the price of a selected level", function()
        it("is set by the click that selects, and the details follow", function()
            choose(11, { crow(150, 2), crow(160, 3), crow(170, 4) })
            local before = ui.details.total.text
            clickLevel(2)
            assert.are.equal(160, ui.details.priceInput:GetCopper())
            assert.are_not.equal(before, ui.details.total.text)
            assert.are.same({}, client.calls)
        end)

        it("is kept by the click that clears the selection", function()
            choose(11, { crow(150, 2), crow(160, 3), crow(170, 4) })
            clickLevel(2)
            ui.details.priceInput:SetCopper(99)
            clickLevel(2)
            assert.is_nil(tab.levelSel)
            assert.are.equal(99, ui.details.priceInput:GetCopper())
        end)

        it("is kept by a click on a level of yours", function()
            choose(11, { crow(150, 2, true), crow(160, 3) })
            local before = ui.details.priceInput:GetCopper()
            clickLevel(1)
            assert.is_nil(tab.levelSel)
            assert.are.equal(before, ui.details.priceInput:GetCopper())
        end)

        it("is the price of one item for a stack level", function()
            choose(10, { arow(150, 1), arow(160, 2) })
            clickLevel(2)
            assert.are.equal(160, ui.details.priceInput:GetCopper())
        end)
    end)

    describe("a list for another item", function()
        it("reads the prices again on the menu click and buys nothing", function()
            choose(11, { crow(150, 5) })
            local entries = tab:LevelMenuEntries(levelId(1))
            tab.live = nil
            local before = #client.searches
            client.inClick = true
            entries[1].onClick()
            client.inClick = false
            assert.are.same({}, client.calls)
            assert.are.equal(before + 1, #client.searches)
        end)
    end)
end)

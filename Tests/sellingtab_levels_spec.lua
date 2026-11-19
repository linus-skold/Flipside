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

describe("SellingTab level pane and Buy", function()
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
            assert.is_not_nil(ui.buyRow)
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

        it("has the Buy button under the pane and none in the details pane", function()
            assert.are.equal("Buy", ui.buy.text)
            assert.is_nil(ui.buyLowest)
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
            assert.are.equal("40 x 1", ui.levelList.data[1].available)
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
        it("keeps the button text Buy, and a second click clears it", function()
            choose(11, { crow(150, 5), crow(160, 4) })
            clickLevel(2)
            assert.are.equal(160, tab.levelSel)
            assert.are.equal("Buy", ui.buy.text)
            assert.is_true(ui.buy.enabled)
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

    describe("Buy with no selection", function()
        it("is off with no item", function()
            assert.is_false(ui.buy.enabled)
            click(ui.buy)
            assert.are.same({}, client.calls)
        end)

        it("buys the cheapest level that is not yours: its quantity, then a quote, then the confirm", function()
            choose(11, { crow(150, 5), crow(160, 4) })
            assert.are.equal(5, ui.amount.GetNumber())
            click(ui.buy)
            assert.are.same({ { "start", 11, 5 } }, client.calls)
            assert.is_nil(box())
            bus:Emit("QUOTE", 150, 750)
            assert.is_true(box():IsShown())
            assert.is_truthy(box().text.text:find("Buy 5 x", 1, true))
            assert.are.same({ "start" }, names())
            click(box().yesButton)
            assert.are.same({ { "start", 11, 5 }, { "confirm", 11, 5 } }, client.calls)
            assert.are.same({}, client.violations)
        end)

        it("is off when every level is yours", function()
            choose(11, { crow(150, 5, true), crow(160, 4, true) })
            assert.is_false(ui.buy.enabled)
            click(ui.buy)
            assert.are.same({}, client.calls)
        end)

        it("is off for a commodity when a level of yours is below the first level that is not yours", function()
            choose(11, { crow(140, 2, true), crow(150, 5) })
            assert.is_false(ui.buy.enabled)
        end)

        it("is on for an item auction above an own auction, because an item buy takes one auction", function()
            choose(10, { arow(140, 1, true), arow(150, 1) })
            assert.is_true(ui.buy.enabled)
        end)

        it("is off while another tab has a buy open", function()
            choose(11, { crow(150, 5) })
            ns.BuyFlow.Register("buying", function() return true end)
            tab:_Update()
            assert.is_false(ui.buy.enabled)
        end)
    end)

    describe("the amount of a commodity", function()
        it("is prefilled with the units up to the selected level", function()
            choose(11, { crow(150, 2), crow(160, 3), crow(170, 4) })
            assert.are.equal(2, ui.amount.GetNumber())
            clickLevel(3)
            assert.are.equal(9, ui.amount.GetNumber())
            assert.is_true(ui.amount.enabled)
            click(ui.buy)
            assert.are.same({ { "start", 11, 9 } }, client.calls)
        end)

        it("can be lowered: the buy takes the typed amount, cheapest units first", function()
            choose(11, { crow(150, 2), crow(160, 3), crow(170, 4) })
            clickLevel(3)
            assert.is_true(tab:SetAmount(4))
            assert.are.equal(4, ui.amount.GetNumber())
            click(ui.buy)
            assert.are.same({ { "start", 11, 4 } }, client.calls)
        end)

        it("can be raised up to the units for sale", function()
            choose(11, { crow(150, 2), crow(160, 3) })
            assert.is_true(tab:SetAmount(5))
            click(ui.buy)
            assert.are.same({ { "start", 11, 5 } }, client.calls)
        end)

        it("is capped by the units for sale: a larger amount turns the button off", function()
            choose(11, { crow(150, 2), crow(160, 3) })
            tab:SetAmount(6)
            assert.is_false(ui.buy.enabled)
            local ok, reason = tab:Buy()
            assert.is_false(ok)
            assert.are.equal("only 5 units are for sale", reason)
            assert.are.same({}, client.calls)
        end)

        it("is capped by the first level of yours: an amount that reaches it is refused", function()
            choose(11, { crow(150, 2), crow(160, 3, true), crow(170, 4) })
            clickLevel(3)
            -- The default is 9 units and takes the units of your level: refused.
            assert.are.equal(9, ui.amount.GetNumber())
            assert.is_false(ui.buy.enabled)
            tab:SetAmount(3)
            assert.is_false(ui.buy.enabled)
            local _, reason = tab:Buy()
            assert.are.equal(ns.BuyingPlan.REASON.ownBelow, reason)
            -- Up to the units below your level, the buy is allowed.
            tab:SetAmount(2)
            assert.is_true(ui.buy.enabled)
            click(ui.buy)
            assert.are.same({ { "start", 11, 2 } }, client.calls)
        end)

        it("refuses an empty or bad amount", function()
            choose(11, { crow(150, 5) })
            assert.is_false(tab:SetAmount(nil))
            assert.is_false(ui.buy.enabled)
            local ok, reason = tab:Buy()
            assert.is_false(ok)
            assert.are.equal("the amount must be a whole number above 0", reason)
            assert.is_false(tab:SetAmount(2.5))
            assert.is_false(tab:SetAmount(0))
            assert.are.same({}, client.calls)
        end)

        it("takes an amount only from a typed text: the hook with userInput false and true", function()
            choose(11, { crow(150, 2), crow(160, 3) })
            assert.are.equal(2, ui.amount.GetNumber())
            -- A text that the tab puts in the box (userInput false) is not an amount.
            ui.amount:SetText("5")
            ui.amount.scripts.OnTextChanged(ui.amount, false)
            assert.is_nil(tab.amount)
            -- A typed text (userInput true) is.
            ui.amount.scripts.OnTextChanged(ui.amount, true)
            assert.are.equal(5, tab.amount)
            click(ui.buy)
            assert.are.same({ { "start", 11, 5 } }, client.calls)
        end)

        it("shows no error text for an empty box while the user types, and shows it for a bad number", function()
            choose(11, { crow(150, 2), crow(160, 3) })
            ui.amount:SetText("")
            ui.amount.scripts.OnTextChanged(ui.amount, true)
            assert.is_true(tab.amountBad)
            assert.is_false(ui.buy.enabled)
            assert.is_nil(ui.details.warn.text:find("whole number", 1, true))
            ui.amount:SetText("0")
            ui.amount.scripts.OnTextChanged(ui.amount, true)
            assert.is_truthy(ui.details.warn.text:find("whole number", 1, true))
        end)

        it("puts the hint of a bad number above the box", function()
            local point = ui.amount.hint.points[#ui.amount.hint.points]
            assert.are.equal("BOTTOM", point[1])
        end)
        it("goes back to the default when another level is selected", function()
            choose(11, { crow(150, 2), crow(160, 3), crow(170, 4) })
            clickLevel(3)
            tab:SetAmount(4)
            clickLevel(2)
            assert.are.equal(5, ui.amount.GetNumber())
        end)

        it("shows a quote more than 10 percent above the list as a price jump, and still needs the confirm", function()
            choose(11, { crow(150, 2), crow(160, 3), crow(170, 4) })
            clickLevel(2)
            click(ui.buy)
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
            click(ui.buy)
            bus:Emit("QUOTE", 156, 780)
            click(box().yesButton)
            local before = #client.searches
            bus:Emit("BOUGHT")
            assert.are.equal(before + 1, #client.searches)
            assert.is_nil(tab.levelSel)
            assert.is_nil(tab.amount)
            assert.are.same({}, ui.levelList.data)
            client.rows[11] = { crow(170, 4) }
            bus:Emit("COMMODITY_RESULTS", 11)
            assert.are.equal(1, #ui.levelList.data)
            local list = ns.BuyingPlan.Log:List()
            assert.are.equal("bought 5 at " .. GetMoneyString(156), list[#list].decision)
        end)
    end)

    describe("an item auction or a stack", function()
        it("has a fixed amount of 1 in a disabled box, with the stack size", function()
            choose(10, { arow(150, 2) })
            assert.are.equal(1, ui.amount.GetNumber())
            assert.is_false(ui.amount.enabled)
            assert.are.equal("1 stack of 2", ui.buyInfo.text)
        end)

        it("shows 1 item for a Forever row of items", function()
            choose(10, { { unitPrice = 449, quantity = 40, ownerItem = false, auctionID = 7, isCommodity = false,
                buyout = 449, owner = "Bob", perItem = true } })
            assert.are.equal(1, ui.amount.GetNumber())
            assert.is_false(ui.amount.enabled)
            assert.are.equal("1 item", ui.buyInfo.text)
        end)

        it("goes to the confirm and buys the selected auction at its buyout, after the confirm click", function()
            choose(10, { arow(150, 1), arow(160, 2), arow(170, 1) })
            clickLevel(2)
            click(ui.buy)
            assert.are.same({}, client.calls)
            assert.is_true(box():IsShown())
            assert.is_truthy(box().text.text:find("Buy one stack: 2 x", 1, true))
            click(box().yesButton)
            assert.are.same({ { "bid", 160, 320 } }, client.calls)
            assert.are.same({}, client.violations)
        end)

        it("ignores a typed amount", function()
            choose(10, { arow(150, 1) })
            tab:SetAmount(5)
            click(ui.buy)
            assert.is_true(box():IsShown())
            click(box().yesButton)
            assert.are.same({ { "bid", 150, 150 } }, client.calls)
        end)

        it("finds the auction again at the confirm and does not buy a gone auction", function()
            choose(10, { arow(150, 1), arow(160, 2) })
            clickLevel(2)
            click(ui.buy)
            client.rows[10] = { arow(150, 1) }
            click(box().yesButton)
            assert.are.same({}, client.calls)
            assert.is_nil(tab.buy)
        end)

        it("keeps the guards: one buy at a time, Post and Skip off", function()
            choose(10, { arow(150, 1), arow(160, 2) })
            clickLevel(2)
            click(ui.buy)
            assert.is_false(ui.postNext.enabled)
            assert.is_false(ui.skip.enabled)
            assert.is_false(ui.buy.enabled)
            assert.is_false((tab:SelectLevel(ns.BuyFlow.LevelId(ui.levelList.data[1]))))
        end)
    end)

    describe("a list for another item", function()
        it("reads the prices again on the click and buys nothing", function()
            choose(11, { crow(150, 5) })
            tab.live = nil
            assert.is_true(ui.buy.enabled)
            local before = #client.searches
            click(ui.buy)
            assert.are.same({}, client.calls)
            assert.are.equal(before + 1, #client.searches)
        end)
    end)
end)
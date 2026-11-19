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

describe("SellingTab Buy", function()
    local ns, bus, client, tab, ui, bagItems, itemGroup, groups

    -- A fake client. A protected call outside a click is a violation.
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

    -- A commodity row and an item auction row (a buyout of price times quantity).
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

    local function box()
        for _, frame in ipairs(mock.frames) do
            if frame.name == "FlipsideBuyConfirm" then
                return frame
            end
        end
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

    -- Choose an item and answer its search with rows. Item 10 is an item, 11 is a commodity.
    local function choose(itemID, rows)
        client.rows[itemID] = rows
        ui.tree:Select("i" .. itemID)
        bus:Emit(itemID == 10 and "ITEM_RESULTS" or "COMMODITY_RESULTS", itemID)
    end

    local function names()
        local out = {}
        for _, call in ipairs(client.calls) do
            out[#out + 1] = call[1]
        end
        return out
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

    describe("the button", function()
        it("is off with no selection", function()
            assert.is_false(ui.buy.enabled)
            click(ui.buy)
            assert.are.same({}, client.calls)
        end)

        it("is on for a selected item with a level that is not yours", function()
            choose(11, { crow(150, 5), crow(160, 4) })
            assert.is_true(ui.buy.enabled)
            assert.are.equal("Buy", ui.buy.text)
        end)

        it("is off when every level is yours", function()
            choose(11, { crow(150, 5, true), crow(160, 4, true) })
            assert.is_false(ui.buy.enabled)
            click(ui.buy)
            assert.are.same({}, client.calls)
        end)

        it("is off for a commodity when an own level is below the first level that is not yours", function()
            choose(11, { crow(140, 2, true), crow(150, 5) })
            assert.is_false(ui.buy.enabled)
        end)

        it("is on for an item auction above an own auction, because an item buy takes one auction", function()
            choose(10, { arow(140, 1, true), arow(150, 1) })
            assert.is_true(ui.buy.enabled)
        end)

        it("is off when the client cannot buy", function()
            client.canBuy = false
            choose(11, { crow(150, 5) })
            assert.is_false(ui.buy.enabled)
        end)

        it("is off while another tab has a buy open", function()
            choose(11, { crow(150, 5) })
            ns.BuyFlow.Register("buying", function() return true end)
            tab:_Update()
            assert.is_false(ui.buy.enabled)
            click(ui.buy)
            assert.are.same({}, client.calls)
        end)
    end)

    describe("DealText", function()
        it("shows the percent under the market value from 30 percent", function()
            assert.are.equal("-70%", ns.SellingTab.DealText(300, 1000))
            assert.are.equal("-30%", ns.SellingTab.DealText(700, 1000))
            assert.is_nil(ns.SellingTab.DealText(800, 1000))
            assert.is_nil(ns.SellingTab.DealText(300, nil))
            assert.is_nil(ns.SellingTab.DealText(300, 0))
        end)
    end)

    describe("a commodity", function()
        it("asks for a quote with the quantity of the lowest level, and buys only after the confirm", function()
            choose(11, { crow(150, 5), crow(160, 4) })
            click(ui.buy)
            assert.are.same({ { "start", 11, 5 } }, client.calls)
            assert.is_nil(box())
            bus:Emit("QUOTE", 150, 750)
            assert.is_true(box():IsShown())
            assert.is_truthy(box().text.text:find("Buy 5 x", 1, true))
            assert.are.equal("Confirm", box().yesButton.text)
            assert.are.same({ "start" }, names())
            click(box().yesButton)
            assert.are.same({ "start", "confirm" }, names())
            assert.are.same({ "confirm", 11, 5 }, client.calls[2])
            assert.are.same({}, client.violations)
        end)

        it("searches the item again after the buy and writes the Buying tab log lines", function()
            choose(11, { crow(150, 5), crow(160, 4) })
            click(ui.buy)
            bus:Emit("QUOTE", 150, 750)
            click(box().yesButton)
            local before = #client.searches
            client.rows[11] = { crow(160, 4) }
            bus:Emit("BOUGHT")
            assert.is_nil(tab.buy)
            assert.are.equal(before + 1, #client.searches)
            assert.are.equal(11, client.searches[#client.searches])
            assert.is_false(box():IsShown())
            local list = ns.BuyingPlan.Log:List()
            assert.is_truthy(list[#list].decision:find("^bought 5 at "))
            assert.is_truthy(list[#list].reason:find("total", 1, true))
        end)

        it("makes no second quote while the first buy is open", function()
            choose(11, { crow(150, 5) })
            click(ui.buy)
            assert.is_false(ui.buy.enabled)
            click(ui.buy)
            assert.are.same({ "start" }, names())
        end)

        it("cancels the quote when the user cancels the box", function()
            choose(11, { crow(150, 5) })
            click(ui.buy)
            bus:Emit("QUOTE", 150, 750)
            click(box().noButton)
            assert.is_nil(tab.buy)
            assert.are.same({ "start", "cancel" }, names())
        end)

        it("cancels an open quote when the tab is left", function()
            choose(11, { crow(150, 5) })
            click(ui.buy)
            tab:Deselect()
            assert.is_nil(tab.buy)
            assert.are.same({ "start", "cancel" }, names())
        end)

        it("fails and searches again when the server refuses", function()
            choose(11, { crow(150, 5) })
            click(ui.buy)
            bus:Emit("QUOTE", 150, 750)
            click(box().yesButton)
            local before = #client.searches
            bus:Emit("NOTBOUGHT")
            assert.is_nil(tab.buy)
            assert.are.equal(before + 1, #client.searches)
            local list = ns.BuyingPlan.Log:List()
            assert.are.equal("buy failed", list[#list].decision)
        end)

        it("ignores buy events when it has no buy open", function()
            choose(11, { crow(150, 5) })
            local before = #client.searches
            bus:Emit("QUOTE", 150, 750)
            bus:Emit("BOUGHT")
            bus:Emit("ITEMBOUGHT", 150)
            assert.are.equal(before, #client.searches)
            assert.is_nil(box())
        end)
    end)

    describe("an item auction", function()
        it("goes to the confirm box and buys the auction at its buyout after the click", function()
            choose(10, { arow(140, 1, true), arow(150, 2), arow(160, 1) })
            click(ui.buy)
            assert.are.same({}, client.calls)
            assert.is_true(box():IsShown())
            assert.is_truthy(box().text.text:find("Buy one stack: 2 x", 1, true))
            assert.are.equal("Buy", box().yesButton.text)
            click(box().yesButton)
            assert.are.same({ { "bid", 150, 300 } }, client.calls)
            assert.are.same({}, client.violations)
        end)

        it("buys one item of a Forever row of 40 at 449 each: Buy 1 x, 449, one PlaceBid", function()
            -- ForeverBackend.LiveRows: unitPrice is the price of one item (buyoutAmount), buyout is the raw amount,
            -- perItem marks 40 separate one-item auctions.
            choose(10, { { unitPrice = 449, quantity = 40, ownerItem = false, auctionID = 7, isCommodity = false,
                buyout = 449, owner = "Bob", perItem = true } })
            click(ui.buy)
            local text = box().text.text
            assert.is_truthy(text:find("Buy 1 x", 1, true))
            assert.is_truthy(text:find("Unit price: " .. GetMoneyString(449), 1, true))
            assert.is_truthy(text:find("Total: " .. GetMoneyString(449), 1, true))
            click(box().yesButton)
            assert.are.same({ { "bid", 7, 449 } }, client.calls)
            assert.are.equal(1, tab.buy.quantity)
        end)

        it("searches again after the purchase completes", function()
            choose(10, { arow(150, 2), arow(160, 1) })
            click(ui.buy)
            click(box().yesButton)
            local before = #client.searches
            client.rows[10] = { arow(160, 1) }
            bus:Emit("ITEMBOUGHT", 150)
            assert.are.equal(before + 1, #client.searches)
            assert.is_nil(tab.buy)
        end)

        it("does not buy when the auction is gone from the list at the confirm", function()
            choose(10, { arow(150, 2) })
            click(ui.buy)
            client.rows[10] = {}
            click(box().yesButton)
            assert.are.same({}, client.calls)
            assert.is_nil(tab.buy)
        end)

        it("takes an error event as a failed buy", function()
            choose(10, { arow(150, 2) })
            click(ui.buy)
            click(box().yesButton)
            bus:Emit("ITEMERR", 7)
            assert.is_nil(tab.buy)
            local list = ns.BuyingPlan.Log:List()
            assert.are.equal("buy failed", list[#list].decision)
        end)
    end)

    describe("while a buy is open", function()
        it("turns Post and Skip off", function()
            choose(11, { crow(150, 5) })
            assert.is_true(ui.postNext.enabled)
            assert.is_true(ui.skip.enabled)
            click(ui.buy)
            assert.is_false(ui.postNext.enabled)
            assert.is_false(ui.skip.enabled)
            bus:Emit("QUOTE", 150, 750)
            click(box().noButton)
            assert.is_true(ui.postNext.enabled)
            assert.is_true(ui.skip.enabled)
        end)

        it("leaves the box open when it ends and the Buying tab has a buy open", function()
            choose(11, { crow(150, 5) })
            click(ui.buy)
            bus:Emit("QUOTE", 150, 750)
            local shown = box()
            ns.BuyFlow.Register("buying", function() return true end)
            tab:_AbortBuy(tab.buy, "test")
            assert.is_true(shown:IsShown())
        end)
    end)

    describe("the AH closes", function()
        local timers

        before_each(function()
            timers = {}
            client.CloseEvent = function() return "CLOSE" end
            tab:Unmount()
            tab = mount({ after = function(_, fn) timers[#timers + 1] = fn end })
            ui = tab.ui
        end)

        it("ends an open quote with no search and no buy call", function()
            choose(11, { crow(150, 5) })
            click(ui.buy)
            bus:Emit("QUOTE", 150, 750)
            local before = #client.searches
            bus:Emit("CLOSE")
            assert.is_nil(tab.buy)
            assert.is_false(box():IsShown())
            assert.are.same({ "start", "cancel" }, names())
            assert.are.equal(before, #client.searches)
        end)

        it("ends a buy that went out, and the wait timer does nothing", function()
            choose(10, { arow(150, 2) })
            click(ui.buy)
            click(box().yesButton)
            local before = #client.searches
            bus:Emit("CLOSE")
            assert.is_nil(tab.buy)
            for _, fn in ipairs(timers) do
                fn()
            end
            assert.are.equal(before, #client.searches)
            local list = ns.BuyingPlan.Log:List()
            assert.are.equal("buy cancelled", list[#list].decision)
        end)

        it("forgets the rows of the last search", function()
            choose(11, { crow(150, 5) })
            assert.is_not_nil(tab.live)
            bus:Emit("CLOSE")
            assert.is_nil(tab.live)
        end)
    end)

    describe("a post", function()
        it("forgets the rows of the last search", function()
            choose(11, { crow(150, 5) })
            assert.is_not_nil(tab.live)
            bus:Emit("CREATED")
            assert.is_nil(tab.live)
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

    it("registers the buy events and removes them on unmount", function()
        assert.is_true(bus:HasSubscribers("QUOTE"))
        tab:Unmount()
        assert.is_false(bus:HasSubscribers("QUOTE"))
        assert.is_false(bus:HasSubscribers("ITEMBOUGHT"))
    end)
end)

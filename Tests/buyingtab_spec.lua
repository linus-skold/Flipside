local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end, Flavour = { hasCommodityMarket = true } }
    for _, name in ipairs({ "EventBus", "ItemString", "BuyingPlan", "Theme", "Widgets", "Window", "List", "Tree",
        "Columns", "AuctionTabs", "BuyingTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

describe("BuyingTab", function()
    local ns, bus, client, rules, run, timers, tab, ui, parentFrame

    -- A fake client: it records searches and gives rows by item id.
    local function makeClient()
        local c = { ready = true, searches = {}, rows = {}, refuse = nil, canLive = true }
        c.CanLiveSearch = function()
            return c.canLive
        end
        c.IsReady = function()
            return c.ready
        end
        c.LiveSearch = function(itemID)
            if c.refuse then
                return false, c.refuse
            end
            c.searches[#c.searches + 1] = itemID
            return true
        end
        c.LiveRows = function(itemID)
            return c.rows[itemID] or {}
        end
        c.LiveResultEvents = function()
            return "COMMODITY_RESULTS", "ITEM_RESULTS"
        end
        c.ReadyEvent = function()
            return "READY"
        end
        c.CloseEvent = function()
            return "CLOSE"
        end
        c.BuyEvents = function()
            return {
                priceUpdated = "QUOTE", priceUnavailable = "NOQUOTE", commoditySucceeded = "BOUGHT",
                commodityFailed = "NOTBOUGHT", itemCompleted = "ITEMBOUGHT", itemError = "ITEMERR",
            }
        end
        -- The protected calls record a call outside a click as a violation.
        c.canBuy, c.calls, c.violations, c.quoteLeft = true, {}, {}, 30
        local function protected(name)
            return function(...)
                c.calls[#c.calls + 1] = { name, ... }
                if not c.inClick then
                    c.violations[#c.violations + 1] = name
                end
            end
        end
        c.CanBuy = function()
            return c.canBuy
        end
        c.StartCommodityPurchase = protected("start")
        c.ConfirmCommodityPurchase = protected("confirm")
        c.BuyItemAuction = protected("bid")
        c.CancelCommodityPurchase = function()
            c.calls[#c.calls + 1] = { "cancel" }
        end
        c.QuoteSecondsLeft = function()
            return c.quoteLeft
        end
        return c
    end

    -- Rules with one group of three items that has a buying operation.
    local function makeRules(items)
        return {
            Walk = function(_, fn)
                fn(1)
                fn(2)
            end,
            EffectiveOperation = function()
                return 7
            end,
            GetOperation = function()
                return { name = "Cheap", settings = { maxPrice = "100", showAboveMax = false } }
            end,
            Path = function()
                return "Herbs/Flowers"
            end,
            ItemsIn = function()
                return items
            end,
            Children = function(_, id)
                return id == 1 and { 2 } or {}
            end,
            Name = function()
                return "Herbs"
            end,
        }
    end

    local function fire(event, ...)
        bus:Emit(event, ...)
    end

    local function mount()
        local core = ns.BuyingTab.New({
            bus = bus, rules = rules, formulaRun = run, client = client,
            after = function(seconds, fn)
                timers[#timers + 1] = { seconds = seconds, fn = fn }
            end,
            itemInfo = function(id)
                return "Item" .. id, 1
            end,
        })
        parentFrame = CreateFrame("Frame", nil, UIParent)
        core:Mount(parentFrame, { Enter = function() end, Leave = function() end })
        return core
    end

    before_each(function()
        mock.reset()
        _G.ScrollUtil = nil
        local frameMethods = getmetatable(CreateFrame("Frame")).__index
        frameMethods.SetJustifyH = function() end
        ns = loadModules()
        bus = ns.EventBus.New({})
        client = makeClient()
        timers = {}
        rules = makeRules({ "10", "11", "12", "13", "14" })
        run = {}
        run.Evaluate = function(_, text, key)
            if key == "13" then
                return nil, { kind = "none" }
            end
            return tonumber(text), nil
        end
        ns.BuyingPlan.Log:Clear()
        tab = mount()
        ui = tab.ui
        tab:RefreshList()
    end)

    after_each(function()
        mock.teardown()
    end)

    local function row(price, quantity, own)
        return { unitPrice = price, quantity = quantity, ownerItem = own or false, auctionID = price }
    end

    describe("shopping list", function()
        it("builds one entry for each item with the group path", function()
            assert.are.equal(5, #tab.list)
            assert.are.equal("Herbs/Flowers", tab.list[1].groupPath)
            assert.are.equal(100, tab.list[1].maxPrice)
            assert.are.equal(10, tab.list[1].itemID)
        end)

        it("shows the reason of an item without a max price", function()
            assert.is_nil(tab.list[4].maxPrice)
            assert.are.equal("no data", tab.list[4].reason)
        end)

        it("shows the list rows with the name and the max price", function()
            local group, first = ui.tree.list.rows[1], ui.tree.list.rows[2]
            assert.are.equal("Herbs", group.label.text)
            assert.are.equal("Item10", first.label.text)
            assert.are.equal("100c", first.parts.price.text)
            assert.are.equal("no data", ui.tree.list.rows[5].parts.price.text)
        end)

        it("refreshes the list on demand", function()
            rules = makeRules({ "10" })
            tab.deps.rules = rules
            tab:RefreshList()
            assert.are.equal(1, #tab.list)
        end)
    end)

    describe("one search", function()
        it("searches the selected item and evaluates the rows on the result event", function()
            client.rows[10] = { row(50, 3), row(90, 2), row(150, 5) }
            tab:Select_("10")
            assert.is_true(tab:Search())
            assert.are.same({ 10 }, client.searches)
            fire("COMMODITY_RESULTS", 10)
            local done = tab.results["10"]
            assert.are.equal(5, done.result.quantity)
            assert.are.equal(3 * 50 + 2 * 90, done.result.cost)
            assert.matches("Buyable: 5 units, total cost 330c", ui.summary.text)
            assert.matches("Stop: above max price", ui.summary.text)
        end)

        it("ignores a result event of another item", function()
            tab:Select_("10")
            tab:Search()
            fire("COMMODITY_RESULTS", 99)
            assert.is_nil(tab.results["10"])
            fire("ITEM_RESULTS", { itemID = 10 })
            assert.is_not_nil(tab.results["10"])
        end)

        it("shows the levels above the max only with showAboveMax", function()
            local entry = { maxPrice = 100 }
            local levels = ns.BuyingPlan.PriceLevels({ row(50, 1), row(150, 1), row(60, 1, true) })
            local plain = ns.BuyingTab.DescribeLevels(entry, levels, false)
            assert.are.equal(2, #plain)
            assert.are.equal("buy", plain[1].state)
            assert.are.equal("own", plain[2].state)
            local all = ns.BuyingTab.DescribeLevels(entry, levels, true)
            assert.are.equal(3, #all)
            assert.are.equal("above", all[3].state)
        end)
        it("sets the stack price from the stack size of the buy row", function()
            local item = function(price, quantity, own)
                return { auctionID = price * 100 + quantity, unitPrice = price, quantity = quantity,
                    isCommodity = false, ownerItem = own }
            end
            local levels = ns.BuyingPlan.PriceLevels({ item(50, 5, true), item(50, 20), item(50, 5) })
            assert.are.equal(20, ns.BuyingTab.StackSize(levels[1]))
            local out = ns.BuyingTab.DescribeLevels({ maxPrice = 100 }, levels, false)
            assert.are.equal(1000, out[1].stackPrice)
            local mine = ns.BuyingPlan.PriceLevels({ item(70, 3, true) })
            assert.are.equal(3, ns.BuyingTab.StackSize(mine[1]))
        end)
        it("leaves the stack price empty for a commodity level", function()
            local levels = ns.BuyingPlan.PriceLevels({ row(50, 40) })
            assert.is_nil(ns.BuyingTab.StackSize(levels[1]))
            assert.is_nil(ns.BuyingTab.StackPrice(levels[1]))
            local out = ns.BuyingTab.DescribeLevels({ maxPrice = 100 }, levels, false)
            assert.is_nil(out[1].stackPrice)
        end)
        it("sets the stack price of every level on a client with no commodity market", function()
            ns.Flavour.hasCommodityMarket = false
            local legacy = function(price, quantity, own)
                return { auctionID = price * 100 + quantity, unitPrice = price, quantity = quantity, ownerItem = own }
            end
            local levels = ns.BuyingPlan.PriceLevels({ legacy(5, 20), legacy(5, 20), legacy(9, 1) })
            assert.are.equal(20, ns.BuyingTab.StackSize(levels[1]))
            local out = ns.BuyingTab.DescribeLevels({ maxPrice = 100 }, levels, false)
            assert.are.equal(100, out[1].stackPrice)
            assert.are.equal(9, out[2].stackPrice)
            ns.Flavour.hasCommodityMarket = nil
            assert.are.equal(100, ns.BuyingTab.StackPrice(levels[1]))
        end)
        it("ignores a commodity mark on a client with no commodity market", function()
            ns.Flavour.hasCommodityMarket = false
            local levels = ns.BuyingPlan.PriceLevels({ row(50, 40) })
            assert.are.equal(2000, ns.BuyingTab.StackPrice(levels[1]))
        end)
        it("describes an entry with no max price", function()
            local entry = { noMax = true, key = "10", itemID = 10 }
            local levels = ns.BuyingPlan.PriceLevels({ row(50, 1), row(9000, 1), row(60, 1, true) })
            local out = ns.BuyingTab.DescribeLevels(entry, levels, false)
            assert.are.equal(3, #out)
            assert.are.equal("buy", out[1].state)
            assert.are.equal("own", out[2].state)
            assert.are.equal("buy", out[3].state)
            local result = ns.BuyingPlan.Evaluate(entry, { row(50, 2), row(9000, 1) })
            local lines = ns.BuyingTab.DescribeSummary(entry, result, { row(50, 2), row(9000, 1) })
            assert.are.equal("no max price set", lines[1])
            assert.are.equal("Stop: end of results", lines[3])
            local decision, reason = ns.BuyingTab.DescribeDecision(result)
            assert.matches("would buy 3 at", decision)
            assert.matches("no max price", reason)
        end)

        it("lists an item with no max price and buys at any level", function()
            rules = makeRules({ "20" })
            rules.GetOperation = function()
                return { name = "Default", settings = { maxPrice = "", showAboveMax = false } }
            end
            tab.deps.rules = rules
            tab:RefreshList()
            assert.is_true(tab.list[1].noMax)
            assert.are.equal("no max", ui.tree.list.rows[2].parts.price.text)
            client.rows[20] = { row(50, 1), row(90000, 1) }
            tab:Select_("20")
            tab:Search()
            fire("COMMODITY_RESULTS", 20)
            assert.are.equal(2, tab.results["20"].result.quantity)
            local _, level, _, reason = tab:_NextBuy()
            assert.is_nil(reason)
            assert.are.equal(50, level.unitPrice)
        end)

        it("needs a selected item", function()
            local ok, text = tab:Search()
            assert.is_false(ok)
            assert.are.equal("pick an item first", text)
            assert.are.same({}, client.searches)
        end)

        it("does not search while the client is not ready", function()
            client.ready = false
            tab:Select_("10")
            local ok = tab:Search()
            assert.is_false(ok)
            assert.are.same({}, client.searches)
        end)

        it("gives up after the timeout and logs no response", function()
            tab:Select_("10")
            tab:Search()
            assert.are.equal(10, timers[1].seconds)
            timers[1].fn()
            assert.is_nil(tab.pending)
            local list = ns.BuyingPlan.Log:List()
            assert.are.equal("no response", list[#list].decision)
        end)
    end)

    describe("search all", function()
        it("walks the list one item at a time", function()
            client.rows[10] = { row(50, 1) }
            assert.is_true(tab:SearchAll())
            assert.are.same({ 10 }, client.searches)
            fire("COMMODITY_RESULTS", 10)
            assert.are.same({ 10, 11 }, client.searches)
            fire("COMMODITY_RESULTS", 11)
            fire("COMMODITY_RESULTS", 12)
            -- The item 13 has no max price: it is not searched.
            assert.are.same({ 10, 11, 12, 14 }, client.searches)
            assert.are.equal("no max price", tab.results["13"].result.stop)
            fire("COMMODITY_RESULTS", 14)
            assert.is_nil(tab.queue)
        end)

        it("waits for the ready event", function()
            client.ready = false
            tab:SearchAll()
            assert.are.same({}, client.searches)
            client.ready = true
            fire("READY")
            assert.are.same({ 10 }, client.searches)
        end)

        it("pauses at the rate guard and retries", function()
            client.refuse = "search limit, wait"
            tab:SearchAll()
            assert.are.same({}, client.searches)
            assert.matches("search limit", ui.message.text)
            assert.are.equal(5, timers[1].seconds)
            client.refuse = nil
            timers[1].fn()
            assert.are.same({ 10 }, client.searches)
        end)

        it("starts no second queue and stops on request", function()
            tab:SearchAll()
            assert.is_false(tab:SearchAll())
            tab:Stop()
            fire("COMMODITY_RESULTS", 10)
            assert.are.same({ 10 }, client.searches)
        end)

        it("skips an item at once after a timeout and goes on", function()
            tab:SearchAll()
            timers[1].fn()
            assert.are.same({ 10, 11 }, client.searches)
        end)
    end)

    describe("decision log", function()
        it("logs would buy and the stop reasons", function()
            client.rows[10] = { row(40, 2), row(90, 1) }
            client.rows[11] = { row(500, 1) }
            client.rows[12] = {}
            tab:SearchAll()
            fire("COMMODITY_RESULTS", 10)
            fire("COMMODITY_RESULTS", 11)
            fire("COMMODITY_RESULTS", 12)
            local list = ns.BuyingPlan.Log:List()
            assert.are.equal("would buy 3 at 90c", list[1].decision)
            assert.are.equal("above max price", list[2].decision)
            assert.are.equal("no results", list[3].decision)
            assert.are.equal("no max price", list[4].decision)
            assert.are.equal(10, list[1].itemID)
        end)

        it("shows the log list with the Log toggle", function()
            client.rows[10] = { row(40, 2) }
            tab:Select_("10")
            tab:Search()
            fire("COMMODITY_RESULTS", 10)
            assert.is_true(ui.rowsList.frame:IsShown())
            tab:ToggleLog()
            assert.is_false(ui.rowsList.frame:IsShown())
            assert.is_true(ui.logList.frame:IsShown())
            assert.matches("would buy 2 at 40c", ui.logList.rows[1].parts.text)
            tab:ToggleLog()
            assert.is_true(ui.rowsList.frame:IsShown())
        end)
    end)

    describe("summary", function()
        it("describes the buyable quantity, the cost and the stop reason", function()
            local lines = ns.BuyingTab.DescribeSummary({ maxPrice = 100 },
                ns.BuyingPlan.Evaluate({ maxPrice = 100 }, { row(150, 1) }), { row(150, 1) })
            assert.are.equal("Max price: 100c", lines[1])
            assert.are.equal("Buyable: 0 units, total cost 0c", lines[2])
            assert.are.equal("Stop: above max price", lines[3])
        end)

        it("says end of results when every row is buyable", function()
            local rows = { row(10, 1) }
            local lines = ns.BuyingTab.DescribeSummary({ maxPrice = 100 },
                ns.BuyingPlan.Evaluate({ maxPrice = 100 }, rows), rows)
            assert.are.equal("Stop: end of results", lines[3])
        end)
    end)

    describe("buying", function()
        local function click(button)
            assert.is_true(button.enabled ~= false, "the button is off")
            client.inClick = true
            button.scripts.OnClick(button)
            client.inClick = false
        end

        local function dialog(name)
            for _, frame in ipairs(mock.frames) do
                if frame.name == name then
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

        local function lastLog()
            local list = ns.BuyingPlan.Log:List()
            return list[#list]
        end

        -- Search the item 10 with these rows and wait for the result.
        local function searchItem(rows)
            client.rows[10] = rows
            tab:Select_("10")
            tab:Search()
            fire("COMMODITY_RESULTS", 10)
        end

        local function buyAndQuote(unit, total)
            click(ui.buyNext)
            fire("QUOTE", unit, total)
        end

        it("shows the listings grouped by price level", function()
            searchItem({ row(50, 3), row(50, 2), row(60, 1, true), row(200, 4) })
            assert.are.equal(2, #ui.rowsList.rows)
            local first = ui.rowsList.rows[1].cells
            assert.are.equal("50c", first.unitPrice.text)
            assert.is_false(first.stackPrice.shown)
            assert.is_false(ui.levelHeader.labels.stackPrice.shown)
            assert.are.equal("x5", first.quantity.text)
            assert.is_nil(first.listings)
            assert.is_nil(first.status)
            assert.is_nil(ui.levelHeader.labels.listings)
            assert.is_nil(ui.levelHeader.labels.status)
            assert.are.equal("Unit Price", ui.levelHeader.labels.unitPrice.text)
            assert.are.equal("Stack Price", ui.levelHeader.labels.stackPrice.text)
            assert.are.equal(0.5, ui.rowsList.rows[2].cells.unitPrice.color[1])
        end)

        it("shows the Stack Price column for an item level", function()
            local item = { auctionID = 1, unitPrice = 50, quantity = 20, isCommodity = false }
            searchItem({ item })
            local cells = ui.rowsList.rows[1].cells
            assert.is_true(cells.stackPrice.shown)
            assert.is_true(ui.levelHeader.labels.stackPrice.shown)
            assert.are.equal("1000c", cells.stackPrice.text)
        end)

        it("shows the Stack Price column again after an item follows a commodity", function()
            searchItem({ row(50, 3) })
            assert.is_false(ui.levelHeader.labels.stackPrice.shown)
            client.rows[11] = { { auctionID = 2, unitPrice = 5, quantity = 4, isCommodity = false } }
            tab:Select_("11")
            tab:Search()
            fire("ITEM_RESULTS", 11)
            assert.is_true(ui.levelHeader.labels.stackPrice.shown)
            assert.is_true(ui.rowsList.rows[1].cells.stackPrice.shown)
            assert.are.equal("20c", ui.rowsList.rows[1].cells.stackPrice.text)
        end)

        it("shows the Stack Price column for a level on a client with no commodity market", function()
            ns.Flavour.hasCommodityMarket = false
            searchItem({ row(50, 3) })
            assert.is_true(ui.levelHeader.labels.stackPrice.shown)
            assert.is_true(ui.rowsList.rows[1].cells.stackPrice.shown)
            assert.are.equal("150c", ui.rowsList.rows[1].cells.stackPrice.text)
        end)

        it("keeps the Dry run text and the jump label apart with relative anchors", function()
            assert.are.equal("Jump warning %", ui.jumpLabel.text)
            assert.are.equal(ui.dryRun.Text, ui.jumpLabel.points[1][2])
            assert.are.equal(ui.jumpLabel, ui.jump.points[1][2])
        end)

        it("has no dry run label and keeps a Dry run check box that is off", function()
            assert.is_false(ui.dryRun:GetChecked() and true or false)
            assert.are.equal("Dry run", ui.dryRun.Text.text)
            assert.is_false(ui.buyNext.enabled)
        end)

        it("enables Buy next for a level under the max price", function()
            searchItem({ row(50, 3), row(200, 1) })
            assert.is_true(ui.buyNext.enabled)
            assert.matches("Buy next: 3 at 50c", ui.summary.text)
        end)

        it("disables Buy next above the max price and for an own level", function()
            searchItem({ row(200, 1) })
            assert.is_false(ui.buyNext.enabled)
            assert.matches("Buy next: above max price", ui.summary.text)
            client.rows[10] = { row(50, 1, true), row(60, 1) }
            tab:Search()
            fire("COMMODITY_RESULTS", 10)
            assert.is_false(ui.buyNext.enabled)
            assert.matches("Buy next: own listing", ui.summary.text)
        end)

        it("disables Buy next while the client is not ready or cannot buy", function()
            searchItem({ row(50, 3) })
            client.ready = false
            tab:_Update()
            assert.is_false(ui.buyNext.enabled)
            client.ready, client.canBuy = true, false
            tab:_Update()
            assert.is_false(ui.buyNext.enabled)
            assert.matches("buying is not available", ui.summary.text)
        end)

        it("buys a level: start, quote, confirm, success, next level", function()
            searchItem({ row(50, 3), row(60, 2) })
            click(ui.buyNext)
            assert.are.same({ { "start", 10, 3 } }, client.calls)
            assert.is_nil(dialog("FlipsideBuyConfirm") and dialog("FlipsideBuyConfirm").onYes)
            fire("QUOTE", 50, 150)
            local confirm = dialog("FlipsideBuyConfirm")
            assert.is_true(confirm:IsShown())
            assert.matches("Buy 3 x Item10", confirm.text.text)
            assert.matches("Total: 150c", confirm.text.text)
            assert.matches("Quote time left: 30 s", confirm.text.text)
            assert.are.same({ "start" }, names())
            click(confirm.yesButton)
            assert.are.same({ { "start", 10, 3 }, { "confirm", 10, 3 } }, client.calls)
            fire("BOUGHT")
            assert.are.equal("bought 3 at 50c", lastLog().decision)
            assert.are.same({ 10, 10 }, client.searches)
            client.rows[10] = { row(60, 2) }
            fire("COMMODITY_RESULTS", 10)
            assert.is_true(ui.buyNext.enabled)
            assert.matches("Buy next: 2 at 60c", ui.summary.text)
            assert.are.same({}, client.violations)
            -- The refresh adds no "would buy" line to the log.
            assert.are.equal("bought 3 at 50c", lastLog().decision)
        end)

        it("shows the jump warning on +30 percent and buys on Keep buying", function()
            searchItem({ row(50, 1), row(65, 2) })
            buyAndQuote(50, 50)
            click(dialog("FlipsideBuyConfirm").yesButton)
            fire("BOUGHT")
            client.rows[10] = { row(65, 2) }
            fire("COMMODITY_RESULTS", 10)
            click(ui.buyNext)
            local warning = dialog("FlipsideBuyJump")
            assert.is_true(warning:IsShown())
            assert.are.equal("Price jumps from 50c to 65c (+30%). Keep buying?", warning.text.text)
            assert.are.equal("Keep buying", warning.yesButton.text)
            assert.are.equal("Stop", warning.noButton.text)
            assert.are.same({ "start", "confirm" }, names())
            click(warning.yesButton)
            assert.are.same({ "start", "confirm", "start" }, names())
            assert.are.same({ "start", 10, 2 }, client.calls[3])
            assert.are.same({}, client.violations)
        end)

        it("shows no warning on +20 percent", function()
            searchItem({ row(50, 1), row(60, 1) })
            buyAndQuote(50, 50)
            click(dialog("FlipsideBuyConfirm").yesButton)
            fire("BOUGHT")
            client.rows[10] = { row(60, 1) }
            fire("COMMODITY_RESULTS", 10)
            click(ui.buyNext)
            assert.is_nil(dialog("FlipsideBuyJump") and dialog("FlipsideBuyJump"):IsShown() or nil)
            assert.are.equal("start", client.calls[3][1])
        end)

        it("uses the saved threshold", function()
            local saved = {}
            tab.deps.db = {
                Get = function(_, scope, key)
                    return saved[scope .. key]
                end,
                Set = function(_, scope, key, value)
                    saved[scope .. key] = value
                    return true
                end,
            }
            assert.are.equal(25, tab:GetJumpPercent())
            assert.is_true(tab:SetJumpPercent(10))
            assert.are.equal(10, saved["profilebuying.jumpPercent"])
            assert.are.equal(10, tab:GetJumpPercent())
            assert.is_false(tab:SetJumpPercent(0))
            searchItem({ row(50, 1), row(60, 1) })
            buyAndQuote(50, 50)
            click(dialog("FlipsideBuyConfirm").yesButton)
            fire("BOUGHT")
            client.rows[10] = { row(60, 1) }
            fire("COMMODITY_RESULTS", 10)
            click(ui.buyNext)
            assert.is_true(dialog("FlipsideBuyJump"):IsShown())
        end)

        it("ends the run on Stop and starts no purchase", function()
            searchItem({ row(50, 1), row(65, 1) })
            buyAndQuote(50, 50)
            click(dialog("FlipsideBuyConfirm").yesButton)
            fire("BOUGHT")
            client.rows[10] = { row(65, 1) }
            fire("COMMODITY_RESULTS", 10)
            click(ui.buyNext)
            click(dialog("FlipsideBuyJump").noButton)
            assert.are.same({ "start", "confirm" }, names())
            assert.is_nil(tab.run)
            assert.are.equal("buying stopped", ui.message.text)
        end)

        it("stops at the max price", function()
            searchItem({ row(50, 1), row(150, 1) })
            buyAndQuote(50, 50)
            click(dialog("FlipsideBuyConfirm").yesButton)
            fire("BOUGHT")
            client.rows[10] = { row(150, 1) }
            fire("COMMODITY_RESULTS", 10)
            assert.is_false(ui.buyNext.enabled)
            assert.matches("Buy next: above max price", ui.summary.text)
            local ok, reason = tab:BuyNext()
            assert.is_false(ok)
            assert.are.equal("above max price", reason)
            assert.are.same({ "start", "confirm" }, names())
        end)

        it("shows a quote above the max price in red and needs an explicit confirm", function()
            searchItem({ row(50, 3) })
            buyAndQuote(200, 600)
            local confirm = dialog("FlipsideBuyConfirm")
            assert.are.same({ 1, 0.2, 0.2 }, { confirm.text.color[1], confirm.text.color[2], confirm.text.color[3] })
            assert.matches("Above your max price: 300c", confirm.text.text)
            assert.are.equal("Buy anyway", confirm.yesButton.text)
            assert.are.same({ "start" }, names())
            click(confirm.yesButton)
            assert.are.same({ "start", "confirm" }, names())
        end)

        it("shows a quote under the max price in white", function()
            searchItem({ row(50, 3) })
            buyAndQuote(50, 150)
            local confirm = dialog("FlipsideBuyConfirm")
            assert.are.equal(1, confirm.text.color[2])
            assert.are.equal("Confirm", confirm.yesButton.text)
        end)

        it("cancels the quote on Cancel", function()
            searchItem({ row(50, 3) })
            buyAndQuote(50, 150)
            click(dialog("FlipsideBuyConfirm").noButton)
            assert.are.same({ "start", "cancel" }, names())
            assert.is_nil(tab.buy)
            assert.are.equal("buy cancelled", lastLog().decision)
            assert.is_true(ui.buyNext.enabled)
        end)

        it("cancels the quote on Escape", function()
            searchItem({ row(50, 3) })
            buyAndQuote(50, 150)
            dialog("FlipsideBuyConfirm"):Hide()
            assert.are.same({ "start", "cancel" }, names())
        end)

        it("cancels an open quote when the Auction House closes", function()
            searchItem({ row(50, 3) })
            buyAndQuote(50, 150)
            fire("CLOSE")
            assert.are.same({ "start", "cancel" }, names())
            assert.is_false(dialog("FlipsideBuyConfirm"):IsShown())
            assert.is_nil(tab.buy)
        end)

        it("cancels an open quote when the tab is left", function()
            searchItem({ row(50, 3) })
            buyAndQuote(50, 150)
            tab:Deselect()
            assert.are.same({ "start", "cancel" }, names())
            assert.is_false(dialog("FlipsideBuyConfirm"):IsShown())
        end)

        it("cancels a quote that runs out", function()
            searchItem({ row(50, 3) })
            buyAndQuote(50, 150)
            client.quoteLeft = 0
            timers[#timers].fn()
            assert.are.same({ "start", "cancel" }, names())
            assert.are.equal("the quote ended", ui.message.text)
        end)

        it("updates the time left on the quote", function()
            searchItem({ row(50, 3) })
            buyAndQuote(50, 150)
            client.quoteLeft = 12
            timers[#timers].fn()
            assert.matches("Quote time left: 12 s", dialog("FlipsideBuyConfirm").text.text)
        end)

        it("gives up when no quote comes", function()
            searchItem({ row(50, 3) })
            click(ui.buyNext)
            timers[#timers].fn()
            assert.are.same({ "start", "cancel" }, names())
            assert.are.equal("no quote came", ui.message.text)
        end)

        it("logs a failed purchase and refreshes the rows", function()
            searchItem({ row(50, 3) })
            buyAndQuote(50, 150)
            click(dialog("FlipsideBuyConfirm").yesButton)
            fire("NOTBOUGHT")
            assert.are.equal("buy failed", lastLog().decision)
            assert.are.same({ 10, 10 }, client.searches)
            assert.is_nil(tab.buy)
        end)

        it("logs no response when the result does not come", function()
            searchItem({ row(50, 3) })
            buyAndQuote(50, 150)
            click(dialog("FlipsideBuyConfirm").yesButton)
            timers[#timers].fn()
            assert.are.equal("buy failed", lastLog().decision)
            assert.are.equal("no response", lastLog().reason)
        end)

        it("makes no protected call from an event or a timer", function()
            searchItem({ row(50, 3) })
            buyAndQuote(50, 150)
            fire("QUOTE", 50, 160)
            timers[#timers].fn()
            assert.are.same({ "start" }, names())
            assert.are.same({}, client.violations)
        end)

        it("buys an item auction after a confirm click", function()
            searchItem({ { auctionID = 7, unitPrice = 30, quantity = 1, isCommodity = false, buyout = 30 } })
            click(ui.buyNext)
            assert.are.same({}, client.calls)
            local confirm = dialog("FlipsideBuyConfirm")
            assert.is_true(confirm:IsShown())
            assert.matches("Total: 30c", confirm.text.text)
            click(confirm.yesButton)
            assert.are.same({ { "bid", 7, 30 } }, client.calls)
            fire("ITEMBOUGHT", 7)
            assert.are.equal("bought 1 at 30c", lastLog().decision)
            assert.are.same({}, client.violations)
        end)

        it("logs an item buy error", function()
            searchItem({ { auctionID = 7, unitPrice = 30, quantity = 1, isCommodity = false, buyout = 30 } })
            click(ui.buyNext)
            click(dialog("FlipsideBuyConfirm").yesButton)
            fire("ITEMERR", 5)
            assert.are.equal("buy failed", lastLog().decision)
            assert.are.equal("error 5", lastLog().reason)
        end)

        it("ignores an item result of another auction", function()
            searchItem({ { auctionID = 7, unitPrice = 30, quantity = 1, isCommodity = false, buyout = 30 } })
            click(ui.buyNext)
            click(dialog("FlipsideBuyConfirm").yesButton)
            fire("ITEMBOUGHT", 8)
            assert.is_not_nil(tab.buy)
        end)

        it("only logs in dry run", function()
            searchItem({ row(50, 3) })
            tab:SetDryRun(true)
            click(ui.buyNext)
            assert.are.same({}, client.calls)
            assert.are.equal("would buy 3 at 50c", lastLog().decision)
            assert.are.equal("dry run", lastLog().reason)
            assert.is_nil(dialog("FlipsideBuyConfirm"))
        end)
    end)

    describe("selecting a price level", function()
        local function click(button)
            assert.is_true(button.enabled ~= false, "the button is off")
            client.inClick = true
            button.scripts.OnClick(button)
            client.inClick = false
        end

        local function dialog(name)
            for _, frame in ipairs(mock.frames) do
                if frame.name == name then
                    return frame
                end
            end
        end

        local function lastLog()
            local list = ns.BuyingPlan.Log:List()
            return list[#list]
        end

        local function auction(id, price, own)
            return { auctionID = id, unitPrice = price, quantity = 1, isCommodity = false, buyout = price,
                ownerItem = own or false }
        end

        local function search(rows)
            client.rows[10] = rows
            tab:Select_("10")
            tab:Search()
            fire("ITEM_RESULTS", 10)
        end

        local function pick(index)
            local level = ui.rowsList.rows[index]
            level.scripts.OnClick(level)
        end

        it("selects a row with the highlight and names the button", function()
            search({ auction(1, 30), auction(2, 40) })
            assert.are.equal("Buy next", ui.buyNext.text)
            pick(2)
            assert.are.equal("Buy selected", ui.buyNext.text)
            assert.is_true(ui.rowsList.rows[2].selection:IsShown())
            assert.is_false(ui.rowsList.rows[1].selection:IsShown())
            assert.is_true(ui.buyNext.enabled)
            assert.matches("Buy selected: 1 at 40c", ui.summary.text)
        end)

        it("clears the selection on a second click on the same row", function()
            search({ auction(1, 30), auction(2, 40) })
            pick(2)
            pick(2)
            assert.are.equal("Buy next", ui.buyNext.text)
            assert.is_false(ui.rowsList.rows[2].selection:IsShown())
        end)

        it("buys the selected level, not the cheapest", function()
            search({ auction(1, 30), auction(2, 40) })
            pick(2)
            click(ui.buyNext)
            assert.are.same({}, client.calls)
            click(dialog("FlipsideBuyJump").yesButton)
            click(dialog("FlipsideBuyConfirm").yesButton)
            assert.are.same({ { "bid", 2, 40 } }, client.calls)
            assert.are.same({}, client.violations)
        end)

        it("compares the selected level with the cheapest level for the jump warning", function()
            search({ auction(1, 30), auction(2, 40) })
            pick(2)
            click(ui.buyNext)
            local warning = dialog("FlipsideBuyJump")
            assert.is_true(warning:IsShown())
            assert.are.equal("Price jumps from 30c to 40c (+33%). Keep buying?", warning.text.text)
            assert.are.same({}, client.calls)
        end)

        it("shows no warning when the selected level is within the threshold", function()
            search({ auction(1, 30), auction(2, 36) })
            pick(2)
            click(ui.buyNext)
            assert.is_nil(dialog("FlipsideBuyJump"))
            assert.is_true(dialog("FlipsideBuyConfirm"):IsShown())
            click(dialog("FlipsideBuyConfirm").yesButton)
            assert.are.same({ { "bid", 2, 36 } }, client.calls)
        end)

        it("keeps Buy next with no selection", function()
            search({ auction(1, 30), auction(2, 40) })
            click(ui.buyNext)
            click(dialog("FlipsideBuyConfirm").yesButton)
            assert.are.same({ { "bid", 1, 30 } }, client.calls)
        end)

        it("selects an own row but turns the button off with a reason", function()
            search({ auction(1, 30), auction(2, 40, true) })
            pick(2)
            assert.is_true(ui.rowsList.rows[2].selection:IsShown())
            assert.is_false(ui.buyNext.enabled)
            assert.are.equal("own listing", ui.message.text)
            assert.is_false((tab:BuyNext()))
            assert.are.same({}, client.calls)
        end)

        it("selects an above max row but turns the button off with a reason", function()
            tab.deps.rules.GetOperation = function()
                return { name = "Cheap", settings = { maxPrice = "100", showAboveMax = true } }
            end
            tab:RefreshList()
            search({ auction(1, 30), auction(2, 150) })
            assert.are.equal(0.5, ui.rowsList.rows[2].cells.unitPrice.color[1])
            pick(2)
            assert.is_true(ui.rowsList.rows[2].selection:IsShown())
            assert.is_false(ui.buyNext.enabled)
            assert.are.equal("above max price", ui.message.text)
            assert.is_false((tab:BuyNext()))
        end)

        it("keeps the selection on the same level after a new result", function()
            search({ auction(1, 30), auction(2, 40), auction(3, 50) })
            pick(2)
            client.rows[10] = { auction(2, 40), auction(3, 50), auction(4, 40) }
            tab:Search()
            fire("ITEM_RESULTS", 10)
            assert.are.equal(40, tab.levelSel)
            assert.are.equal("Buy selected", ui.buyNext.text)
            assert.is_true(ui.rowsList.rows[1].selection:IsShown())
        end)

        it("clears the selection when the level is gone", function()
            search({ auction(1, 30), auction(2, 40) })
            pick(2)
            client.rows[10] = { auction(1, 30) }
            tab:Search()
            fire("ITEM_RESULTS", 10)
            assert.is_nil(tab.levelSel)
            assert.are.equal("Buy next", ui.buyNext.text)
        end)

        it("clears the selection when another item is picked", function()
            search({ auction(1, 30), auction(2, 40) })
            pick(2)
            tab:Select_("11")
            assert.is_nil(tab.levelSel)
        end)

        it("logs the selected level in dry run", function()
            search({ auction(1, 30), auction(2, 40) })
            tab:SetDryRun(true)
            pick(2)
            click(ui.buyNext)
            assert.are.same({}, client.calls)
            assert.are.equal("would buy 1 at 40c", lastLog().decision)
            assert.are.equal("dry run", lastLog().reason)
        end)

        -- Commodity levels: 50 x3, 60 x2, 70 x4, 150 x1 (the max price is 100).
        local function searchCommodity(rows)
            client.rows[10] = rows or { row(50, 3), row(60, 2), row(70, 4), row(150, 1) }
            tab:Select_("10")
            tab:Search()
            fire("COMMODITY_RESULTS", 10)
        end

        it("buys a commodity up to the selected level in one purchase", function()
            searchCommodity()
            pick(2)
            assert.is_true(ui.buyNext.enabled)
            assert.matches("Buy selected: 5 up to 60c, total 270c", ui.summary.text)
            click(ui.buyNext)
            assert.are.same({ { "start", 10, 5 } }, client.calls)
            fire("QUOTE", 54, 270)
            local confirm = dialog("FlipsideBuyConfirm")
            assert.matches("Buy 5 x Item10", confirm.text.text)
            assert.matches("Total: 270c", confirm.text.text)
            click(confirm.yesButton)
            assert.are.same({ { "start", 10, 5 }, { "confirm", 10, 5 } }, client.calls)
            assert.are.same({}, client.violations)
        end)

        it("checks the jump warning against the selected price", function()
            searchCommodity()
            pick(3)
            click(ui.buyNext)
            local warning = dialog("FlipsideBuyJump")
            assert.are.equal("Price jumps from 50c to 70c (+40%). Keep buying?", warning.text.text)
            assert.are.same({}, client.calls)
            click(warning.yesButton)
            assert.are.same({ { "start", 10, 9 } }, client.calls)
        end)

        it("buys the amount N of the cheapest units, capped at the selected level", function()
            searchCommodity()
            pick(2)
            tab:SetAmount("4")
            assert.matches("Buy selected: 4 up to 60c, total 210c", ui.summary.text)
            click(ui.buyNext)
            assert.are.same({ { "start", 10, 4 } }, client.calls)
        end)

        it("caps the amount at the units up to the selected level", function()
            searchCommodity()
            pick(2)
            tab:SetAmount("99")
            click(ui.buyNext)
            assert.are.same({ { "start", 10, 5 } }, client.calls)
        end)

        it("uses the amount with no selected level, capped at the next level", function()
            searchCommodity()
            tab:SetAmount("2")
            assert.matches("Buy next: 2 at 50c, total 100c", ui.summary.text)
            click(ui.buyNext)
            assert.are.same({ { "start", 10, 2 } }, client.calls)
        end)

        it("caps the amount with no selected level at the next level", function()
            searchCommodity()
            tab:SetAmount("9")
            click(ui.buyNext)
            assert.are.same({ { "start", 10, 3 } }, client.calls)
        end)

        it("buys all units when the amount is empty", function()
            searchCommodity()
            pick(2)
            tab:SetAmount("4")
            tab:SetAmount("")
            assert.is_nil(tab.amount)
            click(ui.buyNext)
            assert.are.same({ { "start", 10, 5 } }, client.calls)
        end)

        it("refuses an amount that is not a whole number above 0", function()
            searchCommodity()
            for _, text in ipairs({ "0", "abc", "-3", "2.5" }) do
                tab:SetAmount(text)
                assert.is_false(ui.buyNext.enabled, text)
                assert.are.equal("amount must be a whole number above 0", ui.message.text)
                assert.is_false((tab:BuyNext()))
            end
            assert.are.same({}, client.calls)
            tab:SetAmount("2")
            assert.is_true(ui.buyNext.enabled)
        end)

        it("reads the amount from the text box", function()
            searchCommodity()
            ui.amount:SetText("3")
            ui.amount.scripts.OnTextChanged(ui.amount)
            assert.are.equal(3, tab.amount)
        end)

        it("highlights the rows that the next click buys", function()
            searchCommodity()
            local function covered()
                local out = {}
                for index = 1, #ui.rowsList.rows do
                    out[index] = ui.rowsList.rows[index].cover:IsShown()
                end
                return out
            end
            assert.are.same({ true, false, false }, covered())
            pick(3)
            assert.are.same({ true, true, false }, covered())
            assert.is_true(ui.rowsList.rows[3].selection:IsShown())
            tab:SetAmount("4")
            assert.are.same({ true, true, false }, covered())
            tab:SetAmount("2")
            assert.are.same({ true, false, false }, covered())
            assert.is_true(ui.rowsList.rows[3].selection:IsShown())
            tab:SetAmount("")
            pick(3)
            tab:SetAmount("1")
            assert.are.same({ true, false, false }, covered())
        end)

        it("refuses a selected level when an own level lies below it", function()
            searchCommodity({ row(50, 3), row(60, 2, true), row(70, 4) })
            pick(3)
            assert.is_false(ui.buyNext.enabled)
            assert.are.equal("own listing below the selected level", ui.message.text)
        end)

        it("moves the run on only after a whole level is bought", function()
            searchCommodity()
            tab:SetAmount("2")
            click(ui.buyNext)
            fire("QUOTE", 50, 100)
            click(dialog("FlipsideBuyConfirm").yesButton)
            fire("BOUGHT")
            assert.is_nil(tab.run.lastPrice)
            tab:SetAmount("")
            client.rows[10] = { row(50, 1), row(60, 2) }
            fire("COMMODITY_RESULTS", 10)
            click(ui.buyNext)
            fire("QUOTE", 50, 50)
            click(dialog("FlipsideBuyConfirm").yesButton)
            fire("BOUGHT")
            assert.are.equal(50, tab.run.lastPrice)
        end)

        it("logs the units and the top price in dry run", function()
            searchCommodity()
            tab:SetDryRun(true)
            pick(2)
            tab:SetAmount("4")
            click(ui.buyNext)
            assert.are.same({}, client.calls)
            assert.are.equal("would buy 4 at 60c", lastLog().decision)
        end)

        it("turns the amount box off for an item and buys one auction", function()
            search({ auction(1, 30), auction(2, 36) })
            assert.is_false(ui.amount.enabled)
            tab:SetAmount("5")
            pick(2)
            click(ui.buyNext)
            click(dialog("FlipsideBuyConfirm").yesButton)
            assert.are.same({ { "bid", 2, 36 } }, client.calls)
        end)

        it("turns the amount box on for a commodity", function()
            searchCommodity()
            assert.is_true(ui.amount.enabled)
        end)
    end)
    describe("registry", function()
        it("registers the Buying tab for hosts with many tabs", function()
            local spec = ns.AuctionTabs.List()[1]
            assert.are.equal("buying", spec.id)
            assert.are.equal("Buying", spec.label)
        end)

        it("is not available without live search", function()
            local spec = ns.AuctionTabs.List()[1]
            ns.AuctionClient = client
            assert.is_true(spec.available({ rules = rules, formulaRun = run }))
            client.canLive = false
            assert.is_false(spec.available({ rules = rules, formulaRun = run }))
            assert.is_false(spec.available({ formulaRun = run }))
        end)
    end)

    it("removes its events on unmount", function()
        tab:Unmount()
        assert.is_false(bus:HasSubscribers("COMMODITY_RESULTS"))
        assert.is_false(bus:HasSubscribers("READY"))
    end)
end)

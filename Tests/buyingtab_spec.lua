local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end }
    for _, name in ipairs({ "EventBus", "ItemString", "BuyingPlan", "Theme", "Widgets", "List",
        "AuctionTabs", "BuyingTab" }) do
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
            local first = ui.list.rows[1]
            assert.are.equal("Item10", first.parts.name.text)
            assert.are.equal("100c", first.parts.price.text)
            assert.are.equal("Herbs/Flowers", first.parts.sub.text)
            assert.are.equal("no data", ui.list.rows[4].parts.price.text)
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
            assert.is_false(ui.search.enabled)
            fire("COMMODITY_RESULTS", 10)
            local done = tab.results["10"]
            assert.are.equal(5, done.result.quantity)
            assert.are.equal(3 * 50 + 2 * 90, done.result.cost)
            assert.is_true(ui.search.enabled)
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

        it("shows the rows above the max only with showAboveMax", function()
            local entry = { maxPrice = 100 }
            local rows = { row(50, 1), row(150, 1), row(60, 1, true) }
            local plain = ns.BuyingTab.DescribeRows(entry, rows, false)
            assert.are.equal(2, #plain)
            assert.are.equal("buy", plain[1].state)
            assert.are.equal("own", plain[2].state)
            local all = ns.BuyingTab.DescribeRows(entry, rows, true)
            assert.are.equal(3, #all)
            assert.are.equal("above", all[2].state)
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

        it("has a Buy next button that stays off", function()
            assert.is_false(ui.buyNext.enabled)
            assert.matches("dry run", ui.dryRun.text)
        end)
    end)

    describe("search all", function()
        it("walks the list one item at a time", function()
            client.rows[10] = { row(50, 1) }
            assert.is_true(tab:SearchAll())
            assert.are.same({ 10 }, client.searches)
            assert.is_false(ui.searchAll.enabled)
            fire("COMMODITY_RESULTS", 10)
            assert.are.same({ 10, 11 }, client.searches)
            fire("COMMODITY_RESULTS", 11)
            fire("COMMODITY_RESULTS", 12)
            -- The item 13 has no max price: it is not searched.
            assert.are.same({ 10, 11, 12, 14 }, client.searches)
            assert.are.equal("no max price", tab.results["13"].result.stop)
            fire("COMMODITY_RESULTS", 14)
            assert.is_nil(tab.queue)
            assert.is_true(ui.searchAll.enabled)
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

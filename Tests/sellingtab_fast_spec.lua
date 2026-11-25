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

describe("SellingTab fast clicks and the loading pane", function()
    local ns, bus, client, tab, ui, bagItems, itemGroup, groups, timers

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
        c.CloseEvent = function() return "CLOSE" end
        c.ItemIsCommodity = function(itemID) return c.commodity[itemID] end
        c.CanReadOwned = function() return false end
        c.AvailablePostCount = function() return 1000 end
        c.IsSellItemValid = function() return true end
        c.RefreshOwned = function() end
        c.PostCommodity = function() return false end
        c.ConfirmPostCommodity = function() end
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

    local function mount(extra)
        local deps = {
            bus = bus, rules = makeRules(), formulaRun = { Evaluate = function(_, text) return tonumber(text) end },
            client = client,
            after = function(seconds, fn) timers[#timers + 1] = { seconds = seconds, fn = fn } end,
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
        client.commodity[12] = true
        timers = {}
        groups = { [1] = { name = "Base", children = { 2 } }, [2] = { name = "Cloth", children = {} } }
        itemGroup = { ["10"] = 2, ["11"] = 2, ["12"] = 2 }
        bagItems = {
            { key = "12", itemID = 12, name = "Copper Ore", count = 8, stacks = { { bag = 2, slot = 2, count = 8 } } },
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
    local function entryOf(key)
        for _, entry in ipairs(tab.entries) do
            if entry.key == key then
                return entry
            end
        end
    end

    -- Select an item row as the click of a user does. No result comes.
    local function pickItem(itemID)
        ui.tree:Select("i" .. itemID)
    end

    -- Answer the search of an item with rows.
    local function answer(itemID, rows)
        client.rows[itemID] = rows
        bus:Emit(itemID == 10 and "ITEM_RESULTS" or "COMMODITY_RESULTS", itemID)
    end

    -- Run the timers that were set with this number of seconds, in the order of their setting.
    local function runTimers(seconds)
        local list, rest = {}, {}
        for _, timer in ipairs(timers) do
            table.insert(timer.seconds == seconds and list or rest, timer)
        end
        timers = rest
        for _, timer in ipairs(list) do
            timer.fn()
        end
        return #list
    end

    describe("latest selection wins", function()
        it("drops the result of an item that is not selected any more and searches the wanted item at once", function()
            client.rows[10] = { arow(160, 1) }
            pickItem(11)
            assert.are.same({ 11 }, client.searches)
            pickItem(10)
            -- Only one query is in flight.
            assert.are.same({ 11 }, client.searches)
            answer(11, { crow(150, 5) })
            assert.are.same({ 11, 10 }, client.searches)
            assert.are.equal("waiting", entryOf("11").status)
            assert.is_nil(entryOf("11").decision)
            assert.is_nil(tab.live)
            answer(10, { arow(160, 1) })
            assert.are.equal(10, tab.live.itemID)
            assert.are.equal(1, #ui.levelList.data)
            assert.is_false(ui.levelLoading:IsShown())
        end)

        it("searches only the last of three fast clicks after the search that runs", function()
            pickItem(11)
            pickItem(10)
            pickItem(12)
            assert.are.same({ 11 }, client.searches)
            answer(11, { crow(150, 5) })
            assert.are.same({ 11, 12 }, client.searches)
            assert.are.equal("waiting", entryOf("10").status)
            answer(12, { crow(30, 8) })
            assert.are.same({ 11, 12 }, client.searches)
            assert.are.equal(12, tab.live.itemID)
            assert.are.equal(1, #ui.levelList.data)
        end)

        it("recovers with the timeout: the search that runs is dropped and the wanted item is searched", function()
            pickItem(11)
            pickItem(10)
            assert.are.equal(1, runTimers(4))
            assert.are.same({ 11, 10 }, client.searches)
            assert.are.equal("waiting", entryOf("11").status)
            assert.is_nil(entryOf("11").decision)
        end)

        it("recovers with the timeout when the wanted item gets no answer", function()
            pickItem(11)
            assert.are.equal(1, runTimers(4))
            assert.are.equal("skip", entryOf("11").status)
            assert.is_nil(tab.pending)
            assert.is_false(ui.levelLoading:IsShown())
            -- A new click searches again.
            pickItem(10)
            assert.are.same({ 11, 10 }, client.searches)
        end)

        it("gives the wait state back to a search that the AH close ended", function()
            pickItem(11)
            bus:Emit("CLOSE")
            assert.is_nil(tab.pending)
            assert.are.equal("waiting", entryOf("11").status)
        end)

        it("searches the rows of a decided item once after a run of fast clicks", function()
            pickItem(11)
            answer(11, { crow(150, 5) })
            pickItem(10)
            answer(10, { arow(160, 1) })
            local decision = entryOf("11").decision
            -- Item 11 is decided, but the rows of the last search are the rows of item 10.
            pickItem(11)
            pickItem(10)
            pickItem(11)
            assert.are.same({ 11, 10 }, client.searches)
            assert.is_true(ui.levelLoading:IsShown())
            runTimers(0.15)
            assert.are.same({ 11, 10, 11 }, client.searches)
            answer(11, { crow(155, 4) })
            assert.are.equal(11, tab.live.itemID)
            assert.are.equal(1, #ui.levelList.data)
            assert.are.equal(155, ui.levelList.data[1].unitPrice)
            -- The pane search keeps the decision of the entry.
            assert.are.equal(decision, entryOf("11").decision)
            assert.are.equal("ready", entryOf("11").status)
            assert.is_false(ui.levelLoading:IsShown())
        end)
    end)

    describe("the loading state", function()
        it("shows Loading prices with dots and no rows while the pane waits, and gives no buy menu", function()
            pickItem(11)
            answer(11, { crow(150, 5) })
            assert.are.equal(1, #ui.levelList.data)
            assert.is_false(ui.levelLoading:IsShown())
            pickItem(10)
            assert.is_true(ui.levelLoading:IsShown())
            assert.are.equal("Loading prices.", ui.levelLoading.text)
            -- The rows of the old item are not shown.
            assert.are.same({}, ui.levelList.data)
            assert.is_nil(tab:LevelMenuEntries(150))
            assert.are.equal(1, runTimers(0.4))
            assert.are.equal("Loading prices..", ui.levelLoading.text)
            assert.are.equal(1, runTimers(0.4))
            assert.are.equal("Loading prices...", ui.levelLoading.text)
            answer(10, { arow(160, 1) })
            assert.is_false(ui.levelLoading:IsShown())
            assert.are.equal(1, #ui.levelList.data)
            -- The ticker stops when the rows are there.
            runTimers(0.4)
            assert.are.equal(0, runTimers(0.4))
        end)

        it("shows no loading text with no item selected", function()
            assert.is_false(ui.levelLoading:IsShown())
        end)
    end)

    describe("the search for the rows of the pane", function()
        -- Item 11 is decided but the rows in the pane are the rows of item 10.
        local function decidedWithoutRows()
            pickItem(11)
            answer(11, { crow(150, 5) })
            pickItem(10)
            answer(10, { arow(160, 1) })
            pickItem(11)
        end

        it("sends no second search after a timeout of the wanted item", function()
            pickItem(11)
            runTimers(4)
            assert.are.equal("skip", entryOf("11").status)
            assert.are.equal(11, tab.rowsFailed)
            assert.are.same({ 11 }, client.searches)
            assert.is_nil(tab.pending)
        end)

        it("sends no search while a post is open", function()
            decidedWithoutRows()
            assert.is_true(ui.postNext.enabled)
            ui.postNext.scripts.OnClick(ui.postNext)
            assert.is_true(tab.multi ~= nil or tab.lock ~= nil)
            runTimers(0.15)
            assert.are.same({ 11, 10 }, client.searches)
        end)

        it("sends no search while the tab is hidden", function()
            decidedWithoutRows()
            tab:Deselect()
            runTimers(0.15)
            assert.are.same({ 11, 10 }, client.searches)
        end)

        it("refuses a buy while the pane loads, also in the delay and while it retries", function()
            decidedWithoutRows()
            local ok, reason = tab:BuyLevel(150)
            assert.is_false(ok)
            assert.are.equal("loading prices", reason)
            assert.are.same({}, client.calls)
            client.ready = false
            runTimers(0.15)
            assert.is_true(tab.retrying)
            assert.are.equal("loading prices", select(2, tab:BuyLevel(150)))
        end)

        it("stops the retries after three tries and ends the loading state", function()
            decidedWithoutRows()
            client.ready = false
            runTimers(0.15)
            for _ = 1, 6 do
                assert.are.equal(1, runTimers(1))
            end
            assert.are.equal(11, tab.rowsFailed)
            assert.are.equal(0, runTimers(1))
            assert.is_false(ui.levelLoading:IsShown())
            assert.are.same({ 11, 10 }, client.searches)
        end)
    end)

    describe("the loading text", function()
        it("goes away after Stop: nothing searches the waiting item", function()
            pickItem(11)
            pickItem(10)
            assert.is_true(ui.levelLoading:IsShown())
            tab:Stop()
            assert.is_false(ui.levelLoading:IsShown())
            runTimers(0.4)
            assert.are.equal(0, runTimers(0.4))
        end)

        it("stops the ticker when the tab is hidden", function()
            pickItem(11)
            assert.are.equal("Loading prices.", ui.levelLoading.text)
            tab:Deselect()
            assert.are.equal(1, runTimers(0.4))
            assert.are.equal("Loading prices.", ui.levelLoading.text)
            assert.are.equal(0, runTimers(0.4))
        end)
    end)

    describe("a fast queue", function()
        local function answerAny(itemID)
            answer(itemID, itemID == 10 and { arow(160, 1) } or { crow(150, 5) })
        end

        it("sends the next search at once when a result comes, with no timer", function()
            ui.tree:Select("g2")
            assert.are.equal(1, #client.searches)
            answerAny(client.searches[1])
            assert.are.equal(2, #client.searches)
            answerAny(client.searches[2])
            assert.are.equal(3, #client.searches)
        end)

        it("sends the next search at the ready event, before the retry timer", function()
            client.ready = false
            pickItem(11)
            assert.are.same({}, client.searches)
            client.ready = true
            bus:Emit("READY")
            assert.are.same({ 11 }, client.searches)
            -- The retry timer that is left does no second search.
            runTimers(1)
            assert.are.same({ 11 }, client.searches)
        end)

        it("draws the panel once for a result that decides an entry and starts the next search", function()
            ui.tree:Select("g2")
            local draws = 0
            local update = tab._Update
            tab._Update = function(self)
                -- Count only the real redraws: a call inside a batch only sets the dirty flag.
                draws = draws + ((self.batchDepth or 0) == 0 and 1 or 0)
                return update(self)
            end
            answerAny(client.searches[1])
            assert.are.equal(2, #client.searches)
            assert.are.equal(1, draws)
        end)
    end)

    describe("the stored price in the loading pane", function()
        it("builds the line from the lowest price and the age", function()
            assert.is_nil(ns.SellingTab.StoredText(nil, 2))
            assert.is_nil(ns.SellingTab.StoredText(0, 2))
            assert.is_truthy(ns.SellingTab.StoredText(12000, 5):find("5 h old", 1, true))
            assert.is_truthy(ns.SellingTab.StoredText(12000, 0.2):find("under 1 h old", 1, true))
            assert.is_truthy(ns.SellingTab.StoredText(12000, 72):find("3 d old", 1, true))
            assert.are.equal("Loading prices..\nStored price", ns.SellingTab.LoadingText(2, "Stored price"))
            assert.are.equal("Loading prices.", ns.SellingTab.LoadingText(1, nil))
        end)

        it("shows at once, stays under the dots and goes away with the live rows", function()
            ns.ScanSources = { Compute = function() return { scanMin = 12000, scanAge = 5 } end }
            tab.deps.getRecord = function() return {} end
            tab.deps.now = function() return 1 end
            pickItem(11)
            assert.is_true(ui.levelLoading:IsShown())
            assert.is_truthy(ui.levelLoading.text:find("^Loading prices%.\nStored price .*5 h old"))
            runTimers(0.4)
            assert.is_truthy(ui.levelLoading.text:find("^Loading prices%.%.\nStored price"))
            answer(11, { crow(150, 5) })
            assert.is_false(ui.levelLoading:IsShown())
            assert.are.equal(150, ui.levelList.data[1].unitPrice)
        end)
    end)

    describe("the Available text", function()
        local function available(rows)
            local levels = ns.BuyingPlan.PriceLevels(rows)
            return ns.SellingTab.LevelRows(levels, nil)[1].available
        end

        it("is just the count for a Forever level of one-item auctions", function()
            assert.are.equal("17", available({ { auctionID = 1, unitPrice = 114, quantity = 17, buyout = 114,
                isCommodity = false, perItem = true } }))
        end)

        it("is stacks x size for real TBC stacks", function()
            local rows = {}
            for id = 1, 3 do
                rows[id] = { auctionID = id, unitPrice = 10, quantity = 20, buyout = 200, isCommodity = false,
                    owner = "Bob" }
            end
            assert.are.equal("3 x 20", available(rows))
        end)

        it("is the size for one TBC stack", function()
            assert.are.equal("20", available({ { auctionID = 1, unitPrice = 10, quantity = 20, buyout = 200,
                isCommodity = false, owner = "Bob" } }))
        end)

        it("is just the count for a TBC level of stacks of one item", function()
            local rows = {}
            for id = 1, 5 do
                rows[id] = { auctionID = id, unitPrice = 10, quantity = 1, buyout = 10, isCommodity = false,
                    owner = "Bob" }
            end
            assert.are.equal("5", available(rows))
        end)

        it("is the quantity for a commodity", function()
            assert.are.equal("12", available({ crow(5, 12) }))
        end)
    end)
end)
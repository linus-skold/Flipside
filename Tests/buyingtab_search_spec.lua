local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end }
    for _, name in ipairs({ "EventBus", "SettingsDB", "ItemString", "OperationSchema", "ItemNameIndex", "BuyingPlan",
        "SearchLists", "Theme", "Widgets", "Window", "List", "Tree", "Tabs", "Columns", "AuctionTabs", "BuyingTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

describe("BuyingTab name search", function()
    local ns, bus, client, tab, ui, finder, timers

    local function makeClient()
        local c = { ready = true, searches = {}, rows = {} }
        c.CanLiveSearch = function() return true end
        c.IsReady = function() return c.ready end
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

    -- Group 2 holds item "100" with a buying operation (max 500).
    local function makeRules()
        local ops = { [7] = { name = "Cheap", settings = { maxPrice = "500", showAboveMax = false } } }
        return {
            Walk = function(_, fn) fn(1) fn(2) end,
            Children = function(_, id) return id == 1 and { 2 } or {} end,
            Name = function() return "Herbs" end,
            ItemsIn = function(_, id) return id == 2 and { "100" } or {} end,
            Path = function() return { "Base", "Herbs" } end,
            GroupOf = function(_, key) return key == "100" and 2 or nil end,
            EffectiveOperation = function(_, group) return group == 2 and 7 or nil end,
            GetOperation = function(_, id) return ops[id] end,
        }
    end

    -- A finder double: Find records the call and answers with the next reply at once.
    local function makeFinder()
        local f = { calls = {}, reply = { { itemID = 100, name = "Peacebloom", key = "100" },
            { itemID = 300, name = "Peacebloom Seed", key = "300" } } }
        function f:Find(query, callback, options)
            self.calls[#self.calls + 1] = { query = query, exact = options and options.exact }
            callback(self.reply, self.err)
        end
        return f
    end

    before_each(function()
        mock.reset()
        _G.ScrollUtil = nil
        getmetatable(CreateFrame("Frame")).__index.SetJustifyH = function() end
        ns = loadModules()
        bus = ns.EventBus.New({})
        timers = {}
        client = makeClient()
        finder = makeFinder()
        ns.BuyingPlan.Log:Clear()
        tab = ns.BuyingTab.New({
            bus = bus, rules = makeRules(),
            formulaRun = { Evaluate = function(_, text) return tonumber(text), nil end },
            client = client, ahNameSearch = finder, isAuctionHouseOpen = function() return true end,
            after = function(seconds, fn) timers[#timers + 1] = { seconds = seconds, fn = fn } end,
            itemInfo = function(id) return "item " .. id, 1 end,
        })
        tab:Mount(CreateFrame("Frame", nil, UIParent), { Enter = function() end, Leave = function() end })
        ui = tab.ui
    end)

    after_each(function()
        mock.teardown()
    end)

    it("runs the name query and builds one entry for each result with its key and no max price", function()
        assert.is_true(tab:SearchName("  peace "))
        assert.are.same({ { query = "peace", exact = false } }, finder.calls)
        assert.are.equal(2, #tab.list)
        assert.are.equal("100", tab.list[1].key)
        assert.are.equal(300, tab.list[2].itemID)
        -- The group operation of item 100 does not apply to a searched item.
        assert.is_true(tab.list[1].noMax)
        assert.is_nil(tab.list[1].maxPrice)
        assert.are.equal("Peacebloom", tab:_ItemName(tab.list[1]))
        assert.are.equal(2, #tab.nodes)
        assert.are.equal("item", tab.nodes[1].kind)
        assert.are.equal("no max", ui.tree.list.rows[1].parts.price.text)
    end)

    it("passes an exact name in quotes to the query", function()
        tab:SearchName('"Peacebloom"')
        assert.are.same({ query = "Peacebloom", exact = true }, finder.calls[1])
    end)

    it("runs from the Enter key and the Search button", function()
        ui.searchInput:SetText("peace")
        ui.searchInput.scripts.OnEnterPressed(ui.searchInput)
        assert.are.equal(1, #finder.calls)
        ui.searchButton.scripts.OnClick(ui.searchButton)
        assert.are.equal(2, #finder.calls)
    end)

    it("shows no items found for an empty result", function()
        finder.reply = {}
        assert.is_true(tab:SearchName("zzz"))
        assert.are.equal(0, #tab.list)
        assert.are.equal("no items found", ui.summary.text)
        assert.are.equal("no items found", ui.message.text)
    end)

    it("shows the error of a failed search and keeps the old view", function()
        tab:RefreshList()
        finder.reply, finder.err = nil, "open the Auction House to search it"
        tab:SearchName("peace")
        assert.are.equal("open the Auction House to search it", ui.message.text)
        assert.is_nil(tab.searchResults)
        assert.are.equal(1, #tab.list)
    end)

    it("starts the buy flow for a clicked result and shows the real price with no max price", function()
        tab:SearchName("peace")
        client.rows[300] = { { unitPrice = 700, quantity = 2, isCommodity = false, auctionID = 9, buyout = 1400 } }
        tab:_OnTreeSelect(tab.nodes[2])
        assert.are.same({ 300 }, client.searches)
        bus:Emit("ITEM_RESULTS", 300)
        assert.matches("No max price", ui.summary.text)
        local ok = tab:BuyNext()
        assert.is_true(ok)
        assert.are.equal("quoted", tab.buy.phase)
        assert.are.equal(1400, tab.buy.total)
        assert.is_true(tab.buy.entry.noMax)
    end)

    it("does not search while another search or a buy runs (rate guard)", function()
        tab.pending = { itemID = 1, token = 1 }
        local ok, err = tab:SearchName("peace")
        assert.is_false(ok)
        assert.matches("running", err)
        tab.pending = nil
        client.ready = false
        ok, err = tab:SearchName("peace")
        assert.is_false(ok)
        assert.matches("waiting", err)
        assert.are.equal(0, #finder.calls)
    end)

    it("does not send a second name query while one waits for its answer", function()
        local held
        function finder.Find(_, _, callback)
            held = callback
        end
        assert.is_true(tab:SearchName("peace"))
        local ok = tab:SearchName("peace")
        assert.is_false(ok)
        held({})
        assert.is_true(tab:SearchName("peace"))
    end)

    it("returns to the groups on Clear and keeps the group selection", function()
        tab:RefreshList()
        tab:Select_("100")
        assert.are.equal("100", tab.selectedKey)
        tab:SearchName("peace")
        assert.is_nil(tab.selectedKey)
        tab:Select_("300")
        ui.searchClear.scripts.OnClick(ui.searchClear)
        assert.is_nil(tab.searchResults)
        assert.are.equal("", ui.searchInput:GetText())
        assert.are.equal("100", tab.selectedKey)
        assert.are.equal(500, tab.list[1].maxPrice)
    end)

    it("clears on empty text and when the source changes", function()
        tab:SearchName("peace")
        assert.is_true(tab:SearchName("   "))
        assert.is_nil(tab.searchResults)
        tab:SearchName("peace")
        tab:SetSource("groups")
        assert.is_nil(tab.searchResults)
    end)

    it("does nothing without a name search object", function()
        tab.deps.ahNameSearch = nil
        local ok, err = tab:SearchName("peace")
        assert.is_false(ok)
        assert.matches("not available", err)
    end)
end)

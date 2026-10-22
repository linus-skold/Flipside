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

local LINK = "|cff1eff00|Hitem:100::::::::70:::::|h[Peacebloom]|h|r"
local EMPTY_LINK = "|cff1eff00|Hitem:100::::::::70:::::|h[]|h|r"

describe("BuyingTab shift-click search", function()
    local ns, bus, tab, finder, hooks, chatActive, requested, names, searches

    before_each(function()
        mock.reset()
        _G.ScrollUtil = nil
        local index = getmetatable(CreateFrame("Frame")).__index
        index.SetJustifyH = function() end
        index.HasFocus = function(self) return self.focused == true end
        hooks, chatActive, requested, names, searches = {}, nil, {}, {}, {}
        _G.ChatEdit_InsertLink = function() end
        _G.hooksecurefunc = function(name, fn)
            hooks[name] = fn
        end
        _G.ChatEdit_GetActiveWindow = function() return chatActive end
        ns = loadModules()
        bus = ns.EventBus.New({})
        local client = {
            CanLiveSearch = function() return true end, IsReady = function() return true end,
            LiveSearch = function(itemID, page)
                searches[#searches + 1] = { itemID, page }
                return true
            end,
            LiveRows = function() return {} end,
            LiveResultEvents = function() return "COMMODITY_RESULTS", "ITEM_RESULTS" end,
            ReadyEvent = function() return "READY" end, CloseEvent = function() return "CLOSE" end,
            BuyEvents = function() return nil end, CanBuy = function() return true end,
        }
        finder = { calls = {}, reply = { { itemID = 100, name = "Peacebloom", key = "100" } } }
        function finder:Find(query, callback, options)
            self.calls[#self.calls + 1] = { query = query, exact = options and options.exact }
            callback(self.reply)
        end
        ns.BuyingPlan.Log:Clear()
        tab = ns.BuyingTab.New({
            bus = bus,
            rules = {
                Walk = function() end, Children = function() return {} end, Name = function() return "Base" end,
                ItemsIn = function() return {} end, Path = function() return { "Base" } end,
                GroupOf = function() return nil end, EffectiveOperation = function() return nil end,
                GetOperation = function() return nil end,
            },
            formulaRun = { Evaluate = function(_, text) return tonumber(text), nil end },
            client = client, ahNameSearch = finder, isAuctionHouseOpen = function() return true end,
            after = function() end,
            itemInfo = function(id) return names[id] or ("item " .. id), 1 end,
            requestItem = function(id) requested[#requested + 1] = id end,
        })
        tab:Mount(CreateFrame("Frame", nil, UIParent), { Enter = function() end, Leave = function() end })
        tab:Select()
    end)

    after_each(function()
        _G.ChatEdit_InsertLink, _G.ChatEdit_GetActiveWindow, _G.hooksecurefunc = nil, nil, nil
        mock.teardown()
    end)

    it("hooks ChatEdit_InsertLink without replacing it", function()
        assert.is_function(hooks.ChatEdit_InsertLink)
    end)

    it("shows the item, selects it and starts its item search at once, with no browse", function()
        hooks.ChatEdit_InsertLink(LINK)
        assert.are.equal('"Peacebloom"', tab.ui.searchInput:GetText())
        assert.are.equal(0, #finder.calls)
        assert.are.equal(1, #tab.list)
        assert.are.equal("100", tab.list[1].key)
        assert.are.equal(100, tab.list[1].itemID)
        assert.are.equal("100", tab.selectedKey)
        assert.are.same({ { 100, 0 } }, searches)
        assert.is_not_nil(tab.pending)
    end)

    it("replaces an earlier search list with the one item", function()
        tab:SearchName("peace")
        assert.are.equal(1, #finder.calls)
        hooks.ChatEdit_InsertLink(LINK)
        assert.are.equal(1, #finder.calls)
        assert.are.equal(1, #tab.list)
        assert.are.equal("100", tab.selectedKey)
    end)

    it("does not run a second search while a name search waits for its answer", function()
        function finder.Find() end
        tab:SearchName("peace")
        hooks.ChatEdit_InsertLink(LINK)
        assert.are.equal(0, #searches)
        assert.are.equal("a search is running", tab.ui.message.text)
    end)

    it("does nothing while the tab is not shown", function()
        tab:Deselect()
        hooks.ChatEdit_InsertLink(LINK)
        assert.are.equal(0, #finder.calls)
        assert.are.equal(0, #searches)
    end)

    it("does nothing when the Auction House is closed", function()
        tab.deps.isAuctionHouseOpen = function() return false end
        hooks.ChatEdit_InsertLink(LINK)
        assert.are.equal(0, #finder.calls)
        assert.are.equal(0, #searches)
    end)

    it("leaves the link to an open chat edit box", function()
        chatActive = {}
        hooks.ChatEdit_InsertLink(LINK)
        assert.are.equal(0, #finder.calls)
        assert.are.equal(0, #searches)
    end)

    it("leaves the link to the item box when it has focus", function()
        tab.ui.itemInput.focused = true
        tab.ui.itemInput.Insert = function(self, text) self.inserted = text end
        hooks.ChatEdit_InsertLink(LINK)
        assert.are.equal(LINK, tab.ui.itemInput.inserted)
        assert.are.equal(0, #finder.calls)
    end)

    it("ignores text that is not an item link", function()
        hooks.ChatEdit_InsertLink("hello")
        assert.are.equal(0, #finder.calls)
    end)

    it("searches an item that is not loaded by its ID and asks the client for its data", function()
        hooks.ChatEdit_InsertLink(EMPTY_LINK)
        assert.are.equal(0, #finder.calls)
        assert.are.same({ { 100, 0 } }, searches)
        assert.are.equal("100", tab.selectedKey)
        assert.are.equal('"100"', tab.ui.searchInput:GetText())
        assert.are.same({ 100 }, requested)
    end)
end)

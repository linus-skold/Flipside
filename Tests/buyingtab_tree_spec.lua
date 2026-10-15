local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end, Flavour = { hasCommodityMarket = true } }
    for _, name in ipairs({ "EventBus", "ItemString", "BuyingPlan", "Theme", "Widgets", "Window", "List", "Tree",
        "Tabs",
        "Columns", "AuctionTabs", "BuyingTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

-- These specs keep ScrollUtil: the game uses the ScrollBox path.
describe("BuyingTab item tree", function()
    local ns, bus, client, rules, tab, ui, groups, itemGroup, views

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

    -- Group 2 "Herbs" holds item 10 and has the subgroup 3 "Flowers" with item 11. Item 12 is in no group.
    local function makeRules()
        return {
            Walk = function(_, fn)
                fn(1)
                fn(2)
                fn(3)
            end,
            ItemsIn = function(_, id)
                return id == 2 and { "10" } or id == 3 and { "11" } or {}
            end,
            Children = function(_, id) return (groups[id] or {}).children or {} end,
            Name = function(_, id) return groups[id].name end,
            Path = function(_, id) return groups[id].name end,
            GroupOf = function(_, key) return itemGroup[key] end,
            EffectiveOperation = function() return 7 end,
            GetOperation = function()
                return { name = "Cheap", settings = { maxPrice = "100", showAboveMax = false } }
            end,
        }
    end

    local function mount()
        local core = ns.BuyingTab.New({
            bus = bus, rules = rules, formulaRun = { Evaluate = function(_, text) return tonumber(text), nil end },
            client = client,
            after = function() end,
            itemInfo = function(id) return "Item" .. id, 1 end,
        })
        core:Mount(CreateFrame("Frame", nil, UIParent), { Enter = function() end, Leave = function() end })
        return core
    end

    -- Draw the row of a visible tree node by its id, as the ScrollBox does. Returns the row.
    local function draw(id)
        for _, treeNode in ipairs(ui.tree.box.dataProvider:GetVisible()) do
            if treeNode:GetData().id == id then
                local row = CreateFrame("Button")
                views[ui.tree.box].initializer(row, treeNode)
                return row
            end
        end
        error("no visible node " .. id)
    end

    local function visibleIds()
        local ids = {}
        for _, treeNode in ipairs(ui.tree.box.dataProvider:GetVisible()) do
            ids[#ids + 1] = treeNode:GetData().id
        end
        return ids
    end

    before_each(function()
        mock.reset()
        views = {}
        local init = _G.ScrollUtil.InitScrollBoxListWithScrollBar
        _G.ScrollUtil.InitScrollBoxListWithScrollBar = function(box, bar, view)
            views[box] = view
            init(box, bar, view)
        end
        getmetatable(CreateFrame("Frame")).__index.SetJustifyH = function() end
        ns = loadModules()
        bus = ns.EventBus.New({})
        client = makeClient()
        groups = {
            [1] = { name = "Base", children = { 2 } },
            [2] = { name = "Herbs", children = { 3 } },
            [3] = { name = "Flowers", children = {} },
        }
        itemGroup = {}
        rules = makeRules()
        ns.BuyingPlan.Log:Clear()
        tab = mount()
        ui = tab.ui
        tab:RefreshList()
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("the tree data", function()
        local function name(entry) return "N" .. entry.key end

        it("puts items under their groups, items first, then the subgroups", function()
            local roots = ns.BuyingTab.BuildNodes(rules, {
                { key = "10", groupID = 2 }, { key = "11", groupID = 3 },
            }, name)
            assert.are.equal(1, #roots)
            assert.are.equal("g2", roots[1].id)
            assert.are.equal("Herbs", roots[1].text)
            assert.are.equal("i10", roots[1].children[1].id)
            assert.are.equal("g3", roots[1].children[2].id)
            assert.are.equal("i11", roots[1].children[2].children[1].id)
            assert.are.equal("N10", roots[1].children[1].text)
        end)

        it("puts an item with no group under one last node", function()
            local roots = ns.BuyingTab.BuildNodes(rules, {
                { key = "12" }, { key = "10", groupID = 2 }, { key = "13", groupID = 1 },
            }, name)
            assert.are.equal(2, #roots)
            local none = roots[2]
            assert.are.equal("none", none.id)
            assert.are.equal("Not in a group", none.text)
            assert.are.equal("i12", none.children[1].id)
            assert.are.equal("i13", none.children[2].id)
        end)

        it("has no ungrouped node when every item is in a group", function()
            local roots = ns.BuyingTab.BuildNodes(rules, { { key = "10", groupID = 2 } }, name)
            assert.are.equal(1, #roots)
        end)

        it("hides a group with no item and keeps an item of an unknown group", function()
            local roots = ns.BuyingTab.BuildNodes(rules, { { key = "11", groupID = 3 }, { key = "9", groupID = 99 } },
                name)
            assert.are.equal("g2", roots[1].id)
            assert.are.equal("g3", roots[1].children[1].id)
            assert.are.equal("none", roots[2].id)
            assert.are.equal("i9", roots[2].children[1].id)
        end)

        it("shows the shopping list as the tree in the ScrollBox", function()
            assert.are.equal("WowScrollBoxList", ui.tree.box.template)
            assert.are.equal(22, views[ui.tree.box].extent)
            assert.are.same({ "g2", "i10", "g3", "i11" }, visibleIds())
        end)
    end)

    describe("the click", function()
        it("selects the item and starts the search at once", function()
            local row = draw("i10")
            row.scripts.OnClick(row, "LeftButton")
            assert.are.equal("10", tab.selectedKey)
            assert.are.same({ 10 }, client.searches)
            assert.is_not_nil(tab.pending)
        end)

        it("keeps the highlight on the selected row", function()
            local row = draw("i10")
            row.scripts.OnClick(row, "LeftButton")
            assert.are.equal("i10", ui.tree.selected)
            assert.is_true(draw("i10").selection:IsShown())
            assert.is_false(draw("i11").selection:IsShown())
            assert.is_false(draw("g2").selection:IsShown())
            client.rows[10] = {}
            bus:Emit("ITEM_RESULTS", 10)
            assert.are.equal("i10", ui.tree.selected)
            assert.is_true(draw("i10").selection:IsShown())
        end)

        it("moves the highlight to the next item", function()
            local row = draw("i10")
            row.scripts.OnClick(row, "LeftButton")
            bus:Emit("ITEM_RESULTS", 10)
            local second = draw("i11")
            second.scripts.OnClick(second, "LeftButton")
            assert.is_true(draw("i11").selection:IsShown())
            assert.is_false(draw("i10").selection:IsShown())
            assert.are.same({ 10, 11 }, client.searches)
        end)

        it("only collapses and expands on a group", function()
            local row = draw("g2")
            row.scripts.OnClick(row, "LeftButton")
            assert.are.same({ "g2" }, visibleIds())
            assert.are.same({}, client.searches)
            assert.is_nil(tab.selectedKey)
            row = draw("g2")
            row.scripts.OnClick(row, "LeftButton")
            assert.are.same({ "g2", "i10", "g3", "i11" }, visibleIds())
            assert.is_false(draw("g2").selection:IsShown())
        end)

        it("holds the search of a click while another search runs", function()
            local first = draw("i10")
            first.scripts.OnClick(first, "LeftButton")
            local second = draw("i11")
            second.scripts.OnClick(second, "LeftButton")
            assert.are.equal("11", tab.selectedKey)
            assert.are.same({ 10 }, client.searches)
            assert.matches("queued", ui.message.text)
            bus:Emit("ITEM_RESULTS", 10)
            assert.are.same({ 10, 11 }, client.searches)
            assert.are.equal(11, tab.pending.itemID)
        end)

        it("does not start the held search when the selection moved on", function()
            local first = draw("i10")
            first.scripts.OnClick(first, "LeftButton")
            local second = draw("i11")
            second.scripts.OnClick(second, "LeftButton")
            tab:Select_("10")
            bus:Emit("ITEM_RESULTS", 10)
            assert.are.same({ 10 }, client.searches)
        end)

        it("does not search when the live search is not available", function()
            client.CanLiveSearch = function() return false end
            local row = draw("i10")
            row.scripts.OnClick(row, "LeftButton")
            assert.are.equal("10", tab.selectedKey)
            assert.are.same({}, client.searches)
        end)

        it("enables the buy button after the result and the ready event, with no tab switch", function()
            client.rows[10] = { { auctionID = 1, unitPrice = 50, quantity = 3, ownerItem = false } }
            local row = draw("i10")
            row.scripts.OnClick(row, "LeftButton")
            -- The search sets the throttle: the client is not ready when the result comes.
            client.ready = false
            bus:Emit("ITEM_RESULTS", 10)
            assert.is_false(ui.buyNext.enabled)
            assert.matches("waiting for the Auction House", ui.summary.text)
            client.ready = true
            bus:Emit("READY")
            assert.is_true(ui.buyNext.enabled)
            assert.are.equal("", ui.summary.text)
            assert.are.equal("1", ui.amount.text)
        end)

        it("does not buy: a click makes no protected call", function()
            local row = draw("i10")
            row.scripts.OnClick(row, "LeftButton")
            assert.is_nil(tab.buy)
        end)
    end)

    describe("the rows", function()
        it("draws an item row with the name and the max price, and a group row with the name", function()
            local item = draw("i10")
            assert.are.equal("Item10", item.label.text)
            assert.are.equal("100c", item.parts.price.text)
            assert.is_false(item.toggle:IsShown())
            local group = draw("g2")
            assert.are.equal("Herbs", group.label.text)
            assert.is_true(group.toggle:IsShown())
        end)
    end)
end)

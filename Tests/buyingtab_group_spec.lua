local manifest = require("Tests.manifest")
local mock = require("Tests.wow_mock")

local function loadModules()
    local ns = { ReportError = function() end, Flavour = { hasCommodityMarket = true } }
    for _, name in ipairs({ "EventBus", "ItemString", "BuyingPlan",
        "BuyFlow", "Theme", "Widgets", "Window", "List", "Tree",
        "Tabs",
        "Columns", "AuctionTabs", "BuyDialog", "BuyingTab" }) do
        assert(loadfile(manifest.path(name)))("Flipside", ns)
    end
    return ns
end

-- These specs keep ScrollUtil: the game uses the ScrollBox path.
describe("BuyingTab group click", function()
    local ns, bus, client, rules, tab, ui, groups, views, timers, markets

    local function makeClient()
        local c = { ready = true, searches = {}, rows = {} }
        c.CanLiveSearch = function() return true end
        c.IsReady = function() return c.ready end
        c.LiveSearch = function(itemID)
            if not c.ready then
                return false, "waiting for the Auction House"
            end
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

    -- Group 2 "Herbs" holds item 10 and has the subgroup 3 "Flowers" with item 11. Item 12 is in group 4 "Ore".
    local function makeRules()
        return {
            Walk = function(_, fn)
                fn(1)
                fn(2)
                fn(3)
                fn(4)
            end,
            ItemsIn = function(_, id)
                return id == 2 and { "10" } or id == 3 and { "11" } or id == 4 and { "12" } or {}
            end,
            Children = function(_, id) return (groups[id] or {}).children or {} end,
            Name = function(_, id) return groups[id].name end,
            Path = function(_, id) return groups[id].name end,
            GroupOf = function() return 1 end,
            EffectiveOperation = function() return 7 end,
            GetOperation = function()
                return { name = "Cheap", settings = { maxPrice = "100", showAboveMax = false } }
            end,
        }
    end

    local function row(price, quantity, own)
        return { unitPrice = price, quantity = quantity, ownerItem = own or false, auctionID = price }
    end

    -- Draw the row of a visible tree node by its id, as the ScrollBox does.
    local function draw(id)
        for _, treeNode in ipairs(ui.tree.box.dataProvider:GetVisible()) do
            if treeNode:GetData().id == id then
                local frame = CreateFrame("Button")
                views[ui.tree.box].initializer(frame, treeNode)
                return frame
            end
        end
        error("no visible node " .. id)
    end

    local function click(frame)
        frame.scripts.OnClick(frame, "LeftButton")
    end

    -- Draw the rows of the group list. Returns the row frames.
    local function drawGroup()
        local frames = {}
        for index, data in ipairs(ui.groupList.box.dataProvider.data) do
            frames[index] = CreateFrame("Button")
            views[ui.groupList.box].initializer(frames[index], data)
        end
        return frames
    end

    -- The search of the item ends with these rows.
    local function result(itemID, rows)
        client.rows[itemID] = rows
        bus:Emit("COMMODITY_RESULTS", itemID)
    end

    before_each(function()
        mock.reset()
        views, timers = {}, {}
        markets = { ["10"] = 100, ["11"] = 200, ["12"] = 300 }
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
            [1] = { name = "Base", children = { 2, 4 } },
            [2] = { name = "Herbs", children = { 3 } },
            [3] = { name = "Flowers", children = {} },
            [4] = { name = "Ore", children = {} },
        }
        rules = makeRules()
        ns.BuyingPlan.Log:Clear()
        tab = ns.BuyingTab.New({
            bus = bus, rules = rules, client = client,
            formulaRun = {
                Evaluate = function(_, text, key)
                    if text == "scanmarket" then
                        return markets[key], nil
                    end
                    return tonumber(text), nil
                end,
            },
            after = function(seconds, fn) timers[#timers + 1] = { seconds = seconds, fn = fn } end,
            itemInfo = function(id) return "Item" .. id, 1 end,
        })
        tab:Mount(CreateFrame("Frame", nil, UIParent), { Enter = function() end, Leave = function() end })
        ui = tab.ui
        tab:RefreshList()
    end)

    after_each(function()
        mock.teardown()
    end)

    describe("the pure helpers", function()
        it("takes the items of a group and of its subgroups in tree order", function()
            local keys = {}
            for _, entry in ipairs(ns.BuyingTab.GroupEntries(tab.nodes[1])) do
                keys[#keys + 1] = entry.key
            end
            assert.are.same({ "10", "11" }, keys)
            assert.are.same({}, ns.BuyingTab.GroupEntries(nil))
        end)

        it("gives the lowest price and the units without your own levels", function()
            local levels = ns.BuyingPlan.PriceLevels({ row(70, 4), row(50, 3), row(40, 9, true) })
            local out = ns.BuyingTab.DescribeGroupRow(levels, 100)
            assert.is_true(out.searched)
            assert.are.equal(50, out.price)
            assert.are.equal(7, out.quantity)
            assert.are.equal(50, out.percent)
        end)

        it("gives no price and 0 units for a searched item with none for sale", function()
            local out = ns.BuyingTab.DescribeGroupRow({}, 100)
            assert.is_true(out.searched)
            assert.is_nil(out.price)
            assert.are.equal(0, out.quantity)
            assert.is_nil(out.percent)
        end)

        it("gives an empty row for an item that was not searched", function()
            local out = ns.BuyingTab.DescribeGroupRow(nil, 100)
            assert.is_false(out.searched)
            assert.is_nil(out.price)
            assert.is_nil(out.quantity)
        end)

        it("gives no percent without a market value", function()
            local out = ns.BuyingTab.DescribeGroupRow(ns.BuyingPlan.PriceLevels({ row(50, 3) }), nil)
            assert.are.equal(50, out.price)
            assert.is_nil(out.percent)
        end)
    end)

    describe("a click on a group", function()
        it("shows the group item list and starts the search of its items one at a time", function()
            click(draw("g2"))
            assert.is_not_nil(tab.groupView)
            assert.is_true(ui.groupList.frame:IsShown())
            assert.is_true(ui.groupHeader.frame:IsShown())
            assert.is_false(ui.rowsList.frame:IsShown())
            assert.is_false(ui.levelHeader.frame:IsShown())
            assert.is_false(ui.back:IsShown())
            assert.are.same({ 10 }, client.searches)
            assert.are.equal(2, #ui.groupList.box.dataProvider.data)
            result(10, { row(50, 3) })
            assert.are.same({ 10, 11 }, client.searches)
            result(11, { row(300, 1) })
            assert.are.same({ 10, 11 }, client.searches)
            assert.is_nil(tab.queue)
        end)

        it("fills the list as the results come", function()
            click(draw("g2"))
            local data = ui.groupList.box.dataProvider.data
            assert.is_false(data[1].searched)
            assert.is_false(data[2].searched)
            assert.are.equal("Herbs: searched 0 of 2", ui.summary.text)
            result(10, { row(50, 3), row(80, 2), row(30, 5, true) })
            data = ui.groupList.box.dataProvider.data
            assert.is_true(data[1].searched)
            assert.are.equal(50, data[1].price)
            assert.are.equal(5, data[1].quantity)
            assert.are.equal(50, data[1].percent)
            assert.is_false(data[2].searched)
            assert.are.equal("Herbs: searched 1 of 2", ui.summary.text)
            result(11, { row(300, 1) })
            data = ui.groupList.box.dataProvider.data
            assert.are.equal(150, data[2].percent)
            assert.are.equal("Herbs: 2 items", ui.summary.text)
        end)

        it("draws icon, name, lowest price, colored % MV and the units", function()
            click(draw("g2"))
            result(10, { row(50, 3) })
            local frames = drawGroup()
            assert.are.equal("Item10", frames[1].nameLabel.text)
            assert.are.equal("50c", frames[1].cells.price.text)
            assert.are.equal("50%", frames[1].cells.percent.text)
            assert.are.equal("3", frames[1].cells.quantity.text)
            local r, g, b = ns.BuyingTab.PercentColor(50)
            assert.are.same({ r, g, b }, { unpack(frames[1].cells.percent.color, 1, 3) })
            assert.are.equal("—", frames[2].cells.price.text)
            assert.are.equal("—", frames[2].cells.percent.text)
            assert.are.equal("—", frames[2].cells.quantity.text)
        end)

        it("shows a dash for the price and 0 units of a searched item with no auctions", function()
            click(draw("g2"))
            result(10, {})
            local frames = drawGroup()
            assert.are.equal("—", frames[1].cells.price.text)
            assert.are.equal("0", frames[1].cells.quantity.text)
        end)

        it("uses the market value of the setting for the percent", function()
            local saved = { ["profilebuying.marketSource"] = "150" }
            tab.deps.db = {
                Get = function(_, scope, key) return saved[scope .. key] end,
                Set = function() return true end,
            }
            click(draw("g2"))
            result(10, { row(75, 3) })
            assert.are.equal(50, ui.groupList.box.dataProvider.data[1].percent)
        end)

        it("waits for the Auction House like Search all and goes on at the ready event", function()
            client.ready = false
            click(draw("g2"))
            assert.are.same({}, client.searches)
            assert.is_not_nil(tab.queue)
            assert.are.equal(5, timers[#timers].seconds)
            client.ready = true
            bus:Emit("READY")
            assert.are.same({ 10 }, client.searches)
        end)

        it("searches again when the group is clicked again", function()
            click(draw("g2"))
            result(10, { row(50, 3) })
            result(11, { row(300, 1) })
            click(draw("g2"))
            assert.are.same({ 10, 11, 10 }, client.searches)
        end)

        it("does nothing for an empty group and in the other sources", function()
            groups[4].children = {}
            local ok = tab:OpenGroup({ kind = "group", id = "g9", text = "Empty", children = {} })
            assert.is_false(ok)
            assert.is_nil(tab.groupView)
            assert.is_false(tab:OpenGroup({ kind = "item" }))
        end)

        it("shows the open group in the tree", function()
            click(draw("g2"))
            assert.is_true(draw("g2").selection:IsShown())
            assert.is_false(draw("g4").selection:IsShown())
        end)
    end)

    describe("a click on an item of the group list", function()
        local function openAndFinish()
            click(draw("g2"))
            result(10, { row(50, 3) })
            result(11, { row(300, 1) })
        end

        it("opens the price levels of the item and searches it", function()
            openAndFinish()
            click(drawGroup()[1])
            assert.are.equal("10", tab.selectedKey)
            assert.are.same({ 10, 11, 10 }, client.searches)
            assert.is_false(ui.groupList.frame:IsShown())
            assert.is_false(ui.groupHeader.frame:IsShown())
            assert.is_true(ui.rowsList.frame:IsShown())
            assert.is_true(ui.levelHeader.frame:IsShown())
            assert.is_true(ui.back:IsShown())
            assert.are.equal("i10", ui.tree.selected)
        end)

        it("keeps the buy controls of the level view", function()
            openAndFinish()
            click(drawGroup()[1])
            result(10, { row(50, 3) })
            assert.is_true(ui.buyNext:IsShown())
            assert.is_true(ui.amount:IsShown())
            assert.is_true(ui.totals:IsShown())
            assert.is_true(ui.buyNext:IsEnabled())
        end)
    end)

    describe("Back", function()
        it("shows the group item list again with no new search", function()
            click(draw("g2"))
            result(10, { row(50, 3) })
            result(11, { row(300, 1) })
            click(drawGroup()[1])
            result(10, { row(50, 3) })
            assert.are.same({ 10, 11, 10 }, client.searches)
            click(ui.back)
            assert.is_nil(tab.selectedKey)
            assert.is_not_nil(tab.groupView)
            assert.is_true(ui.groupList.frame:IsShown())
            assert.is_false(ui.rowsList.frame:IsShown())
            assert.is_false(ui.back:IsShown())
            assert.are.same({ 10, 11, 10 }, client.searches)
            assert.are.equal("Item10", drawGroup()[1].nameLabel.text)
        end)

        it("does nothing with no open group or no selected item", function()
            assert.is_false(tab:Back())
            click(draw("g2"))
            assert.is_false(tab:Back())
        end)

        it("is also done by a click on the group again", function()
            click(draw("g2"))
            result(10, { row(50, 3) })
            result(11, { row(300, 1) })
            click(drawGroup()[2])
            assert.are.equal("11", tab.selectedKey)
            result(11, { row(300, 1) })
            click(draw("g2"))
            assert.is_nil(tab.selectedKey)
            assert.is_true(ui.groupList.frame:IsShown())
            assert.is_false(ui.back:IsShown())
        end)
    end)

    describe("the queue while an item of the group is open", function()
        before_each(function()
            rules.ItemsIn = function(_, id)
                return id == 2 and { "10", "13" } or id == 3 and { "11" } or id == 4 and { "12" } or {}
            end
            tab:RefreshList()
        end)

        it("pauses the queue at the item click, keeps Buy off until the list is live, resumes at Back", function()
            click(draw("g2"))
            result(10, { row(50, 3) })
            assert.are.same({ 10, 13 }, client.searches)
            click(drawGroup()[1])
            assert.is_nil(tab.queue)
            assert.is_not_nil(tab.queuePaused)
            assert.are.equal("10", tab.selectedKey)
            -- The search of item 13 is in flight. Its result replaces the client list, then the held search runs.
            assert.is_false(ui.buyNext:IsEnabled())
            result(13, { row(70, 1) })
            assert.are.same({ 10, 13, 10 }, client.searches)
            assert.is_false(ui.buyNext:IsEnabled())
            assert.is_nil(tab.liveKey)
            result(10, { row(50, 3) })
            -- The item 11 of the queue is not searched while the item is open.
            assert.are.same({ 10, 13, 10 }, client.searches)
            assert.are.equal("10", tab.liveKey)
            assert.is_true(ui.buyNext:IsEnabled())
            click(ui.back)
            assert.is_nil(tab.queuePaused)
            assert.is_not_nil(tab.queue)
            assert.are.same({ 10, 13, 10, 11 }, client.searches)
            result(11, { row(300, 1) })
            assert.is_nil(tab.queue)
        end)

        it("drops the paused queue when an item outside the group opens", function()
            click(draw("g2"))
            result(10, { row(50, 3) })
            click(drawGroup()[1])
            assert.is_not_nil(tab.queuePaused)
            click(draw("i12"))
            assert.is_nil(tab.queuePaused)
        end)

        it("drops the paused queue at Stop, so that Back starts no search", function()
            click(draw("g2"))
            result(10, { row(50, 3) })
            click(drawGroup()[1])
            tab:Stop()
            assert.is_nil(tab.queuePaused)
            tab:Back()
            assert.is_nil(tab.queue)
        end)
    end)

    describe("the live key of the client list", function()
        it("turns Buy off with a reason when the list is for another item, and on after a new search", function()
            click(draw("i10"))
            result(10, { row(50, 3) })
            assert.are.equal("10", tab.liveKey)
            assert.is_true(ui.buyNext:IsEnabled())
            click(draw("i11"))
            result(11, { row(60, 1) })
            assert.are.equal("11", tab.liveKey)
            tab:Select_("10")
            local _, _, _, reason = tab:_NextBuy()
            assert.are.equal("the list is for another item, search it", reason)
            assert.is_false(ui.buyNext:IsEnabled())
            tab:Search()
            assert.is_nil(tab.liveKey)
            result(10, { row(50, 3) })
            assert.is_nil((select(4, tab:_NextBuy())))
            assert.is_true(ui.buyNext:IsEnabled())
        end)

        it("does not read the page of a list that is for another item", function()
            click(draw("i10"))
            result(10, { row(50, 3) })
            tab.livePage = 0
            tab.liveKey = "11"
            assert.is_false(tab:_EnsureLive(tab:_Selected()))
        end)
    end)

    describe("a click on a single item of the tree", function()
        it("opens its levels directly, with no group view and no Back", function()
            click(draw("i12"))
            assert.is_nil(tab.groupView)
            assert.are.equal("12", tab.selectedKey)
            assert.are.same({ 12 }, client.searches)
            assert.is_true(ui.rowsList.frame:IsShown())
            assert.is_false(ui.groupList.frame:IsShown())
            assert.is_false(ui.back:IsShown())
        end)

        it("ends the group view when the item is not in the open group", function()
            click(draw("g2"))
            result(10, { row(50, 3) })
            result(11, { row(300, 1) })
            click(draw("i12"))
            assert.is_nil(tab.groupView)
            assert.is_false(ui.back:IsShown())
        end)

        it("keeps the group view when the item is in the open group", function()
            click(draw("g2"))
            result(10, { row(50, 3) })
            result(11, { row(300, 1) })
            click(draw("i10"))
            assert.is_not_nil(tab.groupView)
            assert.is_true(ui.back:IsShown())
        end)
    end)

    describe("the Buying source and the group view", function()
        it("ends the group view when the source changes", function()
            click(draw("g2"))
            assert.is_not_nil(tab.groupView)
            tab:SetSource("groups")
            assert.is_nil(tab.groupView)
            assert.is_false(ui.groupList.frame:IsShown())
        end)
    end)
end)
